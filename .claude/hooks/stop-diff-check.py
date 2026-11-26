#!/usr/bin/env python3
"""エージェント終了時の不要差分検査"""

import codecs
import fcntl
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

MAX_SCAN_BYTES = 262_144
STATE_TTL_SECONDS = 7 * 24 * 60 * 60
EMPTY_TREE_OID = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
# Codex が memories などを Git 管理して裏で書き換えるため、配下のリポジトリは検査しない
CODEX_HOME_DIR = (Path.home() / ".codex").resolve()

HASH_COMMENT_EXTS = {
    ".bash",
    ".conf",
    ".dockerfile",
    ".hcl",
    ".ini",
    ".mk",
    ".pl",
    ".py",
    ".r",
    ".rb",
    ".sh",
    ".tf",
    ".tfvars",
    ".toml",
    ".yaml",
    ".yml",
    ".zsh",
}
HASH_COMMENT_NAMES = {
    ".bash_profile",
    ".bashrc",
    ".profile",
    ".zprofile",
    ".zshenv",
    ".zshrc",
    "Brewfile",
    "Dockerfile",
    "Gemfile",
    "Makefile",
    "Rakefile",
}
SLASH_COMMENT_EXTS = {
    ".c",
    ".cc",
    ".cjs",
    ".cpp",
    ".cs",
    ".css",
    ".dart",
    ".go",
    ".h",
    ".hpp",
    ".java",
    ".js",
    ".jsonc",
    ".jsx",
    ".kt",
    ".kts",
    ".less",
    ".mjs",
    ".php",
    ".proto",
    ".rs",
    ".scala",
    ".scss",
    ".swift",
    ".ts",
    ".tsx",
}
DASH_COMMENT_EXTS = {".lua", ".sql"}

DIRECTIVE_COMMENT_RE = re.compile(
    r"^(?:"
    r"#\s*(?:!|shellcheck\b|noqa\b|type:\s*ignore\b|pyright:|ruff:|fmt:|pylint:|pragma:|"
    r"frozen_string_literal:|rubocop:|tflint-ignore\b|checkov:|yamllint\b|prettier-ignore\b|-\*-)"
    r"|//\s*(?:eslint-|@ts-|prettier-ignore\b|nolint\b|go:|(?:\+build)\b)"
    r"|/\*\s*(?:eslint-|prettier-ignore\b|@ts-)"
    r"|(?:[#/*\s-])*(?:SPDX-License-Identifier:|Copyright\b)"
    r")",
    re.IGNORECASE,
)

HISTORY_COMMENT_RE = re.compile(
    r"(?:従来は|以前は|これまでは|元々は|もともとは|変更前|変更後|修正前|修正後|"
    r"旧実装|旧仕様|暫定対応として|今回(?:の修正|の変更|追加)|"
    r"のため(?:追加|削除|変更)|に合わせて(?:追加|変更)|"
    r"\b(?:previously|formerly|for\s+backward\s+compatibility\s+with\s+old)\b)",
    re.IGNORECASE,
)

DEBUG_STATEMENT_RE = re.compile(
    r"^(?:\s*(?:debugger\s*;?\s*$|breakpoint\s*\(\s*\)|(?:import\s+pdb\s*;\s*)?pdb\.set_trace\s*\(\s*\)|"
    r"binding\.(?:pry|irb)\b|console\.debug\s*\()|.*\bdbg!\s*\()"
)

DOC_BASENAME_RE = re.compile(
    r"^(?:README|CHANGELOG|CONTRIBUTING|ARCHITECTURE|DESIGN|NOTES|PLAN|SUMMARY|TODO)(?:\..+)?$",
    re.IGNORECASE,
)
INSTRUCTION_DOC_NAMES = {
    "AGENTS.md",
    "CLAUDE.md",
    "SKILL.md",
    "SOUL.md",
    "copilot-instructions.md",
}
SENSITIVE_PATH_RE = re.compile(
    r"(?:^|/)(?:(?:secrets|credentials)(?:/|$)|\.aws/(?:sso|cli)/cache/|"
    r"(?:\.env[^/]*|\.git-credentials|\.netrc|\.pgpass|\.vault-token|\.claude\.json[^/]*|\.credentials\.json|"
    r"\.codex/auth\.json|"
    r"id_(?:rsa|dsa|ed25519|ecdsa)[^/]*|[^/]*\.(?:pem|key|p12|pfx|tfstate[^/]*))$)",
    re.IGNORECASE,
)
TEST_PATH_RE = re.compile(
    r"(?:^|/)(?:tests?|__tests__|spec)/|"
    r"(?:^|/)(?:test_[^/]+\.py|[^/]+_test\.(?:py|go)|[^/]+_spec\.rb|"
    r"[^/]+\.(?:test|spec)\.(?:[cm]?[jt]sx?))$",
    re.IGNORECASE,
)


def sha256_text(text: str) -> str:
    """文字列の SHA-256 ダイジェスト"""
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()


def state_dir_path() -> Path:
    """セッション状態を置く一時ディレクトリ（なければ作成）"""
    path = Path(f"/tmp/agent-diff-guard-{os.getuid()}")
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    # 別ユーザーが先に置いたディレクトリやリンクは使わない
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise OSError(f"unsafe state directory: {path}")
    return path


def prune_stale_states(directory: Path) -> None:
    """保持期間を過ぎた状態ファイルの削除"""
    cutoff = time.time() - STATE_TTL_SECONDS
    for entry in directory.iterdir():
        try:
            if entry.stat().st_mtime < cutoff:
                entry.unlink(missing_ok=True)
        except OSError:
            continue


def state_file_path(session_id: str) -> Path:
    """セッション ID に対応する状態ファイルのパス"""
    return state_dir_path() / f"{sha256_text(session_id)}.json"


def load_state(session_id: str) -> dict:
    """セッション状態の読み込み"""
    path = state_file_path(session_id)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {"repos": {}}


def acquire_session_lock(session_id: str):
    """並行するフックが同じセッション状態を上書きしないための排他ロック"""
    lock_file = state_file_path(session_id).with_suffix(".lock").open("a")
    fcntl.flock(lock_file, fcntl.LOCK_EX)
    return lock_file


def save_state(session_id: str, state: dict) -> None:
    """セッション状態を 0600 権限で保存"""
    path = state_file_path(session_id)
    tmp_path = path.with_suffix(".tmp")
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False)
    os.replace(tmp_path, path)


def run_git(repo_or_dir: str, args: list[str], binary: bool = False) -> subprocess.CompletedProcess | None:
    """Git コマンドの実行結果（失敗時は None）"""
    try:
        result = subprocess.run(
            ["git", "--no-optional-locks", "-c", "core.quotePath=false", "-C", repo_or_dir, *args],
            capture_output=True,
            text=not binary,
            encoding=None if binary else "utf-8",
            errors=None if binary else "surrogateescape",
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result


def resolve_git_root(target_path: str | None) -> str | None:
    """パスが属する Git 作業ツリーのルート"""
    if not target_path:
        return None
    candidate = Path(target_path)
    if not candidate.exists():
        candidate = candidate.parent
    if not candidate.is_dir():
        return None
    res = run_git(str(candidate), ["rev-parse", "--show-toplevel"])
    if res is None:
        return None
    root = res.stdout.strip()
    return str(Path(root).resolve()) if root else None


def extract_candidate_roots(payload: dict) -> list[str]:
    """イベント入力から関連する Git ルート候補を抽出"""
    cwd = payload.get("cwd") or ""
    candidates: list[str] = []
    if cwd:
        candidates.append(cwd)

    tool_input = payload.get("tool_input")
    if isinstance(tool_input, dict):
        for key in ("file_path", "path", "notebook_path"):
            val = tool_input.get(key)
            if isinstance(val, str) and val:
                expanded = os.path.expanduser(val)
                full = expanded if os.path.isabs(expanded) else os.path.join(cwd, expanded)
                candidates.append(full)
        command = tool_input.get("command")
        # Codex の apply_patch は tool_input.command にパッチ本文を渡す
        patch_targets = (
            re.findall(r"^\*\*\* (?:Update|Add|Delete) File:\s*(.+)$", command, re.MULTILINE)
            if isinstance(command, str)
            else []
        )
        for target in patch_targets:
            expanded = os.path.expanduser(target.strip())
            candidates.append(expanded if os.path.isabs(expanded) else os.path.join(cwd, expanded))
        if isinstance(command, str) and command and not patch_targets:
            try:
                tokens = shlex.split(command, posix=True)
            except ValueError:
                tokens = command.split()
            for idx, token in enumerate(tokens[:40]):
                if token in ("-C", "cd") and idx + 1 < len(tokens):
                    target = os.path.expanduser(tokens[idx + 1])
                    full = target if os.path.isabs(target) else os.path.join(cwd, target)
                    candidates.append(full)
                elif token.startswith(("/", "~/", "./", "../")) or "/" in token:
                    cleaned = os.path.expanduser(token.strip("\"'();|&"))
                    if cleaned and not cleaned.startswith("-"):
                        full = cleaned if os.path.isabs(cleaned) else os.path.join(cwd, cleaned)
                        candidates.append(full)

    roots: list[str] = []
    dir_roots: dict[str, str | None] = {}
    for item in map(os.path.realpath, candidates):
        directory = item if os.path.isdir(item) else os.path.dirname(item)
        if directory not in dir_roots:
            dir_roots[directory] = resolve_git_root(directory)
        root = dir_roots[directory]
        if (
            root
            and root not in roots
            and not SENSITIVE_PATH_RE.search(root)
            and not Path(root).is_relative_to(CODEX_HOME_DIR)
        ):
            roots.append(root)
    return roots


def inside_repo(repo_root: str, target: Path) -> bool:
    """リンクではなく、親のリンクをたどってもリポジトリ内の機微パス以外にある実ファイルか判定"""
    if target.is_symlink() or not target.is_file():
        return False
    root = Path(repo_root).resolve()
    resolved = target.resolve()
    return resolved.is_relative_to(root) and not SENSITIVE_PATH_RE.search(str(resolved.relative_to(root)))


def file_state_digest(repo_root: str, rel_path: str) -> str:
    """作業ツリー上のファイル状態を、内容を残さずハッシュ化"""
    target = Path(repo_root) / rel_path
    try:
        if target.is_symlink():
            return f"symlink:{sha256_text(os.readlink(target))}"
        if not target.exists():
            return "deleted"
        if not inside_repo(repo_root, target):
            return "other"
        info = target.stat()
        if info.st_size > MAX_SCAN_BYTES:
            return f"large:{info.st_size}:{info.st_mtime_ns}"
        return f"file:{hashlib.sha256(target.read_bytes()).hexdigest()}"
    except OSError:
        return "unreadable"


def collect_status_entries(repo_root: str) -> dict[str, tuple[str, str, str]] | None:
    """Git status の変更・未追跡ファイルの状態・ダイジェスト・改名の移動元（取得失敗は None）"""
    res = run_git(repo_root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], binary=True)
    if res is None:
        return None
    entries: dict[str, tuple[str, str, str]] = {}
    parts = res.stdout.split(b"\x00")
    idx = 0
    while idx < len(parts):
        raw = parts[idx]
        idx += 1
        if len(raw) < 4:
            continue
        xy = raw[:2].decode("ascii", "replace")
        rel_path = raw[3:].decode("utf-8", "surrogateescape")
        # rename/copy は移動元パスが次の NUL 区切り要素に入る
        orig_path = ""
        if "R" in xy or "C" in xy:
            orig_path = parts[idx].decode("utf-8", "surrogateescape")
            idx += 1
            if "R" in xy and not SENSITIVE_PATH_RE.search(orig_path):
                entries.setdefault(orig_path, ("D ", "deleted", ""))
        if not SENSITIVE_PATH_RE.search(rel_path):
            entries[rel_path] = (xy, file_state_digest(repo_root, rel_path), orig_path if "R" in xy else "")
    return entries


def unquote_git_path(raw: str) -> str:
    """Git が引用符とエスケープで囲んだパスの復元"""
    if raw.startswith('"') and raw.endswith('"'):
        return codecs.escape_decode(raw[1:-1].encode("utf-8", "surrogateescape"))[0].decode("utf-8", "surrogateescape")
    return raw


def diff_header_path(raw: str) -> str | None:
    """差分見出しの `+++` 側から b/ を除いたパス（/dev/null は None）"""
    # 空白を含むパスは末尾にタブが付く
    raw = unquote_git_path(raw.removesuffix("\t"))
    return raw[2:] if raw.startswith("b/") else None


def parse_zero_context_diff(diff_text: str) -> dict[str, list[tuple[list[str], list[str]]]]:
    """unified=0 の Git diff をファイルごとの hunk 一覧へ分解"""
    files: dict[str, list[tuple[list[str], list[str]]]] = {}
    current_file: str | None = None
    removed: list[str] | None = None
    added: list[str] | None = None

    for line in diff_text.splitlines():
        if line.startswith("diff --git "):
            if current_file is not None and removed is not None and added is not None:
                files.setdefault(current_file, []).append((removed, added))
            current_file = None
            removed = None
            added = None
        elif line.startswith("+++ ") and removed is None:
            current_file = diff_header_path(line[4:])
        elif line.startswith("@@ "):
            if current_file is not None and removed is not None and added is not None:
                files.setdefault(current_file, []).append((removed, added))
            removed = []
            added = []
        elif removed is not None and added is not None:
            if line.startswith("-"):
                removed.append(line[1:])
            elif line.startswith("+"):
                added.append(line[1:])

    if current_file is not None and removed is not None and added is not None:
        files.setdefault(current_file, []).append((removed, added))
    return files


def tracked_paths(status_entries: dict[str, tuple[str, str, str]]) -> list[str]:
    """機微パスを除いた状態一覧のうち、差分を取れる追跡ファイル"""
    return [path for path, (xy, _, _) in status_entries.items() if xy != "??"]


def read_diff(repo_root: str, rev: str, paths: list[str]) -> dict[str, list[tuple[list[str], list[str]]]]:
    """作業ツリーと指定コミットの差分 hunk を、指定パスに限って取得"""
    # 機微パスの本文を git に出力させないよう、除外済みのファイルのパスだけを指定する
    paths = [path for path in paths if not (Path(repo_root) / path).is_dir()]
    if not paths:
        return {}
    args = [
        "--literal-pathspecs",
        "diff",
        rev,
        "-M",
        "--unified=0",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--submodule=short",
    ]
    res = run_git(repo_root, [*args, "--", *paths])
    if res is None:
        return {}
    return parse_zero_context_diff(res.stdout)


def hunk_digest(removed: list[str], added: list[str]) -> str:
    """hunk 全体の SHA-256 ダイジェスト"""
    joined = "\n".join([*(f"-{line}" for line in removed), *(f"+{line}" for line in added)])
    return sha256_text(joined)


def snapshot_repo(repo_root: str) -> dict:
    """ターン開始時点または初回変更前のリポジトリ基準状態を記録"""
    head_res = run_git(repo_root, ["rev-parse", "--verify", "HEAD"])
    head_oid = head_res.stdout.strip() if head_res else ""
    status_entries = collect_status_entries(repo_root)
    # 基準を取れなかったリポジトリは、利用者の変更を AI の変更と取り違えないよう検査しない
    if status_entries is None:
        return {"unavailable": True}
    diff_map = read_diff(repo_root, head_oid or EMPTY_TREE_OID, tracked_paths(status_entries))

    file_hunks: dict[str, dict[str, int]] = {}
    file_lines: dict[str, dict[str, int]] = {}
    for rel_path, hunks in diff_map.items():
        path_key = sha256_text(rel_path)
        h_counter: Counter[str] = Counter()
        l_counter: Counter[str] = Counter()
        for removed, added in hunks:
            h_counter[hunk_digest(removed, added)] += 1
            for line in removed:
                l_counter[f"-{sha256_text(line)}"] += 1
            for line in added:
                l_counter[f"+{sha256_text(line)}"] += 1
        file_hunks[path_key] = dict(h_counter)
        file_lines[path_key] = dict(l_counter)

    return {
        "head_oid": head_oid,
        "taken_at": time.time(),
        "dirty_files": {sha256_text(path): digest for path, (_, digest, _) in status_entries.items()},
        "file_hunks": file_hunks,
        "file_lines": file_lines,
    }


def comment_style(rel_path: str, sample_first_line: str = "") -> str | None:
    """ファイルの拡張子・名前・shebang からコメント種別を判定"""
    path = Path(rel_path)
    ext = path.suffix.lower()
    if ext in HASH_COMMENT_EXTS or path.name in HASH_COMMENT_NAMES:
        return "hash"
    if ext in SLASH_COMMENT_EXTS:
        return "slash"
    if ext in DASH_COMMENT_EXTS:
        return "dash"
    if not ext and sample_first_line.startswith("#!"):
        return "hash"
    return None


def is_full_line_comment(line: str, style: str) -> bool:
    """1行全体がコードコメントか判定"""
    stripped = line.strip()
    if not stripped:
        return False
    if style == "hash":
        return stripped.startswith("#") and not stripped.startswith("#!")
    if style == "slash":
        return stripped.startswith(("//", "/*", "* ", "*/")) or stripped == "*"
    if style == "dash":
        return stripped.startswith("--")
    return False


def is_directive_comment(line: str) -> bool:
    """リンター指示・ライセンス表記のコメントか判定"""
    return bool(DIRECTIVE_COMMENT_RE.match(line.strip()))


def repo_owner_kind(repo_root: str) -> str:
    """origin URL から判定したリポジトリ所有区分（personal / other / unknown）"""
    res = run_git(repo_root, ["config", "--get", "remote.origin.url"])
    if res is None:
        return "unknown"
    url = res.stdout.strip()
    if not url:
        return "unknown"
    if re.search(r"github\.com[:/]pych-ky(?:/|\.git$|$)", url, re.IGNORECASE):
        return "personal"
    return "other"


def existing_comment_density_low(repo_root: str, rel_path: str, style: str, added_comment_hashes: Counter[str]) -> bool:
    """対象ファイルおよび同階層の同種ファイルで既存コメント率が低いか判定"""
    target = Path(repo_root) / rel_path
    parent = target.parent
    ext = target.suffix.lower()
    candidates = [target]
    if parent.is_dir() and ext:
        for sibling in sorted(parent.glob(f"*{ext}")):
            if sibling != target and len(candidates) < 6 and not SENSITIVE_PATH_RE.search(str(sibling)):
                candidates.append(sibling)

    remaining_added = Counter(added_comment_hashes)
    nonblank_total = 0
    existing_comments = 0
    for candidate in candidates:
        try:
            if not inside_repo(repo_root, candidate) or candidate.stat().st_size > MAX_SCAN_BYTES:
                continue
            lines = candidate.read_text(encoding="utf-8", errors="surrogateescape").splitlines()
        except OSError:
            continue
        for line in lines:
            if not line.strip():
                continue
            if candidate == target:
                line_key = sha256_text(line)
                if remaining_added[line_key] > 0:
                    remaining_added[line_key] -= 1
                    continue
            nonblank_total += 1
            if is_full_line_comment(line, style) and not is_directive_comment(line):
                existing_comments += 1

    return nonblank_total >= 8 and (existing_comments / nonblank_total) < 0.03


def is_doc_file(rel_path: str) -> bool:
    """コード変更と分離して扱う一般文書ファイルか判定"""
    path = Path(rel_path)
    if path.name in INSTRUCTION_DOC_NAMES:
        return False
    parts_lower = [part.lower() for part in path.parts]
    if "skills" in parts_lower:
        return False
    if DOC_BASENAME_RE.match(path.name):
        return True
    return path.suffix.lower() in {".md", ".mdx", ".rst"}


def turn_commit_files(
    repo_root: str, base_oid: str, since: float
) -> tuple[dict[str, bool], set[str], dict[str, str]] | None:
    """基準の HEAD 以降のコミットが変えたファイルを、利用者がその回に作ったもの（追加したか）とそれ以外、改名の移動元に分類"""
    if run_git(repo_root, ["merge-base", "--is-ancestor", base_oid, "HEAD"]) is None:
        return None
    email_res = run_git(repo_root, ["config", "--get", "user.email"])
    email = email_res.stdout.strip().lower() if email_res else ""
    log_res = run_git(
        repo_root,
        ["log", "--first-parent", "--diff-merges=first-parent", "--name-status", "--format=%x01%ce %ct %P", f"{base_oid}..HEAD"],
    )
    if log_res is None:
        return None
    own: dict[str, bool] = {}
    others: set[str] = set()
    renames: dict[str, str] = {}
    is_own = False
    for line in log_res.stdout.splitlines():
        if line.startswith("\x01"):
            committer, timestamp, *parents = line[1:].split(" ")
            is_own = bool(email) and committer.lower() == email and int(timestamp) >= int(since) and len(parents) == 1
        elif line:
            status, *paths = line.split("\t")
            paths = [unquote_git_path(path) for path in paths]
            if is_own and status.startswith("R"):
                renames.setdefault(paths[-1], paths[0])
            for path in paths:
                if SENSITIVE_PATH_RE.search(path):
                    continue
                if is_own:
                    own[path] = own.get(path, False) or status.startswith("A")
                else:
                    others.add(path)
    return own, others, renames


def moved_new_files(
    repo_root: str, status_entries: dict[str, tuple[str, str, str]], baseline_dirty: dict[str, str]
) -> set[str]:
    """作業前のファイルか削除した追跡ファイルの HEAD と内容が同じ、新しいファイル（移動しただけのもの）"""
    deleted = [path for path, (xy, digest, _) in status_entries.items() if digest == "deleted" and xy != "??"]
    res = run_git(repo_root, ["--literal-pathspecs", "ls-tree", "-r", "HEAD", "--", *deleted]) if deleted else None
    blobs = {line.split()[2] for line in res.stdout.splitlines()} if res else set()
    previous_digests = set(baseline_dirty.values())
    moved: set[str] = set()
    for path, (xy, digest, _) in status_entries.items():
        if xy[0] in "?A" and digest.startswith("file:") and sha256_text(path) not in baseline_dirty:
            if digest in previous_digests:
                moved.add(path)
                continue
            if not blobs:
                continue
            try:
                data = (Path(repo_root) / path).read_bytes()
            except OSError:
                continue
            if hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest() in blobs:
                moved.add(path)
    return moved


def analyze_repo_turn_diff(repo_root: str, baseline: dict) -> list[str]:
    """基準状態からの差分を検査し、確認が必要な指摘文を列挙"""
    if baseline.get("unavailable"):
        return []
    head_res = run_git(repo_root, ["rev-parse", "--verify", "HEAD"])
    current_head = head_res.stdout.strip() if head_res else ""
    base_oid = baseline.get("head_oid", "")
    # その回に利用者の名前で作ったコミットの変更も、基準の HEAD との差分として検査する
    commits = (
        None
        if current_head == base_oid or not base_oid
        else turn_commit_files(repo_root, base_oid, baseline.get("taken_at", 0))
    )
    own_commit_files, other_commit_files, commit_renames = commits or ({}, set(), {})

    status_entries = collect_status_entries(repo_root)
    if status_entries is None:
        return []
    for path in own_commit_files:
        xy, digest, orig_path = status_entries.get(path) or (
            "A " if own_commit_files[path] else "M ",
            file_state_digest(repo_root, path),
            "",
        )
        status_entries[path] = (xy, digest, orig_path or commit_renames.get(path, ""))
    baseline_dirty: dict[str, str] = baseline.get("dirty_files", {})
    changed_paths = {
        rel_path
        for rel_path, (_, digest, _) in status_entries.items()
        if digest != "deleted" and baseline_dirty.get(sha256_text(rel_path)) != digest
    }
    if not changed_paths:
        return []

    tracked = tracked_paths(status_entries)
    if commits is not None:
        # ほかの人のコミットが変えたファイルは、取り込んだ変更を含めないよう現在の HEAD と比べる
        diff_map = read_diff(repo_root, base_oid, [path for path in tracked if path not in other_commit_files])
        diff_map.update(read_diff(repo_root, "HEAD", [path for path in tracked if path in other_commit_files]))
    else:
        diff_map = read_diff(repo_root, current_head or EMPTY_TREE_OID, tracked)
    owner_kind = repo_owner_kind(repo_root)
    moved_paths = moved_new_files(repo_root, status_entries, baseline_dirty)
    file_hunks = baseline.get("file_hunks", {})

    existing_comment_files: list[str] = []
    history_comment_files: list[str] = []
    multiline_comment_files: list[str] = []
    low_density_comment_files: list[str] = []
    debug_files: list[str] = []
    personal_test_files: list[str] = []
    modified_doc_files: list[str] = []
    new_doc_files: list[str] = []
    code_changed_count = 0

    for rel_path in sorted(changed_paths):
        xy, _, orig_path = status_entries[rel_path]
        path_key = sha256_text(rel_path)
        # 改名したファイルは、作業前に移動元で記録した差分を基準にする
        if orig_path and sha256_text(orig_path) in file_hunks:
            path_key = sha256_text(orig_path)
        is_untracked = xy == "??"
        # 作業前から未追跡などで行単位の基準がないファイルと、移動しただけのファイルは検査しない
        if (path_key in baseline_dirty and path_key not in file_hunks) or rel_path in moved_paths:
            continue
        is_new = path_key not in baseline_dirty and (is_untracked or xy[0] == "A" or own_commit_files.get(rel_path, False))

        net_hunks: list[tuple[list[str], list[str]]] = []
        if is_untracked:
            target = Path(repo_root) / rel_path
            try:
                if inside_repo(repo_root, target) and target.stat().st_size <= MAX_SCAN_BYTES:
                    lines = target.read_text(encoding="utf-8", errors="surrogateescape").splitlines()
                    net_hunks.append(([], lines))
            except OSError:
                continue
        else:
            raw_hunks = diff_map.get(rel_path, [])
            base_hunks = Counter(file_hunks.get(path_key, {}))
            base_lines = Counter(baseline.get("file_lines", {}).get(path_key, {}))
            for removed, added in raw_hunks:
                h_sig = hunk_digest(removed, added)
                if base_hunks[h_sig] > 0:
                    base_hunks[h_sig] -= 1
                    continue
                net_removed: list[str] = []
                for line in removed:
                    l_key = f"-{sha256_text(line)}"
                    if base_lines[l_key] > 0:
                        base_lines[l_key] -= 1
                    else:
                        net_removed.append(line)
                net_added: list[str] = []
                for line in added:
                    l_key = f"+{sha256_text(line)}"
                    if base_lines[l_key] > 0:
                        base_lines[l_key] -= 1
                    else:
                        net_added.append(line)
                if net_removed or net_added:
                    net_hunks.append((net_removed, net_added))

        if not net_hunks:
            continue

        if is_doc_file(rel_path):
            if is_new and Path(rel_path).suffix.lower() in {".md", ".mdx"}:
                new_doc_files.append(rel_path)
            else:
                modified_doc_files.append(rel_path)
            continue

        first_line = ""
        first_added = net_hunks[0][1]
        if first_added:
            first_line = first_added[0]
        style = comment_style(rel_path, first_line)
        code_changed_count += 1

        is_test_file = bool(TEST_PATH_RE.search(rel_path))
        if owner_kind == "personal" and is_test_file and any(added for _, added in net_hunks):
            personal_test_files.append(rel_path)

        if style is None:
            continue

        file_existing_comment_changed = False
        file_history_comment = False
        file_multiline_comment = False
        file_debug_added = False
        added_comments_all: list[str] = []

        for removed, added in net_hunks:
            removed_comments = [line for line in removed if is_full_line_comment(line, style)]
            removed_code = [line for line in removed if line.strip() and not is_full_line_comment(line, style)]
            added_comments = [line for line in added if is_full_line_comment(line, style)]
            added_code = [line for line in added if line.strip() and not is_full_line_comment(line, style)]

            # インデント調整だけの移動と、対象コードごとの削除は除外する
            if removed_comments:
                same_text = [c.strip() for c in removed_comments] == [c.strip() for c in added_comments]
                pure_block_deletion = not added_code and not added_comments and len(removed_code) >= 1
                if not same_text and not pure_block_deletion and not is_untracked:
                    file_existing_comment_changed = True

            consecutive_comments = 0
            for line in added:
                if not line.strip():
                    continue
                if is_full_line_comment(line, style):
                    if is_directive_comment(line):
                        consecutive_comments = 0
                        continue
                    added_comments_all.append(line)
                    consecutive_comments += 1
                    if consecutive_comments >= 3:
                        file_multiline_comment = True
                    if HISTORY_COMMENT_RE.search(line):
                        file_history_comment = True
                else:
                    consecutive_comments = 0
                    if not is_test_file and DEBUG_STATEMENT_RE.match(line):
                        file_debug_added = True

        if file_existing_comment_changed:
            existing_comment_files.append(rel_path)
        if file_history_comment:
            history_comment_files.append(rel_path)
        if file_multiline_comment:
            multiline_comment_files.append(rel_path)
        if file_debug_added:
            debug_files.append(rel_path)
        if (
            owner_kind == "other"
            and len(added_comments_all) >= 1
            and existing_comment_density_low(
                repo_root, rel_path, style, Counter(sha256_text(c) for c in added_comments_all)
            )
        ):
            low_density_comment_files.append(rel_path)

    repo_label = Path(repo_root).name
    findings: list[str] = []
    if existing_comment_files:
        joined = ", ".join(f"{repo_label}/{p}" for p in existing_comment_files[:5])
        findings.append(
            f"既存コメントの変更・削除 ({joined}): 対象処理の挙動・条件が変わっていない言い換えや、有効な理由コメントの削除は元に戻す"
        )
    if history_comment_files:
        joined = ", ".join(f"{repo_label}/{p}" for p in history_comment_files[:5])
        findings.append(
            f"変更経緯・前後比較コメントの追加 ({joined}): 変更理由・旧実装との比較・PR向けの説明はコード内コメントに書かない"
        )
    if multiline_comment_files:
        joined = ", ".join(f"{repo_label}/{p}" for p in multiline_comment_files[:5])
        findings.append(
            f"3行以上の連続コメント追加 ({joined}): 自明な説明を削り、周辺ファイル（個人所有リポジトリは役割1行＋必要時のみ理由1行）の粒度に絞る"
        )
    if low_density_comment_files:
        joined = ", ".join(f"{repo_label}/{p}" for p in low_density_comment_files[:5])
        findings.append(
            f"コメントの少ない他者・組織リポジトリへのコメント追加 ({joined}): 同種既存ファイルのコメント有無・密度に合わせ、不要なコメントを削る"
        )
    if code_changed_count > 0 and modified_doc_files:
        joined = ", ".join(f"{repo_label}/{p}" for p in modified_doc_files[:5])
        findings.append(
            f"コード変更と同時の文書更新 ({joined}): 明示依頼がある場合、または今回の変更で既存の記載が事実と食い違う箇所だけを残し、未依頼の追記は戻す"
        )
    if new_doc_files:
        joined = ", ".join(f"{repo_label}/{p}" for p in new_doc_files[:5])
        findings.append(
            f"新規 Markdown ファイルの作成 ({joined}): 明示依頼のない計画・メモ・要約ファイルなら削除する"
        )
    if personal_test_files:
        joined = ", ".join(f"{repo_label}/{p}" for p in personal_test_files[:5])
        findings.append(
            f"個人所有リポジトリでのテスト追加・更新 ({joined}): 明示依頼がない実装後のユニットテスト追加は行わず、E2Eで見逃す具体的失敗モードの事前列挙がない分離テストは削る"
        )
    if debug_files:
        joined = ", ".join(f"{repo_label}/{p}" for p in debug_files[:5])
        findings.append(f"デバッグ出力・ブレークポイントの残存候補 ({joined}): 依頼外のデバッグ記述なら削除する")
    return findings


def collect_turn_findings(state: dict) -> list[str]:
    """記録済みリポジトリのターン内差分から不要変更候補を収集"""
    findings: list[str] = []
    for repo_root, baseline in state.get("repos", {}).items():
        if Path(repo_root).is_dir():
            findings.extend(analyze_repo_turn_diff(repo_root, baseline))
    return findings


def handle_event(payload: dict) -> dict | None:
    """セッションごとに排他してフックイベントを処理"""
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return None
    prune_stale_states(state_dir_path())
    with acquire_session_lock(session_id):
        return process_event(payload.get("hook_event_name"), session_id, payload)


def process_event(event: object, session_id: str, payload: dict) -> dict | None:
    """フックイベントに応じた基準記録または差分検査"""
    if event == "UserPromptSubmit":
        state = load_state(session_id)
        # バックグラウンド作業の待機で検査を見送った回は、基準を引き継いで次の終了時に検査する
        repos = state.get("repos", {}) if state.get("deferred") else {}
        for root in extract_candidate_roots(payload):
            if root not in repos:
                repos[root] = snapshot_repo(root)
        save_state(session_id, {"repos": repos, "blocked": False})
        return None

    if event == "PreToolUse":
        state = load_state(session_id)
        repos = state.setdefault("repos", {})
        updated = False
        for root in extract_candidate_roots(payload):
            if root not in repos:
                repos[root] = snapshot_repo(root)
                updated = True
        if updated:
            save_state(session_id, state)
        return None

    if event == "Stop":
        if payload.get("stop_hook_active"):
            return None
        if payload.get("permission_mode") == "plan":
            return None

        state = load_state(session_id)
        bg_tasks = payload.get("background_tasks")
        # 完了時に会話を再開する種類の作業だけを待ち、常駐する作業などの間は通常どおり検査する
        if isinstance(bg_tasks, list) and any(
            isinstance(item, dict)
            and item.get("status") in ("running", "pending")
            and item.get("type") in ("subagent", "workflow")
            for item in bg_tasks
        ):
            state["deferred"] = True
            save_state(session_id, state)
            return None
        if state.get("blocked"):
            return None

        all_findings = collect_turn_findings(state)
        state["deferred"] = False
        state["blocked"] = bool(all_findings)
        save_state(session_id, state)
        if not all_findings:
            return None

        bullet_lines = "\n".join(f"- {item}" for item in all_findings)
        reason = (
            "終了前の差分検査で、過剰記述・不要変更の候補が見つかりました。"
            "この回に自分が加えた変更のうち、元の依頼にない不要なものだけを元に戻してください。"
            "候補には、利用者やほかの人の変更、git で取り込んだ内容、移動しただけのファイルが含まれることがあり、それらは戻しません。"
            "戻すものがなければ、この検査には触れずに終了してください。\n"
            f"{bullet_lines}"
        )
        return {"decision": "block", "reason": reason}

    return None


def main() -> int:
    """標準入力のフック JSON を処理し、必要時だけ判定結果を出力"""
    try:
        decision = handle_event(json.load(sys.stdin))
        if decision is not None:
            json.dump(decision, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
    except Exception:
        # 差分検査の内部障害でエージェントの進行を止めない
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
