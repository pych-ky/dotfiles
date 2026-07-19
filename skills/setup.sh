#!/usr/bin/env bash
#
# private Agent Skills の checkout を用意し、repository 側の管理 CLI へ処理を委譲する。

set -euo pipefail

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

# Git の認証プロンプトで bootstrap 全体が待ち続けないよう非対話で実行する
run_noninteractive_git() {
  GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=Never \
    GIT_ASKPASS=/usr/bin/false \
    SSH_ASKPASS=/usr/bin/false \
    GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
    git "$@"
}

main() {
  local skip="${AGENT_SKILLS_SKIP:-0}"
  local strict="${AGENT_SKILLS_STRICT:-0}"
  local home_dir="${HOME:-}"
  local repository_url="${AGENT_SKILLS_REPO_URL:-https://github.com/pych-ky/agent-skills.git}"
  local repository_dir
  local repository_parent
  local repository_root
  local repository_dir_physical
  local repository_root_physical
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
  if [[ "$repository_dir" != /* || "$repository_dir" == / ]]; then
    error 'AGENT_SKILLS_REPO_DIR must be an absolute path other than /'
    return 1
  fi

  if ! command -v git >/dev/null 2>&1; then
    error 'git is required for Agent Skills setup'
    return 1
  fi

  if [[ ! -e "$repository_dir" && ! -L "$repository_dir" ]]; then
    clone_required=1
    if ! run_noninteractive_git ls-remote "$repository_url" HEAD >/dev/null 2>&1; then
      if handle_access_failure "$strict"; then
        return 0
      fi
      return 1
    fi
  fi

  if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))'; then
    error 'Python 3.9 or newer is required for Agent Skills setup'
    return 1
  fi

  if ((clone_required)); then
    repository_parent="$(dirname "$repository_dir")"
    mkdir -p "$repository_parent"
    if ! run_noninteractive_git clone --quiet --no-recurse-submodules \
      "$repository_url" "$repository_dir"; then
      error 'Agent Skills repository could not be cloned'
      return 1
    fi
  fi

  if [[ ! -d "$repository_dir" ]] ||
    ! repository_root="$(git -C "$repository_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    error 'Agent Skills destination is not a Git working tree'
    return 1
  fi

  repository_dir_physical="$(cd "$repository_dir" && pwd -P)"
  repository_root_physical="$(cd "$repository_root" && pwd -P)"
  if [[ "$repository_dir_physical" != "$repository_root_physical" ]]; then
    error 'AGENT_SKILLS_REPO_DIR must point to the repository root'
    return 1
  fi

  if [[ ! -x "$repository_dir/bin/agent-skills" ]]; then
    error 'Agent Skills management CLI is missing or not executable'
    return 1
  fi

  "$repository_dir/bin/agent-skills" sync
}

main "$@"
