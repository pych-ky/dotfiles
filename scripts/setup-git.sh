#!/usr/bin/env bash
# 全端末で共通にする Git 設定を適用する。

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' \
    "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

if ((EUID == 0)); then
  printf 'error: do not run scripts/setup-git.sh with sudo or as root\n' >&2
  exit 1
fi

setup_validate_home || exit 1

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

# 個人情報や端末固有の設定を残し、共通項目だけを更新
git config --global --replace-all user.useConfigOnly true
git config --global --replace-all fetch.prune true
git config --global --replace-all init.defaultBranch 'main'
git config --global --replace-all branch.autoSetupMerge 'simple'
git config --global --replace-all push.default 'simple'
git config --global --replace-all push.autoSetupRemote true
git config --global --replace-all transfer.credentialsInUrl 'die'
git config --global --replace-all pull.ff 'only'
git config --global --replace-all merge.conflictStyle 'zdiff3'

# ~/.gitconfig.local に identity がある場合だけ global の重複を削除
gitconfig_local="$HOME/.gitconfig.local"
if [[ -f "$gitconfig_local" ]] &&
  git config --file "$gitconfig_local" --get user.email >/dev/null 2>&1; then
  for key in user.name user.email; do
    if current="$(git config --global --get "$key" 2>/dev/null)" &&
      [[ -n "$current" ]]; then
      git config --global --unset-all "$key" || true
      printf 'removed duplicated global %s (managed in %s)\n' \
        "$key" "$gitconfig_local"
    fi
  done
else
  printf 'warning: %s does not define an identity; set user.name and user.email there\n' \
    "$gitconfig_local" >&2
fi

# 継承した helper を空設定でリセットし、gh の二重登録を防ぐ
git config --global --replace-all 'credential.https://github.com.helper' ''
git config --global --add \
  'credential.https://github.com.helper' '!gh auth git-credential'
git config --global --replace-all 'credential.https://github.com.useHttpPath' true

if ! command -v gh >/dev/null 2>&1; then
  printf 'warning: gh is not installed; default GitHub HTTPS authentication will not work\n' >&2
  printf "         install it, then run \`gh auth login\` (agents need a user request or approval)\n" >&2
fi

# 組織固有の includeIf や helper 上書き用。未作成のファイルは Git が無視する
if ! git config --global --get-all include.path 2>/dev/null |
  grep -qxF \~/.gitconfig.local; then
  git config --global --add include.path \~/.gitconfig.local
fi

# dispatch は dirname $0 から deny-private-strings を参照するため、同じ場所に配置
hooks_dir="$HOME/.local/share/dotfiles/git-hooks"

# Git が壊れたリンクを無視するため、core.hooksPath の変更前に実行権を検証
link_hook() {
  local source="$1"
  local target="$hooks_dir/$2"

  if [[ ! -x "$source" ]]; then
    printf 'error: hook source is missing or not executable: %s\n' \
      "$source" >&2
    printf '       core.hooksPath は変更していません。リポジトリの状態を確認してから再実行してください\n' >&2
    return 1
  fi

  if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
    return 0
  fi
  ln -sfh -- "$source" "$target"
}

if mkdir -p "$hooks_dir"; then
  link_hook "$repo_dir/git-hooks/deny-private-strings" 'deny-private-strings'

  for hook in pre-commit prepare-commit-msg commit-msg post-commit pre-push \
    post-checkout post-merge pre-rebase post-rewrite pre-merge-commit; do
    link_hook "$repo_dir/git-hooks/dispatch" "$hook"
  done

  obsolete_hook="$hooks_dir/_local-hook-exec"
  if [[ -L "$obsolete_hook" ]]; then
    rm -- "$obsolete_hook"
    printf 'removed obsolete hook link: %s\n' "$obsolete_hook"
  fi

  git config --global --replace-all core.hooksPath "$hooks_dir"
else
  printf 'error: failed to create the hooks directory: %s\n' "$hooks_dir" >&2
  exit 1
fi

# Git LFS のフックは dispatch が呼ぶため、フィルタだけを導入
if command -v git-lfs >/dev/null 2>&1; then
  git lfs install --skip-repo
fi

printf 'Git configuration updated\n'
