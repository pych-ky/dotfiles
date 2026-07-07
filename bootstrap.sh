#!/usr/bin/env bash
#
# ============================================================================
# 新しい Mac を一括セットアップするブートストラップスクリプト
# ============================================================================
#
# 実行内容:
#   1. sudo 認証 (パスワード入力はここでの 1 回だけ、完了まで keep-alive)
#   2. macos/defaults.sh による macOS 設定の適用
#   3. install.sh による dotfiles のシンボリックリンク展開
#   4. Homebrew の導入 (未導入時、Xcode Command Line Tools も同時に導入される)
#   5. Brewfile に基づくパッケージの一括インストール
#   6. zsh プラグインの取得
#   7. Claude Code CLI / Codex CLI の導入 (未導入時)
#
# 終了後に手動で行う設定は README.md の「手動セットアップ」を参照。

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 進行状況の見出しを出力
step() {
  printf '\n==> %s\n' "$1"
}

# ============================================================================
# sudo 認証 (パスワード入力は冒頭の 1 回だけ)
# ============================================================================

step 'sudo'
# 認証キャッシュ済みなら端末不要。端末がない非対話環境 (CI や AI エージェント等) では明示して終了
if ! sudo -n -v 2>/dev/null; then
  if ! { : </dev/tty; } 2>/dev/null; then
    printf 'error: sudo authentication requires an interactive terminal\n' >&2
    printf '       run ./bootstrap.sh from a local terminal\n' >&2
    exit 1
  fi
  sudo -v
fi

# 完了までバックグラウンドでタイムスタンプを更新し続ける (デフォルトの失効 5 分より短い間隔)
while true; do
  sleep 50
  kill -0 "$$" 2>/dev/null || exit # 親プロセス消滅時に自動終了する保険
  sudo -n -v 2>/dev/null || exit
done &
sudo_keepalive_pid=$!
# 終了時は keep-alive を止め、タイムスタンプも無効化して端末に sudo 有効状態を残さない
trap 'kill "$sudo_keepalive_pid" 2>/dev/null || true; sudo -k' EXIT

# ============================================================================
# macOS 設定と dotfiles リンク
# ============================================================================

step 'macos/defaults.sh'
"$repo_dir/macos/defaults.sh"

step 'install.sh'
# 一部リンクの失敗 (例: /etc/codex の競合) は致命ではないため、警告を出して続行
if ! "$repo_dir/install.sh"; then
  printf 'warning: install.sh reported failures, continuing\n' >&2
fi

# ============================================================================
# Homebrew
# ============================================================================

step 'Homebrew'
if ! command -v brew >/dev/null 2>&1; then
  # 事前の sudo 認証により NONINTERACTIVE でも成功する (確認プロンプトを省略して無人実行)
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# このシェルの PATH に反映 (Apple Silicon: /opt/homebrew, Intel: /usr/local)
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

step 'brew bundle'
# 一部パッケージの失敗 (例: 廃止された cask) は致命ではないため、警告を出して続行
if ! brew bundle --file="$repo_dir/Brewfile"; then
  printf 'warning: brew bundle reported failures, continuing\n' >&2
fi

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
# Claude Code CLI
# ============================================================================

step 'Claude Code'
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

# ============================================================================
# Codex CLI
# ============================================================================

step 'Codex'
if ! command -v codex >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/codex" ]; then
  curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
fi

step 'done'
printf 'see README.md for remaining manual setup steps\n'
