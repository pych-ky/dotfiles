# bash はログインシェルだと .bashrc を読まないので明示的にロード
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
