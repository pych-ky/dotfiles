# Claude Code 共通設定

# 組織配布でローカル managed が無視されても共通設定を追加
claude() {
  local arg source link file
  for arg in "$@"; do
    case "$arg" in
    --) break ;;
    --settings | --settings=*)
      printf 'claude: --settings が指定されているため、共通設定の追加をスキップします\n' >&2
      command claude "$@"
      return $?
      ;;
    esac
  done

  # 先頭で分岐するサブコマンドには --settings を追加しない
  case "${1:-}" in
  remote-control | rc | remote | sync | bridge)
    command claude "$@"
    return $?
    ;;
  esac
  for arg in "$@"; do
    case "$arg" in
    --dangerously-skip-permissions | --allow-dangerously-skip-permissions) ;;
    daemon)
      command claude "$@"
      return $?
      ;;
    *) break ;;
    esac
  done

  if [ -n "${ZSH_VERSION:-}" ]; then
    # shellcheck disable=SC2296
    source="${(%):-%x}"
  else
    source="${BASH_SOURCE[0]}"
  fi
  while [ -L "$source" ]; do
    link="$(readlink "$source")" || break
    case "$link" in
    /*) source="$link" ;;
    *) source="$(dirname "$source")/$link" ;;
    esac
  done
  file="$(cd "$(dirname "$source")/../.." 2>/dev/null && pwd -P)/etc/claude-code/settings.json"
  if ! jq -e . "$file" >/dev/null 2>&1; then
    printf 'claude: 共通設定を読み込めないため、設定を追加せず起動します\n' >&2
    command claude "$@"
    return $?
  fi
  command claude --settings "$file" "$@"
}
