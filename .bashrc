if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# ~/.local/bin、Homebrew Git、Rancher Desktop の順で標準 PATH より優先
for dir in "$HOME/.rd/bin" "${HOMEBREW_PREFIX:-/usr/local}/opt/git/bin" "$HOME/.local/bin"; do
  [ -d "$dir" ] || continue
  case ":$PATH:" in
  *":$dir:"*) ;;
  *) PATH="$dir:$PATH" ;;
  esac
done
unset dir
export PATH

if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi

[ -r "$HOME/.shell/functions/aws.sh" ] && . "$HOME/.shell/functions/aws.sh"

[ -r "$HOME/.shell/functions/git-worktree.sh" ] && . "$HOME/.shell/functions/git-worktree.sh"
[ -r "$HOME/.shell/functions/ghq.sh" ] && . "$HOME/.shell/functions/ghq.sh"

if command -v fzf >/dev/null 2>&1; then
  eval "$(fzf --bash)"
fi

[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"

# 組織固有設定・ツールの自動追記はローカル設定へ
# shellcheck source=/dev/null
[ -r "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
