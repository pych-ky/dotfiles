#!/usr/bin/env bash
# Codex App 共通権限の反映

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dry_run=0

case "${1:-}" in
--dry-run) dry_run=1 ;;
"") ;;
*)
  printf '使い方: ./scripts/setup-codex.sh [--dry-run]\n' >&2
  exit 2
  ;;
esac
if (($# > 1)); then
  printf '使い方: ./scripts/setup-codex.sh [--dry-run]\n' >&2
  exit 2
fi

setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

if ((EUID == 0)); then
  printf 'error: do not run scripts/setup-codex.sh with sudo or as root\n' >&2
  exit 1
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'error: scripts/setup-codex.sh supports macOS only\n' >&2
  exit 1
fi

setup_validate_home || exit 1

if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required\n' >&2
  exit 1
fi

settings_file="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
if [[ -L "$settings_file" || (-e "$settings_file" && ! -f "$settings_file") ]]; then
  printf 'error: Codex App state must be a regular file: %s\n' "$settings_file" >&2
  exit 1
fi
if [[ ! -f "$settings_file" ]]; then
  printf 'skipped: launch and quit ChatGPT once, then run scripts/setup-codex.sh\n'
  exit 3
fi

if ! jq -se 'length == 1 and (.[0] | type == "object")' "$settings_file" >/dev/null; then
  printf 'error: Codex App state must contain one JSON object\n' >&2
  exit 1
fi

settings_filter='
  .["electron-persisted-atom-state"]["agent-mode-by-host-id"].local = "custom" |
  .["electron-persisted-atom-state"]["config-derived-agent-mode-by-host-id"].local = null |
  .["electron-persisted-atom-state"]["permission-selection-by-host-id:local"] =
    {kind: "profile", profileId: "保護付きフルアクセス"}
'

# 一致すれば起動中でも書き換えずに終了
if jq -e ". == ($settings_filter)" "$settings_file" >/dev/null; then
  if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
    printf 'ok: Codex App permissions\n'
  fi
  exit 0
elif [[ $? != 1 ]]; then
  exit 1
fi

if ((dry_run)); then
  printf 'info: would update Codex App permissions: %s (custom / 保護付きフルアクセス)\n' "$settings_file"
  exit 0
fi

# アプリは起動時に読み込んだ状態を再保存するため、終了中だけ更新
process_status=0
pgrep -xq 'ChatGPT|Codex' || process_status=$?
case "$process_status" in
0)
  printf 'error: quit ChatGPT/Codex, then run scripts/setup-codex.sh again\n' >&2
  exit 1
  ;;
1) ;;
*)
  printf 'error: could not determine whether ChatGPT/Codex is running\n' >&2
  exit 1
  ;;
esac

temporary_settings="$(mktemp "$settings_file.XXXXXX")"
trap 'rm -f -- "$temporary_settings"' EXIT

# 他ホストの権限・既存タスク・未指定の状態を保持し、書き出し成功後に置換
jq "$settings_filter" "$settings_file" >"$temporary_settings"
mv -- "$temporary_settings" "$settings_file"
trap - EXIT
printf 'changed: updated Codex App permissions: %s\n' "$settings_file"
if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
  printf 'ok: Codex App permissions\n'
fi
