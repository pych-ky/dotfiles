#!/usr/bin/env bash

SETUP_TEMPORARY_CLONE_DIR=

setup_process_lock_library="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/process-lock.sh"
if [[ ! -f "$setup_process_lock_library" || -L "$setup_process_lock_library" ]]; then
  printf 'error: process lock library is missing or unsafe: %s\n' \
    "$setup_process_lock_library" >&2
  return 1
fi
# shellcheck source=lib/process-lock.sh
source "$setup_process_lock_library"
unset setup_process_lock_library

setup_error() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

setup_run_noninteractive_git() {
  GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=Never \
    GIT_ASKPASS=/usr/bin/false \
    SSH_ASKPASS=/usr/bin/false \
    GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    git "$@"
}

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

setup_handle_access_failure() {
  local strict="$1"
  local label="$2"

  if [[ "$strict" == 1 ]]; then
    printf 'error: private %s repository is not accessible\n' "$label" >&2
    return 1
  fi

  printf 'warning: private %s repository is not accessible; skipping\n' "$label" >&2
}

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

setup_verify_repository_or_error() {
  local repository_error

  if ! repository_error="$(setup_verify_repository "$@")"; then
    setup_error "$repository_error"
    return 1
  fi
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
