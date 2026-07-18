#!/usr/bin/env bash
#
# ============================================================================
# 新しい Mac を一括セットアップするブートストラップスクリプト
# ============================================================================
#
# 実行内容:
#   1. sudo 認証 (パスワード入力はここでの 1 回だけ、特権処理中は keep-alive)
#   2. macos/defaults.sh による macOS 設定の適用
#   3. install.sh による dotfiles のシンボリックリンク展開
#   4. Homebrew の導入 (未導入時、Xcode Command Line Tools も同時に導入される)
#   5. Brewfile に基づくパッケージの一括インストール
#   6. zsh プラグインの取得
#   7. Claude Code CLI / Codex CLI の導入 (未導入時)
#   8. private Agent Skills のセットアップ (アクセス可能な場合)
#
# 終了後に手動で行う設定は README.md の「手動セットアップ」を参照。

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 進行状況の見出しを出力
step() {
  printf '\n==> %s\n' "$1"
}

# 実行可能な Homebrew の絶対パスを解決
resolve_homebrew_executable() {
  local brew_path=

  resolved_homebrew_executable=
  if [[ -n "${BOOTSTRAP_INTERNAL_TEST_HOMEBREW_PREFIX:-}" ]]; then
    resolved_homebrew_executable=$BOOTSTRAP_INTERNAL_TEST_HOMEBREW_PREFIX/bin/brew
  elif brew_path=$(command -v brew 2>/dev/null) && [[ -x "$brew_path" ]]; then
    if [[ "$brew_path" != /* ]]; then
      brew_path=$(cd -P "${brew_path%/*}" 2>/dev/null && printf '%s/%s\n' "$PWD" "${brew_path##*/}") ||
        return 1
    fi
    resolved_homebrew_executable=$brew_path
  elif [[ -x /opt/homebrew/bin/brew ]]; then
    resolved_homebrew_executable=/opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then
    resolved_homebrew_executable=/usr/local/bin/brew
  fi

  [[ -n "$resolved_homebrew_executable" &&
    "$resolved_homebrew_executable" == /* &&
    -x "$resolved_homebrew_executable" ]]
}

# Homebrew の shell environment を現在の shell へ反映
refresh_homebrew_environment() {
  local brew_environment=

  if ! resolve_homebrew_executable; then
    printf 'error: Homebrew was not found after installation\n' >&2
    return 1
  fi
  if ! brew_environment=$("$resolved_homebrew_executable" shellenv); then
    printf 'error: Homebrew environment could not be loaded\n' >&2
    return 1
  fi
  eval "$brew_environment"
}

run_bootstrap_privileged_setup() {
  local plugins_dir

  # ============================================================================
  # macOS 設定と dotfiles リンク
  # ============================================================================

  step 'macos/defaults.sh'
  "$repo_dir/macos/defaults.sh"

  step 'install.sh'
  # 一部リンクの失敗 (例: /etc/codex の競合) は致命ではないため、警告を出して続行
  if ! "$repo_dir/install.sh"; then
    printf 'warning: install.sh reported failures, continuing\n' >&2
  fi

  # ============================================================================
  # Homebrew
  # ============================================================================

  step 'Homebrew'
  if ! resolve_homebrew_executable; then
    # 事前の sudo 認証により NONINTERACTIVE でも成功する (確認プロンプトを省略して無人実行)
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  # このシェルの PATH に反映 (Apple Silicon: /opt/homebrew, Intel: /usr/local)
  refresh_homebrew_environment

  step 'brew bundle'
  # 一部パッケージの失敗 (例: 廃止された cask) は致命ではないため、警告を出して続行
  if ! brew bundle --file="$repo_dir/Brewfile"; then
    printf 'warning: brew bundle reported failures, continuing\n' >&2
  fi

  # ============================================================================
  # zsh プラグイン (.zshrc が ~/.zsh/plugins/*/*.plugin.zsh を一括ロードする)
  # ============================================================================

  step 'zsh plugins'
  plugins_dir="$HOME/.zsh/plugins"
  mkdir -p "$plugins_dir"
  [ -d "$plugins_dir/zsh-autosuggestions" ] ||
    git clone https://github.com/zsh-users/zsh-autosuggestions "$plugins_dir/zsh-autosuggestions"
  [ -d "$plugins_dir/fast-syntax-highlighting" ] ||
    git clone https://github.com/zdharma-continuum/fast-syntax-highlighting.git "$plugins_dir/fast-syntax-highlighting"

  # ============================================================================
  # Claude Code CLI
  # ============================================================================

  step 'Claude Code'
  if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
    curl -fsSL https://claude.ai/install.sh | bash
  fi

  # ============================================================================
  # Codex CLI
  # ============================================================================

  step 'Codex'
  if ! command -v codex >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/codex" ]; then
    curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
  fi
}

# ============================================================================
# sudo 認証 (パスワード入力は冒頭の 1 回だけ)
# ============================================================================

step 'sudo'
# 認証キャッシュ済みなら端末不要。端末がない非対話環境 (CI や AI エージェント等) では明示して終了
if ! sudo -n -v 2>/dev/null; then
  if ! { : </dev/tty; } 2>/dev/null; then
    printf 'error: sudo authentication requires an interactive terminal\n' >&2
    printf '       run ./bootstrap.sh from a local terminal\n' >&2
    exit 1
  fi
  sudo -v
fi

# 認証後の失敗時も sudo timestamp を無効化
trap 'sudo -k || true' EXIT

sudo_keepalive_pid=
sudo_keepalive_sentinel_pid=
sudo_keepalive_sentinel_directory=
sudo_keepalive_sentinel_path=
sudo_keepalive_parent_closed_path=
sudo_keepalive_worker_ready_path=
sudo_keepalive_sentinel_ready_path=
sudo_keepalive_helper_pid_path=
sudo_keepalive_worker_pid_path=
sudo_keepalive_worker_wrapper_pid_path=
sudo_keepalive_setup_wrapper_pid_path=
sudo_keepalive_finalizer_pid_path=
sudo_keepalive_setup_owner_group_identity_path=
sudo_keepalive_setup_request_path=
sudo_keepalive_setup_status_path=
sudo_keepalive_setup_completion_path=
sudo_keepalive_setup_ack_path=
sudo_keepalive_failure_status_path=
sudo_keepalive_setup_foreground_mode=0
sudo_keepalive_finalizer_pid=
cleanup_sudo_keepalive_sentinel() {
  if [[ -n "${sudo_keepalive_sentinel_directory:-}" ]]; then
    rm -f "$sudo_keepalive_sentinel_path" \
      "$sudo_keepalive_parent_closed_path" \
      "$sudo_keepalive_worker_ready_path" \
      "$sudo_keepalive_sentinel_ready_path" \
      "$sudo_keepalive_helper_pid_path" \
      "$sudo_keepalive_worker_pid_path" \
      "$sudo_keepalive_worker_wrapper_pid_path" \
      "$sudo_keepalive_setup_wrapper_pid_path" \
      "$sudo_keepalive_finalizer_pid_path" \
      "$sudo_keepalive_setup_owner_group_identity_path" \
      "$sudo_keepalive_setup_request_path" \
      "$sudo_keepalive_setup_status_path" \
      "$sudo_keepalive_setup_completion_path" \
      "$sudo_keepalive_setup_ack_path" \
      "$sudo_keepalive_failure_status_path" \
      "$sudo_keepalive_sentinel_directory"/child-status.* \
      "$sudo_keepalive_sentinel_directory"/child-ack.* \
      "$sudo_keepalive_sentinel_directory"/child-registration.* \
      "$sudo_keepalive_sentinel_directory"/shell-pid.* \
      "$sudo_keepalive_sentinel_directory"/*.pending.* 2>/dev/null || true
    rmdir "$sudo_keepalive_sentinel_directory" 2>/dev/null || true
  fi
}

bootstrap_process_is_live() {
  local inspected_pid=${1:-}
  local process_state=

  [[ "$inspected_pid" =~ ^[0-9]+$ && "$inspected_pid" -gt 1 ]] || return 1
  kill -0 "$inspected_pid" 2>/dev/null || return 1
  if process_state=$(/bin/ps -o state= -p "$inspected_pid" 2>/dev/null); then
    [[ "$process_state" != *Z* ]] || return 1
  fi
  return 0
}

capture_current_shell_pid() {
  local handoff_path=$1
  local captured_pid=

  bootstrap_captured_shell_pid=
  rm -f "$handoff_path" || return 1
  # Apple Bash 3.2 の subshell PID を子 shell の PPID から取得
  /bin/sh -c 'umask 077; printf "%s\n" "$PPID" >"$1"' sh "$handoff_path" || return 1
  IFS= read -r captured_pid <"$handoff_path" || return 1
  rm -f "$handoff_path" || return 1
  [[ "$captured_pid" =~ ^[0-9]+$ && "$captured_pid" -gt 1 ]] || return 1
  bootstrap_captured_shell_pid=$captured_pid
}

inspect_process_identity() {
  local inspected_pid=$1
  local inspected_output=
  local output_pid=
  local output_ppid=
  local output_pgid=
  local start_weekday=
  local start_month=
  local start_day=
  local start_time=
  local start_year=
  local output_state=
  local trailing_field=

  bootstrap_inspected_pid=
  bootstrap_inspected_ppid=
  bootstrap_inspected_pgid=
  bootstrap_inspected_start=
  bootstrap_inspected_state=
  [[ "$inspected_pid" =~ ^[0-9]+$ && "$inspected_pid" -gt 1 ]] || return 1
  inspected_output=$(LC_ALL=C /bin/ps -o pid= -o ppid= -o pgid= -o lstart= \
    -o state= -p "$inspected_pid" 2>/dev/null) || return 1
  read -r output_pid output_ppid output_pgid start_weekday start_month \
    start_day start_time start_year output_state trailing_field <<EOF
$inspected_output
EOF
  [[ "$output_pid" == "$inspected_pid" && "$output_ppid" =~ ^[0-9]+$ &&
    "$output_pgid" =~ ^[0-9]+$ && -n "$start_weekday" && -n "$start_month" &&
    -n "$start_day" && -n "$start_time" && -n "$start_year" &&
    -n "$output_state" && -z "$trailing_field" ]] || return 1
  bootstrap_inspected_pid=$output_pid
  bootstrap_inspected_ppid=$output_ppid
  bootstrap_inspected_pgid=$output_pgid
  bootstrap_inspected_start="$start_weekday $start_month $start_day $start_time $start_year"
  bootstrap_inspected_state=$output_state
}

record_process_identity() {
  local identity_path=$1
  local recorded_pid=$2
  local require_group_leader=${3:-0}
  local owner_pid=${4:-}
  local group_relation=${5:-any}
  local recorded_ppid=
  local recorded_pgid=
  local recorded_start=
  local owner_pgid=
  local pending_identity=

  [[ "$recorded_pid" =~ ^[0-9]+$ && "$recorded_pid" -gt 1 ]] || return 1
  inspect_process_identity "$recorded_pid" || return 1
  recorded_ppid=$bootstrap_inspected_ppid
  recorded_pgid=$bootstrap_inspected_pgid
  recorded_start=$bootstrap_inspected_start
  [[ "$recorded_pgid" =~ ^[0-9]+$ && "$recorded_pgid" -gt 1 ]] || return 1
  if [[ "$require_group_leader" -eq 1 && "$recorded_pgid" != "$recorded_pid" ]]; then
    return 1
  fi
  if [[ -n "$owner_pid" ]]; then
    [[ "$recorded_ppid" == "$owner_pid" ]] || return 1
    inspect_process_identity "$owner_pid" || return 1
    owner_pgid=$bootstrap_inspected_pgid
    [[ "$owner_pgid" =~ ^[0-9]+$ && "$owner_pgid" -gt 1 ]] || return 1
    case "$group_relation" in
    separate) [[ "$owner_pgid" != "$recorded_pgid" ]] || return 1 ;;
    shared) [[ "$owner_pgid" == "$recorded_pgid" ]] || return 1 ;;
    any) ;;
    *) return 1 ;;
    esac
  elif [[ "$group_relation" != any ]]; then
    return 1
  fi
  pending_identity=$(mktemp "$identity_path.pending.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n' "$recorded_pid" "$recorded_pgid" "$recorded_start" \
    >"$pending_identity" || ! /bin/mv -f "$pending_identity" "$identity_path"; then
    rm -f "$pending_identity" 2>/dev/null || true
    return 1
  fi
}

load_recorded_process_identity() {
  local identity_path=$1
  local require_group_leader=$2
  local loaded_pid=
  local loaded_pgid=
  local loaded_start=

  bootstrap_recorded_pid=
  bootstrap_recorded_pgid=
  bootstrap_recorded_start=

  [[ -s "$identity_path" ]] || return 1
  {
    IFS= read -r loaded_pid || return 1
    IFS= read -r loaded_pgid || return 1
    IFS= read -r loaded_start || return 1
  } <"$identity_path"
  [[ "$loaded_pid" =~ ^[0-9]+$ && "$loaded_pid" -gt 1 ]] || return 1
  [[ "$loaded_pgid" =~ ^[0-9]+$ && "$loaded_pgid" -gt 1 ]] || return 1
  [[ -n "$loaded_start" ]] || return 1
  if [[ "$require_group_leader" -eq 1 && "$loaded_pgid" != "$loaded_pid" ]]; then
    return 1
  fi
  bootstrap_recorded_pid=$loaded_pid
  bootstrap_recorded_pgid=$loaded_pgid
  bootstrap_recorded_start=$loaded_start
}

process_identity_matches_snapshot() {
  local recorded_pid=$1
  local recorded_pgid=$2
  local recorded_start=$3

  [[ "$recorded_pid" =~ ^[0-9]+$ && "$recorded_pid" -gt 1 ]] || return 1
  [[ "$recorded_pgid" =~ ^[0-9]+$ && "$recorded_pgid" -gt 1 ]] || return 1
  inspect_process_identity "$recorded_pid" || return 1
  [[ "$bootstrap_inspected_pgid" == "$recorded_pgid" &&
    "$bootstrap_inspected_start" == "$recorded_start" &&
    "$bootstrap_inspected_state" != *Z* ]]
}

process_group_matches_snapshot() {
  local recorded_pid=$1
  local recorded_pgid=$2
  local recorded_start=$3
  local owner_pid=${4:-$$}
  local owner_pgid=

  [[ "$recorded_pid" == "$recorded_pgid" ]] || return 1
  inspect_process_identity "$owner_pid" || return 1
  owner_pgid=$bootstrap_inspected_pgid
  [[ "$owner_pgid" != "$recorded_pgid" ]] || return 1
  if inspect_process_identity "$recorded_pid"; then
    [[ "$bootstrap_inspected_pgid" == "$recorded_pgid" &&
      "$bootstrap_inspected_start" == "$recorded_start" ]] || return 1
  else
    # group leader 消滅後は PID 再利用に備え、group 番号だけでは判定しない
    ! kill -0 "$recorded_pid" 2>/dev/null || return 1
  fi
  kill -0 -- "-$recorded_pgid" 2>/dev/null || return 1
  if inspect_process_identity "$recorded_pid"; then
    [[ "$bootstrap_inspected_pgid" == "$recorded_pgid" &&
      "$bootstrap_inspected_start" == "$recorded_start" ]] || return 1
  else
    ! kill -0 "$recorded_pid" 2>/dev/null || return 1
  fi
}

stop_process_group_snapshot() {
  local recorded_pid=$1
  local recorded_pgid=$2
  local recorded_start=$3
  local owner_pid=${4:-$$}
  local stop_attempts=0

  process_group_matches_snapshot "$recorded_pid" "$recorded_pgid" \
    "$recorded_start" "$owner_pid" || return 0
  kill -TERM -- "-$recorded_pgid" 2>/dev/null || true
  while [[ "$stop_attempts" -lt 20 ]]; do
    process_group_matches_snapshot "$recorded_pid" "$recorded_pgid" \
      "$recorded_start" "$owner_pid" || return 0
    /bin/sleep 0.01
    stop_attempts=$((stop_attempts + 1))
  done
  process_group_matches_snapshot "$recorded_pid" "$recorded_pgid" \
    "$recorded_start" "$owner_pid" || return 0
  kill -KILL -- "-$recorded_pgid" 2>/dev/null || true
  stop_attempts=0
  while [[ "$stop_attempts" -lt 20 ]]; do
    process_group_matches_snapshot "$recorded_pid" "$recorded_pgid" \
      "$recorded_start" "$owner_pid" || return 0
    /bin/sleep 0.01
    stop_attempts=$((stop_attempts + 1))
  done
  # 消滅を確認できない group は caller 側で fail-closed に処理
  return 0
}

process_group_snapshot_is_gone() {
  local recorded_pgid=$1

  [[ "$recorded_pgid" =~ ^[0-9]+$ && "$recorded_pgid" -gt 1 ]] || return 1
  ! kill -0 -- "-$recorded_pgid" 2>/dev/null
}

stop_process_group_snapshot_and_confirm() {
  local recorded_pid=$1
  local recorded_pgid=$2
  local recorded_start=$3
  local owner_pid=$4
  local retry_attempts=0

  [[ -n "$owner_pid" ]] || owner_pid=$$
  # worker の停止を 3 回確認し、確認不能なら失敗扱いにする
  while [[ "$retry_attempts" -lt 3 ]]; do
    stop_process_group_snapshot "$recorded_pid" "$recorded_pgid" \
      "$recorded_start" "$owner_pid"
    if process_group_snapshot_is_gone "$recorded_pgid"; then
      return 0
    fi
    /bin/sleep 0.01
    retry_attempts=$((retry_attempts + 1))
  done
  return 1
}

stop_recorded_process_group() {
  local identity_path=$1
  local owner_pid=${2:-$$}

  load_recorded_process_identity "$identity_path" 1 || return 0
  stop_process_group_snapshot "$bootstrap_recorded_pid" "$bootstrap_recorded_pgid" \
    "$bootstrap_recorded_start" "$owner_pid"
}

stop_process_snapshot() {
  local recorded_pid=$1
  local recorded_pgid=$2
  local recorded_start=$3
  local stop_attempts=0

  process_identity_matches_snapshot "$recorded_pid" "$recorded_pgid" \
    "$recorded_start" || return 0
  kill -TERM "$recorded_pid" 2>/dev/null || return 0
  while [[ "$stop_attempts" -lt 20 ]]; do
    process_identity_matches_snapshot "$recorded_pid" "$recorded_pgid" \
      "$recorded_start" || return 0
    /bin/sleep 0.01
    stop_attempts=$((stop_attempts + 1))
  done
  process_identity_matches_snapshot "$recorded_pid" "$recorded_pgid" \
    "$recorded_start" || return 0
  kill -KILL "$recorded_pid" 2>/dev/null || true
}

stop_recorded_process() {
  local identity_path=$1

  load_recorded_process_identity "$identity_path" 0 || return 0
  stop_process_snapshot "$bootstrap_recorded_pid" "$bootstrap_recorded_pgid" \
    "$bootstrap_recorded_start"
}

stop_just_forked_process_group() {
  local group_leader_pid=$1
  local owner_pid=$2
  local recorded_pgid=
  local recorded_start=

  inspect_process_identity "$group_leader_pid" || return 0
  [[ "$bootstrap_inspected_ppid" == "$owner_pid" &&
    "$bootstrap_inspected_pgid" == "$group_leader_pid" &&
    "$bootstrap_inspected_state" != *Z* ]] || return 0
  recorded_pgid=$bootstrap_inspected_pgid
  recorded_start=$bootstrap_inspected_start
  stop_process_group_snapshot "$group_leader_pid" "$recorded_pgid" \
    "$recorded_start" "$owner_pid"
}

stop_just_forked_process() {
  local child_pid=$1
  local owner_pid=$2
  local expected_pgid=$3
  local recorded_start=

  inspect_process_identity "$child_pid" || return 0
  [[ "$bootstrap_inspected_ppid" == "$owner_pid" &&
    "$bootstrap_inspected_pgid" == "$expected_pgid" &&
    "$bootstrap_inspected_state" != *Z* ]] || return 0
  recorded_start=$bootstrap_inspected_start
  stop_process_snapshot "$child_pid" "$expected_pgid" "$recorded_start"
}

wait_for_bootstrap_child_exit() {
  local waited_pid=$1
  local wait_limit=${2:-100}
  local wait_attempts=0

  [[ "$waited_pid" =~ ^[0-9]+$ && "$waited_pid" -gt 1 ]] || return 1
  while bootstrap_process_is_live "$waited_pid" &&
    [[ "$wait_attempts" -lt "$wait_limit" ]]; do
    /bin/sleep 0.01
    wait_attempts=$((wait_attempts + 1))
  done
  bootstrap_process_is_live "$waited_pid" && return 1
  wait "$waited_pid" 2>/dev/null || true
}

stop_sudo_keepalive_owned_processes() {
  stop_recorded_process_group "$sudo_keepalive_worker_pid_path" "$$"
  rm -f "$sudo_keepalive_worker_pid_path" \
    "$sudo_keepalive_worker_wrapper_pid_path" \
    "$sudo_keepalive_setup_wrapper_pid_path" || true
}

bootstrap_terminal_foreground_group_is_exclusive() {
  local group_members_path=
  local group_members_ids_path=
  local group_members_probe_pid=
  local group_members_probe_shell_pid=
  local group_members_probe_ps_pid=
  local group_member_pid=
  local group_member_ppid=
  local group_member_pgid=
  local group_member_state=
  local group_member_count=0
  local bootstrap_member_count=0
  local terminal_foreground_pgid=

  # 固定 path を使い、一時 child を group snapshot から除外
  group_members_path=$sudo_keepalive_sentinel_directory/foreground-group-members
  group_members_ids_path=$sudo_keepalive_sentinel_directory/foreground-group-probe
  : >"$group_members_path" || return 1
  : >"$group_members_ids_path" || return 1

  # probe の shell / ps 以外の中間 process は fail-closed
  /bin/sh -c '
    LC_ALL=C /bin/ps -o pid= -o ppid= -o pgid= -o state= -g "$1" >"$2" 2>/dev/null &
    probe_ps_pid=$!
    printf "%s %s\\n" "$$" "$probe_ps_pid" >"$3"
    wait "$probe_ps_pid"
  ' sh "$$" "$group_members_path" "$group_members_ids_path" &
  group_members_probe_pid=$!
  wait "$group_members_probe_pid" 2>/dev/null || {
    rm -f "$group_members_path" "$group_members_ids_path" || true
    return 1
  }
  if ! IFS=' ' read -r group_members_probe_shell_pid \
    group_members_probe_ps_pid <"$group_members_ids_path" ||
    [[ ! "$group_members_probe_shell_pid" =~ ^[0-9]+$ ||
      ! "$group_members_probe_ps_pid" =~ ^[0-9]+$ ||
      "$group_members_probe_shell_pid" != "$group_members_probe_pid" ]]; then
    rm -f "$group_members_path" "$group_members_ids_path" || true
    return 1
  fi
  while read -r group_member_pid group_member_ppid group_member_pgid group_member_state; do
    if [[ ! "$group_member_pid" =~ ^[0-9]+$ ||
      ! "$group_member_ppid" =~ ^[0-9]+$ ||
      ! "$group_member_pgid" =~ ^[0-9]+$ || -z "$group_member_state" ]]; then
      rm -f "$group_members_path" "$group_members_ids_path" || true
      return 1
    fi
    # signal を受けない zombie は group peer から除外
    [[ "$group_member_state" == *Z* ]] && continue
    if [[ "$group_member_pid" == "$group_members_probe_shell_pid" ||
      "$group_member_pid" == "$group_members_probe_ps_pid" ]]; then
      [[ "$group_member_pgid" == "$$" ]] || {
        rm -f "$group_members_path" "$group_members_ids_path" || true
        return 1
      }
      continue
    fi
    group_member_count=$((group_member_count + 1))
    if [[ "$group_member_pid" == "$$" && "$group_member_pgid" == "$$" ]]; then
      bootstrap_member_count=$((bootstrap_member_count + 1))
    fi
  done <"$group_members_path"
  rm -f "$group_members_path" "$group_members_ids_path" || true
  [[ "$group_member_count" -eq 1 && "$bootstrap_member_count" -eq 1 ]] || return 1

  # probe 後も foreground group が変わっていないことを確認
  inspect_process_identity "$$" || return 1
  terminal_foreground_pgid=$(LC_ALL=C /bin/ps -o tpgid= -p "$$" 2>/dev/null) ||
    return 1
  terminal_foreground_pgid=${terminal_foreground_pgid//[[:space:]]/}
  [[ "$bootstrap_inspected_pgid" == "$$" &&
    "$terminal_foreground_pgid" == "$$" ]]
}

sudo_keepalive_foreground_setup_is_incomplete() {
  [[ "$sudo_keepalive_setup_foreground_mode" == 1 &&
    -e "$sudo_keepalive_setup_request_path" &&
    ! -s "$sudo_keepalive_setup_status_path" ]]
}

stop_sudo_keepalive() {
  local helper_identity_pid=
  local helper_identity_pgid=
  local helper_identity_start=
  local helper_stop_attempts=0
  local worker_teardown_failed=0

  if load_recorded_process_identity "$sudo_keepalive_helper_pid_path" 1; then
    helper_identity_pid=$bootstrap_recorded_pid
    helper_identity_pgid=$bootstrap_recorded_pgid
    helper_identity_start=$bootstrap_recorded_start
  fi
  # pipe を閉じて helper に cleanup を要求
  exec 9>&-
  if [[ -n "${sudo_keepalive_sentinel_pid:-}" ]]; then
    # helper の cleanup を待ってから process group を停止
    while bootstrap_process_is_live "$sudo_keepalive_sentinel_pid" &&
      [[ "$helper_stop_attempts" -lt 300 ]]; do
      /bin/sleep 0.01
      helper_stop_attempts=$((helper_stop_attempts + 1))
    done
    if [[ -n "$helper_identity_pid" ]]; then
      stop_process_group_snapshot "$helper_identity_pid" "$helper_identity_pgid" \
        "$helper_identity_start" "$$"
    fi
    # wait 前に helper identity を非公開化
    rm -f "$sudo_keepalive_helper_pid_path" || true
    stop_sudo_keepalive_owned_processes
    wait_for_bootstrap_child_exit "$sudo_keepalive_sentinel_pid" 100 || true
    sudo_keepalive_sentinel_pid=
  else
    stop_sudo_keepalive_owned_processes
  fi
  # foreground group 専有時は未公開の setup wrapper も fail-closed
  if [[ -n "${sudo_keepalive_finalizer_pid:-}" ]]; then
    wait_for_bootstrap_child_exit "$sudo_keepalive_finalizer_pid" 300 || true
    sudo_keepalive_finalizer_pid=
    rm -f "$sudo_keepalive_finalizer_pid_path" || true
  elif sudo_keepalive_foreground_setup_is_incomplete; then
    kill -KILL -- "-$$" 2>/dev/null || true
  fi
  if [[ -s "$sudo_keepalive_failure_status_path" ]] &&
    /usr/bin/grep -Fx 'worker-teardown:125' "$sudo_keepalive_failure_status_path" \
      >/dev/null 2>&1; then
    worker_teardown_failed=1
  fi
  sudo_keepalive_pid=
  exec 8<&-
  exec 7>&-
  cleanup_sudo_keepalive_sentinel || true
  if [[ "$worker_teardown_failed" -ne 0 ]]; then
    printf 'error: sudo keep-alive worker teardown could not be confirmed\n' >&2
    trap - EXIT
    return 125
  fi
  sudo -k || true
}

# 以降の失敗時は keep-alive の一時状態も cleanup
trap stop_sudo_keepalive EXIT

# helper が keep-alive worker を管理し、pipe EOF で親の消滅を検出
sudo_keepalive_sentinel_directory=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-sudo-keepalive.XXXXXX")
sudo_keepalive_sentinel_path=$sudo_keepalive_sentinel_directory/parent
sudo_keepalive_parent_closed_path=$sudo_keepalive_sentinel_directory/parent-closed
sudo_keepalive_worker_ready_path=$sudo_keepalive_sentinel_directory/worker-ready
sudo_keepalive_sentinel_ready_path=$sudo_keepalive_sentinel_directory/helper-ready
sudo_keepalive_helper_pid_path=$sudo_keepalive_sentinel_directory/helper-pid
sudo_keepalive_worker_pid_path=$sudo_keepalive_sentinel_directory/worker-pid
sudo_keepalive_worker_wrapper_pid_path=$sudo_keepalive_sentinel_directory/worker-wrapper-pid
sudo_keepalive_setup_wrapper_pid_path=$sudo_keepalive_sentinel_directory/setup-wrapper-pid
sudo_keepalive_finalizer_pid_path=$sudo_keepalive_sentinel_directory/finalizer-pid
sudo_keepalive_setup_owner_group_identity_path=$sudo_keepalive_sentinel_directory/setup-owner-group
sudo_keepalive_setup_request_path=$sudo_keepalive_sentinel_directory/setup-request
sudo_keepalive_setup_status_path=$sudo_keepalive_sentinel_directory/setup-status
sudo_keepalive_setup_completion_path=$sudo_keepalive_sentinel_directory/setup-completion
sudo_keepalive_setup_ack_path=$sudo_keepalive_sentinel_directory/setup-ack
sudo_keepalive_failure_status_path=$sudo_keepalive_sentinel_directory/keepalive-failure-status
mkfifo -m 600 "$sudo_keepalive_sentinel_path"
exec 7<>"$sudo_keepalive_sentinel_path"
exec 8<"$sudo_keepalive_sentinel_path"
exec 9>"$sudo_keepalive_sentinel_path"
exec 7>&-

# bootstrap が foreground group を専有する場合だけ setup も同じ group で実行
if { : </dev/tty; } 2>/dev/null && inspect_process_identity "$$"; then
  sudo_keepalive_terminal_foreground_pgid=$(LC_ALL=C /bin/ps -o tpgid= -p "$$" \
    2>/dev/null) || sudo_keepalive_terminal_foreground_pgid=
  sudo_keepalive_terminal_foreground_pgid=${sudo_keepalive_terminal_foreground_pgid//[[:space:]]/}
  if [[ "$bootstrap_inspected_pgid" == "$$" &&
    "$sudo_keepalive_terminal_foreground_pgid" == "$$" ]] &&
    bootstrap_terminal_foreground_group_is_exclusive &&
    record_process_identity "$sudo_keepalive_setup_owner_group_identity_path" \
      "$$" 1; then
    sudo_keepalive_setup_foreground_mode=1
  fi
fi

bootstrap_terminal_foreground_group_is_current() {
  local terminal_foreground_pgid=

  inspect_process_identity "$$" || return 1
  terminal_foreground_pgid=$(LC_ALL=C /bin/ps -o tpgid= -p "$$" 2>/dev/null) ||
    return 1
  terminal_foreground_pgid=${terminal_foreground_pgid//[[:space:]]/}
  [[ "$bootstrap_inspected_pgid" == "$$" &&
    "$terminal_foreground_pgid" == "$$" ]] || return 1
  load_recorded_process_identity "$sudo_keepalive_setup_owner_group_identity_path" 1 || return 1
  [[ "$bootstrap_recorded_pid" == "$$" ]] || return 1
  process_identity_matches_snapshot "$bootstrap_recorded_pid" \
    "$bootstrap_recorded_pgid" "$bootstrap_recorded_start"
}

handle_sudo_keepalive_foreground_continue() {
  [[ "$sudo_keepalive_setup_foreground_mode" == 1 ]] || return 0
  sudo_keepalive_foreground_setup_is_incomplete || return 0
  bootstrap_terminal_foreground_group_is_current && return 0

  # foreground ownership 喪失時は setup wrapper を fail-closed
  printf 'foreground-terminal:125\n' >"$sudo_keepalive_failure_status_path" 2>/dev/null || true
  kill -KILL -- "-$$" 2>/dev/null || true
}

start_sudo_keepalive_foreground_finalizer() {
  local finalizer_helper_pid=
  local finalizer_helper_pgid=
  local finalizer_helper_start=
  local finalizer_worker_pid=
  local finalizer_worker_pgid=
  local finalizer_worker_start=
  local finalizer_owner_pid=
  local finalizer_owner_pgid=
  local finalizer_owner_start=
  local pending_finalizer_pid=
  local restore_monitor_mode=0

  [[ "$sudo_keepalive_setup_foreground_mode" == 1 ]] || return 0
  load_recorded_process_identity "$sudo_keepalive_helper_pid_path" 1 || return 1
  finalizer_helper_pid=$bootstrap_recorded_pid
  finalizer_helper_pgid=$bootstrap_recorded_pgid
  finalizer_helper_start=$bootstrap_recorded_start
  load_recorded_process_identity "$sudo_keepalive_worker_pid_path" 1 || return 1
  finalizer_worker_pid=$bootstrap_recorded_pid
  finalizer_worker_pgid=$bootstrap_recorded_pgid
  finalizer_worker_start=$bootstrap_recorded_start
  load_recorded_process_identity "$sudo_keepalive_setup_owner_group_identity_path" 1 || return 1
  finalizer_owner_pid=$bootstrap_recorded_pid
  finalizer_owner_pgid=$bootstrap_recorded_pgid
  finalizer_owner_start=$bootstrap_recorded_start

  # finalizer は helper / worker と別 group で sudo timestamp の無効化まで待機
  [[ "$-" == *m* ]] && restore_monitor_mode=1
  set -m
  (
    exec 9>&-
    trap '' HUP INT TERM
    set +m
    if ! capture_current_shell_pid \
      "$sudo_keepalive_sentinel_directory/shell-pid.finalizer"; then
      exit 125
    fi
    finalizer_self_pid=$bootstrap_captured_shell_pid
    finalizer_publication_attempts=0
    while [[ ! -s "$sudo_keepalive_finalizer_pid_path" &&
      "$finalizer_publication_attempts" -lt 100 ]]; do
      if ! process_identity_matches_snapshot "$finalizer_helper_pid" \
        "$finalizer_helper_pgid" "$finalizer_helper_start"; then
        exit 125
      fi
      /bin/sleep 0.01
      finalizer_publication_attempts=$((finalizer_publication_attempts + 1))
    done
    if ! load_recorded_process_identity "$sudo_keepalive_finalizer_pid_path" 1 ||
      [[ "$bootstrap_recorded_pid" != "$finalizer_self_pid" ]] ||
      ! process_identity_matches_snapshot "$bootstrap_recorded_pid" \
        "$bootstrap_recorded_pgid" "$bootstrap_recorded_start"; then
      exit 125
    fi

    while process_identity_matches_snapshot "$finalizer_helper_pid" \
      "$finalizer_helper_pgid" "$finalizer_helper_start"; do
      /bin/sleep 0.05
    done
    if sudo_keepalive_foreground_setup_is_incomplete; then
      stop_process_group_snapshot "$finalizer_owner_pid" \
        "$finalizer_owner_pgid" "$finalizer_owner_start" "$finalizer_self_pid"
    fi
    if ! stop_process_group_snapshot_and_confirm "$finalizer_worker_pid" \
      "$finalizer_worker_pgid" "$finalizer_worker_start" "$finalizer_self_pid"; then
      printf 'worker-teardown:125\n' >"$sudo_keepalive_failure_status_path" 2>/dev/null || true
      exit 125
    fi
    sudo -k || true
    exit 0
  ) &
  pending_finalizer_pid=$!
  [[ "$restore_monitor_mode" == 1 ]] || set +m
  if ! record_process_identity "$sudo_keepalive_finalizer_pid_path" \
    "$pending_finalizer_pid" 1 "$$" separate; then
    stop_just_forked_process_group "$pending_finalizer_pid" "$$"
    wait_for_bootstrap_child_exit "$pending_finalizer_pid" || true
    rm -f "$sudo_keepalive_finalizer_pid_path" || true
    return 1
  fi
  sudo_keepalive_finalizer_pid=$pending_finalizer_pid
  if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_FINALIZER_PID_FILE:-}" ]]; then
    printf '%s\n' "$pending_finalizer_pid" \
      >"$BOOTSTRAP_INTERNAL_TEST_SUDO_FINALIZER_PID_FILE"
  fi
}

set -m
(
  exec 9>&-
  set +m
  sudo_keepalive_worker_pid=
  sudo_keepalive_worker_identity_pid=
  sudo_keepalive_worker_identity_pgid=
  sudo_keepalive_worker_identity_start=
  sudo_keepalive_parent_watcher_pid=
  sudo_keepalive_setup_wrapper_pid=
  sudo_keepalive_helper_pid=
  sudo_keepalive_helper_stop_requested=0
  sudo_keepalive_failure_handled=0
  sudo_keepalive_foreground_setup_wrapper_seen=0
  request_sudo_keepalive_helper_stop() {
    sudo_keepalive_helper_stop_requested=1
  }
  wait_for_sudo_keepalive_child() {
    wait_for_bootstrap_child_exit "$1"
  }
  unpublish_sudo_keepalive_setup_before_wait() {
    unpublishing_setup_pid=$1
    unpublish_attempts=0
    while [[ -e "$sudo_keepalive_setup_wrapper_pid_path" ]] &&
      bootstrap_process_is_live "$unpublishing_setup_pid" &&
      [[ "$unpublish_attempts" -lt 20 ]]; do
      /bin/sleep 0.01
      unpublish_attempts=$((unpublish_attempts + 1))
    done
    rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
  }
  observe_sudo_keepalive_foreground_setup() {
    [[ "$sudo_keepalive_setup_foreground_mode" == 1 ]] || return 0
    if [[ -s "$sudo_keepalive_setup_status_path" ]]; then
      sudo_keepalive_foreground_setup_wrapper_seen=0
      return 0
    fi
    sudo_keepalive_foreground_setup_is_incomplete || return 0

    # 公開済み setup identity の消失・不一致は infrastructure failure
    if [[ -s "$sudo_keepalive_setup_wrapper_pid_path" ]]; then
      sudo_keepalive_foreground_setup_wrapper_seen=1
      if ! load_recorded_process_identity "$sudo_keepalive_setup_wrapper_pid_path" 0 ||
        ! process_identity_matches_snapshot "$bootstrap_recorded_pid" \
          "$bootstrap_recorded_pgid" "$bootstrap_recorded_start"; then
        printf 'setup-wrapper:125\n' >"$sudo_keepalive_failure_status_path"
      fi
    elif [[ "$sudo_keepalive_foreground_setup_wrapper_seen" -ne 0 &&
      ! -s "$sudo_keepalive_setup_completion_path" ]]; then
      printf 'setup-wrapper:125\n' >"$sudo_keepalive_failure_status_path"
    fi
  }
  stop_sudo_keepalive_foreground_setup() {
    [[ "$sudo_keepalive_setup_foreground_mode" == 1 ]] || return 0
    sudo_keepalive_foreground_setup_is_incomplete || return 0

    # foreground owner group を停止し、未公開 wrapper も終了
    stop_recorded_process_group "$sudo_keepalive_setup_owner_group_identity_path" \
      "$sudo_keepalive_helper_pid"
  }
  stop_sudo_keepalive_setup() {
    if [[ "$sudo_keepalive_setup_foreground_mode" == 1 ]]; then
      stop_sudo_keepalive_foreground_setup
      return 0
    fi
    if [[ -n "${sudo_keepalive_setup_wrapper_pid:-}" ]]; then
      stopped_setup_wrapper_pid=$sudo_keepalive_setup_wrapper_pid
      sudo_keepalive_setup_wrapper_pid=
      if [[ ! -s "$sudo_keepalive_setup_completion_path" ]]; then
        setup_stop_attempts=0
        while [[ ! -s "$sudo_keepalive_setup_completion_path" &&
          "$setup_stop_attempts" -lt 20 ]]; do
          /bin/sleep 0.01
          setup_stop_attempts=$((setup_stop_attempts + 1))
        done
      fi
      if [[ -s "$sudo_keepalive_setup_completion_path" ]]; then
        : >"$sudo_keepalive_setup_ack_path"
      fi
      unpublish_sudo_keepalive_setup_before_wait "$stopped_setup_wrapper_pid"
      if ! wait_for_sudo_keepalive_child "$stopped_setup_wrapper_pid"; then
        # setup の wait 失敗時は process group 全体を fail-closed
        printf 'setup-teardown:125\n' >"$sudo_keepalive_failure_status_path"
      fi
      if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER:-}" &&
        -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_GATE:-}" &&
        ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER" ]]; then
        [[ -e "$sudo_keepalive_setup_wrapper_pid_path" ]] &&
          printf '%s\n' present >"$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER" ||
          printf '%s\n' absent >"$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER"
        while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_GATE" ]]; do
          /bin/sleep 0.01
        done
      fi
      rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
    fi
  }
  stop_sudo_keepalive_helper() {
    local worker_cage_confirmed=1

    trap - EXIT HUP INT TERM
    stop_sudo_keepalive_setup
    if [[ -n "${sudo_keepalive_worker_pid:-}" ]]; then
      stopped_worker_pid=$sudo_keepalive_worker_pid
      sudo_keepalive_worker_pid=
      if [[ -n "$sudo_keepalive_worker_identity_pid" ]]; then
        stop_process_group_snapshot "$sudo_keepalive_worker_identity_pid" \
          "$sudo_keepalive_worker_identity_pgid" "$sudo_keepalive_worker_identity_start" \
          "$sudo_keepalive_helper_pid"
      else
        worker_cage_confirmed=0
      fi
      rm -f "$sudo_keepalive_worker_pid_path" \
        "$sudo_keepalive_worker_wrapper_pid_path" || true
      if ! wait_for_bootstrap_child_exit "$stopped_worker_pid"; then
        worker_cage_confirmed=0
      elif [[ -n "$sudo_keepalive_worker_identity_pid" ]] &&
        ! process_group_snapshot_is_gone "$sudo_keepalive_worker_identity_pgid" &&
        ! stop_process_group_snapshot_and_confirm "$sudo_keepalive_worker_identity_pid" \
          "$sudo_keepalive_worker_identity_pgid" "$sudo_keepalive_worker_identity_start" \
          "$sudo_keepalive_helper_pid"; then
        worker_cage_confirmed=0
      fi
      if [[ "$worker_cage_confirmed" -eq 0 ]]; then
        printf 'worker-teardown:125\n' >"$sudo_keepalive_failure_status_path"
      fi
      if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_MARKER:-}" &&
        -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_GATE:-}" ]]; then
        [[ -e "$sudo_keepalive_worker_pid_path" ]] &&
          printf '%s\n' present >"$BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_MARKER" ||
          printf '%s\n' absent >"$BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_MARKER"
        while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_GATE" ]]; do
          /bin/sleep 0.01
        done
      fi
      rm -f "$sudo_keepalive_worker_pid_path" \
        "$sudo_keepalive_worker_wrapper_pid_path" || true
      if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_FILE:-}" ]]; then
        printf '%s\n' "$stopped_worker_pid" >"$BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_REAPED_FILE"
      fi
    fi
    if [[ -n "${sudo_keepalive_parent_watcher_pid:-}" ]]; then
      sudo_keepalive_parent_watcher_pid=
    fi
    if [[ "$worker_cage_confirmed" -ne 0 ]]; then
      sudo -k || true
      cleanup_sudo_keepalive_sentinel || true
    fi
    # setup / finalizer の process group を終了し、停止中 wrapper も cleanup
    helper_cleanup_pgid=$(LC_ALL=C /bin/ps -o pgid= -p "$sudo_keepalive_helper_pid" \
      2>/dev/null) || helper_cleanup_pgid=
    helper_cleanup_pgid=${helper_cleanup_pgid//[[:space:]]/}
    if [[ "$helper_cleanup_pgid" == "$sudo_keepalive_helper_pid" ]]; then
      kill -KILL -- "-$sudo_keepalive_helper_pid" 2>/dev/null || true
    fi
    exit 0
  }
  trap stop_sudo_keepalive_helper EXIT
  trap request_sudo_keepalive_helper_stop HUP INT TERM

  # watcher だけが read side を保持し、親消滅を EOF で検出
  (
    trap 'exit 0' HUP INT TERM
    IFS= read -r _ <&8 || true
    : >"$sudo_keepalive_parent_closed_path"
  ) &
  sudo_keepalive_parent_watcher_pid=$!
  exec 8<&-

  while [[ ! -s "$sudo_keepalive_helper_pid_path" &&
    ! -e "$sudo_keepalive_parent_closed_path" ]]; do
    /bin/sleep 0.01
  done
  if [[ -e "$sudo_keepalive_parent_closed_path" ]] ||
    ! IFS= read -r sudo_keepalive_helper_pid <"$sudo_keepalive_helper_pid_path"; then
    exit 0
  fi
  if ! load_recorded_process_identity "$sudo_keepalive_helper_pid_path" 1 ||
    [[ "$bootstrap_recorded_pid" != "$sudo_keepalive_helper_pid" ]]; then
    rm -f "$sudo_keepalive_helper_pid_path" || true
    exit 125
  fi

  set -m
  (
    set +m
    if ! capture_current_shell_pid \
      "$sudo_keepalive_sentinel_directory/shell-pid.worker"; then
      rm -f "$sudo_keepalive_worker_pid_path" || true
      exit 125
    fi
    sudo_keepalive_worker_self_pid=$bootstrap_captured_shell_pid
    while [[ ! -s "$sudo_keepalive_worker_pid_path" ]]; do
      if ! bootstrap_process_is_live "$sudo_keepalive_helper_pid"; then
        rm -f "$sudo_keepalive_worker_pid_path" || true
        exit 125
      fi
      /bin/sleep 0.01
    done
    IFS= read -r published_worker_pid <"$sudo_keepalive_worker_pid_path"
    if [[ "$published_worker_pid" != "$sudo_keepalive_worker_self_pid" ]] ||
      ! bootstrap_process_is_live "$sudo_keepalive_helper_pid"; then
      rm -f "$sudo_keepalive_worker_pid_path" || true
      exit 125
    fi
    sudo_keepalive_wrapper_pid=
    sudo_keepalive_wrapper_completion=
    sudo_keepalive_wrapper_ack=
    sudo_keepalive_wrapper_registration=
    sudo_keepalive_finishing_wrapper_pid=
    sudo_keepalive_finishing_wrapper_completion=
    sudo_keepalive_finishing_wrapper_ack=
    sudo_keepalive_finishing_wrapper_registration=
    sudo_keepalive_finishing_wrapper_reaping=0
    sudo_keepalive_child_sequence=0
    sudo_keepalive_worker_stop_requested=0
    sudo_keepalive_wrapper_infrastructure_failure=0

    request_sudo_keepalive_worker_stop() {
      sudo_keepalive_worker_stop_requested=1
    }

    sudo_keepalive_worker_should_stop() {
      [[ "$sudo_keepalive_worker_stop_requested" -ne 0 ]]
    }

    wait_for_sudo_keepalive_wrapper() {
      wait_for_bootstrap_child_exit "$1"
    }

    unpublish_sudo_keepalive_wrapper_before_wait() {
      unpublishing_wrapper_pid=$1
      wrapper_unpublish_attempts=0
      while [[ -e "$sudo_keepalive_worker_wrapper_pid_path" ]] &&
        bootstrap_process_is_live "$unpublishing_wrapper_pid" &&
        [[ "$wrapper_unpublish_attempts" -lt 20 ]]; do
        /bin/sleep 0.01
        wrapper_unpublish_attempts=$((wrapper_unpublish_attempts + 1))
      done
      rm -f "$sudo_keepalive_worker_wrapper_pid_path" || true
    }

    stop_sudo_keepalive_worker() {
      trap - HUP INT TERM
      if [[ -n "${sudo_keepalive_wrapper_pid:-}" ]]; then
        sudo_keepalive_finishing_wrapper_pid=$sudo_keepalive_wrapper_pid
        sudo_keepalive_finishing_wrapper_completion=$sudo_keepalive_wrapper_completion
        sudo_keepalive_finishing_wrapper_ack=$sudo_keepalive_wrapper_ack
        sudo_keepalive_finishing_wrapper_registration=$sudo_keepalive_wrapper_registration
        sudo_keepalive_finishing_wrapper_reaping=0
        sudo_keepalive_wrapper_pid=
        sudo_keepalive_wrapper_completion=
        sudo_keepalive_wrapper_ack=
        sudo_keepalive_wrapper_registration=
      fi

      if [[ -n "${sudo_keepalive_finishing_wrapper_pid:-}" ]]; then
        if [[ "$sudo_keepalive_finishing_wrapper_reaping" -eq 0 ]]; then
          if [[ -s "$sudo_keepalive_finishing_wrapper_completion" ]]; then
            # 完了済み wrapper を ACK まで維持
            : >"$sudo_keepalive_finishing_wrapper_ack"
          fi
          unpublish_sudo_keepalive_wrapper_before_wait \
            "$sudo_keepalive_finishing_wrapper_pid"
          sudo_keepalive_finishing_wrapper_reaping=1
        fi
        wait_for_sudo_keepalive_wrapper \
          "$sudo_keepalive_finishing_wrapper_pid" || true
      fi

      if [[ -n "${sudo_keepalive_finishing_wrapper_completion:-}" ]]; then
        rm -f "$sudo_keepalive_finishing_wrapper_completion" \
          "$sudo_keepalive_finishing_wrapper_ack" \
          "$sudo_keepalive_finishing_wrapper_registration" || true
      fi
      sudo_keepalive_finishing_wrapper_pid=
      sudo_keepalive_finishing_wrapper_completion=
      sudo_keepalive_finishing_wrapper_ack=
      sudo_keepalive_finishing_wrapper_registration=
      rm -f "$sudo_keepalive_worker_wrapper_pid_path" || true
      rm -f "$sudo_keepalive_worker_pid_path" || true
      exit 0
    }
    trap request_sudo_keepalive_worker_stop HUP INT TERM

    run_sudo_keepalive_child() {
      sudo_keepalive_child_sequence=$((sudo_keepalive_child_sequence + 1))
      child_completion=$sudo_keepalive_sentinel_directory/child-status.$sudo_keepalive_child_sequence
      child_ack=$sudo_keepalive_sentinel_directory/child-ack.$sudo_keepalive_child_sequence
      child_registration=$sudo_keepalive_sentinel_directory/child-registration.$sudo_keepalive_child_sequence
      rm -f "$child_completion" "$child_ack" "$child_registration"

      # wrapper は command の reap から worker の ACK まで生存
      (
        set +m
        if ! capture_current_shell_pid \
          "$sudo_keepalive_sentinel_directory/shell-pid.wrapper.$sudo_keepalive_child_sequence"; then
          rm -f "$sudo_keepalive_worker_wrapper_pid_path" || true
          exit 125
        fi
        wrapper_self_pid=$bootstrap_captured_shell_pid
        while [[ ! -e "$child_registration" ]]; do
          if ! bootstrap_process_is_live "$sudo_keepalive_worker_self_pid"; then
            rm -f "$sudo_keepalive_worker_wrapper_pid_path" || true
            exit 125
          fi
          /bin/sleep 0.01
        done
        IFS= read -r published_wrapper_pid <"$sudo_keepalive_worker_wrapper_pid_path"
        wrapper_parent_pid=$(LC_ALL=C /bin/ps -o ppid= -p "$wrapper_self_pid" 2>/dev/null)
        wrapper_parent_pid=${wrapper_parent_pid//[[:space:]]/}
        if [[ "$published_wrapper_pid" != "$wrapper_self_pid" ||
          "$wrapper_parent_pid" != "$sudo_keepalive_worker_self_pid" ]] ||
          ! bootstrap_process_is_live "$sudo_keepalive_worker_self_pid"; then
          rm -f "$sudo_keepalive_worker_wrapper_pid_path" || true
          exit 125
        fi
        child_status=0
        "$@" &
        wrapped_child_pid=$!
        if [[ "${1-}" == /bin/sleep && "${2-}" == 3600 &&
          -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_RESERVATION_PID_FILE:-}" ]]; then
          printf '%s\n' "$wrapped_child_pid" >"$BOOTSTRAP_INTERNAL_TEST_SUDO_RESERVATION_PID_FILE"
        fi
        wait "$wrapped_child_pid" || child_status=$?
        if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_REAPED_PID_FILE:-}" &&
          -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_REAPED_GATE:-}" ]]; then
          printf '%s\n' "$wrapped_child_pid" >"$BOOTSTRAP_INTERNAL_TEST_SUDO_REAPED_PID_FILE"
        fi
        printf '%s\n' "$child_status" >"$child_completion"
        while [[ ! -e "$child_ack" ]]; do
          if ! bootstrap_process_is_live "$sudo_keepalive_worker_self_pid"; then
            rm -f "$sudo_keepalive_worker_wrapper_pid_path" || true
            exit 125
          fi
          /bin/sleep 0.01
        done
        rm -f "$sudo_keepalive_worker_wrapper_pid_path"
      ) &
      pending_wrapper_pid=$!
      sudo_keepalive_wrapper_pid=$pending_wrapper_pid
      sudo_keepalive_wrapper_completion=$child_completion
      sudo_keepalive_wrapper_ack=$child_ack
      sudo_keepalive_wrapper_registration=$child_registration
      if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PUBLICATION_MARKER:-}" &&
        -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PUBLICATION_GATE:-}" ]]; then
        printf '%s\n' "$pending_wrapper_pid" \
          >"${BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PUBLICATION_PID_FILE:?}"
        : >"$BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PUBLICATION_MARKER"
        while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PUBLICATION_GATE" ]] &&
          ! sudo_keepalive_worker_should_stop; do
          /bin/sleep 0.01
        done
      fi
      if ! record_process_identity "$sudo_keepalive_worker_wrapper_pid_path" \
        "$pending_wrapper_pid" 0 "$sudo_keepalive_worker_self_pid" shared; then
        stop_just_forked_process "$pending_wrapper_pid" \
          "$sudo_keepalive_worker_self_pid" "$sudo_keepalive_worker_self_pid"
        rm -f "$sudo_keepalive_worker_wrapper_pid_path" || true
        wait_for_sudo_keepalive_wrapper "$pending_wrapper_pid" || true
        sudo_keepalive_wrapper_pid=
        sudo_keepalive_wrapper_completion=
        sudo_keepalive_wrapper_ack=
        sudo_keepalive_wrapper_registration=
        rm -f "$child_completion" "$child_ack" "$child_registration" || true
        sudo_keepalive_wrapper_infrastructure_failure=1
        return 125
      fi
      : >"$child_registration"
      if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_FORK_MARKER:-}" &&
        -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_FORK_GATE:-}" &&
        ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_FORK_MARKER" ]]; then
        printf '%s\n' "$pending_wrapper_pid" >"${BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_PID_FILE:?}"
        : >"$BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_FORK_MARKER"
        while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_FORK_GATE" ]] &&
          ! sudo_keepalive_worker_should_stop; do
          /bin/sleep 0.01
        done
      fi
      if sudo_keepalive_worker_should_stop; then
        stop_sudo_keepalive_worker
      fi

      while [[ ! -s "$child_completion" ]]; do
        if sudo_keepalive_worker_should_stop; then
          stop_sudo_keepalive_worker
        fi
        if ! bootstrap_process_is_live "$pending_wrapper_pid"; then
          rm -f "$sudo_keepalive_worker_wrapper_pid_path" || true
          wait_for_sudo_keepalive_wrapper "$pending_wrapper_pid" || true
          sudo_keepalive_wrapper_pid=
          sudo_keepalive_wrapper_completion=
          sudo_keepalive_wrapper_ack=
          sudo_keepalive_wrapper_registration=
          rm -f "$child_completion" "$child_ack" "$child_registration" \
            "$sudo_keepalive_worker_wrapper_pid_path" || true
          sudo_keepalive_wrapper_infrastructure_failure=1
          return 125
        fi
        /bin/sleep 0.01
      done
      IFS= read -r child_status <"$child_completion"

      # command reap 後の wrapper を test gate 中も公開
      if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_REAPED_PID_FILE:-}" &&
        -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_REAPED_GATE:-}" ]]; then
        while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_REAPED_GATE" ]] &&
          ! sudo_keepalive_worker_should_stop; do
          :
        done
      fi
      if sudo_keepalive_worker_should_stop; then
        stop_sudo_keepalive_worker
      fi

      sudo_keepalive_finishing_wrapper_pid=$sudo_keepalive_wrapper_pid
      sudo_keepalive_finishing_wrapper_completion=$sudo_keepalive_wrapper_completion
      sudo_keepalive_finishing_wrapper_ack=$sudo_keepalive_wrapper_ack
      sudo_keepalive_finishing_wrapper_registration=$sudo_keepalive_wrapper_registration
      sudo_keepalive_finishing_wrapper_reaping=0
      sudo_keepalive_wrapper_pid=
      sudo_keepalive_wrapper_completion=
      sudo_keepalive_wrapper_ack=
      sudo_keepalive_wrapper_registration=
      : >"$sudo_keepalive_finishing_wrapper_ack"
      unpublish_sudo_keepalive_wrapper_before_wait \
        "$sudo_keepalive_finishing_wrapper_pid"
      sudo_keepalive_finishing_wrapper_reaping=1
      if ! wait_for_sudo_keepalive_wrapper "$sudo_keepalive_finishing_wrapper_pid"; then
        rm -f "$sudo_keepalive_finishing_wrapper_completion" \
          "$sudo_keepalive_finishing_wrapper_ack" \
          "$sudo_keepalive_finishing_wrapper_registration" \
          "$sudo_keepalive_worker_wrapper_pid_path" || true
        sudo_keepalive_wrapper_infrastructure_failure=1
        return 125
      fi
      if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_REAPED_MARKER:-}" &&
        -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_REAPED_GATE:-}" &&
        ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_REAPED_MARKER" ]]; then
        [[ -e "$sudo_keepalive_worker_wrapper_pid_path" ]] &&
          printf '%s\n' present >"$BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_REAPED_MARKER" ||
          printf '%s\n' absent >"$BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_REAPED_MARKER"
        while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_WRAPPER_REAPED_GATE" ]] &&
          ! sudo_keepalive_worker_should_stop; do
          /bin/sleep 0.01
        done
      fi
      rm -f "$sudo_keepalive_finishing_wrapper_completion" \
        "$sudo_keepalive_finishing_wrapper_ack" \
        "$sudo_keepalive_finishing_wrapper_registration" \
        "$sudo_keepalive_worker_wrapper_pid_path"
      sudo_keepalive_finishing_wrapper_pid=
      sudo_keepalive_finishing_wrapper_completion=
      sudo_keepalive_finishing_wrapper_ack=
      sudo_keepalive_finishing_wrapper_registration=
      sudo_keepalive_finishing_wrapper_reaping=0
      return "$child_status"
    }

    # refresh 失敗後も wrapper handshake で child を cleanup
    reserve_sudo_keepalive_worker_pid() {
      while ! sudo_keepalive_worker_should_stop; do
        if run_sudo_keepalive_child /bin/sleep 3600; then
          :
        elif [[ "$sudo_keepalive_wrapper_infrastructure_failure" -ne 0 ]]; then
          rm -f "$sudo_keepalive_worker_pid_path" \
            "$sudo_keepalive_worker_wrapper_pid_path" || true
          exit 125
        fi
      done
      stop_sudo_keepalive_worker
    }

    : >"$sudo_keepalive_worker_ready_path"
    while ! sudo_keepalive_worker_should_stop; do
      if run_sudo_keepalive_child sleep 50; then
        :
      else
        keepalive_child_status=$?
        if [[ "$sudo_keepalive_wrapper_infrastructure_failure" -ne 0 ]]; then
          rm -f "$sudo_keepalive_worker_pid_path" \
            "$sudo_keepalive_worker_wrapper_pid_path" || true
          exit 125
        fi
        printf 'sleep:%s\n' "$keepalive_child_status" >"$sudo_keepalive_failure_status_path"
        reserve_sudo_keepalive_worker_pid
        exit 0
      fi

      if run_sudo_keepalive_child sudo -n -v 2>/dev/null; then
        :
      else
        keepalive_child_status=$?
        if [[ "$sudo_keepalive_wrapper_infrastructure_failure" -ne 0 ]]; then
          rm -f "$sudo_keepalive_worker_pid_path" \
            "$sudo_keepalive_worker_wrapper_pid_path" || true
          exit 125
        fi
        printf 'sudo:%s\n' "$keepalive_child_status" >"$sudo_keepalive_failure_status_path"
        reserve_sudo_keepalive_worker_pid
        exit 0
      fi
    done
    stop_sudo_keepalive_worker
  ) &
  sudo_keepalive_worker_pid=$!
  if ! record_process_identity "$sudo_keepalive_worker_pid_path" \
    "$sudo_keepalive_worker_pid" 1 "$sudo_keepalive_helper_pid" separate; then
    stop_just_forked_process_group "$sudo_keepalive_worker_pid" \
      "$sudo_keepalive_helper_pid"
    rm -f "$sudo_keepalive_worker_pid_path" || true
    wait_for_bootstrap_child_exit "$sudo_keepalive_worker_pid" || true
    sudo_keepalive_worker_pid=
    printf 'worker-publication:125\n' >"$sudo_keepalive_failure_status_path"
  elif load_recorded_process_identity "$sudo_keepalive_worker_pid_path" 1; then
    sudo_keepalive_worker_identity_pid=$bootstrap_recorded_pid
    sudo_keepalive_worker_identity_pgid=$bootstrap_recorded_pgid
    sudo_keepalive_worker_identity_start=$bootstrap_recorded_start
  else
    stop_just_forked_process_group "$sudo_keepalive_worker_pid" \
      "$sudo_keepalive_helper_pid"
    rm -f "$sudo_keepalive_worker_pid_path" || true
    wait_for_bootstrap_child_exit "$sudo_keepalive_worker_pid" || true
    sudo_keepalive_worker_pid=
    printf 'worker-publication:125\n' >"$sudo_keepalive_failure_status_path"
  fi
  set +m
  if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_PID_FILE:-}" ]]; then
    printf '%s\n' "$sudo_keepalive_worker_pid" >"$BOOTSTRAP_INTERNAL_TEST_SUDO_WORKER_PID_FILE"
  fi
  observe_sudo_keepalive_worker() {
    if [[ -n "${sudo_keepalive_worker_pid:-}" ]] &&
      ! bootstrap_process_is_live "$sudo_keepalive_worker_pid"; then
      stopped_worker_pid=$sudo_keepalive_worker_pid
      sudo_keepalive_worker_pid=
      if [[ -n "$sudo_keepalive_worker_identity_pid" ]]; then
        stop_process_group_snapshot "$sudo_keepalive_worker_identity_pid" \
          "$sudo_keepalive_worker_identity_pgid" "$sudo_keepalive_worker_identity_start" \
          "$sudo_keepalive_helper_pid"
      fi
      rm -f "$sudo_keepalive_worker_pid_path" \
        "$sudo_keepalive_worker_wrapper_pid_path" || true
      wait_for_bootstrap_child_exit "$stopped_worker_pid" || true
      if [[ ! -s "$sudo_keepalive_failure_status_path" ]]; then
        printf 'worker:125\n' >"$sudo_keepalive_failure_status_path"
      fi
    fi
  }

  if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_STARTUP_MARKER:-}" &&
    -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_STARTUP_GATE:-}" ]]; then
    : >"$BOOTSTRAP_INTERNAL_TEST_SUDO_STARTUP_MARKER"
    while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_STARTUP_GATE" &&
      ! -e "$sudo_keepalive_parent_closed_path" &&
      ! -s "$sudo_keepalive_failure_status_path" ]]; do
      observe_sudo_keepalive_worker
      /bin/sleep 0.01
    done
  fi

  while [[ ! -e "$sudo_keepalive_worker_ready_path" &&
    ! -e "$sudo_keepalive_parent_closed_path" &&
    ! -s "$sudo_keepalive_failure_status_path" ]]; do
    observe_sudo_keepalive_worker
    /bin/sleep 0.01
  done
  if [[ -e "$sudo_keepalive_parent_closed_path" ]]; then
    exit 0
  fi

  : >"$sudo_keepalive_sentinel_ready_path"
  while [[ ! -e "$sudo_keepalive_parent_closed_path" &&
    "$sudo_keepalive_helper_stop_requested" -eq 0 ]]; do
    observe_sudo_keepalive_worker
    observe_sudo_keepalive_foreground_setup
    if [[ -s "$sudo_keepalive_failure_status_path" ]]; then
      if [[ "$sudo_keepalive_failure_handled" -eq 0 ]]; then
        stop_sudo_keepalive_setup
        printf '%s\n' 125 >"$sudo_keepalive_setup_status_path"
        sudo_keepalive_failure_handled=1
      fi
      /bin/sleep 0.05
      continue
    fi
    if [[ "$sudo_keepalive_setup_foreground_mode" != 1 &&
      -e "$sudo_keepalive_setup_request_path" &&
      -z "$sudo_keepalive_setup_wrapper_pid" ]]; then
      rm -f "$sudo_keepalive_setup_request_path"
      rm -f "$sudo_keepalive_setup_completion_path" "$sudo_keepalive_setup_ack_path"
      (
        set +m
        set +e
        setup_wrapper_pid=
        setup_child_pid=
        setup_owner_failed=0
        if ! capture_current_shell_pid \
          "$sudo_keepalive_sentinel_directory/shell-pid.setup"; then
          rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
          exit 125
        fi
        setup_wrapper_self_pid=$bootstrap_captured_shell_pid
        while [[ ! -s "$sudo_keepalive_setup_wrapper_pid_path" ]]; do
          if ! bootstrap_process_is_live "$sudo_keepalive_helper_pid"; then
            rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
            exit 125
          fi
          /bin/sleep 0.01
        done
        IFS= read -r setup_wrapper_pid <"$sudo_keepalive_setup_wrapper_pid_path"
        if [[ "$setup_wrapper_pid" != "$setup_wrapper_self_pid" ]] ||
          ! bootstrap_process_is_live "$sudo_keepalive_helper_pid"; then
          rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
          exit 125
        fi
        (
          trap - HUP INT TERM
          set -e
          run_bootstrap_privileged_setup
        ) &
        setup_child_pid=$!
        while bootstrap_process_is_live "$setup_child_pid"; do
          if ! bootstrap_process_is_live "$sudo_keepalive_helper_pid"; then
            setup_owner_failed=1
            rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
            exit 125
          fi
          /bin/sleep 0.01
        done
        wait "$setup_child_pid"
        setup_status=$?
        setup_child_pid=
        trap - HUP INT TERM
        if [[ "$setup_owner_failed" -ne 0 ]]; then
          rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
          exit 125
        fi
        set -e
        printf '%s\n' "$setup_status" >"$sudo_keepalive_setup_completion_path"
        while [[ ! -e "$sudo_keepalive_setup_ack_path" ]]; do
          if ! bootstrap_process_is_live "$sudo_keepalive_helper_pid"; then
            rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
            exit 125
          fi
          /bin/sleep 0.01
        done
        rm -f "$sudo_keepalive_setup_wrapper_pid_path"
      ) &
      pending_setup_wrapper_pid=$!
      if ! record_process_identity "$sudo_keepalive_setup_wrapper_pid_path" \
        "$pending_setup_wrapper_pid" 0 "$sudo_keepalive_helper_pid" shared; then
        stop_just_forked_process "$pending_setup_wrapper_pid" \
          "$sudo_keepalive_helper_pid" "$sudo_keepalive_helper_pid"
        rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
        wait_for_sudo_keepalive_child "$pending_setup_wrapper_pid" || true
        printf 'setup-wrapper-publication:125\n' >"$sudo_keepalive_failure_status_path"
        continue
      fi
      if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_WRAPPER_PID_FILE:-}" ]]; then
        printf '%s\n' "$pending_setup_wrapper_pid" \
          >"$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_WRAPPER_PID_FILE"
      fi
      sudo_keepalive_setup_wrapper_pid=$pending_setup_wrapper_pid
    fi

    if [[ -n "$sudo_keepalive_setup_wrapper_pid" &&
      -s "$sudo_keepalive_setup_completion_path" ]]; then
      IFS= read -r setup_status <"$sudo_keepalive_setup_completion_path"
      : >"$sudo_keepalive_setup_ack_path"
      unpublish_sudo_keepalive_setup_before_wait "$sudo_keepalive_setup_wrapper_pid"
      wait_for_sudo_keepalive_child "$sudo_keepalive_setup_wrapper_pid"
      if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER:-}" &&
        -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_GATE:-}" &&
        ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER" ]]; then
        [[ -e "$sudo_keepalive_setup_wrapper_pid_path" ]] &&
          printf '%s\n' present >"$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER" ||
          printf '%s\n' absent >"$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER"
        while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_GATE" ]]; do
          /bin/sleep 0.01
        done
      fi
      sudo_keepalive_setup_wrapper_pid=
      rm -f "$sudo_keepalive_setup_wrapper_pid_path"
      printf '%s\n' "$setup_status" >"$sudo_keepalive_setup_status_path"
    elif [[ -n "$sudo_keepalive_setup_wrapper_pid" ]] &&
      ! bootstrap_process_is_live "$sudo_keepalive_setup_wrapper_pid"; then
      failed_setup_wrapper_pid=$sudo_keepalive_setup_wrapper_pid
      rm -f "$sudo_keepalive_setup_wrapper_pid_path" \
        "$sudo_keepalive_setup_completion_path" \
        "$sudo_keepalive_setup_ack_path" || true
      wait_for_sudo_keepalive_child "$failed_setup_wrapper_pid" || true
      sudo_keepalive_setup_wrapper_pid=
      printf 'setup-wrapper:125\n' >"$sudo_keepalive_failure_status_path"
    fi
    /bin/sleep 0.05
  done
  exit 0
) &
sudo_keepalive_sentinel_pid=$!
if ! record_process_identity "$sudo_keepalive_helper_pid_path" \
  "$sudo_keepalive_sentinel_pid" 1 "$$" separate; then
  stop_just_forked_process_group "$sudo_keepalive_sentinel_pid" "$$"
  rm -f "$sudo_keepalive_helper_pid_path" || true
  wait_for_bootstrap_child_exit "$sudo_keepalive_sentinel_pid" || true
  sudo_keepalive_sentinel_pid=
  printf 'error: sudo keep-alive helper identity could not be published\n' >&2
  exit 1
fi
if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_HELPER_PID_FILE:-}" ]]; then
  printf '%s\n' "$sudo_keepalive_sentinel_pid" >"$BOOTSTRAP_INTERNAL_TEST_SUDO_HELPER_PID_FILE"
fi
exec 8<&-

sudo_keepalive_start_attempts=0
while [[ ! -e "$sudo_keepalive_sentinel_ready_path" &&
  "$sudo_keepalive_start_attempts" -lt 1000 ]]; do
  if ! bootstrap_process_is_live "$sudo_keepalive_sentinel_pid"; then
    break
  fi
  /bin/sleep 0.01
  sudo_keepalive_start_attempts=$((sudo_keepalive_start_attempts + 1))
done
if [[ ! -e "$sudo_keepalive_sentinel_ready_path" ]] ||
  ! IFS= read -r sudo_keepalive_pid <"$sudo_keepalive_worker_pid_path" ||
  ! bootstrap_process_is_live "$sudo_keepalive_sentinel_pid" ||
  ! bootstrap_process_is_live "$sudo_keepalive_pid"; then
  printf 'error: sudo keep-alive helper did not become ready\n' >&2
  exit 1
fi
if ! start_sudo_keepalive_foreground_finalizer; then
  printf 'error: sudo keep-alive finalizer could not be started\n' >&2
  exit 1
fi
if [[ "$sudo_keepalive_setup_foreground_mode" == 1 ]]; then
  trap handle_sudo_keepalive_foreground_continue CONT
fi

run_bootstrap_setup_in_foreground_group() {
  local pending_setup_wrapper_pid=
  local sudo_keepalive_failure=
  local setup_wrapper_status=
  local setup_wait_attempts=0
  local setup_reaped_marker=
  local setup_reaped_gate=
  local setup_prepublication_marker=
  local setup_prepublication_gate=
  local setup_prepublication_pid_file=

  if ! bootstrap_terminal_foreground_group_is_current; then
    printf 'error: terminal foreground ownership was lost before privileged setup started\n' >&2
    return 125
  fi

  if [[ -s "$sudo_keepalive_failure_status_path" ]]; then
    IFS= read -r sudo_keepalive_failure <"$sudo_keepalive_failure_status_path" ||
      sudo_keepalive_failure=unknown
    printf 'error: sudo keep-alive failed during privileged setup (%s)\n' \
      "$sudo_keepalive_failure" >&2
    return 125
  fi

  rm -f "$sudo_keepalive_setup_status_path" \
    "$sudo_keepalive_setup_completion_path" \
    "$sudo_keepalive_setup_ack_path" \
    "$sudo_keepalive_setup_wrapper_pid_path"
  : >"$sudo_keepalive_setup_request_path"
  if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REQUEST_GATE:-}" ]]; then
    while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REQUEST_GATE" ]]; do
      if ! bootstrap_process_is_live "$sudo_keepalive_sentinel_pid" ||
        ! bootstrap_process_is_live "$sudo_keepalive_pid"; then
        printf 'error: sudo keep-alive owner exited before privileged setup started\n' >&2
        return 125
      fi
      /bin/sleep 0.01
    done
  fi

  # foreground setup wrapper は bootstrap の process group を維持
  (
    exec 9>&-
    trap - EXIT HUP INT TERM
    set +m
    set +e
    setup_wrapper_pid=
    setup_child_pid=
    setup_owner_failed=0
    if ! capture_current_shell_pid \
      "$sudo_keepalive_sentinel_directory/shell-pid.setup-foreground"; then
      rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
      exit 125
    fi
    setup_wrapper_self_pid=$bootstrap_captured_shell_pid
    while [[ ! -s "$sudo_keepalive_setup_wrapper_pid_path" ]]; do
      if ! bootstrap_process_is_live "$sudo_keepalive_sentinel_pid" ||
        ! bootstrap_process_is_live "$sudo_keepalive_pid"; then
        rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
        exit 125
      fi
      /bin/sleep 0.01
    done
    if ! load_recorded_process_identity "$sudo_keepalive_setup_wrapper_pid_path" 0 ||
      [[ "$bootstrap_recorded_pid" != "$setup_wrapper_self_pid" ]] ||
      ! process_identity_matches_snapshot "$bootstrap_recorded_pid" \
        "$bootstrap_recorded_pgid" "$bootstrap_recorded_start"; then
      rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
      exit 125
    fi
    (
      trap - HUP INT TERM
      set -e
      run_bootstrap_privileged_setup
    ) &
    setup_child_pid=$!
    while bootstrap_process_is_live "$setup_child_pid"; do
      if ! bootstrap_process_is_live "$sudo_keepalive_sentinel_pid" ||
        ! bootstrap_process_is_live "$sudo_keepalive_pid"; then
        setup_owner_failed=1
        break
      fi
      /bin/sleep 0.01
    done
    if [[ "$setup_owner_failed" -ne 0 ]]; then
      rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
      exit 125
    fi
    wait "$setup_child_pid"
    setup_wrapper_status=$?
    setup_child_pid=
    printf '%s\n' "$setup_wrapper_status" >"$sudo_keepalive_setup_completion_path"
    while [[ ! -e "$sudo_keepalive_setup_ack_path" ]]; do
      if ! bootstrap_process_is_live "$sudo_keepalive_sentinel_pid" ||
        ! bootstrap_process_is_live "$sudo_keepalive_pid"; then
        rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
        exit 125
      fi
      /bin/sleep 0.01
    done
    rm -f "$sudo_keepalive_setup_wrapper_pid_path"
  ) &
  pending_setup_wrapper_pid=$!

  # identity 公開前の wrapper failure を test hook で再現
  # 未公開中は foreground owner group を両 guardian が監視
  setup_prepublication_marker=${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_MARKER:-}
  setup_prepublication_gate=${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_GATE:-}
  setup_prepublication_pid_file=${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_FOREGROUND_WRAPPER_PUBLICATION_PID_FILE:-}
  if [[ -n "$setup_prepublication_pid_file" ]]; then
    printf '%s\n' "$pending_setup_wrapper_pid" >"$setup_prepublication_pid_file"
  fi
  if [[ -n "$setup_prepublication_marker" ]]; then
    : >"$setup_prepublication_marker"
  fi
  if [[ -n "$setup_prepublication_gate" ]]; then
    while [[ ! -e "$setup_prepublication_gate" ]]; do
      if ! bootstrap_process_is_live "$sudo_keepalive_sentinel_pid" ||
        ! bootstrap_process_is_live "$sudo_keepalive_pid"; then
        stop_just_forked_process "$pending_setup_wrapper_pid" "$$" "$$"
        rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
        printf 'setup-wrapper-publication:125\n' >"$sudo_keepalive_failure_status_path"
        return 125
      fi
      /bin/sleep 0.01
    done
  fi
  if ! record_process_identity "$sudo_keepalive_setup_wrapper_pid_path" \
    "$pending_setup_wrapper_pid" 0 "$$" shared; then
    stop_just_forked_process "$pending_setup_wrapper_pid" "$$" "$$"
    rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
    wait_for_bootstrap_child_exit "$pending_setup_wrapper_pid" || true
    printf 'setup-wrapper-publication:125\n' >"$sudo_keepalive_failure_status_path"
    return 125
  fi
  if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_WRAPPER_PID_FILE:-}" ]]; then
    printf '%s\n' "$pending_setup_wrapper_pid" \
      >"$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_WRAPPER_PID_FILE"
  fi

  while [[ ! -s "$sudo_keepalive_setup_completion_path" ]]; do
    if [[ -s "$sudo_keepalive_failure_status_path" ]]; then
      IFS= read -r sudo_keepalive_failure <"$sudo_keepalive_failure_status_path" ||
        sudo_keepalive_failure=unknown
      printf 'error: sudo keep-alive failed during privileged setup (%s)\n' \
        "$sudo_keepalive_failure" >&2
      return 125
    fi
    if ! bootstrap_process_is_live "$sudo_keepalive_sentinel_pid"; then
      printf 'error: sudo keep-alive helper exited during privileged setup\n' >&2
      return 125
    fi
    if ! bootstrap_process_is_live "$sudo_keepalive_pid"; then
      printf 'error: sudo keep-alive worker exited during privileged setup\n' >&2
      return 125
    fi
    if ! bootstrap_process_is_live "$pending_setup_wrapper_pid"; then
      rm -f "$sudo_keepalive_setup_wrapper_pid_path" \
        "$sudo_keepalive_setup_completion_path" \
        "$sudo_keepalive_setup_ack_path" || true
      wait_for_bootstrap_child_exit "$pending_setup_wrapper_pid" || true
      printf 'setup-wrapper:125\n' >"$sudo_keepalive_failure_status_path"
      printf 'error: privileged setup wrapper exited before completion\n' >&2
      return 125
    fi
    /bin/sleep 0.05
  done

  IFS= read -r setup_wrapper_status <"$sudo_keepalive_setup_completion_path" ||
    setup_wrapper_status=125
  if [[ ! "$setup_wrapper_status" =~ ^[0-9]+$ ]]; then
    setup_wrapper_status=125
  fi
  : >"$sudo_keepalive_setup_ack_path"
  while [[ -e "$sudo_keepalive_setup_wrapper_pid_path" &&
    "$setup_wait_attempts" -lt 20 ]] &&
    bootstrap_process_is_live "$pending_setup_wrapper_pid"; do
    /bin/sleep 0.01
    setup_wait_attempts=$((setup_wait_attempts + 1))
  done
  rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
  setup_wait_attempts=0
  while bootstrap_process_is_live "$pending_setup_wrapper_pid" &&
    [[ "$setup_wait_attempts" -lt 100 ]]; do
    /bin/sleep 0.01
    setup_wait_attempts=$((setup_wait_attempts + 1))
  done
  if bootstrap_process_is_live "$pending_setup_wrapper_pid"; then
    printf 'setup-wrapper:125\n' >"$sudo_keepalive_failure_status_path"
    printf 'error: privileged setup wrapper did not exit after completion\n' >&2
    return 125
  fi
  wait_for_bootstrap_child_exit "$pending_setup_wrapper_pid" || true

  setup_reaped_marker=${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_MARKER:-}
  setup_reaped_gate=${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REAPED_GATE:-}
  if [[ -n "$setup_reaped_marker" && -n "$setup_reaped_gate" &&
    ! -e "$setup_reaped_marker" ]]; then
    [[ -e "$sudo_keepalive_setup_wrapper_pid_path" ]] &&
      printf '%s\n' present >"$setup_reaped_marker" ||
      printf '%s\n' absent >"$setup_reaped_marker"
    while [[ ! -e "$setup_reaped_gate" ]]; do
      /bin/sleep 0.01
    done
  fi
  rm -f "$sudo_keepalive_setup_wrapper_pid_path" || true
  printf '%s\n' "$setup_wrapper_status" >"$sudo_keepalive_setup_status_path"
  return "$setup_wrapper_status"
}

run_bootstrap_setup_with_keepalive() {
  local bootstrap_setup_status=
  local sudo_keepalive_failure=

  if [[ "$sudo_keepalive_setup_foreground_mode" == 1 ]]; then
    run_bootstrap_setup_in_foreground_group
    return
  fi
  if [[ -s "$sudo_keepalive_failure_status_path" ]]; then
    IFS= read -r sudo_keepalive_failure <"$sudo_keepalive_failure_status_path" ||
      sudo_keepalive_failure=unknown
    printf 'error: sudo keep-alive failed during privileged setup (%s)\n' \
      "$sudo_keepalive_failure" >&2
    return 125
  fi
  rm -f "$sudo_keepalive_setup_status_path"
  : >"$sudo_keepalive_setup_request_path"
  if [[ -n "${BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REQUEST_GATE:-}" ]]; then
    while [[ ! -e "$BOOTSTRAP_INTERNAL_TEST_SUDO_SETUP_REQUEST_GATE" ]]; do
      /bin/sleep 0.01
    done
  fi
  while [[ ! -s "$sudo_keepalive_setup_status_path" ]]; do
    if [[ -s "$sudo_keepalive_failure_status_path" ]]; then
      IFS= read -r sudo_keepalive_failure <"$sudo_keepalive_failure_status_path" ||
        sudo_keepalive_failure=unknown
      printf 'error: sudo keep-alive failed during privileged setup (%s)\n' \
        "$sudo_keepalive_failure" >&2
      return 125
    fi
    if ! bootstrap_process_is_live "$sudo_keepalive_sentinel_pid"; then
      printf 'error: sudo keep-alive helper exited during privileged setup\n' >&2
      return 125
    fi
    if ! bootstrap_process_is_live "$sudo_keepalive_pid"; then
      printf 'error: sudo keep-alive worker exited during privileged setup\n' >&2
      return 125
    fi
    /bin/sleep 0.05
  done
  if [[ -s "$sudo_keepalive_failure_status_path" ]]; then
    IFS= read -r sudo_keepalive_failure <"$sudo_keepalive_failure_status_path" ||
      sudo_keepalive_failure=unknown
    printf 'error: sudo keep-alive failed during privileged setup (%s)\n' \
      "$sudo_keepalive_failure" >&2
    return 125
  fi
  IFS= read -r bootstrap_setup_status <"$sudo_keepalive_setup_status_path"
  return "$bootstrap_setup_status"
}

set +m

run_bootstrap_setup_with_keepalive

# keep-alive を停止して sudo timestamp を無効化
stop_sudo_keepalive
trap - EXIT

# setup wrapper 内の Homebrew environment を親 shell にも反映
refresh_homebrew_environment

step 'Agent Skills'
"$repo_dir/skills/setup.sh"

step 'done'
printf 'see README.md for remaining manual setup steps\n'
