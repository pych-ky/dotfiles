# Zsh ログインシェル設定

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

typeset -U path PATH
path=("$HOME/.local/bin" $path)

# OrbStack が生成する CLI・補完設定を読み込む
if [[ -r "$HOME/.orbstack/shell/init.zsh" ]]; then
  . "$HOME/.orbstack/shell/init.zsh"
fi
