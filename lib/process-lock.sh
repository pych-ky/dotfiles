#!/usr/bin/env bash

PROCESS_LOCK_HELD=0

process_lock_file_identity() {
  stat -L -f '%d:%i' "$1" 2>/dev/null
}

# 開いたロック記述子を閉じてエラーを表示する
process_lock_fail() {
  exec 9>&-
  printf 'error: %s\n' "$1" >&2
  return 1
}

# lockf で排他し、取得前後のファイル同一性を検査
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

  # bash 3.2 の exec は記述子を変数指定できないため、9 を直接指定
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

process_lock_release() {
  ((PROCESS_LOCK_HELD)) || return 0
  exec 9>&-
  PROCESS_LOCK_HELD=0
}
