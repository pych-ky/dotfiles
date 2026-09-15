# ghq 管理のリポジトリを fzf で選択して移動
cghq() {
  local repository_dir
  repository_dir="$(ghq list --full-path | fzf --no-multi --height=40% --layout=reverse --prompt='ghq> ' --query="$*")" || return 1
  [ -n "$repository_dir" ] || return 1
  cd -- "$repository_dir" || return 1
}
