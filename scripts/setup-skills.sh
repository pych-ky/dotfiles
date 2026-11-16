#!/usr/bin/env bash
# Agent Skills の導入

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/setup-common.sh
source "$script_dir/../lib/setup-common.sh"

repository_dir="$HOME/ghq/github.com/pych-ky/agent-skills"
find_skills="$HOME/.agents/skills/find-skills"
claude_find_skills="$HOME/.claude/skills/find-skills"
checkout_status=0

setup_ensure_private_checkout "$repository_dir" \
  https://github.com/pych-ky/agent-skills.git 'Agent Skills' || checkout_status=$?
case "$checkout_status" in
0) ;;
3)
  [[ "${DOTFILES_BOOTSTRAP:-0}" != 1 ]] || exit 3
  exit 0
  ;;
*) exit 1 ;;
esac

"$repository_dir/setup.sh"
mise exec -- npx --yes skills add nanaism/yomiyasu --global \
  --agent codex --agent claude-code --skill yomiyasu --yes
orca skills install --skill orca-cli --skill orca-computer-use \
  --skill orchestration --agent claude,codex
if [[ ! -e "$find_skills" && ! -L "$find_skills" ]]; then
  mise exec -- npx --yes skills add vercel-labs/skills --global \
    --agent codex --agent claude-code --skill find-skills --yes
fi
if [[ ! -e "$claude_find_skills" && ! -L "$claude_find_skills" ]]; then
  ln -s "$find_skills" "$claude_find_skills"
  printf 'changed: linked skill: %s\n' "$claude_find_skills"
fi
