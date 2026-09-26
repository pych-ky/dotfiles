#!/usr/bin/env bash
# Copilot CLI のステータスラインを Codex TUI に合わせる

set -euo pipefail

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# モデル確定前は Claude 設定のモデルで補完されるため表示しない
# 推論レベルは表示名 "<モデル> · <推論レベル>" にだけ含まれる
payload="$(jq -e 'select(.model.id) | {
  workspace,
  model: {id: .model.id},
  effort: {level: ((.model.display_name // "" | capture(" · (?<level>[a-z]+)( · |$)").level) // "default")},
  context_window: {used_percentage: .context_window.current_context_used_percentage}
}')" || exit 0

"$script_dir/../.claude/hooks/statusline.sh" <<<"$payload"
