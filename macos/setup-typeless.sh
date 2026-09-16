#!/usr/bin/env bash
# Typeless の既存設定に共通設定を反映

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' \
    "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

if ((EUID == 0)); then
  printf 'error: do not run macos/setup-typeless.sh with sudo or as root\n' >&2
  exit 1
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'error: macos/setup-typeless.sh supports macOS only\n' >&2
  exit 1
fi

setup_validate_home || exit 1

if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required\n' >&2
  exit 1
fi

managed_settings="$script_dir/typeless.json"
settings_file="$HOME/Library/Application Support/Typeless/app-settings.json"

if [[ -L "$settings_file" || (-e "$settings_file" && ! -f "$settings_file") ]]; then
  printf 'error: Typeless settings must be a regular file\n' >&2
  exit 1
fi

# 次回の旧設定移行による管理ショートカットの上書きを防ぐ
if [[ -f "$settings_file" ]] &&
  jq -e '
    (.__COMPATIBLE_FEATURE_SHORTCUT_BINDINGS_MIGRATED_FLAG | IN(null, false, 0, "")) and
    (.keyboardShortcut | IN(null, false, 0, "") | not)
  ' "$settings_file" >/dev/null; then
  printf 'error: launch and quit Typeless to migrate legacy shortcuts, then run macos/setup-typeless.sh again\n' >&2
  exit 1
fi

# 一致すれば起動中でも終了不要
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

# 未指定の設定を保持し、書き出し成功後に置換
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
