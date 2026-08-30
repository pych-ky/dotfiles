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

# 端末やツール固有の設定を残し、共通化する項目だけを更新する。
# user.name / user.email は個人情報を公開リポジトリに置かないため、
# 非公開側 (~/.gitconfig.local) で設定する
git config --global --replace-all user.useConfigOnly true
git config --global --replace-all fetch.prune true
git config --global --replace-all init.defaultBranch 'main'
git config --global --replace-all branch.autoSetupMerge 'simple'
git config --global --replace-all push.default 'simple'
git config --global --replace-all push.autoSetupRemote true
git config --global --replace-all transfer.credentialsInUrl 'die'
git config --global --replace-all pull.ff 'only'
git config --global --replace-all merge.conflictStyle 'zdiff3'

# identity は非公開側 (~/.gitconfig.local) が正本。
# 後述の include.path は ~/.gitconfig の末尾に追加されるため、非公開側の値が優先される。
# ただし旧版が --global に書き込んだ値が残ると、非公開側を取得できない端末で
# 古い identity が使われるため、正本がある場合に限り重複を削除する
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

# GitHub の通常の認証は gh の credential helper に委譲する。
# 組織固有の URL 限定 ghtkn helper は非公開側 (~/.gitconfig.local) で設定する。
# 認証そのもの (gh auth login) は利用者が明示的に実行する。
#
# system 設定 (osxkeychain など) や旧 ghtkn helper が継承されるため、空 helper で
# 一度リセットしてから gh helper だけを追加する (helper の二重登録を避ける)
git config --global --replace-all 'credential.https://github.com.helper' ''
git config --global --add \
  'credential.https://github.com.helper' '!gh auth git-credential'
git config --global --replace-all 'credential.https://github.com.useHttpPath' true

if ! command -v gh >/dev/null 2>&1; then
  printf 'warning: gh is not installed; default GitHub HTTPS authentication will not work\n' >&2
  printf '         install it, then run `gh auth login` yourself (do not let an agent run it)\n' >&2
fi

# 組織固有の Git 設定 (includeIf や credential helper の上書きなど) の受け皿。
# 端末固有の他の include を消さないよう、未登録のときだけ追加する。
# ファイルが存在しない間、include は無視される
if ! git config --global --get-all include.path 2>/dev/null |
  grep -qxF '~/.gitconfig.local'; then
  git config --global --add include.path '~/.gitconfig.local'
fi

# ----------------------------------------------------------------------------
# グローバルフック (core.hooksPath)
# ----------------------------------------------------------------------------
#
# core.hooksPath を設定すると Git は各リポジトリの .git/hooks を参照しなくなるため、
# 個別のフックを直接指定すると、リポジトリ固有フックと Git LFS のフックが
# 動かなくなる。そこで振り分け用のディレクトリを作り、そこを参照させる。
#
#   すべてのフック -> git-hooks/dispatch
#                     (gitleaks + denylist 検査 -> リポジトリ固有フック -> Git LFS)
#
# dispatch から git-hooks/deny-private-strings を呼べるよう、同じディレクトリへ
# 配置する (各フックは dirname $0 を基準に参照する)。

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hooks_dir="$HOME/.local/share/dotfiles/git-hooks"

# 対象を指すシンボリックリンクを作成する (既存の異なるリンクや実体は置き換える)。
#
# リンク先が存在しない場合に ln はリンクを作れてしまい、Git は壊れたリンクの
# フックを「無い」ものとして警告なしに飛ばす。それを検出できずに
# core.hooksPath を切り替えると、全リポジトリのフックが無言で止まるため、
# ここで実体を確認して失敗させる (呼び出し側は set -e で中断する)
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

  # secretlint の pre-commit を経由していた頃のリンクを片付ける。
  # 参照先が消えると、Git は壊れたリンクのフックを警告なしに飛ばす
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
