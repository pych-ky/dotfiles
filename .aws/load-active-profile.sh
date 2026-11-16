# AWS プロファイルの復元

if [ -r "$HOME/.aws/active-profile" ] && ! __aws_has_credential_provider; then
  IFS= read -r _aws_active_profile <"$HOME/.aws/active-profile"
  if [ -n "$_aws_active_profile" ]; then
    export AWS_PROFILE="$_aws_active_profile"
  fi
  unset _aws_active_profile
fi
