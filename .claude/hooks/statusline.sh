#!/usr/bin/env bash
# Claude Code ステータスライン

set -euo pipefail

status_separator=' · '
codex_context_baseline_tokens=12000
default_claude_context_window=200000

script_path="$(readlink -f "${BASH_SOURCE[0]}")"
repo_dir="$(cd "${script_path%/*}/../.." && pwd)"
codex_config="${CODEX_STATUSLINE_CODEX_CONFIG:-}"
if [[ -z "$codex_config" || ! -r "$codex_config" ]]; then
  if [[ -r /etc/codex/config.toml ]]; then
    codex_config="/etc/codex/config.toml"
  else
    codex_config="$repo_dir/etc/codex/config.toml"
  fi
fi
claude_settings="${CODEX_STATUSLINE_CLAUDE_SETTINGS:-$repo_dir/etc/claude-code/settings.json}"

# コマンドの存在確認
has_command() {
  command -v "$1" >/dev/null 2>&1
}

input_cwd=''
input_model_name=''
input_effort=''
input_transcript_path=''
input_context_used=''
input_context_input_tokens=''
input_context_window_size=''
input_context_window=''
input_used_tokens=''
input_five_hour_limit=''
input_weekly_limit=''
input_fast_mode=''

# 表示用 JSON フィールドの読み込み
read_input_json() {
  local payload="$1" field

  [[ -n "$payload" ]] || return 0
  has_command jq || return 0

  for field in cwd model_name effort transcript_path context_used context_input_tokens \
    context_window_size context_window used_tokens five_hour_limit weekly_limit fast_mode; do
    IFS= read -r -d '' "input_$field" || break
  done < <(
    jq -j '
      (try .model catch null) as $model
      |
      [
        (try (.workspace.current_dir // .cwd) catch null),
        (
          if ($model | type) == "object" then
            $model.display_name // $model.name // $model.id
          elif ($model | type) == "string" then
            $model
          else
            null
          end
        ),
        (try .effort.level catch null),
        (try .transcript_path catch null),
        (try .context_window.used_percentage catch null),
        (try .context_window.total_input_tokens catch null),
        (try .context_window.context_window_size catch null),
        (try (
          .model_context_window //
          .context.window //
          .usage.context_window
        ) catch null),
        (try (
          .usage.total_tokens //
          .context.total_tokens //
          .context.used_tokens
        ) catch null),
        (try .rate_limits.five_hour.used_percentage catch null),
        (try .rate_limits.seven_day.used_percentage catch null),
        (try (.fast_mode | if type == "boolean" then tostring else null end) catch null)
      ]
      | .[]
      | (. // "" | tostring) + "\u0000"
    ' 2>/dev/null <<<"$payload"
  )
}

settings_model=''
settings_effort=''

# Claude のモデル・effort 設定の読み込み
read_claude_settings() {
  local file="$1"

  [[ -r "$file" ]] || return 0
  has_command jq || return 0

  {
    IFS= read -r -d '' settings_model &&
      IFS= read -r -d '' settings_effort
  } < <(
    jq -j '
      [
        (try .model catch null),
        (try .effortLevel catch null)
      ]
      | .[]
      | (. // "" | tostring) + "\u0000"
    ' "$file" 2>/dev/null
  ) || true
}

# TOML スカラー値の取得
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

# status_line の項目列挙
read_status_items() {
  local file="$1"

  [[ -r "$file" ]] || return 0

  sed -n '/^[[:space:]]*status_line[[:space:]]*=/,/^[[:space:]]*]/p' "$file" 2>/dev/null |
    sed 's/#.*//' |
    grep -o '"[^"]*"' |
    tr -d '"' || true
}

# ホームを ~ に省略した表示
format_directory_display() {
  local dir="${1:-$PWD}"

  if [[ "$dir" == "$HOME" ]]; then
    printf '~'
  elif [[ "$dir" == "$HOME"/* ]]; then
    printf '%s/%s' '~' "${dir#"$HOME"/}"
  else
    printf '%s' "$dir"
  fi
}

# 現在の Git ブランチ取得
current_git_branch() {
  local dir="$1"

  has_command git || return 0
  git -C "$dir" branch --show-current 2>/dev/null | sed -n '1p' || true
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

# transcript の最後の使用トークン数を取得
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

# baseline 控除後の使用率（未丸め）
token_usage_percent() {
  local used_tokens="$1"
  local context_window="$2"
  local baseline="${3:-0}"

  [[ "$used_tokens" =~ ^[0-9]+$ ]] || return 0
  [[ "$context_window" =~ ^[0-9]+$ ]] || return 0

  # ceil_percent 用に小数点を . に固定
  LC_ALL=C awk \
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

        # 切り上げ用の精度を保持
        printf "%.17f", (used / (context_window - baseline)) * 100
      }
    '
}

# レート制限ラベルの作成
rate_limit_label() {
  local used_percent

  used_percent="$(ceil_percent "$2")"
  [[ -n "$used_percent" ]] || return 0

  printf '%s %s%% used' "$1" "$used_percent"
}

status_line_use_colors="$(toml_scalar "$codex_config" status_line_use_colors)"
[[ -n "$status_line_use_colors" ]] || status_line_use_colors=true
if [[ "$status_line_use_colors" == true ]]; then
  status_separator="$(printf '\033[2m%s\033[0m' "$status_separator")"
fi

# 区切り・項目色付きで status_line に追加
append_segment() {
  local item="$1"
  local text="$2"
  local code

  [[ -n "$text" ]] || return 0

  if [[ "$status_line_use_colors" == true ]]; then
    case "$item" in
    model | model-name | model-with-reasoning | reasoning | fast-mode)
      code=36
      ;;
    current-dir | context-used | context-usage)
      code=32
      ;;
    git-branch | five-hour-limit | weekly-limit)
      code=35
      ;;
    *)
      code=2
      ;;
    esac
    text="$(printf '\033[%sm%s\033[0m' "$code" "$text")"
  else
    text="$(printf '%s' "$text")"
  fi

  [[ -z "$status_line" ]] || status_line+="$status_separator"
  status_line+="$text"
}

# ステータスラインの出力
main() {
  local input caller="${1:-claude}"
  input="$(cat)"

  if [[ "$caller" == claude && -x "$HOME/.orca/agent-hooks/claude-statusline.sh" ]]; then
    "$HOME/.orca/agent-hooks/claude-statusline.sh" <<<"$input" >/dev/null 2>&1 || true
  fi

  read_input_json "$input"
  if [[ "$caller" == claude ]]; then
    read_claude_settings "$claude_settings"
  fi

  local cwd="${input_cwd:-$PWD}"

  local model_name="${input_model_name:-$settings_model}"
  [[ -n "$model_name" ]] || model_name="$(toml_scalar "$codex_config" model)"

  local reasoning="${input_effort:-$settings_effort}"
  [[ -n "$reasoning" ]] || reasoning="$(toml_scalar "$codex_config" model_reasoning_effort)"
  case "$reasoning" in
  '' | null | none) reasoning=default ;;
  esac
  reasoning="$(printf '%s' "$reasoning")"

  local context_used="$input_context_used"
  if [[ -z "$context_used" ]]; then
    context_used="$(token_usage_percent "$input_context_input_tokens" "$input_context_window_size")"
  fi
  if [[ -z "$context_used" ]]; then
    local used_tokens="$input_used_tokens"
    [[ -n "$used_tokens" ]] || used_tokens="$(last_transcript_usage_total "$input_transcript_path")"
    [[ "$used_tokens" =~ ^[0-9]+$ ]] || used_tokens=0
    local context_window="$input_context_window"
    [[ "$context_window" =~ ^[0-9]+$ ]] || context_window="$default_claude_context_window"
    context_used="$(token_usage_percent "$used_tokens" "$context_window" "$codex_context_baseline_tokens")"
  fi
  context_used="$(ceil_percent "$context_used")"

  local fast_mode=''
  case "$input_fast_mode" in
  true) fast_mode='Fast on' ;;
  false) fast_mode='Fast off' ;;
  esac

  local status_line='' status_items item
  status_items="$(read_status_items "$codex_config")"
  [[ -n "$status_items" ]] || status_items=$'model-with-reasoning\ncurrent-dir'
  while IFS= read -r item; do
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
    five-hour-limit)
      append_segment "$item" "$(rate_limit_label "5h limit" "$input_five_hour_limit")"
      ;;
    weekly-limit)
      append_segment "$item" "$(rate_limit_label "Weekly limit" "$input_weekly_limit")"
      ;;
    fast-mode)
      append_segment "$item" "$fast_mode"
      ;;
    *) ;;
    esac
  done <<<"$status_items"

  if [[ "$caller" == claude ]] && has_command jq && jq -e 'type=="object" and length>0' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/remote-settings.json" >/dev/null 2>&1; then
    append_segment 'managed-settings' 'org'
  fi

  printf '%s\n' "$status_line"
}

main "$@"
