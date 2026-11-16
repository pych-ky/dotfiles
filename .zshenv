# Zsh 共通環境設定

. "$HOME/.shell/functions/aws.sh"

. "$HOME/.aws/load-active-profile.sh"

# 組織・個人の環境変数は非公開側へ。対話設定は ~/.zshrc.local
[ -r "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
