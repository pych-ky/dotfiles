#!/usr/bin/env bash

PROCESS_LOCK_FD=9
PROCESS_LOCK_HELD=0
PROCESS_LOCK_OWNER_PID=
PROCESS_LOCK_OWNER_START=
PROCESS_LOCK_LEGACY_KIND=
PROCESS_LOCK_LEGACY_ENTRY_IDENTITY=
PROCESS_LOCK_LEGACY_STATE_DIR=
PROCESS_LOCK_RECOVERY_OBSERVATION=
PROCESS_LOCK_RECOVERY_OWNERLESS_ATTEMPTS=0

process_lock_entry_identity() {
  local identity

  identity="$(stat -f '%d:%i:%HT' "$1" 2>/dev/null)" ||
    identity="$(stat -c '%d:%i:%F' "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$identity"
}

process_lock_file_identity() {
  local identity

  identity="$(stat -L -f '%d:%i' "$1" 2>/dev/null)" ||
    identity="$(stat -L -c '%d:%i' "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$identity"
}

process_lock_start_identity() {
  local identity

  identity="$(LC_ALL=C TZ=UTC /bin/ps -o lstart= -o command= -p "$1" 2>/dev/null)" ||
    return 1
  identity="${identity#"${identity%%[![:space:]]*}"}"
  identity="${identity%"${identity##*[![:space:]]}"}"
  [[ -n "$identity" ]] || return 1
  printf '%s\n' "$identity"
}

process_lock_read_owner() {
  local owner_file="$1"

  PROCESS_LOCK_OWNER_PID=
  PROCESS_LOCK_OWNER_START=
  if [[ -f "$owner_file" && ! -L "$owner_file" ]]; then
    {
      IFS= read -r PROCESS_LOCK_OWNER_PID || true
      IFS= read -r PROCESS_LOCK_OWNER_START || true
    } <"$owner_file"
  fi
}

process_lock_owner_is_live() {
  local owner_pid="$1"
  local owner_start="$2"
  local current_start

  [[ "$owner_pid" =~ ^[0-9]+$ ]] && ((10#$owner_pid > 1)) || return 1
  if [[ -z "$owner_start" ]]; then
    kill -0 "$owner_pid" 2>/dev/null
    return
  fi
  current_start="$(process_lock_start_identity "$owner_pid")" || return 1
  [[ "$current_start" == "$owner_start" ]]
}

process_lock_describe_legacy() {
  local lock_path="$1"
  local generation_pattern="$2"
  local generation_name

  PROCESS_LOCK_LEGACY_KIND=
  PROCESS_LOCK_LEGACY_ENTRY_IDENTITY=
  PROCESS_LOCK_LEGACY_STATE_DIR=
  PROCESS_LOCK_OWNER_PID=
  PROCESS_LOCK_OWNER_START=

  if [[ -L "$lock_path" ]]; then
    generation_name="$(readlink "$lock_path")" || return 1
    [[ "$generation_pattern" == '.link-dotfiles.lock.generation.??????' &&
      "$generation_name" != */* ]] || return 1
    case "$generation_name" in
    .link-dotfiles.lock.generation.??????) ;;
    *) return 1 ;;
    esac
    PROCESS_LOCK_LEGACY_KIND=generation
    PROCESS_LOCK_LEGACY_STATE_DIR="$(dirname "$lock_path")/$generation_name"
    [[ -d "$PROCESS_LOCK_LEGACY_STATE_DIR" &&
      ! -L "$PROCESS_LOCK_LEGACY_STATE_DIR" ]] || return 1
  elif [[ -d "$lock_path" && ! -L "$lock_path" ]]; then
    PROCESS_LOCK_LEGACY_KIND=directory
    PROCESS_LOCK_LEGACY_STATE_DIR="$lock_path"
  elif [[ -f "$lock_path" && ! -L "$lock_path" ]]; then
    return 2
  elif [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
    return 3
  else
    return 1
  fi

  PROCESS_LOCK_LEGACY_ENTRY_IDENTITY="$(process_lock_entry_identity "$lock_path")" ||
    return 1
  process_lock_read_owner "$PROCESS_LOCK_LEGACY_STATE_DIR/owner"
}

process_lock_acquire_recovery() {
  local recovery_dir="$1"
  local owner_file="$recovery_dir/owner"
  local recovery_identity
  local owner_pid
  local owner_start
  local observation
  local self_start

  self_start="$(process_lock_start_identity "$$")" || return 1
  if mkdir "$recovery_dir" 2>/dev/null; then
    if printf '%s\n%s\n' "$$" "$self_start" >"$owner_file"; then
      PROCESS_LOCK_RECOVERY_OBSERVATION=
      PROCESS_LOCK_RECOVERY_OWNERLESS_ATTEMPTS=0
      return 0
    fi
    rm -f "$owner_file" 2>/dev/null || true
    rmdir "$recovery_dir" 2>/dev/null || true
    return 1
  fi

  [[ -d "$recovery_dir" && ! -L "$recovery_dir" ]] || return 1
  recovery_identity="$(process_lock_entry_identity "$recovery_dir")" || return 1
  process_lock_read_owner "$owner_file"
  owner_pid="$PROCESS_LOCK_OWNER_PID"
  owner_start="$PROCESS_LOCK_OWNER_START"
  if process_lock_owner_is_live "$owner_pid" "$owner_start"; then
    PROCESS_LOCK_RECOVERY_OBSERVATION=
    PROCESS_LOCK_RECOVERY_OWNERLESS_ATTEMPTS=0
    return 1
  fi

  observation="$recovery_identity|$owner_pid|$owner_start"
  if [[ "$observation" != "$PROCESS_LOCK_RECOVERY_OBSERVATION" ]]; then
    PROCESS_LOCK_RECOVERY_OBSERVATION="$observation"
    PROCESS_LOCK_RECOVERY_OWNERLESS_ATTEMPTS=0
  fi
  if [[ ! "$owner_pid" =~ ^[0-9]+$ ]]; then
    PROCESS_LOCK_RECOVERY_OWNERLESS_ATTEMPTS=$((
      PROCESS_LOCK_RECOVERY_OWNERLESS_ATTEMPTS + 1
    ))
    ((PROCESS_LOCK_RECOVERY_OWNERLESS_ATTEMPTS >= 10)) || return 1
  fi

  [[ "$(process_lock_entry_identity "$recovery_dir" 2>/dev/null || true)" == "$recovery_identity" ]] ||
    return 1
  process_lock_read_owner "$owner_file"
  if [[ "$PROCESS_LOCK_OWNER_PID" != "$owner_pid" ||
    "$PROCESS_LOCK_OWNER_START" != "$owner_start" ]] ||
    process_lock_owner_is_live \
      "$PROCESS_LOCK_OWNER_PID" "$PROCESS_LOCK_OWNER_START"; then
    return 1
  fi

  rm -f "$owner_file" 2>/dev/null || return 1
  rmdir "$recovery_dir" 2>/dev/null || return 1
  PROCESS_LOCK_RECOVERY_OBSERVATION=
  PROCESS_LOCK_RECOVERY_OWNERLESS_ATTEMPTS=0

  mkdir "$recovery_dir" 2>/dev/null || return 1
  if ! printf '%s\n%s\n' "$$" "$self_start" >"$owner_file"; then
    rm -f "$owner_file" 2>/dev/null || true
    rmdir "$recovery_dir" 2>/dev/null || true
    return 1
  fi
}

process_lock_release_recovery() {
  local recovery_dir="$1"
  local self_start

  self_start="$(process_lock_start_identity "$$")" || return 1
  process_lock_read_owner "$recovery_dir/owner"
  [[ "$PROCESS_LOCK_OWNER_PID" == "$$" &&
    "$PROCESS_LOCK_OWNER_START" == "$self_start" ]] || return 1

  rm -f "$recovery_dir/owner" 2>/dev/null || return 1
  rmdir "$recovery_dir" 2>/dev/null
}

process_lock_recover_legacy() {
  local lock_path="$1"
  local generation_pattern="$2"
  local expected_kind="$3"
  local expected_identity="$4"
  local expected_state_dir="$5"
  local expected_owner_pid="$6"
  local expected_owner_start="$7"
  local recovery_dir="$expected_state_dir/recovery"
  local describe_status=0

  process_lock_acquire_recovery "$recovery_dir" || return 1

  process_lock_describe_legacy "$lock_path" "$generation_pattern" ||
    describe_status=$?
  if ((describe_status != 0)) ||
    [[ "$PROCESS_LOCK_LEGACY_KIND" != "$expected_kind" ]] ||
    [[ "$PROCESS_LOCK_LEGACY_ENTRY_IDENTITY" != "$expected_identity" ]] ||
    [[ "$PROCESS_LOCK_LEGACY_STATE_DIR" != "$expected_state_dir" ]] ||
    [[ "$PROCESS_LOCK_OWNER_PID" != "$expected_owner_pid" ]] ||
    [[ "$PROCESS_LOCK_OWNER_START" != "$expected_owner_start" ]] ||
    process_lock_owner_is_live "$PROCESS_LOCK_OWNER_PID" "$PROCESS_LOCK_OWNER_START"; then
    process_lock_release_recovery "$recovery_dir"
    return 1
  fi

  if [[ "$expected_kind" == generation ]]; then
    rm "$lock_path" 2>/dev/null || {
      process_lock_release_recovery "$recovery_dir"
      return 1
    }
  fi
  rm -f "$expected_state_dir/owner" 2>/dev/null || true
  process_lock_release_recovery "$recovery_dir"
  rmdir "$expected_state_dir" 2>/dev/null || return 1
}

process_lock_wait_for_legacy() {
  local lock_path="$1"
  local generation_pattern="$2"
  local label="$3"
  local timeout_seconds="$4"
  local attempts=0
  local max_attempts=$((timeout_seconds * 10))
  local ownerless_attempts=0
  local describe_status
  local expected_kind
  local expected_identity
  local expected_state_dir
  local expected_owner_pid
  local expected_owner_start

  while true; do
    describe_status=0
    process_lock_describe_legacy "$lock_path" "$generation_pattern" ||
      describe_status=$?
    case "$describe_status" in
    2 | 3) return 0 ;;
    0) ;;
    *)
      printf 'error: unsafe %s lock path: %s\n' "$label" "$lock_path" >&2
      return 1
      ;;
    esac

    expected_kind="$PROCESS_LOCK_LEGACY_KIND"
    expected_identity="$PROCESS_LOCK_LEGACY_ENTRY_IDENTITY"
    expected_state_dir="$PROCESS_LOCK_LEGACY_STATE_DIR"
    expected_owner_pid="$PROCESS_LOCK_OWNER_PID"
    expected_owner_start="$PROCESS_LOCK_OWNER_START"

    if process_lock_owner_is_live "$expected_owner_pid" "$expected_owner_start"; then
      ownerless_attempts=0
    elif [[ "$expected_owner_pid" =~ ^[0-9]+$ ]]; then
      process_lock_recover_legacy \
        "$lock_path" "$generation_pattern" "$expected_kind" \
        "$expected_identity" "$expected_state_dir" \
        "$expected_owner_pid" "$expected_owner_start" && continue
    else
      ownerless_attempts=$((ownerless_attempts + 1))
      if ((ownerless_attempts >= 10)); then
        process_lock_recover_legacy \
          "$lock_path" "$generation_pattern" "$expected_kind" \
          "$expected_identity" "$expected_state_dir" \
          "$expected_owner_pid" "$expected_owner_start" && continue
      fi
    fi

    if ((attempts >= max_attempts)); then
      printf 'error: timed out waiting for %s lock: %s\n' "$label" "$lock_path" >&2
      return 1
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
}

process_lock_acquire() {
  local lock_path="$1"
  local generation_pattern="$2"
  local label="$3"
  local timeout_seconds="${4:-30}"
  local backend
  local path_identity
  local descriptor_identity

  ((PROCESS_LOCK_HELD == 0)) || return 1
  [[ -d "$(dirname "$lock_path")" ]] || {
    printf 'error: %s lock parent does not exist: %s\n' "$label" "$(dirname "$lock_path")" >&2
    return 1
  }
  process_lock_wait_for_legacy \
    "$lock_path" "$generation_pattern" "$label" "$timeout_seconds" || return

  if ! exec 9>>"$lock_path"; then
    printf 'error: failed to open %s lock: %s\n' "$label" "$lock_path" >&2
    return 1
  fi
  if [[ ! -f "$lock_path" || -L "$lock_path" ]]; then
    exec 9>&-
    printf 'error: unsafe %s lock path: %s\n' "$label" "$lock_path" >&2
    return 1
  fi

  path_identity="$(process_lock_file_identity "$lock_path")" || {
    exec 9>&-
    return 1
  }
  descriptor_identity="$(process_lock_file_identity "/dev/fd/$PROCESS_LOCK_FD")" || {
    exec 9>&-
    return 1
  }
  if [[ "$path_identity" != "$descriptor_identity" ]]; then
    exec 9>&-
    printf 'error: %s lock changed while opening: %s\n' "$label" "$lock_path" >&2
    return 1
  fi

  backend="$(uname -s)"
  case "$backend" in
  Darwin)
    if [[ ! -x /usr/bin/lockf ]] ||
      ! /usr/bin/lockf -s -t "$timeout_seconds" "$PROCESS_LOCK_FD"; then
      exec 9>&-
      printf 'error: timed out waiting for %s lock: %s\n' "$label" "$lock_path" >&2
      return 1
    fi
    ;;
  Linux)
    if ! command -v flock >/dev/null 2>&1 ||
      ! flock -w "$timeout_seconds" "$PROCESS_LOCK_FD"; then
      exec 9>&-
      printf 'error: timed out waiting for %s lock: %s\n' "$label" "$lock_path" >&2
      return 1
    fi
    ;;
  *)
    exec 9>&-
    printf 'error: unsupported %s lock platform: %s\n' "$label" "$backend" >&2
    return 1
    ;;
  esac

  if [[ ! -f "$lock_path" || -L "$lock_path" ]] ||
    [[ "$(process_lock_file_identity "$lock_path" 2>/dev/null || true)" != "$path_identity" ]]; then
    exec 9>&-
    printf 'error: %s lock changed while waiting: %s\n' "$label" "$lock_path" >&2
    return 1
  fi

  PROCESS_LOCK_HELD=1
}

process_lock_release() {
  ((PROCESS_LOCK_HELD)) || return 0
  exec 9>&-
  PROCESS_LOCK_HELD=0
}
