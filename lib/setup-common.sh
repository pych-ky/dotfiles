#!/usr/bin/env bash
# セットアップスクリプトの共通関数

SETUP_TEMPORARY_CLONE_DIR=
PROCESS_LOCK_HELD=0

# エラーメッセージを標準エラーに出して失敗を返す
setup_error() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

# 認証プロンプトを出さない設定で git を実行
setup_run_noninteractive_git() {
  GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=Never \
    GIT_ASKPASS=/usr/bin/false \
    SSH_ASKPASS=/usr/bin/false \
    GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    git "$@"
}

# HOME が / 以外の既存の絶対パスか検証
setup_validate_home() {
  local home_dir="${HOME:-}"
  local physical_home

  if [[ -z "$home_dir" || "$home_dir" != /* || "$home_dir" == / || ! -d "$home_dir" ]]; then
    setup_error 'HOME must be an existing absolute path other than /'
    return 1
  fi

  physical_home="$(cd "$home_dir" && pwd -P)" || return 1
  if [[ "$physical_home" == / ]]; then
    setup_error 'HOME must not resolve to /'
    return 1
  fi
}

# 環境変数を 0/1 として読み出す（未設定は 0）
setup_read_flag() {
  local variable_name="$1"
  local value="${!variable_name:-0}"

  case "$value" in
  0 | 1) printf '%s\n' "$value" ;;
  *)
    setup_error "$variable_name must be 0 or 1"
    return 1
    ;;
  esac
}

# 末尾の / と /. を除いた絶対パスを返す
setup_normalize_repository_dir() {
  local repository_dir="$1"
  local variable_name="$2"

  while [[ "$repository_dir" != / ]]; do
    case "$repository_dir" in
    */) repository_dir="${repository_dir%/}" ;;
    */.) repository_dir="${repository_dir%/.}" ;;
    *) break ;;
    esac
  done
  if [[ "$repository_dir" != /* || "$repository_dir" == / ]]; then
    setup_error "$variable_name must be an absolute path other than /"
    return 1
  fi
  printf '%s\n' "$repository_dir"
}

# アクセス不可を strict ならエラー、それ以外はスキップとして表示
setup_handle_access_failure() {
  local strict="$1"
  local label="$2"

  if [[ "$strict" == 1 ]]; then
    printf 'error: private %s repository is not accessible\n' "$label" >&2
    return 1
  fi

  printf 'skipped: %s (private repository is inaccessible)\n' "$label"
}

# checkout の root・origin・実行ファイルを検証し、不一致の理由を出力
setup_verify_repository() {
  local repository_dir="$1"
  local expected_url="$2"
  local label="$3"
  local directory_variable="$4"
  local url_variable="$5"
  local executable_relative="$6"
  local executable_error="$7"
  local repository_root
  local repository_dir_physical
  local repository_root_physical
  local origin_url

  if [[ ! -d "$repository_dir" ]] ||
    ! repository_root="$(git -C "$repository_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$label destination is not a Git working tree"
    return 1
  fi

  repository_dir_physical="$(cd "$repository_dir" && pwd -P)" || {
    printf '%s\n' "$directory_variable could not be resolved"
    return 1
  }
  repository_root_physical="$(cd "$repository_root" && pwd -P)" || {
    printf '%s\n' "$label repository root could not be resolved"
    return 1
  }
  if [[ "$repository_dir_physical" != "$repository_root_physical" ]]; then
    printf '%s\n' "$directory_variable must point to the repository root"
    return 1
  fi

  if ! origin_url="$(git -C "$repository_dir" config --local --get remote.origin.url 2>/dev/null)" ||
    [[ "$origin_url" != "$expected_url" ]]; then
    printf '%s\n' "$label repository origin does not match $url_variable"
    return 1
  fi

  if [[ ! -f "$repository_dir/$executable_relative" ||
    -L "$repository_dir/$executable_relative" ||
    ! -x "$repository_dir/$executable_relative" ]]; then
    printf '%s\n' "$executable_error"
    return 1
  fi
}

# setup_verify_repository の失敗理由をエラーとして表示
setup_verify_repository_or_error() {
  local repository_error

  if ! repository_error="$(setup_verify_repository "$@")"; then
    setup_error "$repository_error"
    return 1
  fi
}

# ファイルのデバイス番号と inode を返す
process_lock_file_identity() {
  stat -L -f '%d:%i' "$1" 2>/dev/null
}

# ロックの記述子を閉じてエラーを表示
process_lock_fail() {
  exec 9>&-
  printf 'error: %s\n' "$1" >&2
  return 1
}

# lockf で排他し、ロック取得前後のすり替えを検出
process_lock_acquire() {
  local lock_path="$1"
  local label="$2"
  local timeout_seconds="${3:-30}"
  local path_identity
  local descriptor_identity

  ((PROCESS_LOCK_HELD == 0)) || return 1
  if [[ ! -d "$(dirname "$lock_path")" ]]; then
    printf 'error: %s lock parent does not exist: %s\n' "$label" "$(dirname "$lock_path")" >&2
    return 1
  fi
  if [[ -L "$lock_path" || (-e "$lock_path" && ! -f "$lock_path") ]]; then
    printf 'error: %s lock is a legacy or invalid lock entry: %s\n' "$label" "$lock_path" >&2
    printf '       remove it manually, then retry\n' >&2
    return 1
  fi
  if [[ ! -x /usr/bin/lockf ]]; then
    printf 'error: /usr/bin/lockf is required for %s lock\n' "$label" >&2
    return 1
  fi

  # bash 3.2 は記述子の変数指定に非対応
  if ! exec 9>>"$lock_path"; then
    printf 'error: failed to open %s lock: %s\n' "$label" "$lock_path" >&2
    return 1
  fi
  if [[ ! -f "$lock_path" || -L "$lock_path" ]]; then
    process_lock_fail "unsafe $label lock path: $lock_path"
    return 1
  fi
  if ! path_identity="$(process_lock_file_identity "$lock_path")"; then
    process_lock_fail "failed to inspect $label lock: $lock_path"
    return 1
  fi
  if ! descriptor_identity="$(stat -f '%d:%i' <&9 2>/dev/null)"; then
    process_lock_fail "failed to inspect $label lock: $lock_path"
    return 1
  fi
  if [[ "$path_identity" != "$descriptor_identity" ]]; then
    process_lock_fail "$label lock changed while opening: $lock_path"
    return 1
  fi

  if ! /usr/bin/lockf -s -t "$timeout_seconds" 9; then
    process_lock_fail "timed out waiting for $label lock: $lock_path"
    return 1
  fi
  if [[ ! -f "$lock_path" || -L "$lock_path" ]] ||
    [[ "$(process_lock_file_identity "$lock_path" || true)" != "$path_identity" ]]; then
    process_lock_fail "$label lock changed while waiting: $lock_path"
    return 1
  fi

  PROCESS_LOCK_HELD=1
}

# 保持中のロックを解放
process_lock_release() {
  ((PROCESS_LOCK_HELD)) || return 0
  exec 9>&-
  PROCESS_LOCK_HELD=0
}

# private checkout を用意。アクセス不可でスキップ時は 3 を返す
setup_ensure_private_checkout() {
  local repository_dir="$1"
  local repository_url="$2"
  local label="$3"
  local directory_variable="$4"
  local url_variable="$5"
  local executable_relative="$6"
  local executable_error="$7"
  local strict="$8"
  local repository_parent

  if ! command -v git >/dev/null 2>&1; then
    setup_error "git is required for $label setup"
    return 1
  fi
  if [[ -z "$repository_url" ]]; then
    setup_error "$url_variable must not be empty"
    return 1
  fi

  if [[ -e "$repository_dir" || -L "$repository_dir" ]]; then
    setup_verify_repository_or_error "$repository_dir" "$repository_url" "$label" \
      "$directory_variable" "$url_variable" "$executable_relative" "$executable_error" || return 1
    return 0
  fi

  if ! setup_run_noninteractive_git ls-remote -- "$repository_url" HEAD >/dev/null 2>&1; then
    setup_handle_access_failure "$strict" "$label" || return 1
    return 3
  fi

  repository_parent="$(dirname "$repository_dir")"
  mkdir -p "$repository_parent" || return 1
  SETUP_TEMPORARY_CLONE_DIR="$(mktemp -d "$repository_parent/.${repository_dir##*/}.clone.XXXXXX")" ||
    return 1
  if ! setup_run_noninteractive_git clone --quiet --no-recurse-submodules -- \
    "$repository_url" "$SETUP_TEMPORARY_CLONE_DIR"; then
    setup_error "$label repository could not be cloned"
    return 1
  fi
  setup_verify_repository_or_error "$SETUP_TEMPORARY_CLONE_DIR" "$repository_url" "$label" \
    "$directory_variable" "$url_variable" "$executable_relative" "$executable_error" || return 1

  process_lock_acquire "$repository_dir.publish-lock" "$label publish" 30 || return 1
  if [[ ! -e "$repository_dir" && ! -L "$repository_dir" ]]; then
    mv "$SETUP_TEMPORARY_CLONE_DIR" "$repository_dir" || return 1
    SETUP_TEMPORARY_CLONE_DIR=
  fi
  setup_verify_repository_or_error "$repository_dir" "$repository_url" "$label" \
    "$directory_variable" "$url_variable" "$executable_relative" "$executable_error" || return 1
  process_lock_release
}

# 終了時に一時 clone と自プロセスの公開ロックを清掃
setup_cleanup_private_checkout() {
  [[ -z "$SETUP_TEMPORARY_CLONE_DIR" ]] || rm -rf "$SETUP_TEMPORARY_CLONE_DIR"
  process_lock_release 2>/dev/null || true
}
