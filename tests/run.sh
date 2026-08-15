#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$repo_dir/tests/fixtures"
test_root="$(mktemp -d)"

source_working_dir="$PWD"
cd "$repo_dir"
source lib/process-lock.sh
source lib/setup-common.sh
cd "$source_working_dir"
unset source_working_dir

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "$3 (expected: $2, actual: $1)"
}

test_pre_bash_guard() {
  local scanner="$repo_dir/.claude/hooks/pre-bash-guard.py"
  local wrapper="$repo_dir/.claude/hooks/pre-bash-guard.sh"
  local output
  local status

  output="$(python3 "$scanner" <"$fixture_dir/pre-bash-guard/allow.json")"
  assert_equal "$output" '' 'safe command must be allowed silently'

  output="$(bash "$wrapper" <"$fixture_dir/pre-bash-guard/deny.json")"
  jq -e \
    '.hookSpecificOutput.permissionDecision == "deny" and
     (.hookSpecificOutput.permissionDecisionReason | contains("rm -rf"))' \
    <<<"$output" >/dev/null || fail 'dangerous command must be denied'

  mkdir -p "$test_root/deployed-hooks"
  ln -s "$wrapper" "$test_root/deployed-hooks/pre-bash-guard.sh"
  ln -s "$scanner" "$test_root/deployed-hooks/pre-bash-guard.py"
  output="$(
    bash "$test_root/deployed-hooks/pre-bash-guard.sh" \
      <"$fixture_dir/pre-bash-guard/deny.json"
  )"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null ||
    fail 'deployed symlink wrapper must resolve the repository scanner'

  set +e
  output="$(
    bash "$wrapper" <"$fixture_dir/pre-bash-guard/invalid.json" 2>&1
  )"
  status=$?
  set -e
  assert_equal "$status" 2 'invalid hook JSON must fail closed'
  [[ "$output" == *'invalid hook input JSON'* ]] ||
    fail 'invalid hook JSON must explain the failure'
}

make_counting_jq() {
  local destination="$1"

  cp "$fixture_dir/helpers/counting-jq.sh" "$destination"
  chmod +x "$destination"
}

test_statusline() {
  local statusline="$repo_dir/.claude/hooks/statusline.sh"
  local status_root="$test_root/statusline"
  local expected
  local output
  local call_count
  local no_jq_bin
  local command_path

  mkdir -p "$status_root/bin"
  make_counting_jq "$status_root/bin/jq"
  : >"$status_root/jq-calls"

  output="$(
    REAL_JQ="$(command -v jq)" \
      JQ_COUNT_FILE="$status_root/jq-calls" \
      PATH="$status_root/bin:$PATH" \
      CODEX_STATUSLINE_CODEX_CONFIG="$fixture_dir/statusline/config.toml" \
      CODEX_STATUSLINE_CLAUDE_SETTINGS="$fixture_dir/statusline/settings.json" \
      bash "$statusline" <"$fixture_dir/statusline/input.json"
  )"
  expected=$'Claude\nOpus max · /tmp/statusline-project · Context 13% used · 5h limit 13% used · Weekly limit 50% used'
  assert_equal "$output" "$expected" 'statusline must preserve values and fallback order'
  call_count="$(wc -l <"$status_root/jq-calls" | tr -d ' ')"
  assert_equal "$call_count" 2 'statusline must parse input and settings once each'

  printf '{}\n' >"$status_root/empty-input.json"
  output="$(
    CODEX_STATUSLINE_CODEX_CONFIG="$fixture_dir/statusline/config.toml" \
      CODEX_STATUSLINE_CLAUDE_SETTINGS="$fixture_dir/statusline/settings.json" \
      bash "$statusline" <"$status_root/empty-input.json"
  )"
  [[ "$output" == "settings-model high"* ]] ||
    fail 'Claude settings must take precedence over TOML fallbacks'

  printf '%s\n' \
    '{"cwd":"/tmp/malformed","model":"string-model","context":"bad","context_window":"bad","usage":"bad","rate_limits":"bad","effort":"bad"}' \
    >"$status_root/malformed-fields.json"
  output="$(
    CODEX_STATUSLINE_CODEX_CONFIG="$fixture_dir/statusline/config.toml" \
      CODEX_STATUSLINE_CLAUDE_SETTINGS="$fixture_dir/statusline/settings.json" \
      bash "$statusline" <"$status_root/malformed-fields.json"
  )"
  [[ "$output" == "string-model high · /tmp/malformed"* ]] ||
    fail 'malformed optional fields must not discard valid input fields'

  printf '%s\n' \
    '{"message":{"usage":{"total_tokens":24000}}}' \
    >"$status_root/transcript.jsonl"
  jq -n \
    --arg transcript_path "$status_root/transcript.jsonl" \
    '{model: "transcript-model", transcript_path: $transcript_path}' \
    >"$status_root/transcript-input.json"
  output="$(
    CODEX_STATUSLINE_CODEX_CONFIG="$fixture_dir/statusline/config.toml" \
      CODEX_STATUSLINE_CLAUDE_SETTINGS="$fixture_dir/statusline/settings.json" \
      bash "$statusline" <"$status_root/transcript-input.json"
  )"
  [[ "$output" == "transcript-model high"*'Context 7% used'* ]] ||
    fail 'transcript usage must remain the final context fallback'

  printf '{\n' >"$status_root/invalid-input.json"
  printf '{\n' >"$status_root/invalid-settings.json"
  output="$(
    CODEX_STATUSLINE_CODEX_CONFIG="$fixture_dir/statusline/config.toml" \
      CODEX_STATUSLINE_CLAUDE_SETTINGS="$status_root/invalid-settings.json" \
      bash "$statusline" <"$status_root/invalid-input.json"
  )"
  [[ "$output" == "toml-model medium"* ]] ||
    fail 'invalid JSON must fall back to TOML settings'
  [[ "$output" == *'Context 0% used'* ]] ||
    fail 'invalid JSON must retain the context fallback'

  no_jq_bin="$status_root/no-jq-bin"
  mkdir "$no_jq_bin"
  for command_path in bash dirname readlink cat awk sed grep tr; do
    ln -s "$(command -v "$command_path")" "$no_jq_bin/$command_path"
  done
  output="$(
    PATH="$no_jq_bin" \
      CODEX_STATUSLINE_CODEX_CONFIG="$fixture_dir/statusline/config.toml" \
      CODEX_STATUSLINE_CLAUDE_SETTINGS="$fixture_dir/statusline/settings.json" \
      /usr/bin/bash "$statusline" <"$fixture_dir/statusline/input.json"
  )"
  [[ "$output" == "toml-model medium"* ]] ||
    fail 'statusline without jq must fall back to TOML settings'
}

reset_process_lock_state() {
  PROCESS_LOCK_HELD=0
  exec 9>&- || true
}

test_process_lock() {
  local lock_root="$test_root/locks"
  local lock_path
  local generation
  local holder
  local target
  local start_identity

  mkdir -p "$lock_root"

  lock_path="$lock_root/legacy-directory"
  mkdir "$lock_path"
  printf '99999999\nstale\n' >"$lock_path/owner"
  process_lock_acquire "$lock_path" '' test 2 ||
    fail 'stale legacy directory lock must migrate'
  [[ -f "$lock_path" && ! -L "$lock_path" ]] ||
    fail 'legacy directory lock must become a regular lock file'
  process_lock_release

  lock_path="$lock_root/legacy-generation"
  generation="$lock_root/.link-dotfiles.lock.generation.ABC123"
  mkdir -p "$generation/recovery"
  printf '99999999\nstale\n' >"$generation/owner"
  printf '99999998\nstale\n' >"$generation/recovery/owner"
  ln -s "${generation##*/}" "$lock_path"
  process_lock_acquire \
    "$lock_path" '.link-dotfiles.lock.generation.??????' test 3 ||
    fail 'stale generation and recovery mutex must migrate'
  [[ -f "$lock_path" && ! -L "$lock_path" && ! -e "$generation" ]] ||
    fail 'legacy generation must be removed after migration'
  process_lock_release

  lock_path="$lock_root/forced-exit"
  mkfifo "$lock_root/hold"
  (
    process_lock_acquire "$lock_path" '' holder 2
    printf 'ready\n' >"$lock_root/ready"
    IFS= read -r _ <"$lock_root/hold"
  ) &
  holder=$!
  for _ in {1..200}; do
    [[ -f "$lock_root/ready" ]] && break
    sleep 0.01
  done
  [[ -f "$lock_root/ready" ]] || fail 'lock holder did not start'
  if process_lock_acquire "$lock_path" '' contender 1 2>/dev/null; then
    kill -9 "$holder" 2>/dev/null || true
    fail 'concurrent lock acquisition must time out'
  fi
  kill -9 "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  reset_process_lock_state
  process_lock_acquire "$lock_path" '' contender 2 ||
    fail 'OS lock must be released after forced termination'
  process_lock_release

  target="$lock_root/symlink-target"
  printf 'unchanged\n' >"$target"
  lock_path="$lock_root/unsafe-link"
  ln -s "$target" "$lock_path"
  if process_lock_acquire "$lock_path" '' unsafe 1 2>/dev/null; then
    fail 'symlink lock path must be rejected'
  fi
  assert_equal "$(cat "$target")" unchanged \
    'unsafe lock path must not modify its target'

  lock_path="$lock_root/live-legacy"
  mkdir "$lock_path"
  start_identity="$(process_lock_start_identity "$$")"
  printf '%s\n%s\n' "$$" "$start_identity" >"$lock_path/owner"
  if process_lock_acquire "$lock_path" '' live 1 2>/dev/null; then
    fail 'live legacy owner must not be recovered'
  fi
  [[ -d "$lock_path" ]] || fail 'live legacy lock must remain untouched'

  if [[ "$(uname -s)" == Linux ]]; then
    lock_path="$lock_root/toctou"
    : >"$lock_path"
    mkdir "$lock_root/fake-bin"
    cp "$fixture_dir/helpers/swap-flock.sh" "$lock_root/fake-bin/flock"
    chmod +x "$lock_root/fake-bin/flock"
    if LOCK_SWAP_PATH="$lock_path" PATH="$lock_root/fake-bin:$PATH" \
      process_lock_acquire "$lock_path" '' toctou 1 2>/dev/null; then
      fail 'lock path replacement during acquisition must be rejected'
    fi
    [[ -f "$lock_path.opened" && -f "$lock_path" ]] ||
      fail 'TOCTOU fixture must replace the opened lock path'
  fi
}

test_lock_backend_contract() {
  local darwin_branch

  darwin_branch="$(
    sed -n '/^[[:space:]]*Darwin)/,/^[[:space:]]*;;/p' \
      "$repo_dir/lib/process-lock.sh"
  )"
  [[ "$darwin_branch" == *'/usr/bin/lockf -s -t'* ]] ||
    fail 'Darwin lock backend must use macOS /usr/bin/lockf'
  [[ "$darwin_branch" != *flock* ]] ||
    fail 'Linux flock fallback must not weaken the Darwin lock contract'
}

make_test_repository() {
  local repository="$1"
  local origin="$2"
  local executable="$3"

  mkdir -p "$repository/$(dirname "$executable")"
  git -C "$repository" init -q
  git -C "$repository" remote add origin "$origin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repository/$executable"
  chmod +x "$repository/$executable"
}

test_repository_validation() {
  local repository="$test_root/repository-validation"
  local origin='https://example.invalid/repository.git'

  make_test_repository "$repository" "$origin" bin/manage
  setup_verify_repository \
    "$repository" "$origin" Example REPO_DIR REPO_URL bin/manage missing ||
    fail 'valid repository fixture must pass'
  if setup_verify_repository \
    "$repository/bin" "$origin" Example REPO_DIR REPO_URL manage missing \
    >/dev/null; then
    fail 'repository subdirectory must be rejected'
  fi
  mv "$repository/bin/manage" "$repository/bin/manage-real"
  ln -s manage-real "$repository/bin/manage"
  if setup_verify_repository \
    "$repository" "$origin" Example REPO_DIR REPO_URL bin/manage missing \
    >/dev/null; then
    fail 'symlinked management executable must be rejected'
  fi
}

test_skills_clone_and_publish() {
  local source_repository="$test_root/skills-source"
  local bare_repository="$test_root/skills-origin.git"
  local destination="$test_root/skills-home/agent-skills"
  local log="$test_root/skills-sync.log"

  mkdir -p "$source_repository/bin" "$(dirname "$destination")"
  git -C "$source_repository" init -q
  cp "$fixture_dir/helpers/agent-skills.sh" \
    "$source_repository/bin/agent-skills"
  chmod +x "$source_repository/bin/agent-skills"
  git -C "$source_repository" add bin/agent-skills
  git -C "$source_repository" \
    -c user.name=Test \
    -c user.email=test@example.invalid \
    -c commit.gpgSign=false \
    commit -qm initial
  git clone --bare -q "$source_repository" "$bare_repository"

  : >"$log"
  HOME="$test_root/skills-home" \
    AGENT_SKILLS_REPO_DIR="$destination" \
    AGENT_SKILLS_REPO_URL="$bare_repository" \
    SKILLS_LOG="$log" \
    bash "$repo_dir/skills/setup.sh"
  [[ -d "$destination/.git" ]] ||
    fail 'Agent Skills setup must publish a verified clone'
  [[ -f "$destination.publish-lock" && ! -L "$destination.publish-lock" ]] ||
    fail 'Agent Skills publish lock must use a persistent regular file'
  assert_equal "$(cat "$log")" sync \
    'Agent Skills setup must run the repository management CLI'

  HOME="$test_root/skills-home" \
    AGENT_SKILLS_REPO_DIR="$destination" \
    AGENT_SKILLS_REPO_URL="$bare_repository" \
    SKILLS_LOG="$log" \
    bash "$repo_dir/skills/setup.sh"
  assert_equal "$(cat "$log")" $'sync\nsync' \
    'existing Agent Skills checkout must remain reusable'
}

make_pet_installer() {
  local destination="$1"

  cp "$fixture_dir/helpers/pet-installer.sh" "$destination"
  chmod +x "$destination"
}

test_pet_capability_fallback() {
  local repository="$test_root/pets-repository"
  local origin='https://example.invalid/pets.git'
  local fake_bin="$test_root/pets-bin"
  local home="$test_root/pets-home"
  local log="$test_root/pets-install.log"
  local output

  make_test_repository "$repository" "$origin" bin/install-pet
  make_pet_installer "$repository/bin/install-pet"
  mkdir -p "$repository/pets/alpha" "$repository/pets/beta" "$fake_bin" "$home"
  printf '{}\n' >"$repository/pets/alpha/pet.json"
  printf '{}\n' >"$repository/pets/beta/pet.json"
  cp "$fixture_dir/helpers/lockf.sh" "$fake_bin/lockf"
  chmod +x "$fake_bin/lockf"

  : >"$log"
  output="$(
    HOME="$home" \
      CODEX_HOME="$home/codex-supported" \
      CODEX_CUSTOM_PETS_REPO_DIR="$repository" \
      CODEX_CUSTOM_PETS_REPO_URL="$origin" \
      INSTALL_LOG="$log" \
      CAPABILITY_MODE=supported \
      PATH="$fake_bin:$PATH" \
      bash "$repo_dir/pets/setup.sh"
  )"
  assert_equal "$(cat "$log")" $'--capabilities\n--all' \
    'supported installer must use one batch installation'
  [[ -z "$output" ]] || fail 'test installer must stay silent'

  : >"$log"
  HOME="$home" \
    CODEX_HOME="$home/codex-fallback" \
    CODEX_CUSTOM_PETS_REPO_DIR="$repository" \
    CODEX_CUSTOM_PETS_REPO_URL="$origin" \
    INSTALL_LOG="$log" \
    CAPABILITY_MODE=unsupported \
    PATH="$fake_bin:$PATH" \
    bash "$repo_dir/pets/setup.sh" >/dev/null
  assert_equal "$(cat "$log")" $'--capabilities\nalpha\nbeta' \
    'unsupported installer must fall back to individual pets'
}

test_link_dry_run() {
  local home="$test_root/link-home"
  local output

  mkdir "$home"
  output="$(HOME="$home" bash "$repo_dir/scripts/link-dotfiles.sh" --dry-run)"
  [[ ! -e "$home/.dotfiles-backup" ]] ||
    fail 'link dry-run must not create its lock or backup root'
  [[ "$output" == *"$home/.codex/AGENTS.md -> $repo_dir/.config/agents/AGENTS.md"* ]] ||
    fail 'Codex AGENTS link must point directly to the shared source'
  [[ "$output" == *"$home/.claude/hooks/pre-bash-guard.py"* ]] ||
    fail 'guard scanner module must be included in link deployment'
}

test_pre_bash_guard
test_statusline
test_process_lock
test_lock_backend_contract
test_repository_validation
test_skills_clone_and_publish
test_pet_capability_fallback
test_link_dry_run

jq -e \
  '.hooks.PreToolUse[0].hooks[0].command ==
   "$HOME/.claude/hooks/pre-bash-guard.sh"' \
  "$repo_dir/.claude/settings.json" >/dev/null ||
  fail 'Claude settings must invoke the guard wrapper'

printf 'All dotfiles tests passed.\n'
