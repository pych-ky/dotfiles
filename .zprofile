# Zsh ログインシェル設定

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

typeset -U path PATH
path=("$HOME/.local/bin" $path)

if [[ -r "$HOME/.orbstack/shell/init.zsh" ]]; then
  . "$HOME/.orbstack/shell/init.zsh"
fi

# 非対話ログインでもプロジェクトの指定版を選ぶ
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh --shims)"
fi
