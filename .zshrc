# typeset -U で path / PATH の重複要素を自動的に除去
typeset -U path PATH
path=(
  "$HOME/.local/bin"        # ユーザーローカルのバイナリ
  /usr/local/opt/git/bin    # Homebrew 版 git
  $path
)

# バージョン管理ツール asdf
[ -r /usr/local/opt/asdf/libexec/asdf.sh ] && . /usr/local/opt/asdf/libexec/asdf.sh

# dumb ターミナル以外で starship プロンプトを初期化
if [[ "$TERM" != "dumb" ]] && command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

# cd 拡張 zoxide
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"

# 外部 zsh プラグインの一括ロード
for f in "$HOME"/.zsh/plugins/*/*.plugin.zsh(N); do
  . "$f"
done

# 自作シェル関数の一括ロード
for f in "$HOME"/.zsh/functions/*.zsh(N); do
  . "$f"
done
