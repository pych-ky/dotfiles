# PATH
typeset -U path PATH
path=(
  "$HOME/.local/bin"
  /usr/local/opt/git/bin
  $path
)

# Runtime/tool initializers
[ -r /usr/local/opt/asdf/libexec/asdf.sh ] && . /usr/local/opt/asdf/libexec/asdf.sh
if [[ "$TERM" != "dumb" ]] && command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"

# zsh plugins
for plugin in \
  "$HOME/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh" \
  "$HOME/.zsh/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"; do
  [ -r "$plugin" ] && . "$plugin"
done

# Custom functions
for f in "$HOME"/.zsh/functions/*.zsh(N); do
  . "$f"
done
