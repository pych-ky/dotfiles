#!/usr/bin/env bash
#
# ============================================================================
# 全端末で共通にする Git 設定を適用するスクリプト
# ============================================================================

set -euo pipefail

if ((EUID == 0)); then
  printf 'error: do not run scripts/setup-git.sh with sudo or as root\n' >&2
  exit 1
fi

if [[ -z "${HOME:-}" || "$HOME" != /* || ! -d "$HOME" ]]; then
  printf 'error: HOME must be an existing absolute directory\n' >&2
  exit 1
fi

home_dir="$(cd "$HOME" && pwd -P)"
if [[ "$home_dir" == / ]]; then
  printf 'error: HOME must not resolve to /\n' >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  printf 'error: git is required\n' >&2
  exit 1
fi

git_version_output=
if ! git_version_output="$(git --version 2>&1)"; then
  if [[ -n "$git_version_output" ]]; then
    printf 'error: failed to determine Git version: %s\n' \
      "$git_version_output" >&2
  else
    printf 'error: failed to determine Git version\n' >&2
  fi
  exit 1
fi

if [[ "$git_version_output" =~ ^git[[:space:]]+version[[:space:]]+([0-9]+)\.([0-9]+)([^0-9].*)?$ ]]; then
  git_major="${BASH_REMATCH[1]}"
  git_minor="${BASH_REMATCH[2]}"
else
  printf 'error: could not parse Git version: %s\n' "$git_version_output" >&2
  exit 1
fi

if ((10#$git_major < 2 || (10#$git_major == 2 && 10#$git_minor < 37))); then
  printf 'error: Git 2.37 or later is required (found: %s)\n' \
    "$git_version_output" >&2
  exit 1
fi

# 端末やツール固有の設定を残し、共通化する項目だけを更新する
git config --global --replace-all user.name 'pych_ky'
git config --global --replace-all \
  user.email '88827227+pych-ky@users.noreply.github.com'
git config --global --replace-all user.useConfigOnly true
git config --global --replace-all fetch.prune true
git config --global --replace-all init.defaultBranch 'main'
git config --global --replace-all branch.autoSetupMerge 'simple'
git config --global --replace-all push.default 'simple'
git config --global --replace-all push.autoSetupRemote true
git config --global --replace-all transfer.credentialsInUrl 'die'
git config --global --replace-all pull.ff 'only'
git config --global --replace-all merge.conflictStyle 'zdiff3'

printf 'Git configuration updated\n'
