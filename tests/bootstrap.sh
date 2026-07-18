#!/bin/sh

set -u

REPOSITORY_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
BOOTSTRAP_SCRIPT=$REPOSITORY_ROOT/bootstrap.sh

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-tests.XXXXXX") || exit 1
trap 'rm -rf "$TEST_ROOT"' 0
trap 'exit 1' HUP INT TERM

FAKE_BIN=$TEST_ROOT/bin
KEEPALIVE_RUNNER=$TEST_ROOT/keepalive-runner.sh
FD_RUNNER=$TEST_ROOT/fd-inheritance-runner.sh
PRIVILEGED_FAILURE_RUNNER=$TEST_ROOT/privileged-failure-runner.sh
PID_REUSE_RUNNER=$TEST_ROOT/pid-reuse-runner.sh
STARTUP_RUNNER=$TEST_ROOT/startup-runner.sh
WRAPPER_RACE_RUNNER=$TEST_ROOT/wrapper-race-runner.sh
REQUEST_ONCE_RUNNER=$TEST_ROOT/request-once-runner.sh
KEEPALIVE_FAILURE_RUNNER=$TEST_ROOT/keepalive-failure-runner.sh
HOMEBREW_PATH_RUNNER=$TEST_ROOT/homebrew-path-runner.sh
HOMEBREW_RESOLUTION_RUNNER=$TEST_ROOT/homebrew-resolution-runner.sh
IDENTITY_RUNNER=$TEST_ROOT/identity-runner.sh
PTY_RUNNER=$TEST_ROOT/foreground-pty-runner.sh
PYTHON3=$(command -v python3 2>/dev/null || true)
TEST_FILTER=${BOOTSTRAP_TEST_FILTER-}
TEST_FILTER_MATCHED=0

mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/sleep" <<'EOF'
#!/bin/sh

if [ "${1-}" = "50" ]; then
    if [ -n "${FAKE_SLEEP_FAILURE_STARTED-}" ]; then
        : >"$FAKE_SLEEP_FAILURE_STARTED"
    fi
    if [ -n "${FAKE_SLEEP_BLOCK_GATE-}" ]; then
        printf '%s\n' "$$" >"${FAKE_SLEEP_BLOCK_PID:?}"
        trap 'if [ -n "${FAKE_SLEEP_STOPPED_MARKER-}" ]; then : >"$FAKE_SLEEP_STOPPED_MARKER"; fi; exit 143' HUP INT TERM
        while [ ! -e "$FAKE_SLEEP_BLOCK_GATE" ]; do
            /bin/sleep 0.01
        done
    fi
    sleep_status=${FAKE_SLEEP_STATUS-0}
    if [ "$sleep_status" -ne 0 ] && [ -n "${FAKE_KEEPALIVE_FAILURE_GATE-}" ]; then
        while [ ! -e "$FAKE_KEEPALIVE_FAILURE_GATE" ]; do
            /bin/sleep 0.01
        done
    fi
    exit "$sleep_status"
fi
exec /bin/sleep "$@"
EOF

cat >"$FAKE_BIN/sudo" <<'EOF'
#!/bin/sh

if [ "${1-}" = "-n" ] && [ "${2-}" = "-v" ]; then
    if [ "${FAKE_SUDO_AUTHENTICATION_ONLY-}" = "1" ]; then
        printf '%s\n' authenticate >>"$FAKE_SUDO_EVENTS"
        exit 0
    fi
    printf '%s\n' "$$" >"$FAKE_SUDO_KEEPALIVE_PID"
    : >"$FAKE_SUDO_KEEPALIVE_STARTED"
    if [ "$FAKE_SUDO_REFRESH_STATUS" -ne 0 ]; then
        if [ -n "${FAKE_KEEPALIVE_FAILURE_GATE-}" ]; then
            while [ ! -e "$FAKE_KEEPALIVE_FAILURE_GATE" ]; do
                /bin/sleep 0.01
            done
        fi
        exit "$FAKE_SUDO_REFRESH_STATUS"
    fi
    trap 'exit 143' HUP INT TERM
    while [ ! -e "$FAKE_SUDO_KEEPALIVE_GATE" ]; do
        /bin/sleep 0.01
    done
    printf '%s\n' refresh >>"$FAKE_SUDO_EVENTS"
    exit 0
fi

if [ "${1-}" = "-k" ]; then
    if [ -n "${FAKE_SUDO_WORKER_REAPED_FILE-}" ] && [ ! -e "$FAKE_SUDO_WORKER_REAPED_FILE" ]; then
        printf '%s\n' invalidate-before-worker-reap >>"$FAKE_SUDO_EVENTS"
    fi
    if [ -s "$FAKE_SUDO_KEEPALIVE_PID" ]; then
        IFS= read -r keepalive_pid <"$FAKE_SUDO_KEEPALIVE_PID"
        if kill -0 "$keepalive_pid" 2>/dev/null; then
            printf '%s\n' invalidate-while-child-alive >>"$FAKE_SUDO_EVENTS"
        fi
    fi
    printf '%s\n' invalidate >>"$FAKE_SUDO_EVENTS"
    : >"$FAKE_SUDO_KEEPALIVE_GATE"
    exit 0
fi

exit 1
EOF
chmod +x "$FAKE_BIN/sleep" "$FAKE_BIN/sudo"

cat >"$FAKE_BIN/long-command" <<'EOF'
#!/bin/sh

if (: >&9) 2>/dev/null; then
    printf '%s\n' inherited >"$FAKE_LONG_COMMAND_FD_STATE"
else
    printf '%s\n' closed >"$FAKE_LONG_COMMAND_FD_STATE"
fi
printf '%s\n' "$$" >"$FAKE_LONG_COMMAND_PID"
: >"$FAKE_LONG_COMMAND_STARTED"
trap 'if [ -n "${FAKE_LONG_COMMAND_STOPPED_MARKER-}" ]; then : >"$FAKE_LONG_COMMAND_STOPPED_MARKER"; fi; exit 143' HUP INT TERM
while [ ! -e "$FAKE_LONG_COMMAND_GATE" ]; do
    /bin/sleep 0.01
done
EOF
chmod +x "$FAKE_BIN/long-command"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
exercise_sudo_keepalive() {
printf '%s\n' "$sudo_keepalive_pid" >"$FAKE_SUDO_WORKER_PID"
printf '%s\n' "$sudo_keepalive_sentinel_pid" >"$FAKE_SUDO_HELPER_PID"
attempts=0
while [[ ! -e "$FAKE_SUDO_KEEPALIVE_STARTED" && "$attempts" -lt 200 ]]; do
  /bin/sleep 0.01
  attempts=$((attempts + 1))
done
if [[ ! -e "$FAKE_SUDO_KEEPALIVE_STARTED" ]]; then
  printf 'keep-alive sudo did not start\n' >&2
  exit 1
fi

if [[ "$FAKE_SUDO_PARENT_DEATH_TEST" == 1 && "$FAKE_SUDO_REFRESH_STATUS" -eq 0 ]]; then
  : >"$FAKE_SUDO_PARENT_DEATH_READY"
  while true; do
    /bin/sleep 1
  done
fi

if [[ "$FAKE_SUDO_REFRESH_STATUS" -ne 0 ]]; then
  IFS= read -r refresh_pid <"$FAKE_SUDO_KEEPALIVE_PID"
  attempts=0
  while kill -0 "$refresh_pid" 2>/dev/null && [[ "$attempts" -lt 200 ]]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$refresh_pid" 2>/dev/null; then
    printf 'failed keep-alive refresh did not exit\n' >&2
    exit 1
  fi
  if ! kill -0 "$sudo_keepalive_pid" 2>/dev/null; then
    printf 'keep-alive group leader did not reserve its PGID after refresh failure\n' >&2
    exit 1
  fi

  attempts=0
  while [[ ! -s "$FAKE_SUDO_RESERVATION_PID" && "$attempts" -lt 200 ]]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [[ ! -s "$FAKE_SUDO_RESERVATION_PID" ]]; then
    printf 'keep-alive reservation sleep did not start\n' >&2
    exit 1
  fi

  if [[ "$FAKE_SUDO_PARENT_DEATH_TEST" == 1 ]]; then
    : >"$FAKE_SUDO_PARENT_DEATH_READY"
    while true; do
      /bin/sleep 1
    done
  fi
fi

stop_sudo_keepalive
trap - EXIT
/bin/sleep 0.2
}

exercise_sudo_keepalive
EOF
} >"$KEEPALIVE_RUNNER"
chmod +x "$KEEPALIVE_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  cat <<'EOF'
run_bootstrap_privileged_setup() {
  "$FAKE_BIN/long-command"
}
EOF
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
printf '%s\n' "$sudo_keepalive_pid" >"$FAKE_SUDO_WORKER_PID"
printf '%s\n' "$sudo_keepalive_sentinel_pid" >"$FAKE_SUDO_HELPER_PID"
run_bootstrap_setup_with_keepalive
EOF
} >"$FD_RUNNER"
chmod +x "$FD_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  cat <<'EOF'
run_bootstrap_privileged_setup() {
  /bin/false
  : >"$FAKE_PRIVILEGED_AFTER_FAILURE"
}
EOF
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
set +e
run_bootstrap_setup_with_keepalive
privileged_status=$?
set -e
stop_sudo_keepalive
trap - EXIT
if [[ "$privileged_status" -eq 0 || -e "$FAKE_PRIVILEGED_AFTER_FAILURE" ]]; then
  printf 'privileged setup did not stop at its first failure\n' >&2
  exit 1
fi
EOF
} >"$PRIVILEGED_FAILURE_RUNNER"
chmod +x "$PRIVILEGED_FAILURE_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  cat <<'EOF'
kill() {
  if [[ "${1-}" == -KILL && -s "$FAKE_SUDO_REAPED_PID" && -s "$FAKE_REUSED_PID_VICTIM" ]]; then
    IFS= read -r reaped_pid <"$FAKE_SUDO_REAPED_PID"
    if [[ "${2-}" == "$reaped_pid" ]]; then
      IFS= read -r victim_pid <"$FAKE_REUSED_PID_VICTIM"
      printf '%s\n' "$reaped_pid" >"$FAKE_STALE_CHILD_SIGNAL"
      builtin kill -KILL "$victim_pid"
      return
    fi
  fi
  builtin kill "$@"
}
EOF
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
printf '%s\n' "$sudo_keepalive_pid" >"$FAKE_SUDO_WORKER_PID"
printf '%s\n' "$sudo_keepalive_sentinel_pid" >"$FAKE_SUDO_HELPER_PID"
(
  exec 9>&-
  exec /bin/sleep 30
) &
victim_pid=$!
printf '%s\n' "$victim_pid" >"$FAKE_REUSED_PID_VICTIM"
while [[ ! -s "$FAKE_SUDO_REAPED_PID" ]]; do
  :
done
: >"$FAKE_SUDO_PARENT_DEATH_READY"
while true; do
  /bin/sleep 1
done
EOF
} >"$PID_REUSE_RUNNER"
chmod +x "$PID_REUSE_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  printf '%s\n' "printf 'startup unexpectedly completed\\n' >&2" 'exit 1'
} >"$STARTUP_RUNNER"
chmod +x "$STARTUP_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
printf '%s\n' "$sudo_keepalive_pid" >"$FAKE_SUDO_WORKER_PID"
printf '%s\n' "$sudo_keepalive_sentinel_pid" >"$FAKE_SUDO_HELPER_PID"
: >"$FAKE_SUDO_WRAPPER_RACE_READY"
while [[ ! -e "$FAKE_SUDO_WRAPPER_RACE_RELEASE" ]]; do
  /bin/sleep 0.01
done
stop_sudo_keepalive
trap - EXIT
EOF
} >"$WRAPPER_RACE_RUNNER"
chmod +x "$WRAPPER_RACE_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  cat <<'EOF'
run_bootstrap_privileged_setup() {
  printf '%s\n' invoked >>"$FAKE_PRIVILEGED_INVOCATIONS"
  if [[ ! -e "$FAKE_PRIVILEGED_STARTED" ]]; then
    : >"$FAKE_PRIVILEGED_STARTED"
    while [[ ! -e "$FAKE_PRIVILEGED_GATE" ]]; do
      /bin/sleep 0.01
    done
  fi
}
EOF
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
run_bootstrap_setup_with_keepalive
stop_sudo_keepalive
trap - EXIT
EOF
} >"$REQUEST_ONCE_RUNNER"
chmod +x "$REQUEST_ONCE_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  cat <<'EOF'
run_bootstrap_privileged_setup() {
  "$FAKE_BIN/long-command"
}
EOF
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
set +e
run_bootstrap_setup_with_keepalive
setup_status=$?
set -e
printf '%s\n' "$setup_status" >"$FAKE_KEEPALIVE_SETUP_STATUS"
stop_sudo_keepalive
trap - EXIT
[[ "$setup_status" -ne 0 ]]
EOF
} >"$KEEPALIVE_FAILURE_RUNNER"
chmod +x "$KEEPALIVE_FAILURE_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  sed -n '/^resolve_homebrew_executable() {/,/^}/p' "$BOOTSTRAP_SCRIPT"
  sed -n '/^refresh_homebrew_environment() {/,/^}/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
run_bootstrap_privileged_setup() {
  : >"$FAKE_HOMEBREW_INSTALLED"
  refresh_homebrew_environment
  git privileged
  python3 privileged
}
EOF
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
run_bootstrap_setup_with_keepalive
stop_sudo_keepalive
trap - EXIT
refresh_homebrew_environment
"$FAKE_AGENT_SKILLS_SETUP"
EOF
} >"$HOMEBREW_PATH_RUNNER"
chmod +x "$HOMEBREW_PATH_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  sed -n '/^resolve_homebrew_executable() {/,/^}/p' "$BOOTSTRAP_SCRIPT"
  sed -n '/^refresh_homebrew_environment() {/,/^}/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
if ! resolve_homebrew_executable; then
  : >"$FAKE_HOMEBREW_INSTALLER_MARKER"
fi
refresh_homebrew_environment
brew resolved
EOF
} >"$HOMEBREW_RESOLUTION_RUNNER"
chmod +x "$HOMEBREW_RESOLUTION_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
stop_sudo_keepalive
trap - EXIT

set -m
(
  exec /bin/sleep 30
) &
group_victim_pid=$!
set +m
/bin/sleep 30 &
process_victim_pid=$!

group_identity=$FAKE_IDENTITY_ROOT/group.identity
process_identity=$FAKE_IDENTITY_ROOT/process.identity
stale_group_identity=$FAKE_IDENTITY_ROOT/stale-group.identity
stale_process_identity=$FAKE_IDENTITY_ROOT/stale-process.identity
record_process_identity "$group_identity" "$group_victim_pid"
record_process_identity "$process_identity" "$process_victim_pid"
{
  IFS= read -r group_recorded_pid
  IFS= read -r group_recorded_pgid
  IFS= read -r _
} <"$group_identity"
{
  IFS= read -r process_recorded_pid
  IFS= read -r process_recorded_pgid
  IFS= read -r _
} <"$process_identity"
printf '%s\n%s\n%s\n' "$group_recorded_pid" "$group_recorded_pgid" stale \
  >"$stale_group_identity"
printf '%s\n%s\n%s\n' "$process_recorded_pid" "$process_recorded_pgid" stale \
  >"$stale_process_identity"

stop_recorded_process_group "$stale_group_identity"
stop_recorded_process "$stale_process_identity"
kill -0 "$group_victim_pid"
kill -0 "$process_victim_pid"

stop_recorded_process_group "$group_identity"
stop_recorded_process "$process_identity"
wait "$group_victim_pid" 2>/dev/null || true
wait "$process_victim_pid" 2>/dev/null || true
if kill -0 "$group_victim_pid" 2>/dev/null || kill -0 "$process_victim_pid" 2>/dev/null; then
  exit 1
fi

# TERM 後に identity が変わった PID / PGID へ KILL を送らない
identity_phase=before
identity_kill_log=$FAKE_IDENTITY_ROOT/identity-kill.log
: >"$identity_kill_log"
process_identity_matches_snapshot() {
  [[ "$identity_phase" == before ]]
}
process_group_matches_snapshot() {
  [[ "$identity_phase" == before ]]
}
kill() {
  case "$*" in
    '-TERM 60001'|'-TERM -- -60002')
      printf '%s\n' "$*" >>"$identity_kill_log"
      identity_phase=after
      return 0
      ;;
    '-KILL 60001'|'-KILL -- -60002')
      printf '%s\n' "$*" >>"$identity_kill_log"
      return 0
      ;;
  esac
  builtin kill "$@"
}
printf '%s\n%s\n%s\n' 60001 60003 simulated >"$process_identity"
identity_phase=before
stop_recorded_process "$process_identity"
printf '%s\n%s\n%s\n' 60002 60002 simulated >"$group_identity"
identity_phase=before
stop_recorded_process_group "$group_identity"
if ! grep -Fx -- '-TERM 60001' "$identity_kill_log" >/dev/null 2>&1 ||
  ! grep -Fx -- '-TERM -- -60002' "$identity_kill_log" >/dev/null 2>&1 ||
  grep -F -- '-KILL' "$identity_kill_log" >/dev/null 2>&1; then
  exit 1
fi
EOF
} >"$IDENTITY_RUNNER"
chmod +x "$IDENTITY_RUNNER"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  cat <<'EOF'
run_bootstrap_privileged_setup() {
  case "${PTY_TEST_MODE:?}" in
    interactive)
      trap - TSTP
      setup_pgid=$(LC_ALL=C /bin/ps -o pgid= -p "$$" | tr -d ' ')
      setup_tpgid=$(LC_ALL=C /bin/ps -o tpgid= -p "$$" | tr -d ' ')
      printf '%s\n%s\n%s\n' "$$" "$setup_pgid" "$setup_tpgid" \
        >"$PTY_SETUP_IDENTITY_FILE"
      IFS= read -r pty_input </dev/tty
      printf '%s\n' "$pty_input" >"$PTY_TTY_READ_FILE"
      while [[ ! -e "$PTY_RELEASE_GATE" ]]; do
        /bin/sleep 0.01
      done
      ;;
    shared-peer)
      : >"$PTY_PAYLOAD_STARTED_FILE"
      while [[ ! -e "$PTY_RELEASE_GATE" ]]; do
        /bin/sleep 0.01
      done
      ;;
    stopped-wrapper)
      : >"$PTY_PAYLOAD_STARTED_FILE"
      while [[ ! -e "$PTY_RELEASE_GATE" ]]; do
        /bin/sleep 0.01
      done
      ;;
    *)
      exit 125
      ;;
  esac
}
EOF
  cat <<'EOF'
while [[ ! -e "$PTY_SUPERVISOR_READY_GATE" ]]; do
  /bin/sleep 0.01
done
if [[ "${PTY_SHARED_GROUP_PEER:-}" == 1 ]]; then
  /bin/sleep 50 &
  pty_shared_group_peer_pid=$!
  printf '%s\n' "$pty_shared_group_peer_pid" >"$PTY_SHARED_GROUP_PEER_PID_FILE"
fi
EOF
  sed -n '/^sudo_keepalive_pid=$/,/^set +m$/p' "$BOOTSTRAP_SCRIPT"
  cat <<'EOF'
runner_pgid=$(LC_ALL=C /bin/ps -o pgid= -p "$$" | tr -d ' ')
printf '%s\n%s\n' "$$" "$runner_pgid" >"$PTY_RUNNER_IDENTITY_FILE"
printf '%s\n' "$sudo_keepalive_setup_foreground_mode" >"$PTY_FOREGROUND_MODE_FILE"
if [[ "${PTY_TEST_MODE:?}" == shared-peer ]]; then
  set +e
  run_bootstrap_setup_with_keepalive
  runner_status=$?
  printf '%s\n' "$runner_status" >"$PTY_SHARED_RUNNER_STATUS_FILE"
  while [[ ! -e "$PTY_SHARED_AFTER_FAILURE_GATE" ]]; do
    /bin/sleep 0.01
  done
  set -e
  stop_sudo_keepalive
  trap - EXIT
  exit "$runner_status"
fi
run_bootstrap_setup_with_keepalive
stop_sudo_keepalive
trap - EXIT
EOF
} >"$PTY_RUNNER"
chmod +x "$PTY_RUNNER"

TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
  test_name=$1
  shift
  if [ -z "$TEST_FILTER" ] || [ "$TEST_FILTER" = "$test_name" ]; then
    TEST_FILTER_MATCHED=1
    "$@"
  fi
}

run_keepalive_case() {
  case_name=$1
  refresh_status=$2
  case_root=$TEST_ROOT/$case_name
  events=$case_root/sudo.events
  keepalive_started=$case_root/keepalive.started
  keepalive_gate=$case_root/keepalive.continue
  keepalive_pid_file=$case_root/keepalive.pid
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  worker_reaped_file=$case_root/worker.reaped
  reservation_pid_file=$case_root/reservation.pid
  parent_death_ready=$case_root/parent-death.ready
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  if ! PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED="$keepalive_started" \
    FAKE_SUDO_KEEPALIVE_GATE="$keepalive_gate" \
    FAKE_SUDO_KEEPALIVE_PID="$keepalive_pid_file" \
    FAKE_SUDO_WORKER_PID="$worker_pid_file" \
    FAKE_SUDO_HELPER_PID="$helper_pid_file" \
    FAKE_SUDO_WORKER_REAPED_FILE="$worker_reaped_file" \
    FAKE_SUDO_RESERVATION_PID="$reservation_pid_file" \
    FAKE_SUDO_PARENT_DEATH_TEST=0 \
    FAKE_SUDO_PARENT_DEATH_READY="$parent_death_ready" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_RESERVATION_PID_FILE="$reservation_pid_file" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_FILE="$worker_reaped_file" \
    FAKE_SUDO_REFRESH_STATUS="$refresh_status" \
    /bin/bash "$KEEPALIVE_RUNNER" >"$output" 2>&1; then
    echo "not ok - $case_name" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  if grep -Fx refresh "$events" >/dev/null 2>&1 ||
    grep -Fx invalidate-while-child-alive "$events" >/dev/null 2>&1 ||
    grep -Fx invalidate-before-worker-reap "$events" >/dev/null 2>&1 ||
    ! grep -Fx invalidate "$events" >/dev/null 2>&1; then
    echo "not ok - $case_name" >&2
    sed -n '1,120p' "$events" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  if kill -0 "$worker_pid" 2>/dev/null || kill -0 "$helper_pid" 2>/dev/null; then
    echo "not ok - $case_name: owned keep-alive process remains after cleanup" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_parent_death_case() {
  case_name=$1
  case_directory=$2
  refresh_status=$3
  case_root=$TEST_ROOT/$case_directory
  events=$case_root/sudo.events
  keepalive_started=$case_root/keepalive.started
  keepalive_gate=$case_root/keepalive.continue
  keepalive_pid_file=$case_root/keepalive.pid
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  reservation_pid_file=$case_root/reservation.pid
  parent_death_ready=$case_root/parent-death.ready
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED="$keepalive_started" \
    FAKE_SUDO_KEEPALIVE_GATE="$keepalive_gate" \
    FAKE_SUDO_KEEPALIVE_PID="$keepalive_pid_file" \
    FAKE_SUDO_WORKER_PID="$worker_pid_file" \
    FAKE_SUDO_HELPER_PID="$helper_pid_file" \
    FAKE_SUDO_RESERVATION_PID="$reservation_pid_file" \
    FAKE_SUDO_PARENT_DEATH_TEST=1 \
    FAKE_SUDO_PARENT_DEATH_READY="$parent_death_ready" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_RESERVATION_PID_FILE="$reservation_pid_file" \
    FAKE_SUDO_REFRESH_STATUS="$refresh_status" \
    /bin/bash "$KEEPALIVE_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while [ ! -e "$parent_death_ready" ] && kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$parent_death_ready" ]; then
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  if [ "$refresh_status" -eq 0 ]; then
    active_child_pid_file=$keepalive_pid_file
  else
    active_child_pid_file=$reservation_pid_file
  fi
  IFS= read -r active_child_pid <"$active_child_pid_file"
  kill -KILL "$runner_pid"

  attempts=0
  while { kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$active_child_pid" 2>/dev/null; } &&
    [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  wait "$runner_pid" 2>/dev/null || true

  if kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$active_child_pid" 2>/dev/null; then
    echo "not ok - $case_name: keep-alive process remains after parent SIGKILL" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_initialization_failure_case() {
  case_name='sudo keep-alive initialization failure invalidation'
  case_root=$TEST_ROOT/initialization-failure
  events=$case_root/sudo.events
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  if PATH="$FAKE_BIN:/usr/bin:/bin" \
    TMPDIR=$case_root/missing \
    FAKE_SUDO_AUTHENTICATION_ONLY=1 \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    /bin/bash "$BOOTSTRAP_SCRIPT" >"$output" 2>&1; then
    echo "not ok - $case_name: initialization unexpectedly succeeded" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  if ! grep -Fx authenticate "$events" >/dev/null 2>&1 ||
    ! grep -Fx invalidate "$events" >/dev/null 2>&1; then
    echo "not ok - $case_name: sudo timestamp was not invalidated" >&2
    sed -n '1,120p' "$events" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_setup_child_fd_case() {
  case_name='parent SIGKILL stops owned setup group and invalidates sudo'
  case_root=$TEST_ROOT/setup-child-fd
  events=$case_root/sudo.events
  keepalive_started=$case_root/keepalive.started
  keepalive_gate=$case_root/keepalive.continue
  keepalive_pid_file=$case_root/keepalive.pid
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  reservation_pid_file=$case_root/reservation.pid
  long_started=$case_root/long.started
  long_gate=$case_root/long.continue
  long_pid_file=$case_root/long.pid
  fd_state=$case_root/long.fd-state
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_BIN="$FAKE_BIN" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED="$keepalive_started" \
    FAKE_SUDO_KEEPALIVE_GATE="$keepalive_gate" \
    FAKE_SUDO_KEEPALIVE_PID="$keepalive_pid_file" \
    FAKE_SUDO_WORKER_PID="$worker_pid_file" \
    FAKE_SUDO_HELPER_PID="$helper_pid_file" \
    FAKE_SUDO_RESERVATION_PID="$reservation_pid_file" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_RESERVATION_PID_FILE="$reservation_pid_file" \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_LONG_COMMAND_STARTED="$long_started" \
    FAKE_LONG_COMMAND_GATE="$long_gate" \
    FAKE_LONG_COMMAND_PID="$long_pid_file" \
    FAKE_LONG_COMMAND_FD_STATE="$fd_state" \
    /bin/bash "$FD_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while { [ ! -e "$long_started" ] || [ ! -e "$keepalive_started" ]; } &&
    kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$long_started" ] || [ ! -e "$keepalive_started" ]; then
    : >"$long_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: runner did not become ready" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  IFS= read -r refresh_pid <"$keepalive_pid_file"
  IFS= read -r long_pid <"$long_pid_file"
  worker_pgid=$(/bin/ps -o pgid= -p "$worker_pid" 2>/dev/null)
  helper_pgid=$(/bin/ps -o pgid= -p "$helper_pid" 2>/dev/null)
  long_pgid=$(/bin/ps -o pgid= -p "$long_pid" 2>/dev/null)
  worker_pgid=$(printf '%s' "$worker_pgid" | tr -d ' ')
  helper_pgid=$(printf '%s' "$helper_pgid" | tr -d ' ')
  long_pgid=$(printf '%s' "$long_pgid" | tr -d ' ')
  if [ "$worker_pgid" != "$worker_pid" ] || [ "$helper_pgid" != "$helper_pid" ] ||
    [ "$long_pgid" != "$helper_pid" ] || [ "$worker_pgid" = "$helper_pgid" ]; then
    : >"$long_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: setup/worker process-group containment was not established" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! grep -Fx closed "$fd_state" >/dev/null 2>&1; then
    : >"$long_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: FD 9 reached the external command" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  kill -KILL "$runner_pid"
  attempts=0
  while { kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$refresh_pid" 2>/dev/null || kill -0 "$long_pid" 2>/dev/null; } &&
    [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  wait "$runner_pid" 2>/dev/null || true

  if kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$refresh_pid" 2>/dev/null || kill -0 "$long_pid" 2>/dev/null; then
    : >"$long_gate"
    echo "not ok - $case_name: owned setup or keep-alive process survived bootstrap SIGKILL" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! grep -Fx invalidate "$events" >/dev/null 2>&1; then
    echo "not ok - $case_name: helper did not invalidate the sudo timestamp" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_privileged_failure_case() {
  case_name='privileged setup preserves an early failure status'
  case_root=$TEST_ROOT/privileged-failure
  events=$case_root/sudo.events
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  if ! PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_WORKER_PID=$case_root/worker.pid \
    FAKE_SUDO_HELPER_PID=$case_root/helper.pid \
    FAKE_SUDO_RESERVATION_PID=$case_root/reservation.pid \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_PRIVILEGED_AFTER_FAILURE=$case_root/after-failure \
    /bin/bash "$PRIVILEGED_FAILURE_RUNNER" >"$output" 2>&1; then
    echo "not ok - $case_name" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_reaped_pid_reuse_case() {
  case_name='reaped keep-alive child PID reuse race'
  case_root=$TEST_ROOT/reaped-pid-reuse
  events=$case_root/sudo.events
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  reaped_pid_file=$case_root/reaped.pid
  reaped_gate=$case_root/reaped.continue
  victim_pid_file=$case_root/reused-victim.pid
  stale_signal=$case_root/stale-child.signal
  parent_ready=$case_root/parent-death.ready
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_WORKER_PID="$worker_pid_file" \
    FAKE_SUDO_HELPER_PID="$helper_pid_file" \
    FAKE_SUDO_RESERVATION_PID=$case_root/reservation.pid \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_SUDO_REAPED_PID="$reaped_pid_file" \
    FAKE_REUSED_PID_VICTIM="$victim_pid_file" \
    FAKE_STALE_CHILD_SIGNAL="$stale_signal" \
    FAKE_SUDO_PARENT_DEATH_READY="$parent_ready" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_REAPED_PID_FILE="$reaped_pid_file" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_REAPED_GATE="$reaped_gate" \
    /bin/bash "$PID_REUSE_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while [ ! -e "$parent_ready" ] && kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$parent_ready" ]; then
    : >"$reaped_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: runner did not reach the controlled race" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  IFS= read -r victim_pid <"$victim_pid_file"
  kill -KILL "$runner_pid"
  attempts=0
  while { kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null; } &&
    [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  wait "$runner_pid" 2>/dev/null || true

  if kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null; then
    : >"$reaped_gate"
    kill -KILL "$victim_pid" 2>/dev/null || true
    echo "not ok - $case_name: keep-alive helper or worker survived bootstrap SIGKILL" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if [ -e "$stale_signal" ] || ! kill -0 "$victim_pid" 2>/dev/null; then
    echo "not ok - $case_name: a reaped child PID was signaled" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  kill -KILL "$victim_pid" 2>/dev/null || true
  : >"$reaped_gate"
  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_wrapper_fork_registration_race_case() {
  case_name='keep-alive wrapper signal during fork registration'
  case_root=$TEST_ROOT/wrapper-fork-registration
  events=$case_root/sudo.events
  marker=$case_root/wrapper.forked
  gate=$case_root/wrapper.register
  wrapper_pid_file=$case_root/wrapper.pid
  ready=$case_root/runner.ready
  release=$case_root/runner.release
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_WORKER_PID="$worker_pid_file" \
    FAKE_SUDO_HELPER_PID="$helper_pid_file" \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_SUDO_WRAPPER_RACE_READY="$ready" \
    FAKE_SUDO_WRAPPER_RACE_RELEASE="$release" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_FORK_MARKER="$marker" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_FORK_GATE="$gate" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PID_FILE="$wrapper_pid_file" \
    /bin/bash "$WRAPPER_RACE_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while { [ ! -e "$marker" ] || [ ! -e "$ready" ] || [ ! -s "$worker_pid_file" ] ||
    [ ! -s "$helper_pid_file" ] || [ ! -s "$wrapper_pid_file" ]; } &&
    kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$marker" ] || [ ! -e "$ready" ] || [ ! -s "$worker_pid_file" ] ||
    [ ! -s "$helper_pid_file" ] || [ ! -s "$wrapper_pid_file" ]; then
    : >"$gate"
    : >"$release"
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: controlled fork interval was not reached" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  IFS= read -r wrapper_pid <"$wrapper_pid_file"
  kill -TERM "$worker_pid"

  attempts=0
  while kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  wrapper_survived=0
  if kill -0 "$wrapper_pid" 2>/dev/null; then
    wrapper_survived=1
  fi

  : >"$release"
  wait "$runner_pid" 2>/dev/null || true

  if [ "$wrapper_survived" -ne 0 ] || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$helper_pid" 2>/dev/null; then
    : >"$gate"
    echo "not ok - $case_name: unregistered wrapper or owner remained" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! grep -Fx invalidate "$events" >/dev/null 2>&1; then
    echo "not ok - $case_name: sudo timestamp was not invalidated" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_wrapper_prepublication_worker_sigkill_case() {
  case_name='worker cage kills a stopped unpublished wrapper'
  case_root=$TEST_ROOT/wrapper-prepublication-sigkill
  events=$case_root/sudo.events
  marker=$case_root/wrapper.unpublished
  gate=$case_root/wrapper.publish
  wrapper_pid_file=$case_root/wrapper.pid
  child_pid_file=$case_root/wrapper-child.pid
  child_gate=$case_root/wrapper-child.continue
  ready=$case_root/runner.ready
  release=$case_root/runner.release
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_WORKER_PID="$worker_pid_file" \
    FAKE_SUDO_HELPER_PID="$helper_pid_file" \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_SUDO_WRAPPER_RACE_READY="$ready" \
    FAKE_SUDO_WRAPPER_RACE_RELEASE="$release" \
    FAKE_SLEEP_BLOCK_GATE="$child_gate" \
    FAKE_SLEEP_BLOCK_PID="$child_pid_file" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PUBLICATION_MARKER="$marker" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PUBLICATION_GATE="$gate" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PUBLICATION_PID_FILE="$wrapper_pid_file" \
    /bin/bash "$WRAPPER_RACE_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while { [ ! -e "$marker" ] || [ ! -e "$ready" ] || [ ! -s "$worker_pid_file" ] ||
    [ ! -s "$helper_pid_file" ] || [ ! -s "$wrapper_pid_file" ]; } &&
    kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$marker" ] || [ ! -e "$ready" ] || [ ! -s "$worker_pid_file" ] ||
    [ ! -s "$helper_pid_file" ] || [ ! -s "$wrapper_pid_file" ]; then
    : >"$gate"
    : >"$release"
    : >"$child_gate"
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: controlled pre-publication interval was not reached" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  IFS= read -r wrapper_pid <"$wrapper_pid_file"
  worker_pgid=$(/bin/ps -o pgid= -p "$worker_pid" 2>/dev/null)
  helper_pgid=$(/bin/ps -o pgid= -p "$helper_pid" 2>/dev/null)
  wrapper_pgid=$(/bin/ps -o pgid= -p "$wrapper_pid" 2>/dev/null)
  runner_pgid=$(/bin/ps -o pgid= -p "$runner_pid" 2>/dev/null)
  worker_pgid=$(printf '%s' "$worker_pgid" | tr -d ' ')
  helper_pgid=$(printf '%s' "$helper_pgid" | tr -d ' ')
  wrapper_pgid=$(printf '%s' "$wrapper_pgid" | tr -d ' ')
  runner_pgid=$(printf '%s' "$runner_pgid" | tr -d ' ')
  if [ "$worker_pgid" != "$worker_pid" ] || [ "$wrapper_pgid" != "$worker_pid" ] ||
    [ "$helper_pgid" != "$helper_pid" ] || [ "$runner_pgid" = "$helper_pid" ] ||
    [ "$helper_pgid" = "$worker_pgid" ]; then
    : >"$gate"
    : >"$release"
    : >"$child_gate"
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: helper/worker cage boundaries were not established" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  kill -STOP "$wrapper_pid"
  kill -KILL "$worker_pid"
  : >"$gate"
  : >"$release"
  wait "$runner_pid" 2>/dev/null || true

  attempts=0
  while { kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$wrapper_pid" 2>/dev/null; } && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$wrapper_pid" 2>/dev/null || [ -e "$child_pid_file" ]; then
    kill -KILL "$wrapper_pid" 2>/dev/null || true
    : >"$child_gate"
    echo "not ok - $case_name: an unpublished wrapper started or survived" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! grep -Fx invalidate "$events" >/dev/null 2>&1; then
    echo "not ok - $case_name: sudo timestamp was not invalidated" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_process_identity_reuse_guard_case() {
  case_name='recorded identity is revalidated after TERM'
  case_root=$TEST_ROOT/process-identity-reuse-guard
  events=$case_root/sudo.events
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  if ! PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_WORKER_PID=$case_root/worker.pid \
    FAKE_SUDO_HELPER_PID=$case_root/helper.pid \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_IDENTITY_ROOT="$case_root" \
    /bin/bash "$IDENTITY_RUNNER" >"$output" 2>&1; then
    echo "not ok - $case_name" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_process_protocol_source_guard_case() {
  case_name='keep-alive protocol avoids fork-optimized PID discovery'

  if grep -F '$(/bin/sh -c' "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 ||
    grep -F 'stop_unreaped_process_group' "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 ||
    grep -F 'kill -KILL "$pending_' "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 ||
    ! grep -F 'capture_current_shell_pid' "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 ||
    ! grep -F 'inspect_process_identity' "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1; then
    echo "not ok - $case_name" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_wrapper_reaped_identity_unpublished_case() {
  case_name='wrapper identity is unpublished before owner wait returns'
  case_root=$TEST_ROOT/wrapper-reaped-unpublished
  events=$case_root/sudo.events
  marker=$case_root/wrapper.reaped
  gate=$case_root/wrapper.reaped-continue
  ready=$case_root/runner.ready
  release=$case_root/runner.release
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_WORKER_PID="$worker_pid_file" \
    FAKE_SUDO_HELPER_PID="$helper_pid_file" \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_SUDO_WRAPPER_RACE_READY="$ready" \
    FAKE_SUDO_WRAPPER_RACE_RELEASE="$release" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_REAPED_MARKER="$marker" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_REAPED_GATE="$gate" \
    /bin/bash "$WRAPPER_RACE_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while { [ ! -s "$marker" ] || [ ! -e "$ready" ] || [ ! -s "$worker_pid_file" ] ||
    [ ! -s "$helper_pid_file" ]; } && kill -0 "$runner_pid" 2>/dev/null &&
    [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -s "$marker" ] || [ ! -e "$ready" ]; then
    : >"$gate"
    : >"$release"
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: wrapper reap interval was not reached" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! grep -Fx absent "$marker" >/dev/null 2>&1; then
    : >"$gate"
    : >"$release"
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: wrapper identity remained after wait" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  kill -KILL "$worker_pid"
  : >"$gate"
  : >"$release"
  wait "$runner_pid" 2>/dev/null || true

  attempts=0
  while { kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null; } &&
    [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null; then
    echo "not ok - $case_name: owner cleanup did not finish" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_worker_reaped_identity_unpublished_case() {
  case_name='worker identity is unpublished before helper wait returns'
  case_root=$TEST_ROOT/worker-reaped-unpublished
  events=$case_root/sudo.events
  marker=$case_root/worker.reaped
  gate=$case_root/worker.reaped-continue
  ready=$case_root/runner.ready
  release=$case_root/runner.release
  helper_pid_file=$case_root/helper.pid
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_WORKER_PID=$case_root/worker.pid \
    FAKE_SUDO_HELPER_PID="$helper_pid_file" \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_SUDO_WRAPPER_RACE_READY="$ready" \
    FAKE_SUDO_WRAPPER_RACE_RELEASE="$release" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_MARKER="$marker" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_GATE="$gate" \
    /bin/bash "$WRAPPER_RACE_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while { [ ! -e "$ready" ] || [ ! -s "$helper_pid_file" ]; } &&
    kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  : >"$release"
  attempts=0
  while [ ! -s "$marker" ] && kill -0 "$runner_pid" 2>/dev/null &&
    [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -s "$marker" ] || ! grep -Fx absent "$marker" >/dev/null 2>&1; then
    : >"$gate"
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: worker identity remained after wait" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r helper_pid <"$helper_pid_file"
  kill -KILL "$runner_pid"
  wait "$runner_pid" 2>/dev/null || true
  : >"$gate"
  attempts=0
  while kill -0 "$helper_pid" 2>/dev/null && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$helper_pid" 2>/dev/null; then
    echo "not ok - $case_name: helper cleanup did not finish" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_setup_reaped_identity_unpublished_case() {
  case_name='setup wrapper identity is unpublished before helper wait returns'
  case_root=$TEST_ROOT/setup-reaped-unpublished
  events=$case_root/sudo.events
  privileged_started=$case_root/privileged.started
  privileged_gate=$case_root/privileged.continue
  privileged_invocations=$case_root/privileged.invocations
  marker=$case_root/setup.reaped
  gate=$case_root/setup.reaped-continue
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"
  : >"$case_root/request.continue"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_PRIVILEGED_STARTED="$privileged_started" \
    FAKE_PRIVILEGED_GATE="$privileged_gate" \
    FAKE_PRIVILEGED_INVOCATIONS="$privileged_invocations" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_PID_FILE="$worker_pid_file" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_HELPER_PID_FILE="$helper_pid_file" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REQUEST_GATE=$case_root/request.continue \
    BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER="$marker" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_GATE="$gate" \
    /bin/bash "$REQUEST_ONCE_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while { [ ! -e "$privileged_started" ] || [ ! -s "$worker_pid_file" ] ||
    [ ! -s "$helper_pid_file" ]; } && kill -0 "$runner_pid" 2>/dev/null &&
    [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  : >"$privileged_gate"
  attempts=0
  while [ ! -s "$marker" ] && kill -0 "$runner_pid" 2>/dev/null &&
    [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -s "$marker" ] || ! grep -Fx absent "$marker" >/dev/null 2>&1; then
    : >"$gate"
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: setup wrapper identity remained after wait" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  kill -KILL "$helper_pid"
  : >"$gate"
  wait "$runner_pid" 2>/dev/null || true
  attempts=0
  while { kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null; } &&
    [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null; then
    echo "not ok - $case_name: fallback cleanup did not finish" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_startup_parent_death_case() {
  case_name='sudo keep-alive parent SIGKILL during helper startup cleanup'
  case_root=$TEST_ROOT/startup-parent-sigkill
  events=$case_root/sudo.events
  startup_marker=$case_root/startup.marker
  startup_gate=$case_root/startup.continue
  helper_pid_file=$case_root/helper.pid
  worker_pid_file=$case_root/worker.pid
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_REFRESH_STATUS=0 \
    BOOTSTRAP_INTERNAL_TEST_SUDO_HELPER_PID_FILE="$helper_pid_file" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_PID_FILE="$worker_pid_file" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_STARTUP_MARKER="$startup_marker" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_STARTUP_GATE="$startup_gate" \
    /bin/bash "$STARTUP_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while { [ ! -e "$startup_marker" ] || [ ! -s "$helper_pid_file" ] ||
    [ ! -s "$worker_pid_file" ]; } && kill -0 "$runner_pid" 2>/dev/null &&
    [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$startup_marker" ] || [ ! -s "$helper_pid_file" ] ||
    [ ! -s "$worker_pid_file" ]; then
    : >"$startup_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: helper did not reach the controlled startup interval" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r helper_pid <"$helper_pid_file"
  IFS= read -r worker_pid <"$worker_pid_file"
  kill -KILL "$runner_pid"
  attempts=0
  while { kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null; } &&
    [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  wait "$runner_pid" 2>/dev/null || true

  if kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null; then
    : >"$startup_gate"
    echo "not ok - $case_name: startup helper or worker survived bootstrap SIGKILL" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_setup_request_consumed_once_case() {
  case_name='privileged setup request is consumed once'
  case_root=$TEST_ROOT/request-consumed-once
  events=$case_root/sudo.events
  privileged_started=$case_root/privileged.started
  privileged_gate=$case_root/privileged.continue
  privileged_invocations=$case_root/privileged.invocations
  request_gate=$case_root/request.continue
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_PRIVILEGED_STARTED="$privileged_started" \
    FAKE_PRIVILEGED_GATE="$privileged_gate" \
    FAKE_PRIVILEGED_INVOCATIONS="$privileged_invocations" \
    BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REQUEST_GATE="$request_gate" \
    /bin/bash "$REQUEST_ONCE_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while [ ! -e "$privileged_started" ] && kill -0 "$runner_pid" 2>/dev/null &&
    [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$privileged_started" ]; then
    : >"$privileged_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: privileged setup did not start" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  : >"$privileged_gate"
  /bin/sleep 0.5
  invocation_count=$(wc -l <"$privileged_invocations")
  : >"$request_gate"
  if ! wait "$runner_pid"; then
    echo "not ok - $case_name: runner failed" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  if [ "$invocation_count" -ne 1 ]; then
    echo "not ok - $case_name: setup ran $invocation_count times" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_keepalive_failure_propagation_case() {
  failure_stage=$1
  case_name="keep-alive $failure_stage failure stops privileged setup"
  case_root=$TEST_ROOT/keepalive-$failure_stage-failure
  events=$case_root/sudo.events
  failure_gate=$case_root/failure.continue
  sleep_started=$case_root/sleep.started
  keepalive_started=$case_root/keepalive.started
  long_started=$case_root/long.started
  long_gate=$case_root/long.continue
  long_pid_file=$case_root/long.pid
  setup_status_file=$case_root/setup.status
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  case "$failure_stage" in
  sleep)
    sleep_status=91
    refresh_status=0
    failure_started=$sleep_started
    ;;
  sudo)
    sleep_status=0
    refresh_status=92
    failure_started=$keepalive_started
    ;;
  *) return 1 ;;
  esac

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_BIN="$FAKE_BIN" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED="$keepalive_started" \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_REFRESH_STATUS="$refresh_status" \
    FAKE_SLEEP_STATUS="$sleep_status" \
    FAKE_SLEEP_FAILURE_STARTED="$sleep_started" \
    FAKE_KEEPALIVE_FAILURE_GATE="$failure_gate" \
    FAKE_LONG_COMMAND_STARTED="$long_started" \
    FAKE_LONG_COMMAND_GATE="$long_gate" \
    FAKE_LONG_COMMAND_PID="$long_pid_file" \
    FAKE_LONG_COMMAND_FD_STATE=$case_root/long.fd-state \
    FAKE_KEEPALIVE_SETUP_STATUS="$setup_status_file" \
    /bin/bash "$KEEPALIVE_FAILURE_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while { [ ! -e "$failure_started" ] || [ ! -e "$long_started" ]; } &&
    kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 300 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$failure_started" ] || [ ! -e "$long_started" ]; then
    : >"$failure_gate"
    : >"$long_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: controlled failure interval was not reached" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  : >"$failure_gate"
  attempts=0
  while kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$runner_pid" 2>/dev/null; then
    : >"$long_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: bootstrap did not observe keep-alive failure" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! wait "$runner_pid"; then
    echo "not ok - $case_name: failure runner assertions failed" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  if ! IFS= read -r setup_status <"$setup_status_file" || [ "$setup_status" -eq 0 ]; then
    echo "not ok - $case_name: keep-alive failure status was not propagated" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! IFS= read -r long_pid <"$long_pid_file" || kill -0 "$long_pid" 2>/dev/null; then
    : >"$long_gate"
    echo "not ok - $case_name: privileged setup process survived" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! grep -F "sudo keep-alive failed during privileged setup" "$output" >/dev/null 2>&1; then
    echo "not ok - $case_name: keep-alive error was not reported" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_keepalive_owner_sigkill_case() {
  owner=$1
  case_name="sudo keep-alive $owner SIGKILL cleanup"
  case_root=$TEST_ROOT/$owner-sigkill
  events=$case_root/sudo.events
  keepalive_started=$case_root/keepalive.started
  keepalive_gate=$case_root/keepalive.continue
  keepalive_pid_file=$case_root/keepalive.pid
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  long_started=$case_root/long.started
  long_gate=$case_root/long.continue
  long_pid_file=$case_root/long.pid
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_BIN="$FAKE_BIN" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED="$keepalive_started" \
    FAKE_SUDO_KEEPALIVE_GATE="$keepalive_gate" \
    FAKE_SUDO_KEEPALIVE_PID="$keepalive_pid_file" \
    FAKE_SUDO_WORKER_PID="$worker_pid_file" \
    FAKE_SUDO_HELPER_PID="$helper_pid_file" \
    FAKE_SUDO_REFRESH_STATUS=0 \
    FAKE_LONG_COMMAND_STARTED="$long_started" \
    FAKE_LONG_COMMAND_GATE="$long_gate" \
    FAKE_LONG_COMMAND_PID="$long_pid_file" \
    FAKE_LONG_COMMAND_FD_STATE=$case_root/long.fd-state \
    /bin/bash "$FD_RUNNER" >"$output" 2>&1 &
  runner_pid=$!

  attempts=0
  while { [ ! -e "$long_started" ] || [ ! -e "$keepalive_started" ] ||
    [ ! -s "$worker_pid_file" ] || [ ! -s "$helper_pid_file" ]; } &&
    kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$long_started" ] || [ ! -e "$keepalive_started" ] ||
    [ ! -s "$worker_pid_file" ] || [ ! -s "$helper_pid_file" ]; then
    : >"$long_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: controlled owner interval was not reached" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  IFS= read -r long_pid <"$long_pid_file"
  case "$owner" in
  helper)
    kill -STOP "$long_pid"
    killed_owner_pid=$helper_pid
    ;;
  worker) killed_owner_pid=$worker_pid ;;
  *) return 1 ;;
  esac
  kill -KILL "$killed_owner_pid"

  attempts=0
  while kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  runner_status=0
  wait "$runner_pid" || runner_status=$?
  if [ "$runner_status" -eq 0 ]; then
    echo "not ok - $case_name: owner failure was not propagated" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  attempts=0
  while { kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$long_pid" 2>/dev/null; } && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$long_pid" 2>/dev/null; then
    : >"$long_gate"
    echo "not ok - $case_name: privileged setup or owner process survived" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! grep -Fx invalidate "$events" >/dev/null 2>&1; then
    echo "not ok - $case_name: sudo timestamp was not invalidated" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_keepalive_wrapper_sigkill_case() {
  wrapper_type=$1
  case_name="sudo keep-alive $wrapper_type wrapper SIGKILL infrastructure failure"
  case_root=$TEST_ROOT/$wrapper_type-wrapper-sigkill
  events=$case_root/sudo.events
  keepalive_started=$case_root/keepalive.started
  keepalive_gate=$case_root/keepalive.continue
  keepalive_pid_file=$case_root/keepalive.pid
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  wrapper_pid_file=$case_root/wrapper.pid
  wrapper_marker=$case_root/wrapper.started
  wrapper_gate=$case_root/wrapper.continue
  wrapper_child_pid_file=$case_root/wrapper-child.pid
  wrapper_child_gate=$case_root/wrapper-child.continue
  wrapper_child_stopped=$case_root/wrapper-child.stopped
  long_started=$case_root/long.started
  long_gate=$case_root/long.continue
  long_pid_file=$case_root/long.pid
  long_stopped=$case_root/long.stopped
  output=$case_root/output
  mkdir -p "$case_root"
  : >"$events"

  case "$wrapper_type" in
  worker)
    wrapper_ready_file=$wrapper_child_pid_file
    PATH="$FAKE_BIN:/usr/bin:/bin" \
      FAKE_BIN="$FAKE_BIN" \
      FAKE_SUDO_EVENTS="$events" \
      FAKE_SUDO_KEEPALIVE_STARTED="$keepalive_started" \
      FAKE_SUDO_KEEPALIVE_GATE="$keepalive_gate" \
      FAKE_SUDO_KEEPALIVE_PID="$keepalive_pid_file" \
      FAKE_SUDO_WORKER_PID="$worker_pid_file" \
      FAKE_SUDO_HELPER_PID="$helper_pid_file" \
      FAKE_SUDO_REFRESH_STATUS=0 \
      FAKE_SLEEP_BLOCK_GATE="$wrapper_child_gate" \
      FAKE_SLEEP_BLOCK_PID="$wrapper_child_pid_file" \
      FAKE_SLEEP_STOPPED_MARKER="$wrapper_child_stopped" \
      FAKE_LONG_COMMAND_STARTED="$long_started" \
      FAKE_LONG_COMMAND_GATE="$long_gate" \
      FAKE_LONG_COMMAND_PID="$long_pid_file" \
      FAKE_LONG_COMMAND_STOPPED_MARKER="$long_stopped" \
      FAKE_LONG_COMMAND_FD_STATE=$case_root/long.fd-state \
      BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_FORK_MARKER="$wrapper_marker" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_FORK_GATE="$wrapper_gate" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PID_FILE="$wrapper_pid_file" \
      /bin/bash "$FD_RUNNER" >"$output" 2>&1 &
    ;;
  setup)
    wrapper_ready_file=$wrapper_pid_file
    PATH="$FAKE_BIN:/usr/bin:/bin" \
      FAKE_BIN="$FAKE_BIN" \
      FAKE_SUDO_EVENTS="$events" \
      FAKE_SUDO_KEEPALIVE_STARTED="$keepalive_started" \
      FAKE_SUDO_KEEPALIVE_GATE="$keepalive_gate" \
      FAKE_SUDO_KEEPALIVE_PID="$keepalive_pid_file" \
      FAKE_SUDO_WORKER_PID="$worker_pid_file" \
      FAKE_SUDO_HELPER_PID="$helper_pid_file" \
      FAKE_SUDO_REFRESH_STATUS=0 \
      FAKE_LONG_COMMAND_STARTED="$long_started" \
      FAKE_LONG_COMMAND_GATE="$long_gate" \
      FAKE_LONG_COMMAND_PID="$long_pid_file" \
      FAKE_LONG_COMMAND_STOPPED_MARKER="$long_stopped" \
      FAKE_LONG_COMMAND_FD_STATE=$case_root/long.fd-state \
      BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_WRAPPER_PID_FILE="$wrapper_pid_file" \
      /bin/bash "$FD_RUNNER" >"$output" 2>&1 &
    ;;
  *) return ;;
  esac
  runner_pid=$!

  attempts=0
  while { [ ! -e "$long_started" ] || [ ! -s "$worker_pid_file" ] ||
    [ ! -s "$helper_pid_file" ] || [ ! -s "$wrapper_pid_file" ] ||
    [ ! -s "$wrapper_ready_file" ]; } &&
    kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$long_started" ] || [ ! -s "$worker_pid_file" ] ||
    [ ! -s "$helper_pid_file" ] || [ ! -s "$wrapper_pid_file" ] ||
    [ ! -s "$wrapper_ready_file" ]; then
    : >"$wrapper_gate"
    : >"$wrapper_child_gate"
    : >"$long_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: controlled wrapper interval was not reached" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  IFS= read -r worker_pid <"$worker_pid_file"
  IFS= read -r helper_pid <"$helper_pid_file"
  IFS= read -r wrapper_pid <"$wrapper_pid_file"
  IFS= read -r long_pid <"$long_pid_file"
  wrapper_child_pid=
  if [ "$wrapper_type" = worker ]; then
    IFS= read -r wrapper_child_pid <"$wrapper_child_pid_file"
  fi
  kill -KILL "$wrapper_pid"
  if [ "$wrapper_type" = worker ]; then
    : >"$wrapper_gate"
  fi

  attempts=0
  while kill -0 "$runner_pid" 2>/dev/null && [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$runner_pid" 2>/dev/null; then
    : >"$wrapper_child_gate"
    : >"$long_gate"
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    echo "not ok - $case_name: bootstrap did not observe wrapper failure" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  runner_status=0
  wait "$runner_pid" || runner_status=$?
  if [ "$runner_status" -eq 0 ]; then
    echo "not ok - $case_name: wrapper failure was not propagated" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  attempts=0
  while { kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$wrapper_pid" 2>/dev/null || kill -0 "$long_pid" 2>/dev/null ||
    { [ -n "$wrapper_child_pid" ] && kill -0 "$wrapper_child_pid" 2>/dev/null; }; } &&
    [ "$attempts" -lt 500 ]; do
    /bin/sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$helper_pid" 2>/dev/null || kill -0 "$worker_pid" 2>/dev/null ||
    kill -0 "$wrapper_pid" 2>/dev/null || kill -0 "$long_pid" 2>/dev/null ||
    { [ -n "$wrapper_child_pid" ] && kill -0 "$wrapper_child_pid" 2>/dev/null; }; then
    : >"$wrapper_child_gate"
    : >"$long_gate"
    echo "not ok - $case_name: an owned process survived" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if ! grep -F 'sudo keep-alive' "$output" >/dev/null 2>&1 ||
    ! grep -Fx invalidate "$events" >/dev/null 2>&1; then
    echo "not ok - $case_name: infrastructure failure or invalidation was not reported" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_homebrew_path_propagation_case() {
  case_name='Homebrew PATH reaches Agent Skills after keep-alive'
  case_root=$TEST_ROOT/homebrew-path
  minimal_bin=$case_root/initial-bin
  homebrew_prefix=$case_root/homebrew
  tools_log=$case_root/tools.log
  skills_marker=$case_root/skills.completed
  installed_marker=$case_root/homebrew.installed
  events=$case_root/sudo.events
  output=$case_root/output
  mkdir -p "$minimal_bin" "$homebrew_prefix/bin"
  : >"$events"
  : >"$tools_log"

  cp "$FAKE_BIN/sleep" "$FAKE_BIN/sudo" "$minimal_bin/"
  for required_command in mkfifo mktemp rm rmdir; do
    ln -s "$(command -v "$required_command")" "$minimal_bin/$required_command"
  done
  cat >"$homebrew_prefix/bin/brew" <<'EOF'
#!/bin/sh
[ -e "$FAKE_HOMEBREW_INSTALLED" ] || exit 91
[ "${1-}" = shellenv ] || exit 92
printf 'export PATH="%s/bin:$PATH"\n' "$BOOTSTRAP_INTERNAL_TEST_HOMEBREW_PREFIX"
EOF
  cat >"$homebrew_prefix/bin/git" <<'EOF'
#!/bin/sh
printf 'git:%s\n' "$*" >>"$FAKE_HOMEBREW_TOOLS_LOG"
EOF
  cat >"$homebrew_prefix/bin/python3" <<'EOF'
#!/bin/sh
printf 'python3:%s\n' "$*" >>"$FAKE_HOMEBREW_TOOLS_LOG"
EOF
  cat >"$case_root/skills-setup" <<'EOF'
#!/bin/sh
git skills
python3 skills
: >"$FAKE_AGENT_SKILLS_MARKER"
EOF
  chmod +x "$homebrew_prefix/bin/brew" "$homebrew_prefix/bin/git" \
    "$homebrew_prefix/bin/python3" "$case_root/skills-setup"

  if ! PATH="$minimal_bin" \
    BOOTSTRAP_INTERNAL_TEST_HOMEBREW_PREFIX="$homebrew_prefix" \
    FAKE_HOMEBREW_INSTALLED="$installed_marker" \
    FAKE_HOMEBREW_TOOLS_LOG="$tools_log" \
    FAKE_AGENT_SKILLS_SETUP=$case_root/skills-setup \
    FAKE_AGENT_SKILLS_MARKER="$skills_marker" \
    FAKE_SUDO_EVENTS="$events" \
    FAKE_SUDO_KEEPALIVE_STARTED=$case_root/keepalive.started \
    FAKE_SUDO_KEEPALIVE_GATE=$case_root/keepalive.continue \
    FAKE_SUDO_KEEPALIVE_PID=$case_root/keepalive.pid \
    FAKE_SUDO_REFRESH_STATUS=0 \
    /bin/bash "$HOMEBREW_PATH_RUNNER" >"$output" 2>&1; then
    echo "not ok - $case_name" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  if [ ! -e "$skills_marker" ] ||
    ! grep -Fx 'git:skills' "$tools_log" >/dev/null 2>&1 ||
    ! grep -Fx 'python3:skills' "$tools_log" >/dev/null 2>&1; then
    echo "not ok - $case_name: updated PATH was not used by Agent Skills" >&2
    sed -n '1,120p' "$tools_log" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_homebrew_path_resolution_case() {
  case_name='PATH Homebrew uses the same detection and shellenv candidate'
  case_root=$TEST_ROOT/homebrew-resolution
  custom_bin=$case_root/custom/homebrew/bin
  brew_log=$case_root/brew.log
  installer_marker=$case_root/installer.called
  output=$case_root/output
  mkdir -p "$custom_bin"
  : >"$brew_log"

  cat >"$custom_bin/brew" <<'EOF'
#!/bin/sh
printf '%s\n' "${1-}" >>"$FAKE_HOMEBREW_LOG"
case "${1-}" in
    shellenv) printf 'export PATH="%s:$PATH"\n' "$FAKE_HOMEBREW_BIN" ;;
    resolved) ;;
    *) exit 91 ;;
esac
EOF
  chmod +x "$custom_bin/brew"

  if ! PATH="$custom_bin" \
    FAKE_HOMEBREW_BIN="$custom_bin" \
    FAKE_HOMEBREW_LOG="$brew_log" \
    FAKE_HOMEBREW_INSTALLER_MARKER="$installer_marker" \
    /bin/bash "$HOMEBREW_RESOLUTION_RUNNER" >"$output" 2>&1; then
    echo "not ok - $case_name" >&2
    sed -n '1,120p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  if [ -e "$installer_marker" ] ||
    ! grep -Fx shellenv "$brew_log" >/dev/null 2>&1 ||
    ! grep -Fx resolved "$brew_log" >/dev/null 2>&1; then
    echo "not ok - $case_name: PATH brew was not reused for shellenv" >&2
    sed -n '1,120p' "$brew_log" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_foreground_pty_case() {
  scenario=$1
  case "$scenario" in
  interactive)
    case_name='foreground setup reads /dev/tty and resumes after SIGTSTP'
    runner_mode=interactive
    shared_peer_enabled=
    ;;
  background)
    case_name='background-resumed foreground setup fails closed without SIGTTIN hang'
    runner_mode=interactive
    shared_peer_enabled=
    ;;
  shared)
    case_name='shared foreground process group peer survives fallback cleanup'
    runner_mode=shared-peer
    shared_peer_enabled=1
    ;;
  helper)
    case_name='helper SIGKILL reaps a stopped unpublished foreground wrapper'
    runner_mode=stopped-wrapper
    shared_peer_enabled=
    ;;
  worker)
    case_name='worker SIGKILL reaps a stopped unpublished foreground wrapper'
    runner_mode=stopped-wrapper
    shared_peer_enabled=
    ;;
  *)
    return 1
    ;;
  esac
  case_root=$TEST_ROOT/foreground-pty-$scenario
  events=$case_root/sudo.events
  output=$case_root/output
  keepalive_started=$case_root/keepalive.started
  keepalive_gate=$case_root/keepalive.continue
  keepalive_pid_file=$case_root/keepalive.pid
  worker_pid_file=$case_root/worker.pid
  helper_pid_file=$case_root/helper.pid
  runner_identity_file=$case_root/runner.identity
  setup_identity_file=$case_root/setup.identity
  tty_read_file=$case_root/tty.read
  release_gate=$case_root/release
  payload_started_file=$case_root/payload.started
  wrapper_marker=$case_root/wrapper.unpublished
  wrapper_gate=$case_root/wrapper.publish
  wrapper_pid_file=$case_root/wrapper.pid
  finalizer_pid_file=$case_root/finalizer.pid
  shared_peer_pid_file=$case_root/shared-peer.pid
  foreground_mode_file=$case_root/foreground-mode
  supervisor_ready_gate=$case_root/supervisor-ready
  shared_runner_status_file=$case_root/shared-runner-status
  shared_after_failure_gate=$case_root/shared-after-failure
  mkdir -p "$case_root"
  : >"$events"

  if [ -z "$PYTHON3" ]; then
    echo "not ok - $case_name: python3 is required for PTY coverage" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  if [ "$scenario" = interactive ] || [ "$scenario" = background ]; then
    if ! PATH="$FAKE_BIN:/usr/bin:/bin" \
      FAKE_BIN="$FAKE_BIN" \
      FAKE_SUDO_EVENTS="$events" \
      FAKE_SUDO_KEEPALIVE_STARTED="$keepalive_started" \
      FAKE_SUDO_KEEPALIVE_GATE="$keepalive_gate" \
      FAKE_SUDO_KEEPALIVE_PID="$keepalive_pid_file" \
      FAKE_SUDO_WORKER_PID="$worker_pid_file" \
      FAKE_SUDO_HELPER_PID="$helper_pid_file" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_PID_FILE="$worker_pid_file" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_HELPER_PID_FILE="$helper_pid_file" \
      FAKE_SUDO_REFRESH_STATUS=0 \
      PTY_CASE="$scenario" \
      PTY_TEST_MODE="$runner_mode" \
      PTY_RUNNER_IDENTITY_FILE="$runner_identity_file" \
      PTY_FOREGROUND_MODE_FILE="$foreground_mode_file" \
      PTY_SETUP_IDENTITY_FILE="$setup_identity_file" \
      PTY_TTY_READ_FILE="$tty_read_file" \
      PTY_RELEASE_GATE="$release_gate" \
      PTY_PAYLOAD_STARTED_FILE="$payload_started_file" \
      PTY_SUPERVISOR_READY_GATE="$supervisor_ready_gate" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_FINALIZER_PID_FILE="$finalizer_pid_file" \
      "$PYTHON3" - "$PTY_RUNNER" >"$output" 2>&1 <<'PY'; then
import errno
import os
import pty
import select
import signal
import subprocess
import sys
import time

runner = sys.argv[1]
scenario = os.environ["PTY_CASE"]
supervisor_ready_gate = os.environ["PTY_SUPERVISOR_READY_GATE"]
runner_identity = os.environ["PTY_RUNNER_IDENTITY_FILE"]
setup_identity = os.environ["PTY_SETUP_IDENTITY_FILE"]
tty_read = os.environ["PTY_TTY_READ_FILE"]
release_gate = os.environ["PTY_RELEASE_GATE"]
helper_pid_file = os.environ["FAKE_SUDO_HELPER_PID"]
worker_pid_file = os.environ["FAKE_SUDO_WORKER_PID"]
finalizer_pid_file = os.environ["BOOTSTRAP_INTERNAL_TEST_SUDO_FINALIZER_PID_FILE"]
foreground_mode_file = os.environ["PTY_FOREGROUND_MODE_FILE"]
payload_started = os.environ["PTY_PAYLOAD_STARTED_FILE"]
wrapper_marker = os.environ.get(
    "BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_MARKER", ""
)
wrapper_pid_file = os.environ.get(
    "BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_PID_FILE", ""
)

report_read, report_write = os.pipe()
os.set_blocking(report_read, False)
supervisor_pid = None
runner_pid = None
master_fd = None
reports = []
report_buffer = b""
supervisor_status = None
completed = False


def write_report(message):
    os.write(report_write, (message + "\n").encode("ascii"))


def supervisor():
    global runner_pid
    os.close(report_read)
    runner_pid = os.fork()
    if runner_pid == 0:
        os.close(report_write)
        os.setpgid(0, 0)
        os.execve(runner, [runner], os.environ.copy())

    for _ in range(100):
        try:
            os.setpgid(runner_pid, runner_pid)
            break
        except ProcessLookupError:
            write_report("runner-lost")
            os._exit(125)
        except PermissionError:
            break
        except OSError as error:
            if error.errno != errno.EINTR:
                write_report("runner-pgid-error:%d" % error.errno)
                os._exit(125)
    try:
        os.tcsetpgrp(0, runner_pid)
    except OSError as error:
        write_report("tcsetpgrp-error:%d" % error.errno)
        os._exit(125)
    open(supervisor_ready_gate, "w", encoding="utf-8").close()
    write_report("runner:%d" % runner_pid)

    while True:
        _, status = os.waitpid(runner_pid, os.WUNTRACED)
        if os.WIFSTOPPED(status):
            write_report("stopped:%d" % os.WSTOPSIG(status))
            if scenario == "background":
                try:
                    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
                    os.tcsetpgrp(0, os.getpgrp())
                except OSError as error:
                    write_report("background-tcsetpgrp-error:%d" % error.errno)
                    os._exit(125)
                os.killpg(runner_pid, signal.SIGCONT)
            continue
        if os.WIFEXITED(status):
            write_report("exit:%d" % os.WEXITSTATUS(status))
        elif os.WIFSIGNALED(status):
            write_report("signal:%d" % os.WTERMSIG(status))
        else:
            write_report("runner-status:%d" % status)
        try:
            os.tcsetpgrp(0, os.getpgrp())
        except OSError:
            pass
        os._exit(0)


def pump():
    global report_buffer, supervisor_status
    watched = [report_read]
    if master_fd is not None:
        watched.append(master_fd)
    readable, _, _ = select.select(watched, [], [], 0.02)
    for descriptor in readable:
        if descriptor == report_read:
            try:
                chunk = os.read(report_read, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                continue
            report_buffer += chunk
            while b"\n" in report_buffer:
                line, report_buffer = report_buffer.split(b"\n", 1)
                reports.append(line.decode("ascii", "replace"))
        else:
            try:
                os.read(master_fd, 4096)
            except OSError:
                pass
    if supervisor_status is None:
        try:
            waited, status = os.waitpid(supervisor_pid, os.WNOHANG)
        except ChildProcessError:
            waited, status = supervisor_pid, supervisor_status
        if waited:
            supervisor_status = status


def wait_for(predicate, description, timeout=12.0, allow_supervisor_exit=False):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pump()
        if predicate():
            return
        if supervisor_status is not None and not allow_supervisor_exit:
            raise RuntimeError("%s: supervisor exited early (%r; reports=%r)" % (
                description, supervisor_status, reports
            ))
        time.sleep(0.01)
    raise RuntimeError("%s: timed out (reports=%r)" % (description, reports))


def read_lines(path, count):
    with open(path, "r", encoding="utf-8") as handle:
        values = [line.strip() for line in handle]
    if len(values) != count or not all(values):
        raise RuntimeError("invalid %s: %r" % (path, values))
    return values


def read_pid(path):
    value = read_lines(path, 1)[0]
    if not value.isdigit():
        raise RuntimeError("invalid pid in %s: %r" % (path, value))
    return int(value)


def process_is_live(pid):
    try:
        output = subprocess.check_output(
            ["/bin/ps", "-o", "state=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return False
    return bool(output) and "Z" not in output


def cleanup():
    for pgid in (runner_pid, supervisor_pid):
        if pgid:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    if supervisor_pid and supervisor_status is None:
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            try:
                waited, _ = os.waitpid(supervisor_pid, os.WNOHANG)
            except ChildProcessError:
                break
            if waited:
                break
            time.sleep(0.02)


try:
    supervisor_pid, master_fd = pty.fork()
    if supervisor_pid == 0:
        supervisor()
        os._exit(125)
    os.close(report_write)

    wait_for(lambda: any(item.startswith("runner:") for item in reports),
             "runner process-group publication")
    runner_pid = int(next(item.split(":", 1)[1] for item in reports
                          if item.startswith("runner:")))

    if scenario in ("interactive", "background"):
        wait_for(lambda: os.path.isfile(setup_identity) and
                 os.path.getsize(setup_identity) > 0 and
                 os.path.isfile(runner_identity) and
                 os.path.getsize(runner_identity) > 0 and
                 os.path.isfile(helper_pid_file) and
                 os.path.getsize(helper_pid_file) > 0 and
                 os.path.isfile(worker_pid_file) and
                 os.path.getsize(worker_pid_file) > 0,
                 "foreground setup startup")
        setup_pid, setup_pgid, setup_tpgid = read_lines(setup_identity, 3)
        runner_recorded_pid, runner_pgid = read_lines(runner_identity, 2)
        if not (setup_pgid == setup_tpgid == runner_pgid):
            raise RuntimeError(
                "foreground PG mismatch: setup=%s/%s/%s runner=%s/%s" % (
                    setup_pid, setup_pgid, setup_tpgid,
                    runner_recorded_pid, runner_pgid,
                )
            )
        helper_pid = read_pid(helper_pid_file)
        if not os.path.isfile(finalizer_pid_file):
            group_members = "<unavailable>"
            if os.path.isfile(foreground_group_members_file):
                group_members = open(
                    foreground_group_members_file, "r", encoding="utf-8"
                ).read().strip()
            foreground_mode = "<unavailable>"
            if os.path.isfile(foreground_mode_file):
                foreground_mode = open(
                    foreground_mode_file, "r", encoding="utf-8"
                ).read().strip()
            raise RuntimeError(
                "foreground finalizer was not published (mode=%s setup=%s/%s/%s runner=%s/%s helper-pgid=%s members=%r)" % (
                    foreground_mode,
                    setup_pid, setup_pgid, setup_tpgid,
                    runner_recorded_pid, runner_pgid, os.getpgid(helper_pid), group_members,
                )
            )
        finalizer_pid = read_pid(finalizer_pid_file)
        if os.getpgid(helper_pid) == int(setup_pgid):
            raise RuntimeError("helper shares the foreground setup process group")
        if os.getpgid(finalizer_pid) in (int(setup_pgid), os.getpgid(helper_pid)):
            raise RuntimeError("foreground finalizer is not in a separate process group")

        os.write(master_fd, b"pty-input\n")
        wait_for(lambda: os.path.isfile(tty_read) and
                 os.path.getsize(tty_read) > 0,
                 "/dev/tty read")
        if open(tty_read, "r", encoding="utf-8").read().strip() != "pty-input":
            raise RuntimeError("foreground setup read the wrong terminal input")

        os.killpg(int(setup_pgid), signal.SIGTSTP)
        wait_for(lambda: "stopped:%d" % signal.SIGTSTP in reports,
                 "SIGTSTP stop report")
        if scenario == "background":
            wait_for(lambda: any(item.startswith("signal:") or item.startswith("exit:")
                                 for item in reports),
                     "background SIGCONT failure completion", timeout=15.0)
            if "exit:0" in reports:
                raise RuntimeError("background-resumed runner completed successfully")
            wait_for(lambda: not process_is_live(helper_pid) and
                     not process_is_live(read_pid(worker_pid_file)) and
                     not process_is_live(finalizer_pid),
                     "background cleanup", timeout=8.0, allow_supervisor_exit=True)
        else:
            os.killpg(int(setup_pgid), signal.SIGCONT)
            open(release_gate, "w", encoding="utf-8").close()
            wait_for(lambda: "exit:0" in reports, "SIGCONT completion", timeout=15.0)
    else:
        wait_for(lambda: os.path.isfile(wrapper_marker) and
                 os.path.isfile(wrapper_pid_file) and
                 os.path.getsize(wrapper_pid_file) > 0 and
                 os.path.isfile(runner_identity) and
                 os.path.getsize(runner_identity) > 0 and
                 os.path.isfile(helper_pid_file) and
                 os.path.getsize(helper_pid_file) > 0 and
                 os.path.isfile(worker_pid_file) and
                 os.path.getsize(worker_pid_file) > 0,
                 "unpublished foreground wrapper startup")
        wrapper_pid = read_pid(wrapper_pid_file)
        _, runner_pgid = read_lines(runner_identity, 2)
        if os.getpgid(wrapper_pid) != int(runner_pgid):
            raise RuntimeError("unpublished wrapper is outside the foreground group")
        os.kill(wrapper_pid, signal.SIGSTOP)
        wait_for(lambda: "T" in subprocess.check_output(
            ["/bin/ps", "-o", "state=", "-p", str(wrapper_pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ), "wrapper SIGSTOP state")
        owner_pid = read_pid(helper_pid_file if scenario == "helper" else worker_pid_file)
        os.kill(owner_pid, signal.SIGKILL)
        wait_for(lambda: any(item.startswith("signal:") or item.startswith("exit:")
                             for item in reports),
                 "%s loss cleanup" % scenario, timeout=15.0)
        if process_is_live(wrapper_pid) or process_is_live(runner_pid):
            raise RuntimeError("stopped unpublished wrapper or runner survived")
        if os.path.exists(payload_started):
            raise RuntimeError("unpublished wrapper reached the payload")

    wait_for(lambda: supervisor_status is not None, "supervisor exit", timeout=8.0)
    if supervisor_status is None or not os.WIFEXITED(supervisor_status) or \
            os.WEXITSTATUS(supervisor_status) != 0:
        raise RuntimeError("supervisor did not exit cleanly: %r" % supervisor_status)
    completed = True
except Exception as error:
    print("PTY case failed: %s" % error, file=sys.stderr)
    cleanup()
    raise
finally:
    if not completed:
        cleanup()
    if master_fd is not None:
        try:
            os.close(master_fd)
        except OSError:
            pass
    os.close(report_read)
PY
      echo "not ok - $case_name" >&2
      sed -n '1,160p' "$output" >&2
      TESTS_FAILED=$((TESTS_FAILED + 1))
      return
    fi
  else
    if ! PATH="$FAKE_BIN:/usr/bin:/bin" \
      FAKE_BIN="$FAKE_BIN" \
      FAKE_SUDO_EVENTS="$events" \
      FAKE_SUDO_KEEPALIVE_STARTED="$keepalive_started" \
      FAKE_SUDO_KEEPALIVE_GATE="$keepalive_gate" \
      FAKE_SUDO_KEEPALIVE_PID="$keepalive_pid_file" \
      FAKE_SUDO_WORKER_PID="$worker_pid_file" \
      FAKE_SUDO_HELPER_PID="$helper_pid_file" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_PID_FILE="$worker_pid_file" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_HELPER_PID_FILE="$helper_pid_file" \
      FAKE_SUDO_REFRESH_STATUS=0 \
      PTY_CASE="$scenario" \
      PTY_TEST_MODE="$runner_mode" \
      PTY_RUNNER_IDENTITY_FILE="$runner_identity_file" \
      PTY_FOREGROUND_MODE_FILE="$foreground_mode_file" \
      PTY_SETUP_IDENTITY_FILE="$setup_identity_file" \
      PTY_TTY_READ_FILE="$tty_read_file" \
      PTY_RELEASE_GATE="$release_gate" \
      PTY_PAYLOAD_STARTED_FILE="$payload_started_file" \
      PTY_SHARED_GROUP_PEER="$shared_peer_enabled" \
      PTY_SHARED_GROUP_PEER_PID_FILE="$shared_peer_pid_file" \
      PTY_SUPERVISOR_READY_GATE="$supervisor_ready_gate" \
      PTY_SHARED_RUNNER_STATUS_FILE="$shared_runner_status_file" \
      PTY_SHARED_AFTER_FAILURE_GATE="$shared_after_failure_gate" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_FINALIZER_PID_FILE="$finalizer_pid_file" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_MARKER="$wrapper_marker" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_GATE="$wrapper_gate" \
      BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_PID_FILE="$wrapper_pid_file" \
      "$PYTHON3" - "$PTY_RUNNER" >"$output" 2>&1 <<'PY'; then
import errno
import os
import pty
import select
import signal
import subprocess
import sys
import time

runner = sys.argv[1]
scenario = os.environ["PTY_CASE"]
supervisor_ready_gate = os.environ["PTY_SUPERVISOR_READY_GATE"]
runner_identity = os.environ["PTY_RUNNER_IDENTITY_FILE"]
foreground_mode_file = os.environ["PTY_FOREGROUND_MODE_FILE"]
helper_pid_file = os.environ["FAKE_SUDO_HELPER_PID"]
worker_pid_file = os.environ["FAKE_SUDO_WORKER_PID"]
finalizer_pid_file = os.environ["BOOTSTRAP_INTERNAL_TEST_SUDO_FINALIZER_PID_FILE"]
shared_peer_pid_file = os.environ["PTY_SHARED_GROUP_PEER_PID_FILE"]
shared_runner_status_file = os.environ["PTY_SHARED_RUNNER_STATUS_FILE"]
shared_after_failure_gate = os.environ["PTY_SHARED_AFTER_FAILURE_GATE"]
payload_started = os.environ["PTY_PAYLOAD_STARTED_FILE"]
wrapper_marker = os.environ[
    "BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_MARKER"
]
wrapper_pid_file = os.environ[
    "BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_PID_FILE"
]

report_read, report_write = os.pipe()
os.set_blocking(report_read, False)
supervisor_pid = None
runner_pid = None
master_fd = None
reports = []
report_buffer = b""
supervisor_status = None
completed = False


def write_report(message):
    os.write(report_write, (message + "\n").encode("ascii"))


def supervisor():
    global runner_pid
    os.close(report_read)
    runner_pid = os.fork()
    if runner_pid == 0:
        os.close(report_write)
        os.setpgid(0, 0)
        os.execve(runner, [runner], os.environ.copy())
    for _ in range(100):
        try:
            os.setpgid(runner_pid, runner_pid)
            break
        except ProcessLookupError:
            write_report("runner-lost")
            os._exit(125)
        except PermissionError:
            break
        except OSError as error:
            if error.errno != errno.EINTR:
                write_report("runner-pgid-error:%d" % error.errno)
                os._exit(125)
    try:
        os.tcsetpgrp(0, runner_pid)
    except OSError as error:
        write_report("tcsetpgrp-error:%d" % error.errno)
        os._exit(125)
    open(supervisor_ready_gate, "w", encoding="utf-8").close()
    write_report("runner:%d" % runner_pid)
    while True:
        _, status = os.waitpid(runner_pid, os.WUNTRACED)
        if os.WIFSTOPPED(status):
            write_report("stopped:%d" % os.WSTOPSIG(status))
            continue
        if os.WIFEXITED(status):
            write_report("exit:%d" % os.WEXITSTATUS(status))
        elif os.WIFSIGNALED(status):
            write_report("signal:%d" % os.WTERMSIG(status))
        else:
            write_report("runner-status:%d" % status)
        try:
            os.tcsetpgrp(0, os.getpgrp())
        except OSError:
            pass
        os._exit(0)


def pump():
    global report_buffer, supervisor_status
    watched = [report_read]
    if master_fd is not None:
        watched.append(master_fd)
    readable, _, _ = select.select(watched, [], [], 0.02)
    for descriptor in readable:
        if descriptor == report_read:
            try:
                chunk = os.read(report_read, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                continue
            report_buffer += chunk
            while b"\n" in report_buffer:
                line, report_buffer = report_buffer.split(b"\n", 1)
                reports.append(line.decode("ascii", "replace"))
        else:
            try:
                os.read(master_fd, 4096)
            except OSError:
                pass
    if supervisor_status is None:
        try:
            waited, status = os.waitpid(supervisor_pid, os.WNOHANG)
        except ChildProcessError:
            waited, status = supervisor_pid, supervisor_status
        if waited:
            supervisor_status = status


def wait_for(predicate, description, timeout=12.0, allow_supervisor_exit=False):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pump()
        if predicate():
            return
        if supervisor_status is not None and not allow_supervisor_exit:
            raise RuntimeError("%s: supervisor exited early (%r; reports=%r)" % (
                description, supervisor_status, reports
            ))
        time.sleep(0.01)
    raise RuntimeError("%s: timed out (reports=%r)" % (description, reports))


def read_lines(path, count):
    with open(path, "r", encoding="utf-8") as handle:
        values = [line.strip() for line in handle]
    if len(values) != count or not all(values):
        raise RuntimeError("invalid %s: %r" % (path, values))
    return values


def read_pid(path):
    value = read_lines(path, 1)[0]
    if not value.isdigit():
        raise RuntimeError("invalid pid in %s: %r" % (path, value))
    return int(value)


def process_is_live(pid):
    try:
        output = subprocess.check_output(
            ["/bin/ps", "-o", "state=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return False
    return bool(output) and "Z" not in output


def cleanup():
    for pgid in (runner_pid, supervisor_pid):
        if pgid:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    if supervisor_pid and supervisor_status is None:
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            try:
                waited, _ = os.waitpid(supervisor_pid, os.WNOHANG)
            except ChildProcessError:
                break
            if waited:
                break
            time.sleep(0.02)


try:
    supervisor_pid, master_fd = pty.fork()
    if supervisor_pid == 0:
        supervisor()
        os._exit(125)
    os.close(report_write)
    wait_for(lambda: any(item.startswith("runner:") for item in reports),
             "runner process-group publication")
    runner_pid = int(next(item.split(":", 1)[1] for item in reports
                          if item.startswith("runner:")))
    if scenario == "shared":
        wait_for(lambda: os.path.isfile(shared_peer_pid_file) and
                 os.path.getsize(shared_peer_pid_file) > 0 and
                 os.path.isfile(payload_started) and
                 os.path.isfile(runner_identity) and
                 os.path.getsize(runner_identity) > 0 and
                 os.path.isfile(helper_pid_file) and
                 os.path.getsize(helper_pid_file) > 0,
                 "shared foreground group fallback startup")
        if read_lines(foreground_mode_file, 1)[0] != "0":
            raise RuntimeError("shared process group selected foreground mode")
        peer_pid = read_pid(shared_peer_pid_file)
        helper_pid = read_pid(helper_pid_file)
        _, runner_pgid = read_lines(runner_identity, 2)
        if os.getpgid(peer_pid) != int(runner_pgid):
            raise RuntimeError("shared peer is not in the runner process group")
        os.kill(helper_pid, signal.SIGKILL)
        wait_for(lambda: os.path.isfile(shared_runner_status_file) and
                 os.path.getsize(shared_runner_status_file) > 0,
                 "shared peer fallback cleanup", timeout=15.0)
        if not process_is_live(peer_pid):
            raise RuntimeError("shared foreground-group peer was killed")
        open(shared_after_failure_gate, "w", encoding="utf-8").close()
        wait_for(lambda: any(item.startswith("signal:") or item.startswith("exit:")
                             for item in reports),
                 "shared peer runner completion", timeout=15.0)
    else:
        wait_for(lambda: os.path.isfile(wrapper_marker) and
                 os.path.isfile(wrapper_pid_file) and
                 os.path.getsize(wrapper_pid_file) > 0 and
                 os.path.isfile(runner_identity) and
                 os.path.getsize(runner_identity) > 0 and
                 os.path.isfile(helper_pid_file) and
                 os.path.getsize(helper_pid_file) > 0 and
                 os.path.isfile(worker_pid_file) and
                 os.path.getsize(worker_pid_file) > 0 and
                 os.path.isfile(finalizer_pid_file) and
                 os.path.getsize(finalizer_pid_file) > 0,
                 "unpublished foreground wrapper startup")
        wrapper_pid = read_pid(wrapper_pid_file)
        helper_pid = read_pid(helper_pid_file)
        worker_pid = read_pid(worker_pid_file)
        finalizer_pid = read_pid(finalizer_pid_file)
        _, runner_pgid = read_lines(runner_identity, 2)
        if os.getpgid(wrapper_pid) != int(runner_pgid):
            raise RuntimeError("unpublished wrapper is outside the foreground group")
        if os.getpgid(finalizer_pid) in (int(runner_pgid), os.getpgid(worker_pid)):
            raise RuntimeError("foreground finalizer is not in a separate process group")
        os.kill(wrapper_pid, signal.SIGSTOP)
        wait_for(lambda: "T" in subprocess.check_output(
            ["/bin/ps", "-o", "state=", "-p", str(wrapper_pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ), "wrapper SIGSTOP state")
        owner_pid = helper_pid if scenario == "helper" else worker_pid
        os.kill(owner_pid, signal.SIGKILL)
        wait_for(lambda: any(item.startswith("signal:") or item.startswith("exit:")
                             for item in reports),
                 "%s loss cleanup" % scenario, timeout=15.0)
        wait_for(lambda: not process_is_live(wrapper_pid) and
                 not process_is_live(runner_pid) and
                 not process_is_live(helper_pid) and
                 not process_is_live(worker_pid) and
                 not process_is_live(finalizer_pid),
                 "%s guardian cleanup" % scenario, timeout=8.0,
                 allow_supervisor_exit=True)
        if os.path.exists(payload_started):
            raise RuntimeError("unpublished wrapper reached the payload")
    wait_for(lambda: supervisor_status is not None, "supervisor exit", timeout=8.0)
    if supervisor_status is None or not os.WIFEXITED(supervisor_status) or \
            os.WEXITSTATUS(supervisor_status) != 0:
        raise RuntimeError("supervisor did not exit cleanly: %r" % supervisor_status)
    completed = True
except Exception as error:
    print("PTY case failed: %s" % error, file=sys.stderr)
    cleanup()
    raise
finally:
    if not completed:
        cleanup()
    if master_fd is not None:
        try:
            os.close(master_fd)
        except OSError:
            pass
    os.close(report_read)
PY
      echo "not ok - $case_name" >&2
      sed -n '1,160p' "$output" >&2
      TESTS_FAILED=$((TESTS_FAILED + 1))
      return
    fi
  fi

  if ! grep -Fx invalidate "$events" >/dev/null 2>&1; then
    echo "not ok - $case_name: sudo timestamp was not invalidated" >&2
    sed -n '1,160p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi
  if grep -Fx 'invalidate-while-child-alive' "$events" >/dev/null 2>&1 ||
    grep -Fx 'invalidate-before-worker-reap' "$events" >/dev/null 2>&1; then
    echo "not ok - $case_name: sudo was invalidated before the worker cage ended" >&2
    sed -n '1,160p' "$output" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return
  fi

  echo "ok - $case_name"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

run_test keepalive-child run_keepalive_case 'sudo keep-alive child cleanup' 0
run_test keepalive-refresh-failure run_keepalive_case 'sudo keep-alive refresh failure cleanup' 1
run_test parent-sigkill-refresh run_parent_death_case 'sudo keep-alive parent SIGKILL during refresh cleanup' parent-sigkill-refresh 0
run_test parent-sigkill-reservation run_parent_death_case 'sudo keep-alive parent SIGKILL during reservation cleanup' parent-sigkill-reservation 1
run_test initialization-failure run_initialization_failure_case
run_test setup-child-fd run_setup_child_fd_case
run_test privileged-failure run_privileged_failure_case
run_test reaped-pid-reuse run_reaped_pid_reuse_case
run_test wrapper-fork-registration-race run_wrapper_fork_registration_race_case
run_test wrapper-prepublication-worker-sigkill run_wrapper_prepublication_worker_sigkill_case
run_test process-identity-reuse-guard run_process_identity_reuse_guard_case
run_test process-protocol-source-guard run_process_protocol_source_guard_case
run_test wrapper-reaped-identity-unpublished run_wrapper_reaped_identity_unpublished_case
run_test worker-reaped-identity-unpublished run_worker_reaped_identity_unpublished_case
run_test setup-reaped-identity-unpublished run_setup_reaped_identity_unpublished_case
run_test startup-parent-death run_startup_parent_death_case
run_test setup-request-consumed-once run_setup_request_consumed_once_case
run_test keepalive-failure-sleep run_keepalive_failure_propagation_case sleep
run_test keepalive-failure-sudo run_keepalive_failure_propagation_case sudo
run_test keepalive-owner-sigkill-helper run_keepalive_owner_sigkill_case helper
run_test keepalive-owner-sigkill-worker run_keepalive_owner_sigkill_case worker
run_test keepalive-wrapper-sigkill-worker run_keepalive_wrapper_sigkill_case worker
run_test keepalive-wrapper-sigkill-setup run_keepalive_wrapper_sigkill_case setup
run_test foreground-interactive run_foreground_pty_case interactive
run_test foreground-background run_foreground_pty_case background
run_test foreground-shared run_foreground_pty_case shared
run_test foreground-helper run_foreground_pty_case helper
run_test foreground-worker run_foreground_pty_case worker
run_test homebrew-path-propagation run_homebrew_path_propagation_case
run_test homebrew-path-resolution run_homebrew_path_resolution_case

if [ -n "$TEST_FILTER" ] && [ "$TEST_FILTER_MATCHED" -eq 0 ]; then
  echo "not ok - unknown BOOTSTRAP_TEST_FILTER: $TEST_FILTER" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

printf '%s passed, %s failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
