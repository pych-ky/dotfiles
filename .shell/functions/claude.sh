# Claude Code 共通設定

# 組織配布でローカル managed が無視されても共通設定を追加
claude() {
  local arg file
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

  file="$(readlink -f "$HOME/.shell/functions/claude.sh")"
  command claude --settings "${file%/.shell/functions/claude.sh}/etc/claude-code/settings.json" "$@"
}
