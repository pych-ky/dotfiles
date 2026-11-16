#!/usr/bin/env bash
# Codex Custom Pets の導入

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/setup-common.sh
source "$script_dir/../lib/setup-common.sh"

repository_dir="$HOME/ghq/github.com/pych-ky/codex-custom-pets"
checkout_status=0

setup_ensure_private_checkout "$repository_dir" \
  https://github.com/pych-ky/codex-custom-pets.git 'Codex pets' || checkout_status=$?
case "$checkout_status" in
0) "$repository_dir/bin/install-pet" --all ;;
3) [[ "${DOTFILES_BOOTSTRAP:-0}" != 1 ]] || exit 3 ;;
*) exit 1 ;;
esac
