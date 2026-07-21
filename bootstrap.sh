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
#   5. macos/Brewfile に基づく不足パッケージのインストール
#   6. zsh プラグインの取得
#   7. Claude Code CLI / Codex CLI の導入 (未導入時)
#   8. private Codex Custom Pets の取得と一括インストール (アクセス可能な場合)
#   9. private Agent Skills の取得と同期 (アクセス可能な場合)
#
# 終了後に手動で行う設定は README.md の「手動セットアップ」を参照。

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed_steps=()

# 進行状況の見出しを出力
step() {
  printf '\n==> %s\n' "$1"
}

error() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

# 独立したステップの失敗を記録し、残りのセットアップを続行
record_failure() {
  local label="$1"
  local status="$2"

  # 中断は集約せず、その終了状態を返す
  if ((status == 130 || status == 143)); then
    return "$status"
  fi

  failed_steps+=("$label (exit $status)")
  printf 'warning: %s failed (exit %d), continuing\n' "$label" "$status" >&2
}

run_and_record() {
  local label="$1"
  local status
  shift

  if "$@"; then
    return 0
  else
    status=$?
  fi

  record_failure "$label" "$status"
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

# 取得に成功した非空のインストーラだけを実行
run_downloaded_installer() {
  local url="$1"
  local interpreter="$2"
  local environment_assignment="${3:-}"
  local installer

  installer="$(curl -fsSL "$url")" || return
  if [[ -z "$installer" ]]; then
    error "downloaded installer is empty: $url"
    return 1
  fi

  if [[ -n "$environment_assignment" ]]; then
    env "$environment_assignment" "$interpreter" <<<"$installer"
  else
    "$interpreter" <<<"$installer"
  fi
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

setup_homebrew() {
  local homebrew_installer
  local homebrew_shellenv

  brew_executable="$(resolve_homebrew_executable || true)"
  if [[ -z "$brew_executable" ]]; then
    homebrew_installer="$(
      curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
    )" || return
    if [[ -z "$homebrew_installer" ]]; then
      error 'downloaded Homebrew installer is empty'
      return 1
    fi

    # インストーラ取得後に sudo timestamp を更新
    ensure_sudo || return
    env NONINTERACTIVE=1 /bin/bash <<<"$homebrew_installer" || return
    brew_executable="$(resolve_homebrew_executable || true)"
  fi

  if [[ -z "$brew_executable" ]]; then
    error 'Homebrew executable was not found after installation'
    return 1
  fi

  homebrew_shellenv="$("$brew_executable" shellenv)" || return
  eval "$homebrew_shellenv"
}

install_zsh_plugin() {
  local name="$1"
  local url="$2"
  local entrypoint="$3"
  local target="$plugins_dir/$name"

  [[ -f "$target/$entrypoint" && -r "$target/$entrypoint" ]] && return 0

  if [[ -e "$target" || -L "$target" ]]; then
    printf 'error: incomplete zsh plugin: %s\n' "$target" >&2
    printf '       expected: %s\n' "$target/$entrypoint" >&2
    printf '       move or remove the directory, then rerun ./bootstrap.sh\n' >&2
    return 1
  fi

  git clone "$url" "$target" || return
  if [[ ! -f "$target/$entrypoint" || ! -r "$target/$entrypoint" ]]; then
    printf 'error: zsh plugin entrypoint was not installed: %s\n' \
      "$target/$entrypoint" >&2
    return 1
  fi
}

if ((EUID == 0)); then
  error 'do not run bootstrap.sh with sudo or as root'
  exit 1
fi

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
run_and_record 'macos/defaults.sh' "$repo_dir/macos/defaults.sh"

step 'scripts/link-dotfiles.sh'
if ensure_sudo; then
  run_and_record 'scripts/link-dotfiles.sh' "$repo_dir/scripts/link-dotfiles.sh"
else
  status=$?
  record_failure 'scripts/link-dotfiles.sh sudo authorization' "$status"
fi

# ============================================================================
# Homebrew
# ============================================================================

step 'Homebrew'
homebrew_ready=0
if setup_homebrew; then
  homebrew_ready=1
else
  status=$?
  record_failure 'Homebrew' "$status"
fi

if ((homebrew_ready)); then
  step 'brew bundle'
  # cask に備えて sudo timestamp を更新
  if ensure_sudo; then
    run_and_record \
      'brew bundle' \
      "$brew_executable" bundle --no-upgrade --file="$repo_dir/macos/Brewfile"
  else
    status=$?
    record_failure 'brew bundle sudo authorization' "$status"
  fi
else
  printf 'warning: skipping brew bundle because Homebrew is unavailable\n' >&2
fi

# 以降は管理者権限を使わないため、ここで timestamp を無効化する
sudo -k 2>/dev/null || true
trap - EXIT

# ============================================================================
# zsh プラグイン (.zshrc が ~/.zsh/plugins/*/*.plugin.zsh を一括ロードする)
# ============================================================================

step 'zsh plugins'
plugins_dir="$HOME/.zsh/plugins"
if mkdir -p "$plugins_dir"; then
  run_and_record \
    'zsh-autosuggestions' \
    install_zsh_plugin \
    zsh-autosuggestions \
    https://github.com/zsh-users/zsh-autosuggestions \
    zsh-autosuggestions.plugin.zsh
  run_and_record \
    'fast-syntax-highlighting' \
    install_zsh_plugin \
    fast-syntax-highlighting \
    https://github.com/zdharma-continuum/fast-syntax-highlighting.git \
    fast-syntax-highlighting.plugin.zsh
else
  status=$?
  record_failure 'zsh plugins directory' "$status"
fi

# ============================================================================
# Claude Code CLI / Codex CLI
# ============================================================================

step 'Claude Code'
if ! command -v claude >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/claude" ]]; then
  run_and_record \
    'Claude Code installer' \
    run_downloaded_installer https://claude.ai/install.sh /bin/bash
fi

step 'Codex'
if ! command -v codex >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/codex" ]]; then
  run_and_record \
    'Codex installer' \
    run_downloaded_installer \
    https://chatgpt.com/codex/install.sh \
    /bin/sh \
    CODEX_NON_INTERACTIVE=1
fi

# ============================================================================
# Codex Custom Pets
# ============================================================================

step 'Codex Custom Pets'
run_and_record 'Codex Custom Pets' "$repo_dir/pets/setup.sh"

# ============================================================================
# Agent Skills
# ============================================================================

step 'Agent Skills'
run_and_record 'Agent Skills' "$repo_dir/skills/setup.sh"

step 'summary'
if ((${#failed_steps[@]} > 0)); then
  printf 'bootstrap completed with failed steps:\n' >&2
  printf '  - %s\n' "${failed_steps[@]}" >&2
  printf 'fix the failures and rerun ./bootstrap.sh\n' >&2
  exit 1
fi

printf 'all setup steps completed successfully\n'
printf 'see README.md for remaining manual setup steps\n'
