[ -r "$HOME/.shell/functions/aws.sh" ] && . "$HOME/.shell/functions/aws.sh"

[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"

# 組織固有・個人の環境変数を非公開側から配置。対話用設定は ~/.zshrc.local へ
[ -r "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
