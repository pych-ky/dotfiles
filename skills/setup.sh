#!/bin/sh

set -u

integrity_error() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

access_failure() {
  if [ "${AGENT_SKILLS_STRICT-}" = "1" ]; then
    printf '%s\n' 'Error: the private skills repository is not accessible (strict mode).' >&2
    exit 1
  fi

  printf '%s\n' 'Warning: the private skills repository is not accessible; skipping Agent Skills setup.' >&2
  exit 0
}

resolve_physical_directory() {
  if ! PHYSICAL_DIRECTORY_WITH_SENTINEL=$(
    CDPATH= cd -P "$1" 2>/dev/null &&
      printf '%s.' "$PWD"
  ); then
    return 1
  fi
  RESOLVED_PHYSICAL_DIRECTORY=${PHYSICAL_DIRECTORY_WITH_SENTINEL%.}
}

normalize_remote() {
  remote=$1
  case "$remote" in
  https://github.com/*)
    remote=github.com/${remote#*://github.com/}
    ;;
  git@github.com:*)
    remote=github.com/${remote#git@github.com:}
    ;;
  ssh://git@github.com/*)
    remote=github.com/${remote#ssh://git@github.com/}
    ;;
  *)
    printf '%s\n' "$remote"
    return
    ;;
  esac
  case "$remote" in
  */) remote=${remote%/} ;;
  esac
  case "$remote" in
  *.git) remote=${remote%.git} ;;
  esac
  printf '%s\n' "$remote"
}

validate_repository_url() {
  repository_url=$1

  case "$repository_url" in
  *\?* | *\#*)
    integrity_error "AGENT_SKILLS_REPO_URL must not contain a query string or fragment."
    ;;
  esac

  case "$repository_url" in
  https://*)
    https_location=${repository_url#https://}
    case "$https_location" in
    */*) ;;
    *) integrity_error "AGENT_SKILLS_REPO_URL must include an HTTPS repository path." ;;
    esac
    https_authority=${https_location%%/*}
    https_path=${https_location#*/}
    case "$https_authority" in
    '' | *@*)
      integrity_error "AGENT_SKILLS_REPO_URL must use HTTPS without userinfo."
      ;;
    esac
    if [ -z "$https_path" ]; then
      integrity_error "AGENT_SKILLS_REPO_URL must include an HTTPS repository path."
    fi
    ;;
  git@*:*)
    ssh_location=${repository_url#git@}
    ssh_host=${ssh_location%%:*}
    ssh_path=${ssh_location#*:}
    case "$ssh_host" in
    '' | *@* | */*)
      integrity_error "AGENT_SKILLS_REPO_URL must use git@host:path for SCP-style SSH."
      ;;
    esac
    case "$ssh_path" in
    '' | /*)
      integrity_error "AGENT_SKILLS_REPO_URL must use git@host:path for SCP-style SSH."
      ;;
    esac
    ;;
  ssh://git@*/*)
    ssh_location=${repository_url#ssh://git@}
    ssh_authority=${ssh_location%%/*}
    ssh_path=${ssh_location#*/}
    case "$ssh_authority" in
    '' | *@*)
      integrity_error "AGENT_SKILLS_REPO_URL must use ssh://git@host/path for SSH."
      ;;
    esac
    case "$ssh_path" in
    '' | /*)
      integrity_error "AGENT_SKILLS_REPO_URL must use ssh://git@host/path for SSH."
      ;;
    esac
    ;;
  *)
    integrity_error "AGENT_SKILLS_REPO_URL must use HTTPS or a supported SSH form."
    ;;
  esac
}

validate_repository_url_characters() {
  if ! (cd / && python3 -I -S -c '
import sys

value = sys.argv[1]
raise SystemExit(1 if any(ord(character) < 32 or ord(character) == 127 for character in value) else 0)
' "$1"); then
    integrity_error "AGENT_SKILLS_REPO_URL must not contain control characters."
  fi
}

if [ "${AGENT_SKILLS_SKIP-}" = "1" ]; then
  printf '%s\n' 'Agent Skills setup is disabled by AGENT_SKILLS_SKIP=1; skipping.'
  exit 0
fi

CHECK_ONLY=0
case "$#" in
0) ;;
1)
  if [ "$1" != "--check" ]; then
    integrity_error "the only supported argument is --check."
  fi
  CHECK_ONLY=1
  ;;
*) integrity_error "the only supported argument is --check." ;;
esac

DEFAULT_REPOSITORY_URL=https://github.com/pych-ky/agent-skills.git
REPOSITORY_URL=${AGENT_SKILLS_REPO_URL:-$DEFAULT_REPOSITORY_URL}

validate_repository_url "$REPOSITORY_URL"

if ! command -v git >/dev/null 2>&1; then
  integrity_error "git is required for Agent Skills setup."
fi
if ! command -v python3 >/dev/null 2>&1; then
  integrity_error "python3 is required for Agent Skills setup."
fi

validate_repository_url_characters "$REPOSITORY_URL"
EXPECTED_REMOTE=$(normalize_remote "$REPOSITORY_URL")
if [ -n "${GIT_CONFIG_COUNT-}" ] || [ -n "${GIT_CONFIG_PARAMETERS-}" ]; then
  integrity_error "environment-supplied Git command configuration is not permitted."
fi
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_ATTR_SOURCE GIT_COMMON_DIR GIT_DIR \
  GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE GIT_NAMESPACE \
  GIT_OBJECT_DIRECTORY GIT_PREFIX GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE \
  GIT_WORK_TREE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export GIT_GRAFT_FILE=/dev/null
export GIT_NO_LAZY_FETCH=1
export GIT_NO_REPLACE_OBJECTS=1

GIT_OPERATION_TIMEOUT=${AGENT_SKILLS_GIT_TIMEOUT_SECONDS-20}
case "$GIT_OPERATION_TIMEOUT" in
'' | *[!0-9]*) integrity_error "AGENT_SKILLS_GIT_TIMEOUT_SECONDS must be a positive integer." ;;
esac
if ! [ "$GIT_OPERATION_TIMEOUT" -gt 0 ] 2>/dev/null ||
  ! [ "$GIT_OPERATION_TIMEOUT" -le 86400 ] 2>/dev/null; then
  integrity_error "AGENT_SKILLS_GIT_TIMEOUT_SECONDS must be a positive integer no greater than 86400."
fi

RUN_GIT_GIT_FAILURE_STATUS=1
RUN_GIT_TIMEOUT_STATUS=124
RUN_GIT_INFRASTRUCTURE_STATUS=125
REPOSITORY_SUPERVISOR_STATE=

run_supervised() {
  operation_status_mode=$1
  operation_timeout=$2
  shift 2
  supervised_command_directory=$PWD
  (
    cd / || exit "$RUN_GIT_INFRASTRUCTURE_STATUS"
    python3 -I -S - "$REPOSITORY_SUPERVISOR_STATE" "$operation_status_mode" \
      "$operation_timeout" "$supervised_command_directory" "$@"
  ) <<'PY'
import contextlib
import fcntl
import os
import select
import secrets
import signal
import subprocess
import sys
import time

TIMEOUT_STATUS = 124
INFRASTRUCTURE_STATUS = 125
state_directory = sys.argv[1]
status_mode = sys.argv[2]
timeout_seconds = int(sys.argv[3])
command_directory = sys.argv[4]
command = sys.argv[5:]
control_path = os.path.join(state_directory, "control")
shutdown_path = os.path.join(state_directory, "shutdown")
operations_directory = os.path.join(state_directory, "operations")
control_fd = None
completion_read_fd = None
completion_write_fd = None
worker = None
registration_path = None

WORKER_SOURCE = r'''
import contextlib
import fcntl
import os
import signal
import subprocess
import sys

control_path = sys.argv[1]
registration_path = sys.argv[2]
expected_runner_pid = int(sys.argv[3])
completion_fd = int(sys.argv[4])
command_directory = sys.argv[5]


def keep_group_leader_alive(_signal_number, _frame):
    pass


for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signal_number, keep_group_leader_alive)

control_fd = None
try:
    control_fd = os.open(control_path, os.O_RDWR)
    fcntl.flock(control_fd, fcntl.LOCK_SH)
    if os.getppid() != expected_runner_pid:
        raise RuntimeError("operation runner identity changed")
    with open(registration_path, "r+", encoding="utf-8") as registration:
        if registration.read() != f"{expected_runner_pid}\n":
            raise RuntimeError("operation registration changed")
        registration.seek(0)
        registration.write(f"{expected_runner_pid} {os.getpid()}\n")
        registration.truncate()
    if os.path.exists(os.path.join(os.path.dirname(control_path), "shutdown")):
        command_status = 128 + signal.SIGTERM
    else:
        try:
            command_status = subprocess.call(sys.argv[6:], cwd=command_directory)
        except OSError:
            command_status = 127
except (OSError, RuntimeError):
    command_status = 125

message = f"done:{command_status}\n".encode()
try:
    while message:
        written = os.write(completion_fd, message)
        message = message[written:]
except OSError:
    pass
finally:
    with contextlib.suppress(OSError):
        os.close(completion_fd)

while True:
    signal.pause()
'''


class OperationInterrupted(Exception):
    def __init__(self, signal_number):
        super().__init__(signal_number)
        self.signal_number = signal_number


def interrupt(_signal_number, _frame):
    raise OperationInterrupted(_signal_number)


def signal_worker(signal_number):
    if worker is None:
        return
    with contextlib.suppress(ProcessLookupError):
        os.killpg(worker.pid, signal_number)


def lock_control(lock_type, deadline=None, interrupt_on_shutdown=False):
    while True:
        try:
            fcntl.flock(control_fd, lock_type | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if interrupt_on_shutdown and os.path.exists(shutdown_path):
                raise OperationInterrupted(signal.SIGTERM)
            if deadline is not None and time.monotonic() >= deadline:
                return False
            time.sleep(0.01)


def stop_worker(graceful):
    global registration_path, worker
    if worker is None:
        if registration_path is not None:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(registration_path)
            registration_path = None
        return

    current_worker = worker
    locked = False
    try:
        if control_fd is not None:
            locked = lock_control(fcntl.LOCK_SH, time.monotonic() + 0.2)

        if graceful:
            signal_worker(signal.SIGTERM)
            deadline = time.monotonic() + 0.2
            while time.monotonic() < deadline and current_worker.poll() is None:
                time.sleep(0.01)
        if current_worker.poll() is None:
            signal_worker(signal.SIGKILL)
        with contextlib.suppress(OSError):
            current_worker.wait()
        worker = None
        if registration_path is not None:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(registration_path)
            registration_path = None
    finally:
        if locked:
            fcntl.flock(control_fd, fcntl.LOCK_UN)


for handled_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(handled_signal, interrupt)

exit_status = INFRASTRUCTURE_STATUS
try:
    if status_mode not in ("normalized", "raw") or timeout_seconds < 0 or not command:
        raise ValueError("invalid supervised operation")

    control_fd = os.open(control_path, os.O_RDWR)
    completion_read_fd, completion_write_fd = os.pipe()
    lock_control(fcntl.LOCK_SH, interrupt_on_shutdown=True)
    try:
        if os.path.exists(shutdown_path):
            raise OperationInterrupted(signal.SIGTERM)
        registration_path = os.path.join(
            operations_directory,
            f"operation.{os.getpid()}.{secrets.token_hex(8)}",
        )
        with open(registration_path, "x", encoding="utf-8") as registration:
            registration.write(f"{os.getpid()}\n")
        worker = subprocess.Popen(
            [
                sys.executable,
                "-I",
                "-S",
                "-c",
                WORKER_SOURCE,
                control_path,
                registration_path,
                str(os.getpid()),
                str(completion_write_fd),
                command_directory,
                *command,
            ],
            pass_fds=(completion_write_fd,),
            start_new_session=True,
        )
        operation_runner_marker = os.environ.get(
            "AGENT_SKILLS_INTERNAL_TEST_OPERATION_RUNNER_MARKER"
        )
        operation_runner_command = os.environ.get(
            "AGENT_SKILLS_INTERNAL_TEST_OPERATION_RUNNER_COMMAND", ""
        )
        if operation_runner_marker and (
            not operation_runner_command or operation_runner_command in command
        ):
            with open(operation_runner_marker, "x", encoding="utf-8") as marker:
                marker.write(f"{os.getpid()}\n")
            os.kill(os.getpid(), signal.SIGSTOP)
    finally:
        fcntl.flock(control_fd, fcntl.LOCK_UN)

    os.close(completion_write_fd)
    completion_write_fd = None
    deadline = time.monotonic() + timeout_seconds if timeout_seconds else None
    completion = bytearray()
    while True:
        if deadline is None:
            wait_interval = 0.1
        else:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                stop_worker(graceful=True)
                exit_status = TIMEOUT_STATUS
                break
            wait_interval = min(0.1, remaining)

        readable, _, _ = select.select([completion_read_fd], [], [], wait_interval)
        if not readable:
            continue

        chunk = os.read(completion_read_fd, 64)
        if not chunk:
            stop_worker(graceful=False)
            exit_status = 128 + signal.SIGKILL
            break
        completion.extend(chunk)
        if b"\n" not in completion:
            continue

        line = bytes(completion).split(b"\n", 1)[0].decode("ascii")
        if not line.startswith("done:"):
            stop_worker(graceful=False)
            break
        try:
            reported_status = int(line[len("done:") :])
        except ValueError:
            stop_worker(graceful=False)
            break

        stop_worker(graceful=False)
        if reported_status == 0:
            exit_status = 0
        elif status_mode == "normalized":
            exit_status = 1
        elif reported_status < 0:
            exit_status = 128 - reported_status
        else:
            exit_status = reported_status
        break
except OperationInterrupted as exc:
    exit_status = 128 + exc.signal_number
except Exception:
    exit_status = INFRASTRUCTURE_STATUS
finally:
    for handled_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(handled_signal, signal.SIG_IGN)
    if worker is not None:
        stop_worker(graceful=False)
    if completion_write_fd is not None:
        with contextlib.suppress(OSError):
            os.close(completion_write_fd)
    if completion_read_fd is not None:
        with contextlib.suppress(OSError):
            os.close(completion_read_fd)
    if control_fd is not None:
        with contextlib.suppress(OSError):
            os.close(control_fd)

raise SystemExit(exit_status)
PY
}

run_git() {
  run_supervised normalized "$GIT_OPERATION_TIMEOUT" git \
    -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false \
    -c submodule.recurse=false \
    "$@"
}

run_management_cli() {
  run_supervised raw 0 env \
    GIT_GRAFT_FILE=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=core.hooksPath \
    GIT_CONFIG_VALUE_0=/dev/null \
    GIT_CONFIG_KEY_1=core.fsmonitor \
    GIT_CONFIG_VALUE_1=false \
    GIT_CONFIG_KEY_2=submodule.recurse \
    GIT_CONFIG_VALUE_2=false \
    python3 -I -S "$@"
}

validate_single_origin_url() {
  origin_repository_root=$1
  if run_supervised raw "$GIT_OPERATION_TIMEOUT" python3 -I -S -c '
import subprocess
import sys

try:
    git = [
        "git",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "submodule.recurse=false",
        "-C",
        sys.argv[1],
    ]
    result = subprocess.run(
        [*git, "config", "--null", "--get-all", "remote.origin.url"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
except OSError:
    raise SystemExit(4)

if result.returncode != 0:
    raise SystemExit(2)
if not result.stdout.endswith(b"\0"):
    raise SystemExit(3)
values = result.stdout[:-1].split(b"\0")
if (
    len(values) != 1
    or not values[0]
    or any(byte < 32 or byte == 127 for byte in values[0])
):
    raise SystemExit(3)

try:
    uploadpack = subprocess.run(
        [*git, "config", "--null", "--get-all", "remote.origin.uploadpack"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
except OSError:
    raise SystemExit(4)
if uploadpack.returncode == 0:
    raise SystemExit(5)
if uploadpack.returncode != 1:
    raise SystemExit(4)

try:
    vcs = subprocess.run(
        [*git, "config", "--null", "--get-all", "remote.origin.vcs"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
except OSError:
    raise SystemExit(4)
if vcs.returncode == 0:
    raise SystemExit(6)
if vcs.returncode != 1:
    raise SystemExit(4)

try:
    configured_keys = subprocess.run(
        [*git, "config", "--includes", "--null", "--name-only", "--list"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
except OSError:
    raise SystemExit(4)
if configured_keys.returncode != 0 or (
    configured_keys.stdout and not configured_keys.stdout.endswith(b"\0")
):
    raise SystemExit(4)
for configured_key in (
    configured_keys.stdout[:-1].split(b"\0") if configured_keys.stdout else ()
):
    normalized_key = configured_key.lower()
    if normalized_key == b"extensions.partialclone" or (
        normalized_key.startswith(b"remote.")
        and normalized_key.endswith((b".promisor", b".partialclonefilter"))
    ):
        raise SystemExit(7)
' "$origin_repository_root"; then
    return
  else
    origin_status=$?
  fi

  case "$origin_status" in
  2) integrity_error "the repository has no origin remote." ;;
  3) integrity_error "the repository must have exactly one non-empty origin fetch URL without control characters." ;;
  5) integrity_error "remote.origin.uploadpack must not override the verified repository upload-pack." ;;
  6) integrity_error "remote.origin.vcs must not override the verified repository transport." ;;
  7) integrity_error "partial-clone and promisor remote configuration is not permitted in the Agent Skills repository." ;;
  "$RUN_GIT_TIMEOUT_STATUS") integrity_error "the repository origin configuration inspection timed out." ;;
  "$RUN_GIT_INFRASTRUCTURE_STATUS") integrity_error "Git operation monitoring failed." ;;
  *) integrity_error "the repository origin configuration could not be inspected." ;;
  esac
}

capture_repository_origin_configuration_fingerprint() {
  fingerprint_repository_root=$1

  ORIGIN_CONFIGURATION_FINGERPRINT=
  if ORIGIN_CONFIGURATION_FINGERPRINT_OUTPUT=$(run_supervised raw "$GIT_OPERATION_TIMEOUT" \
    python3 -I -S -c '
import hashlib
import subprocess
import sys

repository_root = sys.argv[1]
git = [
    "git",
    "--no-replace-objects",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "submodule.recurse=false",
    "-C",
    repository_root,
]


def query(*arguments):
    try:
        return subprocess.run(
            [*git, *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        raise SystemExit(4)


digest = hashlib.sha256()
for key in (
    "remote.origin.url",
    "remote.origin.uploadpack",
    "remote.origin.vcs",
):
    result = query("config", "--null", "--get-all", key)
    if result.returncode not in (0, 1) or (
        result.returncode == 0 and not result.stdout.endswith(b"\0")
    ):
        raise SystemExit(2)
    digest.update(key.encode("utf-8"))
    digest.update(b"\0")
    digest.update(str(result.returncode).encode("ascii"))
    digest.update(b"\0")
    digest.update(result.stdout)

result = query("config", "--includes", "--null", "--list")
if result.returncode != 0 or (
    result.stdout and not result.stdout.endswith(b"\0")
):
    raise SystemExit(2)
# 実効 Git 設定の生値は診断に出さず fingerprint に含める。
digest.update(b"effective-config\0")
digest.update(result.stdout)
print(digest.hexdigest())
' "$fingerprint_repository_root"); then
    :
  else
    fingerprint_status=$?
    case "$fingerprint_status" in
    "$RUN_GIT_TIMEOUT_STATUS")
      integrity_error "the repository origin configuration fingerprint inspection timed out."
      ;;
    "$RUN_GIT_INFRASTRUCTURE_STATUS")
      integrity_error "Git operation monitoring failed."
      ;;
    *) integrity_error "the repository origin configuration fingerprint could not be inspected." ;;
    esac
  fi

  ORIGIN_CONFIGURATION_FINGERPRINT=$ORIGIN_CONFIGURATION_FINGERPRINT_OUTPUT
  if [ "${#ORIGIN_CONFIGURATION_FINGERPRINT}" -ne 64 ]; then
    integrity_error "the repository origin configuration fingerprint is malformed."
  fi
  case "$ORIGIN_CONFIGURATION_FINGERPRINT" in
  *[!0123456789abcdef]*)
    integrity_error "the repository origin configuration fingerprint is malformed."
    ;;
  esac
}

validate_repository_tree() {
  tree_repository_root=$1
  expected_tree=$2
  validation_mode=$3

  if run_supervised raw "$GIT_OPERATION_TIMEOUT" python3 -I -S -c '
import contextlib
import os
import secrets
import shutil
import stat
import subprocess
import sys

repository_root, expected_tree, validation_mode, state_directory = sys.argv[1:]
if validation_mode not in ("policy", "worktree"):
    raise SystemExit(5)

git = [
    "git",
    "--no-replace-objects",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "submodule.recurse=false",
    "-C",
    repository_root,
]
git_environment = os.environ.copy()
git_environment.pop("GIT_ATTR_SOURCE", None)
git_environment["GIT_GRAFT_FILE"] = "/dev/null"
git_environment["GIT_NO_REPLACE_OBJECTS"] = "1"
git_environment["GIT_OPTIONAL_LOCKS"] = "0"


def run_git(arguments, *, input_data=None, environment=None):
    try:
        return subprocess.run(
            [*git, *arguments],
            input=input_data,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=environment or git_environment,
            check=False,
        )
    except OSError:
        raise SystemExit(5)


tree_result = run_git(["rev-parse", "--verify", f"{expected_tree}^{{tree}}"])
if tree_result.returncode != 0:
    raise SystemExit(5)
resolved_tree = tree_result.stdout.strip()
if not resolved_tree or b"\n" in resolved_tree:
    raise SystemExit(5)

entries_result = run_git(["ls-tree", "-r", "-t", "-z", "--full-tree", resolved_tree])
if entries_result.returncode != 0 or not entries_result.stdout.endswith(b"\0"):
    raise SystemExit(5)

entries = []
attribute_paths = []
for record in entries_result.stdout[:-1].split(b"\0"):
    try:
        metadata, path = record.split(b"\t", 1)
        mode, object_type, object_id = metadata.split(b" ", 2)
    except ValueError:
        raise SystemExit(5)
    if (
        not path
        or path.startswith(b"/")
        or b"\0" in path
        or any(component in (b"", b".", b"..") for component in path.split(b"/"))
    ):
        raise SystemExit(5)
    entries.append((mode, object_type, object_id, path))
    if object_type == b"blob":
        attribute_paths.append(path)

temporary_index = os.path.join(
    state_directory,
    f"validation-index.{os.getpid()}.{secrets.token_hex(8)}",
)
temporary_worktree = os.path.join(
    state_directory,
    f"validation-worktree.{os.getpid()}.{secrets.token_hex(8)}",
)
temporary_environment = git_environment.copy()
temporary_environment["GIT_INDEX_FILE"] = temporary_index
try:
    os.mkdir(temporary_worktree, mode=0o700)
    temporary_environment["GIT_WORK_TREE"] = temporary_worktree
    read_tree = run_git(["read-tree", resolved_tree], environment=temporary_environment)
    if read_tree.returncode != 0:
        raise SystemExit(5)

    attributes = run_git(
        ["check-attr", "--cached", "-z", "--stdin", "filter"],
        input_data=b"\0".join(attribute_paths) + (b"\0" if attribute_paths else b""),
        environment=temporary_environment,
    )
    if attributes.returncode != 0 or not attributes.stdout.endswith(b"\0"):
        raise SystemExit(5)
    fields = attributes.stdout[:-1].split(b"\0")
    if len(fields) % 3 != 0:
        raise SystemExit(5)
    for index in range(0, len(fields), 3):
        _path, attribute, value = fields[index : index + 3]
        if attribute != b"filter":
            continue
        driver = os.fsdecode(value)
        configured_driver = False
        for command_name in ("clean", "smudge", "process"):
            configured = run_git(
                ["config", "--null", "--get-all", f"filter.{driver}.{command_name}"]
            )
            if configured.returncode == 0:
                configured_driver = True
            if configured.returncode != 1:
                if configured.returncode != 0:
                    raise SystemExit(5)
        if not configured_driver:
            continue
        if value in (b"unspecified", b"unset"):
            # check-attr の予約値と同名の filter driver は failure probe で判別する。
            probe_environment = temporary_environment.copy()
            probe_configuration = (
                (f"filter.{driver}.process", "/usr/bin/false"),
                (f"filter.{driver}.clean", "/usr/bin/false"),
                (f"filter.{driver}.smudge", "/usr/bin/false"),
                (f"filter.{driver}.required", "true"),
            )
            probe_environment["GIT_CONFIG_COUNT"] = str(len(probe_configuration))
            for configuration_index, (key, configured_value) in enumerate(
                probe_configuration
            ):
                probe_environment[f"GIT_CONFIG_KEY_{configuration_index}"] = key
                probe_environment[f"GIT_CONFIG_VALUE_{configuration_index}"] = (
                    configured_value
                )
            probe_directory = os.path.join(
                state_directory,
                f"filter-probe.{os.getpid()}.{secrets.token_hex(8)}",
            )
            try:
                os.mkdir(probe_directory, mode=0o700)
                probe = run_git(
                    [
                        "checkout-index",
                        f"--prefix={probe_directory}{os.sep}",
                        "--",
                        os.fsdecode(_path),
                    ],
                    environment=probe_environment,
                )
            except OSError:
                raise SystemExit(5)
            finally:
                with contextlib.suppress(OSError):
                    shutil.rmtree(probe_directory)
            if probe.returncode == 0:
                continue
        raise SystemExit(3)
finally:
    with contextlib.suppress(OSError):
        shutil.rmtree(temporary_worktree)
    with contextlib.suppress(OSError):
        os.unlink(temporary_index)
    with contextlib.suppress(OSError):
        os.unlink(f"{temporary_index}.lock")

if validation_mode == "policy":
    raise SystemExit(0)

expected_paths = {path for _mode, _object_type, _object_id, path in entries}


def verify_no_untracked_files(directory, relative_directory=b""):
    try:
        with os.scandir(directory) as iterator:
            directory_entries = list(iterator)
    except OSError:
        raise SystemExit(4)

    for directory_entry in directory_entries:
        name = directory_entry.name
        if not relative_directory and name == b".git":
            continue
        relative_path = (
            os.path.join(relative_directory, name) if relative_directory else name
        )
        if relative_path not in expected_paths:
            raise SystemExit(4)
        try:
            is_directory = directory_entry.is_dir(follow_symlinks=False)
        except OSError:
            raise SystemExit(4)
        if is_directory:
            verify_no_untracked_files(directory_entry.path, relative_path)


verify_no_untracked_files(os.fsencode(os.path.abspath(repository_root)))

index_entries = run_git(["ls-files", "-v", "-z"])
if index_entries.returncode != 0 or (
    index_entries.stdout and not index_entries.stdout.endswith(b"\0")
):
    raise SystemExit(5)
for record in index_entries.stdout[:-1].split(b"\0") if index_entries.stdout else ():
    tag = record[:1]
    if tag == b"S" or tag in b"abcdefghijklmnopqrstuvwxyz":
        raise SystemExit(2)

index_entries = run_git(["ls-files", "--stage", "-z"])
if index_entries.returncode != 0 or (
    index_entries.stdout and not index_entries.stdout.endswith(b"\0")
):
    raise SystemExit(5)
expected_index = {
    path: (mode, object_id)
    for mode, object_type, object_id, path in entries
    if object_type != b"tree"
}
actual_index = {}
for record in index_entries.stdout[:-1].split(b"\0") if index_entries.stdout else ():
    try:
        metadata, path = record.split(b"\t", 1)
        mode, object_id, stage = metadata.split(b" ", 2)
    except ValueError:
        raise SystemExit(5)
    if stage != b"0" or not path or path in actual_index:
        raise SystemExit(4)
    actual_index[path] = (mode, object_id)
if actual_index != expected_index:
    raise SystemExit(4)

repository_root_bytes = os.fsencode(os.path.abspath(repository_root))
cat_file = None
try:
    cat_file = subprocess.Popen(
        [*git, "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=git_environment,
    )
    if cat_file.stdin is None or cat_file.stdout is None:
        raise SystemExit(5)

    for mode, object_type, object_id, path in entries:
        filesystem_path = os.path.join(repository_root_bytes, path)
        try:
            path_status = os.lstat(filesystem_path)
        except OSError:
            raise SystemExit(4)

        if object_type == b"tree":
            if not stat.S_ISDIR(path_status.st_mode):
                raise SystemExit(4)
            continue
        if object_type == b"commit":
            continue
        if object_type != b"blob":
            raise SystemExit(4)

        cat_file.stdin.write(object_id + b"\n")
        cat_file.stdin.flush()
        header = cat_file.stdout.readline().split()
        if len(header) != 3 or header[0] != object_id or header[1] != b"blob":
            raise SystemExit(5)
        try:
            object_size = int(header[2])
        except ValueError:
            raise SystemExit(5)
        object_contents = cat_file.stdout.read(object_size)
        if len(object_contents) != object_size or cat_file.stdout.read(1) != b"\n":
            raise SystemExit(5)

        if mode == b"120000":
            if not stat.S_ISLNK(path_status.st_mode):
                raise SystemExit(4)
            try:
                worktree_contents = os.readlink(filesystem_path)
            except OSError:
                raise SystemExit(4)
        elif mode in (b"100644", b"100755"):
            if not stat.S_ISREG(path_status.st_mode):
                raise SystemExit(4)
            open_flags = os.O_RDONLY
            if hasattr(os, "O_NOFOLLOW"):
                open_flags |= os.O_NOFOLLOW
            try:
                descriptor = os.open(filesystem_path, open_flags)
                try:
                    opened_status = os.fstat(descriptor)
                    if (
                        not stat.S_ISREG(opened_status.st_mode)
                        or (opened_status.st_dev, opened_status.st_ino)
                        != (path_status.st_dev, path_status.st_ino)
                    ):
                        raise SystemExit(4)
                    chunks = []
                    while True:
                        chunk = os.read(descriptor, 1024 * 1024)
                        if not chunk:
                            break
                        chunks.append(chunk)
                    worktree_contents = b"".join(chunks)
                finally:
                    os.close(descriptor)
            except OSError:
                raise SystemExit(4)
            expected_executable = mode == b"100755"
            actual_executable = bool(path_status.st_mode & 0o111)
            if actual_executable != expected_executable:
                raise SystemExit(4)
        else:
            raise SystemExit(4)

        if worktree_contents != object_contents:
            raise SystemExit(4)
except OSError:
    raise SystemExit(5)
finally:
    if cat_file is not None:
        if cat_file.stdin is not None:
            with contextlib.suppress(OSError):
                cat_file.stdin.close()
        if cat_file.stdout is not None:
            with contextlib.suppress(OSError):
                cat_file.stdout.close()
        with contextlib.suppress(OSError):
            cat_file.kill()
        with contextlib.suppress(OSError):
            cat_file.wait()
' "$tree_repository_root" "$expected_tree" "$validation_mode" \
    "$REPOSITORY_SUPERVISOR_STATE"; then
    return
  else
    tree_validation_status=$?
  fi

  case "$tree_validation_status" in
  2) integrity_error "the repository index must not contain assume-unchanged or skip-worktree entries." ;;
  3) integrity_error "the repository must not use an active Git content filter." ;;
  4) integrity_error "the repository index and worktree files do not exactly match the verified tree." ;;
  "$RUN_GIT_TIMEOUT_STATUS") integrity_error "the repository file integrity inspection timed out." ;;
  "$RUN_GIT_INFRASTRUCTURE_STATUS") integrity_error "Git operation monitoring failed." ;;
  *) integrity_error "the repository file integrity could not be inspected." ;;
  esac
}

verify_effective_repository_url() {
  remote_argument=$1
  shift

  if EFFECTIVE_REMOTE_OUTPUT=$(
    run_git "$@" ls-remote --get-url "$remote_argument" 2>/dev/null
    resolve_status=$?
    printf x
    exit "$resolve_status"
  ); then
    :
  else
    resolve_status=$?
    case "$resolve_status" in
    "$RUN_GIT_INFRASTRUCTURE_STATUS") integrity_error "Git operation monitoring failed." ;;
    *) integrity_error "the effective Agent Skills repository URL could not be resolved." ;;
    esac
  fi

  EFFECTIVE_REMOTE_OUTPUT=${EFFECTIVE_REMOTE_OUTPUT%x}
  case "$EFFECTIVE_REMOTE_OUTPUT" in
  *'
') ;;
  *) integrity_error "the effective Agent Skills repository URL is malformed." ;;
  esac
  EFFECTIVE_REMOTE=${EFFECTIVE_REMOTE_OUTPUT%'
'}
  case "$EFFECTIVE_REMOTE" in
  '' | *'
') integrity_error "the effective Agent Skills repository URL is malformed." ;;
  esac

  if [ "$(normalize_remote "$EFFECTIVE_REMOTE")" != "$EXPECTED_REMOTE" ]; then
    integrity_error "the effective repository origin does not match the expected Agent Skills repository URL."
  fi
}

validate_repository_checkout() {
  CHECKOUT_ROOT=$1
  CHECKOUT_VALIDATION_MODE=${2-full}

  if ! resolve_physical_directory "$CHECKOUT_ROOT"; then
    integrity_error "the configured repository directory cannot be resolved."
  fi
  CHECKOUT_PHYSICAL_ROOT=$RESOLVED_PHYSICAL_DIRECTORY

  if GIT_ROOT_OUTPUT=$(
    run_git -C "$CHECKOUT_ROOT" rev-parse --show-toplevel 2>/dev/null
    git_root_status=$?
    printf .
    exit "$git_root_status"
  ); then
    :
  else
    integrity_error "the repository is not a valid Git working tree."
  fi
  GIT_ROOT_OUTPUT=${GIT_ROOT_OUTPUT%.}
  case "$GIT_ROOT_OUTPUT" in
  *'
') ;;
  *) integrity_error "the Git working tree root is malformed." ;;
  esac
  GIT_ROOT=${GIT_ROOT_OUTPUT%'
'}
  if ! resolve_physical_directory "$GIT_ROOT"; then
    integrity_error "the Git working tree root cannot be resolved."
  fi
  GIT_ROOT=$RESOLVED_PHYSICAL_DIRECTORY
  if [ "$GIT_ROOT" != "$CHECKOUT_PHYSICAL_ROOT" ]; then
    integrity_error "the configured path is not the root of the expected repository."
  fi

  validate_single_origin_url "$CHECKOUT_ROOT"
  verify_effective_repository_url origin -C "$CHECKOUT_ROOT"

  if ! CURRENT_BRANCH=$(run_git -C "$CHECKOUT_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    integrity_error "the repository must be on a branch before it can be updated."
  fi
  if ! UPSTREAM_REMOTE=$(run_git -C "$CHECKOUT_ROOT" config --get "branch.$CURRENT_BRANCH.remote" 2>/dev/null) ||
    [ "$UPSTREAM_REMOTE" != "origin" ]; then
    integrity_error "the current branch must track the verified origin remote."
  fi
  if ! UPSTREAM_REF=$(run_git -C "$CHECKOUT_ROOT" config --get "branch.$CURRENT_BRANCH.merge" 2>/dev/null); then
    integrity_error "the current branch has no origin upstream branch."
  fi
  case "$UPSTREAM_REF" in
  refs/heads/?*) ;;
  *) integrity_error "the current branch must track an origin branch ref." ;;
  esac
  if ! run_git check-ref-format "$UPSTREAM_REF" >/dev/null 2>&1; then
    integrity_error "the current branch has an invalid origin branch ref."
  fi

  if [ "$CHECKOUT_VALIDATION_MODE" = "configuration-only" ]; then
    return
  fi
  if [ "$CHECKOUT_VALIDATION_MODE" != "full" ]; then
    integrity_error "the repository checkout validation mode is invalid."
  fi

  if ! CHECKOUT_TREE=$(run_git -C "$CHECKOUT_ROOT" rev-parse --verify 'HEAD^{tree}' 2>/dev/null); then
    integrity_error "the repository HEAD tree could not be resolved."
  fi
  validate_repository_tree "$CHECKOUT_ROOT" "$CHECKOUT_TREE" worktree

  if ! WORKTREE_STATUS=$(GIT_OPTIONAL_LOCKS=0 run_git -C "$CHECKOUT_ROOT" \
    status --porcelain --untracked-files=all 2>/dev/null); then
    integrity_error "the repository status could not be inspected."
  fi
  if [ -n "$WORKTREE_STATUS" ]; then
    integrity_error "the repository has uncommitted changes; update was not attempted."
  fi
}

record_repository_update_snapshot() {
  SNAPSHOT_ROOT=$1
  INITIAL_BRANCH=$CURRENT_BRANCH
  INITIAL_UPSTREAM_REMOTE=$UPSTREAM_REMOTE
  INITIAL_UPSTREAM_REF=$UPSTREAM_REF
  if ! INITIAL_BRANCH_REF=$(run_git -C "$SNAPSHOT_ROOT" symbolic-ref --quiet HEAD 2>/dev/null) ||
    ! INITIAL_HEAD=$(run_git -C "$SNAPSHOT_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
    ! INITIAL_TREE=$(run_git -C "$SNAPSHOT_ROOT" rev-parse --verify "$INITIAL_HEAD^{tree}" 2>/dev/null); then
    integrity_error "the repository branch and HEAD could not be recorded before the update."
  fi
  capture_repository_origin_configuration_fingerprint "$SNAPSHOT_ROOT"
  INITIAL_ORIGIN_CONFIGURATION_FINGERPRINT=$ORIGIN_CONFIGURATION_FINGERPRINT
}

verify_repository_update_snapshot() {
  SNAPSHOT_ROOT=$1
  validate_single_origin_url "$SNAPSHOT_ROOT"
  verify_effective_repository_url origin -C "$SNAPSHOT_ROOT"
  capture_repository_origin_configuration_fingerprint "$SNAPSHOT_ROOT"
  if [ "$ORIGIN_CONFIGURATION_FINGERPRINT" != "$INITIAL_ORIGIN_CONFIGURATION_FINGERPRINT" ]; then
    integrity_error "the repository origin configuration changed while the update was being prepared; update was not applied."
  fi
  verify_repository_update_state "$SNAPSHOT_ROOT"
}

record_repository_update_critical_snapshot() {
  SNAPSHOT_ROOT=$1

  capture_repository_origin_configuration_fingerprint "$SNAPSHOT_ROOT"
  CRITICAL_ORIGIN_CONFIGURATION_FINGERPRINT=$ORIGIN_CONFIGURATION_FINGERPRINT
}

verify_repository_update_critical_snapshot() {
  SNAPSHOT_ROOT=$1

  validate_single_origin_url "$SNAPSHOT_ROOT"
  verify_effective_repository_url origin -C "$SNAPSHOT_ROOT"
  capture_repository_origin_configuration_fingerprint "$SNAPSHOT_ROOT"
  if [ "$ORIGIN_CONFIGURATION_FINGERPRINT" != "$CRITICAL_ORIGIN_CONFIGURATION_FINGERPRINT" ]; then
    integrity_error "the repository origin configuration changed during the protected update window; update was not applied."
  fi
  verify_repository_update_state "$SNAPSHOT_ROOT"
}

verify_repository_update_state() {
  SNAPSHOT_ROOT=$1

  if ! CURRENT_BRANCH_NOW=$(run_git -C "$SNAPSHOT_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null) ||
    [ "$CURRENT_BRANCH_NOW" != "$INITIAL_BRANCH" ] ||
    ! CURRENT_BRANCH_REF_NOW=$(run_git -C "$SNAPSHOT_ROOT" symbolic-ref --quiet HEAD 2>/dev/null) ||
    [ "$CURRENT_BRANCH_REF_NOW" != "$INITIAL_BRANCH_REF" ] ||
    ! CURRENT_UPSTREAM_REMOTE_NOW=$(run_git -C "$SNAPSHOT_ROOT" config --get "branch.$INITIAL_BRANCH.remote" 2>/dev/null) ||
    [ "$CURRENT_UPSTREAM_REMOTE_NOW" != "$INITIAL_UPSTREAM_REMOTE" ] ||
    ! CURRENT_UPSTREAM_REF_NOW=$(run_git -C "$SNAPSHOT_ROOT" config --get "branch.$INITIAL_BRANCH.merge" 2>/dev/null) ||
    [ "$CURRENT_UPSTREAM_REF_NOW" != "$INITIAL_UPSTREAM_REF" ] ||
    ! CURRENT_HEAD_NOW=$(run_git -C "$SNAPSHOT_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
    [ "$CURRENT_HEAD_NOW" != "$INITIAL_HEAD" ] ||
    ! CURRENT_REF_HEAD_NOW=$(run_git -C "$SNAPSHOT_ROOT" rev-parse --verify "$INITIAL_BRANCH_REF^{commit}" 2>/dev/null) ||
    [ "$CURRENT_REF_HEAD_NOW" != "$INITIAL_HEAD" ] ||
    ! WORKTREE_STATUS=$(GIT_OPTIONAL_LOCKS=0 run_git -C "$SNAPSHOT_ROOT" \
      status --porcelain --untracked-files=all 2>/dev/null) ||
    [ -n "$WORKTREE_STATUS" ]; then
    integrity_error "the repository branch, upstream, HEAD, or worktree changed while the update was being prepared; update was not applied."
  fi
  validate_repository_tree "$SNAPSHOT_ROOT" "$INITIAL_TREE" worktree
}

handle_remote_git_failure() {
  git_failure_status=$1
  case "$git_failure_status" in
  "$RUN_GIT_GIT_FAILURE_STATUS" | "$RUN_GIT_TIMEOUT_STATUS") access_failure ;;
  "$RUN_GIT_INFRASTRUCTURE_STATUS") integrity_error "Git operation monitoring failed." ;;
  *) integrity_error "a Git operation was interrupted." ;;
  esac
}

handle_transfer_git_failure() {
  git_failure_status=$1
  case "$git_failure_status" in
  "$RUN_GIT_GIT_FAILURE_STATUS") return ;;
  "$RUN_GIT_TIMEOUT_STATUS") access_failure ;;
  "$RUN_GIT_INFRASTRUCTURE_STATUS") integrity_error "Git operation monitoring failed." ;;
  *) integrity_error "a Git operation was interrupted." ;;
  esac
}

synchronize_agent_skills() {
  if ! run_management_cli ./bin/agent-skills sync; then
    integrity_error "Agent Skills synchronization failed."
  fi
}

if [ -n "${AGENT_SKILLS_REPO_DIR-}" ]; then
  REPOSITORY_DIR=$AGENT_SKILLS_REPO_DIR
else
  if [ -z "${HOME-}" ]; then
    integrity_error "HOME or AGENT_SKILLS_REPO_DIR must be set."
  fi
  REPOSITORY_DIR=$HOME/src/pych/agent-skills
fi

case "$REPOSITORY_DIR" in
/*) ;;
*) integrity_error "AGENT_SKILLS_REPO_DIR must be an absolute path." ;;
esac

if [ "$REPOSITORY_DIR" = "/" ]; then
  integrity_error "AGENT_SKILLS_REPO_DIR must not be the filesystem root."
fi

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false
export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=yes'

REPOSITORY_PARENT=${REPOSITORY_DIR%/*}
REPOSITORY_NAME=${REPOSITORY_DIR##*/}
if [ -z "$REPOSITORY_PARENT" ]; then
  REPOSITORY_PARENT=/
fi
if [ -z "$REPOSITORY_NAME" ]; then
  integrity_error "AGENT_SKILLS_REPO_DIR must name a repository directory."
fi

REPOSITORY_SUPERVISOR_PID=
REPOSITORY_SUPERVISOR_STATE=
SUPERVISOR_CLEANUP_STARTED=
SUPERVISOR_CLEANUP_COMPLETE=
SUPERVISOR_CLEANUP_ACK=
SUPERVISOR_FETCH_REF_CLEANUP_REQUEST=
SUPERVISOR_FETCH_REF_CLEANUP_RESULT=
SUPERVISOR_CONFIG_GUARD_ACQUIRE_REQUEST=
SUPERVISOR_CONFIG_GUARD_ACQUIRE_RESULT=
SUPERVISOR_CONFIG_GUARD_RELEASE_REQUEST=
SUPERVISOR_CONFIG_GUARD_RELEASE_RESULT=
TEMPORARY_CLONE=
TEMPORARY_FETCH_REF=
REPOSITORY_CONFIG_GUARD_HELD=0
REPOSITORY_UPDATE_CONFIG_ISOLATED=0
GIT_CONFIG_NOSYSTEM_WAS_SET=0
GIT_CONFIG_NOSYSTEM_SAVED=
GIT_CONFIG_SYSTEM_WAS_SET=0
GIT_CONFIG_SYSTEM_SAVED=
GIT_CONFIG_GLOBAL_WAS_SET=0
GIT_CONFIG_GLOBAL_SAVED=

isolate_repository_update_configuration() {
  if [ "$REPOSITORY_UPDATE_CONFIG_ISOLATED" -eq 1 ]; then
    return 0
  fi
  if [ "${GIT_CONFIG_NOSYSTEM+x}" = x ]; then
    GIT_CONFIG_NOSYSTEM_WAS_SET=1
    GIT_CONFIG_NOSYSTEM_SAVED=$GIT_CONFIG_NOSYSTEM
  fi
  if [ "${GIT_CONFIG_SYSTEM+x}" = x ]; then
    GIT_CONFIG_SYSTEM_WAS_SET=1
    GIT_CONFIG_SYSTEM_SAVED=$GIT_CONFIG_SYSTEM
  fi
  if [ "${GIT_CONFIG_GLOBAL+x}" = x ]; then
    GIT_CONFIG_GLOBAL_WAS_SET=1
    GIT_CONFIG_GLOBAL_SAVED=$GIT_CONFIG_GLOBAL
  fi
  GIT_CONFIG_NOSYSTEM=1
  GIT_CONFIG_SYSTEM=/dev/null
  GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM GIT_CONFIG_SYSTEM GIT_CONFIG_GLOBAL
  REPOSITORY_UPDATE_CONFIG_ISOLATED=1
}

restore_repository_update_configuration() {
  if [ "$REPOSITORY_UPDATE_CONFIG_ISOLATED" -eq 0 ]; then
    return 0
  fi
  if [ "$GIT_CONFIG_NOSYSTEM_WAS_SET" -eq 1 ]; then
    GIT_CONFIG_NOSYSTEM=$GIT_CONFIG_NOSYSTEM_SAVED
    export GIT_CONFIG_NOSYSTEM
  else
    unset GIT_CONFIG_NOSYSTEM
  fi
  if [ "$GIT_CONFIG_SYSTEM_WAS_SET" -eq 1 ]; then
    GIT_CONFIG_SYSTEM=$GIT_CONFIG_SYSTEM_SAVED
    export GIT_CONFIG_SYSTEM
  else
    unset GIT_CONFIG_SYSTEM
  fi
  if [ "$GIT_CONFIG_GLOBAL_WAS_SET" -eq 1 ]; then
    GIT_CONFIG_GLOBAL=$GIT_CONFIG_GLOBAL_SAVED
    export GIT_CONFIG_GLOBAL
  else
    unset GIT_CONFIG_GLOBAL
  fi
  REPOSITORY_UPDATE_CONFIG_ISOLATED=0
}

repository_supervisor_cleanup_started() {
  [ -e "$SUPERVISOR_CLEANUP_STARTED" ] ||
    [ -e "$SUPERVISOR_CLEANUP_COMPLETE" ]
}

remove_temporary_fetch_ref() {
  allow_supervisor_cleanup=${1-0}
  if [ -z "$TEMPORARY_FETCH_REF" ]; then
    return 0
  fi
  if [ -z "$REPOSITORY_SUPERVISOR_PID" ]; then
    return 1
  fi
  if repository_supervisor_cleanup_started; then
    if [ "$allow_supervisor_cleanup" = "1" ]; then
      return 0
    fi
    return 1
  fi
  rm -f "$SUPERVISOR_FETCH_REF_CLEANUP_RESULT" 2>/dev/null || return 1
  if repository_supervisor_cleanup_started; then
    if [ "$allow_supervisor_cleanup" = "1" ]; then
      return 0
    fi
    return 1
  fi
  if ! : >"$SUPERVISOR_FETCH_REF_CLEANUP_REQUEST"; then
    return 1
  fi
  while [ ! -s "$SUPERVISOR_FETCH_REF_CLEANUP_RESULT" ]; do
    if repository_supervisor_cleanup_started; then
      if [ "$allow_supervisor_cleanup" = "1" ]; then
        return 0
      fi
      return 1
    fi
    if ! repository_supervisor_is_live "$REPOSITORY_SUPERVISOR_PID"; then
      return 1
    fi
    sleep 0.01
  done
  if repository_supervisor_cleanup_started; then
    if [ "$allow_supervisor_cleanup" = "1" ]; then
      return 0
    fi
    return 1
  fi
  if ! IFS= read -r temporary_ref_cleanup_result \
    <"$SUPERVISOR_FETCH_REF_CLEANUP_RESULT" ||
    [ "$temporary_ref_cleanup_result" != "removed" ]; then
    return 1
  fi
  rm -f "$SUPERVISOR_FETCH_REF_CLEANUP_REQUEST" \
    "$SUPERVISOR_FETCH_REF_CLEANUP_RESULT" 2>/dev/null || return 1
  TEMPORARY_FETCH_REF=
}

acquire_repository_config_guard() {
  if [ "$REPOSITORY_CONFIG_GUARD_HELD" -eq 1 ]; then
    return 0
  fi
  if [ -z "$REPOSITORY_SUPERVISOR_PID" ] || repository_supervisor_cleanup_started; then
    return 1
  fi
  rm -f "$SUPERVISOR_CONFIG_GUARD_ACQUIRE_RESULT" 2>/dev/null || return 1
  if ! : >"$SUPERVISOR_CONFIG_GUARD_ACQUIRE_REQUEST"; then
    return 1
  fi
  while [ ! -s "$SUPERVISOR_CONFIG_GUARD_ACQUIRE_RESULT" ]; do
    if repository_supervisor_cleanup_started ||
      ! repository_supervisor_is_live "$REPOSITORY_SUPERVISOR_PID"; then
      return 1
    fi
    sleep 0.01
  done
  if ! IFS= read -r repository_config_guard_result \
    <"$SUPERVISOR_CONFIG_GUARD_ACQUIRE_RESULT" ||
    [ "$repository_config_guard_result" != "locked" ]; then
    return 1
  fi
  rm -f "$SUPERVISOR_CONFIG_GUARD_ACQUIRE_REQUEST" \
    "$SUPERVISOR_CONFIG_GUARD_ACQUIRE_RESULT" 2>/dev/null || return 1
  REPOSITORY_CONFIG_GUARD_HELD=1
}

release_repository_config_guard() {
  if [ "$REPOSITORY_CONFIG_GUARD_HELD" -eq 0 ]; then
    return 0
  fi
  if [ -z "$REPOSITORY_SUPERVISOR_PID" ] || repository_supervisor_cleanup_started; then
    return 1
  fi
  rm -f "$SUPERVISOR_CONFIG_GUARD_RELEASE_RESULT" 2>/dev/null || return 1
  if ! : >"$SUPERVISOR_CONFIG_GUARD_RELEASE_REQUEST"; then
    return 1
  fi
  while [ ! -s "$SUPERVISOR_CONFIG_GUARD_RELEASE_RESULT" ]; do
    if repository_supervisor_cleanup_started ||
      ! repository_supervisor_is_live "$REPOSITORY_SUPERVISOR_PID"; then
      return 1
    fi
    sleep 0.01
  done
  if ! IFS= read -r repository_config_guard_result \
    <"$SUPERVISOR_CONFIG_GUARD_RELEASE_RESULT" ||
    [ "$repository_config_guard_result" != "released" ]; then
    return 1
  fi
  rm -f "$SUPERVISOR_CONFIG_GUARD_RELEASE_REQUEST" \
    "$SUPERVISOR_CONFIG_GUARD_RELEASE_RESULT" 2>/dev/null || return 1
  REPOSITORY_CONFIG_GUARD_HELD=0
}

repository_supervisor_is_live() {
  inspected_supervisor_pid=$1
  if ! kill -0 "$inspected_supervisor_pid" 2>/dev/null; then
    return 1
  fi
  if [ -x /bin/ps ]; then
    if SUPERVISOR_PROCESS_STATE=$(/bin/ps -o state= -p \
      "$inspected_supervisor_pid" 2>/dev/null); then
      case "$SUPERVISOR_PROCESS_STATE" in
      *Z*) return 1 ;;
      esac
    fi
  fi
  return 0
}

release_repository_supervisor() {
  if [ -n "$REPOSITORY_SUPERVISOR_PID" ]; then
    stopped_supervisor_pid=$REPOSITORY_SUPERVISOR_PID
    kill "$stopped_supervisor_pid" 2>/dev/null || true
    while [ ! -e "$SUPERVISOR_CLEANUP_COMPLETE" ]; do
      if ! repository_supervisor_is_live "$stopped_supervisor_pid"; then
        wait "$stopped_supervisor_pid" 2>/dev/null || true
        REPOSITORY_SUPERVISOR_PID=
        rm -f "$SUPERVISOR_CLEANUP_STARTED" \
          "$SUPERVISOR_CLEANUP_COMPLETE" \
          "$SUPERVISOR_CLEANUP_ACK" 2>/dev/null || true
        printf '%s\n' 'Error: the repository supervisor exited without completing cleanup.' >&2
        return 1
      fi
      sleep 0.01
    done
    if ! : >"$SUPERVISOR_CLEANUP_ACK"; then
      kill -KILL "$stopped_supervisor_pid" 2>/dev/null || true
      wait "$stopped_supervisor_pid" 2>/dev/null || true
      REPOSITORY_SUPERVISOR_PID=
      printf '%s\n' 'Error: the repository supervisor cleanup acknowledgement could not be written.' >&2
      return 1
    fi
    if ! wait "$stopped_supervisor_pid" 2>/dev/null; then
      REPOSITORY_SUPERVISOR_PID=
      printf '%s\n' 'Error: the repository supervisor failed while completing cleanup.' >&2
      return 1
    fi
    REPOSITORY_SUPERVISOR_PID=
  fi
  rm -f "$SUPERVISOR_CLEANUP_STARTED" "$SUPERVISOR_CLEANUP_COMPLETE" \
    "$SUPERVISOR_CLEANUP_ACK" 2>/dev/null || true
}

cleanup_repository_setup() {
  repository_setup_status=$1
  trap '' HUP INT TERM
  trap - 0
  if ! remove_temporary_fetch_ref 1; then
    printf '%s\n' 'Error: the temporary fetched ref could not be removed.' >&2
    repository_setup_status=1
  fi
  if ! release_repository_supervisor; then
    repository_setup_status=1
  fi
  exit "$repository_setup_status"
}

trap 'cleanup_repository_setup "$?"' 0
trap 'exit 1' HUP INT TERM

SUPERVISOR_STATE_ROOT=${TMPDIR:-/tmp}
case "$SUPERVISOR_STATE_ROOT" in
/*) ;;
*) SUPERVISOR_STATE_ROOT=./$SUPERVISOR_STATE_ROOT ;;
esac
if ! resolve_physical_directory "$SUPERVISOR_STATE_ROOT"; then
  integrity_error "TMPDIR must identify an existing directory."
fi
SUPERVISOR_STATE_ROOT=$RESOLVED_PHYSICAL_DIRECTORY
if ! SUPERVISOR_SUFFIX=$(
  cd / &&
    python3 -I -S -c 'import secrets; print(secrets.token_hex(16))'
); then
  integrity_error "a repository supervisor identifier could not be generated."
fi
REPOSITORY_SUPERVISOR_STATE=$SUPERVISOR_STATE_ROOT/agent-skills-supervisor.$SUPERVISOR_SUFFIX
SUPERVISOR_STATUS=$REPOSITORY_SUPERVISOR_STATE/status
SUPERVISOR_REPOSITORY_PATH=$REPOSITORY_SUPERVISOR_STATE/repository-path
SUPERVISOR_REPOSITORY_IDENTITY=$REPOSITORY_SUPERVISOR_STATE/repository-identity
SUPERVISOR_TEMPORARY_CLONE_PATH=$REPOSITORY_SUPERVISOR_STATE/temporary-clone-path
SUPERVISOR_CLEANUP_STARTED=$REPOSITORY_SUPERVISOR_STATE.cleanup-started
SUPERVISOR_CLEANUP_COMPLETE=$REPOSITORY_SUPERVISOR_STATE.cleanup-complete
SUPERVISOR_CLEANUP_ACK=$REPOSITORY_SUPERVISOR_STATE.cleanup-ack
SUPERVISOR_FETCH_REF_CLEANUP_REQUEST=$REPOSITORY_SUPERVISOR_STATE/fetch-ref-cleanup
SUPERVISOR_FETCH_REF_CLEANUP_RESULT=$REPOSITORY_SUPERVISOR_STATE/fetch-ref-cleanup-status
SUPERVISOR_CONFIG_GUARD_ACQUIRE_REQUEST=$REPOSITORY_SUPERVISOR_STATE/config-guard-acquire
SUPERVISOR_CONFIG_GUARD_ACQUIRE_RESULT=$REPOSITORY_SUPERVISOR_STATE/config-guard-acquire-status
SUPERVISOR_CONFIG_GUARD_RELEASE_REQUEST=$REPOSITORY_SUPERVISOR_STATE/config-guard-release
SUPERVISOR_CONFIG_GUARD_RELEASE_RESULT=$REPOSITORY_SUPERVISOR_STATE/config-guard-release-status
PUBLISH_REQUEST=$REPOSITORY_SUPERVISOR_STATE/publish
PUBLISH_RESULT=$REPOSITORY_SUPERVISOR_STATE/publish-status

if [ "${AGENT_SKILLS_INTERNAL_TEST_STOP_BEFORE_LOCK_HELPER-}" = "1" ]; then
  kill -STOP "$$"
fi

# 子 process が排他・一時 clone・operation registry を所有し、親の消滅を検知する。
(
  cd / || exit 1
  exec python3 -I -S - "$$" "$SUPERVISOR_SUFFIX" "$SUPERVISOR_STATUS" \
    "$REPOSITORY_SUPERVISOR_STATE" "$REPOSITORY_DIR" "$PUBLISH_REQUEST" \
    "$PUBLISH_RESULT" "$SUPERVISOR_REPOSITORY_PATH" \
    "$SUPERVISOR_TEMPORARY_CLONE_PATH" "$SUPERVISOR_CLEANUP_STARTED" \
    "$SUPERVISOR_CLEANUP_COMPLETE" "$SUPERVISOR_CLEANUP_ACK" \
    "$SUPERVISOR_FETCH_REF_CLEANUP_REQUEST" \
    "$SUPERVISOR_FETCH_REF_CLEANUP_RESULT" \
    "$SUPERVISOR_CONFIG_GUARD_ACQUIRE_REQUEST" \
    "$SUPERVISOR_CONFIG_GUARD_ACQUIRE_RESULT" \
    "$SUPERVISOR_CONFIG_GUARD_RELEASE_REQUEST" \
    "$SUPERVISOR_CONFIG_GUARD_RELEASE_RESULT"
) <<'PY' &
import contextlib
import ctypes
import fcntl
import hashlib
import os
import secrets
import signal
import shutil
import stat
import subprocess
import sys
import time
import unicodedata

(
    expected_parent_pid_text,
    supervisor_suffix,
    status_path,
    state_directory,
    configured_repository_path,
    publish_request_path,
    publish_result_path,
    repository_path_path,
    temporary_clone_path_path,
    cleanup_started_path,
    cleanup_complete_path,
    cleanup_ack_path,
    fetch_ref_cleanup_request_path,
    fetch_ref_cleanup_result_path,
    config_guard_acquire_request_path,
    config_guard_acquire_result_path,
    config_guard_release_request_path,
    config_guard_release_result_path,
) = sys.argv[1:]
expected_parent_pid = int(expected_parent_pid_text)
repository_path = os.path.realpath(configured_repository_path)
repository_parent = os.path.dirname(repository_path)
repository_name = os.path.basename(repository_path)
repository_identity_path = os.path.join(state_directory, "repository-identity")
temporary_clone_path = os.path.join(
    repository_parent,
    f".{repository_name}.clone.{supervisor_suffix}",
)
lock_fds = []
control_fd = None
repository_directory_fd = None
initial_repository_directory_fd = None
temporary_clone = None
temporary_fetch_ref = f"refs/agent-skills/setup/{supervisor_suffix}"
config_guard_records = []
state_directory_created = False
operations_directory_created = False
created_parent_directories = []
stop_requested = False
publication_attempted = False


def parent_is_setup():
    return os.getppid() == expected_parent_pid


def write_status(path, status):
    with open(path, "x", encoding="utf-8") as status_file:
        status_file.write(f"{status}\n")


def write_path(path, value):
    with open(path, "xb") as path_file:
        contents = os.fsencode(value)
        while contents:
            contents = contents[os.write(path_file.fileno(), contents) :]


def stop(_signal_number, _frame):
    global stop_requested
    stop_requested = True


DIRECTORY_OPEN_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def directory_identity(file_descriptor):
    directory_status = os.fstat(file_descriptor)
    if not stat.S_ISDIR(directory_status.st_mode):
        raise NotADirectoryError("repository path component is not a directory")
    return directory_status.st_dev, directory_status.st_ino


def repository_parent_components():
    return [component for component in repository_parent.split(os.sep) if component]


def inspect_repository_destination():
    current_fd = os.open(os.sep, DIRECTORY_OPEN_FLAGS)
    topology = [(os.sep, *directory_identity(current_fd))]
    try:
        for component in repository_parent_components():
            try:
                next_fd = os.open(component, DIRECTORY_OPEN_FLAGS, dir_fd=current_fd)
            except FileNotFoundError:
                return tuple(topology), None, None
            os.close(current_fd)
            current_fd = next_fd
            topology.append((component, *directory_identity(current_fd)))

        try:
            repository_status = os.stat(
                repository_name,
                dir_fd=current_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return tuple(topology), None, None
        if not stat.S_ISDIR(repository_status.st_mode):
            raise NotADirectoryError(repository_path)

        repository_fd = os.open(
            repository_name,
            DIRECTORY_OPEN_FLAGS,
            dir_fd=current_fd,
        )
        opened_identity = directory_identity(repository_fd)
        path_identity = (repository_status.st_dev, repository_status.st_ino)
        if opened_identity != path_identity:
            os.close(repository_fd)
            raise OSError("repository destination changed while it was opened")
        return tuple(topology), opened_identity, repository_fd
    finally:
        os.close(current_fd)


def create_parent_directories(path):
    del path
    current_fd = os.open(os.sep, DIRECTORY_OPEN_FLAGS)
    current_path = os.sep
    try:
        for component in repository_parent_components():
            try:
                next_fd = os.open(component, DIRECTORY_OPEN_FLAGS, dir_fd=current_fd)
            except FileNotFoundError:
                os.mkdir(component, mode=0o700, dir_fd=current_fd)
                current_path = os.path.join(current_path, component)
                created_parent_directories.append(current_path)
                next_fd = os.open(component, DIRECTORY_OPEN_FLAGS, dir_fd=current_fd)
            else:
                current_path = os.path.join(current_path, component)
            os.close(current_fd)
            current_fd = next_fd
            directory_identity(current_fd)
    finally:
        os.close(current_fd)


def alternate_case(name):
    return name.swapcase()


def filesystem_is_case_insensitive(path, device, cache):
    if device in cache:
        return cache[device]

    current = path
    while True:
        try:
            if os.stat(current).st_dev != device:
                break
            entries = os.listdir(current)
        except OSError:
            entries = []

        for entry in entries:
            alternate = alternate_case(entry)
            if alternate == entry:
                continue
            original_path = os.path.join(current, entry)
            alternate_path = os.path.join(current, alternate)
            try:
                original_status = os.stat(original_path)
                alternate_status = os.stat(alternate_path)
            except FileNotFoundError:
                cache[device] = False
                return False
            except OSError:
                continue
            cache[device] = (
                original_status.st_dev,
                original_status.st_ino,
            ) == (
                alternate_status.st_dev,
                alternate_status.st_ino,
            )
            return cache[device]

        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent

    # Darwin では未解決名を case-fold して destination alias も排他する。
    cache[device] = sys.platform == "darwin"
    return cache[device]


def repository_lock_digests(path):
    absolute_path = os.path.realpath(path)
    components = [component for component in absolute_path.split(os.sep) if component]
    current = os.sep
    digests = set()
    case_sensitivity_cache = {}

    for index in range(len(components) + 1):
        try:
            current_status = os.stat(current)
        except OSError:
            break

        remaining_components = components[index:]
        if filesystem_is_case_insensitive(
            current if stat.S_ISDIR(current_status.st_mode) else os.path.dirname(current),
            current_status.st_dev,
            case_sensitivity_cache,
        ):
            remaining_components = [
                unicodedata.normalize("NFD", component).casefold()
                for component in remaining_components
            ]
        remaining_path = os.sep.join(remaining_components)
        identity = (
            b"agent-skills-repository-lock-v2\0"
            + str(current_status.st_dev).encode("ascii")
            + b"\0"
            + str(current_status.st_ino).encode("ascii")
            + b"\0"
            + os.fsencode(remaining_path)
        )
        digests.add(hashlib.sha256(identity).hexdigest())

        if index == len(components):
            break
        current = os.path.join(current, components[index])

    if not digests:
        raise OSError("repository lock identity could not be determined")
    return sorted(digests)


def open_repository_lock(root_fd, effective_uid, lock_digest):
    lock_name = f"{lock_digest}.lock"
    expected_contents = f"agent-skills-repository-lock-v2\n{lock_digest}\n".encode()
    lock_flags = os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        lock_flags |= os.O_NOFOLLOW

    try:
        repository_lock_fd = os.open(lock_name, lock_flags, dir_fd=root_fd)
    except FileNotFoundError:
        temporary_name = f".{lock_name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
        temporary_fd = os.open(
            temporary_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=root_fd,
        )
        try:
            os.fchmod(temporary_fd, 0o600)
            contents = expected_contents
            while contents:
                contents = contents[os.write(temporary_fd, contents) :]
            os.fsync(temporary_fd)
        finally:
            os.close(temporary_fd)
        try:
            try:
                os.link(
                    temporary_name,
                    lock_name,
                    src_dir_fd=root_fd,
                    dst_dir_fd=root_fd,
                    follow_symlinks=False,
                )
            except FileExistsError:
                pass
        finally:
            os.unlink(temporary_name, dir_fd=root_fd)
        repository_lock_fd = os.open(lock_name, lock_flags, dir_fd=root_fd)

    try:
        lock_status = os.fstat(repository_lock_fd)
        lock_path_status = os.stat(lock_name, dir_fd=root_fd, follow_symlinks=False)
        if (
            not stat.S_ISREG(lock_status.st_mode)
            or lock_status.st_uid != effective_uid
            or stat.S_IMODE(lock_status.st_mode) != 0o600
            or lock_status.st_nlink != 1
            or (lock_status.st_dev, lock_status.st_ino)
            != (lock_path_status.st_dev, lock_path_status.st_ino)
        ):
            raise OSError("unsafe repository lock file")
        os.lseek(repository_lock_fd, 0, os.SEEK_SET)
        if os.read(repository_lock_fd, len(expected_contents) + 1) != expected_contents:
            raise OSError("repository lock file collision")
        fcntl.flock(repository_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return repository_lock_fd
    except Exception:
        os.close(repository_lock_fd)
        raise


def collect_unused_repository_locks(root_fd, effective_uid, retained_names):
    for lock_name in os.listdir(root_fd):
        if lock_name in retained_names or len(lock_name) != 69 or not lock_name.endswith(".lock"):
            continue
        lock_digest = lock_name[:-5]
        if any(character not in "0123456789abcdef" for character in lock_digest):
            continue

        repository_lock_fd = None
        try:
            lock_flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
            repository_lock_fd = os.open(lock_name, lock_flags, dir_fd=root_fd)
            lock_status = os.fstat(repository_lock_fd)
            lock_path_status = os.stat(lock_name, dir_fd=root_fd, follow_symlinks=False)
            expected_contents = (
                f"agent-skills-repository-lock-v2\n{lock_digest}\n".encode()
            )
            if (
                not stat.S_ISREG(lock_status.st_mode)
                or lock_status.st_uid != effective_uid
                or stat.S_IMODE(lock_status.st_mode) != 0o600
                or lock_status.st_nlink != 1
                or (lock_status.st_dev, lock_status.st_ino)
                != (lock_path_status.st_dev, lock_path_status.st_ino)
            ):
                continue
            os.lseek(repository_lock_fd, 0, os.SEEK_SET)
            if os.read(repository_lock_fd, len(expected_contents) + 1) != expected_contents:
                continue
            fcntl.flock(repository_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock_path_status = os.stat(lock_name, dir_fd=root_fd, follow_symlinks=False)
            if (lock_status.st_dev, lock_status.st_ino) != (
                lock_path_status.st_dev,
                lock_path_status.st_ino,
            ):
                continue
            os.unlink(lock_name, dir_fd=root_fd)
        except (BlockingIOError, FileNotFoundError, OSError):
            pass
        finally:
            if repository_lock_fd is not None:
                with contextlib.suppress(OSError):
                    os.close(repository_lock_fd)


def acquire_interruptible_flock(file_descriptor, lock_type):
    marker_path = os.environ.get("AGENT_SKILLS_INTERNAL_TEST_LOCK_WAIT_MARKER")
    marker_written = False
    while parent_is_setup() and not stop_requested:
        try:
            fcntl.flock(file_descriptor, lock_type | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if marker_path and not marker_written:
                with open(marker_path, "x", encoding="utf-8"):
                    pass
                marker_written = True
            time.sleep(0.05)
    raise InterruptedError("repository lock acquisition was cancelled")


def acquire_repository_locks(path):
    effective_uid = os.geteuid()
    lock_root = os.path.join(
        os.path.realpath("/tmp"),
        f"agent-skills-repository-locks.{effective_uid}",
    )
    lock_root_created = False
    try:
        os.mkdir(lock_root, mode=0o700)
        lock_root_created = True
    except FileExistsError:
        pass

    root_flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        root_flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        root_flags |= os.O_NOFOLLOW
    root_fd = os.open(lock_root, root_flags)
    repository_lock_fds = []
    root_locked = False
    try:
        if lock_root_created:
            os.fchmod(root_fd, 0o700)
        root_status = os.fstat(root_fd)
        root_path_status = os.lstat(lock_root)
        if (
            not stat.S_ISDIR(root_status.st_mode)
            or root_status.st_uid != effective_uid
            or stat.S_IMODE(root_status.st_mode) != 0o700
            or (root_status.st_dev, root_status.st_ino)
            != (root_path_status.st_dev, root_path_status.st_ino)
        ):
            raise OSError("unsafe repository lock directory")

        lock_digests = repository_lock_digests(path)
        acquire_interruptible_flock(root_fd, fcntl.LOCK_EX)
        root_locked = True
        collect_unused_repository_locks(
            root_fd,
            effective_uid,
            {f"{lock_digest}.lock" for lock_digest in lock_digests},
        )
        for lock_digest in lock_digests:
            repository_lock_fds.append(
                open_repository_lock(root_fd, effective_uid, lock_digest)
            )
        return_fds = repository_lock_fds
        repository_lock_fds = []
        return return_fds
    finally:
        for repository_lock_fd in repository_lock_fds:
            with contextlib.suppress(OSError):
                os.close(repository_lock_fd)
        if root_locked:
            with contextlib.suppress(OSError):
                fcntl.flock(root_fd, fcntl.LOCK_UN)
        os.close(root_fd)


def pause_after_parent_creation_for_test():
    marker_path = os.environ.get("AGENT_SKILLS_INTERNAL_TEST_PARENT_MARKER")
    gate_path = os.environ.get("AGENT_SKILLS_INTERNAL_TEST_PARENT_GATE")
    if not marker_path or not gate_path:
        return True
    with open(marker_path, "x", encoding="utf-8"):
        pass
    while not os.path.exists(gate_path):
        if not parent_is_setup() or stop_requested:
            return False
        time.sleep(0.01)
    return True


def registered_operations():
    operations = []
    operations_directory = os.path.join(state_directory, "operations")
    try:
        names = os.listdir(operations_directory)
    except OSError:
        return operations
    for name in names:
        path = os.path.join(operations_directory, name)
        try:
            with open(path, encoding="utf-8") as registration:
                fields = registration.read().split()
            if len(fields) not in (1, 2):
                continue
            runner_pid = int(fields[0])
            if runner_pid <= 1:
                continue
            worker_pid = None
            if len(fields) == 2:
                worker_pid = int(fields[1])
                if worker_pid <= 1 or os.getpgid(worker_pid) != worker_pid:
                    continue
            operations.append((path, runner_pid, worker_pid))
        except (OSError, ValueError):
            continue
    return operations


def signal_registered_operations(operations, signal_number):
    for _path, runner_pid, worker_pid in operations:
        if worker_pid is not None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(worker_pid, signal_number)
        with contextlib.suppress(ProcessLookupError):
            os.kill(runner_pid, signal_number)


def acquire_control_exclusive(deadline):
    while time.monotonic() < deadline:
        try:
            fcntl.flock(control_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            time.sleep(0.01)
    return False


def stop_registered_operations():
    if control_fd is None:
        return True
    shutdown_path = os.path.join(state_directory, "shutdown")
    try:
        with open(shutdown_path, "x", encoding="utf-8"):
            pass
    except FileExistsError:
        pass
    except OSError:
        pass

    control_locked = acquire_control_exclusive(time.monotonic() + 0.5)
    operations_directory = os.path.join(state_directory, "operations")
    deadline = time.monotonic() + 3
    try:
        while time.monotonic() < deadline:
            if control_locked:
                # runner の登録と cage の command 起動を shared lock で囲む。
                # exclusive lock 取得後は未登録 command が残らない。
                for name in os.listdir(operations_directory):
                    with contextlib.suppress(OSError):
                        os.unlink(os.path.join(operations_directory, name))
                return not os.listdir(operations_directory)

            operations = registered_operations()
            if operations:
                signal_registered_operations(operations, signal.SIGTERM)
                graceful_deadline = min(deadline, time.monotonic() + 0.2)
                while time.monotonic() < graceful_deadline:
                    time.sleep(0.01)
                signal_registered_operations(
                    registered_operations(), signal.SIGKILL
                )

            if not control_locked:
                control_locked = acquire_control_exclusive(
                    min(deadline, time.monotonic() + 0.05)
                )
            if not control_locked:
                time.sleep(0.01)
                continue
        return False
    finally:
        if control_locked:
            fcntl.flock(control_fd, fcntl.LOCK_UN)


def remove_validation_artifacts():
    cleanup_succeeded = True
    try:
        names = os.listdir(state_directory)
    except FileNotFoundError:
        return True
    except OSError:
        return False
    for name in names:
        if not name.startswith(
            ("validation-index.", "validation-worktree.", "filter-probe.")
        ):
            continue
        path = os.path.join(state_directory, name)
        try:
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path)
            else:
                os.unlink(path)
        except FileNotFoundError:
            pass
        except OSError:
            cleanup_succeeded = False
    return cleanup_succeeded


def remove_temporary_clone():
    if temporary_clone is None:
        return True
    try:
        cleanup_marker = os.environ.get("AGENT_SKILLS_INTERNAL_TEST_CLEANUP_MARKER")
        cleanup_gate = os.environ.get("AGENT_SKILLS_INTERNAL_TEST_CLEANUP_GATE")
        if cleanup_marker and cleanup_gate:
            with open(cleanup_marker, "x", encoding="utf-8"):
                pass
            while not os.path.exists(cleanup_gate):
                time.sleep(0.01)
        cleanup_error_marker = os.environ.get("AGENT_SKILLS_INTERNAL_TEST_CLEANUP_ERROR_MARKER")
        if cleanup_error_marker:
            with open(cleanup_error_marker, "x", encoding="utf-8"):
                pass
            raise OSError("injected temporary clone cleanup failure")
        if os.path.islink(temporary_clone):
            os.unlink(temporary_clone)
        else:
            shutil.rmtree(temporary_clone)
        return True
    except FileNotFoundError:
        return True
    except OSError as exc:
        print(f"Warning: the temporary clone could not be removed: {exc}", file=sys.stderr)
        return False


def repository_config_guard_paths():
    environment = os.environ.copy()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"

    def query_repository_configuration(*arguments):
        try:
            return subprocess.run(
                [
                    "git",
                    "--no-replace-objects",
                    "-C",
                    repository_path,
                    *arguments,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env=environment,
                check=False,
            )
        except OSError as exc:
            raise OSError("repository configuration could not be inspected") from exc

    def query_repository_path(argument):
        try:
            result = query_repository_configuration("rev-parse", argument)
        except OSError as exc:
            raise OSError("repository Git directory could not be resolved") from exc
        # rev-parse の末尾 LF だけを除き、path 内の LF は保持する。
        if result.returncode != 0 or not result.stdout.endswith(b"\n"):
            raise OSError("repository Git directory could not be resolved")
        value = result.stdout[:-1]
        if not value:
            raise OSError("repository Git directory is malformed")
        return value

    def absolute_git_path(value):
        decoded = os.fsdecode(value)
        if not os.path.isabs(decoded):
            decoded = os.path.join(repository_path, decoded)
        return os.path.realpath(decoded)

    git_directory = absolute_git_path(query_repository_path("--git-dir"))
    common_directory = absolute_git_path(query_repository_path("--git-common-dir"))
    guard_paths = {
        os.path.join(common_directory, "config"),
        os.path.join(git_directory, "config"),
        os.path.join(git_directory, "config.worktree"),
    }

    result = query_repository_configuration(
        "config",
        "--includes",
        "--null",
        "--show-scope",
        "--show-origin",
        "--list",
    )
    if result.returncode != 0 or (
        result.stdout and not result.stdout.endswith(b"\0")
    ):
        raise OSError("repository configuration sources could not be inspected")
    source_records = result.stdout[:-1].split(b"\0") if result.stdout else []
    if len(source_records) % 3 != 0:
        raise OSError("repository configuration source records are malformed")

    def normalize_configuration_path(value, base_directory):
        if not value or b"\0" in value:
            raise OSError("repository configuration path is malformed")
        decoded = os.fsdecode(value)
        # NUL 区切り値を path API で扱い、path 内の制御文字を保持する。
        if decoded.startswith("~"):
            if decoded != "~" and not decoded.startswith("~/"):
                raise OSError("repository configuration path is malformed")
            home_directory = os.environ.get("HOME")
            if not home_directory:
                raise OSError("repository configuration path is malformed")
            decoded = os.path.join(home_directory, decoded[2:]) if decoded != "~" else home_directory
        if not os.path.isabs(decoded):
            decoded = os.path.join(base_directory, decoded)
        return os.path.normpath(os.path.abspath(decoded))

    for offset in range(0, len(source_records), 3):
        source_scope, source_origin, source_entry = source_records[offset : offset + 3]
        if source_scope == b"command":
            raise OSError("environment-supplied Git command configuration is not permitted")
        if source_scope not in (b"local", b"worktree"):
            # merge / checkout に影響する local / worktree 設定だけを guard する。
            continue
        if not source_origin.startswith(b"file:"):
            raise OSError("repository configuration source is not a file")
        source_path = normalize_configuration_path(source_origin[5:], repository_path)
        guard_paths.add(source_path)
        if b"\n" not in source_entry:
            raise OSError("repository configuration entry is malformed")
        source_key, source_value = source_entry.split(b"\n", 1)
        normalized_key = source_key.lower()
        if normalized_key == b"include.path" or (
            normalized_key.startswith(b"includeif.") and normalized_key.endswith(b".path")
        ):
            guard_paths.add(
                normalize_configuration_path(source_value, os.path.dirname(source_path))
            )

    resolved_guard_paths = set()
    for configuration_path in guard_paths:
        resolved_path = os.path.realpath(configuration_path)
        resolved_guard_paths.add(configuration_path)
        resolved_guard_paths.add(resolved_path)
    for configuration_path in resolved_guard_paths:
        directory_path = os.path.dirname(configuration_path)
        if not directory_path or not os.path.isdir(directory_path):
            raise OSError("repository configuration parent directory is invalid")
    return tuple(sorted(resolved_guard_paths))


def config_guard_is_intact():
    if not config_guard_records:
        return False
    for directory_fd, lock_name, expected_identity in config_guard_records:
        try:
            lock_status = os.stat(lock_name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError:
            return False
        if (
            not stat.S_ISREG(lock_status.st_mode)
            or lock_status.st_nlink != 1
            or (lock_status.st_dev, lock_status.st_ino) != expected_identity
        ):
            return False
    return True


def remove_repository_config_guard():
    global config_guard_records
    if not config_guard_records:
        return True
    cleanup_succeeded = True
    for directory_fd, lock_name, expected_identity in reversed(config_guard_records):
        try:
            lock_status = os.stat(lock_name, dir_fd=directory_fd, follow_symlinks=False)
            if (
                stat.S_ISREG(lock_status.st_mode)
                and lock_status.st_nlink == 1
                and (lock_status.st_dev, lock_status.st_ino) == expected_identity
            ):
                os.unlink(lock_name, dir_fd=directory_fd)
            else:
                cleanup_succeeded = False
        except FileNotFoundError:
            cleanup_succeeded = False
        except OSError:
            cleanup_succeeded = False
        finally:
            with contextlib.suppress(OSError):
                os.close(directory_fd)
    config_guard_records = []
    return cleanup_succeeded


def acquire_repository_config_guard():
    global config_guard_records
    if config_guard_records:
        return config_guard_is_intact()
    records = []
    locked_names = set()
    try:
        for configuration_path in repository_config_guard_paths():
            directory_path, configuration_name = os.path.split(configuration_path)
            if not configuration_name or not os.path.isdir(directory_path):
                raise OSError("repository configuration path is invalid")
            directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
            if hasattr(os, "O_NOFOLLOW"):
                directory_flags |= os.O_NOFOLLOW
            directory_fd = os.open(directory_path, directory_flags)
            lock_name = f"{configuration_name}.lock"
            directory_status = os.fstat(directory_fd)
            lock_identity = (
                directory_status.st_dev,
                directory_status.st_ino,
                lock_name,
            )
            # 同一 inode の lock alias は重複作成しない。
            if lock_identity in locked_names:
                os.close(directory_fd)
                continue
            lock_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                lock_flags |= os.O_NOFOLLOW
            try:
                lock_fd = os.open(lock_name, lock_flags, 0o600, dir_fd=directory_fd)
            except FileExistsError:
                # 自身が作成した同一 inode の lock alias だけを重複として許可する。
                try:
                    existing_lock_status = os.stat(
                        lock_name, dir_fd=directory_fd, follow_symlinks=False
                    )
                    existing_lock_identity = (
                        existing_lock_status.st_dev,
                        existing_lock_status.st_ino,
                    )
                except OSError:
                    os.close(directory_fd)
                    raise
                if any(
                    existing_lock_identity == expected_identity
                    for _record_directory_fd, _record_lock_name, expected_identity in records
                ):
                    os.close(directory_fd)
                    continue
                os.close(directory_fd)
                raise
            except Exception:
                os.close(directory_fd)
                raise
            try:
                os.fchmod(lock_fd, 0o600)
                contents = (
                    f"agent-skills-config-guard-v1\\n{supervisor_suffix}\\n".encode()
                )
                while contents:
                    contents = contents[os.write(lock_fd, contents) :]
                os.fsync(lock_fd)
                lock_status = os.fstat(lock_fd)
                if (
                    not stat.S_ISREG(lock_status.st_mode)
                    or lock_status.st_uid != os.geteuid()
                    or stat.S_IMODE(lock_status.st_mode) != 0o600
                    or lock_status.st_nlink != 1
                ):
                    raise OSError("unsafe repository configuration lock")
                records.append(
                    (directory_fd, lock_name, (lock_status.st_dev, lock_status.st_ino))
                )
                locked_names.add(lock_identity)
                directory_fd = None
            finally:
                os.close(lock_fd)
                if directory_fd is not None:
                    with contextlib.suppress(OSError):
                        os.close(directory_fd)
        config_guard_records = records
        if not config_guard_is_intact():
            raise OSError("repository configuration lock identity changed")
        return True
    except Exception:
        for directory_fd, lock_name, expected_identity in reversed(records):
            try:
                lock_status = os.stat(lock_name, dir_fd=directory_fd, follow_symlinks=False)
                if (lock_status.st_dev, lock_status.st_ino) == expected_identity:
                    os.unlink(lock_name, dir_fd=directory_fd)
            except OSError:
                pass
            finally:
                with contextlib.suppress(OSError):
                    os.close(directory_fd)
        config_guard_records = []
        return False


def remove_temporary_fetch_ref():
    if repository_directory_fd is None:
        return True
    try:
        repository_status = os.stat(repository_path, follow_symlinks=False)
        opened_status = os.fstat(repository_directory_fd)
        if (
            not stat.S_ISDIR(repository_status.st_mode)
            or (repository_status.st_dev, repository_status.st_ino)
            != (opened_status.st_dev, opened_status.st_ino)
        ):
            return False
        environment = os.environ.copy()
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        result = subprocess.run(
            [
                "git",
                "--no-replace-objects",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "submodule.recurse=false",
                "-C",
                repository_path,
                "update-ref",
                "-d",
                temporary_fetch_ref,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
            check=False,
        )
    except OSError:
        return False
    return result.returncode == 0


def rename_no_replace():
    libc = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(temporary_clone_path)
    destination_bytes = os.fsencode(repository_path)

    if sys.platform == "darwin":
        rename_exclusive = 0x00000004
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(source_bytes, destination_bytes, rename_exclusive)
    elif sys.platform.startswith("linux"):
        at_current_working_directory = -100
        rename_no_replace_flag = 0x00000001
        rename = libc.renameat2
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        rename.restype = ctypes.c_int
        result = rename(
            at_current_working_directory,
            source_bytes,
            at_current_working_directory,
            destination_bytes,
            rename_no_replace_flag,
        )
    else:
        return False

    return result == 0


def pause_before_publish_for_test():
    marker_path = os.environ.get("AGENT_SKILLS_INTERNAL_TEST_PUBLISH_MARKER")
    gate_path = os.environ.get("AGENT_SKILLS_INTERNAL_TEST_PUBLISH_GATE")
    if not marker_path or not gate_path:
        return True
    with open(marker_path, "x", encoding="utf-8"):
        pass
    while not os.path.exists(gate_path):
        if not parent_is_setup() or stop_requested:
            return False
        time.sleep(0.01)
    return True


signal.signal(signal.SIGHUP, stop)
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)

exit_status = 0
try:
    if not parent_is_setup():
        raise SystemExit(0)

    try:
        os.mkdir(state_directory, mode=0o700)
        state_directory_created = True
        write_path(repository_path_path, repository_path)
        write_path(temporary_clone_path_path, temporary_clone_path)
    except OSError as exc:
        print(f"Error: a repository supervisor state directory could not be created: {exc}", file=sys.stderr)
        raise SystemExit(1)

    if not parent_is_setup():
        raise SystemExit(0)

    try:
        (
            initial_repository_topology,
            initial_repository_identity,
            initial_repository_directory_fd,
        ) = inspect_repository_destination()
    except OSError as exc:
        print(f"Error: the repository destination could not be fixed before locking: {exc}", file=sys.stderr)
        result = "destination-error"
        exit_status = 1

    if exit_status == 0:
        try:
            lock_fds = acquire_repository_locks(repository_path)
        except BlockingIOError:
            result = "busy"
        except OSError as exc:
            print(f"Error: the repository setup lock could not be acquired: {exc}", file=sys.stderr)
            result = "error"
            exit_status = 1
        else:
            result = "locked"

    if exit_status == 0 and result == "locked":
        if not parent_is_setup():
            raise SystemExit(0)
        try:
            create_parent_directories(repository_parent)
        except OSError as exc:
            print(f"Error: the parent directory for the repository could not be created: {exc}", file=sys.stderr)
            result = "parent-error"
            exit_status = 1

        if exit_status == 0 and not pause_after_parent_creation_for_test():
            raise SystemExit(0)

        if exit_status == 0:
            if not parent_is_setup():
                raise SystemExit(0)
            try:
                operations_directory = os.path.join(state_directory, "operations")
                os.mkdir(operations_directory, mode=0o700)
                operations_directory_created = True
                control_path = os.path.join(state_directory, "control")
                control_fd = os.open(control_path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
            except OSError as exc:
                print(f"Error: the operation registry could not be created: {exc}", file=sys.stderr)
                result = "registry-error"
                exit_status = 1
            else:
                current_repository_directory_fd = None
                try:
                    (
                        current_repository_topology,
                        current_repository_identity,
                        current_repository_directory_fd,
                    ) = inspect_repository_destination()
                    topology_is_stable = (
                        current_repository_topology[: len(initial_repository_topology)]
                        == initial_repository_topology
                    )
                    destination_is_stable = (
                        current_repository_identity == initial_repository_identity
                    )
                    if not topology_is_stable or not destination_is_stable:
                        result = "destination-changed"
                        exit_status = 1
                    elif initial_repository_identity is not None:
                        repository_directory_fd = initial_repository_directory_fd
                        initial_repository_directory_fd = None
                        write_status(
                            repository_identity_path,
                            f"{initial_repository_identity[0]}:{initial_repository_identity[1]}",
                        )
                        result = "acquired-existing"
                    else:
                        try:
                            os.mkdir(temporary_clone_path, mode=0o700)
                            temporary_clone = temporary_clone_path
                        except OSError as exc:
                            print(f"Error: a temporary clone directory could not be created: {exc}", file=sys.stderr)
                            result = "clone-error"
                            exit_status = 1
                        else:
                            result = "acquired-new"
                except OSError as exc:
                    print(f"Error: the repository destination changed after locking: {exc}", file=sys.stderr)
                    result = "destination-changed"
                    exit_status = 1
                finally:
                    if current_repository_directory_fd is not None:
                        with contextlib.suppress(OSError):
                            os.close(current_repository_directory_fd)

    if not parent_is_setup():
        raise SystemExit(0)
    write_status(status_path, result)
    while parent_is_setup() and not stop_requested:
        if os.path.exists(config_guard_acquire_request_path):
            with contextlib.suppress(OSError):
                os.unlink(config_guard_acquire_request_path)
            config_guard_result = (
                "locked" if acquire_repository_config_guard() else "error"
            )
            with contextlib.suppress(OSError):
                os.unlink(config_guard_acquire_result_path)
            try:
                write_status(config_guard_acquire_result_path, config_guard_result)
            except OSError:
                pass
        if os.path.exists(config_guard_release_request_path):
            with contextlib.suppress(OSError):
                os.unlink(config_guard_release_request_path)
            config_guard_result = (
                "released"
                if remove_repository_config_guard()
                else "error"
            )
            with contextlib.suppress(OSError):
                os.unlink(config_guard_release_result_path)
            try:
                write_status(config_guard_release_result_path, config_guard_result)
            except OSError:
                pass
        if os.path.exists(fetch_ref_cleanup_request_path):
            with contextlib.suppress(OSError):
                os.unlink(fetch_ref_cleanup_request_path)
            cleanup_result = "removed" if remove_temporary_fetch_ref() else "error"
            with contextlib.suppress(OSError):
                os.unlink(fetch_ref_cleanup_result_path)
            try:
                write_status(fetch_ref_cleanup_result_path, cleanup_result)
            except OSError:
                pass
        if not publication_attempted and os.path.exists(publish_request_path):
            publication_attempted = True
            if not pause_before_publish_for_test():
                break
            if rename_no_replace():
                # publish 後は helper の一時 clone 所有権を解除する。
                temporary_clone = None
                publish_result = "published"
            else:
                publish_result = "publish-error"
                exit_status = 1
            write_status(publish_result_path, publish_result)
        time.sleep(0.05)
finally:
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    try:
        with open(cleanup_started_path, "x", encoding="utf-8"):
            pass
    except OSError:
        pass
    operations_stopped = False
    try:
        operations_stopped = stop_registered_operations()
        if not operations_stopped:
            print("Warning: supervised operations did not stop completely.", file=sys.stderr)
            exit_status = 1
    except Exception as exc:
        print(f"Warning: supervised operations could not be fully stopped: {exc}", file=sys.stderr)
        exit_status = 1
    if operations_stopped:
        try:
            if not remove_repository_config_guard():
                print("Warning: repository configuration guard cleanup was incomplete.", file=sys.stderr)
                exit_status = 1
        except Exception as exc:
            print(f"Warning: repository configuration guard cleanup failed unexpectedly: {exc}", file=sys.stderr)
            exit_status = 1
        try:
            if not remove_validation_artifacts():
                print("Warning: validation artifact cleanup was incomplete.", file=sys.stderr)
                exit_status = 1
        except Exception as exc:
            print(f"Warning: validation index cleanup failed unexpectedly: {exc}", file=sys.stderr)
            exit_status = 1
        try:
            if not remove_temporary_fetch_ref():
                print("Warning: the temporary fetched ref could not be removed.", file=sys.stderr)
                exit_status = 1
        except Exception as exc:
            print(f"Warning: temporary fetched ref cleanup failed unexpectedly: {exc}", file=sys.stderr)
            exit_status = 1
        try:
            if not remove_temporary_clone():
                exit_status = 1
        except Exception as exc:
            print(f"Warning: temporary clone cleanup failed unexpectedly: {exc}", file=sys.stderr)
            exit_status = 1
        for path in (
            status_path,
            publish_request_path,
            publish_result_path,
            repository_path_path,
            repository_identity_path,
            temporary_clone_path_path,
            fetch_ref_cleanup_request_path,
            fetch_ref_cleanup_result_path,
            config_guard_acquire_request_path,
            config_guard_acquire_result_path,
            config_guard_release_request_path,
            config_guard_release_result_path,
        ):
            try:
                os.unlink(path)
            except OSError:
                pass
    operations_directory = os.path.join(state_directory, "operations")
    if operations_stopped and operations_directory_created:
        try:
            for name in os.listdir(operations_directory):
                try:
                    os.unlink(os.path.join(operations_directory, name))
                except OSError:
                    pass
            os.rmdir(operations_directory)
        except OSError:
            pass
    if operations_stopped:
        for name in ("shutdown", "control"):
            try:
                os.unlink(os.path.join(state_directory, name))
            except OSError:
                pass
    if control_fd is not None:
        with contextlib.suppress(OSError):
            os.close(control_fd)
    for repository_fd in (
        repository_directory_fd,
        initial_repository_directory_fd,
    ):
        if repository_fd is not None:
            with contextlib.suppress(OSError):
                os.close(repository_fd)
    if operations_stopped and state_directory_created:
        try:
            os.rmdir(state_directory)
        except OSError as exc:
            print(f"Warning: the repository supervisor state directory could not be removed: {exc}", file=sys.stderr)
            exit_status = 1
    if operations_stopped:
        for directory in reversed(created_parent_directories):
            try:
                os.rmdir(directory)
            except OSError:
                pass
    for lock_fd in lock_fds:
        with contextlib.suppress(OSError):
            os.close(lock_fd)

    try:
        with open(cleanup_complete_path, "x", encoding="utf-8"):
            pass
        while parent_is_setup() and not os.path.exists(cleanup_ack_path):
            time.sleep(0.01)
    except OSError:
        pass
    for path in (cleanup_started_path, cleanup_complete_path, cleanup_ack_path):
        with contextlib.suppress(OSError):
            os.unlink(path)

raise SystemExit(exit_status)
PY
REPOSITORY_SUPERVISOR_PID=$!

SUPERVISOR_START_ATTEMPTS=0
while [ ! -s "$SUPERVISOR_STATUS" ]; do
  if ! repository_supervisor_is_live "$REPOSITORY_SUPERVISOR_PID"; then
    wait "$REPOSITORY_SUPERVISOR_PID" 2>/dev/null || true
    REPOSITORY_SUPERVISOR_PID=
    integrity_error "the repository supervisor failed."
  fi
  SUPERVISOR_START_ATTEMPTS=$((SUPERVISOR_START_ATTEMPTS + 1))
  if [ "$SUPERVISOR_START_ATTEMPTS" -ge 1000 ]; then
    integrity_error "the repository supervisor did not become ready."
  fi
  sleep 0.01
done
if ! IFS= read -r SUPERVISOR_RESULT <"$SUPERVISOR_STATUS"; then
  integrity_error "the repository supervisor status could not be read."
fi
if ! FIXED_REPOSITORY_OUTPUT=$(
  cat "$SUPERVISOR_REPOSITORY_PATH"
  printf .
) ||
  ! FIXED_CLONE_OUTPUT=$(
    cat "$SUPERVISOR_TEMPORARY_CLONE_PATH"
    printf .
  ); then
  integrity_error "the fixed repository destination could not be read."
fi
REPOSITORY_DIR=${FIXED_REPOSITORY_OUTPUT%.}
SUPERVISOR_TEMPORARY_CLONE=${FIXED_CLONE_OUTPUT%.}
case "$SUPERVISOR_RESULT" in
acquired-existing)
  if [ ! -s "$SUPERVISOR_REPOSITORY_IDENTITY" ]; then
    integrity_error "the repository destination identity was not recorded."
  fi
  ;;
acquired-new)
  TEMPORARY_CLONE=$SUPERVISOR_TEMPORARY_CLONE
  ;;
busy)
  release_repository_supervisor
  integrity_error "another Agent Skills setup is already updating the configured repository destination."
  ;;
clone-error)
  release_repository_supervisor
  integrity_error "a temporary clone directory could not be created."
  ;;
destination-changed)
  release_repository_supervisor
  integrity_error "the repository destination changed after the setup lock was acquired."
  ;;
*)
  release_repository_supervisor
  integrity_error "the Agent Skills repository setup lock could not be acquired."
  ;;
esac

if [ "$SUPERVISOR_RESULT" = "acquired-existing" ]; then
  if ! IFS= read -r EXPECTED_REPOSITORY_IDENTITY <"$SUPERVISOR_REPOSITORY_IDENTITY"; then
    integrity_error "the repository destination identity could not be read."
  fi
  if ! (
    cd / &&
      python3 -I -S -c '
import os
import stat
import sys

expected_identity, repository_path = sys.argv[1:]
path_status = os.stat(repository_path, follow_symlinks=False)
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(repository_path, flags)
try:
    opened_status = os.fstat(descriptor)
finally:
    os.close(descriptor)
actual_identity = f"{opened_status.st_dev}:{opened_status.st_ino}"
raise SystemExit(
    0
    if (
        stat.S_ISDIR(path_status.st_mode)
        and (path_status.st_dev, path_status.st_ino)
        == (opened_status.st_dev, opened_status.st_ino)
        and actual_identity == expected_identity
    )
    else 1
)
' "$EXPECTED_REPOSITORY_IDENTITY" "$REPOSITORY_DIR"
  ); then
    integrity_error "the repository destination changed after the setup lock was acquired."
  fi
  if ! cd -P "$REPOSITORY_DIR"; then
    integrity_error "the repository destination disappeared after the setup lock was acquired."
  fi
  REPOSITORY_ROOT=.
  if [ ! -e "$REPOSITORY_ROOT/.git" ]; then
    integrity_error "the configured repository directory exists but is not a Git working tree."
  fi

  validate_repository_checkout "$REPOSITORY_ROOT"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ ! -x "$REPOSITORY_ROOT/bin/agent-skills" ]; then
      integrity_error "the repository does not contain an executable management CLI."
    fi
    printf '%s\n' 'Agent Skills repository integrity check passed.'
    exit 0
  fi
  record_repository_update_snapshot "$REPOSITORY_ROOT"
  if ! acquire_repository_config_guard; then
    integrity_error "the repository-local configuration could not be locked before the update was prepared."
  fi
  if [ -n "${AGENT_SKILLS_INTERNAL_TEST_CONFIG_GUARD_MARKER-}" ] &&
    [ -n "${AGENT_SKILLS_INTERNAL_TEST_CONFIG_GUARD_GATE-}" ]; then
    : >"$AGENT_SKILLS_INTERNAL_TEST_CONFIG_GUARD_MARKER"
    while [ ! -e "$AGENT_SKILLS_INTERNAL_TEST_CONFIG_GUARD_GATE" ]; do
      sleep 0.01
    done
  fi

  # local / worktree guard 後に再検証し、可変な system / global 設定を無効化する。
  verify_repository_update_snapshot "$REPOSITORY_ROOT"
  isolate_repository_update_configuration
  record_repository_update_critical_snapshot "$REPOSITORY_ROOT"

  validate_single_origin_url "$REPOSITORY_ROOT"
  verify_effective_repository_url origin -C "$REPOSITORY_ROOT"
  if REMOTE_REF_OUTPUT=$(run_git -C "$REPOSITORY_ROOT" ls-remote \
    --upload-pack=git-upload-pack origin "$UPSTREAM_REF" 2>/dev/null); then
    :
  else
    GIT_STATUS=$?
    handle_remote_git_failure "$GIT_STATUS"
  fi
  if [ -z "$REMOTE_REF_OUTPUT" ]; then
    integrity_error "the tracked origin branch does not exist in the expected Agent Skills repository."
  fi

  TEMPORARY_FETCH_REF=refs/agent-skills/setup/$SUPERVISOR_SUFFIX
  validate_single_origin_url "$REPOSITORY_ROOT"
  verify_effective_repository_url origin -C "$REPOSITORY_ROOT"
  if run_git -C "$REPOSITORY_ROOT" fetch --no-tags --no-recurse-submodules \
    --no-write-fetch-head --refmap= --upload-pack=git-upload-pack origin \
    "$UPSTREAM_REF:$TEMPORARY_FETCH_REF"; then
    :
  else
    GIT_STATUS=$?
    case "$GIT_STATUS" in
    "$RUN_GIT_TIMEOUT_STATUS")
      integrity_error "Git fetch timed out; repository integrity cannot be guaranteed, so profile synchronization was not attempted."
      ;;
    "$RUN_GIT_INFRASTRUCTURE_STATUS") integrity_error "Git operation monitoring failed." ;;
    "$RUN_GIT_GIT_FAILURE_STATUS")
      integrity_error "Git fetch failed after it started; repository integrity must be checked before retrying."
      ;;
    *) integrity_error "Git fetch was interrupted; repository integrity must be checked before retrying." ;;
    esac
  fi

  if [ -n "${AGENT_SKILLS_INTERNAL_TEST_FETCH_MARKER-}" ] &&
    [ -n "${AGENT_SKILLS_INTERNAL_TEST_FETCH_GATE-}" ]; then
    : >"$AGENT_SKILLS_INTERNAL_TEST_FETCH_MARKER"
    while [ ! -e "$AGENT_SKILLS_INTERNAL_TEST_FETCH_GATE" ]; do
      sleep 0.01
    done
  fi

  if ! FETCHED_HEAD=$(run_git -C "$REPOSITORY_ROOT" rev-parse --verify \
    "$TEMPORARY_FETCH_REF^{commit}" 2>/dev/null) ||
    ! FETCHED_TREE=$(run_git -C "$REPOSITORY_ROOT" rev-parse --verify "$FETCHED_HEAD^{tree}" 2>/dev/null); then
    integrity_error "the fetched origin branch could not be resolved to a commit and tree."
  fi
  validate_repository_tree "$REPOSITORY_ROOT" "$FETCHED_TREE" policy
  verify_repository_update_critical_snapshot "$REPOSITORY_ROOT"
  if [ -n "${AGENT_SKILLS_INTERNAL_TEST_CONFIG_RECHECK_MARKER-}" ] &&
    [ -n "${AGENT_SKILLS_INTERNAL_TEST_CONFIG_RECHECK_GATE-}" ]; then
    : >"$AGENT_SKILLS_INTERNAL_TEST_CONFIG_RECHECK_MARKER"
    while [ ! -e "$AGENT_SKILLS_INTERNAL_TEST_CONFIG_RECHECK_GATE" ]; do
      sleep 0.01
    done
  fi
  verify_repository_update_critical_snapshot "$REPOSITORY_ROOT"
  if ! run_git -C "$REPOSITORY_ROOT" merge-base --is-ancestor "$INITIAL_HEAD" "$FETCHED_HEAD"; then
    integrity_error "the verified origin branch cannot fast-forward the current branch."
  fi
  if ! GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="branch.$INITIAL_BRANCH.mergeOptions" \
    GIT_CONFIG_VALUE_0=--no-strategy \
    run_git \
    -C "$REPOSITORY_ROOT" merge --strategy=ort \
    --ff-only --no-squash --no-autostash --no-overwrite-ignore \
    --no-stat --no-edit --no-verify --no-gpg-sign "$FETCHED_HEAD"; then
    integrity_error "the repository could not be fast-forwarded without overwriting local data."
  fi

  validate_repository_checkout "$REPOSITORY_ROOT"
  if ! UPDATED_HEAD=$(run_git -C "$REPOSITORY_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
    ! UPDATED_TREE=$(run_git -C "$REPOSITORY_ROOT" rev-parse --verify 'HEAD^{tree}' 2>/dev/null) ||
    [ "$UPDATED_HEAD" != "$FETCHED_HEAD" ] ||
    [ "$UPDATED_TREE" != "$FETCHED_TREE" ]; then
    integrity_error "the updated HEAD, index, and working tree do not match the fetched origin commit."
  fi

  if ! remove_temporary_fetch_ref; then
    integrity_error "the temporary fetched ref could not be removed."
  fi
  if ! release_repository_config_guard; then
    integrity_error "the repository-local configuration guard could not be released after the update was verified."
  fi
  restore_repository_update_configuration

  if [ ! -x "$REPOSITORY_ROOT/bin/agent-skills" ]; then
    integrity_error "the repository does not contain an executable management CLI."
  fi

  synchronize_agent_skills
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  integrity_error "the configured Agent Skills repository does not exist."
fi

if [ -e "$REPOSITORY_DIR" ] || [ -L "$REPOSITORY_DIR" ]; then
  integrity_error "the repository destination appeared after the setup lock was acquired; refusing to overwrite it."
fi

verify_effective_repository_url "$REPOSITORY_URL"
if run_git ls-remote --upload-pack=git-upload-pack "$REPOSITORY_URL" HEAD >/dev/null 2>&1; then
  :
else
  GIT_STATUS=$?
  handle_remote_git_failure "$GIT_STATUS"
fi

verify_effective_repository_url "$REPOSITORY_URL"
if run_git clone --quiet --origin origin --no-recurse-submodules --no-checkout \
  --upload-pack=git-upload-pack "$REPOSITORY_URL" "$TEMPORARY_CLONE" >/dev/null 2>&1; then
  :
else
  GIT_STATUS=$?
  handle_transfer_git_failure "$GIT_STATUS"
  verify_effective_repository_url "$REPOSITORY_URL"
  if run_git ls-remote --upload-pack=git-upload-pack "$REPOSITORY_URL" HEAD >/dev/null 2>&1; then
    :
  else
    GIT_STATUS=$?
    handle_remote_git_failure "$GIT_STATUS"
  fi
  integrity_error "Git clone failed while the repository remained accessible."
fi

if ! resolve_physical_directory "$TEMPORARY_CLONE"; then
  integrity_error "the temporary clone cannot be resolved."
fi
REPOSITORY_ROOT=$RESOLVED_PHYSICAL_DIRECTORY
validate_repository_checkout "$REPOSITORY_ROOT" configuration-only
if ! CLONED_TREE=$(run_git -C "$REPOSITORY_ROOT" rev-parse --verify 'HEAD^{tree}' 2>/dev/null); then
  integrity_error "the cloned repository HEAD tree could not be resolved."
fi
validate_repository_tree "$REPOSITORY_ROOT" "$CLONED_TREE" policy
if ! run_git -C "$REPOSITORY_ROOT" reset --hard --quiet HEAD; then
  integrity_error "the validated cloned repository could not be checked out."
fi
validate_repository_checkout "$REPOSITORY_ROOT"

if [ ! -x "$REPOSITORY_ROOT/bin/agent-skills" ]; then
  integrity_error "the cloned repository does not contain an executable management CLI."
fi

if ! (cd "$REPOSITORY_ROOT" && run_management_cli ./bin/agent-skills validate); then
  integrity_error "the cloned Agent Skills repository failed validation."
fi

if [ -e "$REPOSITORY_DIR" ] || [ -L "$REPOSITORY_DIR" ]; then
  integrity_error "the repository destination appeared during clone; refusing to overwrite it."
fi

if ! : >"$PUBLISH_REQUEST"; then
  integrity_error "the validated repository could not be queued for publication."
fi
PUBLISH_WAIT_ATTEMPTS=0
while [ ! -s "$PUBLISH_RESULT" ]; do
  if ! repository_supervisor_is_live "$REPOSITORY_SUPERVISOR_PID"; then
    wait "$REPOSITORY_SUPERVISOR_PID" 2>/dev/null || true
    REPOSITORY_SUPERVISOR_PID=
    integrity_error "the repository supervisor failed during publication."
  fi
  PUBLISH_WAIT_ATTEMPTS=$((PUBLISH_WAIT_ATTEMPTS + 1))
  if [ "$PUBLISH_WAIT_ATTEMPTS" -ge 1000 ]; then
    integrity_error "the repository supervisor did not publish the validated repository."
  fi
  sleep 0.01
done
if ! IFS= read -r PUBLISH_RESULT_STATUS <"$PUBLISH_RESULT"; then
  integrity_error "the repository publication status could not be read."
fi
if [ "$PUBLISH_RESULT_STATUS" != "published" ]; then
  integrity_error "the validated repository could not be moved into place."
fi
TEMPORARY_CLONE=

if ! resolve_physical_directory "$REPOSITORY_DIR"; then
  integrity_error "the cloned repository cannot be resolved."
fi
REPOSITORY_ROOT=$RESOLVED_PHYSICAL_DIRECTORY
cd "$REPOSITORY_ROOT" || integrity_error "the cloned repository cannot be entered."
synchronize_agent_skills
