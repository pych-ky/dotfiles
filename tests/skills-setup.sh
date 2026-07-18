#!/bin/sh

set -u

REPOSITORY_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
SETUP_SCRIPT=$REPOSITORY_ROOT/skills/setup.sh
REAL_PYTHON3=$(command -v python3 2>/dev/null || true)
REAL_GIT=$(command -v git 2>/dev/null || true)

if [ -z "$REAL_PYTHON3" ] || [ -z "$REAL_GIT" ]; then
  echo "git and python3 are required to run skills/setup.sh tests." >&2
  exit 1
fi

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/skills-setup-tests.XXXXXX") || exit 1
trap 'rm -rf "$TEST_ROOT"' 0
trap 'exit 1' HUP INT TERM

TESTS_PASSED=0
TESTS_FAILED=0
RUN_STATUS_INVALID=runner-status-unavailable
TEST_FILTER=${SKILLS_SETUP_TEST_FILTER-}
TEST_FILTER_MATCHED=0

new_case() {
  CASE_ROOT=$TEST_ROOT/$1
  CASE_HOME=$CASE_ROOT/home
  CASE_STATE_HOME=$CASE_ROOT/state
  CASE_TMP=$CASE_ROOT/tmp
  CASE_BIN=$CASE_ROOT/bin
  CASE_WORK=$CASE_ROOT/work
  CASE_REPOSITORY=$CASE_WORK/agent-skills
  CASE_OUTPUT=$CASE_ROOT/output
  CASE_STATUS=$CASE_ROOT/status
  FAKE_GIT_LOG=$CASE_ROOT/git.log
  FAKE_GIT_ENV_LOG=$CASE_ROOT/git-environment.log
  FAKE_CLI_LOG=$CASE_ROOT/cli.log
  FAKE_GIT_COUNTER=$CASE_ROOT/ls-remote.count
  FAKE_GIT_CHILD_PID_FILE=$CASE_ROOT/git-child.pid
  FAKE_GIT_CLONE_MARKER=$CASE_ROOT/clone.started
  FAKE_GIT_CLONE_GATE=$CASE_ROOT/clone.continue
  FAKE_GIT_HEAD_FILE=$CASE_ROOT/git.head
  FAKE_GIT_FETCH_MARKER=$CASE_ROOT/fetch.started
  FAKE_GIT_TTY_STATE_FILE=$CASE_ROOT/git-tty.state
  FAKE_CLI_CHILD_PID_FILE=$CASE_ROOT/cli-child.pid
  FAKE_CLI_MARKER=$CASE_ROOT/cli.started
  FAKE_CLI_GATE=$CASE_ROOT/cli.continue
  FAKE_CLI_AFTER_GATE=$CASE_ROOT/cli.after-gate
  FAKE_PUBLISH_MARKER=$CASE_ROOT/publish.started
  FAKE_PUBLISH_GATE=$CASE_ROOT/publish.continue
  FAKE_PARENT_MARKER=$CASE_ROOT/parent.created
  FAKE_PARENT_GATE=$CASE_ROOT/parent.continue
  FAKE_CLEANUP_MARKER=$CASE_ROOT/cleanup.started
  FAKE_CLEANUP_GATE=$CASE_ROOT/cleanup.continue
  FAKE_CLEANUP_ERROR_MARKER=$CASE_ROOT/cleanup.error
  FAKE_FETCH_MARKER=$CASE_ROOT/fetch.completed
  FAKE_FETCH_GATE=$CASE_ROOT/fetch.continue
  FAKE_OPERATION_RUNNER_MARKER=$CASE_ROOT/operation-runner.stopped
  PRE_REAP_MARKER=$CASE_ROOT/pre-reap.ok
  FAKE_CLI_TEMPLATE=$CASE_ROOT/agent-skills

  mkdir -p "$CASE_HOME" "$CASE_STATE_HOME" "$CASE_TMP" "$CASE_BIN" "$CASE_WORK"
  printf '%s\n' '1111111111111111111111111111111111111111' >"$FAKE_GIT_HEAD_FILE"
  : >"$FAKE_GIT_LOG"
  : >"$FAKE_GIT_ENV_LOG"
  : >"$FAKE_CLI_LOG"
  cat >"$CASE_BIN/python3" <<'EOF'
#!/bin/sh

exec "$TEST_REAL_PYTHON3" "$@"
EOF

  RUN_TMPDIR=$CASE_TMP
  RUN_SETUP_SHELL=/bin/sh
  RUN_SETUP_CWD=$REPOSITORY_ROOT
  RUN_REPOSITORY_URL=
  RUN_REMOTE_URL=https://github.com/pych-ky/agent-skills.git
  RUN_REMOTE_URL_COUNT=1
  RUN_REMOTE_URL_2=
  RUN_DIRECT_EFFECTIVE_URL=https://github.com/pych-ky/agent-skills.git
  RUN_ORIGIN_EFFECTIVE_URL=__raw_origin__
  RUN_CLONE_DEFAULT_REMOTE_NAME=origin
  RUN_STRICT=
  RUN_SKIP=
  RUN_GIT_TIMEOUT=5
  RUN_LS_REMOTE_1_STATUS=0
  RUN_LS_REMOTE_2_STATUS=0
  RUN_CLONE_STATUS=0
  RUN_REV_PARSE_STATUS=0
  RUN_SYMBOLIC_REF_STATUS=0
  RUN_CONFIG_STATUS=0
  RUN_UPLOADPACK_CONFIGURED=0
  RUN_VCS_CONFIGURED=0
  RUN_PARTIAL_CLONE_CONFIGURED=0
  RUN_INDEX_TAG=H
  RUN_FILTER_DRIVER=
  RUN_FILTER_CONFIGURED=0
  RUN_FILTER_PROBE_STATUS=1
  RUN_CURRENT_BRANCH=main
  RUN_UPSTREAM_REMOTE=origin
  RUN_UPSTREAM_REF=refs/heads/main
  RUN_GIT_STATUS_STATUS=0
  RUN_GIT_STATUS_OUTPUT=
  RUN_FETCH_STATUS=0
  RUN_BLOCK_LS_REMOTE=0
  RUN_BLOCK_CLONE=0
  RUN_BLOCK_FETCH=0
  RUN_BLOCK_CHECK_ATTR=0
  RUN_FETCH_MUTATION=
  RUN_FAST_FORWARD_MUTATION=
  RUN_MERGE_BASE_STATUS=0
  RUN_STOP_BEFORE_LOCK_HELPER=0
  RUN_PUBLISH_MARKER=
  RUN_PUBLISH_GATE=
  RUN_PARENT_MARKER=
  RUN_PARENT_GATE=
  RUN_LOCK_WAIT_MARKER=
  RUN_CLEANUP_MARKER=
  RUN_CLEANUP_GATE=
  RUN_CLEANUP_ERROR_MARKER=
  RUN_FETCH_MARKER=
  RUN_FETCH_GATE=
  RUN_OPERATION_RUNNER_MARKER=
  RUN_OPERATION_RUNNER_COMMAND=
  RUN_BLOCK_CLI_COMMAND=
  RUN_CHECK_ONLY=0
  RUN_CLI_VALIDATE_STATUS=0
  RUN_CLI_SYNC_STATUS=0
  RUN_STATUS=$RUN_STATUS_INVALID

  cat >"$CASE_BIN/git" <<'EOF'
#!/bin/sh

printf '%s\n' "$*" >>"$FAKE_GIT_LOG"
printf 'optional-locks=%s graft-file=%s lazy-fetch=%s %s\n' \
    "${GIT_OPTIONAL_LOCKS-}" "${GIT_GRAFT_FILE-}" \
    "${GIT_NO_LAZY_FETCH-}" "$*" >>"$FAKE_GIT_ENV_LOG"

if [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; then
    printf '%s\n' tty >"$FAKE_GIT_TTY_STATE_FILE"
else
    printf '%s\n' no-tty >"$FAKE_GIT_TTY_STATE_FILE"
fi

repository_root=
if [ "${1-}" = "--no-replace-objects" ]; then
    shift
fi
while [ "${1-}" = "-c" ]; do
    shift 2
done
if [ "${1-}" = "-C" ]; then
    repository_root=$2
    shift 2
fi

subcommand=${1-}
if [ "$#" -gt 0 ]; then
    shift
fi

case "$subcommand" in
    rev-parse)
        if [ "$FAKE_GIT_REV_PARSE_STATUS" -ne 0 ]; then
            exit "$FAKE_GIT_REV_PARSE_STATUS"
        fi
        case "${1-}" in
            --show-toplevel)
                printf '%s\n' "$repository_root"
                ;;
            --git-dir | --git-common-dir)
                printf '%s\n' "$repository_root/.git"
                ;;
            --verify)
                case "${2-}" in
                    refs/agent-skills/setup/*)
                        temporary_ref=${2%%\^*}
                        cat "$repository_root/.git/$temporary_ref"
                        ;;
                    FETCH_HEAD*)
                        if [ -s "$repository_root/.git/FETCH_HEAD" ]; then
                            sed -n '1{s/[[:space:]].*//;p;}' "$repository_root/.git/FETCH_HEAD"
                        else
                            cat "$FAKE_GIT_HEAD_FILE"
                        fi
                        ;;
                    1111111111111111111111111111111111111111*)
                        printf '%s\n' 1111111111111111111111111111111111111111
                        ;;
                    2222222222222222222222222222222222222222*)
                        printf '%s\n' 2222222222222222222222222222222222222222
                        ;;
                    *) cat "$FAKE_GIT_HEAD_FILE" ;;
                esac
                ;;
            *)
                exit 1
                ;;
        esac
        exit 0
        ;;
    symbolic-ref)
        current_branch=$FAKE_GIT_CURRENT_BRANCH
        if [ -s "$repository_root/.git/fake-current-branch" ]; then
            IFS= read -r current_branch <"$repository_root/.git/fake-current-branch"
        fi
        if [ "$FAKE_GIT_SYMBOLIC_REF_STATUS" -eq 0 ]; then
            case " $* " in
                *' --short '*) printf '%s\n' "$current_branch" ;;
                *) printf 'refs/heads/%s\n' "$current_branch" ;;
            esac
        fi
        exit "$FAKE_GIT_SYMBOLIC_REF_STATUS"
        ;;
    check-ref-format)
        case "${1-}" in
            *:*) exit 1 ;;
            *) exit 0 ;;
        esac
        ;;
    config)
        if [ "$FAKE_GIT_CONFIG_STATUS" -ne 0 ]; then
            exit "$FAKE_GIT_CONFIG_STATUS"
        fi
        if [ "${1-}" = "--null" ] && [ "${2-}" = "--get-all" ] &&
            [ "${3-}" = "remote.origin.url" ]; then
            if [ -f "$repository_root/.git/remote-name" ] &&
                [ "$(cat "$repository_root/.git/remote-name")" != "origin" ]; then
                exit 1
            fi
            if [ "$FAKE_GIT_REMOTE_URL_COUNT" -eq 0 ]; then
                exit 1
            fi
            printf '%s\0' "$FAKE_GIT_REMOTE_URL"
            if [ "$FAKE_GIT_REMOTE_URL_COUNT" -gt 1 ]; then
                printf '%s\0' "$FAKE_GIT_REMOTE_URL_2"
            fi
            exit 0
        fi
        if [ "${1-}" = "--null" ] && [ "${2-}" = "--get-all" ] &&
            [ "${3-}" = "remote.origin.uploadpack" ]; then
            if [ "$FAKE_GIT_UPLOADPACK_CONFIGURED" -eq 1 ]; then
                printf '%s\0' malicious-upload-pack
                exit 0
            fi
            exit 1
        fi
        if [ "${1-}" = "--null" ] && [ "${2-}" = "--get-all" ] &&
            [ "${3-}" = "remote.origin.vcs" ]; then
            if [ "$FAKE_GIT_VCS_CONFIGURED" -eq 1 ]; then
                printf '%s\0' malicious-transport
                exit 0
            fi
            exit 1
        fi
        if [ "${1-}" = "--includes" ] && [ "${2-}" = "--null" ] &&
            [ "${3-}" = "--name-only" ] && [ "${4-}" = "--list" ]; then
            if [ "$FAKE_GIT_PARTIAL_CLONE_CONFIGURED" -eq 1 ]; then
                printf 'remote.evil.promisor\0'
            fi
            exit 0
        fi
        if [ "${1-}" = "--includes" ] && [ "${2-}" = "--null" ] &&
            [ "${3-}" = "--show-scope" ] && [ "${4-}" = "--show-origin" ] &&
            [ "${5-}" = "--list" ]; then
            printf 'local\0file:%s/.git/config\0remote.origin.url\n%s\0' \
                "$repository_root" "$FAKE_GIT_REMOTE_URL"
            if [ "$FAKE_GIT_UPLOADPACK_CONFIGURED" -eq 1 ]; then
                printf 'local\0file:%s/.git/config\0remote.origin.uploadpack\nmalicious-upload-pack\0' \
                    "$repository_root"
            fi
            if [ "$FAKE_GIT_VCS_CONFIGURED" -eq 1 ]; then
                printf 'local\0file:%s/.git/config\0remote.origin.vcs\nmalicious-transport\0' \
                    "$repository_root"
            fi
            if [ "$FAKE_GIT_PARTIAL_CLONE_CONFIGURED" -eq 1 ]; then
                printf 'local\0file:%s/.git/config\0remote.evil.promisor\ntrue\0' \
                    "$repository_root"
            fi
            exit 0
        fi
        if [ "${1-}" = "--includes" ] && [ "${2-}" = "--null" ] &&
            [ "${3-}" = "--list" ]; then
            printf 'remote.origin.url\n%s\0' "$FAKE_GIT_REMOTE_URL"
            if [ "$FAKE_GIT_UPLOADPACK_CONFIGURED" -eq 1 ]; then
                printf 'remote.origin.uploadpack\nmalicious-upload-pack\0'
            fi
            if [ "$FAKE_GIT_VCS_CONFIGURED" -eq 1 ]; then
                printf 'remote.origin.vcs\nmalicious-transport\0'
            fi
            if [ "$FAKE_GIT_PARTIAL_CLONE_CONFIGURED" -eq 1 ]; then
                printf 'remote.evil.promisor\ntrue\0'
            fi
            exit 0
        fi
        if [ "${1-}" = "--null" ] && [ "${2-}" = "--get-all" ]; then
            case "${3-}" in
                filter.*.clean | filter.*.smudge | filter.*.process)
                    if [ "$FAKE_GIT_FILTER_CONFIGURED" -eq 1 ]; then
                        printf '%s\0' malicious-filter
                        exit 0
                    fi
                    exit 1
                    ;;
            esac
        fi
        case "${2-}" in
            branch.*.remote) printf '%s\n' "$FAKE_GIT_UPSTREAM_REMOTE" ;;
            branch.*.merge)
                if [ -s "$repository_root/.git/fake-upstream-ref" ]; then
                    cat "$repository_root/.git/fake-upstream-ref"
                else
                    printf '%s\n' "$FAKE_GIT_UPSTREAM_REF"
                fi
                ;;
            *) exit 1 ;;
        esac
        exit 0
        ;;
    status)
        if [ -e "$repository_root/.git/forced-dirty" ]; then
            printf '%s\n' ' M bin/agent-skills'
        fi
        if [ -e "$repository_root/.git/forced-untracked" ]; then
            printf '%s\n' '?? local-data'
        fi
        if [ -n "$FAKE_GIT_STATUS_OUTPUT" ]; then
            printf '%s\n' "$FAKE_GIT_STATUS_OUTPUT"
        fi
        exit "$FAKE_GIT_STATUS_STATUS"
        ;;
    ls-files)
        case " $* " in
            *' --stage '*)
                printf '100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0\t.agent-skills-id\0'
                printf '100755 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 0\tbin/agent-skills\0'
                ;;
            *)
                printf '%s .agent-skills-id\0' "$FAKE_GIT_INDEX_TAG"
                printf '%s bin/agent-skills\0' "$FAKE_GIT_INDEX_TAG"
                ;;
        esac
        exit 0
        ;;
    ls-tree)
        printf '040000 tree cccccccccccccccccccccccccccccccccccccccc\tbin\0'
        printf '100644 blob aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t.agent-skills-id\0'
        printf '100755 blob bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tbin/agent-skills\0'
        exit 0
        ;;
    read-tree)
        : >"${GIT_INDEX_FILE:?}"
        exit 0
        ;;
    check-attr)
        if [ "$FAKE_GIT_BLOCK_CHECK_ATTR" = "1" ]; then
            sleep 30 &
            child_pid=$!
            printf '%s\n' "$child_pid" >"$FAKE_GIT_CHILD_PID_FILE"
            wait "$child_pid"
            exit $?
        fi
        printf '.agent-skills-id\0filter\0unspecified\0'
        if [ -n "$FAKE_GIT_FILTER_DRIVER" ]; then
            printf 'bin/agent-skills\0filter\0%s\0' "$FAKE_GIT_FILTER_DRIVER"
        else
            printf 'bin/agent-skills\0filter\0unspecified\0'
        fi
        exit 0
        ;;
    checkout-index)
        exit "$FAKE_GIT_FILTER_PROBE_STATUS"
        ;;
    cat-file)
        while IFS= read -r object_id; do
            case "$object_id" in
                aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
                    object_path=$repository_root/.agent-skills-id
                    ;;
                bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
                    object_path=$repository_root/bin/agent-skills
                    ;;
                *) exit 1 ;;
            esac
            object_size=$(wc -c <"$object_path")
            printf '%s blob %s\n' "$object_id" "$object_size"
            cat "$object_path"
            printf '\n'
        done
        exit 0
        ;;
    ls-remote)
        if [ "${1-}" = "--get-url" ]; then
            if [ "${2-}" = "origin" ]; then
                if [ -f "$repository_root/.git/remote-name" ] &&
                    [ "$(cat "$repository_root/.git/remote-name")" != "origin" ]; then
                    exit 1
                fi
                if [ "$FAKE_GIT_ORIGIN_EFFECTIVE_URL" = "__raw_origin__" ]; then
                    printf '%s\n' "$FAKE_GIT_REMOTE_URL"
                else
                    printf '%s\n' "$FAKE_GIT_ORIGIN_EFFECTIVE_URL"
                fi
            else
                printf '%s\n' "$FAKE_GIT_DIRECT_EFFECTIVE_URL"
            fi
            exit 0
        fi

        count=0
        if [ -f "$FAKE_GIT_COUNTER" ]; then
            IFS= read -r count <"$FAKE_GIT_COUNTER" || count=0
        fi
        count=$((count + 1))
        printf '%s\n' "$count" >"$FAKE_GIT_COUNTER"

        if [ "$FAKE_GIT_BLOCK_LS_REMOTE" = "1" ]; then
            sleep 30 &
            child_pid=$!
            printf '%s\n' "$child_pid" >"$FAKE_GIT_CHILD_PID_FILE"
            wait "$child_pid"
            exit $?
        fi

        case "$count" in
            1) remote_status=$FAKE_GIT_LS_REMOTE_1_STATUS ;;
            *) remote_status=$FAKE_GIT_LS_REMOTE_2_STATUS ;;
        esac
        if [ "$remote_status" -eq 0 ]; then
            remote_ref=
            for argument in "$@"; do
                remote_ref=$argument
            done
            printf '1111111111111111111111111111111111111111\t%s\n' "$remote_ref"
        fi
        exit "$remote_status"
        ;;
    clone)
        if [ "$FAKE_GIT_CLONE_STATUS" -ne 0 ]; then
            exit "$FAKE_GIT_CLONE_STATUS"
        fi
        if [ "$FAKE_GIT_BLOCK_CLONE" = "1" ]; then
            : >"$FAKE_GIT_CLONE_MARKER"
            printf '%s\n' "$$" >"$FAKE_GIT_CHILD_PID_FILE"
            while [ ! -e "$FAKE_GIT_CLONE_GATE" ]; do
                sleep 0.05
            done
        fi
        destination=
        clone_origin=$FAKE_GIT_CLONE_DEFAULT_REMOTE_NAME
        previous_argument=
        for argument in "$@"; do
            if [ "$previous_argument" = "--origin" ]; then
                clone_origin=$argument
            fi
            previous_argument=$argument
            destination=$argument
        done
        mkdir -p "$destination/.git" "$destination/bin"
        printf '%s\n' "$clone_origin" >"$destination/.git/remote-name"
        cp "$FAKE_CLI_TEMPLATE" "$destination/bin/agent-skills"
        chmod +x "$destination/bin/agent-skills"
        printf '%s\n' '11111111-1111-4111-8111-111111111111' >"$destination/.agent-skills-id"
        exit 0
        ;;
    fetch)
        : >"$FAKE_GIT_FETCH_MARKER"
        if [ -e "$repository_root/.git/index.lock" ]; then
            exit 1
        fi
        fetch_refspec=
        for argument in "$@"; do
            fetch_refspec=$argument
        done
        temporary_ref=${fetch_refspec#*:}
        mkdir -p "$repository_root/.git/${temporary_ref%/*}"
        printf '%s\n' '1111111111111111111111111111111111111111' >"$repository_root/.git/$temporary_ref"
        case "$FAKE_GIT_FETCH_MUTATION" in
            fetch-head)
                printf '%s\n' '2222222222222222222222222222222222222222' >"$repository_root/.git/FETCH_HEAD"
                ;;
            remote-ref)
                mkdir -p "$repository_root/.git/refs/remotes/origin"
                printf '%s\n' '2222222222222222222222222222222222222222' >"$repository_root/.git/refs/remotes/origin/main"
                ;;
            lock-file)
                : >"$repository_root/.git/index.lock"
                ;;
            branch)
                printf '%s\n' feature >"$repository_root/.git/fake-current-branch"
                ;;
            upstream-ref)
                printf '%s\n' refs/heads/feature >"$repository_root/.git/fake-upstream-ref"
                ;;
            head)
                printf '%s\n' '2222222222222222222222222222222222222222' >"$FAKE_GIT_HEAD_FILE"
                ;;
            worktree)
                : >"$repository_root/.git/forced-dirty"
                ;;
            untracked)
                : >"$repository_root/.git/forced-untracked"
                ;;
        esac
        if [ "$FAKE_GIT_BLOCK_FETCH" = "1" ]; then
            sleep 30 &
            child_pid=$!
            printf '%s\n' "$child_pid" >"$FAKE_GIT_CHILD_PID_FILE"
            wait "$child_pid"
            exit $?
        fi
        exit "$FAKE_GIT_FETCH_STATUS"
        ;;
    merge-base)
        exit "$FAKE_GIT_MERGE_BASE_STATUS"
        ;;
    merge)
        fetched_head=
        for argument in "$@"; do
            fetched_head=$argument
        done
        printf '%s\n' "$fetched_head" >"$FAKE_GIT_HEAD_FILE"
        if [ "$FAKE_GIT_FAST_FORWARD_MUTATION" = "dirty-cli" ]; then
            printf '%s\n' '#!/bin/sh' 'exit 93' >"$repository_root/bin/agent-skills"
            chmod +x "$repository_root/bin/agent-skills"
            : >"$repository_root/.git/forced-dirty"
        fi
        exit 0
        ;;
    reset)
        exit 0
        ;;
    update-ref)
        if [ "${1-}" = "-d" ]; then
            rm -f "$repository_root/.git/${2-}"
            exit 0
        fi
        exit 1
        ;;
    write-tree)
        printf '%s\n' 1111111111111111111111111111111111111111
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF

  cat >"$FAKE_CLI_TEMPLATE" <<'PY'
#!/usr/bin/env python3

import os
from pathlib import Path
import sys


if __name__ == "__main__":
    arguments = sys.argv[1:]
    internal_post_pull = os.environ.get("AGENT_SKILLS_INTERNAL_POST_PULL", "")
    no_replace_objects = os.environ.get("GIT_NO_REPLACE_OBJECTS", "")
    graft_file = os.environ.get("GIT_GRAFT_FILE", "")
    with open(os.environ["FAKE_CLI_LOG"], "a", encoding="utf-8") as log:
        log.write(
            f"{' '.join(arguments)} [internal-post-pull={internal_post_pull}] "
            f"[no-replace-objects={no_replace_objects}] "
            f"[graft-file={graft_file}]\n"
        )

    if not arguments or arguments[0] not in ("validate", "sync"):
        raise SystemExit(1)
    if arguments[0] == os.environ["FAKE_CLI_BLOCK_COMMAND"]:
        Path(os.environ["FAKE_CLI_CHILD_PID_FILE"]).write_text(f"{os.getpid()}\n", encoding="utf-8")
        Path(os.environ["FAKE_CLI_MARKER"]).touch()
        while not Path(os.environ["FAKE_CLI_GATE"]).exists():
            import time

            time.sleep(0.01)
        Path(os.environ["FAKE_CLI_AFTER_GATE"]).touch()
    status_name = "FAKE_CLI_" + arguments[0].upper() + "_STATUS"
    raise SystemExit(int(os.environ[status_name]))
PY

  chmod +x "$CASE_BIN/git" "$CASE_BIN/python3" "$FAKE_CLI_TEMPLATE"
}

create_existing_repository() {
  mkdir -p "$CASE_REPOSITORY/.git" "$CASE_REPOSITORY/bin"
  cp "$FAKE_CLI_TEMPLATE" "$CASE_REPOSITORY/bin/agent-skills"
  chmod +x "$CASE_REPOSITORY/bin/agent-skills"
  printf '%s\n' '11111111-1111-4111-8111-111111111111' >"$CASE_REPOSITORY/.agent-skills-id"
}

repository_lock_path() {
  "$REAL_PYTHON3" - "$CASE_REPOSITORY" <<'PY'
import hashlib
import os
import sys

repository_path = os.path.normpath(os.path.abspath(sys.argv[1]))
repository_parent = os.path.dirname(repository_path)
repository_name = os.path.basename(repository_path)
parent_status = os.stat(repository_parent)
identity = (
    b"agent-skills-repository-lock-v2\0"
    + str(parent_status.st_dev).encode("ascii")
    + b"\0"
    + str(parent_status.st_ino).encode("ascii")
    + b"\0"
    + os.fsencode(repository_name)
)
lock_digest = hashlib.sha256(identity).hexdigest()
lock_root = os.path.join(
    os.path.realpath("/tmp"),
    f"agent-skills-repository-locks.{os.geteuid()}",
)
print(os.path.join(lock_root, f"{lock_digest}.lock"))
PY
}

run_setup() {
  runner_mode=${1-wait}
  run_output=${2-$CASE_OUTPUT}
  run_status_file=${3-$CASE_STATUS}
  RUN_STATUS=$RUN_STATUS_INVALID
  if ! rm -f "$run_status_file"; then
    echo "setup runner status file could not be removed: $run_status_file" >&2
    return 1
  fi
  setup_argument=
  if [ "$RUN_CHECK_ONLY" -eq 1 ]; then
    setup_argument=--check
  fi
  "$REAL_PYTHON3" - \
    "$runner_mode" \
    "$run_output" \
    "$run_status_file" \
    "$FAKE_GIT_CHILD_PID_FILE" \
    "$FAKE_GIT_CLONE_MARKER" \
    "$FAKE_GIT_CLONE_GATE" \
    "$FAKE_PUBLISH_MARKER" \
    "$FAKE_PUBLISH_GATE" \
    "$FAKE_CLI_MARKER" \
    "$FAKE_CLI_CHILD_PID_FILE" \
    "$FAKE_PARENT_MARKER" \
    "$FAKE_FETCH_MARKER" \
    "$FAKE_OPERATION_RUNNER_MARKER" \
    "$PRE_REAP_MARKER" \
    "$FAKE_CLEANUP_MARKER" \
    "$FAKE_CLEANUP_GATE" \
    "$CASE_TMP" \
    "$CASE_WORK" \
    "$CASE_REPOSITORY" \
    "$RUN_SETUP_CWD" \
    /usr/bin/env -i \
    "HOME=$CASE_HOME" \
    "XDG_STATE_HOME=$CASE_STATE_HOME" \
    "PATH=$CASE_BIN:/usr/bin:/bin" \
    "TMPDIR=$RUN_TMPDIR" \
    "LC_ALL=C" \
    "TEST_REAL_PYTHON3=$REAL_PYTHON3" \
    "AGENT_SKILLS_REPO_DIR=$CASE_REPOSITORY" \
    "AGENT_SKILLS_REPO_URL=$RUN_REPOSITORY_URL" \
    "AGENT_SKILLS_STRICT=$RUN_STRICT" \
    "AGENT_SKILLS_SKIP=$RUN_SKIP" \
    "AGENT_SKILLS_GIT_TIMEOUT_SECONDS=$RUN_GIT_TIMEOUT" \
    "AGENT_SKILLS_INTERNAL_TEST_STOP_BEFORE_LOCK_HELPER=$RUN_STOP_BEFORE_LOCK_HELPER" \
    "AGENT_SKILLS_INTERNAL_TEST_PUBLISH_MARKER=$RUN_PUBLISH_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_PUBLISH_GATE=$RUN_PUBLISH_GATE" \
    "AGENT_SKILLS_INTERNAL_TEST_PARENT_MARKER=$RUN_PARENT_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_PARENT_GATE=$RUN_PARENT_GATE" \
    "AGENT_SKILLS_INTERNAL_TEST_LOCK_WAIT_MARKER=$RUN_LOCK_WAIT_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_CLEANUP_MARKER=$RUN_CLEANUP_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_CLEANUP_GATE=$RUN_CLEANUP_GATE" \
    "AGENT_SKILLS_INTERNAL_TEST_CLEANUP_ERROR_MARKER=$RUN_CLEANUP_ERROR_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_FETCH_MARKER=$RUN_FETCH_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_FETCH_GATE=$RUN_FETCH_GATE" \
    "AGENT_SKILLS_INTERNAL_TEST_OPERATION_RUNNER_MARKER=$RUN_OPERATION_RUNNER_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_OPERATION_RUNNER_COMMAND=$RUN_OPERATION_RUNNER_COMMAND" \
    "FAKE_GIT_LOG=$FAKE_GIT_LOG" \
    "FAKE_GIT_ENV_LOG=$FAKE_GIT_ENV_LOG" \
    "FAKE_CLI_LOG=$FAKE_CLI_LOG" \
    "FAKE_CLI_CHILD_PID_FILE=$FAKE_CLI_CHILD_PID_FILE" \
    "FAKE_CLI_MARKER=$FAKE_CLI_MARKER" \
    "FAKE_CLI_GATE=$FAKE_CLI_GATE" \
    "FAKE_CLI_AFTER_GATE=$FAKE_CLI_AFTER_GATE" \
    "FAKE_CLI_BLOCK_COMMAND=$RUN_BLOCK_CLI_COMMAND" \
    "FAKE_GIT_COUNTER=$FAKE_GIT_COUNTER" \
    "FAKE_GIT_CHILD_PID_FILE=$FAKE_GIT_CHILD_PID_FILE" \
    "FAKE_GIT_CLONE_MARKER=$FAKE_GIT_CLONE_MARKER" \
    "FAKE_GIT_CLONE_GATE=$FAKE_GIT_CLONE_GATE" \
    "FAKE_GIT_HEAD_FILE=$FAKE_GIT_HEAD_FILE" \
    "FAKE_GIT_FETCH_MARKER=$FAKE_GIT_FETCH_MARKER" \
    "FAKE_GIT_TTY_STATE_FILE=$FAKE_GIT_TTY_STATE_FILE" \
    "FAKE_CLI_TEMPLATE=$FAKE_CLI_TEMPLATE" \
    "FAKE_GIT_REMOTE_URL=$RUN_REMOTE_URL" \
    "FAKE_GIT_REMOTE_URL_COUNT=$RUN_REMOTE_URL_COUNT" \
    "FAKE_GIT_REMOTE_URL_2=$RUN_REMOTE_URL_2" \
    "FAKE_GIT_DIRECT_EFFECTIVE_URL=$RUN_DIRECT_EFFECTIVE_URL" \
    "FAKE_GIT_ORIGIN_EFFECTIVE_URL=$RUN_ORIGIN_EFFECTIVE_URL" \
    "FAKE_GIT_CLONE_DEFAULT_REMOTE_NAME=$RUN_CLONE_DEFAULT_REMOTE_NAME" \
    "FAKE_GIT_LS_REMOTE_1_STATUS=$RUN_LS_REMOTE_1_STATUS" \
    "FAKE_GIT_LS_REMOTE_2_STATUS=$RUN_LS_REMOTE_2_STATUS" \
    "FAKE_GIT_CLONE_STATUS=$RUN_CLONE_STATUS" \
    "FAKE_GIT_REV_PARSE_STATUS=$RUN_REV_PARSE_STATUS" \
    "FAKE_GIT_SYMBOLIC_REF_STATUS=$RUN_SYMBOLIC_REF_STATUS" \
    "FAKE_GIT_CONFIG_STATUS=$RUN_CONFIG_STATUS" \
    "FAKE_GIT_UPLOADPACK_CONFIGURED=$RUN_UPLOADPACK_CONFIGURED" \
    "FAKE_GIT_VCS_CONFIGURED=$RUN_VCS_CONFIGURED" \
    "FAKE_GIT_PARTIAL_CLONE_CONFIGURED=$RUN_PARTIAL_CLONE_CONFIGURED" \
    "FAKE_GIT_INDEX_TAG=$RUN_INDEX_TAG" \
    "FAKE_GIT_FILTER_DRIVER=$RUN_FILTER_DRIVER" \
    "FAKE_GIT_FILTER_CONFIGURED=$RUN_FILTER_CONFIGURED" \
    "FAKE_GIT_FILTER_PROBE_STATUS=$RUN_FILTER_PROBE_STATUS" \
    "FAKE_GIT_CURRENT_BRANCH=$RUN_CURRENT_BRANCH" \
    "FAKE_GIT_UPSTREAM_REMOTE=$RUN_UPSTREAM_REMOTE" \
    "FAKE_GIT_UPSTREAM_REF=$RUN_UPSTREAM_REF" \
    "FAKE_GIT_STATUS_STATUS=$RUN_GIT_STATUS_STATUS" \
    "FAKE_GIT_STATUS_OUTPUT=$RUN_GIT_STATUS_OUTPUT" \
    "FAKE_GIT_FETCH_STATUS=$RUN_FETCH_STATUS" \
    "FAKE_GIT_BLOCK_LS_REMOTE=$RUN_BLOCK_LS_REMOTE" \
    "FAKE_GIT_BLOCK_CLONE=$RUN_BLOCK_CLONE" \
    "FAKE_GIT_BLOCK_FETCH=$RUN_BLOCK_FETCH" \
    "FAKE_GIT_BLOCK_CHECK_ATTR=$RUN_BLOCK_CHECK_ATTR" \
    "FAKE_GIT_FETCH_MUTATION=$RUN_FETCH_MUTATION" \
    "FAKE_GIT_FAST_FORWARD_MUTATION=$RUN_FAST_FORWARD_MUTATION" \
    "FAKE_GIT_MERGE_BASE_STATUS=$RUN_MERGE_BASE_STATUS" \
    "FAKE_CLI_VALIDATE_STATUS=$RUN_CLI_VALIDATE_STATUS" \
    "FAKE_CLI_SYNC_STATUS=$RUN_CLI_SYNC_STATUS" \
    "$RUN_SETUP_SHELL" "$SETUP_SCRIPT" ${setup_argument:+"$setup_argument"} <<'PY'
import contextlib
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

(
    mode,
    output_path,
    status_path,
    signal_marker_path,
    kill_marker_path,
    clone_gate_path,
    publish_marker_path,
    publish_gate_path,
    cli_marker_path,
    cli_pid_path,
    parent_marker_path,
    fetch_marker_path,
    operation_runner_marker_path,
    pre_reap_marker_path,
    cleanup_marker_path,
    cleanup_gate_path,
    case_tmp_path,
    case_work_path,
    repository_path,
    setup_cwd_path,
) = sys.argv[1:21]
command = sys.argv[21:]


def wait_for_process_gone(pid_path, timeout=5):
    try:
        child_pid = int(Path(pid_path).read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.01)
    return False


def wait_for_supervisor_cleanup(timeout=5):
    deadline = time.monotonic() + timeout
    case_tmp = Path(case_tmp_path)
    case_work = Path(case_work_path)
    while time.monotonic() < deadline:
        state_exists = any(case_tmp.glob("agent-skills-supervisor.*"))
        clone_exists = any(case_work.glob("**/.agent-skills.clone.*"))
        if not state_exists and not clone_exists:
            return True
        time.sleep(0.01)
    return False


def wait_for_created_parent_cleanup(timeout=5):
    case_work = Path(case_work_path)
    repository = Path(repository_path)
    try:
        first_created_component = repository.relative_to(case_work).parts[0]
    except (ValueError, IndexError):
        return False
    created_root = case_work / first_created_component
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not created_root.exists() and not created_root.is_symlink():
            return True
        time.sleep(0.01)
    return False


def record_pre_reap_cleanup(child_pid_path=None, require_parent_cleanup=False):
    child_gone = child_pid_path is None or wait_for_process_gone(child_pid_path)
    artifacts_gone = wait_for_supervisor_cleanup()
    parents_gone = not require_parent_cleanup or wait_for_created_parent_cleanup()
    if child_gone and artifacts_gone and parents_gone:
        Path(pre_reap_marker_path).write_text("cleanup completed before setup wait\n", encoding="utf-8")
        return True
    return False

if mode == "runner-failure":
    raise SystemExit(86)

with open(output_path, "wb") as output:
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        cwd=setup_cwd_path,
    )
    if mode == "kill-before-lock-helper":
        deadline = time.monotonic() + 60
        stopped = False
        while time.monotonic() < deadline:
            waited_pid, wait_status = os.waitpid(process.pid, os.WNOHANG | os.WUNTRACED)
            if waited_pid == 0:
                time.sleep(0.01)
                continue
            if os.WIFSTOPPED(wait_status):
                stopped = True
            else:
                process.returncode = os.waitstatus_to_exitcode(wait_status)
            break

        if not stopped:
            if process.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            return_code = 125
        else:
            os.kill(process.pid, signal.SIGKILL)
            record_pre_reap_cleanup()
            return_code = process.wait(timeout=5)
    elif mode in (
        "signal",
        "kill",
        "kill-git-parent",
        "kill-cli-parent",
        "kill-publish",
        "kill-parent-created",
        "kill-fetch-ref",
        "signal-fetch-ref",
        "destination-race",
        "signal-lock",
        "signal-control-lock",
        "signal-cleanup-twice",
        "kill-operation-registration-race",
    ):
        if mode == "kill":
            marker_path = kill_marker_path
            child_pid_path = signal_marker_path
        elif mode in ("kill-publish", "destination-race"):
            marker_path = publish_marker_path
            child_pid_path = None
        elif mode == "kill-cli-parent":
            marker_path = cli_marker_path
            child_pid_path = cli_pid_path
        elif mode == "signal-cleanup-twice":
            marker_path = cli_marker_path
            child_pid_path = cli_pid_path
        elif mode in ("kill-fetch-ref", "signal-fetch-ref"):
            marker_path = fetch_marker_path
            child_pid_path = None
        elif mode in ("kill-parent-created", "signal-lock"):
            marker_path = parent_marker_path
            child_pid_path = None
        elif mode == "kill-operation-registration-race":
            marker_path = operation_runner_marker_path
            child_pid_path = signal_marker_path
        else:
            marker_path = signal_marker_path
            child_pid_path = signal_marker_path
        deadline = time.monotonic() + 60
        while process.poll() is None and not Path(marker_path).exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if not Path(marker_path).exists():
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            return_code = 125
        elif mode == "kill-operation-registration-race":
            deadline = time.monotonic() + 5
            while (
                process.poll() is None
                and not Path(child_pid_path).exists()
                and time.monotonic() < deadline
            ):
                time.sleep(0.01)
            if not Path(child_pid_path).exists():
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                return_code = 125
            else:
                os.kill(process.pid, signal.SIGKILL)
                record_pre_reap_cleanup(child_pid_path)
                return_code = process.wait(timeout=5)
        elif mode == "signal-cleanup-twice":
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            deadline = time.monotonic() + 5
            while (
                process.poll() is None
                and not Path(cleanup_marker_path).exists()
                and time.monotonic() < deadline
            ):
                time.sleep(0.01)
            if not Path(cleanup_marker_path).exists():
                Path(cleanup_gate_path).touch()
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                return_code = 127
            else:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(process.pid, signal.SIGTERM)
                time.sleep(0.2)
                exited_during_cleanup = process.poll() is not None
                Path(cleanup_gate_path).touch()
                if exited_during_cleanup:
                    process.wait(timeout=5)
                    wait_for_supervisor_cleanup()
                    return_code = 126
                else:
                    return_code = process.wait(timeout=5)
        elif mode in ("signal", "signal-fetch-ref", "signal-lock", "signal-control-lock"):
            control_lock_fd = None
            return_code = None
            if mode == "signal-control-lock":
                control_paths = list(Path(case_tmp_path).glob("agent-skills-supervisor.*/control"))
                if len(control_paths) != 1:
                    return_code = 126
                    Path(status_path).write_text(f"{return_code}\n", encoding="utf-8")
                    raise SystemExit(0)
                control_lock_fd = os.open(control_paths[0], os.O_RDONLY)
                fcntl.flock(control_lock_fd, fcntl.LOCK_SH)
            time.sleep(0.1)
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            if control_lock_fd is not None:
                # exclusive lock 取得まで cleanup state を保持する
                time.sleep(0.7)
                if not list(Path(case_tmp_path).glob("agent-skills-supervisor.*")):
                    return_code = 127
                    os.close(control_lock_fd)
                    control_lock_fd = None
                else:
                    os.close(control_lock_fd)
                    control_lock_fd = None
            try:
                if return_code == 127:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                else:
                    return_code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                return_code = 124
            if control_lock_fd is not None:
                os.close(control_lock_fd)
        elif mode == "destination-race":
            Path(repository_path).mkdir()
            Path(publish_gate_path).touch()
            try:
                return_code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
                return_code = 124
        else:
            os.kill(process.pid, signal.SIGKILL)
            record_pre_reap_cleanup(
                child_pid_path,
                require_parent_cleanup=mode == "kill-parent-created",
            )
            return_code = process.wait(timeout=5)
    else:
        try:
            return_code = process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            return_code = 124

if mode != "missing-status":
    Path(status_path).write_text(f"{return_code}\n", encoding="utf-8")
PY
  runner_status=$?
  if [ "$runner_status" -ne 0 ]; then
    echo "setup runner failed with status $runner_status" >&2
    return 1
  fi
  if [ ! -s "$run_status_file" ]; then
    echo "setup runner status file is missing or empty: $run_status_file" >&2
    return 1
  fi
  run_status=
  if ! IFS= read -r run_status <"$run_status_file"; then
    echo "setup runner status file could not be read: $run_status_file" >&2
    return 1
  fi
  RUN_STATUS=$run_status
}

assert_status() {
  expected=$1
  if [ "$RUN_STATUS" = "$expected" ]; then
    return 0
  fi
  echo "expected status $expected, got $RUN_STATUS" >&2
  sed -n '1,120p' "$CASE_OUTPUT" >&2
  return 1
}

assert_nonzero_status() {
  if [ "$RUN_STATUS" = "$RUN_STATUS_INVALID" ]; then
    echo "setup runner did not provide a status" >&2
    return 1
  fi
  if [ "$RUN_STATUS" != "0" ]; then
    return 0
  fi
  echo "expected a nonzero status" >&2
  sed -n '1,120p' "$CASE_OUTPUT" >&2
  return 1
}

assert_contains() {
  file=$1
  expected=$2
  if grep -F -- "$expected" "$file" >/dev/null 2>&1; then
    return 0
  fi
  echo "expected $file to contain: $expected" >&2
  sed -n '1,120p' "$file" >&2
  return 1
}

assert_not_contains() {
  file=$1
  unexpected=$2
  if ! grep -F -- "$unexpected" "$file" >/dev/null 2>&1; then
    return 0
  fi
  echo "expected $file not to contain: $unexpected" >&2
  sed -n '1,120p' "$file" >&2
  return 1
}

assert_empty() {
  file=$1
  if [ ! -s "$file" ]; then
    return 0
  fi
  echo "expected $file to be empty" >&2
  sed -n '1,120p' "$file" >&2
  return 1
}

wait_for_test_path() {
  target_path=$1
  attempts=${2-3000}
  current_attempt=0
  while [ ! -e "$target_path" ] && [ "$current_attempt" -lt "$attempts" ]; do
    sleep 0.01
    current_attempt=$((current_attempt + 1))
  done
  if [ -e "$target_path" ]; then
    return 0
  fi
  echo "timed out waiting for test path: $target_path" >&2
  return 1
}

assert_no_artifacts() {
  root=$1
  pattern=$2
  found=$(find "$root" -name "$pattern" -print -quit)
  if [ -z "$found" ]; then
    return 0
  fi
  echo "unexpected temporary artifact: $found" >&2
  return 1
}

assert_no_artifacts_eventually() {
  root=$1
  pattern=$2
  attempts=0
  while [ "$attempts" -lt 100 ]; do
    found=$(find "$root" -name "$pattern" -print -quit)
    if [ -z "$found" ]; then
      return 0
    fi
    sleep 0.05
    attempts=$((attempts + 1))
  done
  echo "unexpected temporary artifact: $found" >&2
  return 1
}

assert_has_artifact() {
  root=$1
  pattern=$2
  found=$(find "$root" -name "$pattern" -print -quit)
  if [ -n "$found" ]; then
    return 0
  fi
  echo "expected temporary artifact matching $pattern under $root" >&2
  return 1
}

assert_line_count() {
  file=$1
  expected_count=$2
  expected=$3
  actual_count=$(grep -F -c -- "$expected" "$file")
  if [ "$actual_count" -eq "$expected_count" ]; then
    return 0
  fi
  echo "expected $file to contain $expected_count lines matching: $expected" >&2
  sed -n '1,120p' "$file" >&2
  return 1
}

assert_network_operations_preceded_by_resolution() {
  "$REAL_PYTHON3" - "$1" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()


def parse(line):
    arguments = line.split()
    while arguments[:1] == ["-c"]:
        arguments = arguments[2:]
    if arguments[:1] == ["-C"]:
        context = arguments[:2]
        arguments = arguments[2:]
    else:
        context = []
    return context, arguments


for index, line in enumerate(lines):
    context, arguments = parse(line)
    if not arguments:
        continue
    if arguments[0] == "ls-remote":
        if arguments[1:2] == ["--get-url"]:
            continue
        source = arguments[-2]
    elif arguments[0] == "clone":
        source = arguments[-2]
    elif arguments[0] == "fetch":
        source = arguments[-2]
    else:
        continue

    if index == 0:
        raise SystemExit(f"network operation has no preceding URL resolution: {line}")
    previous_context, previous_arguments = parse(lines[index - 1])
    if previous_context != context or previous_arguments != ["ls-remote", "--get-url", source]:
        raise SystemExit(
            "network operation is not immediately preceded by matching URL resolution: "
            f"{line}"
        )
PY
}

assert_process_gone() {
  pid_file=$1
  if [ ! -s "$pid_file" ]; then
    echo "expected child PID file: $pid_file" >&2
    return 1
  fi
  IFS= read -r child_pid <"$pid_file"
  attempts=0
  while kill -0 "$child_pid" 2>/dev/null && [ "$attempts" -lt 3 ]; do
    sleep 1
    attempts=$((attempts + 1))
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    echo "child process remains after cleanup: $child_pid" >&2
    return 1
  fi
}

assert_process_gone_now() {
  pid_file=$1
  if [ ! -s "$pid_file" ]; then
    echo "expected child PID file: $pid_file" >&2
    return 1
  fi
  if ! IFS= read -r child_pid <"$pid_file"; then
    echo "child PID file could not be read: $pid_file" >&2
    return 1
  fi
  if kill -0 "$child_pid" 2>/dev/null; then
    echo "child process remains after parent-shell cleanup: $child_pid" >&2
    return 1
  fi
}

test_run_setup_rejects_invalid_runner_results() {
  new_case invalid-runner-results
  RUN_SKIP=1
  run_setup
  assert_status 0 || return 1

  if run_setup runner-failure 2>"$CASE_ROOT/runner-failure.error"; then
    echo "expected run_setup to reject a runner failure" >&2
    return 1
  fi
  [ "$RUN_STATUS" = "$RUN_STATUS_INVALID" ] || return 1
  [ ! -e "$CASE_STATUS" ] || return 1
  assert_contains "$CASE_ROOT/runner-failure.error" "setup runner failed with status 86" || return 1

  printf '%s\n' 0 >"$CASE_STATUS"
  RUN_STATUS=0
  if run_setup missing-status 2>"$CASE_ROOT/missing-status.error"; then
    echo "expected run_setup to reject a missing status file" >&2
    return 1
  fi
  [ "$RUN_STATUS" = "$RUN_STATUS_INVALID" ] || return 1
  [ ! -e "$CASE_STATUS" ] || return 1
  assert_contains "$CASE_ROOT/missing-status.error" "status file is missing or empty" || return 1
}

test_new_clone_success() {
  new_case new-clone-success
  run_setup

  assert_status 0 || return 1
  [ -x "$CASE_REPOSITORY/bin/agent-skills" ] || return 1
  assert_contains "$FAKE_GIT_LOG" "clone --quiet --origin origin" || return 1
  assert_contains "$FAKE_CLI_LOG" "validate" || return 1
  assert_line_count "$FAKE_CLI_LOG" 1 "sync [internal-post-pull=]" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "update" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "install" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "doctor" || return 1
  assert_contains "$FAKE_CLI_LOG" "no-replace-objects=1" || return 1
  assert_contains "$FAKE_CLI_LOG" "graft-file=/dev/null" || return 1
  assert_network_operations_preceded_by_resolution "$FAKE_GIT_LOG" || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
}

test_clone_origin_is_stable_across_reruns() {
  new_case clone-default-remote-name
  RUN_CLONE_DEFAULT_REMOTE_NAME=upstream
  run_setup

  assert_status 0 || return 1
  assert_contains "$FAKE_GIT_LOG" "clone --quiet --origin origin" || return 1
  assert_contains "$CASE_REPOSITORY/.git/remote-name" "origin" || return 1

  run_setup wait "$CASE_ROOT/output.rerun" "$CASE_ROOT/status.rerun"
  assert_status 0 || return 1
  assert_line_count "$FAKE_CLI_LOG" 2 "sync [internal-post-pull=]" || return 1
  assert_contains "$FAKE_GIT_LOG" "fetch --no-tags --no-recurse-submodules --no-write-fetch-head --refmap= --upload-pack=git-upload-pack origin refs/heads/main:refs/agent-skills/setup/" || return 1
}

test_dash_without_tty() {
  dash_shell=$(command -v dash 2>/dev/null || true)
  if [ -z "$dash_shell" ]; then
    echo "dash is not available; skipping dash runtime coverage" >&2
    return 0
  fi

  new_case dash-without-tty
  RUN_SETUP_SHELL=$dash_shell
  run_setup

  assert_status 0 || return 1
  assert_contains "$FAKE_GIT_TTY_STATE_FILE" "no-tty" || return 1
  [ -x "$CASE_REPOSITORY/bin/agent-skills" ] || return 1
}

test_supported_ssh_urls() {
  new_case scp-ssh-url
  RUN_REPOSITORY_URL=git@github.com:pych-ky/agent-skills.git
  run_setup
  assert_status 0 || return 1
  assert_contains "$FAKE_GIT_LOG" "git@github.com:pych-ky/agent-skills.git" || return 1

  new_case ssh-url
  RUN_REPOSITORY_URL=ssh://git@github.com/pych-ky/agent-skills.git
  run_setup
  assert_status 0 || return 1
  assert_contains "$FAKE_GIT_LOG" "ssh://git@github.com/pych-ky/agent-skills.git" || return 1
}

test_unsafe_urls_are_rejected() {
  new_case plain-http-url
  RUN_REPOSITORY_URL=http://github.com/pych-ky/agent-skills.git
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "must use HTTPS or a supported SSH form" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1

  new_case query-credential-url
  RUN_REPOSITORY_URL='https://example.invalid/repo.git?token=dummy'
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "must not contain a query string or fragment" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1

  new_case https-userinfo-url
  RUN_REPOSITORY_URL=https://user@example.invalid/repo.git
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "must use HTTPS without userinfo" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1

  new_case fragment-url
  RUN_REPOSITORY_URL='https://example.invalid/repo.git#revision'
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "must not contain a query string or fragment" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1
}

test_skip_and_access_exit_codes() {
  new_case explicit-skip
  RUN_SKIP=1
  RUN_REPOSITORY_URL=http://example.invalid/repo.git
  RUN_BLOCK_LS_REMOTE=1
  run_setup
  assert_status 0 || return 1
  assert_contains "$CASE_OUTPUT" "AGENT_SKILLS_SKIP=1" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1

  new_case access-skip
  RUN_LS_REMOTE_1_STATUS=1
  run_setup
  assert_status 0 || return 1
  assert_contains "$CASE_OUTPUT" "not accessible; skipping" || return 1

  new_case strict-access-failure
  RUN_LS_REMOTE_1_STATUS=1
  RUN_STRICT=1
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "strict mode" || return 1
}

test_supervisor_startup_failure_is_integrity_error() {
  new_case supervisor-startup-failure
  RUN_TMPDIR=$CASE_ROOT/missing/tmp
  run_setup

  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "TMPDIR must identify an existing directory" || return 1
  assert_not_contains "$CASE_OUTPUT" "not accessible; skipping" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1
}

test_relative_tmpdir_is_resolved_before_repository_entry() {
  new_case relative-tmpdir
  create_existing_repository
  RUN_SETUP_CWD=$CASE_ROOT
  RUN_TMPDIR=tmp
  run_setup

  assert_status 0 || return 1
  assert_contains "$FAKE_CLI_LOG" "sync [internal-post-pull=]" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
  assert_no_artifacts "$CASE_REPOSITORY" 'agent-skills-supervisor.*' || return 1
}

test_trailing_lf_tmpdir_is_preserved() {
  new_case trailing-lf-tmpdir
  trailing_lf='
'
  trailing_lf_tmp=${CASE_ROOT}/tmp${trailing_lf}
  rmdir "$CASE_TMP" || return 1
  mkdir "$trailing_lf_tmp" || return 1
  create_existing_repository
  RUN_TMPDIR=$trailing_lf_tmp
  run_setup

  assert_status 0 || return 1
  [ ! -e "$CASE_TMP" ] || return 1
  assert_no_artifacts "$trailing_lf_tmp" 'agent-skills-supervisor.*' || return 1
}

test_trailing_lf_repository_path_is_preserved() {
  trailing_lf='
'

  new_case trailing-lf-existing-repository
  plain_repository=$CASE_REPOSITORY
  create_existing_repository
  CASE_REPOSITORY=${plain_repository}${trailing_lf}
  create_existing_repository
  run_setup

  assert_status 0 || return 1
  [ ! -e "$CASE_REPOSITORY/.git/FETCH_HEAD" ] || return 1
  assert_contains "$FAKE_CLI_LOG" "sync [internal-post-pull=]" || return 1
  [ ! -e "$plain_repository/.git/FETCH_HEAD" ] || return 1

  new_case trailing-lf-new-repository
  plain_repository=$CASE_REPOSITORY
  create_existing_repository
  printf '%s\n' '#!/bin/sh' 'exit 91' >"$plain_repository/bin/agent-skills"
  chmod +x "$plain_repository/bin/agent-skills"
  CASE_REPOSITORY=${plain_repository}${trailing_lf}
  run_setup

  assert_status 0 || return 1
  [ -x "$CASE_REPOSITORY/bin/agent-skills" ] || return 1
}

test_existing_repository_guards() {
  new_case http-origin
  create_existing_repository
  RUN_REMOTE_URL=http://github.com/pych-ky/agent-skills.git
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "origin does not match" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case trailing-newline-origin-fetch-url
  create_existing_repository
  RUN_REMOTE_URL='https://github.com/pych-ky/agent-skills.git
'
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "exactly one non-empty origin fetch URL" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "ls-remote origin" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case newline-only-second-origin-fetch-url
  create_existing_repository
  RUN_REMOTE_URL_COUNT=2
  RUN_REMOTE_URL_2='
'
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "exactly one non-empty origin fetch URL" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "ls-remote origin" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case multiple-origin-fetch-urls
  create_existing_repository
  RUN_REMOTE_URL='https://example.invalid/unverified.git
https://github.com/pych-ky/agent-skills.git'
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "exactly one non-empty origin fetch URL" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "ls-remote" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "fetch --no-tags" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case non-github-dot-git-mismatch
  create_existing_repository
  RUN_REPOSITORY_URL=git@example.invalid:repos/skills.git
  RUN_REMOTE_URL=git@example.invalid:repos/skills
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "origin does not match" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case unexpected-upstream-remote
  create_existing_repository
  RUN_UPSTREAM_REMOTE=backup
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "must track the verified origin remote" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "fetch --no-tags" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case invalid-upstream-ref
  create_existing_repository
  RUN_UPSTREAM_REF=refs/heads/main:refs/heads/injected
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "invalid origin branch ref" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "fetch --no-tags" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case dirty-repository
  create_existing_repository
  RUN_GIT_STATUS_OUTPUT=' M tracked-file'
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "uncommitted changes" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case uploadpack-override
  create_existing_repository
  RUN_UPLOADPACK_CONFIGURED=1
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "remote.origin.uploadpack must not override" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "ls-remote --upload-pack" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case vcs-override
  create_existing_repository
  RUN_VCS_CONFIGURED=1
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "remote.origin.vcs must not override" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "ls-remote --upload-pack" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case partial-clone-configuration
  create_existing_repository
  RUN_PARTIAL_CLONE_CONFIGURED=1
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "partial-clone and promisor remote configuration" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "ls-tree" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "ls-remote --upload-pack" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  for unsafe_index_tag in h S; do
    new_case unsafe-index-$unsafe_index_tag
    create_existing_repository
    RUN_INDEX_TAG=$unsafe_index_tag
    run_setup
    assert_status 1 || return 1
    assert_contains "$CASE_OUTPUT" "assume-unchanged or skip-worktree" || return 1
    assert_not_contains "$FAKE_GIT_LOG" "ls-remote --upload-pack" || return 1
    assert_empty "$FAKE_CLI_LOG" || return 1
  done

  new_case active-filter
  create_existing_repository
  RUN_FILTER_DRIVER=malicious
  RUN_FILTER_CONFIGURED=1
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "must not use an active Git content filter" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "ls-remote --upload-pack" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  for reserved_filter_driver in unspecified unset; do
    new_case active-filter-$reserved_filter_driver
    create_existing_repository
    RUN_FILTER_DRIVER=$reserved_filter_driver
    RUN_FILTER_CONFIGURED=1
    run_setup
    assert_status 1 || return 1
    assert_contains "$CASE_OUTPUT" "must not use an active Git content filter" || return 1
    assert_not_contains "$FAKE_GIT_LOG" "ls-remote --upload-pack" || return 1
    assert_empty "$FAKE_CLI_LOG" || return 1
  done
}

test_check_only_uses_the_hardened_read_only_diagnostic() {
  new_case check-only
  create_existing_repository
  RUN_CHECK_ONLY=1
  run_setup

  assert_status 0 || return 1
  assert_contains "$CASE_OUTPUT" "repository integrity check passed" || return 1
  assert_contains "$FAKE_GIT_ENV_LOG" "optional-locks=0 graft-file=/dev/null" || return 1
  assert_contains "$FAKE_GIT_ENV_LOG" "lazy-fetch=1" || return 1
  assert_contains "$FAKE_GIT_ENV_LOG" "status --porcelain --untracked-files=all" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "write-tree" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "ls-remote --upload-pack" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "fetch --no-tags" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1
}

test_git_isolation_and_post_update_validation() {
  new_case git-isolation
  create_existing_repository
  RUN_FAST_FORWARD_MUTATION=dirty-cli
  run_setup

  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "uncommitted changes" || return 1
  assert_contains "$FAKE_GIT_LOG" "-c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false" || return 1
  assert_contains "$FAKE_GIT_LOG" "fetch --no-tags --no-recurse-submodules --no-write-fetch-head --refmap= --upload-pack=git-upload-pack" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1
}

test_update_snapshot_is_rechecked_before_fast_forward() {
  for update_mutation in branch upstream-ref head worktree untracked; do
    new_case update-snapshot-$update_mutation
    create_existing_repository
    RUN_FETCH_MUTATION=$update_mutation
    run_setup

    assert_status 1 || return 1
    assert_contains "$CASE_OUTPUT" "changed while the update was being prepared" || return 1
    assert_not_contains "$FAKE_GIT_LOG" " merge --strategy=ort" || return 1
    assert_empty "$FAKE_CLI_LOG" || return 1
  done
}

test_fetch_uses_an_isolated_temporary_ref() {
  new_case isolated-temporary-fetch-ref
  create_existing_repository
  printf '%s\n' 2222222222222222222222222222222222222222 >"$CASE_REPOSITORY/.git/FETCH_HEAD"
  run_setup

  assert_status 0 || return 1
  assert_contains "$CASE_REPOSITORY/.git/FETCH_HEAD" 2222222222222222222222222222222222222222 || return 1
  assert_contains "$FAKE_GIT_LOG" "fetch --no-tags --no-recurse-submodules --no-write-fetch-head" || return 1
  assert_contains "$FAKE_GIT_LOG" "refs/heads/main:refs/agent-skills/setup/" || return 1
  if [ -d "$CASE_REPOSITORY/.git/refs/agent-skills" ] &&
    [ -n "$(find "$CASE_REPOSITORY/.git/refs/agent-skills" -type f -print -quit)" ]; then
    echo "temporary fetched ref remains after setup" >&2
    return 1
  fi
  assert_contains "$FAKE_CLI_LOG" "sync [internal-post-pull=]" || return 1
}

test_parent_sigkill_removes_temporary_fetch_ref() {
  new_case sigkill-after-fetch
  create_existing_repository
  RUN_FETCH_MARKER=$FAKE_FETCH_MARKER
  RUN_FETCH_GATE=$FAKE_FETCH_GATE

  run_setup kill-fetch-ref

  [ "$RUN_STATUS" = "-9" ] || return 1
  [ -e "$FAKE_FETCH_MARKER" ] || return 1
  [ -e "$PRE_REAP_MARKER" ] || return 1
  if [ -d "$CASE_REPOSITORY/.git/refs/agent-skills" ] &&
    [ -n "$(find "$CASE_REPOSITORY/.git/refs/agent-skills" -type f -print -quit)" ]; then
    echo "temporary fetched ref remains after setup SIGKILL" >&2
    return 1
  fi
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_process_group_signal_after_fetch_completes_cleanup() {
  new_case signal-after-fetch
  create_existing_repository
  RUN_FETCH_MARKER=$FAKE_FETCH_MARKER
  RUN_FETCH_GATE=$FAKE_FETCH_GATE

  run_setup signal-fetch-ref

  assert_status 1 || return 1
  [ -e "$FAKE_FETCH_MARKER" ] || return 1
  if [ -d "$CASE_REPOSITORY/.git/refs/agent-skills" ] &&
    [ -n "$(find "$CASE_REPOSITORY/.git/refs/agent-skills" -type f -print -quit)" ]; then
    echo "temporary fetched ref remains after setup process-group signal" >&2
    return 1
  fi
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_effective_url_rewrites_are_constrained() {
  new_case direct-url-rewrite
  RUN_DIRECT_EFFECTIVE_URL=https://unverified.example.invalid/agent-skills.git
  run_setup

  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "effective repository origin does not match" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "clone --quiet" || return 1
  [ ! -e "$FAKE_GIT_COUNTER" ] || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  new_case existing-two-stage-rewrite
  create_existing_repository
  RUN_REMOTE_URL=https://alias.example.invalid/agent-skills.git
  RUN_ORIGIN_EFFECTIVE_URL=https://github.com/pych-ky/agent-skills.git
  RUN_DIRECT_EFFECTIVE_URL=https://unverified.example.invalid/agent-skills.git
  run_setup

  assert_status 0 || return 1
  assert_contains "$FAKE_GIT_LOG" "ls-remote --upload-pack=git-upload-pack origin refs/heads/main" || return 1
  assert_contains "$FAKE_GIT_LOG" "fetch --no-tags --no-recurse-submodules --no-write-fetch-head --refmap= --upload-pack=git-upload-pack origin refs/heads/main:refs/agent-skills/setup/" || return 1
  assert_not_contains "$FAKE_GIT_LOG" "fetch --no-tags --no-recurse-submodules --no-write-fetch-head --refmap= --upload-pack=git-upload-pack https://github.com/pych-ky/agent-skills.git" || return 1
  assert_network_operations_preceded_by_resolution "$FAKE_GIT_LOG" || return 1
}

test_temporary_clone_invariants_precede_cli_execution() {
  new_case temporary-clone-upstream
  RUN_UPSTREAM_REMOTE=upstream
  run_setup

  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "must track the verified origin remote" || return 1
  assert_contains "$FAKE_GIT_LOG" "clone --quiet --origin origin" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1
  [ ! -e "$CASE_REPOSITORY" ] || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
}

test_repository_lock_rejects_unsafe_existing_files() {
  new_case lock-symlink
  lock_path=$(repository_lock_path) || return 1
  lock_root=${lock_path%/*}
  mkdir -p "$lock_root" || return 1
  chmod 700 "$lock_root" || return 1
  [ -d "$lock_root" ] || return 1
  printf '%s\n' untouched >"$CASE_ROOT/unrelated"
  cp "$CASE_ROOT/unrelated" "$CASE_ROOT/unrelated.before"
  ln -s "$CASE_ROOT/unrelated" "$lock_path" || return 1
  run_setup
  symlink_preserved=0
  if [ -L "$lock_path" ] && cmp -s "$CASE_ROOT/unrelated.before" "$CASE_ROOT/unrelated"; then
    symlink_preserved=1
  fi
  rm "$lock_path"
  assert_status 1 || return 1
  [ "$symlink_preserved" -eq 1 ] || return 1
  assert_contains "$CASE_OUTPUT" "repository setup lock could not be acquired" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1

  new_case lock-hardlink
  lock_path=$(repository_lock_path) || return 1
  printf '%s\n' unrelated >"$CASE_ROOT/unrelated"
  chmod 600 "$CASE_ROOT/unrelated"
  ln "$CASE_ROOT/unrelated" "$lock_path" || return 1
  run_setup
  hardlink_preserved=0
  link_count=$("$REAL_PYTHON3" -c 'import os, sys; print(os.stat(sys.argv[1]).st_nlink)' "$lock_path")
  if [ -f "$lock_path" ] && [ "$link_count" -eq 2 ]; then
    hardlink_preserved=1
  fi
  rm "$lock_path"
  assert_status 1 || return 1
  [ "$hardlink_preserved" -eq 1 ] || return 1
  assert_contains "$CASE_OUTPUT" "repository setup lock could not be acquired" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1

  new_case lock-collision
  lock_path=$(repository_lock_path) || return 1
  printf '%s\n' unrelated >"$lock_path"
  chmod 600 "$lock_path"
  cp "$lock_path" "$CASE_ROOT/lock.before"
  run_setup
  collision_preserved=0
  if [ -f "$lock_path" ] && cmp -s "$CASE_ROOT/lock.before" "$lock_path"; then
    collision_preserved=1
  fi
  rm "$lock_path"
  assert_status 1 || return 1
  [ "$collision_preserved" -eq 1 ] || return 1
  assert_contains "$CASE_OUTPUT" "repository setup lock could not be acquired" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1
}

test_repository_lock_gc_removes_unused_files() {
  new_case lock-gc-first
  old_lock_path=$(repository_lock_path) || return 1
  run_setup
  assert_status 0 || return 1
  [ -f "$old_lock_path" ] || return 1

  new_case lock-gc-second
  run_setup
  assert_status 0 || return 1
  if [ -e "$old_lock_path" ] || [ -L "$old_lock_path" ]; then
    echo "unused repository lock was not collected: $old_lock_path" >&2
    return 1
  fi
}

test_existing_uninitialized_state_installs_all() {
  new_case existing-no-state
  create_existing_repository
  run_setup

  assert_status 0 || return 1
  assert_contains "$FAKE_GIT_LOG" "fetch --no-tags --no-recurse-submodules --no-write-fetch-head --refmap= --upload-pack=git-upload-pack origin refs/heads/main:refs/agent-skills/setup/" || return 1
  assert_line_count "$FAKE_CLI_LOG" 1 "sync [internal-post-pull=]" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "update" || return 1
}

test_public_sync_api_avoids_a_second_git_update() {
  new_case public-sync-api
  create_existing_repository
  run_setup

  assert_status 0 || return 1
  assert_line_count "$FAKE_CLI_LOG" 1 "sync [internal-post-pull=]" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "update" || return 1
  assert_not_contains "$FAKE_GIT_LOG" " pull" || return 1
  assert_line_count "$FAKE_GIT_LOG" 1 "fetch --no-tags" || return 1
}

test_empty_and_foreign_state_install_all() {
  new_case empty-state
  RUN_GIT_TIMEOUT=10
  create_existing_repository
  mkdir -p "$CASE_STATE_HOME/agent-skills"
  cat >"$CASE_STATE_HOME/agent-skills/install-state.json" <<'EOF'
{
  "schema_version": 1,
  "profiles": [],
  "installations": []
}
EOF
  run_setup
  assert_status 0 || return 1
  assert_line_count "$FAKE_CLI_LOG" 1 "sync [internal-post-pull=]" || return 1

  new_case foreign-state
  RUN_GIT_TIMEOUT=10
  create_existing_repository
  mkdir -p "$CASE_STATE_HOME/agent-skills"
  cat >"$CASE_STATE_HOME/agent-skills/install-state.json" <<EOF
{
  "schema_version": 1,
  "profiles": [
    {
      "repository_id": "22222222-2222-4222-8222-222222222222",
      "repository_root": "$CASE_WORK/other-skills",
      "client": "codex",
      "install_root": "$CASE_HOME/.agents/skills",
      "selection": {"kind": "all", "skills": [], "excluded": []},
      "default_mode": "copy"
    }
  ],
  "installations": []
}
EOF
  run_setup
  assert_status 0 || return 1
  assert_line_count "$FAKE_CLI_LOG" 1 "sync [internal-post-pull=]" || return 1
}

test_existing_copy_mode_state_is_preserved() {
  new_case existing-copy-state
  create_existing_repository
  mkdir -p "$CASE_STATE_HOME/agent-skills"
  cat >"$CASE_STATE_HOME/agent-skills/install-state.json" <<EOF
{
  "schema_version": 1,
  "profiles": [
    {
      "repository_id": "11111111-1111-4111-8111-111111111111",
      "repository_root": "$CASE_REPOSITORY",
      "client": "codex",
      "install_root": "$CASE_HOME/.agents/skills",
      "selection": {"kind": "explicit", "skills": ["one-skill"], "excluded": []},
      "default_mode": "copy"
    },
    {
      "repository_id": "11111111-1111-4111-8111-111111111111",
      "repository_root": "$CASE_REPOSITORY",
      "client": "claude",
      "install_root": "$CASE_HOME/.claude/skills",
      "selection": {"kind": "all", "skills": [], "excluded": ["other-skill"]},
      "default_mode": "copy"
    }
  ],
  "installations": []
}
EOF
  cp "$CASE_STATE_HOME/agent-skills/install-state.json" "$CASE_ROOT/state.before"
  run_setup

  assert_status 0 || return 1
  assert_line_count "$FAKE_CLI_LOG" 1 "sync [internal-post-pull=]" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "update" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "install" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "doctor" || return 1
  cmp -s "$CASE_ROOT/state.before" "$CASE_STATE_HOME/agent-skills/install-state.json" || return 1
}

test_reclone_preserves_matching_profile() {
  new_case reclone-copy-state
  mkdir -p "$CASE_STATE_HOME/agent-skills"
  cat >"$CASE_STATE_HOME/agent-skills/install-state.json" <<EOF
{
  "schema_version": 1,
  "profiles": [
    {
      "repository_id": "11111111-1111-4111-8111-111111111111",
      "repository_root": "$CASE_WORK/previous-agent-skills",
      "client": "codex",
      "install_root": "$CASE_HOME/.agents/skills",
      "selection": {"kind": "explicit", "skills": ["one-skill"], "excluded": []},
      "default_mode": "copy"
    }
  ],
  "installations": []
}
EOF
  cp "$CASE_STATE_HOME/agent-skills/install-state.json" "$CASE_ROOT/state.before"
  run_setup

  assert_status 0 || return 1
  assert_contains "$FAKE_CLI_LOG" "validate" || return 1
  assert_line_count "$FAKE_CLI_LOG" 1 "sync [internal-post-pull=]" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "install" || return 1
  assert_not_contains "$FAKE_CLI_LOG" "doctor" || return 1
  cmp -s "$CASE_ROOT/state.before" "$CASE_STATE_HOME/agent-skills/install-state.json" || return 1
}

test_clone_failure_is_reclassified() {
  new_case local-clone-failure
  RUN_CLONE_STATUS=1
  RUN_LS_REMOTE_1_STATUS=0
  RUN_LS_REMOTE_2_STATUS=0
  run_setup

  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "clone failed while the repository remained accessible" || return 1
  [ ! -e "$CASE_REPOSITORY" ] || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1

  new_case clone-access-lost
  RUN_CLONE_STATUS=1
  RUN_LS_REMOTE_1_STATUS=0
  RUN_LS_REMOTE_2_STATUS=1
  run_setup
  assert_status 0 || return 1
  assert_contains "$CASE_OUTPUT" "not accessible; skipping" || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1

  new_case clone-status-124
  RUN_CLONE_STATUS=124
  RUN_LS_REMOTE_1_STATUS=0
  RUN_LS_REMOTE_2_STATUS=0
  run_setup
  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "clone failed while the repository remained accessible" || return 1
  assert_not_contains "$CASE_OUTPUT" "not accessible; skipping" || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
}

test_transfer_timeouts_follow_strict_mode() {
  new_case clone-timeout
  RUN_BLOCK_CLONE=1
  RUN_GIT_TIMEOUT=2
  run_setup

  assert_status 0 || return 1
  assert_contains "$CASE_OUTPUT" "not accessible; skipping" || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1

  new_case clone-timeout-strict
  RUN_BLOCK_CLONE=1
  RUN_GIT_TIMEOUT=2
  RUN_STRICT=1
  run_setup

  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "not accessible (strict mode)" || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_fetch_failure_is_integrity_error() {
  new_case fetch-failure-access-lost
  create_existing_repository
  RUN_FETCH_STATUS=1
  RUN_LS_REMOTE_2_STATUS=1
  run_setup

  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "failed after it started" || return 1
  assert_not_contains "$CASE_OUTPUT" "not accessible; skipping" || return 1
  assert_line_count "$FAKE_GIT_LOG" 1 "ls-remote --upload-pack=git-upload-pack origin refs/heads/main" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1

  for fetch_mutation in none fetch-head remote-ref lock-file; do
    new_case fetch-timeout-$fetch_mutation
    create_existing_repository
    RUN_BLOCK_FETCH=1
    RUN_GIT_TIMEOUT=2
    if [ "$fetch_mutation" = "none" ]; then
      RUN_FETCH_MUTATION=
    else
      RUN_FETCH_MUTATION=$fetch_mutation
    fi
    run_setup

    assert_status 1 || return 1
    assert_contains "$CASE_OUTPUT" "repository integrity cannot be guaranteed" || return 1
    assert_not_contains "$CASE_OUTPUT" "not accessible; skipping" || return 1
    assert_empty "$FAKE_CLI_LOG" || return 1
    assert_process_gone "$FAKE_GIT_CHILD_PID_FILE" || return 1

    case "$fetch_mutation" in
    fetch-head) [ -f "$CASE_REPOSITORY/.git/FETCH_HEAD" ] || return 1 ;;
    remote-ref) [ -f "$CASE_REPOSITORY/.git/refs/remotes/origin/main" ] || return 1 ;;
    lock-file)
      [ -f "$CASE_REPOSITORY/.git/index.lock" ] || return 1
      rm "$CASE_REPOSITORY/.git/index.lock"
      RUN_BLOCK_FETCH=0
      RUN_FETCH_MUTATION=
      run_setup wait "$CASE_ROOT/output.retry" "$CASE_ROOT/status.retry"
      assert_status 0 || return 1
      assert_contains "$FAKE_CLI_LOG" "sync [internal-post-pull=]" || return 1
      ;;
    esac
    assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
  done
}

test_parallel_clone_is_excluded() {
  new_case parallel-clone
  RUN_BLOCK_CLONE=1
  RUN_GIT_TIMEOUT=10

  (
    run_setup wait "$CASE_ROOT/output.first" "$CASE_ROOT/status.first"
  ) &
  first_runner_pid=$!

  attempts=0
  while [ ! -e "$FAKE_GIT_CLONE_MARKER" ] && [ "$attempts" -lt 400 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ ! -e "$FAKE_GIT_CLONE_MARKER" ]; then
    : >"$FAKE_GIT_CLONE_GATE"
    wait "$first_runner_pid" 2>/dev/null || true
    echo "first setup did not reach the clone publication lock" >&2
    return 1
  fi
  assert_has_artifact "$CASE_TMP" 'agent-skills-supervisor.*' || return 1

  run_setup wait "$CASE_ROOT/output.second" "$CASE_ROOT/status.second"
  second_status=$RUN_STATUS
  : >"$FAKE_GIT_CLONE_GATE"
  if ! wait "$first_runner_pid"; then
    echo "first setup runner failed" >&2
    sed -n '1,120p' "$CASE_ROOT/output.first" >&2
    return 1
  fi
  if [ ! -s "$CASE_ROOT/status.first" ] ||
    ! IFS= read -r first_status <"$CASE_ROOT/status.first"; then
    echo "first setup status file is missing, empty, or unreadable" >&2
    return 1
  fi

  if [ "$first_status" != "0" ] || [ "$second_status" != "1" ]; then
    echo "expected parallel setup statuses 0 and 1, got $first_status and $second_status" >&2
    sed -n '1,120p' "$CASE_ROOT/output.first" >&2
    sed -n '1,120p' "$CASE_ROOT/output.second" >&2
    return 1
  fi
  assert_contains "$CASE_ROOT/output.second" "another Agent Skills setup is already updating" || return 1
  [ -x "$CASE_REPOSITORY/bin/agent-skills" ] || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_parallel_initial_parent_creation_is_excluded_across_tmpdirs() {
  new_case parallel-initial-parent
  CASE_REPOSITORY=$CASE_WORK/missing/level/agent-skills
  first_tmp=$CASE_ROOT/tmp.first
  second_tmp=$CASE_ROOT/tmp.second
  mkdir -p "$first_tmp" "$second_tmp"
  RUN_TMPDIR=$first_tmp
  RUN_PARENT_MARKER=$FAKE_PARENT_MARKER
  RUN_PARENT_GATE=$FAKE_PARENT_GATE

  (
    run_setup wait "$CASE_ROOT/output.first" "$CASE_ROOT/status.first"
  ) &
  first_runner_pid=$!

  attempts=0
  while [ ! -e "$FAKE_PARENT_MARKER" ] && [ "$attempts" -lt 200 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ ! -e "$FAKE_PARENT_MARKER" ]; then
    : >"$FAKE_PARENT_GATE"
    wait "$first_runner_pid" 2>/dev/null || true
    echo "first setup did not pause after creating the repository parent" >&2
    return 1
  fi

  RUN_TMPDIR=$second_tmp
  RUN_PARENT_MARKER=
  RUN_PARENT_GATE=
  run_setup wait "$CASE_ROOT/output.second" "$CASE_ROOT/status.second"
  second_status=$RUN_STATUS
  : >"$FAKE_PARENT_GATE"
  if ! wait "$first_runner_pid"; then
    echo "first setup runner failed" >&2
    sed -n '1,120p' "$CASE_ROOT/output.first" >&2
    return 1
  fi
  if [ ! -s "$CASE_ROOT/status.first" ] ||
    ! IFS= read -r first_status <"$CASE_ROOT/status.first"; then
    echo "first setup status file is missing, empty, or unreadable" >&2
    return 1
  fi

  if [ "$first_status" != "0" ] || [ "$second_status" != "1" ]; then
    echo "expected parallel setup statuses 0 and 1, got $first_status and $second_status" >&2
    sed -n '1,120p' "$CASE_ROOT/output.first" >&2
    sed -n '1,120p' "$CASE_ROOT/output.second" >&2
    return 1
  fi
  assert_contains "$CASE_ROOT/output.second" "another Agent Skills setup is already updating" || return 1
  [ -x "$CASE_REPOSITORY/bin/agent-skills" ] || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
  assert_no_artifacts "$first_tmp" 'agent-skills-supervisor.*' || return 1
  assert_no_artifacts "$second_tmp" 'agent-skills-supervisor.*' || return 1
}

test_parallel_after_publication_is_excluded() {
  new_case parallel-after-publication
  RUN_BLOCK_CLI_COMMAND=sync

  (
    run_setup wait "$CASE_ROOT/output.first" "$CASE_ROOT/status.first"
  ) &
  first_runner_pid=$!

  attempts=0
  while { [ ! -e "$FAKE_CLI_MARKER" ] || [ ! -d "$CASE_REPOSITORY/.git" ]; } &&
    [ "$attempts" -lt 200 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ ! -e "$FAKE_CLI_MARKER" ] || [ ! -d "$CASE_REPOSITORY/.git" ]; then
    : >"$FAKE_CLI_GATE"
    wait "$first_runner_pid" 2>/dev/null || true
    echo "first setup did not reach sync after publication" >&2
    return 1
  fi
  git_lines_before=$(wc -l <"$FAKE_GIT_LOG")

  run_setup wait "$CASE_ROOT/output.second" "$CASE_ROOT/status.second"
  second_status=$RUN_STATUS
  git_lines_after=$(wc -l <"$FAKE_GIT_LOG")
  : >"$FAKE_CLI_GATE"
  wait "$first_runner_pid" || return 1
  IFS= read -r first_status <"$CASE_ROOT/status.first" || return 1

  [ "$first_status" = "0" ] || return 1
  [ "$second_status" = "1" ] || return 1
  [ "$git_lines_before" -eq "$git_lines_after" ] || return 1
  assert_contains "$CASE_ROOT/output.second" "another Agent Skills setup is already updating" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_parallel_existing_repositories_are_excluded() {
  new_case parallel-existing
  create_existing_repository
  RUN_BLOCK_CLI_COMMAND=sync

  (
    run_setup wait "$CASE_ROOT/output.first" "$CASE_ROOT/status.first"
  ) &
  first_runner_pid=$!

  attempts=0
  while [ ! -e "$FAKE_CLI_MARKER" ] && [ "$attempts" -lt 600 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ ! -e "$FAKE_CLI_MARKER" ]; then
    : >"$FAKE_CLI_GATE"
    wait "$first_runner_pid" 2>/dev/null || true
    echo "first existing setup did not reach sync" >&2
    return 1
  fi
  git_lines_before=$(wc -l <"$FAKE_GIT_LOG")

  run_setup wait "$CASE_ROOT/output.second" "$CASE_ROOT/status.second"
  second_status=$RUN_STATUS
  git_lines_after=$(wc -l <"$FAKE_GIT_LOG")
  : >"$FAKE_CLI_GATE"
  wait "$first_runner_pid" || return 1
  IFS= read -r first_status <"$CASE_ROOT/status.first" || return 1

  [ "$first_status" = "0" ] || return 1
  [ "$second_status" = "1" ] || return 1
  [ "$git_lines_before" -eq "$git_lines_after" ] || return 1
  assert_line_count "$FAKE_GIT_LOG" 1 "fetch --no-tags" || return 1
  assert_contains "$CASE_ROOT/output.second" "another Agent Skills setup is already updating" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

assert_parallel_existing_alias_is_excluded() {
  alias_repository=$1
  real_repository=$CASE_REPOSITORY
  RUN_BLOCK_CLI_COMMAND=sync

  (
    CASE_REPOSITORY=$real_repository
    run_setup wait "$CASE_ROOT/output.first" "$CASE_ROOT/status.first"
  ) &
  first_runner_pid=$!

  attempts=0
  while [ ! -e "$FAKE_CLI_MARKER" ] && [ "$attempts" -lt 600 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ ! -e "$FAKE_CLI_MARKER" ]; then
    : >"$FAKE_CLI_GATE"
    wait "$first_runner_pid" 2>/dev/null || true
    echo "first aliased setup did not reach sync" >&2
    return 1
  fi
  git_lines_before=$(wc -l <"$FAKE_GIT_LOG")

  CASE_REPOSITORY=$alias_repository
  run_setup wait "$CASE_ROOT/output.second" "$CASE_ROOT/status.second"
  second_status=$RUN_STATUS
  git_lines_after=$(wc -l <"$FAKE_GIT_LOG")
  CASE_REPOSITORY=$real_repository
  : >"$FAKE_CLI_GATE"
  wait "$first_runner_pid" || return 1
  IFS= read -r first_status <"$CASE_ROOT/status.first" || return 1

  [ "$first_status" = "0" ] || return 1
  [ "$second_status" = "1" ] || return 1
  [ "$git_lines_before" -eq "$git_lines_after" ] || return 1
  assert_contains "$CASE_ROOT/output.second" "another Agent Skills setup is already updating" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_parallel_symlink_alias_is_excluded() {
  new_case parallel-symlink-alias
  create_existing_repository
  alias_repository=$CASE_WORK/agent-skills-link
  ln -s "$CASE_REPOSITORY" "$alias_repository" || return 1

  assert_parallel_existing_alias_is_excluded "$alias_repository"
}

test_parallel_symlink_dotdot_alias_is_excluded() {
  new_case parallel-symlink-dotdot-alias
  physical_parent=$CASE_WORK/physical-parent
  symlink_target=$physical_parent/through-link
  mkdir -p "$symlink_target"
  CASE_REPOSITORY=$physical_parent/agent-skills
  create_existing_repository
  alias_link=$CASE_WORK/path-link
  ln -s "$symlink_target" "$alias_link" || return 1
  alias_repository=$alias_link/../agent-skills

  assert_parallel_existing_alias_is_excluded "$alias_repository"
}

test_parallel_missing_destination_parent_symlink_is_excluded() {
  new_case parallel-parent-symlink-alias
  real_parent=$CASE_WORK/real-parent
  alias_parent=$CASE_WORK/parent-link
  mkdir -p "$real_parent"
  ln -s "$real_parent" "$alias_parent" || return 1
  CASE_REPOSITORY=$real_parent/agent-skills
  RUN_BLOCK_CLONE=1
  RUN_GIT_TIMEOUT=10

  (
    run_setup wait "$CASE_ROOT/output.first" "$CASE_ROOT/status.first"
  ) &
  first_runner_pid=$!
  attempts=0
  while [ ! -e "$FAKE_GIT_CLONE_MARKER" ] && [ "$attempts" -lt 200 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ ! -e "$FAKE_GIT_CLONE_MARKER" ]; then
    : >"$FAKE_GIT_CLONE_GATE"
    wait "$first_runner_pid" 2>/dev/null || true
    echo "first symlink-parent setup did not reach clone" >&2
    return 1
  fi

  CASE_REPOSITORY=$alias_parent/agent-skills
  run_setup wait "$CASE_ROOT/output.second" "$CASE_ROOT/status.second"
  second_status=$RUN_STATUS
  : >"$FAKE_GIT_CLONE_GATE"
  wait "$first_runner_pid" || return 1
  IFS= read -r first_status <"$CASE_ROOT/status.first" || return 1

  [ "$first_status" = "0" ] || return 1
  [ "$second_status" = "1" ] || return 1
  assert_contains "$CASE_ROOT/output.second" "another Agent Skills setup is already updating" || return 1
  [ -x "$real_parent/agent-skills/bin/agent-skills" ] || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_destination_symlink_after_lock_is_rejected() {
  new_case destination-symlink-after-lock
  existing_repository=$CASE_WORK/b/repo
  CASE_REPOSITORY=$existing_repository
  create_existing_repository
  raced_repository=$CASE_WORK/a/repo
  CASE_REPOSITORY=$raced_repository
  RUN_PARENT_MARKER=$FAKE_PARENT_MARKER
  RUN_PARENT_GATE=$FAKE_PARENT_GATE

  (
    run_setup wait "$CASE_ROOT/output.raced" "$CASE_ROOT/status.raced"
  ) &
  first_runner_pid=$!

  attempts=0
  while [ ! -e "$FAKE_PARENT_MARKER" ] && kill -0 "$first_runner_pid" 2>/dev/null &&
    [ "$attempts" -lt 200 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ ! -e "$FAKE_PARENT_MARKER" ]; then
    : >"$FAKE_PARENT_GATE"
    wait "$first_runner_pid" 2>/dev/null || true
    echo "setup did not pause after acquiring the absent destination lock" >&2
    return 1
  fi

  ln -s "$existing_repository" "$raced_repository" || return 1
  : >"$FAKE_PARENT_GATE"
  wait "$first_runner_pid" || return 1
  IFS= read -r raced_status <"$CASE_ROOT/status.raced" || return 1

  [ "$raced_status" = "1" ] || return 1
  assert_contains "$CASE_ROOT/output.raced" "destination changed after the setup lock" || return 1
  assert_empty "$FAKE_GIT_LOG" || return 1
  assert_empty "$FAKE_CLI_LOG" || return 1
}

test_symlink_retarget_uses_fixed_physical_destination() {
  new_case symlink-retarget-fixed-destination
  target_a=$CASE_WORK/target-a/agent-skills
  target_b=$CASE_WORK/target-b/agent-skills
  alias_repository=$CASE_WORK/agent-skills-alias

  CASE_REPOSITORY=$target_a
  create_existing_repository
  CASE_REPOSITORY=$target_b
  create_existing_repository
  target_a=$("$REAL_PYTHON3" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$target_a") || return 1
  target_b=$("$REAL_PYTHON3" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$target_b") || return 1
  ln -s "$target_a" "$alias_repository" || return 1

  first_git_log=$CASE_ROOT/git.first.log
  first_cli_log=$CASE_ROOT/cli.first.log
  : >"$first_git_log"
  : >"$first_cli_log"
  CASE_REPOSITORY=$alias_repository
  RUN_PARENT_MARKER=$FAKE_PARENT_MARKER
  RUN_PARENT_GATE=$FAKE_PARENT_GATE
  (
    FAKE_GIT_LOG=$first_git_log
    FAKE_CLI_LOG=$first_cli_log
    run_setup wait "$CASE_ROOT/output.first" "$CASE_ROOT/status.first"
  ) &
  first_runner_pid=$!

  attempts=0
  while [ ! -e "$FAKE_PARENT_MARKER" ] && kill -0 "$first_runner_pid" 2>/dev/null &&
    [ "$attempts" -lt 200 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if [ ! -e "$FAKE_PARENT_MARKER" ]; then
    : >"$FAKE_PARENT_GATE"
    wait "$first_runner_pid" 2>/dev/null || true
    echo "first setup did not acquire the fixed destination lock" >&2
    return 1
  fi

  rm "$alias_repository" || return 1
  ln -s "$target_b" "$alias_repository" || return 1

  second_git_log=$CASE_ROOT/git.second.log
  second_cli_log=$CASE_ROOT/cli.second.log
  : >"$second_git_log"
  : >"$second_cli_log"
  CASE_REPOSITORY=$target_b
  RUN_PARENT_MARKER=
  RUN_PARENT_GATE=
  FAKE_GIT_LOG=$second_git_log
  FAKE_CLI_LOG=$second_cli_log
  run_setup wait "$CASE_ROOT/output.second" "$CASE_ROOT/status.second"
  second_status=$RUN_STATUS

  : >"$FAKE_PARENT_GATE"
  wait "$first_runner_pid" || return 1
  IFS= read -r first_status <"$CASE_ROOT/status.first" || return 1

  [ "$first_status" = "0" ] || return 1
  [ "$second_status" = "0" ] || return 1
  [ ! -e "$target_a/.git/FETCH_HEAD" ] || return 1
  [ ! -e "$target_b/.git/FETCH_HEAD" ] || return 1
  assert_contains "$first_cli_log" "sync [internal-post-pull=]" || return 1
  assert_contains "$second_cli_log" "sync [internal-post-pull=]" || return 1
}

test_parallel_macos_case_alias_is_excluded() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "macOS case-insensitive path coverage is not available; skipping" >&2
    return 0
  fi

  new_case parallel-macos-case-alias
  create_existing_repository
  alias_repository=$CASE_WORK/AGENT-SKILLS
  if ! "$REAL_PYTHON3" - "$CASE_REPOSITORY" "$alias_repository" <<'PY'; then
import os
import sys

first = os.stat(sys.argv[1])
try:
    second = os.stat(sys.argv[2])
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if (first.st_dev, first.st_ino) == (second.st_dev, second.st_ino) else 1)
PY
    echo "test filesystem is case-sensitive; skipping macOS case-alias coverage" >&2
    return 0
  fi

  assert_parallel_existing_alias_is_excluded "$alias_repository"
}

test_parallel_macos_physical_path_alias_is_excluded() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "macOS physical path alias coverage is not available; skipping" >&2
    return 0
  fi

  new_case parallel-macos-physical-alias
  create_existing_repository
  alias_repository=$("$REAL_PYTHON3" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$CASE_REPOSITORY") || return 1
  if [ "$alias_repository" = "$CASE_REPOSITORY" ]; then
    echo "test path has no distinct macOS physical alias; skipping" >&2
    return 0
  fi

  assert_parallel_existing_alias_is_excluded "$alias_repository"
}

test_sigkill_releases_repository_lock() {
  new_case sigkill-publication
  RUN_BLOCK_CLONE=1
  RUN_GIT_TIMEOUT=10
  run_setup kill "$CASE_ROOT/output.killed" "$CASE_ROOT/status.killed"

  if [ "$RUN_STATUS" != "-9" ]; then
    echo "expected SIGKILL status -9, got $RUN_STATUS" >&2
    sed -n '1,120p' "$CASE_ROOT/output.killed" >&2
    return 1
  fi
  [ -e "$FAKE_GIT_CLONE_MARKER" ] || return 1
  [ -e "$PRE_REAP_MARKER" ] || return 1
  assert_no_artifacts_eventually "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
  assert_no_artifacts_eventually "$CASE_WORK" '.agent-skills.clone.*' || return 1

  RUN_BLOCK_CLONE=0
  run_setup wait "$CASE_ROOT/output.retry" "$CASE_ROOT/status.retry"

  assert_status 0 || return 1
  assert_not_contains "$CASE_ROOT/output.retry" "another Agent Skills setup is already updating" || return 1
  [ -x "$CASE_REPOSITORY/bin/agent-skills" ] || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
}

test_sigkill_before_lock_helper_start() {
  new_case sigkill-before-lock-helper
  CASE_REPOSITORY=$CASE_WORK/missing/agent-skills
  RUN_STOP_BEFORE_LOCK_HELPER=1
  run_setup kill-before-lock-helper "$CASE_ROOT/output.killed" "$CASE_ROOT/status.killed"

  if [ "$RUN_STATUS" != "-9" ]; then
    echo "expected SIGKILL status -9, got $RUN_STATUS" >&2
    sed -n '1,120p' "$CASE_ROOT/output.killed" >&2
    return 1
  fi
  [ -e "$PRE_REAP_MARKER" ] || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
  [ ! -e "$CASE_WORK/missing" ] || return 1

  RUN_STOP_BEFORE_LOCK_HELPER=0
  run_setup wait "$CASE_ROOT/output.retry" "$CASE_ROOT/status.retry"

  assert_status 0 || return 1
  assert_not_contains "$CASE_ROOT/output.retry" "another Agent Skills setup is already updating" || return 1
  [ -x "$CASE_REPOSITORY/bin/agent-skills" ] || return 1
}

test_sigkill_before_publication_cleans_clone() {
  new_case sigkill-before-publication
  RUN_PUBLISH_MARKER=$FAKE_PUBLISH_MARKER
  RUN_PUBLISH_GATE=$FAKE_PUBLISH_GATE
  run_setup kill-publish "$CASE_ROOT/output.killed" "$CASE_ROOT/status.killed"

  if [ "$RUN_STATUS" != "-9" ]; then
    echo "expected SIGKILL status -9, got $RUN_STATUS" >&2
    sed -n '1,120p' "$CASE_ROOT/output.killed" >&2
    return 1
  fi
  [ -e "$FAKE_PUBLISH_MARKER" ] || return 1
  [ -e "$PRE_REAP_MARKER" ] || return 1
  assert_no_artifacts_eventually "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
  assert_no_artifacts_eventually "$CASE_WORK" '.agent-skills.clone.*' || return 1
  [ ! -e "$CASE_REPOSITORY" ] || return 1
}

test_destination_race_does_not_replace() {
  new_case destination-race
  RUN_PUBLISH_MARKER=$FAKE_PUBLISH_MARKER
  RUN_PUBLISH_GATE=$FAKE_PUBLISH_GATE
  run_setup destination-race

  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "validated repository could not be moved into place" || return 1
  [ -d "$CASE_REPOSITORY" ] || return 1
  [ ! -e "$CASE_REPOSITORY/.git" ] || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
}

test_parent_sigkill_cleans_up_git_process_groups_before_reap() {
  new_case git-parent-sigkill-initial
  RUN_BLOCK_LS_REMOTE=1
  RUN_GIT_TIMEOUT=10
  run_setup kill-git-parent

  if [ "$RUN_STATUS" != "-9" ]; then
    echo "expected SIGKILL status -9, got $RUN_STATUS" >&2
    sed -n '1,120p' "$CASE_OUTPUT" >&2
    return 1
  fi
  [ -e "$PRE_REAP_MARKER" ] || return 1
  assert_process_gone_now "$FAKE_GIT_CHILD_PID_FILE" || return 1
  assert_no_artifacts_eventually "$CASE_TMP" 'agent-skills-supervisor.*' || return 1

  new_case git-parent-sigkill-command-substitution
  create_existing_repository
  dash_shell=$(command -v dash 2>/dev/null || true)
  if [ -n "$dash_shell" ]; then
    RUN_SETUP_SHELL=$dash_shell
  fi
  RUN_BLOCK_LS_REMOTE=1
  RUN_GIT_TIMEOUT=10
  run_setup kill-git-parent

  if [ "$RUN_STATUS" != "-9" ]; then
    echo "expected SIGKILL status -9, got $RUN_STATUS" >&2
    sed -n '1,120p' "$CASE_OUTPUT" >&2
    return 1
  fi
  [ -e "$PRE_REAP_MARKER" ] || return 1
  assert_process_gone_now "$FAKE_GIT_CHILD_PID_FILE" || return 1
  assert_no_artifacts_eventually "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_parent_sigkill_cleans_pre_registration_cage_before_reap() {
  new_case operation-registration-race
  create_existing_repository
  RUN_BLOCK_LS_REMOTE=1
  RUN_GIT_TIMEOUT=10
  RUN_OPERATION_RUNNER_MARKER=$FAKE_OPERATION_RUNNER_MARKER
  RUN_OPERATION_RUNNER_COMMAND=--upload-pack=git-upload-pack
  run_setup kill-operation-registration-race

  if [ "$RUN_STATUS" != "-9" ]; then
    echo "expected SIGKILL status -9, got $RUN_STATUS" >&2
    sed -n '1,120p' "$CASE_OUTPUT" >&2
    return 1
  fi
  [ -e "$PRE_REAP_MARKER" ] || return 1
  assert_process_gone_now "$FAKE_OPERATION_RUNNER_MARKER" || return 1
  assert_process_gone_now "$FAKE_GIT_CHILD_PID_FILE" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_parent_sigkill_cleans_up_management_cli_before_reap() {
  new_case cli-parent-sigkill-validate
  RUN_BLOCK_CLI_COMMAND=validate
  run_setup kill-cli-parent

  [ "$RUN_STATUS" = "-9" ] || return 1
  [ -e "$PRE_REAP_MARKER" ] || return 1
  assert_process_gone_now "$FAKE_CLI_CHILD_PID_FILE" || return 1
  [ ! -e "$FAKE_CLI_AFTER_GATE" ] || return 1
  [ ! -e "$CASE_REPOSITORY" ] || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1

  new_case cli-parent-sigkill-sync
  RUN_BLOCK_CLI_COMMAND=sync
  run_setup kill-cli-parent

  [ "$RUN_STATUS" = "-9" ] || return 1
  [ -e "$PRE_REAP_MARKER" ] || return 1
  assert_process_gone_now "$FAKE_CLI_CHILD_PID_FILE" || return 1
  [ ! -e "$FAKE_CLI_AFTER_GATE" ] || return 1
  [ -d "$CASE_REPOSITORY/.git" ] || return 1
  [ -x "$CASE_REPOSITORY/bin/agent-skills" ] || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_sigkill_after_parent_creation_removes_all_parents() {
  new_case sigkill-after-parent-creation
  CASE_REPOSITORY=$CASE_WORK/missing/level/agent-skills
  RUN_PARENT_MARKER=$FAKE_PARENT_MARKER
  RUN_PARENT_GATE=$FAKE_PARENT_GATE
  run_setup kill-parent-created

  [ "$RUN_STATUS" = "-9" ] || return 1
  [ -e "$FAKE_PARENT_MARKER" ] || return 1
  [ -e "$PRE_REAP_MARKER" ] || return 1
  [ ! -e "$CASE_WORK/missing" ] || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_cleanup_error_does_not_skip_remaining_cleanup() {
  new_case cleanup-error
  CASE_REPOSITORY=$CASE_WORK/missing/level/agent-skills
  RUN_CLONE_STATUS=1
  RUN_LS_REMOTE_1_STATUS=0
  RUN_LS_REMOTE_2_STATUS=1
  RUN_CLEANUP_ERROR_MARKER=$FAKE_CLEANUP_ERROR_MARKER
  run_setup

  assert_status 1 || return 1
  [ -e "$FAKE_CLEANUP_ERROR_MARKER" ] || return 1
  assert_contains "$CASE_OUTPUT" "not accessible; skipping" || return 1
  assert_contains "$CASE_OUTPUT" "temporary clone could not be removed" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
  temporary_clone=$(find "$CASE_WORK" -name '.agent-skills.clone.*' -print -quit)
  [ -n "$temporary_clone" ] || return 1

  rm -rf "$temporary_clone"
  rmdir "$CASE_WORK/missing/level" "$CASE_WORK/missing" || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
}

test_parent_waits_for_supervisor_cleanup_handshake() {
  new_case slow-supervisor-cleanup
  RUN_CLI_VALIDATE_STATUS=1
  RUN_CLEANUP_MARKER=$FAKE_CLEANUP_MARKER
  RUN_CLEANUP_GATE=$FAKE_CLEANUP_GATE

  (
    run_setup wait "$CASE_ROOT/output.slow-cleanup" "$CASE_ROOT/status.slow-cleanup"
  ) &
  runner_pid=$!

  while [ ! -e "$FAKE_CLEANUP_MARKER" ] && kill -0 "$runner_pid" 2>/dev/null; do
    sleep 0.05
  done
  if [ ! -e "$FAKE_CLEANUP_MARKER" ]; then
    : >"$FAKE_CLEANUP_GATE"
    wait "$runner_pid" 2>/dev/null || true
    echo "supervisor did not reach temporary clone cleanup" >&2
    return 1
  fi

  sleep 5.5
  runner_still_waiting=0
  if kill -0 "$runner_pid" 2>/dev/null; then
    runner_still_waiting=1
  fi
  : >"$FAKE_CLEANUP_GATE"
  wait "$runner_pid" || return 1
  IFS= read -r setup_status <"$CASE_ROOT/status.slow-cleanup" || return 1

  [ "$runner_still_waiting" -eq 1 ] || return 1
  [ "$setup_status" = "1" ] || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_repeated_signal_does_not_interrupt_supervisor_cleanup() {
  new_case repeated-signal-during-cleanup
  RUN_BLOCK_CLI_COMMAND=validate
  RUN_CLEANUP_MARKER=$FAKE_CLEANUP_MARKER
  RUN_CLEANUP_GATE=$FAKE_CLEANUP_GATE
  run_setup signal-cleanup-twice

  assert_status 1 || return 1
  [ ! -e "$FAKE_CLI_AFTER_GATE" ] || return 1
  assert_no_artifacts "$CASE_WORK" '.agent-skills.clone.*' || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_dead_supervisor_without_cleanup_marker_is_reported() {
  new_case supervisor-missing-cleanup-marker
  cleanup_runner=$CASE_ROOT/cleanup-runner.sh
  cleanup_output=$CASE_ROOT/cleanup-output
  {
    printf '%s\n' '#!/bin/sh' 'set -u'
    sed -n '/^repository_supervisor_is_live() {/,/^}/p' "$SETUP_SCRIPT"
    sed -n '/^release_repository_supervisor() {/,/^}/p' "$SETUP_SCRIPT"
    cat <<EOF
SUPERVISOR_CLEANUP_COMPLETE=$CASE_ROOT/cleanup-complete
SUPERVISOR_CLEANUP_STARTED=$CASE_ROOT/cleanup-started
SUPERVISOR_CLEANUP_ACK=$CASE_ROOT/cleanup-ack
sleep 30 &
REPOSITORY_SUPERVISOR_PID=\$!
kill -KILL "\$REPOSITORY_SUPERVISOR_PID"
if release_repository_supervisor; then
    exit 1
fi
[ -z "\$REPOSITORY_SUPERVISOR_PID" ]
EOF
  } >"$cleanup_runner"
  chmod +x "$cleanup_runner"

  /bin/sh "$cleanup_runner" >"$cleanup_output" 2>&1 &
  cleanup_runner_pid=$!
  attempts=0
  while kill -0 "$cleanup_runner_pid" 2>/dev/null && [ "$attempts" -lt 800 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$cleanup_runner_pid" 2>/dev/null; then
    kill -KILL "$cleanup_runner_pid" 2>/dev/null || true
    wait "$cleanup_runner_pid" 2>/dev/null || true
    echo "dead supervisor was not detected while waiting for cleanup" >&2
    return 1
  fi
  if ! wait "$cleanup_runner_pid"; then
    sed -n '1,120p' "$cleanup_output" >&2
    return 1
  fi
  if ! grep -F 'exited without completing cleanup' "$cleanup_output" >/dev/null 2>&1; then
    sed -n '1,120p' "$cleanup_output" >&2
    return 1
  fi
}

test_signal_cancels_global_lock_wait() {
  new_case cancel-global-lock-wait
  lock_path=$(repository_lock_path) || return 1
  lock_root=${lock_path%/*}
  mkdir -p "$lock_root" || return 1
  chmod 700 "$lock_root" || return 1
  holder_ready=$CASE_ROOT/holder.ready
  holder_gate=$CASE_ROOT/holder.continue

  "$REAL_PYTHON3" - "$lock_root" "$holder_ready" "$holder_gate" <<'PY' &
import fcntl
import os
from pathlib import Path
import sys
import time

lock_root, ready_path, gate_path = sys.argv[1:]
fd = os.open(lock_root, os.O_RDONLY)
fcntl.flock(fd, fcntl.LOCK_EX)
Path(ready_path).touch()
while not Path(gate_path).exists():
    time.sleep(0.01)
os.close(fd)
PY
  holder_pid=$!

  attempts=0
  while [ ! -e "$holder_ready" ] && kill -0 "$holder_pid" 2>/dev/null &&
    [ "$attempts" -lt 200 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$holder_ready" ]; then
    : >"$holder_gate"
    wait "$holder_pid" 2>/dev/null || true
    return 1
  fi

  RUN_LOCK_WAIT_MARKER=$FAKE_PARENT_MARKER
  run_setup signal-lock
  setup_status=$RUN_STATUS
  holder_still_active=0
  if kill -0 "$holder_pid" 2>/dev/null; then
    holder_still_active=1
  fi
  : >"$holder_gate"
  wait "$holder_pid" || return 1

  [ "$setup_status" != "0" ] || return 1
  [ "$setup_status" != "124" ] || return 1
  [ "$holder_still_active" -eq 1 ] || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_signal_forces_cleanup_past_control_lock_wait() {
  new_case cancel-control-lock-wait
  create_existing_repository
  RUN_BLOCK_LS_REMOTE=1
  run_setup signal-control-lock

  assert_nonzero_status || return 1
  [ "$RUN_STATUS" != "124" ] || return 1
  [ "$RUN_STATUS" != "126" ] || return 1
  assert_process_gone "$FAKE_GIT_CHILD_PID_FILE" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_timeout_cleans_up_processes() {
  new_case git-timeout
  RUN_BLOCK_LS_REMOTE=1
  RUN_GIT_TIMEOUT=2
  run_setup

  assert_status 0 || return 1
  assert_contains "$CASE_OUTPUT" "not accessible; skipping" || return 1
  assert_process_gone "$FAKE_GIT_CHILD_PID_FILE" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_validation_timeout_removes_supervisor_owned_index() {
  new_case validation-index-timeout
  create_existing_repository
  RUN_BLOCK_CHECK_ATTR=1
  RUN_GIT_TIMEOUT=3
  run_setup

  assert_status 1 || return 1
  assert_contains "$CASE_OUTPUT" "repository file integrity inspection timed out" || return 1
  assert_process_gone "$FAKE_GIT_CHILD_PID_FILE" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

test_signal_cleans_up_processes() {
  new_case git-signal
  RUN_BLOCK_LS_REMOTE=1
  RUN_GIT_TIMEOUT=10
  run_setup signal

  assert_nonzero_status || return 1
  assert_process_gone "$FAKE_GIT_CHILD_PID_FILE" || return 1
  assert_no_artifacts "$CASE_TMP" 'agent-skills-supervisor.*' || return 1
}

create_real_git_case() {
  new_case "$1"
  REAL_SOURCE=$CASE_ROOT/source
  REAL_REMOTE=$CASE_ROOT/remote.git
  CASE_REPOSITORY=$CASE_ROOT/repository
  REAL_TEST_BIN=$CASE_ROOT/real-bin
  REAL_SSH_LOG=$CASE_ROOT/ssh.log
  REAL_GIT_ENV_LOG=$CASE_ROOT/git-environment.log
  REAL_CLI_LOG=$CASE_ROOT/real-cli.log
  REAL_HOOK_MARKER=$CASE_ROOT/hook.executed
  REAL_FSMONITOR_MARKER=$CASE_ROOT/fsmonitor.executed
  REAL_VCS_HELPER_MARKER=$CASE_ROOT/vcs-helper.executed
  REAL_SITECUSTOMIZE_MARKER=$CASE_ROOT/sitecustomize.executed
  REAL_SETUP_GIT_INDEX_FILE=
  REAL_SETUP_GIT_OBJECT_DIRECTORY=
  REAL_SETUP_GIT_ALTERNATE_OBJECT_DIRECTORIES=
  REAL_SETUP_GIT_ATTR_SOURCE=
  REAL_SETUP_PYTHONPATH=
  REAL_SETUP_CHECK_ONLY=0
  REAL_SETUP_FETCH_MARKER=
  REAL_SETUP_FETCH_GATE=
  REAL_SETUP_CONFIG_GUARD_MARKER=
  REAL_SETUP_CONFIG_GUARD_GATE=
  REAL_SETUP_CONFIG_RECHECK_MARKER=
  REAL_SETUP_CONFIG_RECHECK_GATE=
  mkdir -p "$REAL_SOURCE/bin" "$REAL_TEST_BIN"
  : >"$REAL_SSH_LOG"
  : >"$REAL_GIT_ENV_LOG"
  : >"$REAL_CLI_LOG"

  "$REAL_GIT" init -q -b main "$REAL_SOURCE" || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" config user.name test || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" config user.email test@example.invalid || return 1
  cat >"$REAL_SOURCE/bin/agent-skills" <<'PY'
#!/usr/bin/env python3

import os
from pathlib import Path
import subprocess
import sys

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent


if __name__ == "__main__":
    version = (REPOSITORY_ROOT / ".test-cli-version").read_text(encoding="utf-8").strip()
    with open(os.environ["REAL_CLI_LOG"], "a", encoding="utf-8") as log:
        no_replace_objects = os.environ.get("GIT_NO_REPLACE_OBJECTS", "")
        graft_file = os.environ.get("GIT_GRAFT_FILE", "")
        log.write(
            f"{version}:{' '.join(sys.argv[1:])} "
            f"[no-replace-objects={no_replace_objects}] "
            f"[graft-file={graft_file}]\n"
        )
    if not sys.argv[1:] or sys.argv[1] not in ("validate", "sync"):
        raise SystemExit(1)
    if sys.argv[1] == "sync":
        subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            cwd=REPOSITORY_ROOT,
            check=True,
        )
PY
  chmod +x "$REAL_SOURCE/bin/agent-skills"
  printf '%s\n' v1 >"$REAL_SOURCE/.test-cli-version"
  printf '%s\n' secrets/local >"$REAL_SOURCE/.gitignore"
  "$REAL_GIT" -C "$REAL_SOURCE" add bin/agent-skills .test-cli-version .gitignore || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" commit -q -m v1 || return 1
  REAL_OLD_OID=$("$REAL_GIT" -C "$REAL_SOURCE" rev-parse HEAD) || return 1
  "$REAL_GIT" clone -q --bare "$REAL_SOURCE" "$REAL_REMOTE" || return 1
  "$REAL_GIT" clone -q "$REAL_REMOTE" "$CASE_REPOSITORY" || return 1

  printf '%s\n' v2 >"$REAL_SOURCE/.test-cli-version"
  "$REAL_GIT" -C "$REAL_SOURCE" add .test-cli-version || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" commit -q -m v2 || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" push -q "$REAL_REMOTE" main || return 1
  REAL_REMOTE_OID=$("$REAL_GIT" --git-dir="$REAL_REMOTE" rev-parse refs/heads/main) || return 1

  "$REAL_GIT" -C "$CASE_REPOSITORY" remote set-url origin git@example.invalid:safe.git || return 1

  cat >"$REAL_TEST_BIN/git" <<'EOF'
#!/bin/sh
printf 'optional-locks=%s graft-file=%s lazy-fetch=%s index=%s object=%s alternates=%s args=%s\n' \
    "${GIT_OPTIONAL_LOCKS-}" "${GIT_GRAFT_FILE-}" \
    "${GIT_NO_LAZY_FETCH-}" \
    "${GIT_INDEX_FILE-}" "${GIT_OBJECT_DIRECTORY-}" \
    "${GIT_ALTERNATE_OBJECT_DIRECTORIES-}" "$*" >>"$REAL_GIT_ENV_LOG"
exec "$TEST_REAL_GIT" "$@"
EOF
  cat >"$REAL_TEST_BIN/python3" <<'EOF'
#!/bin/sh
exec "$TEST_REAL_PYTHON3" "$@"
EOF
  cat >"$REAL_TEST_BIN/ssh" <<'EOF'
#!/bin/sh
remote_command=
for argument in "$@"; do
    remote_command=$argument
done
printf '%s\n' "$remote_command" >>"$REAL_SSH_LOG"
case "$remote_command" in
    git-upload-pack*)
        unset GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
        exec "$TEST_REAL_GIT" upload-pack "$REAL_REMOTE"
        ;;
    *) exit 97 ;;
esac
EOF
  cat >"$REAL_TEST_BIN/git-remote-evil" <<'EOF'
#!/bin/sh
: >"$REAL_VCS_HELPER_MARKER"
exit 98
EOF
  chmod +x "$REAL_TEST_BIN/git" "$REAL_TEST_BIN/python3" "$REAL_TEST_BIN/ssh" \
    "$REAL_TEST_BIN/git-remote-evil"
}

configure_real_origin_configuration_include() {
  REAL_ORIGIN_CONFIGURATION_INCLUDE=$CASE_ROOT/origin-configuration.include
  : >"$REAL_ORIGIN_CONFIGURATION_INCLUDE"
  "$REAL_GIT" -C "$CASE_REPOSITORY" config --local include.path \
    "$REAL_ORIGIN_CONFIGURATION_INCLUDE" || return 1
}

run_real_setup() {
  set --
  real_setup_argument=
  if [ "$REAL_SETUP_CHECK_ONLY" -eq 1 ]; then
    real_setup_argument=--check
  fi
  if [ -n "$REAL_SETUP_GIT_INDEX_FILE" ]; then
    set -- "$@" "GIT_INDEX_FILE=$REAL_SETUP_GIT_INDEX_FILE"
  fi
  if [ -n "$REAL_SETUP_GIT_OBJECT_DIRECTORY" ]; then
    set -- "$@" "GIT_OBJECT_DIRECTORY=$REAL_SETUP_GIT_OBJECT_DIRECTORY"
  fi
  if [ -n "$REAL_SETUP_GIT_ALTERNATE_OBJECT_DIRECTORIES" ]; then
    set -- "$@" \
      "GIT_ALTERNATE_OBJECT_DIRECTORIES=$REAL_SETUP_GIT_ALTERNATE_OBJECT_DIRECTORIES"
  fi
  if [ -n "$REAL_SETUP_GIT_ATTR_SOURCE" ]; then
    set -- "$@" "GIT_ATTR_SOURCE=$REAL_SETUP_GIT_ATTR_SOURCE"
  fi
  if [ -n "$REAL_SETUP_PYTHONPATH" ]; then
    set -- "$@" "PYTHONPATH=$REAL_SETUP_PYTHONPATH"
  fi
  REAL_SETUP_STATUS=0
  if /usr/bin/env -i \
    "HOME=$CASE_HOME" \
    "XDG_STATE_HOME=$CASE_STATE_HOME" \
    "PATH=$REAL_TEST_BIN:/usr/bin:/bin" \
    "TMPDIR=$CASE_TMP" \
    "LC_ALL=C" \
    "GIT_CONFIG_NOSYSTEM=1" \
    "TEST_REAL_GIT=$REAL_GIT" \
    "TEST_REAL_PYTHON3=$REAL_PYTHON3" \
    "REAL_REMOTE=$REAL_REMOTE" \
    "REAL_SSH_LOG=$REAL_SSH_LOG" \
    "REAL_GIT_ENV_LOG=$REAL_GIT_ENV_LOG" \
    "REAL_CLI_LOG=$REAL_CLI_LOG" \
    "REAL_HOOK_MARKER=$REAL_HOOK_MARKER" \
    "REAL_FSMONITOR_MARKER=$REAL_FSMONITOR_MARKER" \
    "REAL_VCS_HELPER_MARKER=$REAL_VCS_HELPER_MARKER" \
    "REAL_SITECUSTOMIZE_MARKER=$REAL_SITECUSTOMIZE_MARKER" \
    "REAL_FILTER_MARKER=${REAL_FILTER_MARKER-}" \
    "AGENT_SKILLS_REPO_DIR=$CASE_REPOSITORY" \
    "AGENT_SKILLS_REPO_URL=git@example.invalid:safe.git" \
    "AGENT_SKILLS_GIT_TIMEOUT_SECONDS=10" \
    "AGENT_SKILLS_INTERNAL_TEST_FETCH_MARKER=$REAL_SETUP_FETCH_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_FETCH_GATE=$REAL_SETUP_FETCH_GATE" \
    "AGENT_SKILLS_INTERNAL_TEST_CONFIG_GUARD_MARKER=$REAL_SETUP_CONFIG_GUARD_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_CONFIG_GUARD_GATE=$REAL_SETUP_CONFIG_GUARD_GATE" \
    "AGENT_SKILLS_INTERNAL_TEST_CONFIG_RECHECK_MARKER=$REAL_SETUP_CONFIG_RECHECK_MARKER" \
    "AGENT_SKILLS_INTERNAL_TEST_CONFIG_RECHECK_GATE=$REAL_SETUP_CONFIG_RECHECK_GATE" \
    "$@" \
    /bin/sh "$SETUP_SCRIPT" ${real_setup_argument:+"$real_setup_argument"} \
    >"$CASE_OUTPUT" 2>&1; then
    REAL_SETUP_STATUS=0
  else
    REAL_SETUP_STATUS=$?
  fi
}

configure_real_git_execution_traps() {
  hooks_directory=$CASE_ROOT/hooks
  mkdir -p "$hooks_directory"
  cat >"$hooks_directory/post-checkout" <<'EOF'
#!/bin/sh
: >"$REAL_HOOK_MARKER"
exit 0
EOF
  cp "$hooks_directory/post-checkout" "$hooks_directory/post-merge"
  cat >"$CASE_ROOT/fsmonitor" <<'EOF'
#!/bin/sh
: >"$REAL_FSMONITOR_MARKER"
exit 1
EOF
  chmod +x "$hooks_directory/post-checkout" "$hooks_directory/post-merge" "$CASE_ROOT/fsmonitor"
  "$REAL_GIT" -C "$CASE_REPOSITORY" config core.hooksPath "$hooks_directory" || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" config core.fsmonitor "$CASE_ROOT/fsmonitor" || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" config submodule.recurse true || return 1
}

assert_real_git_fast_forward() {
  updated_head=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
  updated_tree=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -C "$CASE_REPOSITORY" rev-parse 'HEAD^{tree}') || return 1
  remote_tree=$("$REAL_GIT" --git-dir="$REAL_REMOTE" rev-parse 'refs/heads/main^{tree}') || return 1
  remote_tracking=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -C "$CASE_REPOSITORY" rev-parse refs/remotes/origin/main) || return 1
  worktree_status=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -C "$CASE_REPOSITORY" status --porcelain --untracked-files=all) || return 1

  [ "$updated_head" = "$REAL_REMOTE_OID" ] || return 1
  [ "$updated_tree" = "$remote_tree" ] || return 1
  [ "$remote_tracking" = "$REAL_OLD_OID" ] || return 1
  [ -z "$worktree_status" ] || return 1
  [ ! -e "$REAL_HOOK_MARKER" ] || return 1
  [ ! -e "$REAL_FSMONITOR_MARKER" ] || return 1
  assert_contains "$REAL_CLI_LOG" "v2:sync" || return 1
  assert_contains "$REAL_CLI_LOG" "no-replace-objects=1" || return 1
  assert_contains "$REAL_CLI_LOG" "graft-file=/dev/null" || return 1
  assert_contains "$REAL_SSH_LOG" "git-upload-pack" || return 1
}

snapshot_real_repository_storage() {
  snapshot_prefix=$1
  ls -id "$CASE_REPOSITORY/.git/index" >"$snapshot_prefix.index" || return 1
  cksum "$CASE_REPOSITORY/.git/index" >>"$snapshot_prefix.index" || return 1
  find "$CASE_REPOSITORY/.git/objects" -type f -exec cksum {} \; |
    LC_ALL=C sort >"$snapshot_prefix.objects" || return 1
  find "$CASE_REPOSITORY/.git" -name '*.lock' -type f -exec cksum {} \; |
    LC_ALL=C sort >"$snapshot_prefix.locks" || return 1
}

assert_real_repository_storage_unchanged() {
  before_prefix=$1
  after_prefix=$2
  cmp "$before_prefix.index" "$after_prefix.index" >/dev/null 2>&1 || return 1
  cmp "$before_prefix.objects" "$after_prefix.objects" >/dev/null 2>&1 || return 1
  cmp "$before_prefix.locks" "$after_prefix.locks" >/dev/null 2>&1 || return 1
}

test_real_git_origin_configuration_change_after_fetch_is_non_destructive() {
  create_real_git_case real-origin-configuration-change || return 1
  configure_real_origin_configuration_include || return 1
  REAL_SETUP_FETCH_MARKER=$CASE_ROOT/fetch.completed
  REAL_SETUP_FETCH_GATE=$CASE_ROOT/fetch.continue
  real_setup_status_file=$CASE_ROOT/real-setup.status
  initial_head=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
  initial_tree=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse 'HEAD^{tree}') || return 1
  initial_worktree_status=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false -C "$CASE_REPOSITORY" status --porcelain --untracked-files=all) || return 1

  (
    run_real_setup
    printf '%s\n' "$REAL_SETUP_STATUS" >"$real_setup_status_file"
  ) &
  real_setup_pid=$!
  if ! wait_for_test_path "$REAL_SETUP_FETCH_MARKER"; then
    : >"$REAL_SETUP_FETCH_GATE"
    wait "$real_setup_pid" || true
    return 1
  fi

  # cooperative lock 外の変更を fetch 後の再検証で拒否する
  if ! printf '%s\n' '[remote "origin"]' 'tagopt = --no-tags' \
    >>"$REAL_ORIGIN_CONFIGURATION_INCLUDE"; then
    : >"$REAL_SETUP_FETCH_GATE"
    wait "$real_setup_pid" || true
    return 1
  fi
  : >"$REAL_SETUP_FETCH_GATE"
  if ! wait "$real_setup_pid"; then
    return 1
  fi
  if ! IFS= read -r real_setup_status <"$real_setup_status_file" ||
    [ "$real_setup_status" -eq 0 ]; then
    return 1
  fi

  assert_contains "$CASE_OUTPUT" "origin configuration changed during the protected update window" || return 1
  current_head=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
  current_tree=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse 'HEAD^{tree}') || return 1
  current_worktree_status=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false -C "$CASE_REPOSITORY" status --porcelain --untracked-files=all) || return 1
  [ "$current_head" = "$initial_head" ] || return 1
  [ "$current_tree" = "$initial_tree" ] || return 1
  [ "$current_worktree_status" = "$initial_worktree_status" ] || return 1
  temporary_refs=$("$REAL_GIT" -C "$CASE_REPOSITORY" for-each-ref \
    --format='%(refname)' refs/agent-skills/setup) || return 1
  [ -z "$temporary_refs" ] || return 1
  [ ! -e "$CASE_REPOSITORY/.git/config.lock" ] || return 1
  [ ! -e "$CASE_REPOSITORY/.git/config.worktree.lock" ] || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
}

test_real_git_configuration_guard_blocks_post_recheck_writes() {
  create_real_git_case real-configuration-guard || return 1
  configure_real_origin_configuration_include || return 1
  case_alias_include=$CASE_ROOT/ORIGIN-CONFIGURATION.INCLUDE
  if [ -e "$case_alias_include" ]; then
    "$REAL_GIT" -C "$CASE_REPOSITORY" config --add include.path \
      "$case_alias_include" || return 1
  fi
  REAL_SETUP_CONFIG_GUARD_MARKER=$CASE_ROOT/config-guard.locked
  REAL_SETUP_CONFIG_GUARD_GATE=$CASE_ROOT/config-guard.continue
  REAL_SETUP_CONFIG_RECHECK_MARKER=$CASE_ROOT/config-recheck.complete
  REAL_SETUP_CONFIG_RECHECK_GATE=$CASE_ROOT/config-recheck.continue
  real_setup_status_file=$CASE_ROOT/real-setup.status

  (
    run_real_setup
    printf '%s\n' "$REAL_SETUP_STATUS" >"$real_setup_status_file"
  ) &
  real_setup_pid=$!
  if ! wait_for_test_path "$REAL_SETUP_CONFIG_GUARD_MARKER"; then
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  fi

  [ -e "$CASE_REPOSITORY/.git/config.lock" ] || {
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  }
  [ -e "${REAL_ORIGIN_CONFIGURATION_INCLUDE}.lock" ] || {
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  }
  if "$REAL_GIT" config --file "$REAL_ORIGIN_CONFIGURATION_INCLUDE" \
    remote.origin.tagopt --no-tags \
    >/dev/null 2>&1; then
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  fi

  : >"$REAL_SETUP_CONFIG_GUARD_GATE"
  if ! wait_for_test_path "$REAL_SETUP_CONFIG_RECHECK_MARKER"; then
    : >"$REAL_SETUP_CONFIG_RECHECK_GATE"
    wait "$real_setup_pid" || true
    return 1
  fi
  # 再検証後の global config は protected update に影響しない
  if ! HOME="$CASE_HOME" GIT_CONFIG_NOSYSTEM=1 "$REAL_GIT" config --global \
    remote.origin.tagopt --no-tags; then
    : >"$REAL_SETUP_CONFIG_RECHECK_GATE"
    wait "$real_setup_pid" || true
    return 1
  fi
  : >"$REAL_SETUP_CONFIG_RECHECK_GATE"
  if ! wait "$real_setup_pid"; then
    return 1
  fi
  if ! IFS= read -r real_setup_status <"$real_setup_status_file" ||
    [ "$real_setup_status" -ne 0 ]; then
    sed -n '1,120p' "$CASE_OUTPUT" >&2
    return 1
  fi
  [ ! -e "$CASE_REPOSITORY/.git/config.lock" ] || return 1
  [ ! -e "$CASE_REPOSITORY/.git/config.worktree.lock" ] || return 1
  [ ! -e "${REAL_ORIGIN_CONFIGURATION_INCLUDE}.lock" ] || return 1
  assert_real_git_fast_forward || return 1
}

test_real_git_configuration_guard_covers_linked_worktrees() {
  create_real_git_case real-linked-worktree-configuration-guard || return 1
  primary_repository=$CASE_REPOSITORY
  linked_repository=$CASE_ROOT/linked-worktree
  linked_include=$CASE_ROOT/linked-worktree.include

  "$REAL_GIT" -C "$primary_repository" checkout -q --detach || return 1
  "$REAL_GIT" -C "$primary_repository" config extensions.worktreeConfig true || return 1
  "$REAL_GIT" -C "$primary_repository" worktree add -q "$linked_repository" main || return 1
  CASE_REPOSITORY=$linked_repository
  : >"$linked_include"
  "$REAL_GIT" -C "$CASE_REPOSITORY" config --worktree include.path \
    "$linked_include" || return 1
  linked_git_directory=$("$REAL_GIT" -C "$CASE_REPOSITORY" \
    rev-parse --absolute-git-dir) || return 1

  REAL_SETUP_CONFIG_GUARD_MARKER=$CASE_ROOT/config-guard.locked
  REAL_SETUP_CONFIG_GUARD_GATE=$CASE_ROOT/config-guard.continue
  real_setup_status_file=$CASE_ROOT/real-setup.status
  (
    run_real_setup
    printf '%s\n' "$REAL_SETUP_STATUS" >"$real_setup_status_file"
  ) &
  real_setup_pid=$!
  if ! wait_for_test_path "$REAL_SETUP_CONFIG_GUARD_MARKER"; then
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  fi

  [ -e "$primary_repository/.git/config.lock" ] || {
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  }
  [ -e "$linked_git_directory/config.lock" ] || {
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  }
  [ -e "$linked_git_directory/config.worktree.lock" ] || {
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  }
  [ -e "${linked_include}.lock" ] || {
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  }
  if "$REAL_GIT" -C "$CASE_REPOSITORY" config --local \
    remote.origin.tagopt --no-tags >/dev/null 2>&1 ||
    "$REAL_GIT" -C "$CASE_REPOSITORY" config --worktree \
      remote.origin.tagopt --no-tags >/dev/null 2>&1 ||
    "$REAL_GIT" config --file "$linked_include" \
      remote.origin.tagopt --no-tags >/dev/null 2>&1; then
    : >"$REAL_SETUP_CONFIG_GUARD_GATE"
    wait "$real_setup_pid" || true
    return 1
  fi

  : >"$REAL_SETUP_CONFIG_GUARD_GATE"
  if ! wait "$real_setup_pid"; then
    return 1
  fi
  if ! IFS= read -r real_setup_status <"$real_setup_status_file" ||
    [ "$real_setup_status" -ne 0 ]; then
    sed -n '1,120p' "$CASE_OUTPUT" >&2
    return 1
  fi
  [ ! -e "$primary_repository/.git/config.lock" ] || return 1
  [ ! -e "$linked_git_directory/config.lock" ] || return 1
  [ ! -e "$linked_git_directory/config.worktree.lock" ] || return 1
  [ ! -e "${linked_include}.lock" ] || return 1
  assert_real_git_fast_forward || return 1
}

test_real_git_rechecks_repository_state_before_merge() {
  create_real_git_case real-state-recheck || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" branch race "$REAL_OLD_OID" || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" config branch.race.remote origin || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" config branch.race.merge refs/heads/main || return 1
  REAL_SETUP_CONFIG_RECHECK_MARKER=$CASE_ROOT/config-recheck.complete
  REAL_SETUP_CONFIG_RECHECK_GATE=$CASE_ROOT/config-recheck.continue
  real_setup_status_file=$CASE_ROOT/real-setup.status

  (
    run_real_setup
    printf '%s\n' "$REAL_SETUP_STATUS" >"$real_setup_status_file"
  ) &
  real_setup_pid=$!
  if ! wait_for_test_path "$REAL_SETUP_CONFIG_RECHECK_MARKER"; then
    : >"$REAL_SETUP_CONFIG_RECHECK_GATE"
    wait "$real_setup_pid" || true
    return 1
  fi

  "$REAL_GIT" -C "$CASE_REPOSITORY" checkout -q race || {
    : >"$REAL_SETUP_CONFIG_RECHECK_GATE"
    wait "$real_setup_pid" || true
    return 1
  }
  : >"$REAL_SETUP_CONFIG_RECHECK_GATE"
  if ! wait "$real_setup_pid"; then
    return 1
  fi
  if ! IFS= read -r real_setup_status <"$real_setup_status_file" ||
    [ "$real_setup_status" -eq 0 ]; then
    return 1
  fi

  assert_contains "$CASE_OUTPUT" "repository branch, upstream, HEAD, or worktree changed" || return 1
  current_branch=$("$REAL_GIT" -C "$CASE_REPOSITORY" symbolic-ref --quiet --short HEAD) || return 1
  current_head=$("$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
  main_head=$("$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse refs/heads/main) || return 1
  race_head=$("$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse refs/heads/race) || return 1
  temporary_refs=$("$REAL_GIT" -C "$CASE_REPOSITORY" for-each-ref \
    --format='%(refname)' refs/agent-skills/setup) || return 1
  [ "$current_branch" = race ] || return 1
  [ "$current_head" = "$REAL_OLD_OID" ] || return 1
  [ "$main_head" = "$REAL_OLD_OID" ] || return 1
  [ "$race_head" = "$REAL_OLD_OID" ] || return 1
  [ -z "$temporary_refs" ] || return 1
  [ ! -e "$CASE_REPOSITORY/.git/config.lock" ] || return 1
  [ ! -e "$CASE_REPOSITORY/.git/config.worktree.lock" ] || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
}

test_real_git_merge_configuration_is_ignored() {
  for merge_case in branch-merge-options-ours pull-twohead-ours \
    branch-merge-options-squash branch-name-with-equals; do
    create_real_git_case "real-$merge_case" || return 1
    configure_real_git_execution_traps || return 1
    case "$merge_case" in
    branch-merge-options-ours)
      "$REAL_GIT" -C "$CASE_REPOSITORY" config --local --replace-all \
        branch.main.mergeOptions '-s ours' || return 1
      ;;
    pull-twohead-ours)
      "$REAL_GIT" -C "$CASE_REPOSITORY" config --local --replace-all \
        pull.twohead ours || return 1
      ;;
    branch-merge-options-squash)
      "$REAL_GIT" -C "$CASE_REPOSITORY" config --local --replace-all \
        branch.main.mergeOptions --squash || return 1
      ;;
    branch-name-with-equals)
      "$REAL_GIT" -C "$CASE_REPOSITORY" branch -m 'release=prod' || return 1
      "$REAL_GIT" -C "$CASE_REPOSITORY" config --local --replace-all \
        'branch.release=prod.mergeOptions' --verify-signatures || return 1
      ;;
    esac

    run_real_setup
    if [ "$REAL_SETUP_STATUS" -ne 0 ]; then
      sed -n '1,120p' "$CASE_OUTPUT" >&2
      return 1
    fi
    assert_real_git_fast_forward || return 1
  done
}

test_real_git_ignored_file_collision_is_non_destructive() {
  create_real_git_case real-ignored-file-collision || return 1
  mkdir -p "$REAL_SOURCE/secrets" "$CASE_REPOSITORY/secrets" || return 1
  : >"$REAL_SOURCE/.gitignore"
  printf '%s\n' remote-data >"$REAL_SOURCE/secrets/local"
  "$REAL_GIT" -C "$REAL_SOURCE" add .gitignore || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" add -f secrets/local || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" commit -q -m tracked-secret-path || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" push -q "$REAL_REMOTE" main || return 1
  printf '%s\n' local-data >"$CASE_REPOSITORY/secrets/local"

  run_real_setup

  [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
  assert_contains "$CASE_OUTPUT" "worktree files do not exactly match" || return 1
  assert_contains "$CASE_REPOSITORY/secrets/local" "local-data" || return 1
  current_head=$("$REAL_GIT" -c core.fsmonitor=false -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
  [ "$current_head" = "$REAL_OLD_OID" ] || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
}

test_real_git_uploadpack_override_is_rejected() {
  create_real_git_case real-uploadpack-override || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" config remote.origin.uploadpack malicious-upload-pack || return 1

  run_real_setup

  [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
  assert_contains "$CASE_OUTPUT" "remote.origin.uploadpack must not override" || return 1
  assert_empty "$REAL_SSH_LOG" || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
  current_head=$("$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
  [ "$current_head" = "$REAL_OLD_OID" ] || return 1
}

test_real_git_vcs_override_is_rejected_in_all_scopes() {
  for config_scope in local global; do
    create_real_git_case "real-vcs-override-$config_scope" || return 1
    case "$config_scope" in
    local)
      "$REAL_GIT" -C "$CASE_REPOSITORY" config remote.origin.vcs evil || return 1
      ;;
    global)
      "$REAL_GIT" config --file "$CASE_HOME/.gitconfig" remote.origin.vcs evil || return 1
      ;;
    esac

    run_real_setup

    [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
    assert_contains "$CASE_OUTPUT" "remote.origin.vcs must not override" || return 1
    [ ! -e "$REAL_VCS_HELPER_MARKER" ] || return 1
    assert_empty "$REAL_SSH_LOG" || return 1
    assert_empty "$REAL_CLI_LOG" || return 1
  done
}

test_real_git_unsafe_index_bits_are_rejected() {
  for index_mode in assume-unchanged skip-worktree; do
    create_real_git_case "real-$index_mode" || return 1
    "$REAL_GIT" -C "$CASE_REPOSITORY" update-index "--$index_mode" bin/agent-skills || return 1
    printf '%s\n' '#!/bin/sh' 'exit 97' >"$CASE_REPOSITORY/bin/agent-skills"
    chmod +x "$CASE_REPOSITORY/bin/agent-skills"

    run_real_setup

    [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
    assert_contains "$CASE_OUTPUT" "assume-unchanged or skip-worktree" || return 1
    assert_empty "$REAL_SSH_LOG" || return 1
    assert_empty "$REAL_CLI_LOG" || return 1
  done
}

test_real_git_active_fetched_filter_is_rejected_before_checkout() {
  create_real_git_case real-active-fetched-filter || return 1
  printf '%s\n' 'bin/agent-skills filter=malicious' >"$REAL_SOURCE/.gitattributes"
  "$REAL_GIT" -C "$REAL_SOURCE" add .gitattributes || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" commit -q -m filter-attribute || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" push -q "$REAL_REMOTE" main || return 1
  REAL_REMOTE_OID=$("$REAL_GIT" --git-dir="$REAL_REMOTE" rev-parse refs/heads/main) || return 1
  cat >"$CASE_ROOT/malicious-filter" <<'EOF'
#!/bin/sh
: >"$REAL_FILTER_MARKER"
cat
EOF
  chmod +x "$CASE_ROOT/malicious-filter"
  REAL_FILTER_MARKER=$CASE_ROOT/filter.executed
  "$REAL_GIT" -C "$CASE_REPOSITORY" config filter.malicious.smudge \
    "$CASE_ROOT/malicious-filter" || return 1

  run_real_setup

  [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
  assert_contains "$CASE_OUTPUT" "must not use an active Git content filter" || return 1
  [ ! -e "$REAL_FILTER_MARKER" ] || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
  current_head=$(GIT_NO_REPLACE_OBJECTS=1 "$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
  [ "$current_head" = "$REAL_OLD_OID" ] || return 1
}

test_real_git_reserved_filter_names_are_classified_by_attribute_state() {
  for filter_case in literal-unspecified literal-unset special-unspecified special-unset; do
    create_real_git_case "real-filter-$filter_case" || return 1
    case "$filter_case" in
    literal-unspecified)
      filter_driver=unspecified
      filter_attribute='filter=unspecified'
      expected_status=rejected
      ;;
    literal-unset)
      filter_driver=unset
      filter_attribute='filter=unset'
      expected_status=rejected
      ;;
    special-unspecified)
      filter_driver=unspecified
      filter_attribute='!filter'
      expected_status=accepted
      ;;
    special-unset)
      filter_driver=unset
      filter_attribute='-filter'
      expected_status=accepted
      ;;
    esac
    printf 'bin/agent-skills %s\n' "$filter_attribute" >"$REAL_SOURCE/.gitattributes"
    "$REAL_GIT" -C "$REAL_SOURCE" add .gitattributes || return 1
    "$REAL_GIT" -C "$REAL_SOURCE" commit -q -m "$filter_case" || return 1
    "$REAL_GIT" -C "$REAL_SOURCE" push -q "$REAL_REMOTE" main || return 1
    REAL_REMOTE_OID=$("$REAL_GIT" --git-dir="$REAL_REMOTE" rev-parse refs/heads/main) || return 1
    REAL_FILTER_MARKER=$CASE_ROOT/filter.executed
    cat >"$CASE_ROOT/reserved-filter" <<'EOF'
#!/bin/sh
: >"$REAL_FILTER_MARKER"
cat
EOF
    chmod +x "$CASE_ROOT/reserved-filter"
    "$REAL_GIT" -C "$CASE_REPOSITORY" config "filter.$filter_driver.smudge" \
      "$CASE_ROOT/reserved-filter" || return 1

    run_real_setup

    [ ! -e "$REAL_FILTER_MARKER" ] || return 1
    case "$expected_status" in
    rejected)
      [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
      assert_contains "$CASE_OUTPUT" "must not use an active Git content filter" || return 1
      assert_empty "$REAL_CLI_LOG" || return 1
      current_head=$(GIT_GRAFT_FILE=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
        "$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
      [ "$current_head" = "$REAL_OLD_OID" ] || return 1
      ;;
    accepted)
      if [ "$REAL_SETUP_STATUS" -ne 0 ]; then
        sed -n '1,120p' "$CASE_OUTPUT" >&2
        return 1
      fi
      assert_real_git_fast_forward || return 1
      ;;
    esac
  done
}

test_real_git_reserved_filter_probe_uses_only_fetched_attributes() {
  for attribute_source in working-tree inherited-environment; do
    create_real_git_case "real-filter-source-$attribute_source" || return 1
    printf '%s\n' 'bin/agent-skills -filter' >"$REAL_SOURCE/.gitattributes"
    "$REAL_GIT" -C "$REAL_SOURCE" add .gitattributes || return 1
    "$REAL_GIT" -C "$REAL_SOURCE" commit -q -m old-special-filter || return 1
    "$REAL_GIT" -C "$REAL_SOURCE" push -q "$REAL_REMOTE" main || return 1
    "$REAL_GIT" -C "$CASE_REPOSITORY" fetch -q "$REAL_REMOTE" main || return 1
    "$REAL_GIT" -C "$CASE_REPOSITORY" reset -q --hard FETCH_HEAD || return 1
    REAL_OLD_OID=$("$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1

    printf '%s\n' 'bin/agent-skills filter=unset' >"$REAL_SOURCE/.gitattributes"
    "$REAL_GIT" -C "$REAL_SOURCE" add .gitattributes || return 1
    "$REAL_GIT" -C "$REAL_SOURCE" commit -q -m fetched-literal-filter || return 1
    "$REAL_GIT" -C "$REAL_SOURCE" push -q "$REAL_REMOTE" main || return 1
    REAL_REMOTE_OID=$("$REAL_GIT" --git-dir="$REAL_REMOTE" \
      rev-parse refs/heads/main) || return 1
    REAL_FILTER_MARKER=$CASE_ROOT/filter.executed
    cat >"$CASE_ROOT/reserved-filter" <<'EOF'
#!/bin/sh
: >"$REAL_FILTER_MARKER"
cat
EOF
    chmod +x "$CASE_ROOT/reserved-filter"
    "$REAL_GIT" -C "$CASE_REPOSITORY" config filter.unset.smudge \
      "$CASE_ROOT/reserved-filter" || return 1
    if [ "$attribute_source" = inherited-environment ]; then
      REAL_SETUP_GIT_ATTR_SOURCE=HEAD
    fi

    run_real_setup

    [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
    assert_contains "$CASE_OUTPUT" "must not use an active Git content filter" || return 1
    [ ! -e "$REAL_FILTER_MARKER" ] || return 1
    assert_empty "$REAL_CLI_LOG" || return 1
    current_head=$(GIT_GRAFT_FILE=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
      "$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
    [ "$current_head" = "$REAL_OLD_OID" ] || return 1
  done
}

test_real_git_partial_clone_configuration_is_rejected_before_object_access() {
  create_real_git_case real-partial-clone-no-lazy-fetch || return 1
  printf '%s\n' unique-promisor-object >"$CASE_REPOSITORY/promisor-object" || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" add promisor-object || return 1
  "$REAL_GIT" -c user.name=test -c user.email=test@example.invalid \
    -c core.hooksPath=/dev/null -c gc.auto=0 -C "$CASE_REPOSITORY" \
    commit -q -m local-promisor-object || return 1
  missing_object=$("$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD:promisor-object) || return 1
  object_directory=${missing_object%${missing_object#??}}
  object_name=${missing_object#??}
  missing_object_path=$CASE_REPOSITORY/.git/objects/$object_directory/$object_name
  [ -f "$missing_object_path" ] || return 1

  "$REAL_GIT" -C "$CASE_REPOSITORY" config core.repositoryFormatVersion 1 || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" config extensions.partialClone evil || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" remote add evil evil::missing || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" config remote.evil.promisor true || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" config remote.evil.partialCloneFilter blob:none || return 1
  rm "$missing_object_path" || return 1

  run_real_setup

  [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
  assert_contains "$CASE_OUTPUT" "partial-clone and promisor remote configuration" || return 1
  [ ! -e "$REAL_VCS_HELPER_MARKER" ] || return 1
  assert_not_contains "$REAL_GIT_ENV_LOG" " cat-file --batch" || return 1
  assert_contains "$REAL_GIT_ENV_LOG" "lazy-fetch=1" || return 1
  assert_empty "$REAL_SSH_LOG" || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
}

test_real_git_partial_clone_keys_are_rejected_in_all_scopes() {
  for partial_clone_key in extensions.partialClone remote.backup.promisor \
    remote.backup.partialCloneFilter; do
    for config_scope in local global; do
      create_real_git_case "real-partial-${partial_clone_key##*.}-$config_scope" || return 1
      case "$config_scope" in
      local)
        "$REAL_GIT" -C "$CASE_REPOSITORY" config "$partial_clone_key" true || return 1
        ;;
      global)
        "$REAL_GIT" config --file "$CASE_HOME/.gitconfig" \
          "$partial_clone_key" false || return 1
        ;;
      esac

      run_real_setup

      [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
      assert_contains "$CASE_OUTPUT" "partial-clone and promisor remote configuration" || return 1
      assert_not_contains "$REAL_GIT_ENV_LOG" " ls-tree -r" || return 1
      [ ! -e "$REAL_VCS_HELPER_MARKER" ] || return 1
      assert_empty "$REAL_SSH_LOG" || return 1
      assert_empty "$REAL_CLI_LOG" || return 1
    done
  done
}

test_real_git_check_only_preserves_index_objects_and_locks() {
  for check_case in matching-index mismatched-index; do
    create_real_git_case "real-check-read-only-$check_case" || return 1
    REAL_SETUP_CHECK_ONLY=1
    case "$check_case" in
    matching-index)
      tracked_object=$("$REAL_GIT" -C "$CASE_REPOSITORY" \
        rev-parse HEAD:.test-cli-version) || return 1
      "$REAL_GIT" -C "$CASE_REPOSITORY" update-index --cacheinfo \
        100644 "$tracked_object" .test-cli-version || return 1
      ;;
    mismatched-index)
      printf '%s\n' staged-only-version >"$CASE_REPOSITORY/.test-cli-version" || return 1
      "$REAL_GIT" -C "$CASE_REPOSITORY" add .test-cli-version || return 1
      "$REAL_GIT" -C "$CASE_REPOSITORY" restore --source=HEAD --worktree \
        .test-cli-version || return 1
      ;;
    esac
    printf '%s\n' preserved-lock >"$CASE_REPOSITORY/.git/read-only-sentinel.lock" || return 1
    before_snapshot=$CASE_ROOT/before
    after_snapshot=$CASE_ROOT/after
    snapshot_real_repository_storage "$before_snapshot" || return 1
    [ -s "$before_snapshot.locks" ] || return 1

    run_real_setup
    snapshot_real_repository_storage "$after_snapshot" || return 1

    assert_real_repository_storage_unchanged "$before_snapshot" "$after_snapshot" || return 1
    [ -s "$after_snapshot.locks" ] || return 1
    assert_not_contains "$REAL_GIT_ENV_LOG" " write-tree" || return 1
    case "$check_case" in
    matching-index)
      [ "$REAL_SETUP_STATUS" -eq 0 ] || return 1
      assert_contains "$CASE_OUTPUT" "repository integrity check passed" || return 1
      ;;
    mismatched-index)
      [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
      assert_contains "$CASE_OUTPUT" \
        "index and worktree files do not exactly match" || return 1
      ;;
    esac
    assert_empty "$REAL_SSH_LOG" || return 1
    assert_empty "$REAL_CLI_LOG" || return 1
  done
}

test_real_git_check_only_does_not_execute_fsmonitor() {
  create_real_git_case real-check-only || return 1
  configure_real_git_execution_traps || return 1
  REAL_SETUP_CHECK_ONLY=1

  run_real_setup

  if [ "$REAL_SETUP_STATUS" -ne 0 ]; then
    sed -n '1,120p' "$CASE_OUTPUT" >&2
    return 1
  fi
  assert_contains "$CASE_OUTPUT" "repository integrity check passed" || return 1
  [ ! -e "$REAL_FSMONITOR_MARKER" ] || return 1
  assert_contains "$REAL_GIT_ENV_LOG" \
    "optional-locks=0 graft-file=/dev/null" || return 1
  assert_contains "$REAL_GIT_ENV_LOG" \
    "args=-c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false -C . status" || return 1
  assert_empty "$REAL_SSH_LOG" || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
}

test_real_git_check_only_requires_executable_management_cli() {
  create_real_git_case real-check-executable-cli || return 1
  chmod -x "$REAL_SOURCE/bin/agent-skills" || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" update-index --chmod=-x bin/agent-skills || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" commit -q -m nonexecutable-cli || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" push -q "$REAL_REMOTE" main || return 1
  CASE_REPOSITORY=$CASE_ROOT/nonexecutable-repository
  "$REAL_GIT" clone -q "$REAL_REMOTE" "$CASE_REPOSITORY" || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" remote set-url origin git@example.invalid:safe.git || return 1
  [ ! -x "$CASE_REPOSITORY/bin/agent-skills" ] || return 1

  REAL_SETUP_CHECK_ONLY=1
  run_real_setup

  [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
  assert_contains "$CASE_OUTPUT" "the repository does not contain an executable management CLI." || return 1
  assert_empty "$REAL_SSH_LOG" || return 1
  assert_empty "$REAL_CLI_LOG" || return 1

  REAL_SETUP_CHECK_ONLY=0
  run_real_setup

  [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
  assert_contains "$CASE_OUTPUT" "the repository does not contain an executable management CLI." || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
}

test_real_git_worktree_files_must_match_the_verified_tree() {
  create_real_git_case real-worktree-file-mismatch || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" config core.fileMode false || return 1
  chmod -x "$CASE_REPOSITORY/bin/agent-skills" || return 1
  status_output=$("$REAL_GIT" -C "$CASE_REPOSITORY" status --porcelain) || return 1
  [ -z "$status_output" ] || return 1

  run_real_setup

  [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
  assert_contains "$CASE_OUTPUT" "worktree files do not exactly match" || return 1
  assert_empty "$REAL_SSH_LOG" || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
}

test_real_git_ignored_sitecustomize_is_rejected_without_execution() {
  create_real_git_case real-ignored-sitecustomize || return 1
  cat >"$CASE_REPOSITORY/sitecustomize.py" <<'PY'
import os
from pathlib import Path

Path(os.environ["REAL_SITECUSTOMIZE_MARKER"]).touch()
PY
  printf '%s\n' sitecustomize.py >>"$CASE_REPOSITORY/.git/info/exclude"
  status_output=$("$REAL_GIT" -C "$CASE_REPOSITORY" status --porcelain --untracked-files=all) || return 1
  [ -z "$status_output" ] || return 1

  run_real_setup

  [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
  assert_contains "$CASE_OUTPUT" "worktree files do not exactly match" || return 1
  [ ! -e "$REAL_SITECUSTOMIZE_MARKER" ] || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
}

test_real_git_management_cli_ignores_inherited_python_path() {
  create_real_git_case real-cli-python-isolation || return 1
  CASE_REPOSITORY=$CASE_ROOT/new-repository
  python_path=$CASE_ROOT/pythonpath
  mkdir "$python_path" || return 1
  cat >"$python_path/sitecustomize.py" <<'PY'
import os
from pathlib import Path

Path(os.environ["REAL_SITECUSTOMIZE_MARKER"]).touch()
PY
  REAL_SETUP_PYTHONPATH=$python_path

  run_real_setup

  if [ "$REAL_SETUP_STATUS" -ne 0 ]; then
    sed -n '1,120p' "$CASE_OUTPUT" >&2
    return 1
  fi
  [ ! -e "$REAL_SITECUSTOMIZE_MARKER" ] || return 1
  assert_line_count "$REAL_CLI_LOG" 1 "v2:validate" || return 1
  assert_line_count "$REAL_CLI_LOG" 1 "v2:sync" || return 1
}

test_real_git_replacement_refs_are_ignored() {
  create_real_git_case real-replacement-ref || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" fetch -q "$REAL_REMOTE" refs/heads/main || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" replace "$REAL_REMOTE_OID" "$REAL_OLD_OID" || return 1

  run_real_setup

  if [ "$REAL_SETUP_STATUS" -ne 0 ]; then
    sed -n '1,120p' "$CASE_OUTPUT" >&2
    return 1
  fi
  assert_real_git_fast_forward || return 1
  "$REAL_GIT" -C "$CASE_REPOSITORY" show-ref --verify --quiet \
    "refs/replace/$REAL_REMOTE_OID" || return 1
}

test_real_git_default_graft_file_cannot_bypass_fast_forward_check() {
  create_real_git_case real-default-graft || return 1
  remote_tree=$("$REAL_GIT" -C "$REAL_SOURCE" rev-parse 'HEAD^{tree}') || return 1
  unrelated_oid=$(printf '%s\n' unrelated |
    "$REAL_GIT" -C "$REAL_SOURCE" commit-tree "$remote_tree") || return 1
  "$REAL_GIT" -C "$REAL_SOURCE" push -q --force "$REAL_REMOTE" \
    "$unrelated_oid:refs/heads/main" || return 1
  REAL_REMOTE_OID=$unrelated_oid
  printf '%s %s\n' "$REAL_REMOTE_OID" "$REAL_OLD_OID" \
    >"$CASE_REPOSITORY/.git/info/grafts"

  run_real_setup

  [ "$REAL_SETUP_STATUS" -ne 0 ] || return 1
  assert_contains "$CASE_OUTPUT" "cannot fast-forward" || return 1
  assert_empty "$REAL_CLI_LOG" || return 1
  current_head=$(GIT_GRAFT_FILE=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    "$REAL_GIT" -C "$CASE_REPOSITORY" rev-parse HEAD) || return 1
  [ "$current_head" = "$REAL_OLD_OID" ] || return 1
  [ -s "$CASE_REPOSITORY/.git/info/grafts" ] || return 1
}

test_real_git_fetch_head_is_preserved_and_temporary_ref_is_removed() {
  create_real_git_case real-isolated-fetch-ref || return 1
  printf '%s\n' preserved-fetch-head >"$CASE_REPOSITORY/.git/FETCH_HEAD"

  run_real_setup

  if [ "$REAL_SETUP_STATUS" -ne 0 ]; then
    sed -n '1,120p' "$CASE_OUTPUT" >&2
    return 1
  fi
  assert_contains "$CASE_REPOSITORY/.git/FETCH_HEAD" preserved-fetch-head || return 1
  temporary_refs=$("$REAL_GIT" -C "$CASE_REPOSITORY" for-each-ref \
    --format='%(refname)' refs/agent-skills/setup) || return 1
  [ -z "$temporary_refs" ] || return 1
  assert_real_git_fast_forward || return 1
}

test_real_git_repository_environment_is_removed() {
  for repository_environment in index objects; do
    create_real_git_case "real-inherited-$repository_environment" || return 1
    case "$repository_environment" in
    index)
      alternate_index=$CASE_ROOT/alternate.index
      cp "$CASE_REPOSITORY/.git/index" "$alternate_index" || return 1
      REAL_SETUP_GIT_INDEX_FILE=$alternate_index
      inherited_environment_path=$alternate_index
      ;;
    objects)
      alternate_objects=$CASE_ROOT/alternate-objects
      mkdir "$alternate_objects" || return 1
      REAL_SETUP_GIT_OBJECT_DIRECTORY=$alternate_objects
      REAL_SETUP_GIT_ALTERNATE_OBJECT_DIRECTORIES=$CASE_REPOSITORY/.git/objects
      inherited_environment_path=$alternate_objects
      ;;
    esac

    run_real_setup

    if [ "$REAL_SETUP_STATUS" -ne 0 ]; then
      sed -n '1,120p' "$CASE_OUTPUT" >&2
      return 1
    fi
    assert_not_contains "$REAL_GIT_ENV_LOG" "$inherited_environment_path" || return 1
    assert_real_git_fast_forward || return 1
  done
}

run_test() {
  name=$1
  shift
  if [ -n "$TEST_FILTER" ] && [ "$name" != "$TEST_FILTER" ]; then
    return 0
  fi
  TEST_FILTER_MATCHED=1
  if "$@"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf 'ok - %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'not ok - %s\n' "$name"
  fi
}

run_test 'run_setup rejects invalid runner results' test_run_setup_rejects_invalid_runner_results
run_test 'new clone success' test_new_clone_success
run_test 'clone origin stability across reruns' test_clone_origin_is_stable_across_reruns
run_test 'dash without a TTY' test_dash_without_tty
run_test 'supported SSH URLs' test_supported_ssh_urls
run_test 'unsafe URLs are rejected' test_unsafe_urls_are_rejected
run_test 'skip and access exit codes' test_skip_and_access_exit_codes
run_test 'supervisor startup failure classification' test_supervisor_startup_failure_is_integrity_error
run_test 'relative TMPDIR supervisor state' test_relative_tmpdir_is_resolved_before_repository_entry
run_test 'trailing LF TMPDIR preservation' test_trailing_lf_tmpdir_is_preserved
run_test 'trailing LF repository path preservation' test_trailing_lf_repository_path_is_preserved
run_test 'existing repository guards' test_existing_repository_guards
run_test 'hardened read-only repository diagnostic' test_check_only_uses_the_hardened_read_only_diagnostic
run_test 'Git execution isolation and post-update validation' test_git_isolation_and_post_update_validation
run_test 'update snapshot recheck before fast-forward' test_update_snapshot_is_rechecked_before_fast_forward
run_test 'isolated temporary fetch ref' test_fetch_uses_an_isolated_temporary_ref
run_test 'parent SIGKILL removes temporary fetch ref' test_parent_sigkill_removes_temporary_fetch_ref
run_test 'process-group signal after fetch completes cleanup' test_process_group_signal_after_fetch_completes_cleanup
run_test 'effective URL rewrite constraints' test_effective_url_rewrites_are_constrained
run_test 'temporary clone invariants before CLI' test_temporary_clone_invariants_precede_cli_execution
run_test 'repository lock file validation' test_repository_lock_rejects_unsafe_existing_files
run_test 'repository lock garbage collection' test_repository_lock_gc_removes_unused_files
run_test 'existing state initialization' test_existing_uninitialized_state_installs_all
run_test 'public sync API without a second Git update' test_public_sync_api_avoids_a_second_git_update
run_test 'empty and foreign state initialization' test_empty_and_foreign_state_install_all
run_test 'existing copy-mode state' test_existing_copy_mode_state_is_preserved
run_test 'reclone matching profile' test_reclone_preserves_matching_profile
run_test 'clone failure classification' test_clone_failure_is_reclassified
run_test 'transfer timeout classification' test_transfer_timeouts_follow_strict_mode
run_test 'fetch failure integrity classification and retry' test_fetch_failure_is_integrity_error
run_test 'parallel clone exclusion' test_parallel_clone_is_excluded
run_test 'parallel initial parent exclusion across TMPDIRs' test_parallel_initial_parent_creation_is_excluded_across_tmpdirs
run_test 'parallel setup after publication exclusion' test_parallel_after_publication_is_excluded
run_test 'parallel existing repository exclusion' test_parallel_existing_repositories_are_excluded
run_test 'parallel symlink alias exclusion' test_parallel_symlink_alias_is_excluded
run_test 'parallel symlink dot-dot alias exclusion' test_parallel_symlink_dotdot_alias_is_excluded
run_test 'parallel missing destination parent symlink exclusion' test_parallel_missing_destination_parent_symlink_is_excluded
run_test 'destination symlink after lock rejection' test_destination_symlink_after_lock_is_rejected
run_test 'symlink retarget fixed physical destination' test_symlink_retarget_uses_fixed_physical_destination
run_test 'parallel macOS case alias exclusion' test_parallel_macos_case_alias_is_excluded
run_test 'parallel macOS physical path alias exclusion' test_parallel_macos_physical_path_alias_is_excluded
run_test 'SIGKILL releases repository lock' test_sigkill_releases_repository_lock
run_test 'SIGKILL before lock helper start' test_sigkill_before_lock_helper_start
run_test 'SIGKILL before publication cleanup' test_sigkill_before_publication_cleans_clone
run_test 'destination publication race' test_destination_race_does_not_replace
run_test 'parent SIGKILL cleans up Git process groups before reap' test_parent_sigkill_cleans_up_git_process_groups_before_reap
run_test 'parent SIGKILL cleans pre-registration operation cage before reap' test_parent_sigkill_cleans_pre_registration_cage_before_reap
run_test 'parent SIGKILL cleans up management CLI before reap' test_parent_sigkill_cleans_up_management_cli_before_reap
run_test 'SIGKILL after parent creation cleanup' test_sigkill_after_parent_creation_removes_all_parents
run_test 'cleanup error isolation' test_cleanup_error_does_not_skip_remaining_cleanup
run_test 'supervisor cleanup completion handshake' test_parent_waits_for_supervisor_cleanup_handshake
run_test 'repeated signal during supervisor cleanup' test_repeated_signal_does_not_interrupt_supervisor_cleanup
run_test 'dead supervisor cleanup marker failure' test_dead_supervisor_without_cleanup_marker_is_reported
run_test 'signal cancellation during global lock wait' test_signal_cancels_global_lock_wait
run_test 'signal cleanup during control lock wait' test_signal_forces_cleanup_past_control_lock_wait
run_test 'timeout cleanup' test_timeout_cleans_up_processes
run_test 'validation timeout index cleanup' test_validation_timeout_removes_supervisor_owned_index
run_test 'signal cleanup' test_signal_cleans_up_processes
run_test 'real Git rejects post-fetch origin configuration changes without merging' test_real_git_origin_configuration_change_after_fetch_is_non_destructive
run_test 'real Git configuration guard blocks post-recheck writes' test_real_git_configuration_guard_blocks_post_recheck_writes
run_test 'real Git configuration guard covers linked worktrees' test_real_git_configuration_guard_covers_linked_worktrees
run_test 'real Git rechecks repository state immediately before merge' test_real_git_rechecks_repository_state_before_merge
run_test 'real Git ignores inherited merge settings' test_real_git_merge_configuration_is_ignored
run_test 'real Git preserves colliding ignored files' test_real_git_ignored_file_collision_is_non_destructive
run_test 'real Git rejects upload-pack override' test_real_git_uploadpack_override_is_rejected
run_test 'real Git rejects vcs override in all scopes' test_real_git_vcs_override_is_rejected_in_all_scopes
run_test 'real Git rejects unsafe index bits' test_real_git_unsafe_index_bits_are_rejected
run_test 'real Git rejects active fetched filter' test_real_git_active_fetched_filter_is_rejected_before_checkout
run_test 'real Git classifies reserved filter names' test_real_git_reserved_filter_names_are_classified_by_attribute_state
run_test 'real Git isolates reserved filter probe attributes' test_real_git_reserved_filter_probe_uses_only_fetched_attributes
run_test 'real Git rejects partial clone before object access' test_real_git_partial_clone_configuration_is_rejected_before_object_access
run_test 'real Git rejects partial clone keys in all scopes' test_real_git_partial_clone_keys_are_rejected_in_all_scopes
run_test 'real Git check-only preserves repository storage' test_real_git_check_only_preserves_index_objects_and_locks
run_test 'real Git check-only disables fsmonitor' test_real_git_check_only_does_not_execute_fsmonitor
run_test 'real Git check-only requires an executable management CLI' test_real_git_check_only_requires_executable_management_cli
run_test 'real Git verifies worktree files' test_real_git_worktree_files_must_match_the_verified_tree
run_test 'real Git rejects ignored sitecustomize without execution' test_real_git_ignored_sitecustomize_is_rejected_without_execution
run_test 'real Git isolates management CLI Python startup' test_real_git_management_cli_ignores_inherited_python_path
run_test 'real Git ignores replacement refs' test_real_git_replacement_refs_are_ignored
run_test 'real Git disables default graft file' test_real_git_default_graft_file_cannot_bypass_fast_forward_check
run_test 'real Git isolates fetched ref' test_real_git_fetch_head_is_preserved_and_temporary_ref_is_removed
run_test 'real Git removes inherited repository environment' test_real_git_repository_environment_is_removed

if [ -n "$TEST_FILTER" ] && [ "$TEST_FILTER_MATCHED" -eq 0 ]; then
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'not ok - requested test was not found: %s\n' "$TEST_FILTER"
fi
printf '%s passed, %s failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
