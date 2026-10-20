# Codex CLI プロファイル設定

# ブラウザ拡張と CLI のモデル設定を分離
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
      # 空白区切りの画像値は次のオプションまで続く
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
