# AWS SSO プロファイルを永続化し、一時認証情報の解決は AWS SDK に任せる
# Claude Code の shell snapshot に含めるため __aws_* 名を使う

[ -n "${__AWS_FUNCTIONS_LOADED:-}" ] && return
__AWS_FUNCTIONS_LOADED=1

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

__aws_has_credential_provider() {
  local variable

  while IFS= read -r variable; do
    # 値を展開せず、空でない変数の有無だけを確認
    eval "[ \"\${$variable:+x}\" = x ]" && return 0
  done < <(__aws_credential_provider_variables)

  return 1
}

__aws_clear_credentials() {
  local clear_status=0
  local variable

  while IFS= read -r variable; do
    unset "$variable" || clear_status=1
  done < <(__aws_credential_provider_variables)

  return "$clear_status"
}

__aws_run_without_credentials() (
  __aws_clear_credentials || exit
  "$@"
)

__aws_verify_profile_credentials() (
  local profile="$1"

  __aws_clear_credentials || exit
  AWS_PROFILE="$profile" AWS_PAGER='' aws sts get-caller-identity
)

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

# 次回のシェル起動用にプロファイル名を保存
__aws_persist_active_profile() {
  local profile="${1:?usage: __aws_persist_active_profile <profile>}"
  local file="$HOME/.aws/active-profile"
  local directory="${file%/*}"
  local temporary

  mkdir -p "$directory" || return
  temporary="$(mktemp "$directory/.active-profile.XXXXXX")" || return

  if [ -d "$file" ] ||
    ! printf '%s\n' "$profile" >"$temporary" ||
    ! mv -f "$temporary" "$file"; then
    rm -f "$temporary"
    return 1
  fi
}

aws-use() {
  local profile="${1:?usage: aws-use <profile>}"

  if ! command -v aws >/dev/null 2>&1; then
    printf 'aws: aws CLI not found\n' >&2
    return 127
  fi

  __aws_require_sso_profile "$profile" || return
  __aws_run_without_credentials aws sso login --profile "$profile" || return

  __aws_verify_profile_credentials "$profile" || return
  __aws_persist_active_profile "$profile" || return
  __aws_clear_credentials || return
  export AWS_PROFILE="$profile"
}

aws-clear() {
  local clear_status=0

  __aws_clear_credentials || clear_status=1
  rm -f "$HOME/.aws/active-profile" || clear_status=1
  return "$clear_status"
}
