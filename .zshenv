# aws-use / aws-clear の読み込み
[ -r "$HOME/.shell/functions/aws.sh" ] && . "$HOME/.shell/functions/aws.sh"

# 保存済み AWS プロファイルの読み込み
[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"

# 組織固有・個人の環境変数の受け皿 (非公開側が配置する。無い間は無視される)。
# 対話シェル向けの設定は .zshrc が読む ~/.zshrc.local 側に置く
[ -r "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
