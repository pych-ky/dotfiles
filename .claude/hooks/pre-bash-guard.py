#!/usr/bin/env python3
"""Bash コマンドの静的検査"""

import json
import os
import re
import sys


class Denied(Exception):
    """deny として返す危険操作"""


CREDENTIAL_REASON = "認証情報ファイルの直接読み取り・持ち出しは許可していません。"
DESTRUCTIVE_REASON = "強制的な変更破棄、検証の迂回、ディスクの破壊は許可していません。"

# 各行は「コマンド 引数…」の正規表現で、各語に全体一致する引数がこの順に現れれば拒否する（間に他の引数があってもよい）
SECRET_OUTPUTS = r"""
    aws codeartifact get-authorization-token
    aws configure export-credentials
    aws configure get|set (?i:.*(?:secret|token|password).*)
    aws ecr|ecr-public get-login-password|get-authorization-token
    aws eks get-token
    aws iam create-access-key
    aws kms decrypt
    aws rds generate-db-auth-token
    aws s3 presign
    aws secretsmanager get-secret-value|batch-get-secret-value
    aws ssm get-parameter.* --with-decryption
    aws sso get-role-credentials
    aws sts assume-.*|get-.*-token
    (?:docker|git)-credential-.+
    gcloud auth print-access-token|print-identity-token|print-refresh-token
    gcloud secrets versions access
    gh auth status --show-token|-t
    gh auth token|git-credential
    ghtkn exec|get|git-credential
    git credential fill
    git credential-.+
    kubectl|oc config view --raw|--flatten
    kubectl|oc create token
    kubectl|oc get|describe|extract (?:.*,)?secrets?(?:[./,].*)?
    oc whoami --show-token|-t
    op item|document get
    op read|inject|run
    op signin --raw|--force|-f
    security dump-keychain
    security find-generic-password|find-internet-password -[A-Za-z]*[gw][A-Za-z]*
    terraform|terragrunt output [^-].*|-json|-raw|--json|--raw
    terraform|terragrunt show -json|--json
    terraform|terragrunt state pull|show
    uv auth token
"""
DESTRUCTIVE_OPERATIONS = r"""
    dd of=/dev/(?:r?disk|sd|nvme).*
    diskutil (?i:apfs|ap) (?i:deletecontainer|deletevolume|deletevolumegroup)
    diskutil (?i:erasedisk|erasevolume|partitiondisk|zerodisk|randomdisk|secureerase|reformat)
    git checkout|switch --force|--discard-changes|-[A-Za-z]*f[A-Za-z]*
    git clean --force|-[A-Za-z]*f[A-Za-z]*
    git commit -[A-Za-z]*n[A-Za-z]*
    git commit|merge|rebase|push --no-verify
    git push --force|--mirror|--prune|-[A-Za-z]*f[A-Za-z]*|\+.+
    git reset --hard
    git stash clear
    mkfs.*|newfs.*
"""
EXEC_OVERRIDES = r"""
    git -c|--config (?i:core\.hookspath|core\.askpass|credential\.(?:.+\.)?helper)=.*
    git config (?i:core\.hookspath|core\.askpass|credential\.(?:.+\.)?helper) [^-].*
    git config --unset|--unset-all|unset (?i:core\.hookspath)
"""
RULES = [
    (reason, line.split())
    for table, reason in (
        (SECRET_OUTPUTS, "資格情報や秘密値を直接出力・取得する操作は許可していません。"),
        (DESTRUCTIVE_OPERATIONS, DESTRUCTIVE_REASON),
        (EXEC_OVERRIDES, "保護機構や認証処理を迂回する実行設定は許可していません。"),
    )
    for line in table.strip().splitlines()
]

# 認証情報の保管先（小文字化した絶対パスのどの階層にあっても一致）
CREDENTIAL_PATH = re.compile(r"""/(?:
    \.env[^/]* | secrets | credentials
  | \.ssh(?!/[^/]*\.(?:pub|crt|cer)$) | \.gnupg | library/keychains
  | \.aws(?:$|/(?:credentials[^/]*|login|sso|cli)) | \.azure | \.config/gcloud
  | gcloud/(?:application_default_credentials\.json|credentials\.db|access_tokens\.db)[^/]*
  | \.kube/config[^/]* | gh/hosts\.yml[^/]* | \.docker/config\.json | (?:containers|\.?composer)/auth\.json
  | \.ocm\.json | ocm/ocm\.json[^/]* | helm/(?:repositories\.yaml|registry/config\.json)[^/]*
  | \.terraform\.d/credentials\.tfrc\.json | \.terraformrc | [^/]*\.tfstate[^/]* | \.vault-token
  | \.?cargo/credentials\.toml | pypoetry/auth\.toml | \.bundle/config | pip\.conf
  | \.git-credentials | \.netrc | \.pgpass | \.?pg_service\.conf | \.pypirc | \.curlrc | \.wgetrc
  | \.(?:zsh|bash)_(?:history|sessions) | fish_history
  | \.claude/(?:\.credentials\.json|shell-snapshots|backups) | \.claude\.json(?:\.backup)?
  | \.codex(?:-account-[^/]+)?/(?:auth\.json|\.credentials\.json|shell_snapshots)
  | orca/codex-(?:runtime-home|accounts/[^/]+)
    /(?:home/auth|system-default-auth|system-default-runtime-logout|shared-runtime-auth-provenance)\.json
  | \.hermes/(?:profiles/[^/]+/)?(?:
        (?:\.anthropic_oauth\.json|auth\.json|auth\.lock|auth/google_oauth\.json
          |cache/bws_cache(?:\.enc)?\.json|config\.yaml|webhook_subscriptions\.json)[^/]*
      | backups | browser[-_]profiles? | mcp-tokens | state-snapshots | vault
    )
  | hermes-snap-[^/]+\.sh(?:\.tmp\.[^/]+)?
  | id_(?:rsa|dsa|ecdsa|ed25519)(?![^/]*\.pub$)[^/]*
  | [^/]*\.(?:p12|pfx|p8|ppk|key|keystore|jks|kdbx)
  | [^/]*(?:service[-_]account|client[-_]secret|application_default_credentials)[^/]*\.json
  | (?![^/]*public)(?:[^/]*priv[^/]*|(?:[^/]*[-_.])?key)\.(?:pem|der)
)(?=/|$)""", re.X)
SECRET_WORDS = re.compile(
    r"(?:^|_)(?:TOKENS?|SECRETS?|PASSWORD|PASSWD|CREDENTIALS?|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY)(?:_|$)"
)
HOME_VARIABLES = {"HOME": "~", "CODEX_HOME": "~/.codex", "HERMES_HOME": "~/.hermes"}

# 本文を出力・複製・送信するコマンド
PATTERN_FIRST = {"awk", "egrep", "fgrep", "gawk", "grep", "gsed", "jq", "mawk", "nawk", "rg", "sed", "yq"}
COPIERS = {"cp", "rsync", "scp"}
READERS = PATTERN_FIRST | COPIERS | set("""
    base32 base64 cat comm curl cut dd diff head hexdump less
    more nl od paste sort strings tail tar uniq xxd
""".split())
# 引数を子コマンドとして起動するコマンドと、-- の後ろを子コマンドとして起動するコマンド
RUNNERS = set("arch builtin caffeinate command coproc env exec nice nohup sudo time timeout xargs".split())
DELEGATORS = {"docker", "kubectl", "mise", "npm", "npx", "oc", "pnpm", "yarn"}
SHELLS = {"bash", "dash", "ksh", "sh", "zsh"}
KEYWORDS = {"!", "do", "elif", "else", "if", "then", "until", "while", "{"}

ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\+?=")
# ${NAME:+…} は値を出力しない
EXPANSION = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])(?!:?\+)")
HEREDOC = re.compile(
    r"((?<!<)<<-?[ \t]*(['\"]?)([^\s'\"<>|&;()]+)\2)([^\n]*)\n(.*?)^[ \t]*\3[ \t]*$", re.S | re.M
)
TOKEN = re.compile(r"""
    (?P<blank>[ \t\r]+)
  | (?P<continuation>\\\n)
  | (?P<comment>(?<![^\s;&|()<>])\#[^\n]*)
  | (?P<single>'[^']*')
  | (?P<escape>\\.)
  | (?P<operator>
        (?:(?<![^\s;&|()<>])\d+(?=[<>]))?(?:<<<|<<-?|[<>]&|&>>?|>>|>\||<>|[<>])
      | \|\||&&|;;|[;&|()\n]
    )
  | (?P<plain>`[^`]*`|.)
""", re.X | re.S)


def expand(value):
    """~ とホームを指す変数を展開"""
    return os.path.expanduser(re.sub(
        r"\$(?:(\w+)|\{(\w+)\})",
        lambda match: HOME_VARIABLES.get(match[1] or match[2], match[0]),
        value,
    ))


def credential_path(value, cwd):
    """認証情報を指すパスか判定（本文は読まず、symlink の解決先も対象）"""
    if not value:
        return False
    path = os.path.join(cwd, expand(value))
    return any(
        CREDENTIAL_PATH.search(spelling.casefold())
        for spelling in (os.path.normpath(path), os.path.realpath(path))
    )


def secret_name(name):
    """変数名・設定キーが秘密値を表すか判定（パスを指す名前は除く）"""
    name = name.upper()
    return bool(SECRET_WORDS.search(name)) and not name.endswith(("_DIR", "_FILE", "_PATH"))


def in_order(patterns, args):
    """各正規表現に全体一致する引数が、この順に現れるか判定"""
    remaining = iter(args)
    return all(any(re.fullmatch(pattern, arg) for arg in remaining) for pattern in patterns)


def check(argv, cwd):
    """秘密の取得・重大な破壊・保護機構の迂回にあたるコマンドを拒否"""
    command, args = os.path.basename(argv[0]).casefold(), argv[1:]
    # 除外指定（--exclude の値・! で始まる glob）と数値は読み取り対象ではない
    operands = [
        arg for option, arg in zip(argv, args)
        if arg and not arg.startswith(("-", "!")) and not arg.isdigit() and not option.startswith("--exclude")
    ]
    # help・版数の表示は実行を伴わない（-- より後ろは子コマンドの引数）
    if not {"--help", "--version"} & set(args[:args.index("--")] if "--" in args else args):
        for reason, (name, *patterns) in RULES:
            if re.fullmatch(name, command) and in_order(patterns, args):
                raise Denied(reason)
        if command == "printenv" and (not operands or any(map(secret_name, operands))) or (
            command == "env" and all(arg.startswith("-") or "=" in arg for arg in args)
        ):
            raise Denied("環境変数の一括出力・秘密値の表示は許可していません。")
    if command == "rm" and in_order([r"--recursive|-[A-Za-z]*[rR][A-Za-z]*"], args):
        for target in args:
            path = os.path.realpath(os.path.join(cwd, expand(target)))
            if re.sub(r"/\*$", "", path) in {"", "/", os.path.realpath(expand("~"))}:
                raise Denied("ルート・ホーム全体の再帰削除は許可していません。")
    if command in READERS:
        if command in PATTERN_FIRST:
            # -e の値はパターン。-e も -f（パターン・プログラムのファイル）もなければ、最初の位置引数がパターン・プログラム
            patterns = [arg for option, arg in zip(argv, args) if option in {"-e", "--expression", "--regexp"}]
            first = 0 if patterns or {"-f", "--file", "--from-file"} & set(args) else 1
            operands = [operand for operand in operands if operand not in patterns][first:]
        if command in COPIERS:
            operands = operands[:-1]
        if command == "dd":
            operands = [arg.partition("=")[2] for arg in args if arg.startswith("if=")]
        if command == "curl":
            # --upload-file の値と、-T・file://・@・< に続くファイルは、本文を送信・出力する（URL 中の @ は除く）
            operands = [arg for option, arg in zip(argv, args) if option in {"-T", "--upload-file"}] + [
                arg[mark.end():].partition(";")[0]
                for arg in args if not re.match(r"(?!file:)[a-z]+://", arg)
                for mark in re.finditer(r"^-T|^file://|[@<]", arg)
            ]
        if any(credential_path(operand, cwd) for operand in operands):
            raise Denied(CREDENTIAL_REASON)
    if command in SHELLS:
        for index, arg in enumerate(args[:-1]):
            if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", arg):
                scan(args[index + 1], cwd)
    if command == "eval":
        scan(" ".join(args), cwd)
    if command in DELEGATORS and "--" in args[:-1]:
        inspect(args[args.index("--") + 1:], cwd)


def inspect(argv, cwd):
    """単純コマンドと、ラッパーが起動する子コマンドを検査"""
    # command -v・-V は子コマンドを起動しない
    runs = os.path.basename(argv[0]) in RUNNERS and argv[:2] not in (["command", "-v"], ["command", "-V"])
    for index in range(len(argv) if runs else 1):
        check(argv[index:], cwd)


def quote_end(text, start):
    """二重引用を閉じる " の位置（中のコマンド置換は対応する ) まで飛ばし、閉じていなければ末尾）"""
    while start < len(text) and text[start] != '"':
        if text.startswith("$(", start):
            start = closing(text, start + 2)
        else:
            start += 2 if text[start] == "\\" else 1
    return start


def closing(text, start):
    """$( に対応する ) の次の位置（引用内の括弧は数えず、閉じていなければ末尾）"""
    depth = 1
    while start < len(text) and depth:
        char = text[start]
        if char == '"':
            start = quote_end(text, start + 1) + 1
        elif char == "'":
            start = text.find("'", start + 1) + 1 or len(text)
        else:
            depth += (char == "(") - (char == ")")
            start += 2 if char == "\\" else 1
    return start


def live_part(body):
    """二重引用・未引用 heredoc の本文のうち、シェルが展開する部分（\\$ と \\` は展開しない）"""
    return re.sub(r"\\(.)", lambda match: "" if match[1] in "$`" else match[0], body, flags=re.S)


def substitutions(live):
    """シェルが展開する部分に含まれるコマンド置換の本文"""
    bodies, start = re.findall(r"`([^`]*)`", live), live.find("$(")
    while start >= 0:
        end = closing(live, start + 2)
        bodies.append(live[start + 2:end].removesuffix(")"))
        start = live.find("$(", end)
    return bodies


def tokenize(text):
    """演算子（文字列）と語（引用を解除した値, シェルが展開する部分）に分割"""
    tokens, value, live, index = [], None, "", 0
    while index < len(text):
        match = TOKEN.match(text, index)
        kind, piece = match.lastgroup, match.group()
        # 二重引用と引用外のコマンド置換は、対応する終わりまでを語の一部とする
        if piece == '"':
            kind, piece = "double", text[index:quote_end(text, index + 1) + 1]
        elif text.startswith("$(", index):
            piece = text[index:closing(text, index + 2)]
        index += len(piece)
        if kind in {"blank", "comment", "operator"}:
            if value is not None:
                tokens.append((value, live))
                value, live = None, ""
            if kind == "operator":
                # リダイレクトの fd 番号は除く
                tokens.append(piece.lstrip("0123456789"))
        elif kind != "continuation":
            value = value or ""
            if kind == "single":
                value += piece[1:-1]
            elif kind == "double":
                body = piece[1:].removesuffix('"')
                value += re.sub(r"\\([$`\"\\])", r"\1", body)
                live += live_part(body)
            elif kind == "escape":
                value += piece[1]
            else:
                value += piece
                live += piece
    return tokens + ([(value, live)] if value is not None else [])


def strip_heredoc(match):
    """終端を引用した heredoc の本文はデータとして除き、未引用の本文は同じコマンドの語（NUL と16進）に置き換える"""
    if match[2]:
        return match[1] + match[4]
    return f"{match[1]} <<<\0{live_part(match[5]).encode('utf-8', 'surrogatepass').hex()}{match[4]}"


def scan(text, cwd):
    """シェルコードを単純コマンドへ分けて検査（変数値・関数・実行結果は推論しない）"""
    argv, lives, redirect, outer, piped = [], [], None, [], False
    for token in tokenize(HEREDOC.sub(strip_heredoc, text)) + ["\n"]:
        if isinstance(token, tuple):
            value, live = token
            # 未引用の heredoc の本文は、シェルが展開する部分として検査
            if value.startswith("\0"):
                live = bytes.fromhex(value[1:]).decode("utf-8", "surrogatepass")
            lives.append(live)
            if redirect in {"<", "<>"} and credential_path(value, cwd):
                raise Denied(CREDENTIAL_REASON)
            if redirect and ">" in redirect and re.match(r"/dev/(?:r?disk|sd|nvme)", value):
                raise Denied(DESTRUCTIVE_REASON)
            if redirect is None:
                argv.append(value)
            redirect = None
        elif "<" in token or ">" in token:
            redirect = token
        else:
            while argv and (argv[0] in KEYWORDS or ASSIGNMENT.match(argv[0])):
                del argv[0]
            names = []
            for live in lives:
                # コマンド置換の本文は別のシェルコードとして検査し、変数の展開は置換の外だけを見る
                for body in substitutions(live):
                    scan(body, cwd)
                    live = live.replace(body, "")
                names += EXPANSION.findall(live)
            # test は値を出力しない
            if argv[:1] not in (["test"], ["["], ["[["]) and any(map(secret_name, names)):
                raise Denied("秘密値を持つ環境変数の明示展開は許可していません。")
            if argv:
                inspect(argv, cwd)
            # 後続の相対パスを移動先で解決する（パイプ・バックグラウンドの cd と、存在しない移動先は親に及ばない）
            if argv[:1] == ["cd"] and token not in {"|", "&"} and not piped:
                target = os.path.join(cwd, expand(argv[-1] if len(argv) > 1 else "~"))
                cwd = target if os.path.isdir(target) else cwd
            # サブシェルを抜けたら作業場所を戻す
            if token == "(":
                outer.append(cwd)
            elif token == ")" and outer:
                cwd = outer.pop()
            argv, lives, redirect, piped = [], [], None, token == "|"


def main():
    """Bash・Monitor 入力の検査と deny 出力"""
    try:
        event = json.load(sys.stdin)
        if event["tool_name"] not in {"Bash", "Monitor"}:
            return 0
        tool_input = event["tool_input"]
        # Monitor の WebSocket 監視はコマンドを実行しない
        if event["tool_name"] != "Monitor" or "command" in tool_input or "ws" not in tool_input:
            scan(tool_input["command"], event.get("cwd") or os.getcwd())
    except Denied as error:
        json.dump({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny",
            "permissionDecisionReason": str(error),
        }}, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
    except Exception:
        print("pre-bash-guard: 入力を安全に解析できませんでした。", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
