#!/usr/bin/env bash
# 新しい Mac の一括セットアップ

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed_steps=()
skipped_steps=()
current_step=
step_failed_start=0
step_skipped_start=0

# shellcheck source=lib/setup-common.sh
source "$repo_dir/lib/setup-common.sh"

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

# インストーラーを取得し、指定コマンドの標準入力へ渡す
# 取得が途中で切れた内容を実行しないよう、全体を取得してから渡す
run_downloaded_installer() {
  local url="$1"
  local installer

  shift
  installer="$(curl -fsSL "$url")" || return
  "$@" <<<"$installer"
}

# 未導入の CLI を公式配布から導入
install_user_cli() {
  local name="$1"
  local label="$2"

  shift 2
  command -v "$name" >/dev/null 2>&1 || run_and_record "$label" run_downloaded_installer "$@"
}

# Homebrew を導入・有効化
setup_homebrew() {
  local homebrew_shellenv

  if [[ ! -x /opt/homebrew/bin/brew ]]; then
    sudo -v || return
    run_downloaded_installer https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
      env NONINTERACTIVE=1 /bin/bash || return
  fi

  homebrew_shellenv="$(/opt/homebrew/bin/brew shellenv)" || return
  eval "$homebrew_shellenv"
}

# Homebrew と Brewfile のパッケージを導入
setup_homebrew_and_bundle() {
  setup_homebrew || {
    record_failure 'Homebrew' "$?"
    record_skip 'Homebrew packages (Homebrew is unavailable)'
    return 0
  }

  step 'Homebrew packages'
  run_and_record 'Homebrew packages' \
    brew bundle --quiet --no-upgrade --file="$repo_dir/macos/Brewfile"
}

# ログイン項目を設定
setup_login_items() {
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

  # サービス常駐アプリと休止中の Typeless はログイン項目から外す
  for login_item_app in \
    /Applications/logioptionsplus.app \
    /Applications/Typeless.app; do
    run_and_record \
      "remove login item: $login_item_app" \
      osascript - "$login_item_app" <<'APPLESCRIPT'
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
  done

  for login_item_app in \
    "/Applications/Aqua Voice.app" \
    /Applications/Maccy.app \
    /Applications/noTunes.app \
    /Applications/Raycast.app \
    /Applications/Rectangle.app; do
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

# 未導入の Zsh プラグインを取得
install_zsh_plugin() {
  local target="$HOME/.zsh/plugins/$1"

  [[ ! -e "$target" ]] || return 0
  setup_run_noninteractive_git clone --quiet -- "$2" "$target" || return
  printf 'changed: installed Zsh plugin: %s\n' "$1"
}

# Codex に Linear プラグインを導入
setup_codex_plugins() {
  local plugins
  local install_output
  local status

  # codex plugin は全プラグインの一覧の取り直しで1分以上かかることがあるため、導入済みは保存先の版フォルダで判定する
  ! compgen -G "${CODEX_HOME:-$HOME/.codex}/plugins/cache/openai-curated-remote/linear/*/" >/dev/null || return 0

  plugins="$(codex plugin list --json)" || {
    record_failure 'Codex plugin list' "$?"
    return 0
  }
  if jq -e '.installed | any(.pluginId == "linear@openai-curated-remote")' <<<"$plugins" >/dev/null; then
    return 0
  fi

  if install_output="$(codex plugin add --json linear@openai-curated-remote)"; then
    return 0
  else
    status=$?
    [[ -z "$install_output" ]] || printf '%s\n' "$install_output" >&2
    record_failure 'Codex plugin: linear@openai-curated-remote' "$status"
  fi
}

# 非公開設定を取得・適用
setup_private_overlay() {
  local overlay_dir="$HOME/ghq/github.com/pych-ky/dotfiles-private"
  local status=0

  setup_ensure_private_checkout "$overlay_dir" \
    https://github.com/pych-ky/dotfiles-private.git 'Private settings' || status=$?
  case "$status" in
  0) run_and_record 'Private settings' "$overlay_dir/setup.sh" ;;
  3) skipped_steps+=('Private settings (repository is inaccessible)') ;;
  *) record_failure 'Private settings checkout' "$status" ;;
  esac
}

# sudo 付きで実行すると HOME に root 所有のファイルができる
if ((EUID == 0)); then
  printf 'error: do not run bootstrap.sh with sudo or as root\n' >&2
  exit 1
fi

export DOTFILES_BOOTSTRAP=1
# 公式インストーラーの導入先
export PATH="$HOME/.local/bin:$PATH"

step 'Administrator access'
# 認証中の終了時も sudo timestamp を破棄
trap 'sudo -k 2>/dev/null || true' EXIT
sudo -v

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
run_and_record zsh-autosuggestions install_zsh_plugin \
  zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions
run_and_record fast-syntax-highlighting install_zsh_plugin \
  fast-syntax-highlighting https://github.com/zdharma-continuum/fast-syntax-highlighting.git

step 'Development tools'
run_and_record 'Development tools' mise install

step 'Claude Code'
install_user_cli claude 'Claude Code installer' \
  https://claude.ai/install.sh /bin/bash -s --

step 'Codex'
install_user_cli codex 'Codex installer' \
  https://chatgpt.com/codex/install.sh env CODEX_NON_INTERACTIVE=1 /bin/sh -s --
run_and_record 'Codex settings' "$repo_dir/scripts/setup-codex.sh"
setup_codex_plugins

step 'Hermes Agent'
install_user_cli hermes 'Hermes Agent installer' \
  https://hermes-agent.nousresearch.com/install.sh /bin/bash -s -- --non-interactive
run_and_record 'Hermes settings' "$repo_dir/scripts/setup-hermes.sh"

step 'Codex pets'
run_optional_setup 'Codex pets' "$repo_dir/scripts/setup-pets.sh"

step 'Agent Skills'
run_optional_setup 'Agent Skills' "$repo_dir/scripts/setup-skills.sh"

step 'Private settings'
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
