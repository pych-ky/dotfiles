# Homebrew の PATH と HOMEBREW_PREFIX を反映 (Apple Silicon: /opt/homebrew, Intel: /usr/local)
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# ~/.local/bin と Homebrew Git を標準 PATH より優先
for dir in "${HOMEBREW_PREFIX:-/usr/local}/opt/git/bin" "$HOME/.local/bin"; do
  [ -d "$dir" ] || continue
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
done
unset dir
export PATH

# aws-use / aws-env / aws-clear の読み込み
[ -r "$HOME/.shell/functions/aws.sh" ] && . "$HOME/.shell/functions/aws.sh"

# Git worktree 関数の読み込み
[ -r "$HOME/.shell/functions/git-worktree.sh" ] && . "$HOME/.shell/functions/git-worktree.sh"

# 保存済み AWS プロファイルの読み込み
[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"
