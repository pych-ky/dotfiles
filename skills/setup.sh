#!/usr/bin/env bash
# private Agent Skills の checkout を用意し、repository 側の setup.sh に配置を委譲する。

set -euo pipefail

temporary_clone_dir=

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup_common_library="$script_dir/../lib/setup-common.sh"
process_lock_library="$script_dir/../lib/process-lock.sh"
for library in "$setup_common_library" "$process_lock_library"; do
  if [[ ! -f "$library" || -L "$library" ]]; then
    printf 'error: setup library is missing or unsafe: %s\n' "$library" >&2
    exit 1
  fi
done
source_working_dir="$PWD"
cd "$script_dir/.." || exit 1
source lib/setup-common.sh
source lib/process-lock.sh
cd "$source_working_dir" || exit 1
unset source_working_dir

error() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

# private repository への認証が未設定の端末では Agent Skills だけをスキップする
handle_access_failure() {
  if [[ "$1" == 1 ]]; then
    error 'private Agent Skills repository is not accessible'
    return 1
  fi

  printf 'warning: private Agent Skills repository is not accessible; skipping\n' >&2
}

# 一時 clone と自プロセスが所有する公開ロックを終了時に清掃
cleanup() {
  [[ -z "$temporary_clone_dir" ]] || rm -rf "$temporary_clone_dir"
  process_lock_release 2>/dev/null || true
}

# 保存先の repository root と origin、setup.sh の実行権を確認
verify_repository() {
  local repository_dir="$1"
  local expected_url="$2"
  local repository_error

  if ! repository_error="$(setup_verify_repository \
    "$repository_dir" \
    "$expected_url" \
    'Agent Skills' \
    'AGENT_SKILLS_REPO_DIR' \
    'AGENT_SKILLS_REPO_URL' \
    'setup.sh' \
    'Agent Skills setup script is missing or not executable')"; then
    error "$repository_error"
    return 1
  fi
}

main() {
  local skip="${AGENT_SKILLS_SKIP:-0}"
  local strict="${AGENT_SKILLS_STRICT:-0}"
  local home_dir="${HOME:-}"
  local repository_url="${AGENT_SKILLS_REPO_URL:-https://github.com/pych-ky/agent-skills.git}"
  local repository_dir
  local repository_parent
  local clone_required=0

  if (($#)); then
    error 'arguments are not supported'
    return 1
  fi

  case "$skip" in
  0) ;;
  1)
    printf 'Agent Skills setup is disabled; skipping\n'
    return 0
    ;;
  *)
    error 'AGENT_SKILLS_SKIP must be 0 or 1'
    return 1
    ;;
  esac

  case "$strict" in
  0 | 1) ;;
  *)
    error 'AGENT_SKILLS_STRICT must be 0 or 1'
    return 1
    ;;
  esac

  if [[ -z "$home_dir" || "$home_dir" != /* ]]; then
    error 'HOME must be an absolute path'
    return 1
  fi

  repository_dir="${AGENT_SKILLS_REPO_DIR:-$home_dir/src/pych/agent-skills}"
  while [[ "$repository_dir" != / ]]; do
    case "$repository_dir" in
    */) repository_dir="${repository_dir%/}" ;;
    */.) repository_dir="${repository_dir%/.}" ;;
    *) break ;;
    esac
  done
  if [[ "$repository_dir" != /* || "$repository_dir" == / ]]; then
    error 'AGENT_SKILLS_REPO_DIR must be an absolute path other than /'
    return 1
  fi

  if ! command -v git >/dev/null 2>&1; then
    error 'git is required for Agent Skills setup'
    return 1
  fi

  if [[ -z "$repository_url" ]]; then
    error 'AGENT_SKILLS_REPO_URL must not be empty'
    return 1
  fi

  if [[ ! -e "$repository_dir" && ! -L "$repository_dir" ]]; then
    clone_required=1
    if ! setup_run_noninteractive_git ls-remote -- "$repository_url" HEAD >/dev/null 2>&1; then
      if handle_access_failure "$strict"; then
        return 0
      fi
      return 1
    fi
  fi

  if ((clone_required)); then
    repository_parent="$(dirname "$repository_dir")"
    mkdir -p "$repository_parent"
    temporary_clone_dir="$(mktemp -d "$repository_parent/.agent-skills.clone.XXXXXX")"
    trap 'cleanup' EXIT

    if ! setup_run_noninteractive_git clone --quiet --no-recurse-submodules -- \
      "$repository_url" "$temporary_clone_dir"; then
      error 'Agent Skills repository could not be cloned'
      return 1
    fi

    verify_repository "$temporary_clone_dir" "$repository_url" || return
    process_lock_acquire \
      "$repository_dir.publish-lock" \
      '' \
      'Agent Skills publish' \
      30 || return
    if [[ ! -e "$repository_dir" && ! -L "$repository_dir" ]]; then
      mv "$temporary_clone_dir" "$repository_dir"
      temporary_clone_dir=
    fi
    verify_repository "$repository_dir" "$repository_url" || return
    process_lock_release || return
  else
    verify_repository "$repository_dir" "$repository_url" || return
  fi

  "$repository_dir/setup.sh"
}

main "$@"
