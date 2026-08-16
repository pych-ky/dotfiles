#!/usr/bin/env bash

set -u

script_dir() {
  local source="${BASH_SOURCE[0]}"
  local directory
  local target

  while [[ -L "$source" ]]; do
    directory="$(cd -P "$(dirname "$source")" && pwd)"
    target="$(readlink "$source")"
    if [[ "$target" == /* ]]; then
      source="$target"
    else
      source="$directory/$target"
    fi
  done
  cd -P "$(dirname "$source")" && pwd
}

scanner="$(script_dir)/pre-bash-guard.py"

command -v python3 >/dev/null 2>&1 || {
  printf 'pre-bash-guard.sh: python3 is required but not installed\n' >&2
  exit 2
}
[[ -f "$scanner" && ! -L "$scanner" ]] || {
  printf 'pre-bash-guard.sh: scanner is missing or unsafe\n' >&2
  exit 2
}

python3 "$scanner" "$@" || {
  scanner_status=$?
  if ((scanner_status != 2)); then
    printf 'pre-bash-guard.sh: scanner failed with status %s\n' \
      "$scanner_status" >&2
  fi
  exit 2
}
