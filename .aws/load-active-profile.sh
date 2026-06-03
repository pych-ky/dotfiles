# ============================================================================
# aws-use で保存した AWS プロファイルを復元するスクリプト
# ============================================================================

_aws_active_profile_file="${HOME}/.aws/active-profile"

if [ -r "$_aws_active_profile_file" ] &&
  [ -z "${AWS_PROFILE:-}" ] &&
  [ -z "${AWS_ACCESS_KEY_ID:-}" ] &&
  [ -z "${AWS_SECRET_ACCESS_KEY:-}" ] &&
  [ -z "${AWS_SESSION_TOKEN:-}" ]; then
  IFS= read -r _aws_active_profile <"$_aws_active_profile_file" || _aws_active_profile=

  if [ -n "$_aws_active_profile" ]; then
    export AWS_PROFILE="$_aws_active_profile"
  fi
fi

unset _aws_active_profile_file _aws_active_profile
