# Homebrew の PATH と HOMEBREW_PREFIX を反映 (Apple Silicon: /opt/homebrew, Intel: /usr/local)
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# ~/.local/bin、Homebrew Git、Rancher Desktop の CLI を標準 PATH より優先
for dir in "$HOME/.rd/bin" "${HOMEBREW_PREFIX:-/usr/local}/opt/git/bin" "$HOME/.local/bin"; do
  [ -d "$dir" ] || continue
  case ":$PATH:" in
  *":$dir:"*) ;;
  *) PATH="$dir:$PATH" ;;
  esac
done
unset dir
export PATH

# mise: リポジトリごとに開発ツールのバージョンを切り替える
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi

# aws-use / aws-clear の読み込み
[ -r "$HOME/.shell/functions/aws.sh" ] && . "$HOME/.shell/functions/aws.sh"

# Git worktree 関数の読み込み
[ -r "$HOME/.shell/functions/git-worktree.sh" ] && . "$HOME/.shell/functions/git-worktree.sh"

# 保存済み AWS プロファイルの読み込み
[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"

# 端末ローカル設定の読み込み (組織固有の設定やツールの自動追記の受け皿、git 管理外)
[ -r "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
