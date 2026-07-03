# ~/.local/bin と Homebrew Git を標準 PATH より優先
for dir in /usr/local/opt/git/bin "$HOME/.local/bin"; do
  [ -d "$dir" ] || continue
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
done
unset dir
export PATH

# asdf を初期化して shim を PATH に反映
[ -r /usr/local/opt/asdf/libexec/asdf.sh ] && . /usr/local/opt/asdf/libexec/asdf.sh

# aws-use / aws-env / aws-clear の読み込み
[ -r "$HOME/.shell/functions/aws.sh" ] && . "$HOME/.shell/functions/aws.sh"

# 保存済み AWS プロファイルの読み込み
[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"
