#!/usr/bin/env bash
# 新しい Mac の一括セットアップ

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

# ステップの結果を表示
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

# ステップを切り替え
step() {
  finish_step
  current_step="$1"
  step_failed_start=${#failed_steps[@]}
  step_skipped_start=${#skipped_steps[@]}
  printf '\n==> %s\n' "$1"
}

# 中断以外の失敗を記録して続行
record_failure() {
  local label="$1"
  local status="$2"

  if ((status == 130 || status == 143)); then
    return "$status"
  fi

  failed_steps+=("$label (exit $status)")
  printf 'error: %s (exit %d); continuing\n' "$label" "$status" >&2
}

# スキップを記録・表示
record_skip() {
  local reason="$1"

  skipped_steps+=("$reason")
  printf 'skipped: %s\n' "$reason"
}

# 任意の setup を実行（終了コード 3 はスキップ）
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

# コマンドの失敗を記録して続行
run_and_record() {
  local label="$1"
  shift

  "$@" || record_failure "$label" "$?"
}

# 必要なら端末で sudo 認証
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

# インストーラーを取得・実行
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

# PATH・~/.local/bin から実行ファイルを検索
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

# 未導入の CLI を公式配布から導入
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

# PATH・既定パスから brew を検索
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

# Homebrew を導入・有効化
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

# Homebrew と Brewfile のパッケージを導入
setup_homebrew_and_bundle() {
  local brew_cellar

  setup_homebrew || {
    record_failure 'Homebrew' "$?"
    record_skip 'Homebrew packages (Homebrew is unavailable)'
    return 0
  }

  step 'Homebrew packages'
  brew_cellar="$("$brew_executable" --prefix)/Cellar"
  if [[ -d "$brew_cellar" && ! -w "$brew_cellar" ]]; then
    printf 'warning: %s is not writable\n' "$brew_cellar" >&2
    printf '         fix it with: sudo chown -R "%s" "%s"\n' \
      "$(id -un)" "$brew_cellar" >&2
  fi

  # Homebrew が sudo timestamp を無効化するため、再認証も任せる
  run_and_record \
    'Homebrew packages' \
    env HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 \
    "$brew_executable" bundle --quiet --no-upgrade --file="$repo_dir/macos/Brewfile"
}

# ログイン項目を設定
setup_login_items() {
  local logi_options_app=/Applications/logioptionsplus.app
  local login_item_app
  local system_events_status=0

  # 起動直後の -600 だけ再試行
  osascript <<'APPLESCRIPT' || system_events_status=$?
repeat with attempt from 1 to 3
  try
    tell application "System Events"
      launch
      count login items
    end tell
    exit repeat
  on error errorMessage number errorNumber
    if errorNumber is not -600 or attempt is 3 then error errorMessage number errorNumber
    delay 0.5
  end try
end repeat
APPLESCRIPT
  if ((system_events_status != 0)); then
    record_failure 'launch System Events' "$system_events_status" || return
    return 0
  fi

  # Logi Options+ はサービスで常駐するため、メインアプリの自動起動は不要
  run_and_record \
    "remove login item: $logi_options_app" \
    osascript - "$logi_options_app" <<'APPLESCRIPT'
-- 対象アプリのログイン項目を削除
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
-- 未登録のアプリをログイン項目に追加
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

# mise で開発ツールを導入
setup_mise_tools() {
  # mise install は設定なしでも成功するため事前検証
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

# 未導入の Zsh プラグインを取得
install_zsh_plugin() {
  local plugins_dir="$1"
  local name="$2"
  local url="$3"
  local entrypoint="$name.plugin.zsh"
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

# Zsh プラグインを導入
setup_zsh_plugins() {
  local plugins_dir="$HOME/.zsh/plugins"

  mkdir -p "$plugins_dir" || {
    record_failure 'zsh plugins directory' "$?"
    return 0
  }

  local plugin name
  for plugin in \
    'zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions' \
    'fast-syntax-highlighting https://github.com/zdharma-continuum/fast-syntax-highlighting.git'; do
    name="${plugin%% *}"
    run_and_record "$name" install_zsh_plugin "$plugins_dir" "$name" "${plugin#* }"
  done
}

# Codex に Linear プラグインを導入
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

  plugins="$(
    "$executable" plugin list --json |
      jq -ce '
        if type == "object" and (.installed | type == "array") then
          [.installed[] | objects | .pluginId? | strings]
        else
          error("expected an object with an installed array")
        end
      '
  )" || {
    record_failure 'Codex plugin list' "$?"
    return 0
  }

  if jq -e 'index("linear@openai-curated-remote") != null' <<<"$plugins" >/dev/null; then
    return 0
  fi

  if install_output="$("$executable" plugin add --json linear@openai-curated-remote)"; then
    return 0
  else
    status=$?
    [[ -z "$install_output" ]] || printf '%s\n' "$install_output" >&2
    record_failure 'Codex plugin: linear@openai-curated-remote' "$status"
  fi
}

# 非公開設定を取得・適用
setup_private_overlay() {
  local overlay_dir
  local overlay_url
  local status=0

  if [[ "${DOTFILES_PRIVATE_SKIP:-0}" == 1 ]]; then
    record_skip 'Private settings (DOTFILES_PRIVATE_SKIP=1)'
    return 0
  fi

  # publish-lock が未作成の取得先に入らないよう末尾の / を除く
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
# 認証中の終了時も sudo timestamp を破棄
trap 'sudo -k 2>/dev/null || true' EXIT
ensure_sudo

step 'macOS settings'
run_and_record 'macOS settings' "$repo_dir/scripts/setup-macos.sh"

step 'Homebrew'
setup_homebrew_and_bundle

step 'Configuration'
run_and_record 'Configuration files' "$repo_dir/scripts/link-dotfiles.sh"

sudo -k 2>/dev/null || true
trap - EXIT

run_and_record 'Git settings' "$repo_dir/scripts/setup-git.sh"
run_and_record 'Typeless settings' "$repo_dir/scripts/setup-typeless.sh"
run_optional_setup 'Orca settings' "$repo_dir/scripts/setup-orca.sh"
run_and_record 'Menu bar settings' "$repo_dir/scripts/setup-menubar.sh"

step 'Zsh plugins'
setup_zsh_plugins

step 'Development tools'
setup_mise_tools

step 'Claude Code'
install_user_cli claude 'Claude Code installer' https://claude.ai/install.sh /bin/bash

step 'Codex'
install_user_cli codex 'Codex installer' \
  https://chatgpt.com/codex/install.sh /bin/sh CODEX_NON_INTERACTIVE=1
setup_codex_plugins

step 'Codex pets'
run_optional_setup 'Codex pets' "$repo_dir/scripts/setup-pets.sh"

step 'Agent Skills'
run_optional_setup 'Agent Skills' "$repo_dir/scripts/setup-skills.sh"

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
