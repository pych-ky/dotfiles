#!/usr/bin/env bash
# Hermes のツール実行前ガードの起動

set -u

# リンク解決後のディレクトリ
script_dir() {
  local source="${BASH_SOURCE[0]}"
  local directory target

  while [[ -L "$source" ]]; do
    directory="$(cd -P "$(dirname "$source")" && pwd)"
    target="$(readlink "$source")"
    if [[ "$target" == /* ]]; then
      source="$target"
    else
      source="$directory/$target"
    fi
  done
  cd -P "$(dirname "$source")" && pwd
}

scanner="$(script_dir)/pre-tool-guard.py"

# 作業場所の mise 設定に依存せず Python を選択
python="$(mise -C "$HOME" which python3 2>/dev/null)" || python=python3
command -v "$python" >/dev/null 2>&1 || {
  printf 'pre-tool-guard.sh: python3 is required but not installed\n' >&2
  exit 2
}
[[ -f "$scanner" && ! -L "$scanner" ]] || {
  printf 'pre-tool-guard.sh: scanner is missing or unsafe\n' >&2
  exit 2
}

"$python" -I "$scanner" "$@" || {
  scanner_status=$?
  if ((scanner_status != 2)); then
    printf 'pre-tool-guard.sh: scanner failed with status %s\n' \
      "$scanner_status" >&2
  fi
  exit 2
}
