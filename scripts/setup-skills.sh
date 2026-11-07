#!/usr/bin/env bash
# Agent Skills の導入

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

# 既存の配置を保ち、同じスキルへのリンクを作成
link_skill() {
  local source="$1"
  local destination="$2"

  if [[ ! -f "$source/SKILL.md" ]]; then
    setup_error "skill is missing: $source"
    return 1
  fi
  if [[ "$source/SKILL.md" -ef "$destination/SKILL.md" ]]; then
    return 0
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    setup_error "skill destination already exists: $destination"
    return 1
  fi
  mkdir -p "${destination%/*}"
  ln -s "$source" "$destination"
  printf 'changed: linked skill: %s\n' "$destination"
}

# Agent Skills を取得・セットアップ
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
  mise exec -- npx --yes skills add nanaism/yomiyasu --global \
    --agent codex --agent claude-code --skill yomiyasu --yes
  orca skills install --skill orca-cli --skill orca-computer-use \
    --skill orchestration --agent claude,codex
  if [[ ! -e "$home_dir/.agents/skills/find-skills" &&
    ! -L "$home_dir/.agents/skills/find-skills" ]]; then
    mise exec -- npx --yes skills add vercel-labs/skills --global \
      --agent codex --agent claude-code --skill find-skills --yes
  fi
  link_skill "$home_dir/.agents/skills/find-skills" "$home_dir/.claude/skills/find-skills"
}

main "$@"
