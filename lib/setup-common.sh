#!/usr/bin/env bash
# セットアップスクリプトの共通関数

# git の対話認証を抑止
setup_run_noninteractive_git() {
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false git "$@"
}

# 未取得の非公開リポジトリを clone（アクセス不可のスキップは 3）
setup_ensure_private_checkout() {
  local repository_dir="$1"
  local repository_url="$2"
  local label="$3"

  [[ ! -e "$repository_dir" ]] || return 0

  if ! setup_run_noninteractive_git ls-remote -- "$repository_url" HEAD >/dev/null 2>&1; then
    printf 'skipped: %s (private repository is inaccessible)\n' "$label"
    return 3
  fi

  setup_run_noninteractive_git clone --quiet --no-recurse-submodules -- \
    "$repository_url" "$repository_dir"
}
