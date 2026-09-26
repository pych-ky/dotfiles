#!/usr/bin/env bash
# 新しい Mac を一括セットアップ

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed_steps=()
skipped_steps=()
current_step=
step_failed_start=0
step_skipped_start=0

setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' \
    "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

finish_step() {
  [[ -n "$current_step" ]] || return 0

  local failed_count=$((${#failed_steps[@]} - step_failed_start))
  local skipped_count=$((${#skipped_steps[@]} - step_skipped_start))
  if ((failed_count > 0)); then
    printf 'error: %s (%d failed, %d skipped)\n' "$current_step" "$failed_count" "$skipped_count" >&2
  elif ((skipped_count > 0)); then
    printf 'skipped: %s (%d skipped)\n' "$current_step" "$skipped_count"
  else
    printf 'ok: %s\n' "$current_step"
  fi
  current_step=
}

step() {
  finish_step
  current_step="$1"
  step_failed_start=${#failed_steps[@]}
  step_skipped_start=${#skipped_steps[@]}
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
  printf 'error: %s (exit %d); continuing\n' "$label" "$status" >&2
}

record_skip() {
  local reason="$1"

  skipped_steps+=("$reason")
  printf 'skipped: %s\n' "$reason"
}

# 任意リポジトリの setup は、bootstrap 中の未実施を終了コード 3 で伝える。
run_optional_setup() {
  local label="$1"
  shift
  local status=0

  "$@" || status=$?
  case "$status" in
  0) ;;
  3) skipped_steps+=("$label (see reason above)") ;;
  *) record_failure "$label" "$status" ;;
  esac
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
    record_skip 'Homebrew packages (Homebrew is unavailable)'
    return 0
  fi

  step 'Homebrew packages'
  # MDM などによる所有者変更で bundle が失敗する場合の案内
  brew_cellar="$("$brew_executable" --prefix)/Cellar"
  if [[ -d "$brew_cellar" && ! -w "$brew_cellar" ]]; then
    printf 'warning: %s is not writable\n' "$brew_cellar" >&2
    printf '         fix it with: sudo chown -R "%s" "%s"\n' \
      "$(id -un)" "$brew_cellar" >&2
  fi

  # Homebrew は起動時に sudo timestamp を無効化するため、認証も任せる
  run_and_record \
    'Homebrew packages' \
    "$brew_executable" bundle --quiet --no-upgrade --file="$repo_dir/macos/Brewfile"
}

setup_login_items() {
  local logi_options_app=/Applications/logioptionsplus.app
  local login_item_app

  # Logi Options+ はサービスで常駐するため、メインアプリの自動起動は不要
  run_and_record \
    "remove login item: $logi_options_app" \
    osascript - "$logi_options_app" <<'APPLESCRIPT'
on run argv
  set targetPath to item 1 of argv
  set removedItem to false
  tell application "System Events"
    repeat with existingItem in every login item
      set existingPath to path of existingItem
      if existingPath is targetPath or existingPath is (targetPath & "/") then
        delete existingItem
        set removedItem to true
      end if
    end repeat
  end tell
  if removedItem then return "changed: removed login item: " & targetPath
end run
APPLESCRIPT

  for login_item_app in \
    /Applications/Maccy.app \
    /Applications/Rectangle.app \
    /Applications/Typeless.app; do
    if [[ ! -d "$login_item_app" ]]; then
      record_skip "add login item: $login_item_app (application is missing)"
      continue
    fi

    run_and_record \
      "add login item: $login_item_app" \
      osascript - "$login_item_app" <<'APPLESCRIPT'
on run argv
  set targetPath to item 1 of argv
  tell application "System Events"
    set existingPaths to path of every login item
    if existingPaths contains targetPath then return
    if existingPaths contains (targetPath & "/") then return
    make new login item at end with properties {path:targetPath, hidden:false}
  end tell
  return "changed: added login item: " & targetPath
end run
APPLESCRIPT
  done
}

setup_mise_tools() {
  # mise install は設定なしでも成功するため、リンク失敗を先に検出
  local mise_config="${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml"

  if ! command -v mise >/dev/null 2>&1; then
    record_skip 'Development tools (mise is unavailable)'
  elif [[ ! -r "$mise_config" ]]; then
    printf 'error: mise configuration is not readable: %s\n' "$mise_config" >&2
    printf '       check that scripts/link-dotfiles.sh completed successfully\n' >&2
    record_failure 'Development tools (missing mise configuration)' 1
  else
    run_and_record 'Development tools' mise install
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
  printf 'changed: installed Zsh plugin: %s\n' "$name"
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
    record_skip 'Claude Code plugins (Claude Code is unavailable)'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    record_skip 'Claude Code plugins (jq is unavailable)'
    return 0
  fi

  if marketplaces="$(list_claude_marketplaces "$executable")"; then
    :
  else
    status=$?
    record_failure 'Claude Code marketplace list' "$status"
    record_skip 'Claude Code plugins (official marketplace could not be inspected)'
    return 0
  fi

  marketplace_status=0
  ensure_claude_marketplace "$executable" "$marketplaces" || marketplace_status=$?
  if ((marketplace_status != 0)); then
    # 中断は即時伝播
    ((marketplace_status == 1)) || return "$marketplace_status"
    record_skip 'Claude Code plugins (official marketplace could not be registered)'
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
      'remove Claude Code plugin: context7@claude-plugins-official' \
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
  local install_output
  local status

  if ! executable="$(resolve_user_executable codex)"; then
    record_skip 'Codex plugins (Codex CLI is unavailable)'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    record_skip 'Codex plugins (jq is unavailable)'
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

  if install_output="$("$executable" plugin add --json linear@openai-curated)"; then
    return 0
  else
    status=$?
    [[ -z "$install_output" ]] || printf '%s\n' "$install_output" >&2
    record_failure 'Codex plugin: linear@openai-curated' "$status"
  fi
}

setup_private_overlay() {
  local overlay_dir
  local overlay_url
  local status=0

  if [[ "${DOTFILES_PRIVATE_SKIP:-0}" == 1 ]]; then
    record_skip 'Private settings (DOTFILES_PRIVATE_SKIP=1)'
    return 0
  fi

  # publish-lock の親が未作成の取得先にならないよう末尾の / を除く
  overlay_dir="$(setup_normalize_repository_dir \
    "${DOTFILES_PRIVATE_DIR:-$HOME/ghq/github.com/pych-ky/dotfiles-private}" \
    DOTFILES_PRIVATE_DIR)" || {
    record_failure 'Private settings checkout' 1
    return 0
  }
  overlay_url="${DOTFILES_PRIVATE_REPO_URL:-https://github.com/pych-ky/dotfiles-private.git}"

  setup_ensure_private_checkout \
    "$overlay_dir" "$overlay_url" 'Private settings' \
    DOTFILES_PRIVATE_DIR DOTFILES_PRIVATE_REPO_URL \
    setup.sh 'dotfiles-private setup.sh is missing or not executable' 0 || status=$?

  case "$status" in
  0) run_and_record 'Private settings' "$overlay_dir/setup.sh" ;;
  3) skipped_steps+=('Private settings (repository is inaccessible)') ;;
  *) record_failure 'Private settings checkout' 1 ;;
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
export DOTFILES_BOOTSTRAP=1

step 'Administrator access'
# 認証中の終了でも sudo timestamp を無効化
trap 'sudo -k 2>/dev/null || true' EXIT
ensure_sudo

step 'macOS settings'
run_and_record 'macOS settings' "$repo_dir/macos/defaults.sh"

step 'Homebrew'
setup_homebrew_and_bundle

step 'Configuration'
run_and_record 'Configuration files' "$repo_dir/scripts/link-dotfiles.sh"

# 以降は管理者権限が不要
sudo -k 2>/dev/null || true
trap - EXIT

run_and_record 'Git settings' "$repo_dir/scripts/setup-git.sh"
run_and_record 'Typeless settings' "$repo_dir/macos/setup-typeless.sh"
run_and_record 'Orca settings' "$repo_dir/macos/setup-orca.sh"

step 'Zsh plugins'
setup_zsh_plugins

step 'Development tools'
setup_mise_tools

step 'Claude Code'
install_user_cli claude 'Claude Code installer' https://claude.ai/install.sh /bin/bash
setup_claude_plugins

step 'Codex'
install_user_cli codex 'Codex installer' \
  https://chatgpt.com/codex/install.sh /bin/sh CODEX_NON_INTERACTIVE=1
setup_codex_plugins

step 'Codex pets'
run_optional_setup 'Codex pets' "$repo_dir/pets/setup.sh"

step 'Agent Skills'
run_optional_setup 'Agent Skills' "$repo_dir/skills/setup.sh"

step 'Private settings'
trap 'setup_cleanup_private_checkout' EXIT
setup_private_overlay

step 'Login items'
setup_login_items

finish_step
printf '\n==> Summary\n'
if ((${#skipped_steps[@]} > 0)); then
  printf 'skipped: tasks not executed:\n'
  printf '  - %s\n' "${skipped_steps[@]}"
fi

if ((${#failed_steps[@]} > 0)); then
  printf 'error: bootstrap completed with failed tasks:\n' >&2
  printf '  - %s\n' "${failed_steps[@]}" >&2
  printf 'info: fix the failures and rerun ./bootstrap.sh\n' >&2
  exit 1
fi

if ((${#skipped_steps[@]} > 0)); then
  printf 'skipped: bootstrap completed with unexecuted tasks\n'
  printf 'info: rerun ./bootstrap.sh if you want to complete the skipped tasks\n'
else
  printf 'ok: bootstrap completed\n'
fi
