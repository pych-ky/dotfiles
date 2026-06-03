# aws-use / aws-env / aws-clear の読み込み
[ -r "$HOME/.shell/functions/aws.sh" ] && . "$HOME/.shell/functions/aws.sh"

# 保存済み AWS プロファイルの読み込み
[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"
