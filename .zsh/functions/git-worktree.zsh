# ============================================================================
# fzf で複数ブランチの worktree を作成するシェル関数
# ============================================================================

# HEAD / main / master を除外し、ローカル / origin の全ブランチを重複排除して列挙
_wto_branches() {
  {
    git for-each-ref --format='%(refname:short)' refs/heads
    git for-each-ref --format='%(refname)' refs/remotes/origin |
      sed 's#^refs/remotes/origin/##'
  } |
    grep -vE '^(HEAD|main|master)$' |
    awk '!seen[$0]++'
}

# パス衝突回避用の安定サフィックスとして文字列の SHA-1 先頭 6 文字を返却
_wto_hash6() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 1
  else
    printf '%s' "$1" | sha1sum
  fi | awk '{print substr($1, 1, 6)}'
}

# 指定 path / branch の worktree が登録済みかを確認し、一致時は終了コード 0 を返却
_wto_path_has_branch() {
  # zsh では path が PATH と連動する特殊変数のため、local 変数にその名前を使わない
  local worktree_path="$1"
  local branch="$2"

  git worktree list --porcelain | awk -v path="$PWD/$worktree_path" -v branch="refs/heads/$branch" '
    $1 == "worktree" { worktree = substr($0, 10) }
    $1 == "branch" && worktree == path && $2 == branch { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

# fzf で複数ブランチを選択し、まとめて .worktrees/<leaf> に worktree を作成
wto() {
  # git リポジトリ内かつ fzf が必須
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  command -v fzf >/dev/null 2>&1 || {
    echo 'wto: fzf is required' >&2
    return 1
  }

  mkdir -p .worktrees
  # リモートの最新状態を取り込んでから候補列挙、失敗しても継続
  git fetch --all --prune >/dev/null 2>&1 || true

  local branches
  branches="$(_wto_branches | fzf -m --prompt='worktrees> ' --header='TABで複数選択 / ENTERで確定')" || return 1
  [ -n "$branches" ] || return 1

  local branch dir leaf
  local -a created_paths
  created_paths=()

  while IFS= read -r branch; do
    [ -n "$branch" ] || continue

    # ブランチ名の最後のスラッシュ以降をディレクトリ名に使用
    leaf="${branch##*/}"
    dir=".worktrees/$leaf"

    # leaf 名が別ブランチに使われているだけのときはハッシュサフィックスを付けて回避
    if [ -e "$dir" ] && ! _wto_path_has_branch "$dir" "$branch"; then
      dir=".worktrees/${leaf}__$(_wto_hash6 "$branch")"
    fi

    # 確定したパスに既に同じ branch が割り当て済みなら冪等にスキップ
    if [ -e "$dir" ] && _wto_path_has_branch "$dir" "$branch"; then
      echo "exists: $dir (branch=$branch)"
      created_paths+=("$dir")
      continue
    fi

    # ローカルにブランチが無ければ origin から追跡ブランチを作成
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
      git branch --track "$branch" "origin/$branch" >/dev/null 2>&1 || true
    fi

    # stdout は抑制しつつ、失敗原因が分かるよう stderr は通す
    if git worktree add "$dir" "$branch" >/dev/null; then
      echo "created: $dir (branch=$branch)"
      created_paths+=("$dir")
    else
      echo "failed: $dir (branch=$branch)" >&2
    fi
  done <<<"$branches"

  # 作成 / 既存 worktree のパス一覧をエディタで開きやすい形式で表示
  if (( ${#created_paths[@]} )); then
    echo "Open these folders in your editor:"
    printf '  %s\n' "${created_paths[@]}"
  fi
}
