#!/usr/bin/env bash

printf 'call\n' >>"$JQ_COUNT_FILE"
exec "$REAL_JQ" "$@"
