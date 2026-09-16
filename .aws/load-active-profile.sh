# aws-use で保存した AWS プロファイルを復元

_aws_active_profile_file="${HOME}/.aws/active-profile"

if [ -r "$_aws_active_profile_file" ] &&
  command -v __aws_has_credential_provider >/dev/null 2>&1 &&
  ! __aws_has_credential_provider; then
  # 末尾改行がなくても読み取った値を保持
  _aws_active_profile=
  IFS= read -r _aws_active_profile <"$_aws_active_profile_file" || true

  if [ -n "$_aws_active_profile" ]; then
    export AWS_PROFILE="$_aws_active_profile"
  fi
fi

unset _aws_active_profile_file _aws_active_profile
