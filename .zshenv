# aws-use で選んだ AWS プロファイルを新しいシェルでも自動復元
# (GUI アプリ等の非対話シェルにも反映させたいので .zshrc ではなく .zshenv に配置)
[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"
