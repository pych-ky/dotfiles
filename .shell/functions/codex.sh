# ブラウザ拡張のモデル設定と CLI の設定を分ける
codex() {
  local arg skip_value=0 skip_images=0 subcommand="" has_profile=0
  local -a embedded_args=(--no-daemon)
  for arg in "$@"; do
    case "$arg" in
    --) break ;;
    --no-daemon | --remote | --remote=*) embedded_args=() ;;
    --profile | --profile=* | -p | -p?*)
      has_profile=1
      ;;
    esac
  done

  if [ "$has_profile" = 1 ]; then
    command codex "${embedded_args[@]}" "$@"
    return $?
  fi

  for arg in "$@"; do
    if [ "$skip_images" = 1 ]; then
      # 空白で渡した画像は、次のオプションまで複数の値を受け取る
      case "$arg" in
      -*) skip_images=0 ;;
      *) continue ;;
      esac
    fi
    if [ "$skip_value" = 1 ]; then
      skip_value=0
      continue
    fi
    case "$arg" in
    --) break ;;
    -i | --image) skip_images=1 ;;
    -c | --config | --enable | --disable | --remote | --remote-auth-token-env | -m | --model | --local-provider | -s | --sandbox | -C | --cd | --add-dir | -a | --ask-for-approval)
      skip_value=1
      ;;
    -*) ;;
    *)
      subcommand="$arg"
      break
      ;;
    esac
  done

  case "$subcommand" in
  agents | login | logout | plugin | app-server | remote-control | app | completion | update | doctor | features | help | debug | exec-server | cloud | apply | a | migrate-rollouts)
    command codex "$@"
    ;;
  *) command codex "${embedded_args[@]}" --profile cli "$@" ;;
  esac
}
