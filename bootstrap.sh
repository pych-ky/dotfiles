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
#   6. mise によるグローバル開発ツールの導入
#   7. scripts/setup-git.sh による Git の共通設定
#   8. zsh プラグインの取得
#   9. Claude Code CLI / Codex CLI の導入 (未導入時)
#  10. private Codex Custom Pets の取得と一括インストール (アクセス可能な場合)
#  11. private Agent Skills の取得と同期 (アクセス可能な場合)
#  12. private dotfiles-private (非公開設定) の取得と適用 (アクセス可能な場合)
#
# 終了後に手動で行う設定は README.md の「手動セットアップ」を参照。

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed_steps=()
skipped_steps=()

# 非対話 git とリポジトリ検証の共通関数
setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' \
    "$setup_common_library" >&2
  exit 1
fi
source "$setup_common_library"

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

# 実行しなかったステップを記録する。
# 失敗ではないが「完了した」とも言えないため、サマリで必ず一覧に出す
record_skip() {
  local reason="$1"

  skipped_steps+=("$reason")
  printf 'warning: skipped: %s\n' "$reason" >&2
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

  # 認証待ちで固まらないよう、他の取得処理と同じ非対話ラッパを使う
  setup_run_noninteractive_git clone --quiet -- "$url" "$target" || return
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
  # MDM 初期構成などで Homebrew ディレクトリの所有者が変わっていると bundle が失敗する
  brew_cellar="$("$brew_executable" --prefix)/Cellar"
  if [[ -d "$brew_cellar" && ! -w "$brew_cellar" ]]; then
    printf 'warning: %s is not writable\n' "$brew_cellar" >&2
    printf '         fix it with: sudo chown -R "%s" "%s"\n' \
      "$(id -un)" "$brew_cellar" >&2
  fi
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
  record_skip 'brew bundle (Homebrew が使えないため)'
fi

# 以降は管理者権限を使わないため、ここで timestamp を無効化する
sudo -k 2>/dev/null || true
trap - EXIT

# ============================================================================
# mise によるグローバル開発ツール (.config/mise/config.toml が管理する)
# ============================================================================

step 'mise install'
# mise install は設定が無くても「導入済み」と言って正常終了するため、
# 設定の有無を先に確かめる (無いのは link ステップの失敗なので skip ではなく失敗)
mise_config="${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml"
if ! command -v mise >/dev/null 2>&1; then
  record_skip 'mise install (mise が使えないため)'
elif [[ ! -r "$mise_config" ]]; then
  printf 'error: mise の設定が読めません: %s\n' "$mise_config" >&2
  printf '       scripts/link-dotfiles.sh が成功しているか確認してください\n' >&2
  record_failure 'mise install (設定が無い)' 1
else
  run_and_record 'mise install' mise install
fi

# ============================================================================
# Git の共通設定
# ============================================================================

step 'scripts/setup-git.sh'
run_and_record 'scripts/setup-git.sh' "$repo_dir/scripts/setup-git.sh"

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

# ============================================================================
# 非公開設定のオーバーレイ (private リポジトリ、アクセス可能な場合のみ)
# ============================================================================

step 'dotfiles-private overlay'
if [[ "${DOTFILES_PRIVATE_SKIP:-0}" == 1 ]]; then
  record_skip 'dotfiles-private overlay (DOTFILES_PRIVATE_SKIP=1)'
else
  overlay_dir="${DOTFILES_PRIVATE_DIR:-$HOME/src/pych/dotfiles-private}"
  overlay_url="${DOTFILES_PRIVATE_REPO_URL:-https://github.com/pych-ky/dotfiles-private.git}"
  overlay_ready=1
  # 未取得なら、まずアクセス可否を非対話で確認してから clone する (認証待ちで固まらない)
  if [[ ! -d "$overlay_dir" ]]; then
    if setup_run_noninteractive_git ls-remote -- "$overlay_url" HEAD >/dev/null 2>&1; then
      mkdir -p "$(dirname "$overlay_dir")" || true
      if ! setup_run_noninteractive_git clone --quiet --no-recurse-submodules -- \
        "$overlay_url" "$overlay_dir"; then
        record_failure 'dotfiles-private clone' 1
        overlay_ready=0
      fi
    else
      record_skip 'dotfiles-private overlay (リポジトリへアクセスできないため)'
      overlay_ready=0
    fi
  fi
  # 取得済みディレクトリが正しいリポジトリ (origin 一致・ルート・実行可能な setup.sh) か検証
  if ((overlay_ready)); then
    if overlay_error="$(
      setup_verify_repository \
        "$overlay_dir" "$overlay_url" 'dotfiles-private' \
        DOTFILES_PRIVATE_DIR DOTFILES_PRIVATE_REPO_URL \
        setup.sh 'dotfiles-private setup.sh is missing or not executable'
    )"; then
      run_and_record 'dotfiles-private setup' "$overlay_dir/setup.sh"
    else
      printf 'warning: %s\n' "$overlay_error" >&2
      record_failure 'dotfiles-private verification' 1
    fi
  fi
fi

step 'summary'
if ((${#skipped_steps[@]} > 0)); then
  printf 'skipped steps (not executed):\n' >&2
  printf '  - %s\n' "${skipped_steps[@]}" >&2
fi

if ((${#failed_steps[@]} > 0)); then
  printf 'bootstrap completed with failed steps:\n' >&2
  printf '  - %s\n' "${failed_steps[@]}" >&2
  printf 'fix the failures and rerun ./bootstrap.sh\n' >&2
  exit 1
fi

# 未実行があるまま「完了」と言わない (受け入れ条件を満たしたかを誤認させないため)
if ((${#skipped_steps[@]} > 0)); then
  printf 'bootstrap finished without failures, but some steps were skipped\n'
  printf 'satisfy their requirements and rerun ./bootstrap.sh to complete setup\n'
else
  printf 'all setup steps completed successfully\n'
fi
printf 'see README.md for remaining manual setup steps\n'
