#!/usr/bin/env bash
# Typeless 共通設定の反映

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
managed_settings="$repo_dir/macos/typeless.json"
settings_file="$HOME/Library/Application Support/Typeless/app-settings.json"

if [[ -f "$settings_file" ]] &&
  jq -e --slurpfile managed "$managed_settings" \
    '. == (. * $managed[0])' "$settings_file" >/dev/null; then
  if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
    printf 'ok: Typeless settings\n'
  fi
  exit 0
fi

if pgrep -xq Typeless; then
  printf 'error: quit Typeless, then run scripts/setup-typeless.sh again\n' >&2
  exit 1
fi

mkdir -p "$(dirname "$settings_file")"
temporary_settings="$(mktemp "$settings_file.XXXXXX")"
trap 'rm -f -- "$temporary_settings"' EXIT

if [[ -f "$settings_file" ]]; then
  jq -s '.[0] * .[1]' "$settings_file" "$managed_settings" >"$temporary_settings"
else
  jq . "$managed_settings" >"$temporary_settings"
fi

mv -- "$temporary_settings" "$settings_file"
printf 'changed: updated Typeless settings: %s\n' "$settings_file"
if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
  printf 'ok: Typeless settings\n'
fi
