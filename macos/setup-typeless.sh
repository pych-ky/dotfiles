#!/usr/bin/env bash
# Typeless の共通設定だけを既存のユーザー設定へ反映する。

set -euo pipefail

if ((EUID == 0)); then
  printf 'error: do not run macos/setup-typeless.sh with sudo or as root\n' >&2
  exit 1
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'error: macos/setup-typeless.sh supports macOS only\n' >&2
  exit 1
fi

if [[ "${HOME:-}" != /* || "$HOME" == / || ! -d "$HOME" ]]; then
  printf 'error: HOME must be an existing absolute directory other than /\n' >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required\n' >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
managed_settings="$script_dir/typeless.json"
settings_file="$HOME/Library/Application Support/Typeless/app-settings.json"

if [[ -L "$settings_file" || (-e "$settings_file" && ! -f "$settings_file") ]]; then
  printf 'error: Typeless settings must be a regular file\n' >&2
  exit 1
fi

# 次回起動時の旧設定移行で管理ショートカットが上書きされるのを防ぐ
if [[ -f "$settings_file" ]] &&
  jq -e '
    (.__COMPATIBLE_FEATURE_SHORTCUT_BINDINGS_MIGRATED_FLAG | IN(null, false, 0, "")) and
    (.keyboardShortcut | IN(null, false, 0, "") | not)
  ' "$settings_file" >/dev/null; then
  printf 'error: launch and quit Typeless to migrate legacy shortcuts, then run macos/setup-typeless.sh again\n' >&2
  exit 1
fi

# 一致する場合は起動中でも設定を書き換えない
if [[ -f "$settings_file" ]] &&
  jq -e --slurpfile managed "$managed_settings" \
    '. == (. * $managed[0])' "$settings_file" >/dev/null; then
  printf 'Typeless settings are already up to date\n'
  exit 0
fi

if pgrep -xq Typeless; then
  printf 'error: quit Typeless, then run macos/setup-typeless.sh again\n' >&2
  exit 1
fi

mkdir -p "$(dirname "$settings_file")"
temporary_settings="$(mktemp "$settings_file.XXXXXX")"
trap 'rm -f -- "$temporary_settings"' EXIT

# 未指定の設定を保持し、書き出しに成功してから置き換える
if [[ -f "$settings_file" ]]; then
  jq -s '
    if length == 2 and all(.[]; type == "object") then
      .[0] * .[1]
    else
      error("Typeless settings must contain one JSON object per file")
    end
  ' "$settings_file" "$managed_settings" >"$temporary_settings"
else
  jq . "$managed_settings" >"$temporary_settings"
fi

mv -- "$temporary_settings" "$settings_file"
trap - EXIT
printf 'Typeless settings updated\n'
