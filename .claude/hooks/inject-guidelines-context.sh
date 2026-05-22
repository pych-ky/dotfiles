#!/usr/bin/env bash

set -euo pipefail

context_file="$(mktemp)"
exec 4>&1
exec 1>"$context_file"
trap 'exec 1>&4; rm -f "$context_file"' EXIT

project_root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
agents_file="${AGENTS_GLOBAL_FILE:-$HOME/.config/agents/AGENTS.md}"
rules_dir="$project_root/.cursor/rules"

print_file() {
  local file_path=$1
  [[ -r "$file_path" ]] || return 0

  local relative_path=${file_path#"$project_root"/}
  printf '===== %s =====\n' "${relative_path:-$file_path}"
  cat -- "$file_path"
  printf '\n'
}

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

while IFS= read -r -d '' file; do
  print_file "$file"
done < <(find_rule_files)

exec 1>&4

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
