#!/usr/bin/env bash
#
# private Agent Skills の checkout を用意し、repository 側の管理 CLI へ処理を委譲する。

set -euo pipefail

# ============================================================================
# グローバル設定
# ============================================================================

temporary_clone_dir=
publish_lock_dir=
publish_lock_path_identity=
publish_lock_owner_start_identity=
publish_lock_acquired=0
publish_recovery_observation=
publish_recovery_ownerless_attempts=0

# ============================================================================
# ユーティリティ
# ============================================================================

error() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

# private repository への認証が未設定の端末では Agent Skills だけをスキップする
handle_access_failure() {
  if [[ "$1" == 1 ]]; then
    error 'private Agent Skills repository is not accessible'
    return 1
  fi

  printf 'warning: private Agent Skills repository is not accessible; skipping\n' >&2
}

# Git の認証プロンプトで bootstrap 全体が待ち続けないよう非対話で実行する
run_noninteractive_git() {
  GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=Never \
    GIT_ASKPASS=/usr/bin/false \
    SSH_ASKPASS=/usr/bin/false \
    GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    git "$@"
}

# PID と開始時刻を組み合わせ、PID 再利用後の別プロセスを所有者と誤認しない
process_start_identity() {
  local identity

  identity="$(LC_ALL=C TZ=UTC /bin/ps -o lstart= -o command= -p "$1" 2>/dev/null)" ||
    return 1
  identity="${identity#"${identity%%[![:space:]]*}"}"
  identity="${identity%"${identity##*[![:space:]]}"}"
  [[ -n "$identity" ]] || return 1
  printf '%s\n' "$identity"
}

# 連続観測するディレクトリの同一性を識別
path_identity() {
  local identity

  identity="$(stat -f '%d:%i' "$1" 2>/dev/null)" ||
    identity="$(stat -c '%d:%i' "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$identity"
}

write_owner_identity() {
  printf '%s\n%s\n' "$2" "$3" >"$1"
}

# FIFO やシンボリックリンクを読まず、通常ファイルの所有者情報だけを取得
read_owner_identity() {
  local owner_file="$1"

  OWNER_IDENTITY_PID=
  OWNER_IDENTITY_START=
  if [[ -f "$owner_file" && ! -L "$owner_file" ]]; then
    {
      IFS= read -r OWNER_IDENTITY_PID || true
      IFS= read -r OWNER_IDENTITY_START || true
    } <"$owner_file"
  fi
}

is_complete_owner_identity() {
  [[ "$1" =~ ^[0-9]+$ && -n "$2" ]] || return 1
  ((10#$1 > 1))
}

is_live_owner_identity() {
  local current_start

  is_complete_owner_identity "$1" "$2" || return 1
  current_start="$(process_start_identity "$1")" || return 1
  [[ "$current_start" == "$2" ]]
}

is_live_legacy_owner_pid() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 > 1)) && kill -0 "$1" 2>/dev/null
}

# ============================================================================
# 公開ロック
# ============================================================================

# 復旧ミューテックスを取得し、放棄済みなら回収
acquire_publish_recovery_mutex() {
  local recovery_dir="$publish_lock_dir/recovery"
  local owner_file="$recovery_dir/owner"
  local recovery_identity=
  local owner_pid=
  local owner_start=
  local observation

  if mkdir "$recovery_dir" 2>/dev/null; then
    if write_owner_identity "$owner_file" "$$" "$publish_lock_owner_start_identity"; then
      publish_recovery_observation=
      publish_recovery_ownerless_attempts=0
      return 0
    fi
    rmdir "$recovery_dir" 2>/dev/null || true
    return 1
  fi

  [[ -d "$recovery_dir" && ! -L "$recovery_dir" ]] || return 1
  recovery_identity="$(path_identity "$recovery_dir")" || return 1
  read_owner_identity "$owner_file"
  owner_pid="$OWNER_IDENTITY_PID"
  owner_start="$OWNER_IDENTITY_START"
  if is_live_owner_identity "$owner_pid" "$owner_start" ||
    { [[ -z "$owner_start" ]] && is_live_legacy_owner_pid "$owner_pid"; }; then
    publish_recovery_observation=
    publish_recovery_ownerless_attempts=0
    return 1
  fi

  observation="$recovery_identity|$owner_pid|$owner_start"
  if [[ "$observation" != "$publish_recovery_observation" ]]; then
    publish_recovery_observation="$observation"
    publish_recovery_ownerless_attempts=0
  fi
  if ! is_complete_owner_identity "$owner_pid" "$owner_start" &&
    [[ ! "$owner_pid" =~ ^[0-9]+$ ]]; then
    publish_recovery_ownerless_attempts=$((publish_recovery_ownerless_attempts + 1))
    ((publish_recovery_ownerless_attempts >= 10)) || return 1
  fi

  [[ "$(path_identity "$recovery_dir" 2>/dev/null || true)" == "$recovery_identity" ]] ||
    return 1
  read_owner_identity "$owner_file"
  if [[ "$OWNER_IDENTITY_PID" != "$owner_pid" ||
    "$OWNER_IDENTITY_START" != "$owner_start" ]] ||
    is_live_owner_identity "$OWNER_IDENTITY_PID" "$OWNER_IDENTITY_START" ||
    { [[ -z "$OWNER_IDENTITY_START" ]] &&
      is_live_legacy_owner_pid "$OWNER_IDENTITY_PID"; }; then
    return 1
  fi

  rm -f "$owner_file" 2>/dev/null || return 1
  rmdir "$recovery_dir" 2>/dev/null || return 1
  publish_recovery_observation=
  publish_recovery_ownerless_attempts=0

  mkdir "$recovery_dir" 2>/dev/null || return 1
  if ! write_owner_identity "$owner_file" "$$" "$publish_lock_owner_start_identity"; then
    rmdir "$recovery_dir" 2>/dev/null || true
    return 1
  fi
}

release_publish_recovery_mutex() {
  local recovery_dir="$publish_lock_dir/recovery"
  local owner_file="$recovery_dir/owner"

  read_owner_identity "$owner_file"
  [[ "$OWNER_IDENTITY_PID" == "$$" &&
    "$OWNER_IDENTITY_START" == "$publish_lock_owner_start_identity" ]] || return 1
  rm -f "$owner_file" 2>/dev/null || return 1
  rmdir "$recovery_dir" 2>/dev/null
}

# 所有者が終了した公開ロックを、同一性を再確認して回収
recover_abandoned_publish_lock() {
  local expected_identity="$1"
  local expected_owner="$2"
  local expected_owner_start="$3"
  local owner_file="$publish_lock_dir/owner"

  [[ -n "$expected_identity" ]] || return 1
  [[ -d "$publish_lock_dir" && ! -L "$publish_lock_dir" ]] || return 1
  [[ "$(path_identity "$publish_lock_dir" 2>/dev/null || true)" == "$expected_identity" ]] ||
    return 1
  acquire_publish_recovery_mutex || return 1

  read_owner_identity "$owner_file"
  if [[ "$(path_identity "$publish_lock_dir" 2>/dev/null || true)" != "$expected_identity" ]] ||
    [[ "$OWNER_IDENTITY_PID" != "$expected_owner" ]] ||
    [[ "$OWNER_IDENTITY_START" != "$expected_owner_start" ]] ||
    is_live_owner_identity "$OWNER_IDENTITY_PID" "$OWNER_IDENTITY_START" ||
    { [[ -z "$OWNER_IDENTITY_START" ]] &&
      is_live_legacy_owner_pid "$OWNER_IDENTITY_PID"; }; then
    release_publish_recovery_mutex 2>/dev/null || true
    return 1
  fi

  rm -f "$owner_file" 2>/dev/null || {
    release_publish_recovery_mutex 2>/dev/null || true
    return 1
  }
  release_publish_recovery_mutex 2>/dev/null || return 1
  rmdir "$publish_lock_dir" 2>/dev/null
}

# 保存先の公開ロックを取得し、放棄済みロックを回収
acquire_publish_lock() {
  local attempts=0
  local max_attempts=300
  local ownerless_attempts=0
  local observed_lock_state=
  local current_lock_identity=
  local owner_pid=
  local owner_start=

  publish_lock_dir="$1"
  publish_lock_owner_start_identity="$(process_start_identity "$$")" || {
    error 'Agent Skills publish lock owner could not be identified'
    return 1
  }
  while true; do
    if mkdir "$publish_lock_dir" 2>/dev/null; then
      if ! write_owner_identity "$publish_lock_dir/owner" "$$" \
        "$publish_lock_owner_start_identity"; then
        rm -f "$publish_lock_dir/owner" 2>/dev/null || true
        rmdir "$publish_lock_dir" 2>/dev/null || true
        error 'Agent Skills publish lock owner could not be recorded'
        return 1
      fi
      if ! publish_lock_path_identity="$(path_identity "$publish_lock_dir")"; then
        rm -f "$publish_lock_dir/owner" 2>/dev/null || true
        rmdir "$publish_lock_dir" 2>/dev/null || true
        error 'Agent Skills publish lock could not be identified'
        return 1
      fi
      publish_lock_acquired=1
      return 0
    fi

    if [[ -L "$publish_lock_dir" ]] ||
      { [[ -e "$publish_lock_dir" ]] && [[ ! -d "$publish_lock_dir" ]]; }; then
      error 'Agent Skills publish lock could not be acquired'
      return 1
    fi

    current_lock_identity="$(path_identity "$publish_lock_dir" 2>/dev/null || true)"
    read_owner_identity "$publish_lock_dir/owner"
    owner_pid="$OWNER_IDENTITY_PID"
    owner_start="$OWNER_IDENTITY_START"
    if is_live_owner_identity "$owner_pid" "$owner_start" ||
      { [[ -z "$owner_start" ]] && is_live_legacy_owner_pid "$owner_pid"; }; then
      observed_lock_state=
      ownerless_attempts=0
    elif is_complete_owner_identity "$owner_pid" "$owner_start" ||
      [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
      recover_abandoned_publish_lock "$current_lock_identity" "$owner_pid" "$owner_start" && continue
    else
      if [[ "$current_lock_identity|$owner_pid|$owner_start" != "$observed_lock_state" ]]; then
        observed_lock_state="$current_lock_identity|$owner_pid|$owner_start"
        ownerless_attempts=0
      fi
      ownerless_attempts=$((ownerless_attempts + 1))
      if ((ownerless_attempts >= 10)); then
        recover_abandoned_publish_lock "$current_lock_identity" "$owner_pid" "$owner_start" && continue
      fi
    fi

    if ((attempts >= max_attempts)); then
      error 'timed out waiting for Agent Skills publish lock'
      return 1
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
}

# 自プロセスが所有する公開ロックだけを、パスと所有者を再確認して解放
release_publish_lock() {
  ((publish_lock_acquired)) || return 0
  [[ -d "$publish_lock_dir" && ! -L "$publish_lock_dir" ]] || return 1
  [[ "$(path_identity "$publish_lock_dir" 2>/dev/null || true)" == "$publish_lock_path_identity" ]] ||
    return 1
  acquire_publish_recovery_mutex || return 1
  read_owner_identity "$publish_lock_dir/owner"
  if [[ "$OWNER_IDENTITY_PID" != "$$" ||
    "$OWNER_IDENTITY_START" != "$publish_lock_owner_start_identity" ]]; then
    release_publish_recovery_mutex 2>/dev/null || true
    return 1
  fi
  rm -f "$publish_lock_dir/owner" || {
    release_publish_recovery_mutex 2>/dev/null || true
    return 1
  }
  release_publish_recovery_mutex || return 1
  rmdir "$publish_lock_dir" || return 1
  publish_lock_acquired=0
}

# 一時 clone と自プロセスが所有する公開ロックを終了時に清掃
cleanup() {
  [[ -z "$temporary_clone_dir" ]] || rm -rf "$temporary_clone_dir"
  if ((publish_lock_acquired)); then
    release_publish_lock 2>/dev/null || true
  fi
}

# ============================================================================
# リポジトリ検証
# ============================================================================

# 保存先の repository root と origin、管理 CLI の実行権を確認
verify_repository() {
  local repository_dir="$1"
  local expected_url="$2"
  local repository_root
  local repository_dir_physical
  local repository_root_physical
  local origin_url

  if [[ ! -d "$repository_dir" ]] ||
    ! repository_root="$(git -C "$repository_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    error 'Agent Skills destination is not a Git working tree'
    return 1
  fi

  repository_dir_physical="$(cd "$repository_dir" && pwd -P)"
  repository_root_physical="$(cd "$repository_root" && pwd -P)"
  if [[ "$repository_dir_physical" != "$repository_root_physical" ]]; then
    error 'AGENT_SKILLS_REPO_DIR must point to the repository root'
    return 1
  fi

  if ! origin_url="$(git -C "$repository_dir" config --local --get remote.origin.url 2>/dev/null)" ||
    [[ "$origin_url" != "$expected_url" ]]; then
    error 'Agent Skills repository origin does not match AGENT_SKILLS_REPO_URL'
    return 1
  fi

  if [[ ! -x "$repository_dir/bin/agent-skills" ]]; then
    error 'Agent Skills management CLI is missing or not executable'
    return 1
  fi
}

# ============================================================================
# エントリポイント
# ============================================================================

main() {
  local skip="${AGENT_SKILLS_SKIP:-0}"
  local strict="${AGENT_SKILLS_STRICT:-0}"
  local home_dir="${HOME:-}"
  local repository_url="${AGENT_SKILLS_REPO_URL:-https://github.com/pych-ky/agent-skills.git}"
  local repository_dir
  local repository_parent
  local clone_required=0

  if (($#)); then
    error 'arguments are not supported'
    return 1
  fi

  case "$skip" in
  0) ;;
  1)
    printf 'Agent Skills setup is disabled; skipping\n'
    return 0
    ;;
  *)
    error 'AGENT_SKILLS_SKIP must be 0 or 1'
    return 1
    ;;
  esac

  case "$strict" in
  0 | 1) ;;
  *)
    error 'AGENT_SKILLS_STRICT must be 0 or 1'
    return 1
    ;;
  esac

  if [[ -z "$home_dir" || "$home_dir" != /* ]]; then
    error 'HOME must be an absolute path'
    return 1
  fi

  repository_dir="${AGENT_SKILLS_REPO_DIR:-$home_dir/src/pych/agent-skills}"
  while [[ "$repository_dir" != / ]]; do
    case "$repository_dir" in
    */) repository_dir="${repository_dir%/}" ;;
    */.) repository_dir="${repository_dir%/.}" ;;
    *) break ;;
    esac
  done
  if [[ "$repository_dir" != /* || "$repository_dir" == / ]]; then
    error 'AGENT_SKILLS_REPO_DIR must be an absolute path other than /'
    return 1
  fi

  if ! command -v git >/dev/null 2>&1; then
    error 'git is required for Agent Skills setup'
    return 1
  fi

  if [[ -z "$repository_url" ]]; then
    error 'AGENT_SKILLS_REPO_URL must not be empty'
    return 1
  fi

  if [[ ! -e "$repository_dir" && ! -L "$repository_dir" ]]; then
    clone_required=1
    if ! run_noninteractive_git ls-remote "$repository_url" HEAD >/dev/null 2>&1; then
      if handle_access_failure "$strict"; then
        return 0
      fi
      return 1
    fi
  fi

  if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))'; then
    error 'Python 3.9 or newer is required for Agent Skills setup'
    return 1
  fi

  if ((clone_required)); then
    repository_parent="$(dirname "$repository_dir")"
    mkdir -p "$repository_parent"
    temporary_clone_dir="$(mktemp -d "$repository_parent/.agent-skills.clone.XXXXXX")"
    trap 'cleanup' EXIT

    if ! run_noninteractive_git clone --quiet --no-recurse-submodules \
      "$repository_url" "$temporary_clone_dir"; then
      error 'Agent Skills repository could not be cloned'
      return 1
    fi

    verify_repository "$temporary_clone_dir" "$repository_url" || return
    acquire_publish_lock "$repository_dir.publish-lock" || return
    if [[ ! -e "$repository_dir" && ! -L "$repository_dir" ]]; then
      mv "$temporary_clone_dir" "$repository_dir"
      temporary_clone_dir=
    fi
    verify_repository "$repository_dir" "$repository_url" || return
    release_publish_lock || return
  else
    verify_repository "$repository_dir" "$repository_url" || return
  fi

  "$repository_dir/bin/agent-skills" sync
}

main "$@"
