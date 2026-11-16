# Zsh 対話シェル設定

HISTSIZE=100000
SAVEHIST=100000
setopt SHARE_HISTORY

eval "$(/opt/homebrew/bin/brew shellenv)"

# (N-/) は既存ディレクトリだけ追加
typeset -U path PATH
path=(
  $HOME/.local/bin
  $HOMEBREW_PREFIX/opt/git/bin(N-/)
  $HOMEBREW_PREFIX/opt/libpq/bin(N-/)  # keg-only の libpq
  $HOME/.orbstack/bin(N-/)
  $path
)

eval "$(mise activate zsh)"

if [[ "$TERM" != "dumb" ]]; then
  eval "$(starship init zsh)"
fi

eval "$(zoxide init zsh)"

for f in "$HOME"/.zsh/plugins/*/*.plugin.zsh(N); do
  . "$f"
done
unset f

. "$HOME/.shell/functions/git-worktree.sh"
. "$HOME/.shell/functions/ghq.sh"
. "$HOME/.shell/functions/codex.sh"
. "$HOME/.shell/functions/claude.sh"

. <(fzf --zsh)
# cghq 後にプロンプトを再描画
_cghq_widget() {
  cghq
  zle reset-prompt
}
zle -N _cghq_widget
bindkey '^G' _cghq_widget

# Karabiner の Home/End → Ctrl+Home/End を行頭・行末へ割り当て
bindkey '^[[1;5H' beginning-of-line
bindkey '^[[1;5F' end-of-line
# Orca 向け Karabiner 変換（Cmd+Delete → Option+Delete）を次の単語削除へ
bindkey '^[[3;3~' kill-word

# 組織設定・ツールの自動追記はローカル設定へ
[[ -r "$HOME/.zshrc.local" ]] && . "$HOME/.zshrc.local"
