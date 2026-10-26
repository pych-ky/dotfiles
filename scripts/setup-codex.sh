#!/usr/bin/env bash
# Codex アプリのモデル保存値を共通設定に合わせる

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

python3.14 - "$repo_dir/etc/codex/config.toml" <<'PYTHON'
import json
import os
from pathlib import Path
from queue import Queue
import subprocess
import sys
from threading import Thread
import tomllib

managed = tomllib.loads(Path(sys.argv[1]).read_text())
edits = [
    {"keyPath": key, "value": managed[key], "mergeStrategy": "replace"}
    for key in ("model", "model_reasoning_effort")
]
homes = [Path.home() / ".codex"]
orca_home = Path.home() / "Library/Application Support/orca/codex-runtime-home/home"
if orca_home.is_dir():
    homes.append(orca_home)

for home in homes:
    process = subprocess.Popen(
        ["codex", "app-server", "--stdio"],
        env={**os.environ, "CODEX_HOME": str(home)},
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    replies = Queue()

    # app-server の出力を JSON として応答キューへ渡す
    def read_replies(stdout=process.stdout, output=replies):
        for line in stdout:
            output.put(json.loads(line))
        output.put(None)

    Thread(target=read_replies, daemon=True).start()

    # JSON-RPC 要求を送り、同じ id の応答だけを返す
    def request(request_id, method, params):
        process.stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
        process.stdin.flush()
        while True:
            reply = replies.get(timeout=30)
            if reply is None:
                raise RuntimeError("Codex app-server closed before responding")
            if reply.get("id") != request_id:
                continue
            if "error" in reply:
                raise RuntimeError(f"Codex {method} failed: {reply['error']['message']}")
            return reply["result"]

    try:
        request(1, "initialize", {"clientInfo": {"name": "dotfiles-setup", "version": "1.0"}})
        process.stdin.write('{"method":"initialized"}\n')
        process.stdin.flush()
        result = request(2, "config/batchWrite", {"edits": edits})
        if result["status"] != "ok":
            raise RuntimeError(f"Codex model settings are overridden: {home}")
        if os.environ.get("DOTFILES_BOOTSTRAP") != "1":
            print(f"ok: Codex model settings: {home / 'config.toml'}")
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)
PYTHON
