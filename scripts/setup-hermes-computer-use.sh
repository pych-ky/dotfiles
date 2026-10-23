#!/usr/bin/env bash
# Hermes PM と macOS の権限要求で使う CuaDriver を揃える

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'error: scripts/setup-hermes-computer-use.sh supports macOS only\n' >&2
  exit 1
fi

hermes computer-use install

cua_app="$(hermes pm env cua-driver | /usr/bin/python3 -c '
import json
from pathlib import Path
import shutil
import sys

path = json.load(sys.stdin).get("PATH")
binary = shutil.which("cua-driver", path=path) if path else None
if not binary:
    sys.exit("error: Hermes PM has no installed cua-driver")
app = Path(binary).resolve().parents[2]
if app.name != "CuaDriver.app":
    sys.exit("error: Hermes PM did not select CuaDriver.app")
print(app)
')"
cua_destination=/Applications/CuaDriver.app
cua_requirement='=anchor apple generic and identifier "com.trycua.driver" and certificate leaf[subject.OU] = "YCK386LBJ7"'

/usr/bin/codesign --verify --deep --strict -R "$cua_requirement" "$cua_app"
if [[ -L "$cua_destination" ]]; then
  printf 'error: CuaDriver destination must not be a symlink\n' >&2
  exit 1
fi
if [[ -e "$cua_destination" ]]; then
  /usr/bin/codesign --verify --deep --strict -R "$cua_requirement" "$cua_destination"
fi

# CuaDriver の権限要求は /Applications のバンドルを起動する
if ! /usr/bin/diff -qr "$cua_app" "$cua_destination" >/dev/null 2>&1; then
  cua_temporary="$(mktemp -d /Applications/.hermes-cua.XXXXXX)"
  # 置換失敗時は元のアプリを復元し、一時ディレクトリを削除
  cleanup_cua() {
    if [[ -d "$cua_temporary/previous.app" && ! -e "$cua_destination" ]]; then
      mv -- "$cua_temporary/previous.app" "$cua_destination" || return
    fi
    rm -rf -- "$cua_temporary"
  }
  trap cleanup_cua EXIT

  /usr/bin/ditto "$cua_app" "$cua_temporary/CuaDriver.app"
  /usr/bin/codesign --verify --deep --strict -R "$cua_requirement" "$cua_temporary/CuaDriver.app"
  if [[ -e "$cua_destination" ]]; then
    mv -- "$cua_destination" "$cua_temporary/previous.app"
  fi
  mv -- "$cua_temporary/CuaDriver.app" "$cua_destination"
  cleanup_cua
  trap - EXIT
fi

hermes computer-use permissions grant
hermes computer-use doctor
