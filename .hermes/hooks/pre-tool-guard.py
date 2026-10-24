#!/usr/bin/env python3
"""Hermes のツール入力を共通ガードで静的検査"""

import importlib.util
import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True


def load_guard(cwd):
    """共通ガードを読み込み、Hermes の認証保存先を保護対象へ追加"""
    source = Path(__file__).resolve().parents[2] / ".claude/hooks/pre-bash-guard.py"
    spec = importlib.util.spec_from_file_location("hermes_pre_bash_guard", source)
    guard = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = guard
    spec.loader.exec_module(guard)

    roots = set()
    for root in {str(Path.home() / ".hermes"), os.environ.get("HERMES_HOME", "")}:
        if root:
            roots.update(guard.path_spellings(root, cwd))
    files = (
        ".anthropic_oauth.json", "auth.json", "auth.lock", "auth/google_oauth.json",
        "cache/bws_cache.enc.json", "cache/bws_cache.json", "config.yaml", "webhook_subscriptions.json",
    )
    directories = ("backups/config", "browser-profile", "browser-profiles", "browser_profiles", "mcp-tokens", "vault")
    locations = tuple(f"{root}/{name}" for root in roots for name in files + directories)
    guard.CREDENTIAL_LOCATIONS += locations
    original_credential_path = guard.credential_path
    original_path_exposes_credentials = guard.path_exposes_credentials
    protected = re.compile(
        r"(?:profiles/[^/]+/)?(?:"
        + "|".join(re.escape(name) + r"(?:\.[^/]*)?" for name in files)
        + "|" + "|".join(re.escape(name) + r"(?:/.*)?" for name in directories)
        + r"|state-snapshots/[^/]+/(?:auth\.json|config\.yaml)(?:\.[^/]*)?"
        + r"|backups/pre-(?:update|migration)-[^/]+\.zip)"
    )

    def credential_path(value, directory):
        """認証保存先・バックアップとシェルスナップショットを保護"""
        if original_credential_path(value, directory):
            return True
        return bool(value) and any(
            re.fullmatch(r"hermes-snap-[^/]+\.sh(?:\.tmp\.[^/]+)?", os.path.basename(path))
            or any(path.startswith(root + "/") and protected.fullmatch(path[len(root) + 1:]) for root in roots)
            for path in guard.path_spellings(value, directory)
        )

    def path_exposes_credentials(value, directory):
        """名前付きプロファイル・スナップショットの再帰検索も検査"""
        if original_path_exposes_credentials(value, directory):
            return True
        for path in guard.path_spellings(value, directory):
            for root in roots:
                if not path.startswith(root + "/"):
                    continue
                relative = path[len(root) + 1:]
                if re.fullmatch(r"profiles(?:/[^/]+)?", relative):
                    return True
                relative = re.sub(r"^profiles/[^/]+/", "", relative)
                if re.fullmatch(r"state-snapshots(?:/[^/]+)?", relative):
                    return True
                if any(name.startswith(relative + "/") for name in files + directories):
                    return True
        return False

    guard.credential_path = credential_path
    guard.path_exposes_credentials = path_exposes_credentials
    return guard


def check_path(guard, path, cwd, recursive=False):
    """明示された認証ファイル・既知の認証保存先の親を拒否"""
    if not isinstance(path, str) or not path:
        raise ValueError("path must be a nonempty string")
    predicate = guard.path_exposes_credentials if recursive else guard.credential_path
    if predicate(path, cwd):
        guard.deny("認証情報ファイルの直接読み取り・変更は許可していません。")


def inspect_call(guard, tool, arguments, cwd):
    """公式ツールのコマンド・パス・直接 Python コードを検査"""
    if tool == "terminal":
        directory = arguments.get("workdir")
        if directory is None or directory == "":
            directory = cwd
        if not isinstance(directory, str) or not os.path.isabs(directory):
            raise ValueError("workdir must be an absolute path")
        if not isinstance(arguments.get("command"), str):
            raise ValueError("command must be a string")
        guard.scan(arguments["command"], directory)
    elif tool in {"execute_code", "browser_exec"}:
        if not isinstance(arguments.get("code"), str):
            raise ValueError("code must be a string")
        guard.inspect_code("python", arguments["code"], cwd)
    elif tool == "search_files":
        target = arguments.get("target", "content")
        if target not in {"content", "files", "grep", "find"}:
            raise ValueError("invalid search target")
        if target in {"content", "grep"}:
            search_path = arguments.get("path", ".")
            if search_path is None or (isinstance(search_path, str) and not search_path.strip()):
                search_path = "."
            check_path(guard, search_path, cwd, recursive=True)
            if arguments.get("file_glob"):
                check_path(guard, arguments["file_glob"], cwd)
    elif tool == "patch" and arguments.get("mode", "replace") == "patch":
        patch = arguments.get("patch")
        if not isinstance(patch, str):
            raise ValueError("patch must be a string")
        for match in re.finditer(r"^\*\*\*\s*(?:Update|Add|Delete)\s+File:\s*(.+)$", patch, re.MULTILINE):
            check_path(guard, match[1].strip(), cwd)
        for match in re.finditer(r"^\*\*\*\s*Move\s+File:\s*(.+?)\s*->\s*(.+)$", patch, re.MULTILINE):
            for path in match.groups():
                check_path(guard, path.strip(), cwd)
    elif tool in {"read_file", "write_file", "patch"}:
        check_path(guard, arguments.get("path"), cwd)


def main():
    """拒否を Hermes 形式で返し、入力・内部故障は終了コード 2 で停止"""
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict) or event.get("hook_event_name") != "pre_tool_call":
            raise ValueError("invalid hook event")
        tool, arguments, cwd = (event.get(key) for key in ("tool_name", "tool_input", "cwd"))
        if not isinstance(tool, str) or not isinstance(arguments, dict):
            raise ValueError("invalid tool input")
        if not isinstance(cwd, str) or not os.path.isabs(cwd):
            raise ValueError("cwd must be an absolute path")
        guard = load_guard(cwd)
        try:
            inspect_call(guard, tool, arguments, cwd)
        except guard.Denied as error:
            json.dump({"action": "block", "message": str(error)}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
        except guard.UnsupportedSyntax:
            pass
    except Exception:
        print("pre-tool-guard: 入力を安全に解析できませんでした。", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
