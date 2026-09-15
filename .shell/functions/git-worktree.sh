# Bash / Zsh 共通の fzf worktree 作成関数

# ローカル / origin のブランチを重複排除して列挙する
_wto_branches() {
  local repository_root="$1"

  {
    git -C "$repository_root" for-each-ref --format='%(refname:short)' refs/heads
    git -C "$repository_root" for-each-ref --format='%(refname)' refs/remotes/origin |
      sed 's#^refs/remotes/origin/##'
  } |
    grep -vE '^(HEAD|main|master)$' |
    awk '!seen[$0]++'
}

# パス衝突回避用の安定したサフィックスを返す
_wto_hash6() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 1
  else
    printf '%s' "$1" | sha1sum
  fi | awk '{print substr($1, 1, 6)}'
}

_wto_path_has_branch() {
  local repository_root="$1"
  local worktree_path="$2"
  local branch="$3"
  local worktree_path_physical

  # /tmp と /private/tmp を同じパスとして比較する
  worktree_path_physical="$(cd "$worktree_path" 2>/dev/null && pwd -P)" || return 1

  git -C "$repository_root" worktree list --porcelain |
    awk -v path="$worktree_path_physical" -v branch="refs/heads/$branch" '
    # 空白を含むパスも取得する
    $1 == "worktree" { worktree = substr($0, 10) }
    $1 == "branch" && worktree == path && $2 == branch { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

# fzf で複数ブランチを選択し、まとめて .worktrees/<leaf> に worktree を作成
wto() {
  local repository_root
  repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  repository_root="$(cd "$repository_root" && pwd -P)" || return 1

  command -v fzf >/dev/null 2>&1 || {
    echo 'wto: fzf is required' >&2
    return 1
  }

  local worktrees_root="$repository_root/.worktrees"
  mkdir -p "$worktrees_root" || return 1
  git -C "$repository_root" fetch --all --prune >/dev/null 2>&1 || true

  local branches
  branches="$(_wto_branches "$repository_root" | fzf -m --prompt='worktrees> ' --header='TABで複数選択 / ENTERで確定')" || return 1
  [ -n "$branches" ] || return 1

  local branch dir leaf
  local failed_count=0
  local -a created_paths=()

  while IFS= read -r branch; do
    [ -n "$branch" ] || continue

    leaf="${branch##*/}"
    dir="$worktrees_root/$leaf"

    # 同名の末尾要素を持つ別ブランチとのパス衝突を避ける
    if [ -e "$dir" ] && ! _wto_path_has_branch "$repository_root" "$dir" "$branch"; then
      dir="$worktrees_root/${leaf}__$(_wto_hash6 "$branch")"
    fi

    if [ -e "$dir" ] && _wto_path_has_branch "$repository_root" "$dir" "$branch"; then
      echo "exists: $dir (branch=$branch)"
      created_paths+=("$dir")
      continue
    fi

    if ! git -C "$repository_root" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$repository_root" branch --track "$branch" "origin/$branch" >/dev/null 2>&1 || true
    fi

    if git -C "$repository_root" worktree add "$dir" "$branch" >/dev/null; then
      echo "created: $dir (branch=$branch)"
      created_paths+=("$dir")
    else
      echo "failed: $dir (branch=$branch)" >&2
      failed_count=$((failed_count + 1))
    fi
  done <<<"$branches"

  if ((${#created_paths[@]})); then
    echo "Open these folders in your editor:"
    printf '  %s\n' "${created_paths[@]}"
  fi

  ((failed_count == 0))
}
