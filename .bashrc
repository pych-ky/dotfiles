# 優先したいディレクトリを PATH の先頭に追加し、重複は回避
for dir in "$HOME/.local/bin" /usr/local/opt/git/bin; do
  [ -d "$dir" ] || continue
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
done
export PATH

# バージョン管理ツール asdf
[ -r /usr/local/opt/asdf/libexec/asdf.sh ] && . /usr/local/opt/asdf/libexec/asdf.sh

# aws-use で選んだ AWS プロファイルを新しいシェルでも自動復元
[ -r "$HOME/.aws/load-active-profile.sh" ] && . "$HOME/.aws/load-active-profile.sh"
