#!/usr/bin/env bash
# private Agent Skills を取得し、付属 setup.sh で配置

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

main() {
  local skip
  local strict
  local home_dir="${HOME:-}"
  local repository_url="${AGENT_SKILLS_REPO_URL:-https://github.com/pych-ky/agent-skills.git}"
  local repository_dir
  local checkout_status=0

  if (($#)); then
    setup_error 'arguments are not supported'
    return 1
  fi

  skip="$(setup_read_flag AGENT_SKILLS_SKIP)" || return
  if ((skip)); then
    printf 'skipped: Agent Skills (AGENT_SKILLS_SKIP=1)\n'
    [[ "${DOTFILES_BOOTSTRAP:-0}" != 1 ]] || return 3
    return 0
  fi
  strict="$(setup_read_flag AGENT_SKILLS_STRICT)" || return
  setup_validate_home || return

  repository_dir="$(setup_normalize_repository_dir \
    "${AGENT_SKILLS_REPO_DIR:-$home_dir/ghq/github.com/pych-ky/agent-skills}" \
    AGENT_SKILLS_REPO_DIR)" || return

  trap 'setup_cleanup_private_checkout' EXIT
  setup_ensure_private_checkout "$repository_dir" "$repository_url" \
    'Agent Skills' \
    'AGENT_SKILLS_REPO_DIR' \
    'AGENT_SKILLS_REPO_URL' \
    'setup.sh' \
    'Agent Skills setup script is missing or not executable' \
    "$strict" || checkout_status=$?
  case "$checkout_status" in
  0) ;;
  3)
    [[ "${DOTFILES_BOOTSTRAP:-0}" != 1 ]] || return 3
    return 0
    ;;
  *) return 1 ;;
  esac

  "$repository_dir/setup.sh"
}

main "$@"
