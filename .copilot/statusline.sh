#!/usr/bin/env bash
# Copilot CLI ステータスライン

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# モデル未確定時は Claude 設定で補完しない
# 推論レベルは display_name にのみ含まれる
payload="$(jq -e 'select(.model.id) | {
  workspace,
  model: {id: .model.id},
  effort: {level: ((.model.display_name // "" | capture(" · (?<level>[a-z]+)( · |$)").level) // "default")},
  context_window: {used_percentage: .context_window.current_context_used_percentage},
  fast_mode: (.model.id == "claude-opus-4.8-fast")
}')" || exit 0

"$script_dir/../.claude/hooks/statusline.sh" copilot <<<"$payload"
