# Zsh 対話シェル設定

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# (N-/) は既存ディレクトリだけ追加
typeset -U path PATH
path=(
  "$HOME/.local/bin"
  ${HOMEBREW_PREFIX:-/usr/local}/opt/git/bin(N-/)
  ${HOMEBREW_PREFIX:-/usr/local}/opt/libpq/bin(N-/)  # keg-only の libpq
  $HOME/.orbstack/bin(N-/)
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
[[ -r "$HOME/.shell/functions/codex.sh" ]] && . "$HOME/.shell/functions/codex.sh"
[[ -r "$HOME/.shell/functions/claude.sh" ]] && . "$HOME/.shell/functions/claude.sh"

if command -v fzf >/dev/null 2>&1; then
  . <(fzf --zsh)
  # cghq 後にプロンプトを再描画
  _cghq_widget() {
    cghq
    zle reset-prompt
  }
  zle -N _cghq_widget
  bindkey '^G' _cghq_widget
fi

# Karabiner の Home/End → Ctrl+Home/End を行頭・行末へ割り当て
bindkey '^[[1;5H' beginning-of-line
bindkey '^[[1;5F' end-of-line
# Orca 向け Karabiner 変換（Cmd+Delete → Option+Delete）を次の単語削除へ
bindkey '^[[3;3~' kill-word

# 組織設定・ツールの自動追記はローカル設定へ
[[ -r "$HOME/.zshrc.local" ]] && . "$HOME/.zshrc.local"
