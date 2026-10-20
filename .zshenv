# Zsh 共通環境設定

[ -r "$HOME/.shell/functions/aws.sh" ] && . "$HOME/.shell/functions/aws.sh"

[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"

# 組織・個人の環境変数は非公開側へ。対話設定は ~/.zshrc.local
[ -r "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
