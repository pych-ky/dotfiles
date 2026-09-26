#!/usr/bin/env bash
# 選択中のプロファイルへ Orca の共通設定だけを反映

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

if ((EUID == 0)); then
  printf 'error: do not run macos/setup-orca.sh with sudo or as root\n' >&2
  exit 1
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'error: macos/setup-orca.sh supports macOS only\n' >&2
  exit 1
fi

setup_validate_home || exit 1

if [[ ! -d /Applications/Orca.app && ! -d "$HOME/Applications/Orca.app" ]]; then
  printf 'skipped: Orca is not installed\n'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required\n' >&2
  exit 1
fi

data_dir="$HOME/Library/Application Support/orca"
profile_index="$data_dir/orca-profile-index.json"
managed_settings="$repo_dir/.orca/settings.json"

if [[ ! -f "$profile_index" ]]; then
  printf 'skipped: launch and quit Orca once, then run macos/setup-orca.sh\n'
  exit 0
fi

profile_id="$(jq -er '.activeProfileId | strings | select(test("^[A-Za-z0-9_-]+$"))' "$profile_index")"
settings_file="$data_dir/profiles/$profile_id/orca-data.json"
if [[ -L "$settings_file" || ! -f "$settings_file" ]]; then
  printf 'error: Orca profile data must be an existing regular file: %s\n' "$settings_file" >&2
  exit 1
fi

jq -e 'type == "object"' "$managed_settings" >/dev/null
jq -e '.settings | type == "object"' "$settings_file" >/dev/null

# エージェントごとの環境は空オブジェクトも明示的な設定として置換
settings_filter=".settings *= \$managed[0] | .settings.agentDefaultEnv += \$managed[0].agentDefaultEnv"

# 一致すれば起動中でも書き換えずに終了
if jq -e --slurpfile managed "$managed_settings" \
  ". == ($settings_filter)" "$settings_file" >/dev/null; then
  if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
    printf 'ok: Orca settings\n'
  fi
  exit 0
fi

process_status=0
pgrep -xq Orca || process_status=$?
case "$process_status" in
0)
  printf 'error: quit Orca, then run macos/setup-orca.sh again\n' >&2
  exit 1
  ;;
1) ;;
*)
  printf 'error: could not determine whether Orca is running\n' >&2
  exit 1
  ;;
esac

temporary_settings="$(mktemp "$settings_file.XXXXXX")"
trap 'rm -f -- "$temporary_settings"' EXIT

# 未指定の設定・アカウント・作業状態を保持
jq --slurpfile managed "$managed_settings" \
  "$settings_filter" "$settings_file" >"$temporary_settings"
mv -- "$temporary_settings" "$settings_file"
trap - EXIT
printf 'changed: updated Orca settings: %s\n' "$settings_file"
if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
  printf 'ok: Orca settings\n'
fi
