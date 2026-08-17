#!/usr/bin/env bash
#
# ============================================================================
# AGENTS.md を注入する UserPromptSubmit フックスクリプト
# ============================================================================

set -euo pipefail

# CLI 実行時は CLAUDE_PROJECT_DIR が無いので $PWD にフォールバック
project_root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
agents_file="${AGENTS_GLOBAL_FILE:-$HOME/.config/agents/AGENTS.md}"

# ファイル先頭にパス見出しを付けて中身を出力、読めなければ黙って無視
print_file() {
  local file_path=$1
  [[ -r "$file_path" ]] || return 0

  local relative_path=${file_path#"$project_root"/}
  printf '===== %s =====\n' "${relative_path:-$file_path}"
  cat -- "$file_path"
  printf '\n'
}

# 注入するコンテキストを一時ファイルへ集約
context_file="$(mktemp)"
trap 'rm -f "$context_file"' EXIT

print_file "$agents_file" >"$context_file"

# Claude Code 経由のパイプなら JSON、手動実行の端末なら生テキストで返却
if [ -t 1 ]; then
  cat "$context_file"
elif grep -q '[^[:space:]]' "$context_file"; then
  if command -v jq >/dev/null 2>&1; then
    jq -n --rawfile context "$context_file" '{
      suppressOutput: true,
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $context
      }
    }'
  else
    # jq が無ければ生テキストで返却
    cat "$context_file"
  fi
fi
