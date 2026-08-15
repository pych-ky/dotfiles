#!/usr/bin/env bash

set -eu

printf '%s\n' "$1" >>"$INSTALL_LOG"
if [[ "$1" == --capabilities ]]; then
  [[ "$CAPABILITY_MODE" == supported ]] || exit 2
  printf 'install-all\n'
fi
