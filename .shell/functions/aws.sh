# ============================================================================
# AWS SSO プロファイルを切り替えて永続化するシェル関数
# ============================================================================

# Claude Code のシェルスナップショットで除外されないよう __aws_* 名にする

# 二重読み込みの防止
[ -n "${__AWS_FUNCTIONS_LOADED:-}" ] && return
__AWS_FUNCTIONS_LOADED=1

# プロファイル切替時に古い認証情報が残らないよう AWS 関連環境変数を全消去
__aws_clear_credentials() {
  unset AWS_PROFILE \
    AWS_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY \
    AWS_SESSION_TOKEN \
    AWS_SECURITY_TOKEN \
    AWS_CREDENTIAL_EXPIRATION
}

# 指定プロファイルが AWS SSO 用に設定済みかを検証
__aws_require_sso_profile() {
  local profile="${1:?usage: __aws_require_sso_profile <profile>}"
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
__aws_persist_active_profile() {
  local profile="${1:?usage: __aws_persist_active_profile <profile>}"
  local file="$HOME/.aws/active-profile"

  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$profile" > "$file"
}

# SSO 検証・ログイン・疎通確認・永続化の共通フロー
__aws_login_sso_profile() {
  local profile="${1:?usage: __aws_login_sso_profile <profile> <credential-mode>}"
  local credential_mode="${2:?usage: __aws_login_sso_profile <profile> <credential-mode>}"

  if ! command -v aws >/dev/null 2>&1; then
    printf 'aws: aws CLI not found\n' >&2
    return 127
  fi

  __aws_require_sso_profile "$profile" || return
  __aws_clear_credentials

  # credential-mode に応じて AWS_PROFILE または環境変数へ認証情報を反映
  case "$credential_mode" in
    profile)
      aws sso login --profile "$profile" || return
      export AWS_PROFILE="$profile"
      ;;
    env)
      aws sso login --profile "$profile" || return
      # コマンド置換の終了コードは eval に伝わらないため、一旦変数に受けて失敗を検知する
      local credentials
      credentials="$(aws configure export-credentials --profile "$profile" --format env)" || return
      eval "$credentials"
      ;;
    *)
      printf 'aws: unknown credential mode: %s\n' "$credential_mode" >&2
      return 2
      ;;
  esac

  # ページャを無効化してログイン成功を確認
  AWS_PAGER= aws sts get-caller-identity || return
  __aws_persist_active_profile "$profile"
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

# 認証情報と永続化ファイルを削除して未認証状態へリセット
aws-clear() {
  __aws_clear_credentials
  rm -f "$HOME/.aws/active-profile"
}
