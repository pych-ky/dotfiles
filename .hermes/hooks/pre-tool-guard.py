#!/usr/bin/env python3
"""Hermes のツール入力を共通ガードで静的検査"""

import importlib.util
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True


def load_guard():
    """共通ガードの読み込み"""
    source = Path(__file__).resolve().parents[2] / ".claude/hooks/pre-bash-guard.py"
    spec = importlib.util.spec_from_file_location("pre_bash_guard", source)
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    return guard


def tool_paths(tool, arguments):
    """ツールが本文を読み書きするパス"""
    if tool == "search_files":
        # ファイル名の検索は本文を読まない
        if arguments.get("target") in {"files", "find"}:
            return []
        return [arguments.get("path") or ".", arguments.get("file_glob")]
    if tool == "patch" and arguments.get("mode") == "patch":
        headers = re.findall(r"^\*\*\*\s*(?:Update|Add|Delete|Move)\s+File:\s*(.+)$", arguments["patch"], re.M)
        return [path.strip() for header in headers for path in header.split("->")]
    if tool in {"read_file", "write_file", "patch"}:
        return [arguments["path"]]
    return []


def main():
    """拒否を Hermes 形式で返し、入力・内部故障は終了コード 2 で停止"""
    try:
        event = json.load(sys.stdin)
        tool, arguments, cwd = event["tool_name"], event["tool_input"], event["cwd"]
        guard = load_guard()
        try:
            if tool == "terminal":
                guard.scan(arguments["command"], arguments.get("workdir") or cwd)
            elif any(guard.credential_path(path, cwd) for path in tool_paths(tool, arguments)):
                raise guard.Denied("認証情報ファイルの直接読み取り・変更は許可していません。")
        except guard.Denied as error:
            json.dump({"action": "block", "message": str(error)}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
    except Exception:
        print("pre-tool-guard: 入力を安全に解析できませんでした。", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
