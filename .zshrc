if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# PATH の重複を除き、(N-/) は既存ディレクトリだけ追加
typeset -U path PATH
path=(
  "$HOME/.local/bin"
  ${HOMEBREW_PREFIX:-/usr/local}/opt/git/bin(N-/)
  ${HOMEBREW_PREFIX:-/usr/local}/opt/libpq/bin(N-/) # keg-only の libpq (psql など)
  $HOME/.rd/bin(N-/)                                # Rancher Desktop の CLI
  $path
)

if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi

if [[ "$TERM" != "dumb" ]] && command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"

for f in "$HOME"/.zsh/plugins/*/*.plugin.zsh(N); do
  . "$f"
done
unset f

[[ -r "$HOME/.shell/functions/git-worktree.sh" ]] && . "$HOME/.shell/functions/git-worktree.sh"
[[ -r "$HOME/.shell/functions/ghq.sh" ]] && . "$HOME/.shell/functions/ghq.sh"

if command -v fzf >/dev/null 2>&1; then
  . <(fzf --zsh)
  _cghq_widget() {
    cghq
    zle reset-prompt
  }
  zle -N _cghq_widget
  bindkey '^G' _cghq_widget
fi

# 組織固有設定・ツールの自動追記はローカル設定へ
[[ -r "$HOME/.zshrc.local" ]] && . "$HOME/.zshrc.local"
