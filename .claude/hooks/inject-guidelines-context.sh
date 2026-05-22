#!/usr/bin/env bash
#
# ============================================================================
# AGENTS.md と Cursor ルールを追加コンテキストとして注入する UserPromptSubmit フックスクリプト
# ============================================================================

set -euo pipefail

# print_file の出力を一時ファイルへ集約するため stdout を fd 4 に退避
context_file="$(mktemp)"
exec 4>&1
exec 1>"$context_file"
trap 'exec 1>&4; rm -f "$context_file"' EXIT

# CLI 実行時は CLAUDE_PROJECT_DIR が無いので $PWD にフォールバック
project_root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
agents_file="${AGENTS_GLOBAL_FILE:-$HOME/.config/agents/AGENTS.md}"
rules_dir="$project_root/.cursor/rules"

# ファイル先頭にパス見出しを付けて中身を出力、読めなければ黙って無視
print_file() {
  local file_path=$1
  [[ -r "$file_path" ]] || return 0

  local relative_path=${file_path#"$project_root"/}
  printf '===== %s =====\n' "${relative_path:-$file_path}"
  cat -- "$file_path"
  printf '\n'
}

# Cursor ルールを列挙、one-platform は粒度が大きいため overview / *_guidelines のみに限定
find_rule_files() {
  [[ -d "$rules_dir" ]] || return 0

  if [[ "$(basename "$project_root")" == "one-platform" ]]; then
    find "$rules_dir" -type f \( -name 'overview.mdc' -o -name '*_guidelines.mdc' \) -print0 2>/dev/null
  else
    find "$rules_dir" -type f -name '*.mdc' -print0 2>/dev/null
  fi
}

if [[ -r "$agents_file" ]]; then
  print_file "$agents_file"
fi

# NUL 区切りで読むことでパスにスペースや改行を含むケースに対応
while IFS= read -r -d '' file; do
  print_file "$file"
done < <(find_rule_files)

exec 1>&4

# Claude Code 経由のパイプなら JSON、手動実行の端末なら生テキストで返却
if [ ! -t 1 ]; then
  python3 - "$context_file" <<'PYTHON'
import sys, json, io
context_file = sys.argv[1]
with io.open(context_file, 'r', encoding='utf-8', errors='ignore') as f:
    context = f.read()
if context.strip():
    print(json.dumps({
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": context
        }
    }))
PYTHON
else
  cat "$context_file"
fi
