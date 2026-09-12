[ -r "$HOME/.shell/functions/aws.sh" ] && . "$HOME/.shell/functions/aws.sh"

[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"

# 非公開側で配置する、組織固有・個人の環境変数
# 対話シェル向けの設定は .zshrc が読む ~/.zshrc.local 側に置く
[ -r "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
