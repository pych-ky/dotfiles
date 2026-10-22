# Bash ログインシェル設定

[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"

# 非対話ログインでもプロジェクトの指定版を選ぶ
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash --shims)"
fi
