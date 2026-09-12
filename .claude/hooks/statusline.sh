#!/usr/bin/env bash
# Claude Code ステータスラインを Codex TUI の表示構成に合わせる

set -euo pipefail

status_separator=' · '
codex_context_baseline_tokens=12000
default_claude_context_window=200000

# このスクリプトの実体があるディレクトリを返す
script_dir() {
  local source="${BASH_SOURCE[0]}"
  local dir
  local target

  while [[ -L "$source" ]]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    target="$(readlink "$source")"
    if [[ "$target" == /* ]]; then
      source="$target"
    else
      source="$dir/$target"
    fi
  done

  cd -P "$(dirname "$source")" && pwd
}

repo_dir="$(cd "$(script_dir)/../.." && pwd)"
codex_config="${CODEX_STATUSLINE_CODEX_CONFIG:-}"
if [[ -z "$codex_config" || ! -r "$codex_config" ]]; then
  if [[ -r /etc/codex/config.toml ]]; then
    codex_config="/etc/codex/config.toml"
  else
    codex_config="$repo_dir/.config/codex/config.toml"
  fi
fi
claude_settings="${CODEX_STATUSLINE_CLAUDE_SETTINGS:-$repo_dir/.claude/settings.json}"

has_command() {
  command -v "$1" >/dev/null 2>&1
}

# Claude の入力 JSON を 1 回で読み、表示値を設定する
read_input_json() {
  local payload="$1"
  local key
  local value

  [[ -n "$payload" ]] || return 0
  has_command jq || return 0

  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    case "$key" in
    cwd | model_name | effort | transcript_path | context_used | context_input_tokens | context_window_size | context_window | used_tokens | five_hour_limit | weekly_limit)
      printf -v "input_$key" '%s' "$value"
      ;;
    esac
  done < <(
    jq -j '
      . as $root
      | (try $root.model catch null) as $model
      |
      [
        ["cwd", (try ($root.workspace.current_dir // $root.cwd) catch null)],
        ["model_name", (
          if ($model | type) == "object" then
            $model.display_name // $model.name // $model.id
          elif ($model | type) == "string" then
            $model
          else
            null
          end
        )],
        ["effort", (try $root.effort.level catch null)],
        ["transcript_path", (try $root.transcript_path catch null)],
        ["context_used", (
          try $root.context_window.used_percentage catch null
        )],
        ["context_input_tokens", (
          try $root.context_window.total_input_tokens catch null
        )],
        ["context_window_size", (
          try $root.context_window.context_window_size catch null
        )],
        ["context_window", (try (
          $root.model_context_window //
          $root.context.window //
          $root.usage.context_window
        ) catch null)],
        ["used_tokens", (try (
          $root.usage.total_tokens //
          $root.context.total_tokens //
          $root.context.used_tokens
        ) catch null)],
        ["five_hour_limit", (
          try $root.rate_limits.five_hour.used_percentage catch null
        )],
        ["weekly_limit", (
          try $root.rate_limits.seven_day.used_percentage catch null
        )]
      ]
      | .[]
      | .[0] + "\u0000" + (.[1] // "" | tostring) + "\u0000"
    ' 2>/dev/null <<<"$payload" || true
  )
}

# Claude 設定を 1 回で読み、入力 JSON のフォールバック値を設定する
read_claude_settings() {
  local file="$1"
  local key
  local value

  [[ -r "$file" ]] || return 0
  has_command jq || return 0

  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    case "$key" in
    model | effort) printf -v "settings_$key" '%s' "$value" ;;
    esac
  done < <(
    jq -j '
      [
        ["model", (try .model catch null)],
        ["effort", (try .effortLevel catch null)]
      ]
      | .[]
      | .[0] + "\u0000" + (.[1] // "" | tostring) + "\u0000"
    ' "$file" 2>/dev/null || true
  )
}

# TOML から単純な scalar 値を取り出す
toml_scalar() {
  local file="$1"
  local key="$2"

  [[ -r "$file" ]] || return 0

  awk -v key="$key" '
    BEGIN { pattern = "^[[:space:]]*" key "[[:space:]]*=" }
    $0 ~ pattern {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      sub(/^[^=]*=[[:space:]]*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      gsub(/^"|"$/, "", line)
      print line
      exit
    }
  ' "$file" 2>/dev/null || true
}

# Codex の status_line 配列から表示項目を 1 行ずつ返す
read_status_items() {
  local file="$1"

  [[ -r "$file" ]] || return 0

  sed -n '/^[[:space:]]*status_line[[:space:]]*=/,/^[[:space:]]*]/p' "$file" 2>/dev/null |
    sed 's/#.*//' |
    grep -o '"[^"]*"' |
    tr -d '"' || true
}

# ホームディレクトリ配下のパスを ~ 表記に変換する
format_directory_display() {
  local dir="${1:-$PWD}"

  if [[ "$dir" == "$HOME" ]]; then
    printf '~'
  elif [[ "$dir" == "$HOME"/* ]]; then
    printf '~'
    printf '/%s' "${dir#"$HOME"/}"
  else
    printf '%s' "$dir"
  fi
}

current_git_branch() {
  local dir="$1"

  has_command git || return 0
  git -C "$dir" branch --show-current 2>/dev/null | sed -n '1p' || true
}

# パーセント値を切り上げた 0-100 の整数に整形する
ceil_percent() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0

  awk -v value="$value" '
    BEGIN {
      if (value > 100) {
        value = 100
      }

      rounded = int(value)
      if (value > rounded) {
        rounded += 1
      }

      printf "%d", rounded
    }
  '
}

# Claude transcript の末尾から直近の合計トークン数を返す
last_transcript_usage_total() {
  local transcript_path="$1"

  [[ -r "$transcript_path" ]] || return 0
  has_command jq || return 0

  tail -n 2000 "$transcript_path" 2>/dev/null |
    jq -r '
      select(.message.usage? != null)
      | .message.usage
      | (
          .total_tokens //
          (
            (.input_tokens // 0) +
            (.output_tokens // 0) +
            (.cache_creation_input_tokens // 0) +
            (.cache_read_input_tokens // 0)
          )
        )
    ' 2>/dev/null |
    tail -n 1 || true
}

# Codex の baseline を差し引いた context 使用率を返す
context_used_percent() {
  local used_tokens="$1"
  local context_window="$2"

  [[ "$used_tokens" =~ ^[0-9]+$ ]] || used_tokens=0
  [[ "$context_window" =~ ^[0-9]+$ ]] || context_window="$default_claude_context_window"

  token_usage_percent "$used_tokens" "$context_window" "$codex_context_baseline_tokens"
}

# baseline がある場合は差し引き、context window に対する使用率を返す
token_usage_percent() {
  local used_tokens="$1"
  local context_window="$2"
  local baseline="${3:-0}"

  [[ "$used_tokens" =~ ^[0-9]+$ ]] || return 0
  [[ "$context_window" =~ ^[0-9]+$ ]] || return 0

  awk \
    -v used_tokens="$used_tokens" \
    -v context_window="$context_window" \
    -v baseline="$baseline" '
      BEGIN {
        if (context_window <= baseline) {
          if (baseline > 0) {
            print 100
          }
          exit
        }

        used = used_tokens - baseline
        if (used < 0) {
          used = 0
        }

        percent = (used / (context_window - baseline)) * 100
        if (percent > 100) {
          percent = 100
        }

        rounded = int(percent)
        if (percent > rounded) {
          rounded += 1
        }

        printf "%d", rounded
      }
    '
}

# reasoning 未指定時は Codex と同じ default 表示にする
reasoning_label() {
  local value="$1"

  if [[ -z "$value" || "$value" == "null" || "$value" == "none" ]]; then
    printf 'default'
  else
    printf '%s' "$value"
  fi
}

# rate limit の使用率が取れたときだけ表示用ラベルを返す
rate_limit_label() {
  local label="$1"
  local used_percentage="$2"
  local used_percent

  [[ -n "$used_percentage" ]] || return 0

  used_percent="$(ceil_percent "$used_percentage")"
  [[ -n "$used_percent" ]] || return 0

  printf '%s %s%% used' "$label" "$used_percent"
}

status_line_use_colors="$(toml_scalar "$codex_config" status_line_use_colors)"
[[ -n "$status_line_use_colors" ]] || status_line_use_colors=true

# 色設定が有効なときだけ項目の ANSI color を付ける
styled() {
  local item="$1"
  local text="$2"
  local code

  if [[ "$status_line_use_colors" != true ]]; then
    printf '%s' "$text"
    return 0
  fi

  case "$item" in
  model | model-name | model-with-reasoning | reasoning | run-state | status | fast-mode | raw-output | permissions | approval-mode | approval | codex-version | thread-id | session-id)
    code=36
    ;;
  current-dir | project-name | project | project-root | context-remaining | context-used | context-usage | context-window-size | used-tokens | total-input-tokens | total-output-tokens | task-progress)
    code=32
    ;;
  git-branch | pull-request-number | branch-changes | five-hour-limit | weekly-limit | thread-title)
    code=35
    ;;
  *)
    code=2
    ;;
  esac
  printf '\033[%sm%s\033[0m' "$code" "$text"
}

# 表示値が空でなければステータスライン末尾に追加する
append_segment() {
  local item="$1"
  local text="$2"

  [[ -n "$text" ]] || return 0

  if [[ -n "$status_line" ]]; then
    if [[ "$status_line_use_colors" == true ]]; then
      status_line+="$(printf '\033[2m%s\033[0m' "$status_separator")"
    else
      status_line+="$status_separator"
    fi
  fi
  status_line+="$(styled "$item" "$text")"
}

main() {
  local input
  input="$(cat)"

  local input_cwd=''
  local input_model_name=''
  local input_effort=''
  local input_transcript_path=''
  local input_context_used=''
  local input_context_input_tokens=''
  local input_context_window_size=''
  local input_context_window=''
  local input_used_tokens=''
  local input_five_hour_limit=''
  local input_weekly_limit=''
  local settings_model=''
  local settings_effort=''
  read_input_json "$input"
  read_claude_settings "$claude_settings"

  local cwd="$input_cwd"
  [[ -n "$cwd" ]] || cwd="$PWD"

  local model_name="$input_model_name"
  [[ -n "$model_name" ]] || model_name="$settings_model"
  [[ -n "$model_name" ]] || model_name="$(toml_scalar "$codex_config" model)"

  local claude_effort="$input_effort"
  [[ -n "$claude_effort" ]] || claude_effort="$settings_effort"
  [[ -n "$claude_effort" ]] || claude_effort="$(toml_scalar "$codex_config" model_reasoning_effort)"

  local reasoning
  reasoning="$(reasoning_label "$claude_effort")"

  local context_used="$input_context_used"
  if [[ -z "$context_used" ]]; then
    context_used="$(token_usage_percent "$input_context_input_tokens" "$input_context_window_size")"
  fi
  if [[ -z "$context_used" ]]; then
    local used_tokens
    used_tokens="$input_used_tokens"
    [[ -n "$used_tokens" ]] || used_tokens="$(last_transcript_usage_total "$input_transcript_path")"
    context_used="$(context_used_percent "$used_tokens" "$input_context_window")"
  fi
  context_used="$(ceil_percent "$context_used")"

  local service_tier
  service_tier="$(toml_scalar "$codex_config" service_tier)"
  local fast_mode='Fast off'
  case "$service_tier" in
  fast | priority) fast_mode='Fast on' ;;
  esac

  local status_line=''
  local -a status_items=()
  local item
  while IFS= read -r item; do
    [[ -n "$item" ]] && status_items+=("$item")
  done < <(read_status_items "$codex_config")

  if ((${#status_items[@]} == 0)); then
    status_items=("model-with-reasoning" "current-dir")
  fi

  for item in "${status_items[@]}"; do
    case "$item" in
    model | model-name)
      append_segment "$item" "$model_name"
      ;;
    model-with-reasoning)
      append_segment "$item" "$model_name $reasoning"
      ;;
    reasoning)
      append_segment "$item" "$reasoning"
      ;;
    current-dir)
      append_segment "$item" "$(format_directory_display "$cwd")"
      ;;
    git-branch)
      append_segment "$item" "$(current_git_branch "$cwd")"
      ;;
    context-used | context-usage)
      append_segment "$item" "Context ${context_used}% used"
      ;;
    fast-mode)
      append_segment "$item" "$fast_mode"
      ;;
    five-hour-limit)
      append_segment "$item" "$(rate_limit_label "5h limit" "$input_five_hour_limit")"
      ;;
    weekly-limit)
      append_segment "$item" "$(rate_limit_label "Weekly limit" "$input_weekly_limit")"
      ;;
    *) ;;
    esac
  done

  printf '%s\n' "$status_line"
}

main "$@"
