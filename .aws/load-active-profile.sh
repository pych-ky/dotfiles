# ============================================================================
# aws-use / aws-env で保存した AWS プロファイルを復元するスクリプト
# ============================================================================

_aws_active_profile_file="${HOME}/.aws/active-profile"

if [ -r "$_aws_active_profile_file" ] &&
  command -v __aws_has_credential_provider >/dev/null 2>&1 &&
  ! __aws_has_credential_provider; then
  # 末尾改行なしのファイルでも read は内容を代入してから非 0 を返すため、読めた内容は保持する
  _aws_active_profile=
  IFS= read -r _aws_active_profile <"$_aws_active_profile_file" || true

  if [ -n "$_aws_active_profile" ]; then
    export AWS_PROFILE="$_aws_active_profile"
  fi
fi

unset _aws_active_profile_file _aws_active_profile
