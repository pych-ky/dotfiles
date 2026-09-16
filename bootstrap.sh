#!/usr/bin/env bash
# 新しい Mac を一括セットアップ

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed_steps=()
skipped_steps=()

setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' \
    "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

step() {
  printf '\n==> %s\n' "$1"
}

# 失敗を記録し、後続ステップを続行
record_failure() {
  local label="$1"
  local status="$2"

  # 中断は即時伝播
  if ((status == 130 || status == 143)); then
    return "$status"
  fi

  failed_steps+=("$label (exit $status)")
  printf 'warning: %s failed (exit %d), continuing\n' "$label" "$status" >&2
}

record_skip() {
  local reason="$1"

  skipped_steps+=("$reason")
  printf 'warning: skipped: %s\n' "$reason" >&2
}

run_and_record() {
  local label="$1"
  shift

  if "$@"; then
    return 0
  else
    record_failure "$label" "$?"
  fi
}

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

run_downloaded_installer() {
  local url="$1"
  local interpreter="$2"
  local environment_assignment="${3:-}"
  local installer

  installer="$(curl -fsSL "$url")" || return
  if [[ -z "$installer" ]]; then
    setup_error "downloaded installer is empty: $url"
    return 1
  fi

  if [[ -n "$environment_assignment" ]]; then
    env "$environment_assignment" "$interpreter" <<<"$installer"
  else
    "$interpreter" <<<"$installer"
  fi
}

resolve_user_executable() {
  local name="$1"
  local candidate

  if candidate="$(command -v "$name" 2>/dev/null)"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if [[ -x "$HOME/.local/bin/$name" ]]; then
    printf '%s\n' "$HOME/.local/bin/$name"
    return 0
  fi

  return 1
}

install_user_cli() {
  local name="$1"
  local label="$2"
  local url="$3"
  local interpreter="$4"
  local environment_assignment="${5:-}"

  if resolve_user_executable "$name" >/dev/null; then
    return 0
  fi

  run_and_record \
    "$label" \
    run_downloaded_installer "$url" "$interpreter" "$environment_assignment"
}

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
      setup_error 'downloaded Homebrew installer is empty'
      return 1
    fi

    ensure_sudo || return
    env NONINTERACTIVE=1 /bin/bash <<<"$homebrew_installer" || return
    brew_executable="$(resolve_homebrew_executable || true)"
  fi

  if [[ -z "$brew_executable" ]]; then
    setup_error 'Homebrew executable was not found after installation'
    return 1
  fi

  homebrew_shellenv="$("$brew_executable" shellenv)" || return
  eval "$homebrew_shellenv"
}

setup_homebrew_and_bundle() {
  local brew_cellar
  local status

  if setup_homebrew; then
    :
  else
    status=$?
    record_failure 'Homebrew' "$status"
    record_skip 'brew bundle (Homebrew が使えないため)'
    return 0
  fi

  step 'brew bundle'
  # MDM などによる所有者変更で bundle が失敗する場合の案内
  brew_cellar="$("$brew_executable" --prefix)/Cellar"
  if [[ -d "$brew_cellar" && ! -w "$brew_cellar" ]]; then
    printf 'warning: %s is not writable\n' "$brew_cellar" >&2
    printf '         fix it with: sudo chown -R "%s" "%s"\n' \
      "$(id -un)" "$brew_cellar" >&2
  fi

  # Homebrew は起動時に sudo timestamp を無効化するため、認証も任せる
  run_and_record \
    'brew bundle' \
    "$brew_executable" bundle --no-upgrade --file="$repo_dir/macos/Brewfile"
}

setup_login_items() {
  local logi_options_app=/Applications/logioptionsplus.app
  local login_item_app

  # Logi Options+ はサービスで常駐するため、メインアプリの自動起動は不要
  run_and_record \
    "login item removed: $logi_options_app" \
    osascript - "$logi_options_app" <<'APPLESCRIPT'
on run argv
  set targetPath to item 1 of argv
  tell application "System Events"
    repeat with existingItem in every login item
      set existingPath to path of existingItem
      if existingPath is targetPath or existingPath is (targetPath & "/") then
        delete existingItem
      end if
    end repeat
  end tell
end run
APPLESCRIPT

  for login_item_app in \
    /Applications/Maccy.app \
    /Applications/Rectangle.app \
    /Applications/Typeless.app; do
    if [[ ! -d "$login_item_app" ]]; then
      record_skip "login item added: $login_item_app (アプリが見つからないため)"
      continue
    fi

    run_and_record \
      "login item added: $login_item_app" \
      osascript - "$login_item_app" <<'APPLESCRIPT'
on run argv
  set targetPath to item 1 of argv
  tell application "System Events"
    set existingPaths to path of every login item
    if existingPaths contains targetPath then return
    if existingPaths contains (targetPath & "/") then return
    make new login item at end with properties {path:targetPath, hidden:false}
  end tell
end run
APPLESCRIPT
  done
}

setup_mise_tools() {
  # mise install は設定なしでも成功するため、リンク失敗を先に検出
  local mise_config="${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml"

  if ! command -v mise >/dev/null 2>&1; then
    record_skip 'mise install (mise が使えないため)'
  elif [[ ! -r "$mise_config" ]]; then
    printf 'error: mise の設定が読めません: %s\n' "$mise_config" >&2
    printf '       scripts/link-dotfiles.sh が成功しているか確認してください\n' >&2
    record_failure 'mise install (設定が無い)' 1
  else
    run_and_record 'mise install' mise install
  fi
}

install_zsh_plugin() {
  local plugins_dir="$1"
  local name="$2"
  local url="$3"
  local entrypoint="$4"
  local target="$plugins_dir/$name"

  [[ -f "$target/$entrypoint" && -r "$target/$entrypoint" ]] && return 0

  if [[ -e "$target" || -L "$target" ]]; then
    printf 'error: incomplete zsh plugin: %s\n' "$target" >&2
    printf '       expected: %s\n' "$target/$entrypoint" >&2
    printf '       move or remove the directory, then rerun ./bootstrap.sh\n' >&2
    return 1
  fi

  setup_run_noninteractive_git clone --quiet -- "$url" "$target" || return
  if [[ ! -f "$target/$entrypoint" || ! -r "$target/$entrypoint" ]]; then
    setup_error "zsh plugin entrypoint was not installed: $target/$entrypoint"
    return 1
  fi
}

setup_zsh_plugins() {
  local plugins_dir="$HOME/.zsh/plugins"
  local status

  if mkdir -p "$plugins_dir"; then
    :
  else
    status=$?
    record_failure 'zsh plugins directory' "$status"
    return 0
  fi

  run_and_record \
    'zsh-autosuggestions' \
    install_zsh_plugin \
    "$plugins_dir" \
    zsh-autosuggestions \
    https://github.com/zsh-users/zsh-autosuggestions \
    zsh-autosuggestions.plugin.zsh
  run_and_record \
    'fast-syntax-highlighting' \
    install_zsh_plugin \
    "$plugins_dir" \
    fast-syntax-highlighting \
    https://github.com/zdharma-continuum/fast-syntax-highlighting.git \
    fast-syntax-highlighting.plugin.zsh
}

json_array_contains() {
  jq -e --arg value "$2" 'index($value) != null' <<<"$1" >/dev/null
}

list_claude_marketplaces() {
  "$1" plugin marketplace list --json |
    jq -ce '
      arrays // error("expected an array")
      | [.[] | objects | .name? | strings]
    '
}

list_claude_user_plugins() {
  "$1" plugin list --json |
    jq -ce '
      arrays // error("expected an array")
      | [.[] | objects | select(.scope == "user") | .id? | strings]
    '
}

# 公式 marketplace を登録。戻り値は 0=登録済み、1=登録不可、他=中断
ensure_claude_marketplace() {
  local executable="$1"
  local marketplaces="$2"
  local add_status=0
  local verify_status

  if json_array_contains "$marketplaces" claude-plugins-official; then
    return 0
  fi

  "$executable" plugin marketplace add \
    anthropics/claude-plugins-official --scope user || add_status=$?
  if ((add_status != 0)); then
    record_failure 'Claude Code marketplace: claude-plugins-official' "$add_status" || return
  fi

  if marketplaces="$(list_claude_marketplaces "$executable")" &&
    json_array_contains "$marketplaces" claude-plugins-official; then
    return 0
  else
    verify_status=$?
  fi

  # 追加失敗との重複記録を避ける
  if ((add_status == 0)); then
    record_failure 'Claude Code marketplace verification' "$verify_status" || return
  fi
  return 1
}

setup_claude_plugins() {
  local executable
  local marketplaces
  local plugins
  local plugin
  local marketplace_status
  local status

  if ! executable="$(resolve_user_executable claude)"; then
    record_skip 'Claude Code plugins (Claude Code が使えないため)'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    record_skip 'Claude Code plugins (jq が使えないため)'
    return 0
  fi

  if marketplaces="$(list_claude_marketplaces "$executable")"; then
    :
  else
    status=$?
    record_failure 'Claude Code marketplace list' "$status"
    record_skip 'Claude Code plugins (公式 marketplace を確認できないため)'
    return 0
  fi

  marketplace_status=0
  ensure_claude_marketplace "$executable" "$marketplaces" || marketplace_status=$?
  if ((marketplace_status != 0)); then
    # 中断は即時伝播
    ((marketplace_status == 1)) || return "$marketplace_status"
    record_skip 'Claude Code plugins (公式 marketplace を登録できないため)'
    return 0
  fi

  if plugins="$(list_claude_user_plugins "$executable")"; then
    :
  else
    status=$?
    record_failure 'Claude Code plugin list' "$status"
    return 0
  fi

  if json_array_contains "$plugins" context7@claude-plugins-official; then
    run_and_record \
      'Claude Code plugin removed: context7@claude-plugins-official' \
      "$executable" plugin uninstall context7@claude-plugins-official --scope user
  fi

  for plugin in \
    linear@claude-plugins-official \
    microsoft-docs@claude-plugins-official; do
    if json_array_contains "$plugins" "$plugin"; then
      continue
    fi

    run_and_record \
      "Claude Code plugin: $plugin" \
      "$executable" plugin install "$plugin" --scope user
  done
}

setup_codex_plugins() {
  local executable
  local plugins
  local status

  if ! executable="$(resolve_user_executable codex)"; then
    record_skip 'Codex plugins (Codex CLI が使えないため)'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    record_skip 'Codex plugins (jq が使えないため)'
    return 0
  fi

  if plugins="$(
    "$executable" plugin list --json |
      jq -ce '
        if type == "object" and (.installed | type == "array") then
          [.installed[] | objects | .pluginId? | strings]
        else
          error("expected an object with an installed array")
        end
      '
  )"; then
    :
  else
    status=$?
    record_failure 'Codex plugin list' "$status"
    return 0
  fi

  if json_array_contains "$plugins" linear@openai-curated; then
    return 0
  fi

  run_and_record \
    'Codex plugin: linear@openai-curated' \
    "$executable" plugin add linear@openai-curated
}

setup_private_overlay() {
  local overlay_dir
  local overlay_url
  local status=0

  if [[ "${DOTFILES_PRIVATE_SKIP:-0}" == 1 ]]; then
    record_skip 'dotfiles-private overlay (DOTFILES_PRIVATE_SKIP=1)'
    return 0
  fi

  # publish-lock の親が未作成の取得先にならないよう末尾の / を除く
  overlay_dir="$(setup_normalize_repository_dir \
    "${DOTFILES_PRIVATE_DIR:-$HOME/ghq/github.com/pych-ky/dotfiles-private}" \
    DOTFILES_PRIVATE_DIR)" || {
    record_failure 'dotfiles-private checkout' 1
    return 0
  }
  overlay_url="${DOTFILES_PRIVATE_REPO_URL:-https://github.com/pych-ky/dotfiles-private.git}"

  setup_ensure_private_checkout \
    "$overlay_dir" "$overlay_url" 'dotfiles-private' \
    DOTFILES_PRIVATE_DIR DOTFILES_PRIVATE_REPO_URL \
    setup.sh 'dotfiles-private setup.sh is missing or not executable' 0 || status=$?

  case "$status" in
  0) run_and_record 'dotfiles-private setup' "$overlay_dir/setup.sh" ;;
  3) record_skip 'dotfiles-private overlay (リポジトリへアクセスできないため)' ;;
  *) record_failure 'dotfiles-private checkout' 1 ;;
  esac
}

if ((EUID == 0)); then
  setup_error 'do not run bootstrap.sh with sudo or as root'
  exit 1
fi

if [[ "$(uname -s)" != Darwin ]]; then
  setup_error 'bootstrap.sh supports macOS only'
  exit 1
fi

setup_validate_home

step 'sudo'
# 認証中の終了でも sudo timestamp を無効化
trap 'sudo -k 2>/dev/null || true' EXIT
ensure_sudo

step 'macos/defaults.sh'
run_and_record 'macos/defaults.sh' "$repo_dir/macos/defaults.sh"

step 'Homebrew'
setup_homebrew_and_bundle

step 'scripts/link-dotfiles.sh'
run_and_record 'scripts/link-dotfiles.sh' "$repo_dir/scripts/link-dotfiles.sh"

# 以降は管理者権限が不要
sudo -k 2>/dev/null || true
trap - EXIT

step 'macos/setup-typeless.sh'
run_and_record 'macos/setup-typeless.sh' "$repo_dir/macos/setup-typeless.sh"

step 'login items'
setup_login_items

step 'mise install'
setup_mise_tools

step 'scripts/setup-git.sh'
run_and_record 'scripts/setup-git.sh' "$repo_dir/scripts/setup-git.sh"

step 'zsh plugins'
setup_zsh_plugins

step 'Claude Code'
install_user_cli claude 'Claude Code installer' https://claude.ai/install.sh /bin/bash
setup_claude_plugins

step 'Codex'
install_user_cli codex 'Codex installer' \
  https://chatgpt.com/codex/install.sh /bin/sh CODEX_NON_INTERACTIVE=1
setup_codex_plugins

step 'Codex Custom Pets'
run_and_record 'Codex Custom Pets' "$repo_dir/pets/setup.sh"

step 'Agent Skills'
run_and_record 'Agent Skills' "$repo_dir/skills/setup.sh"

step 'dotfiles-private overlay'
trap 'setup_cleanup_private_checkout' EXIT
setup_private_overlay

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

if ((${#skipped_steps[@]} > 0)); then
  printf 'bootstrap finished without failures, but some steps were skipped\n'
  printf 'satisfy their requirements and rerun ./bootstrap.sh to complete setup\n'
else
  printf 'all setup steps completed successfully\n'
fi
printf 'see README.md for remaining manual setup steps\n'
