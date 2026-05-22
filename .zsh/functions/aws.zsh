_aws_active_profile_file="$HOME/.aws/active-profile"

_aws_clear_credentials() {
  unset AWS_PROFILE
  unset AWS_ACCESS_KEY_ID
  unset AWS_SECRET_ACCESS_KEY
  unset AWS_SESSION_TOKEN
  unset AWS_SECURITY_TOKEN
  unset AWS_CREDENTIAL_EXPIRATION
}

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

_aws_persist_active_profile() {
  local profile="${1:?usage: _aws_persist_active_profile <profile>}"

  mkdir -p "${_aws_active_profile_file:h}"
  printf '%s\n' "$profile" > "$_aws_active_profile_file"
}

aws-use() {
  local profile="${1:?usage: aws-use <profile>}"

  _aws_require_sso_profile "$profile" || return
  _aws_clear_credentials

  aws sso login --profile "$profile" || return
  export AWS_PROFILE="$profile"
  AWS_PAGER= aws sts get-caller-identity || return
  _aws_persist_active_profile "$profile"
}

aws-env() {
  local profile="${1:?usage: aws-env <profile>}"

  _aws_require_sso_profile "$profile" || return
  _aws_clear_credentials

  aws sso login --profile "$profile" >/dev/null || return
  eval "$(aws configure export-credentials --profile "$profile" --format env)" || return
  AWS_PAGER= aws sts get-caller-identity || return
  _aws_persist_active_profile "$profile"
}

aws-clear() {
  _aws_clear_credentials
  rm -f "$_aws_active_profile_file"
}
