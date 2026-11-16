#!/usr/bin/env bash
# Git 共通設定の反映

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while read -r key value; do
  git config --global --replace-all "$key" "$value"
done <<'SETTINGS'
branch.autoSetupMerge simple
fetch.prune true
init.defaultBranch main
merge.conflictStyle zdiff3
pull.ff true
pull.rebase true
push.autoSetupRemote true
push.default simple
transfer.credentialsInUrl die
user.useConfigOnly true
SETTINGS

# 空設定で継承 helper を無効化
git config --global --replace-all 'credential.https://github.com.helper' ''
git config --global --add \
  'credential.https://github.com.helper' '!gh auth git-credential'
git config --global --replace-all 'credential.https://github.com.useHttpPath' true

# 組織別の includeIf・helper はローカルで上書き
if ! git config --global --get-all include.path 2>/dev/null |
  grep -qxF \~/.gitconfig.local; then
  git config --global --add include.path \~/.gitconfig.local
fi

# dispatch は同じ場所の検査フックを呼ぶ
hooks_dir="$HOME/.local/share/dotfiles/git-hooks"
mkdir -p "$hooks_dir"
ln -sfh "$repo_dir/git-hooks/deny-private-strings" "$hooks_dir/deny-private-strings"
for hook in pre-commit prepare-commit-msg commit-msg post-commit pre-push \
  post-checkout post-merge pre-rebase post-rewrite pre-merge-commit; do
  ln -sfh "$repo_dir/git-hooks/dispatch" "$hooks_dir/$hook"
done
git config --global --replace-all core.hooksPath "$hooks_dir"

# LFS フックは dispatch に任せ、フィルタだけ導入
git lfs install --skip-repo >/dev/null

if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
  printf 'ok: Git configuration applied\n'
fi
