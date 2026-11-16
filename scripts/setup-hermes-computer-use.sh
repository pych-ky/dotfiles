#!/usr/bin/env bash
# Hermes PM と macOS の権限要求で使う CuaDriver を揃える

set -euo pipefail

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

# 権限を与えるアプリなので、配置前に配布元の署名を検証
/usr/bin/codesign --verify --deep --strict -R "$cua_requirement" "$cua_app"

# CuaDriver の権限要求は /Applications のバンドルを起動する
if ! /usr/bin/diff -qr "$cua_app" "$cua_destination" >/dev/null 2>&1; then
  rm -rf -- "$cua_destination"
  /usr/bin/ditto "$cua_app" "$cua_destination"
fi

hermes computer-use permissions grant
hermes computer-use doctor
