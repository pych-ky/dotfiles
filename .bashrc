# Bash 対話シェル設定

eval "$(/opt/homebrew/bin/brew shellenv)"

# PATH 優先順: ~/.local/bin → Homebrew Git → OrbStack
for dir in "$HOME/.orbstack/bin" "$HOMEBREW_PREFIX/opt/git/bin" "$HOME/.local/bin"; do
  [ -d "$dir" ] || continue
  case ":$PATH:" in
  *":$dir:"*) ;;
  *) PATH="$dir:$PATH" ;;
  esac
done
unset dir

eval "$(mise activate bash)"

. "$HOME/.shell/functions/aws.sh"

. "$HOME/.shell/functions/git-worktree.sh"
. "$HOME/.shell/functions/ghq.sh"
. "$HOME/.shell/functions/codex.sh"
. "$HOME/.shell/functions/claude.sh"

eval "$(fzf --bash)"

. "$HOME/.aws/load-active-profile.sh"

# 組織設定・ツールの自動追記はローカル設定へ
# shellcheck source=/dev/null
[ -r "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
