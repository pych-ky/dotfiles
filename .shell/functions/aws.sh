# ============================================================================
# AWS SSO プロファイルを切り替えて永続化するシェル関数
# ============================================================================
#
# 扱うのは AWS_PROFILE (プロファイル名) だけで、一時認証情報そのものは
# シェルへ持ち込まない。解決は AWS SDK 側に任せる。
#
# 以前あった aws-env は aws configure export-credentials の結果を
# AWS_ACCESS_KEY_ID などへ export していた。値がシェルの環境に載ると、
# そこから起動する AI エージェントの子プロセスへそのまま渡るため廃止した。
# AWS_PROFILE 非対応ツールは、最終的には外部の署名ブローカーか認証済みの
# 隔離 runner 経由で扱う (未実装。SECURITY.md「未完了の対策」を参照)。

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

  while IFS= read -r variable; do
    # 値そのものは展開せず、空でない変数だけを provider とみなす。
    eval "[ \"\${$variable:+x}\" = x ]" && return 0
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

# 認証情報の解決を SDK 側に任せ、AWS_PROFILE 方式で SSO ログイン
aws-use() {
  local profile="${1:?usage: aws-use <profile>}"

  if ! command -v aws >/dev/null 2>&1; then
    printf 'aws: aws CLI not found\n' >&2
    return 127
  fi

  __aws_require_sso_profile "$profile" || return
  __aws_run_without_credentials aws sso login --profile "$profile" || return

  # 候補の疎通確認後に永続化し、現在の shell へ反映
  __aws_verify_profile_credentials "$profile" || return
  __aws_persist_active_profile "$profile" || return
  __aws_clear_credentials || return
  export AWS_PROFILE="$profile"
}

# 明示的な credential provider と永続化ファイルを削除
aws-clear() {
  local clear_status=0

  __aws_clear_credentials || clear_status=1
  rm -f "$HOME/.aws/active-profile" || clear_status=1
  return "$clear_status"
}
