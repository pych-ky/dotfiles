#!/usr/bin/env bash
# 全端末で共通にする Git 設定を適用する。

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

# 端末やツール固有の設定を残し、共通化する項目だけを更新する。
# 個人情報の user.name / user.email は非公開側 (~/.gitconfig.local) で設定する。
git config --global --replace-all user.useConfigOnly true
git config --global --replace-all fetch.prune true
git config --global --replace-all init.defaultBranch 'main'
git config --global --replace-all branch.autoSetupMerge 'simple'
git config --global --replace-all push.default 'simple'
git config --global --replace-all push.autoSetupRemote true
git config --global --replace-all transfer.credentialsInUrl 'die'
git config --global --replace-all pull.ff 'only'
git config --global --replace-all merge.conflictStyle 'zdiff3'

# identity は ~/.gitconfig.local を正本とし、末尾の include で優先する。
# 正本がある場合だけ global の重複を削除し、非公開側を取得できない端末で古い identity が使われるのを防ぐ。
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

# GitHub は gh helper に委譲し、継承した helper を空設定でリセットして二重登録を防ぐ。
# 組織固有 URL の ghtkn helper は ~/.gitconfig.local に置き、gh auth login は利用者の依頼または承認に基づいて実行する。
git config --global --replace-all 'credential.https://github.com.helper' ''
git config --global --add \
  'credential.https://github.com.helper' '!gh auth git-credential'
git config --global --replace-all 'credential.https://github.com.useHttpPath' true

if ! command -v gh >/dev/null 2>&1; then
  printf 'warning: gh is not installed; default GitHub HTTPS authentication will not work\n' >&2
  printf "         install it, then run \`gh auth login\` (agents need a user request or approval)\n" >&2
fi

# 組織固有の includeIf や helper 上書き用。ほかの include を残して未登録時だけ追加する。
# ファイルが存在しない間は Git が無視する。
if ! git config --global --get-all include.path 2>/dev/null |
  grep -qxF \~/.gitconfig.local; then
  git config --global --add include.path \~/.gitconfig.local
fi

# core.hooksPath で隠れるリポジトリ固有フックと Git LFS は dispatch が実行する。
# secretlint/denylist 検査 → リポジトリ固有フック → Git LFS の順に呼ぶ。
# dispatch は dirname $0 を基準に参照するため、deny-private-strings を同じディレクトリへ配置する。

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hooks_dir="$HOME/.local/share/dotfiles/git-hooks"

# フックをリンクし、異なる既存リンクや実体は置き換える。
# Git は壊れたリンクを無警告で無視するため、参照先の実行権を検証して core.hooksPath 変更前に失敗させる。
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

  # 不要になった中継フックのリンクを除去する
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

# Git LFS のグローバルフィルタ (clean/smudge) を有効化する。
# フックは上記 dispatch が呼び出すため、ここでは設置しない
if command -v git-lfs >/dev/null 2>&1; then
  git lfs install --skip-repo
fi

printf 'Git configuration updated\n'
