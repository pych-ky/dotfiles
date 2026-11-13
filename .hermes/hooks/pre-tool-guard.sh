#!/usr/bin/env bash
# Hermes のツール実行前ガードの起動

# 作業場所の mise 設定に依存せず Python を選択
python="$(mise -C "$HOME" which python3 2>/dev/null)" || python=python3

"$python" -I "$(dirname "${BASH_SOURCE[0]}")/pre-tool-guard.py" || exit 2
