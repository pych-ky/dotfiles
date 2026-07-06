#!/usr/bin/env bash
#
# ============================================================================
# 新しい Mac を一括セットアップするブートストラップスクリプト
# ============================================================================
#
# 実行内容:
#   1. Homebrew の導入 (未導入時、Xcode Command Line Tools も同時に導入される)
#   2. Brewfile に基づくパッケージの一括インストール
#   3. zsh プラグインの取得
#   4. install.sh による dotfiles のシンボリックリンク展開
#   5. macos/defaults.sh による macOS 設定の適用
#   6. Claude Code CLI の導入 (未導入時)
#
# 終了後に手動で行う設定は README.md の「手動セットアップ」を参照。

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 進行状況の見出しを出力
step() {
  printf '\n==> %s\n' "$1"
}

# ============================================================================
# Homebrew
# ============================================================================

step 'Homebrew'
if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# このシェルの PATH に反映 (Apple Silicon: /opt/homebrew, Intel: /usr/local)
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

step 'brew bundle'
brew bundle --file="$repo_dir/Brewfile"

# ============================================================================
# zsh プラグイン (.zshrc が ~/.zsh/plugins/*/*.plugin.zsh を一括ロードする)
# ============================================================================

step 'zsh plugins'
plugins_dir="$HOME/.zsh/plugins"
mkdir -p "$plugins_dir"
[ -d "$plugins_dir/zsh-autosuggestions" ] ||
  git clone https://github.com/zsh-users/zsh-autosuggestions "$plugins_dir/zsh-autosuggestions"
[ -d "$plugins_dir/fast-syntax-highlighting" ] ||
  git clone https://github.com/zdharma-continuum/fast-syntax-highlighting.git "$plugins_dir/fast-syntax-highlighting"

# ============================================================================
# dotfiles リンクと macOS 設定
# ============================================================================

step 'install.sh'
# 一部リンクの失敗 (例: /etc/codex の競合) は致命ではないため、警告を出して続行
if ! "$repo_dir/install.sh"; then
  printf 'warning: install.sh reported failures, continuing\n' >&2
fi

step 'macos/defaults.sh'
"$repo_dir/macos/defaults.sh"

# ============================================================================
# Claude Code CLI
# ============================================================================

step 'Claude Code'
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

step 'done'
printf 'see README.md for remaining manual setup steps\n'
