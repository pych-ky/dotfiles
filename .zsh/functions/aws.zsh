# ============================================================================
# AWS SSO プロファイルの切り替えと永続化を行うシェル関数
# ============================================================================

# 現在アクティブな AWS プロファイル名を永続化するファイル
_aws_active_profile_file="$HOME/.aws/active-profile"

# プロファイル切替時に古い認証情報が残らないよう AWS 関連環境変数を全消去
_aws_clear_credentials() {
  unset AWS_PROFILE
  unset AWS_ACCESS_KEY_ID
  unset AWS_SECRET_ACCESS_KEY
  unset AWS_SESSION_TOKEN
  unset AWS_SECURITY_TOKEN
  unset AWS_CREDENTIAL_EXPIRATION
}

# 指定プロファイルが AWS SSO 用に設定済みかを検証
_aws_require_sso_profile() {
  local profile="${1:?usage: _aws_require_sso_profile <profile>}"
  local sso_session
  local sso_start_url

  sso_session="$(aws configure get sso_session --profile "$profile" 2>/dev/null)"
  sso_start_url="$(aws configure get sso_start_url --profile "$profile" 2>/dev/null)"

  if [ -z "$sso_session$sso_start_url" ]; then
    printf 'aws-use: %s is not configured as an AWS SSO profile\n' "$profile" >&2
    return 2
  fi
}

# 次回シェル起動時に復元できるよう、アクティブなプロファイル名をファイルへ保存
_aws_persist_active_profile() {
  local profile="${1:?usage: _aws_persist_active_profile <profile>}"

  mkdir -p "${_aws_active_profile_file:h}"
  printf '%s\n' "$profile" > "$_aws_active_profile_file"
}

# 認証情報の解決を SDK 側に任せ、AWS_PROFILE 方式で SSO ログイン
aws-use() {
  local profile="${1:?usage: aws-use <profile>}"

  _aws_require_sso_profile "$profile" || return
  _aws_clear_credentials

  aws sso login --profile "$profile" || return
  export AWS_PROFILE="$profile"
  # ページャを無効化してログイン成功を確認
  AWS_PAGER= aws sts get-caller-identity || return
  _aws_persist_active_profile "$profile"
}

# AWS_PROFILE 非対応ツール向けに環境変数方式で SSO ログイン
aws-env() {
  local profile="${1:?usage: aws-env <profile>}"

  _aws_require_sso_profile "$profile" || return
  _aws_clear_credentials

  aws sso login --profile "$profile" >/dev/null || return
  # configure export-credentials の env 形式出力を eval で環境変数化
  eval "$(aws configure export-credentials --profile "$profile" --format env)" || return
  AWS_PAGER= aws sts get-caller-identity || return
  _aws_persist_active_profile "$profile"
}

# 認証情報と永続化ファイルを削除して未認証状態へリセット
aws-clear() {
  _aws_clear_credentials
  rm -f "$_aws_active_profile_file"
}
