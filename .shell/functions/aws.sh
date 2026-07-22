# ============================================================================
# AWS SSO プロファイルを切り替えて永続化するシェル関数
# ============================================================================

# Claude Code のシェルスナップショットで除外されないよう __aws_* 名にする

# 二重読み込みの防止
[ -n "${__AWS_FUNCTIONS_LOADED:-}" ] && return
__AWS_FUNCTIONS_LOADED=1

# credential provider として扱う AWS 環境変数を列挙
__aws_credential_provider_variables() {
  printf '%s\n' \
    AWS_PROFILE \
    AWS_DEFAULT_PROFILE \
    AWS_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY \
    AWS_SESSION_TOKEN \
    AWS_SECURITY_TOKEN \
    AWS_CREDENTIAL_EXPIRATION \
    AWS_ROLE_ARN \
    AWS_WEB_IDENTITY_TOKEN_FILE \
    AWS_ROLE_SESSION_NAME \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
    AWS_CONTAINER_CREDENTIALS_FULL_URI \
    AWS_CONTAINER_AUTHORIZATION_TOKEN \
    AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
}

# credential provider 環境変数の設定有無を判定
__aws_has_credential_provider() {
  local variable
  local value

  while IFS= read -r variable; do
    eval "value=\${$variable-}"
    [ -z "$value" ] || return 0
  done < <(__aws_credential_provider_variables)

  return 1
}

# credential provider 環境変数を全消去
__aws_clear_credentials() {
  local clear_status=0
  local variable

  while IFS= read -r variable; do
    unset "$variable" || clear_status=1
  done < <(__aws_credential_provider_variables)

  return "$clear_status"
}

# credential provider を除外したサブシェルでコマンドを実行
__aws_run_without_credentials() (
  __aws_clear_credentials || exit
  "$@"
)

# AWS_PROFILE 候補だけを使って疎通を確認
__aws_verify_profile_credentials() (
  local profile="$1"

  __aws_clear_credentials || exit
  AWS_PROFILE="$profile" AWS_PAGER='' aws sts get-caller-identity
)

# export-credentials の候補を現在の shell へ設定
__aws_set_env_credentials() {
  local access_key_id="$1"
  local secret_access_key="$2"
  local session_token="$3"
  local expiration="$4"

  export AWS_ACCESS_KEY_ID="$access_key_id"
  export AWS_SECRET_ACCESS_KEY="$secret_access_key"
  export AWS_SESSION_TOKEN="$session_token"
  if [ -n "$expiration" ]; then
    export AWS_CREDENTIAL_EXPIRATION="$expiration"
  fi
}

# 環境変数方式の候補だけを使って疎通を確認
__aws_verify_env_credentials() (
  __aws_clear_credentials || exit
  __aws_set_env_credentials "$@"
  AWS_PAGER='' aws sts get-caller-identity
)

# 指定プロファイルが AWS SSO 用に設定済みかを検証
__aws_require_sso_profile() {
  local profile="${1:?usage: __aws_require_sso_profile <profile>}"
  local sso_session
  local sso_start_url

  sso_session="$(__aws_run_without_credentials \
    aws configure get sso_session --profile "$profile" 2>/dev/null)" || sso_session=
  sso_start_url="$(__aws_run_without_credentials \
    aws configure get sso_start_url --profile "$profile" 2>/dev/null)" || sso_start_url=

  if [ -z "$sso_session$sso_start_url" ]; then
    printf 'aws-use: %s is not configured as an AWS SSO profile\n' "$profile" >&2
    return 2
  fi
}

# 次回シェル起動時に復元できるよう、アクティブなプロファイル名をファイルへ保存
__aws_persist_active_profile() {
  local profile="${1:?usage: __aws_persist_active_profile <profile>}"
  local file="$HOME/.aws/active-profile"
  local directory
  local temporary

  directory="$(dirname "$file")"
  mkdir -p "$directory" || return
  temporary="$(mktemp "$directory/.active-profile.XXXXXX")" || return

  if [ -d "$file" ] ||
    ! printf '%s\n' "$profile" >"$temporary" ||
    ! mv -f "$temporary" "$file"; then
    rm -f "$temporary"
    return 1
  fi
}

# SSO 検証・ログイン・疎通確認・永続化の共通フロー
__aws_login_sso_profile() {
  local profile="${1:?usage: __aws_login_sso_profile <profile> <credential-mode>}"
  local credential_mode="${2:?usage: __aws_login_sso_profile <profile> <credential-mode>}"
  local credentials
  local candidate_access_key_id=
  local candidate_secret_access_key=
  local candidate_session_token=
  local candidate_expiration=
  local line

  if ! command -v aws >/dev/null 2>&1; then
    printf 'aws: aws CLI not found\n' >&2
    return 127
  fi

  case "$credential_mode" in
  profile | env) ;;
  *)
    printf 'aws: unknown credential mode: %s\n' "$credential_mode" >&2
    return 2
    ;;
  esac

  __aws_require_sso_profile "$profile" || return
  __aws_run_without_credentials aws sso login --profile "$profile" || return

  case "$credential_mode" in
  profile)
    # 候補の疎通確認後に永続化し、現在の shell へ反映
    __aws_verify_profile_credentials "$profile" || return
    __aws_persist_active_profile "$profile" || return
    __aws_clear_credentials || return
    export AWS_PROFILE="$profile"
    ;;
  env)
    credentials="$(__aws_run_without_credentials \
      aws configure export-credentials --profile "$profile" --format env)" || return

    # AWS CLI の既知の代入だけを受理し、eval しない
    while IFS= read -r line; do
      case "$line" in
      'export AWS_ACCESS_KEY_ID='*)
        candidate_access_key_id="${line#export AWS_ACCESS_KEY_ID=}"
        ;;
      'export AWS_SECRET_ACCESS_KEY='*)
        candidate_secret_access_key="${line#export AWS_SECRET_ACCESS_KEY=}"
        ;;
      'export AWS_SESSION_TOKEN='*)
        candidate_session_token="${line#export AWS_SESSION_TOKEN=}"
        ;;
      'export AWS_CREDENTIAL_EXPIRATION='*)
        candidate_expiration="${line#export AWS_CREDENTIAL_EXPIRATION=}"
        ;;
      '') ;;
      *)
        printf 'aws: export-credentials returned unexpected output\n' >&2
        return 1
        ;;
      esac
    done <<EOF
$credentials
EOF

    if [ -z "$candidate_access_key_id" ] ||
      [ -z "$candidate_secret_access_key" ] ||
      [ -z "$candidate_session_token" ]; then
      printf 'aws: export-credentials returned incomplete credentials\n' >&2
      return 1
    fi

    # 候補の疎通確認後に永続化し、現在の shell へ反映
    __aws_verify_env_credentials \
      "$candidate_access_key_id" \
      "$candidate_secret_access_key" \
      "$candidate_session_token" \
      "$candidate_expiration" || return
    __aws_persist_active_profile "$profile" || return
    __aws_clear_credentials || return
    __aws_set_env_credentials \
      "$candidate_access_key_id" \
      "$candidate_secret_access_key" \
      "$candidate_session_token" \
      "$candidate_expiration"
    ;;
  esac
}

# 認証情報の解決を SDK 側に任せ、AWS_PROFILE 方式で SSO ログイン
aws-use() {
  local profile="${1:?usage: aws-use <profile>}"

  __aws_login_sso_profile "$profile" profile
}

# AWS_PROFILE 非対応ツール向けに環境変数方式で SSO ログイン
aws-env() {
  local profile="${1:?usage: aws-env <profile>}"

  __aws_login_sso_profile "$profile" env
}

# 明示的な credential provider と永続化ファイルを削除
aws-clear() {
  local clear_status=0

  __aws_clear_credentials || clear_status=1
  rm -f "$HOME/.aws/active-profile" || clear_status=1
  return "$clear_status"
}
