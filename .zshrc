# Homebrew の PATH と HOMEBREW_PREFIX を反映 (Apple Silicon: /opt/homebrew, Intel: /usr/local)
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# typeset -U で path / PATH の重複要素を自動的に除去
typeset -U path PATH
path=(
  "$HOME/.local/bin"                                 # ユーザーローカルのバイナリ (常に追加)
  ${HOMEBREW_PREFIX:-/usr/local}/opt/git/bin(N-/)    # Homebrew 版 git (存在時のみ)
  ${HOMEBREW_PREFIX:-/usr/local}/opt/libpq/bin(N-/)  # keg-only の libpq (psql など、存在時のみ)
  $path
)

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
unset f
