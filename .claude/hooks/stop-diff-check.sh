#!/usr/bin/env bash
# エージェント終了時の不要差分検査の起動

# 作業場所の mise 設定に依存せず Python を選択
python="$(mise -C "$HOME" which python3 2>/dev/null)" || python=python3

"$python" -I "$(dirname "${BASH_SOURCE[0]}")/stop-diff-check.py" || exit 0
