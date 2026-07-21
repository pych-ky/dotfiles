#!/usr/bin/env bash
# private Codex Custom Pets の checkout を用意し、repository 側のインストーラへ処理を委譲する。

set -euo pipefail

# ============================================================================
# グローバル設定
# ============================================================================

temporary_clone_dir=

# ============================================================================
# ユーティリティ
# ============================================================================

error() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

# アクセス失敗を strict 指定に応じてエラーまたはスキップにする
handle_access_failure() {
  if [[ "$1" == 1 ]]; then
    error 'private Codex Custom Pets repository is not accessible'
    return 1
  fi

  printf 'warning: private Codex Custom Pets repository is not accessible; skipping\n' >&2
}

# Git の認証プロンプトを無効化する
run_noninteractive_git() {
  GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=Never \
    GIT_ASKPASS=/usr/bin/false \
    SSH_ASKPASS=/usr/bin/false \
    GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    git "$@"
}

# / および . / .. 成分を含む絶対パスを拒否
path_is_safe_absolute() {
  [[ "$1" == /* && "$1" != / ]] || return 1
  case "$1" in
  */../* | */.. | */./* | */.) return 1 ;;
  esac
}

# 未作成の末尾を保ち、既存の親まで物理パスを解決
resolve_physical_path() {
  local candidate="$1"
  local suffix=
  local component

  while [[ "$candidate" != / && "$candidate" == */ ]]; do
    candidate="${candidate%/}"
  done
  while [[ ! -e "$candidate" && ! -L "$candidate" ]]; do
    component="${candidate##*/}"
    if [[ -n "$component" ]]; then
      suffix="/$component$suffix"
    fi
    candidate="${candidate%/*}"
    [[ -n "$candidate" ]] || candidate=/
  done

  [[ -d "$candidate" ]] || return 1
  candidate="$(cd "$candidate" && pwd -P)" || return 1
  if [[ "$candidate" == / ]]; then
    candidate=
  fi
  printf '%s%s\n' "$candidate" "$suffix"
}

paths_overlap() {
  [[ "$1" == "$2" || "$1" == "$2"/* || "$2" == "$1"/* ]]
}

# repository と CODEX_HOME/pets の物理パス重複を検証
verify_install_paths() {
  local repository_physical
  local codex_root_physical
  local pets_root_physical

  repository_physical="$(resolve_physical_path "$1")" || {
    error 'CODEX_CUSTOM_PETS_REPO_DIR must resolve through directories'
    return 1
  }
  codex_root_physical="$(resolve_physical_path "$2")" || {
    error 'CODEX_HOME must resolve through directories'
    return 1
  }
  if [[ -z "$codex_root_physical" ]]; then
    error 'CODEX_HOME must not resolve to /'
    return 1
  fi
  pets_root_physical="$(resolve_physical_path "$codex_root_physical/pets")" || {
    error 'CODEX_HOME/pets must resolve through directories'
    return 1
  }

  if paths_overlap "$repository_physical" "$pets_root_physical"; then
    error 'Codex Custom Pets repository must not overlap CODEX_HOME/pets'
    return 1
  fi
}

# ============================================================================
# 排他制御
# ============================================================================

# repository の配置を直列化
acquire_repository_lock() {
  local repository_dir="$1"
  local actual_repository_physical
  local repository_physical
  local repository_parent
  local lock_file

  if ! command -v lockf >/dev/null 2>&1; then
    error 'lockf is required for Codex Custom Pets setup'
    return 1
  fi

  repository_physical="$(resolve_physical_path "$repository_dir")" || {
    error 'CODEX_CUSTOM_PETS_REPO_DIR must resolve through directories'
    return 1
  }
  repository_parent="$(dirname "$repository_physical")"
  lock_file="$repository_parent/.${repository_physical##*/}.setup.lock"
  mkdir -p "$repository_parent" || return
  if [[ -L "$lock_file" || (-e "$lock_file" && ! -f "$lock_file") ]]; then
    error "Codex Custom Pets repository lock is not a regular file: $lock_file"
    return 1
  fi

  exec 8>>"$lock_file"
  if [[ -L "$lock_file" || ! -f "$lock_file" ]]; then
    exec 8>&-
    error "Codex Custom Pets repository lock changed unexpectedly: $lock_file"
    return 1
  fi
  if ! lockf -s -t 30 8; then
    exec 8>&-
    error "timed out waiting for Codex Custom Pets repository lock: $lock_file"
    return 1
  fi
  actual_repository_physical="$(resolve_physical_path "$repository_dir")" || {
    error 'CODEX_CUSTOM_PETS_REPO_DIR must resolve through directories'
    return 1
  }
  if [[ "$actual_repository_physical" != "$repository_physical" ]]; then
    error 'CODEX_CUSTOM_PETS_REPO_DIR changed while acquiring the repository lock'
    return 1
  fi
}

release_repository_lock() {
  exec 8>&-
}

# CODEX_HOME/pets へのインストールを直列化
acquire_install_lock() {
  local codex_root="$1"
  local expected_pets_root="$2"
  local actual_pets_root
  local lock_file="$expected_pets_root/.custom-pets-setup.lock"

  if ! command -v lockf >/dev/null 2>&1; then
    error 'lockf is required for Codex Custom Pets setup'
    return 1
  fi

  mkdir -p "$expected_pets_root" || return
  actual_pets_root="$(resolve_physical_path "$codex_root/pets")" || {
    error 'CODEX_HOME/pets must resolve through directories'
    return 1
  }
  if [[ "$actual_pets_root" != "$expected_pets_root" ]]; then
    error 'CODEX_HOME/pets changed while acquiring the setup lock'
    return 1
  fi
  if [[ -L "$lock_file" || (-e "$lock_file" && ! -f "$lock_file") ]]; then
    error "Codex Custom Pets setup lock is not a regular file: $lock_file"
    return 1
  fi

  exec 9>>"$lock_file"
  if [[ -L "$lock_file" || ! -f "$lock_file" ]]; then
    exec 9>&-
    error "Codex Custom Pets setup lock changed unexpectedly: $lock_file"
    return 1
  fi
  if ! lockf -s -t 30 9; then
    exec 9>&-
    error "timed out waiting for Codex Custom Pets setup lock: $lock_file"
    return 1
  fi
}

# 終了時に一時 clone とロックを解放
cleanup() {
  if [[ -n "$temporary_clone_dir" ]]; then
    rm -rf "$temporary_clone_dir" 2>/dev/null || true
  fi
  exec 8>&- 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
}

# ============================================================================
# リポジトリ検証
# ============================================================================

# repository root、origin、install-pet の実行権と --all 対応を検証
verify_repository() {
  local repository_dir="$1"
  local expected_url="$2"
  local repository_root
  local repository_dir_physical
  local repository_root_physical
  local origin_url
  local installer="$repository_dir/bin/install-pet"
  local installer_usage
  local installer_status

  if [[ ! -d "$repository_dir" ]] ||
    ! repository_root="$(git -C "$repository_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    error 'Codex Custom Pets destination is not a Git working tree'
    return 1
  fi

  repository_dir_physical="$(cd "$repository_dir" && pwd -P)"
  repository_root_physical="$(cd "$repository_root" && pwd -P)"
  if [[ "$repository_dir_physical" != "$repository_root_physical" ]]; then
    error 'CODEX_CUSTOM_PETS_REPO_DIR must point to the repository root'
    return 1
  fi

  if ! origin_url="$(git -C "$repository_dir" config --local --get remote.origin.url 2>/dev/null)" ||
    [[ "$origin_url" != "$expected_url" ]]; then
    error 'Codex Custom Pets repository origin does not match CODEX_CUSTOM_PETS_REPO_URL'
    return 1
  fi

  if [[ ! -f "$installer" || -L "$installer" || ! -x "$installer" ]]; then
    error 'Codex Custom Pets installer is missing or not executable'
    return 1
  fi

  if installer_usage="$("$installer" 2>&1)"; then
    installer_status=0
  else
    installer_status=$?
  fi
  if [[ "$installer_status" -ne 2 ||
    "$installer_usage" != "Usage: $installer {<pet-id>|--all}" ]]; then
    error "Codex Custom Pets checkout does not support bin/install-pet --all; \
update it to 422d80e or later (for example, run git switch main && \
git pull --ff-only in $repository_dir)"
    return 1
  fi
}

# ============================================================================
# エントリポイント
# ============================================================================

main() {
  local skip="${CODEX_CUSTOM_PETS_SKIP:-0}"
  local strict="${CODEX_CUSTOM_PETS_STRICT:-0}"
  local home_dir="${HOME:-}"
  local codex_home="${CODEX_HOME:-}"
  local codex_root
  local repository_url="${CODEX_CUSTOM_PETS_REPO_URL:-https://github.com/pych-ky/codex-custom-pets.git}"
  local repository_dir
  local repository_parent
  local clone_required=0
  local pets_root_physical

  if (($#)); then
    error 'arguments are not supported'
    return 1
  fi

  case "$skip" in
  0) ;;
  1)
    printf 'Codex Custom Pets setup is disabled; skipping\n'
    return 0
    ;;
  *)
    error 'CODEX_CUSTOM_PETS_SKIP must be 0 or 1'
    return 1
    ;;
  esac

  case "$strict" in
  0 | 1) ;;
  *)
    error 'CODEX_CUSTOM_PETS_STRICT must be 0 or 1'
    return 1
    ;;
  esac

  if [[ -z "$home_dir" || "$home_dir" != /* || "$home_dir" == / || ! -d "$home_dir" ]] ||
    [[ "$(cd "$home_dir" 2>/dev/null && pwd -P)" == / ]]; then
    error 'HOME must be an existing absolute path other than /'
    return 1
  fi

  if [[ -n "$codex_home" ]] && ! path_is_safe_absolute "$codex_home"; then
    error 'CODEX_HOME must be an absolute path other than /'
    return 1
  fi

  repository_dir="${CODEX_CUSTOM_PETS_REPO_DIR:-$home_dir/src/pych/codex-custom-pets}"
  while [[ "$repository_dir" != / ]]; do
    case "$repository_dir" in
    */) repository_dir="${repository_dir%/}" ;;
    */.) repository_dir="${repository_dir%/.}" ;;
    *) break ;;
    esac
  done
  if ! path_is_safe_absolute "$repository_dir"; then
    error 'CODEX_CUSTOM_PETS_REPO_DIR must be an absolute path other than /'
    return 1
  fi

  codex_root="${codex_home:-$home_dir/.codex}"
  while [[ "$codex_root" != / && "$codex_root" == */ ]]; do
    codex_root="${codex_root%/}"
  done
  verify_install_paths "$repository_dir" "$codex_root" || return

  if ! command -v git >/dev/null 2>&1; then
    error 'git is required for Codex Custom Pets setup'
    return 1
  fi

  if [[ -z "$repository_url" ]]; then
    error 'CODEX_CUSTOM_PETS_REPO_URL must not be empty'
    return 1
  fi

  if [[ ! -e "$repository_dir" && ! -L "$repository_dir" ]]; then
    clone_required=1
    if ! run_noninteractive_git ls-remote -- "$repository_url" HEAD >/dev/null 2>&1; then
      if handle_access_failure "$strict"; then
        return 0
      fi
      return 1
    fi
  else
    verify_repository "$repository_dir" "$repository_url" || return
  fi

  if ! command -v jq >/dev/null 2>&1; then
    error 'jq is required for Codex Custom Pets setup'
    return 1
  fi

  trap 'cleanup' EXIT

  if ((clone_required)); then
    acquire_repository_lock "$repository_dir" || return
    repository_parent="$(dirname "$repository_dir")"
    if [[ ! -e "$repository_dir" && ! -L "$repository_dir" ]]; then
      mkdir -p "$repository_parent"
      temporary_clone_dir="$(mktemp -d "$repository_parent/.codex-custom-pets.clone.XXXXXX")"

      if ! run_noninteractive_git clone --quiet --no-recurse-submodules -- \
        "$repository_url" "$temporary_clone_dir"; then
        error 'Codex Custom Pets repository could not be cloned'
        return 1
      fi

      verify_repository "$temporary_clone_dir" "$repository_url" || return
      if ! mv "$temporary_clone_dir" "$repository_dir"; then
        error 'Codex Custom Pets repository could not be placed at its destination'
        return 1
      fi
      temporary_clone_dir=
    fi
    verify_repository "$repository_dir" "$repository_url" || return
    release_repository_lock
  else
    verify_repository "$repository_dir" "$repository_url" || return
  fi

  pets_root_physical="$(resolve_physical_path "$codex_root/pets")" || {
    error 'CODEX_HOME/pets must resolve through directories'
    return 1
  }
  acquire_install_lock "$codex_root" "$pets_root_physical" || return
  verify_repository "$repository_dir" "$repository_url" || return
  verify_install_paths "$repository_dir" "$codex_root" || return
  "$repository_dir/bin/install-pet" --all
}

main "$@"
