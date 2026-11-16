#!/usr/bin/env bash
# Claude Code ステータスライン

set -euo pipefail

input_cwd=''
input_model_name=''
input_effort=''
input_context_used=''
input_context_input_tokens=''
input_context_window_size=''
input_five_hour_limit=''
input_weekly_limit=''
input_fast_mode=''

# 表示用 JSON フィールドの読み込み
read_input_json() {
  local field

  for field in cwd model_name effort context_used context_input_tokens context_window_size \
    five_hour_limit weekly_limit fast_mode; do
    IFS= read -r -d '' "input_$field" || break
  done < <(
    jq -j '
      .workspace.current_dir,
      (.model | .display_name // .id),
      .effort.level,
      .context_window.used_percentage,
      .context_window.total_input_tokens,
      .context_window.context_window_size,
      .rate_limits.five_hour.used_percentage,
      .rate_limits.seven_day.used_percentage,
      (.fast_mode | tostring)
      | (. // "" | tostring) + "\u0000"
    ' 2>/dev/null <<<"$1"
  )
}

# Codex の status_line と同じ表示項目を列挙
read_status_items() {
  sed -n '/^[[:space:]]*status_line[[:space:]]*=/,/^[[:space:]]*]/p' /etc/codex/config.toml |
    sed 's/#.*//' |
    grep -o '"[^"]*"' |
    tr -d '"'
}

# ホームを ~ に省略した表示
format_directory_display() {
  local dir="$1"

  if [[ "$dir" == "$HOME" ]]; then
    printf '~'
  elif [[ "$dir" == "$HOME"/* ]]; then
    printf '%s/%s' '~' "${dir#"$HOME"/}"
  else
    printf '%s' "$dir"
  fi
}

# 百分率の切り上げ（上限 100）
ceil_percent() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0

  awk -v value="$value" '
    BEGIN {
      if (value > 100) {
        value = 100
      }

      rounded = int(value)
      printf "%d", rounded + (value > rounded)
    }
  '
}

# コンテキスト使用率（未丸め）
token_usage_percent() {
  [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[1-9][0-9]*$ ]] || return 0

  # 切り上げ用の精度を保持
  awk -v used_tokens="$1" -v context_window="$2" \
    'BEGIN { printf "%.17f", (used_tokens / context_window) * 100 }'
}

# レート制限ラベルの作成
rate_limit_label() {
  local used_percent

  used_percent="$(ceil_percent "$2")"
  [[ -n "$used_percent" ]] || return 0

  printf '%s %s%% used' "$1" "$used_percent"
}

# 指定色の項目を区切り付きで status_line に追加
append_segment() {
  [[ -n "$2" ]] || return 0

  [[ -z "$status_line" ]] || status_line+=$'\033[2m · \033[0m'
  status_line+=$'\033['"$1m$2"$'\033[0m'
}

# ステータスラインの出力
main() {
  local input caller="${1:-claude}"
  input="$(cat)"

  if [[ "$caller" == claude && -x "$HOME/.orca/agent-hooks/claude-statusline.sh" ]]; then
    "$HOME/.orca/agent-hooks/claude-statusline.sh" <<<"$input" >/dev/null 2>&1 || true
  fi

  read_input_json "$input"

  local cwd="${input_cwd:-$PWD}"

  local reasoning="$input_effort"
  case "$reasoning" in
  '' | none) reasoning=default ;;
  esac

  local context_used="$input_context_used"
  if [[ -z "$context_used" ]]; then
    context_used="$(token_usage_percent "$input_context_input_tokens" "$input_context_window_size")"
  fi
  context_used="$(ceil_percent "${context_used:-0}")"

  local fast_mode=''
  case "$input_fast_mode" in
  true) fast_mode='Fast on' ;;
  false) fast_mode='Fast off' ;;
  esac

  local status_line='' item
  while IFS= read -r item; do
    case "$item" in
    model-with-reasoning) append_segment 36 "$input_model_name $reasoning" ;;
    current-dir) append_segment 32 "$(format_directory_display "$cwd")" ;;
    git-branch) append_segment 35 "$(git -C "$cwd" branch --show-current 2>/dev/null)" ;;
    context-used) append_segment 32 "Context ${context_used}% used" ;;
    five-hour-limit) append_segment 35 "$(rate_limit_label "5h limit" "$input_five_hour_limit")" ;;
    weekly-limit) append_segment 35 "$(rate_limit_label "Weekly limit" "$input_weekly_limit")" ;;
    fast-mode) append_segment 36 "$fast_mode" ;;
    esac
  done < <(read_status_items)

  if [[ "$caller" == claude ]] &&
    jq -e 'type=="object" and length>0' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/remote-settings.json" >/dev/null 2>&1; then
    append_segment 2 org
  fi

  printf '%s\n' "$status_line"
}

main "$@"
