#!/usr/bin/env bash

setup_run_noninteractive_git() {
  GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=Never \
    GIT_ASKPASS=/usr/bin/false \
    SSH_ASKPASS=/usr/bin/false \
    GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    git "$@"
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
