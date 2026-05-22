#!/usr/bin/env bash
#
# ============================================================================
# 危険な Bash コマンド (rm -rf / sudo / curl|sh) をブロックする PreToolUse フックスクリプト
# ============================================================================

set -euo pipefail

# jq が必須
if ! command -v jq >/dev/null 2>&1; then
  echo "pre-bash-guard.sh: jq is required but not installed" >&2
  exit 0
fi

# Claude Code から渡される PreToolUse イベントの JSON 全文を標準入力から取得
input=$(cat)

# ツール名と Bash コマンド文字列の取り出し
tool_name=$(jq -r '.tool_name // ""' <<<"$input")
command=$(jq -r '.tool_input.command // ""' <<<"$input")

# Bash 以外、またはコマンド空なら即時終了
if [[ "$tool_name" != "Bash" || -z "$command" ]]; then
  exit 0
fi

# 前後の空白をトリム
trimmed_command="$(
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$command"
)"

# ブロック理由を集める配列
blocked_reasons=()

# ルール 1: 先頭が rm -rf
if [[ $trimmed_command =~ ^[[:space:]]*rm[[:space:]]+-rf ]]; then
  blocked_reasons+=("rm -rf は許可していません。")
fi

# ルール 2: 先頭が sudo
if [[ $trimmed_command =~ ^[[:space:]]*sudo[[:space:]]+ ]]; then
  blocked_reasons+=("sudo の使用は Claude からは許可していません。")
fi

# ルール 3 & 4: curl / wget ... | sh / bash
if [[ $trimmed_command =~ (curl|wget)[^|]*\|[[:space:]]*(sh|bash) ]]; then
  blocked_reasons+=("curl / wget ... | sh / bash 形式のコマンドは許可していません。")
fi

# ブロック対象でなければそのまま許可
if ((${#blocked_reasons[@]} == 0)); then
  exit 0
fi

# 理由をまとめた JSON を Claude に返却し、exit 2 でブロック
reason_header="危険な可能性がある Bash コマンドをブロックしました。"
reason_details=$(printf '%s\n' "${blocked_reasons[@]}" | sed 's/^/- /')

msg=$reason_header$'\n\n'"Command:"$'\n  '"$trimmed_command"$'\n\n'"Reasons:"$'\n'"$reason_details"

jq -n --arg msg "$msg" '{decision:"block", reason:$msg}'
exit 2
