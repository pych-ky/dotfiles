#!/usr/bin/env bash
#
# ============================================================================
# 危険な Bash コマンドをブロックする PreToolUse フックスクリプト
# ============================================================================

set -u

main() {
  # 正規表現だけでは引用符・ヒアドキュメント・ネストしたシェルを区別できないため、標準 Python で構文走査する
  command -v python3 >/dev/null 2>&1 || {
    printf 'pre-bash-guard.sh: python3 is required but not installed\n' >&2
    exit 2
  }

  # フックイベント JSON を標準入力に残すため、スキャナー本体は -c で渡す
  # Apple 付属の Python はパイプ入力時に /dev/fd のスクリプトを読めない
  local scanner_source=
  local scanner_status
  IFS= read -r -d '' scanner_source <<'PYTHON' || true
import json
import os
import re
import shlex
import sys


# ============================================================================
# 定数
# ============================================================================

RM_REASON = "rm -rf / rm -Rf / rm --recursive --force は許可していません。"
SUDO_REASON = "sudo の使用は Claude からは許可していません。"
PIPE_SHELL_REASON = "curl / wget ... | sh / bash 形式のコマンドは許可していません。"
SHELL_STDIN_REASON = "内容を安全に検証できない標準入力を shell script として実行できません。"
PARSE_REASON = "Bash コマンドを安全に解析できませんでした。"

PUNCTUATION = ";&|()<>\n"
LITERAL_PUNCTUATION_ENCODE = {
    character: chr(0xE100 + index) for index, character in enumerate(PUNCTUATION)
}
LITERAL_PUNCTUATION_DECODE = {
    ord(encoded): character for character, encoded in LITERAL_PUNCTUATION_ENCODE.items()
}
QUOTED_WORD_MARKER = chr(0xE200)
LITERAL_PUNCTUATION_DECODE[ord(QUOTED_WORD_MARKER)] = None
CONTROL_OPERATORS = {
    ";",
    ";;",
    ";&",
    ";;&",
    "&",
    "&&",
    "|",
    "|&",
    "||",
    "\n",
    "(",
    ")",
}
PIPE_OPERATORS = {"|", "|&"}
SHELL_COMMANDS = {"bash", "dash", "ksh", "sh", "zsh"}
SHELL_FD0_PATHS = {"/dev/fd/0", "/dev/stdin", "/proc/self/fd/0"}
SHELL_STDIN_PATHS = {"-"} | SHELL_FD0_PATHS
REDIRECTIONS = {
    "<",
    ">",
    "<<",
    ">>",
    "<<<",
    "<>",
    "<&",
    ">&",
    ">|",
    "&>",
    "&>>",
}
PUNCTUATION_OPERATORS = tuple(
    sorted(
        CONTROL_OPERATORS | REDIRECTIONS | {"((", "))", "()"},
        key=len,
        reverse=True,
    )
)
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]*\])?\+?=.*$", re.S)
ARRAY_ASSIGNMENT_RE = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]*\])?\+?=$", re.S
)
XARGS_REPLACEMENT_MARKER = "__xargs_replacement__"
UNQUOTED_EXPANSION_MARKER = "__unquoted_expansion__"
QUOTED_EXPANSION_MARKER = "__quoted_expansion__"
DYNAMIC_COMMAND_MARKERS = {
    "__arithmetic_expansion__",
    "__command_substitution__",
    "__process_substitution__",
    UNQUOTED_EXPANSION_MARKER,
    QUOTED_EXPANSION_MARKER,
    XARGS_REPLACEMENT_MARKER,
}
NESTED_COMMAND_MARKER_RE = re.compile(
    r"__(?:command|process)_substitution__(\d+)__"
)
ARITHMETIC_EXPRESSION_MARKER_RE = re.compile(
    r"__arithmetic_expansion__([0-9a-f]*)__"
)
ARITHMETIC_COMMAND_MARKER_RE = re.compile(r"__arithmetic_command__([0-9a-f]*)__")
NON_STDIN_FD_PATH_RE = re.compile(r"^/(?:dev/fd|proc/self/fd)/[1-9][0-9]*$")
ASSIGNMENT_PARTS_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*)(?:\[([^]]*)\])?(\+?)=(.*)$", re.S
)


# ============================================================================
# 字句・構文解析
# ============================================================================

class ShellScanError(Exception):
    pass


def add_reason(reasons, reason):
    if reason not in reasons:
        reasons.append(reason)


def command_basename(word):
    return os.path.basename(word.rstrip("/")) if "/" in word else word


def arithmetic_expression_marker(expression):
    return "__arithmetic_expansion__" + expression.encode("utf-8").hex() + "__"


def arithmetic_command_marker(expression):
    return "__arithmetic_command__" + expression.encode("utf-8").hex() + "__"


def parameter_arithmetic_markers(parameter):
    """パラメーター展開で算術評価される添字・部分文字列式をマーカー化する。"""
    match = re.match(
        r"^[!#]?(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])",
        parameter,
    )
    if not match:
        return ""
    cursor = match.end()
    markers = []
    if parameter.startswith("!") and cursor == len(parameter):
        # 間接展開先の配列添字などは再評価される
        indirect_name = parameter[1:]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", indirect_name):
            markers.append(arithmetic_expression_marker(indirect_name))
    if cursor < len(parameter) and parameter[cursor] == "[":
        subscript_start = cursor + 1
        cursor = subscript_start
        depth = 1
        while cursor < len(parameter) and depth:
            if parameter[cursor] == "[":
                depth += 1
            elif parameter[cursor] == "]":
                depth -= 1
            cursor += 1
        if depth:
            raise ShellScanError("unterminated parameter array subscript")
        subscript = parameter[subscript_start : cursor - 1]
        if subscript not in {"@", "*"}:
            markers.append(arithmetic_expression_marker(subscript))
    if (
        cursor < len(parameter)
        and parameter[cursor] == ":"
        and (
            cursor + 1 >= len(parameter)
            or parameter[cursor + 1] not in "-=+?"
        )
    ):
        markers.append(arithmetic_expression_marker(parameter[cursor + 1 :]))
    return "".join(markers)


def decode_ansi_c(value):
    """Bash の $'...' でコマンド名に使われる代表的なエスケープを復元する。"""
    escapes = {
        "a": "\a",
        "b": "\b",
        "e": "\x1b",
        "E": "\x1b",
        "f": "\f",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "v": "\v",
        "\\": "\\",
        "'": "'",
        '"': '"',
    }
    result = []
    index = 0
    while index < len(value):
        if value[index] != "\\" or index + 1 >= len(value):
            result.append(value[index])
            index += 1
            continue

        escaped = value[index + 1]
        if escaped in escapes:
            result.append(escapes[escaped])
            index += 2
            continue
        if escaped in "01234567":
            match = re.match(r"[0-7]{1,3}", value[index + 1 :])
            result.append(chr(int(match.group(0), 8)))
            index += 1 + len(match.group(0))
            continue
        if escaped == "x":
            match = re.match(r"[0-9A-Fa-f]{1,2}", value[index + 2 :])
            if match:
                result.append(chr(int(match.group(0), 16)))
                index += 2 + len(match.group(0))
                continue
        if escaped == "u":
            match = re.match(r"[0-9A-Fa-f]{1,4}", value[index + 2 :])
            if match:
                result.append(chr(int(match.group(0), 16)))
                index += 2 + len(match.group(0))
                continue
        if escaped == "U":
            match = re.match(r"[0-9A-Fa-f]{1,8}", value[index + 2 :])
            if match:
                result.append(chr(int(match.group(0), 16)))
                index += 2 + len(match.group(0))
                continue

        # Bash は未知のエスケープでもバックスラッシュを保持する
        result.append("\\" + escaped)
        index += 2

    return "".join(result)


def find_backtick_end(text, start):
    index = start
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == "`":
            return index
        index += 1
    raise ShellScanError("unterminated backtick command substitution")


def starts_alternate_command_substitution(text, index):
    return text.startswith("${|", index) or (
        text.startswith("${", index)
        and index + 2 < len(text)
        and text[index + 2].isspace()
    )


def find_arithmetic_end(text, start):
    """$(( の内容開始位置から、対応する )) の直後を返す。"""
    depth = 2
    quote = None
    index = start
    while index < len(text):
        character = text[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            elif text.startswith("$(", index) and not text.startswith("$((", index):
                index = find_parenthesized_end(text, index + 2)
            else:
                index += 1
            continue

        if character == "\\":
            index += 2
        elif character in {"'", '"'}:
            quote = character
            index += 1
        elif character == "`":
            index = find_backtick_end(text, index + 1) + 1
        elif text.startswith("$((", index):
            index = find_arithmetic_end(text, index + 3)
        elif text.startswith("$(", index):
            index = find_parenthesized_end(text, index + 2)
        elif character == "(":
            depth += 1
            index += 1
        elif character == ")":
            depth -= 1
            index += 1
            if depth == 0:
                return index
        else:
            index += 1
    raise ShellScanError("unterminated arithmetic expansion")


def find_parameter_expansion_end(text, start):
    """${ の内容開始位置から、クォートと入れ子を考慮して対応する } の直後を返す。"""
    depth = 1
    quote = None
    index = start
    while index < len(text):
        character = text[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            elif text.startswith("${", index):
                depth += 1
                index += 2
            elif text.startswith("$(", index):
                index = find_parenthesized_end(text, index + 2)
            elif character == "}":
                depth -= 1
                index += 1
                if depth == 0:
                    return index
            else:
                index += 1
            continue

        if character == "\\":
            index += 2
        elif character in {"'", '"'}:
            quote = character
            index += 1
        elif text.startswith("${", index):
            depth += 1
            index += 2
        elif text.startswith("$(", index):
            index = find_parenthesized_end(text, index + 2)
        elif character == "}":
            depth -= 1
            index += 1
            if depth == 0:
                return index
        else:
            index += 1
    raise ShellScanError("unterminated parameter expansion")


def find_parenthesized_end(text, start):
    """$( / <( / >( の内容開始位置から、対応する ) の直後を返す。"""
    depth = 1
    quote = None
    case_states = []
    at_command_start = True
    coproc_name_pending = False
    time_command_pending = False
    command_prefixes = {
        "if",
        "then",
        "elif",
        "else",
        "while",
        "until",
        "do",
        "!",
    }
    index = start
    while index < len(text):
        character = text[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            elif character == "`":
                index = find_backtick_end(text, index + 1) + 1
            elif text.startswith("$((", index):
                index = find_arithmetic_end(text, index + 3)
            elif text.startswith("$(", index):
                index = find_parenthesized_end(text, index + 2)
            elif text.startswith("${", index):
                index = find_parameter_expansion_end(text, index + 2)
            else:
                index += 1
            continue

        if (
            character == "#"
            and (
                index == start
                or text[index - 1].isspace()
                or text[index - 1] in ";&|()<>"
            )
        ):
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline + 1
            at_command_start = True
            continue
        if text.startswith("<<", index) and not text.startswith("<<<", index):
            # ネストしたヒアドキュメントを安全に読み飛ばせない場合は拒否する
            raise ShellScanError("heredoc in command substitution is unsupported")
        if (
            time_command_pending
            and character == "-"
            and (index == start or text[index - 1].isspace())
        ):
            option_end = index + 1
            while option_end < len(text) and not (
                text[option_end].isspace() or text[option_end] in ";&|()<>"
            ):
                option_end += 1
            if text[index:option_end] in {"-p", "--"}:
                index = option_end
                continue

        # case パターンの閉じ括弧はコマンド置換自体の閉じ括弧ではない
        in_case_pattern = case_states and case_states[-1]["mode"] == "pattern"
        if in_case_pattern:
            state = case_states[-1]
            if character.isspace():
                index += 1
                continue
            if (
                state["at_start"]
                and text.startswith("esac", index)
                and (
                    index + 4 == len(text)
                    or not (text[index + 4].isalnum() or text[index + 4] == "_")
                )
            ):
                case_states.pop()
                at_command_start = False
                index += 4
                continue
            if character == "(" and state["at_start"]:
                state["at_start"] = False
                index += 1
                continue
            if character == "(":
                state["pattern_depth"] += 1
                state["at_start"] = False
                index += 1
                continue
            if character == ")":
                if state["pattern_depth"]:
                    state["pattern_depth"] -= 1
                else:
                    state["mode"] = "body"
                    at_command_start = True
                index += 1
                continue
            if character == "|" and state["pattern_depth"] == 0:
                state["at_start"] = True
                index += 1
                continue
            state["at_start"] = False

        if case_states and case_states[-1]["mode"] == "body":
            for terminator in (";;&", ";;", ";&"):
                if text.startswith(terminator, index):
                    case_states[-1] = {
                        "mode": "pattern",
                        "pattern_depth": 0,
                        "at_start": True,
                    }
                    at_command_start = True
                    index += len(terminator)
                    break
            else:
                terminator = None
            if terminator is not None:
                continue

        if character.isalpha() or character == "_":
            end = index + 1
            while end < len(text) and (text[end].isalnum() or text[end] == "_"):
                end += 1
            word = text[index:end]
            at_word_boundary = (
                (
                    index == start
                    or text[index - 1].isspace()
                    or text[index - 1] in ";&|()<>"
                )
                and (
                    end == len(text)
                    or text[end].isspace()
                    or text[end] in ";&|()<>")
                )
            if not in_case_pattern and at_word_boundary:
                if case_states and case_states[-1]["mode"] == "word":
                    case_states[-1]["mode"] = "await_in"
                    at_command_start = False
                elif (
                    word == "in"
                    and case_states
                    and case_states[-1]["mode"] == "await_in"
                ):
                    case_states[-1] = {
                        "mode": "pattern",
                        "pattern_depth": 0,
                        "at_start": True,
                    }
                    at_command_start = True
                elif word == "case" and at_command_start:
                    case_states.append({"mode": "word"})
                    at_command_start = False
                    coproc_name_pending = False
                    time_command_pending = False
                elif (
                    word == "esac"
                    and at_command_start
                    and case_states
                    and case_states[-1]["mode"] == "body"
                ):
                    case_states.pop()
                    at_command_start = False
                elif word == "coproc" and at_command_start:
                    coproc_name_pending = True
                    time_command_pending = False
                    at_command_start = True
                elif coproc_name_pending and at_command_start:
                    coproc_name_pending = False
                    at_command_start = True
                elif word == "time" and at_command_start:
                    time_command_pending = True
                    at_command_start = True
                elif at_command_start and word in command_prefixes:
                    at_command_start = True
                else:
                    coproc_name_pending = False
                    time_command_pending = False
                    at_command_start = False
            elif not in_case_pattern and (
                index == start
                or text[index - 1].isspace()
                or text[index - 1] in ";&|()<>"
            ):
                if case_states and case_states[-1]["mode"] == "word":
                    case_states[-1]["mode"] = "await_in"
                coproc_name_pending = False
                time_command_pending = False
                at_command_start = False
            index = end
            continue

        if character == "\\":
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index += 2
        elif character in {"'", '"'}:
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            quote = character
            index += 1
        elif character == "`":
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index = find_backtick_end(text, index + 1) + 1
        elif text.startswith("$((", index):
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index = find_arithmetic_end(text, index + 3)
        elif text.startswith("$(", index):
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index = find_parenthesized_end(text, index + 2)
        elif text.startswith("${", index):
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index = find_parameter_expansion_end(text, index + 2)
        elif character == "(":
            depth += 1
            time_command_pending = False
            at_command_start = True
            index += 1
        elif character == ")":
            depth -= 1
            at_command_start = False
            index += 1
            if depth == 0:
                return index
        elif character in ";&|\n":
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = True
            index += 1
        elif character == "{":
            time_command_pending = False
            at_command_start = True
            index += 1
        else:
            if not character.isspace() and character not in "<>":
                if case_states and case_states[-1]["mode"] == "word":
                    case_states[-1]["mode"] = "await_in"
                coproc_name_pending = False
                time_command_pending = False
                at_command_start = False
            index += 1
    raise ShellScanError("unterminated command substitution")


def remove_shell_line_continuations(command):
    """シングルクォート外のバックスラッシュ改行をトークン化前に除去する。"""
    output = []
    quote = None
    index = 0
    while index < len(command):
        character = command[index]
        if (
            character == "\\"
            and index + 1 < len(command)
            and command[index + 1] == "\n"
        ):
            if quote != "'":
                index += 2
                continue
        output.append(character)
        if quote is None and character in {"'", '"'}:
            quote = character
        elif quote == character:
            quote = None
        if character == "\\" and quote != "'" and index + 1 < len(command):
            output.append(command[index + 1])
            index += 2
        else:
            index += 1
    return "".join(output)


def strip_shell_comments(command):
    """引用符外かつ単語先頭の # から改行までをコメントとして除去する。"""
    output = []
    quote = None
    at_word_start = True
    index = 0
    while index < len(command):
        character = command[index]
        if quote is None:
            if command.startswith("$(", index):
                if command.startswith("$((", index):
                    closing = find_arithmetic_end(command, index + 3)
                else:
                    closing = find_parenthesized_end(command, index + 2)
                output.append(command[index:closing])
                index = closing
                at_word_start = False
                continue
            if (
                character in {"<", ">"}
                and index + 1 < len(command)
                and command[index + 1] == "("
            ):
                closing = find_parenthesized_end(command, index + 2)
                output.append(command[index:closing])
                index = closing
                at_word_start = False
                continue
            if command.startswith("${", index):
                closing = find_parameter_expansion_end(command, index + 2)
                output.append(command[index:closing])
                index = closing
                at_word_start = False
                continue
            if character == "`":
                closing = find_backtick_end(command, index + 1) + 1
                output.append(command[index:closing])
                index = closing
                at_word_start = False
                continue
        if quote is None and character == "#" and at_word_start:
            while index < len(command) and command[index] != "\n":
                index += 1
            continue
        output.append(character)
        if quote is None:
            if character in {"'", '"'}:
                quote = character
                at_word_start = False
            elif character == "\\" and index + 1 < len(command):
                output.append(command[index + 1])
                index += 1
                at_word_start = False
            else:
                at_word_start = character.isspace() or character in ";&|()<>"
        elif character == quote:
            quote = None
            at_word_start = False
        elif character == "\\" and quote == '"' and index + 1 < len(command):
            output.append(command[index + 1])
            index += 1
        index += 1
    return "".join(output)


def mask_literal_punctuation(command):
    """引用された単語とリテラルの区切り文字を構文トークンから区別できるようマスクする。"""
    output = []
    quote = None
    index = 0
    while index < len(command):
        character = command[index]
        if quote is None:
            if character in {"'", '"'}:
                quote = character
                output.append(character)
                output.append(QUOTED_WORD_MARKER)
                index += 1
            elif character == "\\" and index + 1 < len(command):
                escaped = command[index + 1]
                if escaped in LITERAL_PUNCTUATION_ENCODE:
                    output.append(LITERAL_PUNCTUATION_ENCODE[escaped])
                else:
                    output.append(character + escaped)
                index += 2
            else:
                output.append(character)
                index += 1
            continue

        if character == quote:
            quote = None
            output.append(character)
            index += 1
        elif character == "\\" and quote == '"' and index + 1 < len(command):
            escaped = command[index + 1]
            output.append(character)
            output.append(LITERAL_PUNCTUATION_ENCODE.get(escaped, escaped))
            index += 2
        else:
            output.append(LITERAL_PUNCTUATION_ENCODE.get(character, character))
            index += 1
    return "".join(output)


def decode_literal_punctuation(value):
    return value.translate(LITERAL_PUNCTUATION_DECODE)


def mask_arithmetic_for_heredocs(command):
    """算術式内の << をヒアドキュメント演算子と誤認しないよう、改行以外を空白化する。"""
    masked = list(command)
    quote = None
    index = 0
    while index < len(command):
        character = command[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            elif command.startswith("$((", index):
                closing = find_arithmetic_end(command, index + 3)
                for position in range(index, closing):
                    if command[position] not in "\r\n":
                        masked[position] = " "
                index = closing
            else:
                index += 1
            continue

        if character == "\\":
            index += 2
        elif character in {"'", '"'}:
            quote = character
            index += 1
        elif command.startswith("$((", index):
            closing = find_arithmetic_end(command, index + 3)
            for position in range(index, closing):
                if command[position] not in "\r\n":
                    masked[position] = " "
            index = closing
        elif command.startswith("((", index):
            closing = find_arithmetic_end(command, index + 2)
            for position in range(index, closing):
                if command[position] not in "\r\n":
                    masked[position] = " "
            index = closing
        else:
            index += 1
    return "".join(masked)


def parse_heredoc_word(line, start):
    index = start
    while index < len(line) and line[index] in " \t":
        index += 1

    value = []
    quoted = False
    while index < len(line):
        character = line[index]
        if character in " \t\r\n;&|()<>":
            break
        if character == "\\":
            quoted = True
            if index + 1 < len(line):
                value.append(line[index + 1])
                index += 2
            else:
                index += 1
            continue
        if line.startswith("$'", index):
            quoted = True
            cursor = index + 2
            raw = []
            while cursor < len(line):
                if line[cursor] == "\\" and cursor + 1 < len(line):
                    raw.append(line[cursor : cursor + 2])
                    cursor += 2
                elif line[cursor] == "'":
                    break
                else:
                    raw.append(line[cursor])
                    cursor += 1
            if cursor >= len(line):
                raise ShellScanError("unterminated ANSI-C quote in heredoc delimiter")
            value.append(decode_ansi_c("".join(raw)))
            index = cursor + 1
            continue
        if character == "'":
            quoted = True
            closing = line.find("'", index + 1)
            if closing < 0:
                raise ShellScanError("unterminated quote in heredoc delimiter")
            value.append(line[index + 1 : closing])
            index = closing + 1
            continue
        if character == '"' or line.startswith('$"', index):
            quoted = True
            index += 2 if line.startswith('$"', index) else 1
            while index < len(line) and line[index] != '"':
                if line[index] == "\\" and index + 1 < len(line):
                    escaped = line[index + 1]
                    if escaped in {'$', '`', '"', "\\"}:
                        value.append(escaped)
                        index += 2
                    elif escaped == "\n":
                        index += 2
                    else:
                        value.append("\\" + escaped)
                        index += 2
                else:
                    value.append(line[index])
                    index += 1
            if index >= len(line):
                raise ShellScanError("unterminated quote in heredoc delimiter")
            index += 1
            continue
        value.append(character)
        index += 1

    return "".join(value), quoted, index


def heredocs_on_line(line):
    heredocs = []
    quote = None
    index = 0
    at_word_start = True
    while index < len(line):
        character = line[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            else:
                index += 1
            continue

        if character == "\\":
            index += 2
            at_word_start = False
        elif character in {"'", '"'}:
            quote = character
            index += 1
            at_word_start = False
        elif character == "#" and at_word_start:
            break
        elif line.startswith("<<<", index):
            index += 3
            at_word_start = True
        elif line.startswith("<<", index):
            index += 2
            strip_tabs = False
            if index < len(line) and line[index] == "-":
                strip_tabs = True
                index += 1
            delimiter, quoted, index = parse_heredoc_word(line, index)
            if not delimiter:
                raise ShellScanError("missing heredoc delimiter")
            heredocs.append((delimiter, strip_tabs, quoted))
            at_word_start = False
        else:
            at_word_start = character.isspace() or character in ";&|()<>"
            index += 1
    return heredocs


def strip_heredoc_bodies(command):
    """本文をトークンから除き、各本文と引用有無を出現順で返す。"""
    lines = command.splitlines(True)
    scan_lines = mask_arithmetic_for_heredocs(command).splitlines(True)
    output = []
    heredoc_regions = []
    index = 0
    while index < len(lines):
        header = lines[index]
        output.append(header)
        pending = heredocs_on_line(scan_lines[index])
        index += 1

        for delimiter, strip_tabs, quoted in pending:
            body = []
            found = False
            while index < len(lines):
                line = lines[index]
                comparison = line.rstrip("\r\n")
                if strip_tabs:
                    comparison = comparison.lstrip("\t")
                output.append("\n" if line.endswith(("\n", "\r")) else "")
                index += 1
                if comparison == delimiter:
                    found = True
                    break
                body.append(line)
            heredoc_regions.append(("".join(body), quoted))
            if not found:
                raise ShellScanError("unterminated heredoc")

    return "".join(output), heredoc_regions


def collect_substitutions(command, nested=None, mark_unquoted_fields=True):
    """ネストしたコマンドを回収し、外側の shlex 用には無害な単語へ置換する。"""
    output = []
    if nested is None:
        nested = []

    def register_nested(body, kind="command"):
        marker = "__{}_substitution__{}__".format(kind, len(nested))
        nested.append(body)
        return marker

    quote = None
    index = 0
    while index < len(command):
        character = command[index]
        if quote == "'":
            output.append(character)
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                output.append(command[index : index + 2])
                index += 2
            elif character == '"':
                output.append(character)
                quote = None
                index += 1
            elif character == "`":
                closing = find_backtick_end(command, index + 1)
                body = command[index + 1 : closing].replace("\\`", "`")
                output.append(register_nested(body))
                index = closing + 1
            elif command.startswith("$((", index):
                closing = find_arithmetic_end(command, index + 3)
                arithmetic = command[index + 3 : closing - 2]
                arithmetic_sanitized, _ = collect_substitutions(
                    arithmetic,
                    nested,
                    mark_unquoted_fields=False,
                )
                markers = "".join(
                    match.group(0)
                    for match in NESTED_COMMAND_MARKER_RE.finditer(arithmetic_sanitized)
                )
                output.append(
                    arithmetic_expression_marker(arithmetic_sanitized) + markers
                )
                index = closing
            elif command.startswith("$(", index):
                closing = find_parenthesized_end(command, index + 2)
                output.append(register_nested(command[index + 2 : closing - 1]))
                index = closing
            elif starts_alternate_command_substitution(command, index):
                raise ShellScanError("alternate command substitution is unsupported")
            elif command.startswith("${", index):
                closing = find_parameter_expansion_end(command, index + 2)
                parameter = command[index + 2 : closing - 1]
                parameter_sanitized, _ = collect_substitutions(
                    parameter,
                    nested,
                    mark_unquoted_fields=False,
                )
                output.append(
                    QUOTED_EXPANSION_MARKER
                    + parameter_arithmetic_markers(parameter_sanitized)
                )
                index = closing
            elif character == "$" and index + 1 < len(command):
                parameter_start = index + 1
                if (
                    command[parameter_start].isalpha()
                    or command[parameter_start] == "_"
                ):
                    parameter_end = parameter_start + 1
                    while parameter_end < len(command) and (
                        command[parameter_end].isalnum()
                        or command[parameter_end] == "_"
                    ):
                        parameter_end += 1
                    output.append(QUOTED_EXPANSION_MARKER)
                    index = parameter_end
                elif (
                    command[parameter_start].isdigit()
                    or command[parameter_start] in "*@#?-$!_"
                ):
                    output.append(QUOTED_EXPANSION_MARKER)
                    index += 2
                else:
                    output.append(character)
                    index += 1
            else:
                output.append(character)
                index += 1
            continue

        if character == "\\":
            output.append(command[index : index + 2])
            index += 2
        elif command.startswith("$'", index):
            cursor = index + 2
            raw = []
            while cursor < len(command):
                if command[cursor] == "\\" and cursor + 1 < len(command):
                    raw.append(command[cursor : cursor + 2])
                    cursor += 2
                elif command[cursor] == "'":
                    break
                else:
                    raw.append(command[cursor])
                    cursor += 1
            if cursor >= len(command):
                raise ShellScanError("unterminated ANSI-C quote")
            output.append(shlex.quote(decode_ansi_c("".join(raw))))
            index = cursor + 1
        elif command.startswith('$"', index):
            output.append('"')
            quote = '"'
            index += 2
        elif character in {"'", '"'}:
            output.append(character)
            quote = character
            index += 1
        elif character == "`":
            closing = find_backtick_end(command, index + 1)
            body = command[index + 1 : closing].replace("\\`", "`")
            output.append(UNQUOTED_EXPANSION_MARKER + register_nested(body))
            index = closing + 1
        elif command.startswith("$((", index):
            closing = find_arithmetic_end(command, index + 3)
            arithmetic = command[index + 3 : closing - 2]
            arithmetic_sanitized, _ = collect_substitutions(
                arithmetic,
                nested,
                mark_unquoted_fields=False,
            )
            markers = "".join(
                match.group(0)
                for match in NESTED_COMMAND_MARKER_RE.finditer(arithmetic_sanitized)
            )
            output.append(
                UNQUOTED_EXPANSION_MARKER
                + arithmetic_expression_marker(arithmetic_sanitized)
                + markers
            )
            index = closing
        elif command.startswith("$(", index):
            closing = find_parenthesized_end(command, index + 2)
            output.append(
                UNQUOTED_EXPANSION_MARKER
                + register_nested(command[index + 2 : closing - 1])
            )
            index = closing
        elif command.startswith("((", index):
            closing = find_arithmetic_end(command, index + 2)
            arithmetic = command[index + 2 : closing - 2]
            arithmetic_sanitized, _ = collect_substitutions(
                arithmetic,
                nested,
                mark_unquoted_fields=False,
            )
            output.append("((" + arithmetic_sanitized + "))")
            index = closing
        elif starts_alternate_command_substitution(command, index):
            raise ShellScanError("alternate command substitution is unsupported")
        elif command.startswith("${", index):
            closing = find_parameter_expansion_end(command, index + 2)
            parameter = command[index + 2 : closing - 1]
            parameter_sanitized, _ = collect_substitutions(parameter, nested)
            markers = "".join(
                match.group(0)
                for match in NESTED_COMMAND_MARKER_RE.finditer(parameter_sanitized)
            )
            output.append(
                UNQUOTED_EXPANSION_MARKER
                + parameter_arithmetic_markers(parameter_sanitized)
                + markers
            )
            index = closing
        elif character == "$" and index + 1 < len(command):
            parameter_start = index + 1
            if command[parameter_start].isalpha() or command[parameter_start] == "_":
                parameter_end = parameter_start + 1
                while parameter_end < len(command) and (
                    command[parameter_end].isalnum() or command[parameter_end] == "_"
                ):
                    parameter_end += 1
                output.append(UNQUOTED_EXPANSION_MARKER)
                index = parameter_end
            elif (
                command[parameter_start].isdigit()
                or command[parameter_start] in "*@#?-$!_"
            ):
                output.append(UNQUOTED_EXPANSION_MARKER)
                index += 2
            else:
                output.append(character)
                index += 1
        elif (
            character in {"<", ">"}
            and index + 1 < len(command)
            and command[index + 1] == "("
        ):
            closing = find_parenthesized_end(command, index + 2)
            output.append(
                register_nested(command[index + 2 : closing - 1], "process")
            )
            index = closing
        elif mark_unquoted_fields and character in "*?":
            output.append(UNQUOTED_EXPANSION_MARKER + character)
            index += 1
        elif mark_unquoted_fields and character == "[":
            word_start = index
            while word_start > 0 and not (
                command[word_start - 1].isspace()
                or command[word_start - 1] in ";&|()<>"
            ):
                word_start -= 1
            word_end = index + 1
            while word_end < len(command) and not (
                command[word_end].isspace() or command[word_end] in ";&|()<>"
            ):
                if command[word_end] == "]":
                    full_word_end = word_end + 1
                    while full_word_end < len(command) and not (
                        command[full_word_end].isspace()
                        or command[full_word_end] in ";&|()<>"
                    ):
                        full_word_end += 1
                    if ASSIGNMENT_RE.match(command[word_start:full_word_end]):
                        output.append(character)
                    else:
                        output.append(character + UNQUOTED_EXPANSION_MARKER)
                    break
                word_end += 1
            else:
                output.append(character)
            index += 1
        elif mark_unquoted_fields and character == "{":
            word_end = index + 1
            has_comma = False
            while word_end < len(command) and not (
                command[word_end].isspace() or command[word_end] in ";&|()<>"
            ):
                has_comma = has_comma or command[word_end] == ","
                if command[word_end] == "}":
                    output.append(
                        UNQUOTED_EXPANSION_MARKER + character
                        if has_comma
                        else character
                    )
                    break
                word_end += 1
            else:
                output.append(character)
            index += 1
        else:
            output.append(character)
            index += 1

    if quote is not None:
        raise ShellScanError("unterminated shell quote")
    return "".join(output), nested


def collect_heredoc_substitutions(body):
    """引用なしヒアドキュメントのコマンド置換と算術式を回収する。"""
    nested = []
    arithmetic_expressions = []
    index = 0
    while index < len(body):
        if body[index] == "\\":
            index += 2
        elif body[index] == "`":
            closing = find_backtick_end(body, index + 1)
            nested.append(body[index + 1 : closing])
            index = closing + 1
        elif body.startswith("$((", index):
            closing = find_arithmetic_end(body, index + 3)
            arithmetic = body[index + 3 : closing - 2]
            arithmetic_sanitized, arithmetic_nested = collect_substitutions(arithmetic)
            nested.extend(arithmetic_nested)
            arithmetic_expressions.append(arithmetic_sanitized)
            index = closing
        elif body.startswith("$(", index):
            closing = find_parenthesized_end(body, index + 2)
            nested.append(body[index + 2 : closing - 1])
            index = closing
        elif body.startswith("${", index):
            closing = find_parameter_expansion_end(body, index + 2)
            parameter = body[index + 2 : closing - 1]
            parameter_sanitized, parameter_nested = collect_substitutions(parameter)
            nested.extend(parameter_nested)
            markers = parameter_arithmetic_markers(parameter_sanitized)
            for match in ARITHMETIC_EXPRESSION_MARKER_RE.finditer(markers):
                try:
                    arithmetic_expressions.append(
                        bytes.fromhex(match.group(1)).decode("utf-8")
                    )
                except (ValueError, UnicodeDecodeError):
                    raise ShellScanError("invalid arithmetic expression marker")
            index = closing
        else:
            index += 1
    return nested, arithmetic_expressions


def expand_punctuation(token):
    if not token or any(character not in PUNCTUATION for character in token):
        return [token]
    result = []
    index = 0
    while index < len(token):
        for operator in PUNCTUATION_OPERATORS:
            if token.startswith(operator, index):
                if operator == "()":
                    result.extend(("(", ")"))
                else:
                    result.append(operator)
                index += len(operator)
                break
        else:
            result.append(token[index])
            index += 1
    return result


def shell_tokens(command):
    command = mask_literal_punctuation(command)
    lexer = shlex.shlex(command, posix=True, punctuation_chars=PUNCTUATION)
    # 引用符外の改行はコマンド区切りとして残す
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    # コメントは単語途中の # を誤認しないよう strip_shell_comments で処理済み
    lexer.commenters = ""
    try:
        raw_tokens = list(lexer)
    except ValueError as error:
        raise ShellScanError(str(error))

    tokens = []
    for token in raw_tokens:
        tokens.extend(expand_punctuation(token))
    return suppress_noncommand_groups(suppress_case_patterns(tokens))


def suppress_noncommand_groups(tokens):
    """算術コマンドと配列代入の本文をコマンド候補から除外する。"""
    result = []
    index = 0
    while index < len(tokens):
        if tokens[index] == "((":
            depth = 1
            expression = []
            index += 1
            while index < len(tokens) and depth:
                if tokens[index] == "((":
                    depth += 1
                elif tokens[index] == "))":
                    depth -= 1
                    if not depth:
                        index += 1
                        break
                if depth:
                    expression.append(tokens[index])
                index += 1
            if depth:
                raise ShellScanError("unterminated arithmetic command")
            result.append(arithmetic_command_marker(" ".join(expression)))
            continue
        if (
            ARRAY_ASSIGNMENT_RE.match(tokens[index])
            and index + 1 < len(tokens)
            and tokens[index + 1] == "("
        ):
            assignment = tokens[index]
            arithmetic_markers = []
            depth = 1
            index += 2
            while index < len(tokens) and depth:
                if tokens[index] == "(":
                    depth += 1
                elif tokens[index] == ")":
                    depth -= 1
                elif depth == 1:
                    element = decode_literal_punctuation(tokens[index])
                    if element.startswith("["):
                        closing = element.find("]")
                        if closing < 0:
                            raise ShellScanError(
                                "unterminated array assignment subscript"
                            )
                        subscript = element[1:closing]
                        if subscript.startswith(UNQUOTED_EXPANSION_MARKER):
                            # collect_substitutions が `[...]` を glob として付けたマーカー
                            subscript = subscript[len(UNQUOTED_EXPANSION_MARKER) :]
                        arithmetic_markers.append(
                            arithmetic_expression_marker(subscript)
                        )
                index += 1
            if depth:
                raise ShellScanError("unterminated array assignment")
            result.append(assignment + "".join(arithmetic_markers))
            continue
        result.append(tokens[index])
        index += 1
    return result


def suppress_case_patterns(tokens):
    """case の選択パターンをコマンド候補から除外する。"""
    result = []
    case_states = []
    at_command_start = True
    redirection_operand = False
    command_prefixes = {
        "if",
        "then",
        "elif",
        "else",
        "while",
        "until",
        "do",
        "!",
        "{",
    }
    clause_terminators = {";;", ";&", ";;&"}

    for token in tokens:
        if case_states and case_states[-1]["mode"] == "pattern":
            state = case_states[-1]
            if token == "\n":
                continue
            if state["at_start"] and token == "esac":
                result.append(token)
                case_states.pop()
                at_command_start = False
                continue
            if token and all(character in "()" for character in token):
                for character in token:
                    if state["mode"] != "pattern":
                        result.append(character)
                        at_command_start = True
                    elif character == "(" and state["at_start"]:
                        state["at_start"] = False
                    elif character == "(":
                        state["pattern_depth"] += 1
                        state["at_start"] = False
                    elif state["pattern_depth"]:
                        state["pattern_depth"] -= 1
                    else:
                        state["mode"] = "body"
                        result.append(character)
                        at_command_start = True
                continue
            if token == "|" and state["pattern_depth"] == 0:
                state["at_start"] = True
                continue
            state["at_start"] = False
            continue

        if case_states and case_states[-1]["mode"] == "word":
            result.append(token)
            if token != "\n":
                case_states[-1]["mode"] = "await_in"
            continue

        if case_states and case_states[-1]["mode"] == "await_in":
            result.append(token)
            if token == "in":
                case_states[-1] = {
                    "mode": "pattern",
                    "pattern_depth": 0,
                    "at_start": True,
                }
            continue

        if case_states and case_states[-1]["mode"] == "body":
            if token in clause_terminators:
                result.append(token)
                case_states[-1] = {
                    "mode": "pattern",
                    "pattern_depth": 0,
                    "at_start": True,
                }
                at_command_start = True
                continue
            if token == "esac" and at_command_start:
                result.append(token)
                case_states.pop()
                at_command_start = False
                continue

        if at_command_start and token == "case":
            result.append(token)
            case_states.append({"mode": "word"})
            at_command_start = False
            continue

        result.append(token)
        if token in REDIRECTIONS:
            redirection_operand = True
        elif redirection_operand:
            redirection_operand = False
        elif token in CONTROL_OPERATORS:
            at_command_start = True
        elif at_command_start and (
            token in command_prefixes or ASSIGNMENT_RE.match(token)
        ):
            continue
        else:
            at_command_start = False

    return result


def split_command_units(tokens):
    units = []
    current = []
    previous_operator = None
    group_depth = 0
    for token in tokens:
        # 括弧なしの function 定義でも本体を別コマンドにする
        function_prefix = 0
        while function_prefix < len(current) and current[function_prefix] in {
            "{",
            "then",
            "elif",
            "else",
            "do",
        }:
            function_prefix += 1
        if (
            token == "{"
            and function_prefix < len(current)
            and command_basename(current[function_prefix]) == "function"
        ):
            units.append(
                {
                    "tokens": current,
                    "before": previous_operator,
                    "after": "{",
                    "group_depth": group_depth,
                }
            )
            current = ["{"]
            previous_operator = "{"
            continue
        if token in CONTROL_OPERATORS:
            if current:
                units.append(
                    {
                        "tokens": current,
                        "before": previous_operator,
                        "after": token,
                        "group_depth": group_depth,
                    }
                )
                current = []
            if token == "(":
                group_depth += 1
            elif token == ")" and group_depth:
                group_depth -= 1
            previous_operator = token
        else:
            current.append(token)
    if current:
        units.append(
            {
                "tokens": current,
                "before": previous_operator,
                "after": None,
                "group_depth": group_depth,
            }
        )
    return units


def remove_redirections(tokens, heredoc_bodies, heredoc_index):
    argv = []
    stdin_commands = []
    stdin_is_external = False
    stdin_is_redirected = False
    index = 0
    while index < len(tokens):
        redirection_fd = None
        if (
            (
                tokens[index].isdigit()
                or re.match(r"^\{[A-Za-z_][A-Za-z0-9_]*\}$", tokens[index])
            )
            and index + 1 < len(tokens)
            and tokens[index + 1] in REDIRECTIONS
        ):
            redirection_fd = tokens[index]
            index += 1
        if index < len(tokens) and tokens[index] in REDIRECTIONS:
            operator = tokens[index]
            redirects_stdin = redirection_fd in {None, "0"}
            index += 1
            if index < len(tokens):
                operand = tokens[index]
                index += 1
                if operator == "<<":
                    if heredoc_index >= len(heredoc_bodies):
                        raise ShellScanError("heredoc body could not be associated")
                    if redirects_stdin:
                        stdin_is_redirected = True
                        stdin_is_external = False
                        stdin_commands = [heredoc_bodies[heredoc_index][0]]
                    if not heredoc_bodies[heredoc_index][1]:
                        _, arithmetic_expressions = collect_heredoc_substitutions(
                            heredoc_bodies[heredoc_index][0]
                        )
                        argv.extend(
                            arithmetic_expression_marker(expression)
                            for expression in arithmetic_expressions
                        )
                    heredoc_index += 1
                elif operator == "<<<" and redirects_stdin:
                    stdin_is_redirected = True
                    stdin_is_external = False
                    stdin_commands = [decode_literal_punctuation(operand)]
                elif operator in {"<", "<>"} and redirects_stdin:
                    stdin_is_redirected = True
                    stdin_is_external = True
                    stdin_commands = []
                elif (
                    (operator == "<&" and redirects_stdin)
                    or (operator == ">&" and redirection_fd == "0")
                ):
                    # Bash は `0>&3` でも FD 3 を標準入力へ複製できる
                    if operand not in {"-", "0"}:
                        stdin_is_redirected = True
                        stdin_is_external = True
                        stdin_commands = []
                    elif operand == "-":
                        stdin_is_redirected = True
                        stdin_is_external = False
                        stdin_commands = []
            continue
        argv.append(decode_literal_punctuation(tokens[index]))
        index += 1
    return (
        argv,
        stdin_commands,
        stdin_is_external,
        stdin_is_redirected,
        heredoc_index,
    )


# ============================================================================
# コマンド解決
# ============================================================================

def strip_control_prefixes(argv):
    executable_prefixes = {
        "if",
        "then",
        "elif",
        "else",
        "while",
        "until",
        "do",
        "!",
        "{",
    }
    declarations = {"for", "select", "case", "function", "in"}
    while argv and command_basename(argv[0]) in executable_prefixes:
        argv = argv[1:]
        while argv and ASSIGNMENT_RE.match(argv[0]):
            argv = argv[1:]
    if argv and command_basename(argv[0]) in declarations:
        return []
    return argv


def unwrap_command_options(arguments):
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return arguments[index + 1 :]
        if not argument.startswith("-") or argument == "-":
            break
        if "v" in argument[1:] or "V" in argument[1:]:
            return []
        index += 1
    return arguments[index:]


def unwrap_builtin_options(arguments):
    if arguments[:1] == ["--"]:
        return arguments[1:]
    # -a/-p/-s は照会用で、後続を実行しない
    if arguments and arguments[0].startswith("-"):
        return []
    return arguments


def unwrap_exec_options(arguments):
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return arguments[index + 1 :]
        if argument in {"-a", "--argv0"}:
            index += 2
        elif argument.startswith("--argv0="):
            index += 1
        elif argument.startswith("-") and argument != "-":
            # -a が末尾なら次の単語、途中なら残りが argv[0]
            short_options = argument[1:]
            argv0_index = short_options.find("a")
            index += 2 if argv0_index == len(short_options) - 1 else 1
        else:
            break
    return arguments[index:]


def split_env_string(value):
    try:
        return shlex.split(value, posix=True)
    except ValueError as error:
        raise ShellScanError("invalid env split-string: " + str(error))


def unwrap_env(arguments, split_depth=0, environment=None):
    if split_depth > 32:
        raise ShellScanError("nested env split-string depth exceeded")
    index = 0
    long_options_with_value = {"--argv0", "--chdir", "--split-string", "--unset"}
    long_options_with_optional_value = {
        "--block-signal",
        "--default-signal",
        "--ignore-signal",
    }
    long_flags = {
        "--debug",
        "--ignore-environment",
        "--list-signal-handling",
        "--null",
    }
    short_options_with_value = {"a", "C", "P", "S", "u"}
    short_flags = {"0", "i", "v"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            index += 1
            break
        if argument == "-":
            # env の単独 `-` は `-i` と同じ
            if environment is not None:
                environment.clear()
            index += 1
            continue
        if argument in long_options_with_value:
            if index + 1 >= len(arguments):
                raise ShellScanError("env option is missing its argument")
            if argument == "--split-string":
                expanded = (
                    split_env_string(arguments[index + 1]) + arguments[index + 2 :]
                )
                return unwrap_env(expanded, split_depth + 1, environment)
            if argument == "--unset" and environment is not None:
                environment.pop(arguments[index + 1], None)
            index += 2
            continue
        if argument.startswith("--split-string="):
            expanded = (
                split_env_string(argument.split("=", 1)[1]) + arguments[index + 1 :]
            )
            return unwrap_env(expanded, split_depth + 1, environment)
        if any(argument.startswith(option + "=") for option in long_options_with_value):
            if argument.startswith("--unset=") and environment is not None:
                environment.pop(argument.split("=", 1)[1], None)
            index += 1
            continue
        if argument in long_options_with_optional_value or any(
            argument.startswith(option + "=")
            for option in long_options_with_optional_value
        ):
            index += 1
            continue
        if argument in long_flags:
            if argument == "--ignore-environment" and environment is not None:
                environment.clear()
            index += 1
            continue
        if argument.startswith("--"):
            raise ShellScanError("unsupported env option")
        if (
            argument.startswith("-")
            and not argument.startswith("--")
            and argument != "-"
        ):
            short_options = argument[1:]
            option_index = 0
            while option_index < len(short_options):
                option = short_options[option_index]
                if option == "i" and environment is not None:
                    environment.clear()
                if option in short_options_with_value:
                    inline_value = short_options[option_index + 1 :]
                    if option == "S":
                        if inline_value:
                            split_value = inline_value
                            trailing = arguments[index + 1 :]
                        elif index + 1 < len(arguments):
                            split_value = arguments[index + 1]
                            trailing = arguments[index + 2 :]
                        else:
                            raise ShellScanError(
                                "env split-string is missing its argument"
                            )
                        return unwrap_env(
                            split_env_string(split_value) + trailing,
                            split_depth + 1,
                            environment,
                        )
                    if not inline_value:
                        if index + 1 >= len(arguments):
                            raise ShellScanError("env option is missing its argument")
                        index += 1
                    if option == "u" and environment is not None:
                        unset_name = inline_value or arguments[index]
                        environment.pop(unset_name, None)
                    break
                if option not in short_flags:
                    raise ShellScanError("unsupported env option")
                option_index += 1
            index += 1
            continue
        if ASSIGNMENT_RE.match(argument):
            if environment is not None and "[" not in argument.split("=", 1)[0]:
                name, value = argument.split("=", 1)
                environment[name] = value
            index += 1
            continue
        break
    while index < len(arguments) and ASSIGNMENT_RE.match(arguments[index]):
        if environment is not None and "[" not in arguments[index].split("=", 1)[0]:
            name, value = arguments[index].split("=", 1)
            environment[name] = value
        index += 1
    return arguments[index:]


def unwrap_nice(arguments):
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return arguments[index + 1 :]
        if argument in {"-n", "--adjustment"}:
            index += 2
        elif argument.startswith("--adjustment=") or re.match(r"^-\d+$", argument):
            index += 1
        elif argument.startswith("-") and argument != "-":
            index += 1
        else:
            break
    return arguments[index:]


def unwrap_time(arguments):
    index = 0
    long_options_with_value = {"--format", "--output"}
    long_flags = {"--append", "--portability", "--quiet", "--verbose"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return arguments[index + 1 :]
        if argument in long_options_with_value:
            if index + 1 >= len(arguments):
                raise ShellScanError("time option is missing its argument")
            index += 2
            continue
        if any(argument.startswith(option + "=") for option in long_options_with_value):
            index += 1
            continue
        if argument in long_flags:
            index += 1
            continue
        if argument.startswith("--"):
            raise ShellScanError("unsupported time option")
        if argument.startswith("-") and argument != "-":
            short_options = argument[1:]
            option_index = 0
            consumed_next = False
            while option_index < len(short_options):
                option = short_options[option_index]
                if option in {"f", "o"}:
                    if option_index + 1 == len(short_options):
                        if index + 1 >= len(arguments):
                            raise ShellScanError("time option is missing its argument")
                        consumed_next = True
                    break
                if option not in {"a", "h", "l", "p", "q", "v"}:
                    raise ShellScanError("unsupported time option")
                option_index += 1
            index += 2 if consumed_next else 1
            continue
        break
    return arguments[index:]


def unwrap_timeout(arguments):
    index = 0
    long_options_with_value = {"--kill-after", "--signal"}
    long_flags = {"--foreground", "--preserve-status", "--verbose"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            index += 1
            break
        if argument in long_options_with_value:
            if index + 1 >= len(arguments):
                raise ShellScanError("timeout option is missing its argument")
            index += 2
            continue
        if any(argument.startswith(option + "=") for option in long_options_with_value):
            index += 1
            continue
        if argument in long_flags:
            index += 1
            continue
        if argument.startswith("--"):
            raise ShellScanError("unsupported timeout option")
        if argument.startswith("-") and argument != "-":
            short_options = argument[1:]
            option_index = 0
            consumed_next = False
            while option_index < len(short_options):
                option = short_options[option_index]
                if option in {"k", "s"}:
                    if option_index + 1 == len(short_options):
                        if index + 1 >= len(arguments):
                            raise ShellScanError(
                                "timeout option is missing its argument"
                            )
                        consumed_next = True
                    break
                if option != "v":
                    raise ShellScanError("unsupported timeout option")
                option_index += 1
            index += 2 if consumed_next else 1
            continue
        break
    # 最初の非オプションは時間、次がコマンド
    return arguments[index + 1 :] if index < len(arguments) else []


def unwrap_xargs(arguments):
    index = 0
    replacement_mode = None
    replacement_string = None
    long_options_with_value = {
        "--arg-file",
        "--delimiter",
        "--max-args",
        "--max-chars",
        "--max-procs",
        "--process-slot-var",
    }
    long_options_with_optional_value = {"--eof", "--max-lines"}
    long_flags = {
        "--exit",
        "--interactive",
        "--no-run-if-empty",
        "--null",
        "--open-tty",
        "--show-limits",
        "--verbose",
    }
    short_options_with_value = {"a", "d", "E", "I", "J", "L", "n", "P", "R", "S", "s"}
    short_flags = {"0", "o", "p", "r", "t", "x"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            index += 1
            break
        if argument in long_options_with_value:
            if index + 1 >= len(arguments):
                raise ShellScanError("xargs option is missing its argument")
            index += 2
            continue
        if any(argument.startswith(option + "=") for option in long_options_with_value):
            index += 1
            continue
        if argument == "--replace":
            replacement_mode = "replace"
            replacement_string = "{}"
            index += 1
            continue
        if argument.startswith("--replace="):
            replacement_mode = "replace"
            replacement_string = argument.split("=", 1)[1]
            index += 1
            continue
        if argument in long_options_with_optional_value or any(
            argument.startswith(option + "=")
            for option in long_options_with_optional_value
        ):
            index += 1
            continue
        if argument in long_flags:
            index += 1
            continue
        if argument.startswith("--"):
            raise ShellScanError("unsupported xargs option")
        if argument.startswith("-") and argument != "-":
            short_options = argument[1:]
            option_index = 0
            consumed_next = False
            while option_index < len(short_options):
                option = short_options[option_index]
                if option in short_options_with_value:
                    option_value = short_options[option_index + 1 :]
                    if option_index + 1 == len(short_options):
                        if index + 1 >= len(arguments):
                            raise ShellScanError("xargs option is missing its argument")
                        option_value = arguments[index + 1]
                        consumed_next = True
                    if option in {"I", "J"}:
                        replacement_mode = "replace" if option == "I" else "insert"
                        replacement_string = option_value
                    break
                if option not in short_flags:
                    raise ShellScanError("unsupported xargs option")
                option_index += 1
            index += 2 if consumed_next else 1
            continue
        if argument == "-":
            # `-` はコマンド名として実行される引数
            break
        if argument.startswith("+"):
            raise ShellScanError("unsupported xargs option")
        else:
            break

    argv = arguments[index:]
    if replacement_mode is None:
        # 置換なしでは標準入力の単語を引数末尾へ追加する
        return (argv or ["echo"]) + [XARGS_REPLACEMENT_MARKER]
    if not replacement_string:
        raise ShellScanError("xargs replacement string is empty")
    if replacement_mode == "replace":
        return [
            argument.replace(replacement_string, XARGS_REPLACEMENT_MARKER)
            for argument in argv
        ]

    replaced = []
    replacement_pending = True
    for argument in argv:
        if replacement_pending and argument == replacement_string:
            replaced.append(XARGS_REPLACEMENT_MARKER)
            replacement_pending = False
        else:
            replaced.append(argument)
    return replaced


def shell_structure_depends_on_xargs_replacement(arguments):
    """置換値がシェルオプションまたはスクリプト引数になり得るか判定する。"""
    index = 0
    option_arguments = {"-O", "+O", "-o", "+o", "--rcfile", "--init-file"}
    while index < len(arguments):
        argument = arguments[index]
        if XARGS_REPLACEMENT_MARKER in argument:
            return True
        if argument == "--":
            return (
                index + 1 < len(arguments)
                and XARGS_REPLACEMENT_MARKER in arguments[index + 1]
            )
        if argument in option_arguments:
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if argument.startswith(("-", "+")) and len(argument) > 1:
            if "c" in argument[1:]:
                return False
            index += 1
            continue
        return False
    return False


def shell_word_is_dynamic(argument):
    return (
        UNQUOTED_EXPANSION_MARKER in argument
        or QUOTED_EXPANSION_MARKER in argument
        or "__command_substitution__" in argument
        or "__process_substitution__" in argument
        or "__arithmetic_expansion__" in argument
    )


def shell_structure_depends_on_dynamic_expansion(arguments):
    """展開値がシェルオプション・オプション引数・スクリプト引数を変え得るか判定する。"""
    index = 0
    force_stdin = False
    option_arguments = {"-O", "+O", "-o", "+o", "--rcfile", "--init-file"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return (
                not force_stdin
                and index + 1 < len(arguments)
                and shell_word_is_dynamic(arguments[index + 1])
            )
        if shell_word_is_dynamic(argument):
            return True
        if argument in option_arguments:
            if (
                index + 1 < len(arguments)
                and shell_word_is_dynamic(arguments[index + 1])
            ):
                return True
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if argument.startswith(("-", "+")) and len(argument) > 1:
            flags = argument[1:]
            if "c" in flags:
                return (
                    index + 1 < len(arguments)
                    and shell_word_is_dynamic(arguments[index + 1])
                )
            force_stdin = force_stdin or "s" in flags
            index += 1
            continue
        if force_stdin:
            return False
        return shell_word_is_dynamic(argument)
    return False


def shell_command_string(arguments):
    index = 0
    option_arguments = {"-O", "+O", "-o", "+o", "--rcfile", "--init-file"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return None
        if argument in option_arguments:
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if argument.startswith(('-', '+')) and len(argument) > 1:
            if "c" in argument[1:]:
                return arguments[index + 1] if index + 1 < len(arguments) else ""
            index += 1
            continue
        return None
    return None


def shell_reads_stdin_script(arguments):
    """-c またはスクリプト引数がなく、標準入力をスクリプトとして読む呼び出しか判定する。"""
    index = 0
    force_stdin = False
    option_arguments = {"-O", "+O", "-o", "+o", "--rcfile", "--init-file"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return (
                force_stdin
                or index + 1 >= len(arguments)
                or arguments[index + 1] in SHELL_STDIN_PATHS
            )
        if argument in option_arguments:
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if argument.startswith(("-", "+")) and len(argument) > 1:
            flags = argument[1:]
            if "c" in flags:
                return False
            force_stdin = force_stdin or "s" in flags
            index += 1
            continue
        return force_stdin or argument in SHELL_STDIN_PATHS
    return True


def shell_startup_inputs(arguments, environment):
    inputs = [
        environment[name]
        for name in ("BASH_ENV", "ENV")
        if environment.get(name)
    ]
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in {"--rcfile", "--init-file"}:
            if index + 1 >= len(arguments):
                raise ShellScanError("shell startup option is missing its argument")
            inputs.append(arguments[index + 1])
            index += 2
            continue
        if argument.startswith("--rcfile=") or argument.startswith("--init-file="):
            inputs.append(argument.split("=", 1)[1])
        index += 1
    return inputs


def pipeline_consumer_indexes(units, left_index):
    """同じパイプライン、またはパイプ直後の複合コマンドに属するコマンド単位を返す。"""
    first = left_index + 1
    if first >= len(units):
        return []

    indexes = []
    index = first
    while index < len(units):
        indexes.append(index)
        if units[index]["after"] not in PIPE_OPERATORS:
            break
        index += 1

    tokens = units[first]["tokens"]
    first_word = command_basename(tokens[0]) if tokens else ""
    enters_subshell = units[first]["group_depth"] > units[left_index]["group_depth"]
    if (
        not enters_subshell
        and first_word not in {"if", "while", "until", "for", "select", "case", "{"}
    ):
        return indexes

    terminators = {"fi", "done", "esac", "}"}
    index = indexes[-1] + 1
    while index < len(units):
        if (
            enters_subshell
            and units[index]["group_depth"] < units[first]["group_depth"]
        ):
            break
        indexes.append(index)
        raw = units[index]["tokens"]
        if not enters_subshell and raw and command_basename(raw[0]) in terminators:
            break
        index += 1
    return indexes


def compound_redirection_start(units, redirection_index):
    """複合コマンド末尾の標準入力リダイレクトが適用される最初のコマンド単位を返す。"""
    unit = units[redirection_index]
    tokens = unit["tokens"]
    first_word = command_basename(tokens[0]) if tokens else ""

    if unit["before"] == ")" and tokens and tokens[0] in REDIRECTIONS:
        required_depth = unit["group_depth"] + 1
        index = redirection_index - 1
        while index >= 0 and units[index]["group_depth"] >= required_depth:
            index -= 1
        return index + 1

    openers = {
        "}": {"{"},
        "fi": {"if"},
        "done": {"for", "select", "until", "while"},
        "esac": {"case"},
    }
    if first_word not in openers:
        return None
    index = redirection_index - 1
    while index >= 0:
        raw = units[index]["tokens"]
        if raw and command_basename(raw[0]) in openers[first_word]:
            return index
        index -= 1
    raise ShellScanError("compound command opener could not be associated")


def discover_function_definitions(units):
    functions = {}
    definition_indexes = set()
    index = 0
    while index < len(units):
        tokens = units[index]["tokens"]
        name = None
        body_start = None
        if (
            len(tokens) == 1
            and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", tokens[0])
            and units[index]["after"] == "("
        ):
            if index + 1 >= len(units) or units[index + 1]["before"] != ")":
                raise ShellScanError("unsupported function definition")
            name = tokens[0]
            body_start = index + 1
        elif (
            len(tokens) >= 2
            and command_basename(tokens[0]) == "function"
            and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", tokens[1])
        ):
            name = tokens[1]
            body_start = index + 1

        if name is None:
            index += 1
            continue
        if name in functions:
            raise ShellScanError("function redefinition is unsupported")
        if body_start >= len(units) or "{" not in units[body_start]["tokens"]:
            raise ShellScanError("unsupported function body")

        brace_depth = 0
        body_end = None
        for body_index in range(body_start, len(units)):
            brace_depth += units[body_index]["tokens"].count("{")
            brace_depth -= units[body_index]["tokens"].count("}")
            if brace_depth == 0:
                body_end = body_index
                break
        if body_end is None:
            raise ShellScanError("unterminated function body")
        for body_index in range(body_start, body_end):
            body_tokens = units[body_index]["tokens"]
            if (
                body_tokens
                and command_basename(body_tokens[0]) == "function"
            ) or (
                len(body_tokens) == 1
                and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", body_tokens[0])
                and units[body_index]["after"] == "("
            ):
                raise ShellScanError("nested function definition is unsupported")
        functions[name] = {
            "definition_index": index,
            "body_indexes": list(range(body_start, body_end)),
            "redirection_index": body_end,
        }
        definition_indexes.update(range(index, body_end + 1))
        index = body_end + 1
    return functions, definition_indexes


def static_function_call(argv, functions):
    argv = strip_control_prefixes(argv)
    while argv and ASSIGNMENT_RE.match(argv[0]):
        argv = argv[1:]
    while argv:
        if command_word_is_dynamic(argv[0]):
            return None
        command = command_basename(argv[0])
        if command == "time":
            argv = unwrap_time(argv[1:])
            while argv and ASSIGNMENT_RE.match(argv[0]):
                argv = argv[1:]
            continue
        if command == "coproc":
            arguments = strip_control_prefixes(argv[1:])
            if len(arguments) > 1:
                named_command = command_basename(arguments[1])
                if named_command in functions:
                    return named_command
            if arguments:
                direct_command = command_basename(arguments[0])
                if direct_command in functions:
                    return direct_command
            return None
        return command if command in functions else None
    return None


# ============================================================================
# 判定ルール
# ============================================================================

def rm_has_recursive_force(arguments):
    recursive = False
    force = False
    for argument in arguments:
        if argument == "--":
            break
        if argument == "--recursive":
            recursive = True
        elif argument == "--force":
            force = True
        elif (
            argument.startswith("-")
            and not argument.startswith("--")
            and argument != "-"
        ):
            options = argument[1:]
            recursive = recursive or "r" in options or "R" in options
            force = force or "f" in options
    return recursive and force


def command_word_is_dynamic(word):
    """実行コマンド名がシェル展開の結果に依存するか判定する。"""
    if any(marker in word for marker in DYNAMIC_COMMAND_MARKERS):
        return True
    if "$" in word or "`" in word:
        return True
    if word not in {"[", "[["} and any(character in word for character in "*?["):
        return True
    if word.startswith("~"):
        return True
    if "{" in word and "," in word and "}" in word:
        return True
    return False


def validate_arithmetic_expression(expression, values, seen=None, depth=0):
    """変数値の再評価を含め、コマンドを起動し得ない算術式だけを受理する。"""
    if depth > 32:
        raise ShellScanError("recursive arithmetic expression depth exceeded")
    if seen is None:
        seen = set()
    if (
        "$" in expression
        or "`" in expression
        or UNQUOTED_EXPANSION_MARKER in expression
        or "__command_substitution__" in expression
        or "__process_substitution__" in expression
        or "__arithmetic_expansion__" in expression
    ):
        raise ShellScanError("arithmetic expression contains a dynamic expansion")

    index = 0
    operators = set("+-*/%<>=!&|^~?:,()")
    while index < len(expression):
        character = expression[index]
        if character.isspace() or character in operators:
            index += 1
            continue
        if character.isdigit():
            number = re.match(
                r"(?:0[xX][0-9A-Fa-f]+|[0-9]+#[0-9A-Za-z@_]+|[0-9]+)",
                expression[index:],
            )
            index += len(number.group(0))
            continue
        if character.isalpha() or character == "_":
            end = index + 1
            while end < len(expression) and (
                expression[end].isalnum() or expression[end] == "_"
            ):
                end += 1
            name = expression[index:end]
            key = name
            if end < len(expression) and expression[end] == "[":
                subscript_start = end + 1
                cursor = subscript_start
                bracket_depth = 1
                while cursor < len(expression) and bracket_depth:
                    if expression[cursor] == "[":
                        bracket_depth += 1
                    elif expression[cursor] == "]":
                        bracket_depth -= 1
                    cursor += 1
                if bracket_depth:
                    raise ShellScanError("unterminated arithmetic array subscript")
                subscript = expression[subscript_start : cursor - 1]
                validate_arithmetic_expression(
                    subscript,
                    values,
                    seen.copy(),
                    depth + 1,
                )
                key = name + "[" + subscript + "]"
                end = cursor
            if key not in values or key in seen:
                raise ShellScanError(
                    "arithmetic expression depends on an unknown value"
                )
            validate_arithmetic_expression(
                values[key],
                values,
                seen | {key},
                depth + 1,
            )
            index = end
            continue
        raise ShellScanError("unsupported arithmetic expression syntax")


def validate_nameref_target(target, values):
    if shell_word_is_dynamic(target):
        raise ShellScanError("nameref target is dynamic")
    match = re.match(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[(.*)\])?$", target, re.S)
    if not match:
        raise ShellScanError("unsupported nameref target")
    if match.group(1) is not None:
        validate_arithmetic_expression(match.group(1), values)


# ============================================================================
# コマンド走査
# ============================================================================

class CommandScanner:
    def __init__(self):
        self.reasons = []
        self.arithmetic_values = {}
        self.integer_variables = set()
        self.shell_variables = {}
        self.exported_environment = {}

    def record_arithmetic_assignment(self, assignment):
        match = ASSIGNMENT_PARTS_RE.match(assignment)
        if not match:
            return
        name, subscript, append, value = match.groups()
        key = name
        if subscript is not None:
            validate_arithmetic_expression(subscript, self.arithmetic_values)
            key += "[" + subscript + "]"
        if append:
            if key not in self.arithmetic_values:
                value = UNQUOTED_EXPANSION_MARKER
            else:
                value = self.arithmetic_values[key] + value
        if name in self.integer_variables:
            validate_arithmetic_expression(value, self.arithmetic_values)
        self.arithmetic_values[key] = value

    def inspect_integer_declaration(self, arguments):
        integer_mode = None
        nameref_mode = None
        export_mode = None
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument == "--":
                index += 1
                break
            if argument.startswith("-") and argument != "-":
                if "i" in argument[1:]:
                    integer_mode = True
                if "n" in argument[1:]:
                    nameref_mode = True
                if "x" in argument[1:]:
                    export_mode = True
                index += 1
                continue
            if argument.startswith("+") and argument != "+":
                if "i" in argument[1:]:
                    integer_mode = False
                if "n" in argument[1:]:
                    nameref_mode = False
                if "x" in argument[1:]:
                    export_mode = False
                index += 1
                continue
            break

        for operand in arguments[index:]:
            match = ASSIGNMENT_PARTS_RE.match(operand)
            name = match.group(1) if match else operand
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                continue
            if integer_mode is True:
                self.integer_variables.add(name)
            elif integer_mode is False:
                self.integer_variables.discard(name)
            if match:
                if nameref_mode is True:
                    validate_nameref_target(match.group(4), self.arithmetic_values)
                self.record_arithmetic_assignment(operand)
                self.record_shell_assignment(operand)
            elif integer_mode is True:
                self.arithmetic_values.setdefault(name, "0")
            if export_mode is True:
                self.exported_environment[name] = self.shell_variables.get(
                    name,
                    QUOTED_EXPANSION_MARKER,
                )
            elif export_mode is False:
                self.exported_environment.pop(name, None)

    def record_shell_assignment(self, assignment):
        match = ASSIGNMENT_PARTS_RE.match(assignment)
        if not match or match.group(2) is not None:
            return
        name, _, append, value = match.groups()
        if append:
            value = self.shell_variables.get(name, QUOTED_EXPANSION_MARKER) + value
        self.shell_variables[name] = value

    def inspect_export(self, arguments):
        unexport = False
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument == "--":
                index += 1
                break
            if argument.startswith("-") and argument != "-":
                unexport = unexport or "n" in argument[1:]
                index += 1
                continue
            break
        for operand in arguments[index:]:
            match = ASSIGNMENT_PARTS_RE.match(operand)
            name = match.group(1) if match else operand
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                continue
            if match:
                self.record_arithmetic_assignment(operand)
                self.record_shell_assignment(operand)
            if unexport:
                self.exported_environment.pop(name, None)
            else:
                self.exported_environment[name] = self.shell_variables.get(
                    name,
                    QUOTED_EXPANSION_MARKER,
                )

    def split_leading_assignments(self, argv):
        index = 0
        while index < len(argv) and ASSIGNMENT_RE.match(argv[index]):
            index += 1
        return argv[:index], argv[index:]

    def validate_assignments(self, assignments, persist):
        for assignment in assignments:
            if persist:
                self.record_arithmetic_assignment(assignment)
                self.record_shell_assignment(assignment)
                continue
            match = ASSIGNMENT_PARTS_RE.match(assignment)
            if not match:
                continue
            name, subscript, _, value = match.groups()
            if subscript is not None:
                validate_arithmetic_expression(subscript, self.arithmetic_values)
            if name in self.integer_variables:
                validate_arithmetic_expression(value, self.arithmetic_values)

    def inspect_arithmetic_expansions(self, argv):
        for argument in argv:
            for match in ARITHMETIC_EXPRESSION_MARKER_RE.finditer(argument):
                try:
                    expression = bytes.fromhex(match.group(1)).decode("utf-8")
                except (ValueError, UnicodeDecodeError):
                    raise ShellScanError("invalid arithmetic expression marker")
                validate_arithmetic_expression(expression, self.arithmetic_values)

    def inspect_arithmetic_commands(self, argv):
        found = False
        for argument in argv:
            for match in ARITHMETIC_COMMAND_MARKER_RE.finditer(argument):
                found = True
                try:
                    expression = bytes.fromhex(match.group(1)).decode("utf-8")
                    validate_arithmetic_expression(expression, self.arithmetic_values)
                except (ValueError, UnicodeDecodeError):
                    raise ShellScanError("invalid arithmetic command marker")
                except ShellScanError:
                    if not self.reasons:
                        raise
        if found:
            self.arithmetic_values.clear()

    def inspect_function_call(
        self,
        name,
        functions,
        definition_indexes,
        unit_argv,
        unit_stdin_commands,
        unit_stdin_is_external,
        unit_stdin_is_redirected,
        unit_after,
        depth,
        stdin_commands,
        stdin_is_external,
        call_stack=None,
    ):
        call_stack = call_stack or []
        if name in call_stack:
            raise ShellScanError("recursive function call is unsupported")
        body_indexes = functions[name]["body_indexes"]
        redirection_index = functions[name]["redirection_index"]
        if unit_stdin_is_redirected[redirection_index]:
            for body_index in body_indexes:
                body_argv = unit_argv[body_index]
                self.inspect_arithmetic_commands(body_argv)
                self.inspect_argv(
                    body_argv,
                    depth + 1,
                    unit_stdin_commands[redirection_index],
                    unit_stdin_is_external[redirection_index],
                )
        for body_index in body_indexes:
            body_argv = unit_argv[body_index]
            self.inspect_arithmetic_commands(body_argv)
            self.inspect_argv(
                body_argv,
                depth + 1,
                unit_stdin_commands[body_index]
                if unit_stdin_is_redirected[body_index]
                else stdin_commands,
                unit_stdin_is_external[body_index]
                or (stdin_is_external and not unit_stdin_is_redirected[body_index]),
            )
            nested_name = static_function_call(body_argv, functions)
            if nested_name:
                self.inspect_function_call(
                    nested_name,
                    functions,
                    definition_indexes,
                    unit_argv,
                    unit_stdin_commands,
                    unit_stdin_is_external,
                    unit_stdin_is_redirected,
                    unit_after,
                    depth + 1,
                    unit_stdin_commands[body_index]
                    if unit_stdin_is_redirected[body_index]
                    else stdin_commands,
                    unit_stdin_is_external[body_index]
                    or (
                        stdin_is_external
                        and not unit_stdin_is_redirected[body_index]
                    ),
                    call_stack + [name],
                )

        for position, body_index in enumerate(body_indexes[:-1]):
            if unit_after[body_index] not in PIPE_OPERATORS:
                continue
            right_index = body_indexes[position + 1]
            if unit_stdin_is_redirected[right_index]:
                continue
            self.inspect_argv(
                unit_argv[right_index],
                depth + 1,
                stdin_is_external=True,
            )
            nested_name = static_function_call(unit_argv[right_index], functions)
            if nested_name:
                self.inspect_function_call(
                    nested_name,
                    functions,
                    definition_indexes,
                    unit_argv,
                    unit_stdin_commands,
                    unit_stdin_is_external,
                    unit_stdin_is_redirected,
                    unit_after,
                    depth + 1,
                    [],
                    True,
                    call_stack + [name],
                )

    def scan(
        self,
        command,
        depth=0,
        inherited_stdin_is_external=False,
        reject_function_definitions=False,
    ):
        if depth > 32:
            raise ShellScanError("nested shell command depth exceeded")

        without_heredocs, heredoc_bodies = strip_heredoc_bodies(command)
        without_heredocs = strip_shell_comments(
            remove_shell_line_continuations(without_heredocs)
        )
        sanitized, nested_commands = collect_substitutions(without_heredocs)
        for body, quoted in heredoc_bodies:
            if not quoted:
                heredoc_nested, _ = collect_heredoc_substitutions(body)
                nested_commands.extend(heredoc_nested)
        for nested in nested_commands:
            self.scan(nested, depth + 1, inherited_stdin_is_external)

        units = split_command_units(shell_tokens(sanitized))
        functions, definition_indexes = discover_function_definitions(units)
        if reject_function_definitions and functions:
            raise ShellScanError("function definition escapes the inspected input")
        unit_after = [unit["after"] for unit in units]
        resolved = []
        unit_argv = []
        unit_stdin_commands = []
        unit_stdin_is_external = []
        unit_stdin_is_redirected = []
        heredoc_index = 0
        raw_unit_argv = []
        for unit in units:
            (
                argv,
                stdin_commands,
                stdin_is_external,
                stdin_is_redirected,
                heredoc_index,
            ) = remove_redirections(unit["tokens"], heredoc_bodies, heredoc_index)
            raw_unit_argv.append(argv)
            unit_stdin_commands.append(stdin_commands)
            unit_stdin_is_external.append(stdin_is_external)
            unit_stdin_is_redirected.append(stdin_is_redirected)

        unit_argv = [strip_control_prefixes(argv) for argv in raw_unit_argv]
        for index, unit in enumerate(units):
            argv = raw_unit_argv[index]
            self.inspect_arithmetic_commands(argv)
            argv = unit_argv[index]
            if index in definition_indexes:
                resolved.append(None)
                continue
            state_is_uncertain = (
                unit["group_depth"]
                or unit["before"] in {"&&", "||", "|", "|&"}
                or unit["after"] in {"&&", "||", "|", "|&"}
                or any(
                    command_basename(token)
                    in {"if", "then", "elif", "else", "while", "until", "do"}
                    for token in unit["tokens"]
                )
            )
            if state_is_uncertain:
                self.arithmetic_values.clear()
            integer_variables_before = self.integer_variables.copy()
            shell_variables_before = self.shell_variables.copy()
            exported_environment_before = self.exported_environment.copy()
            resolved.append(
                self.inspect_argv(
                    argv,
                    depth,
                    unit_stdin_commands[index],
                    unit_stdin_is_external[index]
                    or (
                        inherited_stdin_is_external
                        and not unit_stdin_is_redirected[index]
                    ),
                    persist_assignments=not state_is_uncertain,
                )
            )
            function_name = static_function_call(argv, functions)
            if function_name:
                function_values_before = self.arithmetic_values.copy()
                function_integers_before = self.integer_variables.copy()
                function_shell_before = self.shell_variables.copy()
                function_environment_before = self.exported_environment.copy()
                self.inspect_function_call(
                    function_name,
                    functions,
                    definition_indexes,
                    unit_argv,
                    unit_stdin_commands,
                    unit_stdin_is_external,
                    unit_stdin_is_redirected,
                    unit_after,
                    depth,
                    unit_stdin_commands[index],
                    unit_stdin_is_external[index]
                    or (
                        inherited_stdin_is_external
                        and not unit_stdin_is_redirected[index]
                    ),
                )
                if (
                    self.arithmetic_values != function_values_before
                    or self.integer_variables != function_integers_before
                    or self.shell_variables != function_shell_before
                    or self.exported_environment != function_environment_before
                ):
                    raise ShellScanError(
                        "function variable scope cannot be merged safely"
                    )
            if state_is_uncertain:
                self.arithmetic_values.clear()
                if (
                    unit["group_depth"]
                    or unit["before"] in PIPE_OPERATORS
                    or unit["after"] in PIPE_OPERATORS
                ):
                    self.integer_variables = integer_variables_before
                    self.shell_variables = shell_variables_before
                    self.exported_environment = exported_environment_before
                elif (
                    self.integer_variables != integer_variables_before
                    or self.shell_variables != shell_variables_before
                    or self.exported_environment != exported_environment_before
                ):
                    raise ShellScanError(
                        "variable state depends on conditional execution"
                    )

        if heredoc_index != len(heredoc_bodies):
            raise ShellScanError("heredoc body could not be associated")

        # `(bash) <<EOF` / `{ bash; } <<EOF` のリダイレクトは内部コマンドへ継承される
        for index in range(len(units)):
            if not unit_stdin_is_redirected[index]:
                continue
            start = compound_redirection_start(units, index)
            if start is None:
                continue
            for inner_index in range(start, index):
                if (
                    inner_index in definition_indexes
                    or unit_stdin_is_redirected[inner_index]
                ):
                    continue
                self.inspect_argv(
                    unit_argv[inner_index],
                    depth,
                    unit_stdin_commands[index],
                    unit_stdin_is_external[index],
                )
                function_name = static_function_call(unit_argv[inner_index], functions)
                if function_name:
                    self.inspect_function_call(
                        function_name,
                        functions,
                        definition_indexes,
                        unit_argv,
                        unit_stdin_commands,
                        unit_stdin_is_external,
                        unit_stdin_is_redirected,
                        unit_after,
                        depth,
                        unit_stdin_commands[index],
                        unit_stdin_is_external[index],
                    )

        for index, unit in enumerate(units):
            if index in definition_indexes:
                continue
            if unit["after"] not in PIPE_OPERATORS:
                continue
            left = resolved[index]
            for right_index in pipeline_consumer_indexes(units, index):
                if (
                    right_index in definition_indexes
                    or unit_stdin_is_redirected[right_index]
                ):
                    continue

                had_stdin_reason = SHELL_STDIN_REASON in self.reasons
                self.inspect_argv(
                    unit_argv[right_index],
                    depth,
                    stdin_is_external=True,
                )
                function_name = static_function_call(unit_argv[right_index], functions)
                if function_name:
                    self.inspect_function_call(
                        function_name,
                        functions,
                        definition_indexes,
                        unit_argv,
                        unit_stdin_commands,
                        unit_stdin_is_external,
                        unit_stdin_is_redirected,
                        unit_after,
                        depth,
                        [],
                        True,
                    )
                nested_indexes = {
                    int(match.group(1))
                    for argument in unit_argv[right_index]
                    for match in NESTED_COMMAND_MARKER_RE.finditer(argument)
                }
                for nested_index in sorted(nested_indexes):
                    if nested_index >= len(nested_commands):
                        raise ShellScanError("nested command marker is invalid")
                    self.scan(
                        nested_commands[nested_index],
                        depth + 1,
                        inherited_stdin_is_external=True,
                    )
                gained_stdin_reason = (
                    not had_stdin_reason and SHELL_STDIN_REASON in self.reasons
                )
                if not gained_stdin_reason:
                    continue

                # `cat <<EOF | bash` は静的本文を直接検査できる
                if (
                    right_index == index + 1
                    and left
                    and left[0] == "cat"
                    and unit_stdin_commands[index]
                    and not unit_stdin_is_external[index]
                    and all(
                        argument == "-" or argument.startswith("-")
                        for argument in left[1]
                    )
                ):
                    self.reasons.remove(SHELL_STDIN_REASON)
                    for stdin_command in unit_stdin_commands[index]:
                        self.scan(stdin_command, depth + 1)
                else:
                    if left and left[0] in {"curl", "wget"}:
                        add_reason(self.reasons, PIPE_SHELL_REASON)
                break

    def inspect_argv(
        self,
        argv,
        depth,
        stdin_commands=None,
        stdin_is_external=False,
        persist_assignments=True,
    ):
        stdin_commands = stdin_commands or []
        effective_environment = self.exported_environment.copy()
        original_argv = argv
        leading_assignments, argv = self.split_leading_assignments(argv)
        try:
            self.inspect_arithmetic_expansions(original_argv)
        except ShellScanError:
            if not self.reasons:
                raise
        if not argv:
            self.validate_assignments(
                leading_assignments,
                persist=persist_assignments,
            )
            return None
        self.validate_assignments(leading_assignments, persist=False)
        for assignment in leading_assignments:
            name, value = assignment.split("=", 1)
            if "[" not in name:
                effective_environment[name] = value

        if ARITHMETIC_COMMAND_MARKER_RE.fullmatch(argv[0]):
            return None

        while argv:
            if command_word_is_dynamic(argv[0]):
                raise ShellScanError("dynamic command name")
            command = command_basename(argv[0])
            arguments = argv[1:]

            if command == "command":
                argv = unwrap_command_options(arguments)
            elif command == "builtin":
                argv = unwrap_builtin_options(arguments)
            elif command == "exec":
                argv = unwrap_exec_options(arguments)
            elif command == "env":
                env_assignments = effective_environment.copy()
                argv = unwrap_env(arguments, environment=env_assignments)
                effective_environment = env_assignments
            elif command == "nohup":
                argv = (
                    arguments[1:]
                    if arguments and arguments[0] == "--"
                    else arguments
                )
            elif command == "nice":
                argv = unwrap_nice(arguments)
            elif command == "time":
                argv = unwrap_time(arguments)
            elif command == "timeout":
                argv = unwrap_timeout(arguments)
            elif command == "xargs":
                argv = unwrap_xargs(arguments)
            else:
                break

            original_argv = argv
            wrapper_assignments, argv = self.split_leading_assignments(argv)
            try:
                self.inspect_arithmetic_expansions(original_argv)
            except ShellScanError:
                if not self.reasons:
                    raise
            if not argv:
                return None
            self.validate_assignments(wrapper_assignments, persist=False)
            for assignment in wrapper_assignments:
                name, value = assignment.split("=", 1)
                if "[" not in name:
                    effective_environment[name] = value

        command = command_basename(argv[0])
        arguments = argv[1:]
        if command == "sudo":
            add_reason(self.reasons, SUDO_REASON)
        elif command == "rm":
            for argument in arguments:
                if argument == "--":
                    break
                if command_word_is_dynamic(argument):
                    raise ShellScanError("dynamic rm option")
            if rm_has_recursive_force(arguments):
                add_reason(self.reasons, RM_REASON)
        elif command == "eval":
            if arguments and arguments[0] == "--":
                arguments = arguments[1:]
            if arguments:
                if any(XARGS_REPLACEMENT_MARKER in argument for argument in arguments):
                    raise ShellScanError("xargs replacement in eval string")
                self.scan(
                    " ".join(arguments),
                    depth + 1,
                    stdin_is_external,
                    reject_function_definitions=True,
                )
        elif command == "let":
            for expression in arguments:
                try:
                    validate_arithmetic_expression(
                        expression,
                        self.arithmetic_values,
                    )
                except ShellScanError:
                    if not self.reasons:
                        raise
            self.arithmetic_values.clear()
        elif command == "export":
            if any(command_word_is_dynamic(argument) for argument in arguments):
                raise ShellScanError("dynamic export operand")
            self.inspect_export(arguments)
        elif command == "readonly":
            if any(command_word_is_dynamic(argument) for argument in arguments):
                raise ShellScanError("dynamic readonly operand")
            for argument in arguments:
                if ASSIGNMENT_RE.match(argument):
                    self.record_arithmetic_assignment(argument)
                    self.record_shell_assignment(argument)
        elif command == "unset":
            unset_arguments = [
                argument
                for argument in arguments
                if argument == "--" or not argument.startswith("-")
            ]
            if any(command_word_is_dynamic(argument) for argument in unset_arguments):
                raise ShellScanError("dynamic unset operand")
            for name in unset_arguments:
                if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                    continue
                self.arithmetic_values.pop(name, None)
                self.integer_variables.discard(name)
                self.shell_variables.pop(name, None)
                self.exported_environment.pop(name, None)
        elif command in {"declare", "typeset", "local"}:
            self.inspect_integer_declaration(arguments)
        elif command == "[[":
            arithmetic_comparisons = {"-eq", "-ne", "-lt", "-le", "-gt", "-ge"}
            for index, argument in enumerate(arguments):
                if argument not in arithmetic_comparisons:
                    continue
                if index == 0 or index + 1 >= len(arguments):
                    raise ShellScanError("incomplete arithmetic comparison")
                validate_arithmetic_expression(
                    arguments[index - 1],
                    self.arithmetic_values,
                )
                validate_arithmetic_expression(
                    arguments[index + 1],
                    self.arithmetic_values,
                )
        elif command in SHELL_COMMANDS:
            if shell_structure_depends_on_xargs_replacement(arguments):
                raise ShellScanError(
                    "xargs replacement controls shell option or script operand"
                )
            if shell_structure_depends_on_dynamic_expansion(arguments):
                raise ShellScanError(
                    "dynamic expansion controls shell option or script operand"
                )
            for startup_input in shell_startup_inputs(
                arguments,
                effective_environment,
            ):
                if shell_word_is_dynamic(startup_input):
                    raise ShellScanError("dynamic shell startup input")
                if startup_input in SHELL_STDIN_PATHS:
                    if stdin_is_external:
                        add_reason(self.reasons, SHELL_STDIN_REASON)
                    for stdin_command in stdin_commands:
                        self.scan(
                            stdin_command,
                            depth + 1,
                            reject_function_definitions=True,
                        )
                elif (
                    NON_STDIN_FD_PATH_RE.match(startup_input)
                    or "__process_substitution__" in startup_input
                ):
                    add_reason(self.reasons, SHELL_STDIN_REASON)
                else:
                    raise ShellScanError("shell startup input cannot be inspected")
            nested = shell_command_string(arguments)
            if nested is not None:
                if XARGS_REPLACEMENT_MARKER in nested:
                    raise ShellScanError("xargs replacement in shell command string")
                self.scan(nested, depth + 1, stdin_is_external)
            elif any(NON_STDIN_FD_PATH_RE.match(argument) for argument in arguments):
                add_reason(self.reasons, SHELL_STDIN_REASON)
            elif any("__process_substitution__" in argument for argument in arguments):
                add_reason(self.reasons, SHELL_STDIN_REASON)
            elif shell_reads_stdin_script(arguments):
                if stdin_is_external:
                    add_reason(self.reasons, SHELL_STDIN_REASON)
                for stdin_command in stdin_commands:
                    self.scan(
                        stdin_command,
                        depth + 1,
                        reject_function_definitions=True,
                    )
        elif command in {".", "source"}:
            source_arguments = arguments[1:] if arguments[:1] == ["--"] else arguments
            if source_arguments and source_arguments[0] in SHELL_FD0_PATHS:
                if stdin_is_external:
                    add_reason(self.reasons, SHELL_STDIN_REASON)
                for stdin_command in stdin_commands:
                    self.scan(
                        stdin_command,
                        depth + 1,
                        reject_function_definitions=True,
                    )
            elif source_arguments and (
                NON_STDIN_FD_PATH_RE.match(source_arguments[0])
                or "__process_substitution__" in source_arguments[0]
            ):
                add_reason(self.reasons, SHELL_STDIN_REASON)
        elif command == "trap":
            trap_arguments = arguments[1:] if arguments[:1] == ["--"] else arguments
            if len(trap_arguments) >= 2 and trap_arguments[0] not in {"-", ""}:
                if XARGS_REPLACEMENT_MARKER in trap_arguments[0]:
                    raise ShellScanError("xargs replacement in trap string")
                self.scan(trap_arguments[0], depth + 1, stdin_is_external)
        elif command == "find":
            if any(XARGS_REPLACEMENT_MARKER in argument for argument in arguments):
                raise ShellScanError("runtime arguments control find expression")
            index = 0
            while index < len(arguments):
                if arguments[index] not in {"-exec", "-execdir", "-ok", "-okdir"}:
                    index += 1
                    continue
                command_start = index + 1
                command_end = command_start
                while (
                    command_end < len(arguments)
                    and arguments[command_end] not in {";", "+"}
                ):
                    command_end += 1
                if command_end >= len(arguments):
                    raise ShellScanError("unterminated find executor")
                executor = [
                    argument.replace("{}", XARGS_REPLACEMENT_MARKER)
                    for argument in arguments[command_start:command_end]
                ]
                self.inspect_argv(executor, depth + 1)
                index = command_end + 1
        elif command == "coproc" and arguments:
            self.inspect_argv(strip_control_prefixes(arguments), depth + 1)
            if len(arguments) > 1 and re.match(
                r"^[A-Za-z_][A-Za-z0-9_]*$", arguments[0]
            ):
                self.inspect_argv(
                    strip_control_prefixes(arguments[1:]),
                    depth + 1,
                )
        return command, arguments


# ============================================================================
# 出力
# ============================================================================

def print_block_json(command, reasons):
    details = "\n".join("- " + reason for reason in reasons)
    message = (
        "危険な可能性がある Bash コマンドをブロックしました。\n\n"
        "Command:\n  "
        + command
        + "\n\nReasons:\n"
        + details
    )
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": message,
            }
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")


def fail_closed(message):
    print("pre-bash-guard.sh: " + message, file=sys.stderr)
    return 2


# ============================================================================
# エントリポイント
# ============================================================================

def main():
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return fail_closed("invalid hook input JSON")

    if not isinstance(event, dict) or not isinstance(event.get("tool_name"), str):
        return fail_closed("invalid hook input JSON")
    if event["tool_name"] != "Bash":
        return 0

    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict) or not isinstance(
        tool_input.get("command"), str
    ):
        return fail_closed("Bash hook input does not contain a string command")
    command = tool_input["command"].strip()
    if not command:
        return 0

    scanner = CommandScanner()
    try:
        scanner.scan(command)
    except (ShellScanError, ValueError, IndexError) as error:
        print("pre-bash-guard.sh: " + PARSE_REASON + " " + str(error), file=sys.stderr)
        return 2

    if scanner.reasons:
        print_block_json(command, scanner.reasons)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYTHON

  [[ -n "$scanner_source" ]] || {
    printf 'pre-bash-guard.sh: failed to load scanner\n' >&2
    exit 2
  }

  python3 -c "$scanner_source" "$@" || {
    scanner_status=$?
    if ((scanner_status != 2)); then
      printf 'pre-bash-guard.sh: scanner failed with status %s\n' \
        "$scanner_status" >&2
    fi
    exit 2
  }
}

main "$@"
