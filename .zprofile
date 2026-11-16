# Zsh ログインシェル設定

eval "$(/opt/homebrew/bin/brew shellenv)"

typeset -U path PATH
export PATH="$HOME/.local/bin:$PATH"

if [[ -r "$HOME/.orbstack/shell/init.zsh" ]]; then
  . "$HOME/.orbstack/shell/init.zsh"
fi

# 非対話ログインでもプロジェクトの指定版を選ぶ
eval "$(mise activate zsh --shims)"
