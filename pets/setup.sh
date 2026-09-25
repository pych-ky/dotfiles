#!/usr/bin/env bash
# private Codex Custom Pets を取得し、付属インストーラで導入

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup_common_library="$script_dir/../lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' \
    "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

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

verify_install_paths() {
  local repository_physical
  local codex_root_physical
  local pets_root_physical

  repository_physical="$(resolve_physical_path "$1")" || {
    setup_error 'CODEX_CUSTOM_PETS_REPO_DIR must resolve through directories'
    return 1
  }
  codex_root_physical="$(resolve_physical_path "$2")" || {
    setup_error 'CODEX_HOME must resolve through directories'
    return 1
  }
  if [[ -z "$codex_root_physical" ]]; then
    setup_error 'CODEX_HOME must not resolve to /'
    return 1
  fi
  pets_root_physical="$(resolve_physical_path "$codex_root_physical/pets")" || {
    setup_error 'CODEX_HOME/pets must resolve through directories'
    return 1
  }

  if paths_overlap "$repository_physical" "$pets_root_physical"; then
    setup_error 'Codex Custom Pets repository must not overlap CODEX_HOME/pets'
    return 1
  fi
}

# 一括インストール未対応なら個別に導入
install_repository_pets() {
  local repository_dir="$1"
  local installer="$repository_dir/bin/install-pet"
  local pet_dir
  local pet_id
  local found=0

  if "$installer" --capabilities 2>/dev/null | grep -Fxq install-all; then
    "$installer" --all
    return
  fi

  for pet_dir in "$repository_dir"/pets/*; do
    [[ -d "$pet_dir" && ! -L "$pet_dir" &&
      -f "$pet_dir/pet.json" && ! -L "$pet_dir/pet.json" ]] || continue
    pet_id="${pet_dir##*/}"
    "$installer" "$pet_id" || return
    found=1
  done
  ((found)) || setup_error 'Codex Custom Pets repository does not contain installable pets'
}

main() {
  local skip
  local strict
  local home_dir="${HOME:-}"
  local codex_home="${CODEX_HOME:-}"
  local codex_root
  local repository_url="${CODEX_CUSTOM_PETS_REPO_URL:-https://github.com/pych-ky/codex-custom-pets.git}"
  local repository_dir
  local checkout_status=0
  local pets_root_physical
  local actual_pets_root

  if (($#)); then
    setup_error 'arguments are not supported'
    return 1
  fi

  skip="$(setup_read_flag CODEX_CUSTOM_PETS_SKIP)" || return
  if ((skip)); then
    printf 'skipped: Codex pets (CODEX_CUSTOM_PETS_SKIP=1)\n'
    [[ "${DOTFILES_BOOTSTRAP:-0}" != 1 ]] || return 3
    return 0
  fi
  strict="$(setup_read_flag CODEX_CUSTOM_PETS_STRICT)" || return
  setup_validate_home || return

  if [[ -n "$codex_home" ]] && ! path_is_safe_absolute "$codex_home"; then
    setup_error 'CODEX_HOME must be an absolute path other than /'
    return 1
  fi

  repository_dir="$(setup_normalize_repository_dir \
    "${CODEX_CUSTOM_PETS_REPO_DIR:-$home_dir/ghq/github.com/pych-ky/codex-custom-pets}" \
    CODEX_CUSTOM_PETS_REPO_DIR)" || return
  if ! path_is_safe_absolute "$repository_dir"; then
    setup_error 'CODEX_CUSTOM_PETS_REPO_DIR must be an absolute path other than /'
    return 1
  fi

  codex_root="${codex_home:-$home_dir/.codex}"
  while [[ "$codex_root" != / && "$codex_root" == */ ]]; do
    codex_root="${codex_root%/}"
  done
  verify_install_paths "$repository_dir" "$codex_root" || return

  if ! command -v jq >/dev/null 2>&1; then
    setup_error 'jq is required for Codex Custom Pets setup'
    return 1
  fi

  trap 'setup_cleanup_private_checkout' EXIT
  setup_ensure_private_checkout "$repository_dir" "$repository_url" \
    'Codex pets' \
    'CODEX_CUSTOM_PETS_REPO_DIR' \
    'CODEX_CUSTOM_PETS_REPO_URL' \
    'bin/install-pet' \
    'Codex Custom Pets installer is missing or not executable' \
    "$strict" || checkout_status=$?
  case "$checkout_status" in
  0) ;;
  3)
    [[ "${DOTFILES_BOOTSTRAP:-0}" != 1 ]] || return 3
    return 0
    ;;
  *) return 1 ;;
  esac

  # CODEX_HOME/pets へのインストールを直列化
  pets_root_physical="$(resolve_physical_path "$codex_root/pets")" || {
    setup_error 'CODEX_HOME/pets must resolve through directories'
    return 1
  }
  mkdir -p "$pets_root_physical" || return
  actual_pets_root="$(resolve_physical_path "$codex_root/pets")" || {
    setup_error 'CODEX_HOME/pets must resolve through directories'
    return 1
  }
  if [[ "$actual_pets_root" != "$pets_root_physical" ]]; then
    setup_error 'CODEX_HOME/pets changed while acquiring the setup lock'
    return 1
  fi
  process_lock_acquire "$pets_root_physical/.custom-pets-setup.lock" \
    'Codex Custom Pets install' 30 || return
  setup_verify_repository_or_error "$repository_dir" "$repository_url" \
    'Codex pets' \
    'CODEX_CUSTOM_PETS_REPO_DIR' \
    'CODEX_CUSTOM_PETS_REPO_URL' \
    'bin/install-pet' \
    'Codex Custom Pets installer is missing or not executable' || return
  verify_install_paths "$repository_dir" "$codex_root" || return
  install_repository_pets "$repository_dir"
}

main "$@"
