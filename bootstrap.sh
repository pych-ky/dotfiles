#!/usr/bin/env bash
#
# ============================================================================
# 新しい Mac を一括セットアップするブートストラップスクリプト
# ============================================================================
#
# 実行内容:
#   1. sudo 認証
#   2. macos/defaults.sh による macOS 設定の適用
#   3. scripts/link-dotfiles.sh による dotfiles のシンボリックリンク展開
#   4. Homebrew の導入 (未導入時、Xcode Command Line Tools も同時に導入される)
#   5. macos/Brewfile に基づくパッケージの一括インストール
#   6. zsh プラグインの取得
#   7. Claude Code CLI / Codex CLI の導入 (未導入時)
#   8. private Codex Custom Pets の取得と一括インストール (アクセス可能な場合)
#   9. private Agent Skills の取得と同期 (アクセス可能な場合)
#
# 終了後に手動で行う設定は README.md の「手動セットアップ」を参照。

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 進行状況の見出しを出力
step() {
  printf '\n==> %s\n' "$1"
}

error() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

# sudo timestamp が有効なら再利用し、失効済みなら端末から再認証する
ensure_sudo() {
  if sudo -n -v 2>/dev/null; then
    return 0
  fi

  if ! { : </dev/tty; } 2>/dev/null; then
    printf 'error: sudo authentication requires an interactive terminal\n' >&2
    printf '       run ./bootstrap.sh from a local terminal\n' >&2
    return 1
  fi

  sudo -v
}

# Homebrew の実体を、現在の PATH と標準のインストール先から解決する
resolve_homebrew_executable() {
  local candidate

  if candidate="$(command -v brew 2>/dev/null)" && [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

if [[ "$(uname -s)" != Darwin ]]; then
  error 'bootstrap.sh supports macOS only'
  exit 1
fi

if [[ -z "${HOME:-}" || "$HOME" != /* ]]; then
  error 'HOME must be an absolute path'
  exit 1
fi

# ============================================================================
# sudo 認証、macOS 設定、dotfiles リンク
# ============================================================================

step 'sudo'
# 認証処理を含むどの経路で終了しても sudo timestamp を無効化する
trap 'sudo -k 2>/dev/null || true' EXIT
ensure_sudo

step 'macos/defaults.sh'
"$repo_dir/macos/defaults.sh"

step 'scripts/link-dotfiles.sh'
# 一部リンクの失敗 (例: /etc/codex の競合) は致命ではないため、警告を出して続行
if ! "$repo_dir/scripts/link-dotfiles.sh"; then
  printf 'warning: scripts/link-dotfiles.sh reported failures, continuing\n' >&2
fi

# ============================================================================
# Homebrew
# ============================================================================

step 'Homebrew'
brew_executable="$(resolve_homebrew_executable || true)"
if [[ -z "$brew_executable" ]]; then
  # 冒頭の認証が失効していれば、インストーラの実行前に再認証する
  ensure_sudo
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh |
    NONINTERACTIVE=1 /bin/bash
  brew_executable="$(resolve_homebrew_executable || true)"
fi

if [[ -z "$brew_executable" ]]; then
  error 'Homebrew executable was not found after installation'
  exit 1
fi

homebrew_shellenv="$("$brew_executable" shellenv)"
eval "$homebrew_shellenv"

step 'brew bundle'
# 一部パッケージの失敗 (例: 廃止された cask) は致命ではないため、警告を出して続行
if ! "$brew_executable" bundle --file="$repo_dir/macos/Brewfile"; then
  printf 'warning: brew bundle reported failures, continuing\n' >&2
fi

# 以降は管理者権限を使わないため、ここで timestamp を無効化する
sudo -k 2>/dev/null || true
trap - EXIT

# ============================================================================
# zsh プラグイン (.zshrc が ~/.zsh/plugins/*/*.plugin.zsh を一括ロードする)
# ============================================================================

step 'zsh plugins'
plugins_dir="$HOME/.zsh/plugins"
mkdir -p "$plugins_dir"
[[ -d "$plugins_dir/zsh-autosuggestions" ]] ||
  git clone https://github.com/zsh-users/zsh-autosuggestions "$plugins_dir/zsh-autosuggestions"
[[ -d "$plugins_dir/fast-syntax-highlighting" ]] ||
  git clone https://github.com/zdharma-continuum/fast-syntax-highlighting.git "$plugins_dir/fast-syntax-highlighting"

# ============================================================================
# Claude Code CLI / Codex CLI
# ============================================================================

step 'Claude Code'
if ! command -v claude >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/claude" ]]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

step 'Codex'
if ! command -v codex >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/codex" ]]; then
  curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
fi

# ============================================================================
# Codex Custom Pets
# ============================================================================

step 'Codex Custom Pets'
"$repo_dir/pets/setup.sh"

# ============================================================================
# Agent Skills
# ============================================================================

step 'Agent Skills'
"$repo_dir/skills/setup.sh"

step 'done'
printf 'see README.md for remaining manual setup steps\n'
