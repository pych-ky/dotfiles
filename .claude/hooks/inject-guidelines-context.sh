#!/usr/bin/env bash
#
# ============================================================================
# AGENTS.md と Cursor ルールを注入する UserPromptSubmit フックスクリプト
# ============================================================================

set -euo pipefail

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

# プロジェクト別の既定 glob、必要になったら case を追加
default_rules_globs() {
  case "$(basename "$project_root")" in
  one-platform)
    printf '%s\n' 'overview.mdc:*_guidelines.mdc'
    ;;
  *)
    printf '%s\n' '*.mdc'
    ;;
  esac
}

# 注入する Cursor ルールファイル (.cursor/rules 配下の .mdc) を絞り込んで列挙
# 全ルールを毎回注入するとコンテキストが膨らむので、ファイル名パターンで対象を絞り込む仕組み
# INJECT_RULES_GLOBS に ":" 区切りでパターンを任意個並べ、いずれかに一致した .mdc すべてが対象
#   "*.mdc"                          -> 配下の全 .mdc (既定)
#   "overview.mdc:*_guidelines.mdc"  -> overview.mdc と、末尾が _guidelines.mdc の全ファイル
# 未指定時は default_rules_globs が返すプロジェクト別の既定パターン
find_rule_files() {
  [[ -d "$rules_dir" ]] || return 0

  local globs_spec="${INJECT_RULES_GLOBS:-$(default_rules_globs)}"
  local -a globs=() name_args=()
  local glob
  IFS=':' read -r -a globs <<<"$globs_spec"

  # 各パターンのいずれかに一致するよう find の検索条件を組み立て
  for glob in "${globs[@]}"; do
    [[ -n "$glob" ]] || continue
    ((${#name_args[@]})) && name_args+=(-o)
    name_args+=(-name "$glob")
  done
  ((${#name_args[@]})) || name_args=(-name '*.mdc')

  find "$rules_dir" -type f \( "${name_args[@]}" \) -print0 2>/dev/null
}

# 注入するコンテキスト (AGENTS.md + 対象ルール) を一時ファイルへ集約
context_file="$(mktemp)"
trap 'rm -f "$context_file"' EXIT

{
  # 1. グローバル指示 (AGENTS.md) の読み込み
  print_file "$agents_file"
  # 2. プロジェクトの Cursor ルールの読み込み
  while IFS= read -r -d '' file; do
    print_file "$file"
  done < <(find_rule_files)
} >"$context_file"

# Claude Code 経由のパイプなら JSON、手動実行の端末なら生テキストで返却
if [ -t 1 ]; then
  cat "$context_file"
elif grep -q '[^[:space:]]' "$context_file"; then
  jq -n --rawfile context "$context_file" '{
    suppressOutput: true,
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: $context
    }
  }'
fi
