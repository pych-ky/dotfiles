#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_dir/.claude/hooks/pre-bash-guard.sh"
test_root="$(mktemp -d)"
deployed_hooks="$test_root/deployed-hooks"

cleanup() {
  rm -r -- "$test_root"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

safe_input='{"tool_name":"Bash","tool_input":{"command":"printf safe"}}'
dangerous_input='{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'

mkdir "$deployed_hooks"
ln -s "$guard" "$deployed_hooks/pre-bash-guard.sh"
ln -s "$repo_dir/.claude/hooks/pre-bash-guard.py" \
  "$deployed_hooks/pre-bash-guard.py"

output="$(printf '%s\n' "$safe_input" | bash "$guard")"
[[ -z "$output" ]] || fail 'safe command must be allowed silently'

output="$(
  printf '%s\n' "$dangerous_input" |
    bash "$deployed_hooks/pre-bash-guard.sh"
)"
decision="$(
  python3 -c 'import json, sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' \
    <<<"$output"
)"
[[ "$decision" == deny ]] ||
  fail 'dangerous command must be denied'

set +e
printf '{\n' | bash "$guard" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail 'invalid input must fail closed'

python3 - "$repo_dir/.claude/settings.json" <<'PY' || fail 'Claude settings must invoke the guard wrapper'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    matchers = json.load(file)["hooks"]["PreToolUse"]
assert any(
    hook.get("type") == "command"
    and hook.get("command") == "$HOME/.claude/hooks/pre-bash-guard.sh"
    for matcher in matchers
    if matcher.get("matcher") == "Bash"
    for hook in matcher.get("hooks", [])
)
PY

mkdir "$test_root/home"
link_output="$(
  HOME="$test_root/home" bash "$repo_dir/scripts/link-dotfiles.sh" --dry-run
)"
for hook in pre-bash-guard.py pre-bash-guard.sh; do
  [[ "$link_output" == *"$test_root/home/.claude/hooks/$hook -> $repo_dir/.claude/hooks/$hook"* ]] ||
    fail "$hook must be included in link deployment"
done

source "$repo_dir/lib/process-lock.sh"
lock_path="$test_root/process.lock"
process_lock_acquire "$lock_path" '' test 1 ||
  fail 'lock must be acquired normally'
contender_error="$test_root/contender-error"
if bash -c '
source "$1"
process_lock_acquire "$2" "" contender 1
' _ "$repo_dir/lib/process-lock.sh" "$lock_path" 2>"$contender_error"; then
  fail 'concurrent lock acquisition must time out'
fi
[[ "$(cat "$contender_error")" == *'timed out waiting for contender lock'* ]] ||
  fail 'concurrent lock must fail because it is already held'
process_lock_release
process_lock_acquire "$lock_path" '' test 1 ||
  fail 'released lock must be acquired again'
process_lock_release

printf 'unchanged\n' >"$test_root/target"
ln -s "$test_root/target" "$test_root/unsafe-lock"
if process_lock_acquire "$test_root/unsafe-lock" '' test 1 2>/dev/null; then
  fail 'symlink lock path must be rejected'
fi
[[ "$(cat "$test_root/target")" == unchanged ]] ||
  fail 'rejected lock path must not modify its target'

printf 'All dotfiles tests passed.\n'
