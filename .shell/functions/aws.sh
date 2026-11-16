# AWS プロファイル切り替え

# Claude Code の shell snapshot に含めるため __aws_* 名を使う

# 認証プロバイダーの環境変数名を列挙
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

# 空でない認証プロバイダー変数を確認
__aws_has_credential_provider() {
  local variable

  while IFS= read -r variable; do
    # 秘密値を展開せず、空でない変数の有無だけ確認
    eval "[ \"\${$variable:+x}\" = x ]" && return 0
  done < <(__aws_credential_provider_variables)

  return 1
}

# 認証プロバイダーの環境変数を解除
__aws_clear_credentials() {
  local variable

  while IFS= read -r variable; do
    unset "$variable"
  done < <(__aws_credential_provider_variables)
}

# 認証プロバイダーを外したサブシェルで実行
__aws_run_without_credentials() (
  __aws_clear_credentials
  "$@"
)

# SSO ログイン後にプロファイルを切り替え・保存
aws-use() {
  local profile="${1:?使い方: aws-use <profile>}"

  __aws_run_without_credentials aws sso login --profile "$profile" || return
  AWS_PAGER='' __aws_run_without_credentials aws sts get-caller-identity --profile "$profile" || return
  # 次回起動時に load-active-profile.sh が復元
  printf '%s\n' "$profile" >"$HOME/.aws/active-profile" || return
  __aws_clear_credentials
  export AWS_PROFILE="$profile"
}

# 認証プロバイダーと保存済みプロファイルを解除
aws-clear() {
  __aws_clear_credentials
  rm -f "$HOME/.aws/active-profile"
}
