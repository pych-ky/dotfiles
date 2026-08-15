#!/usr/bin/env bash

set -eu

mv "$LOCK_SWAP_PATH" "$LOCK_SWAP_PATH.opened"
: >"$LOCK_SWAP_PATH"
