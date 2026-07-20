#!/usr/bin/env bash
#
# ============================================================================
# dotfiles を $HOME 配下にシンボリックリンク展開するスクリプト
# ============================================================================

set -euo pipefail

# ============================================================================
# グローバル設定
# ============================================================================

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # このスクリプトを置いているリポジトリのルート
home_dir="${HOME:-}"                                        # 検証対象の HOME
backup_root=                                                # HOME 検証後に初期化するバックアップルート
backup_dir=                                                 # 最初の退避時に一意に確保する今回分のバックアップ先
lock_path=                                                  # 同一 HOME への並行展開を防ぐ固定ロックパス
lock_generation_dir=                                        # 所有者の公開前に保持するプロセス固有のロック世代
lock_generation_name=                                       # 固定ロックのシンボリックリンクから参照する世代名
lock_owner_start_identity=                                  # PID 再利用を識別するプロセス開始情報
recovery_observation=                                       # 所有者不在の復旧ミューテックスの同一性確認用
recovery_ownerless_attempts=0                               # 初期化中のミューテックスを誤回収しないための観測回数
dry_run=0                                                   # 1 のとき実コマンドを実行せず内容のみ表示
backup_created=0                                            # 退避が 1 件以上発生したかを示すフラグ
backup_keep=5                                               # 保持するバックアップ世代数

# 使い方を標準出力に表示
usage() {
  cat <<'EOF'
Usage: ./scripts/link-dotfiles.sh [--dry-run] [-h | --help]

Create symlinks from this repository into $HOME.
Existing regular files and directories are moved to ~/.dotfiles-backup/<timestamp>[-<sequence>]/ first.

Options:
  --dry-run   Show actions without changing files.
  -h, --help  Show this help and exit.
EOF
}

# HOME がルート以外の既存絶対パスか検証
validate_environment() {
  local physical_home

  if [[ -z "$home_dir" || "$home_dir" != /* || "$home_dir" == / || ! -d "$home_dir" ]]; then
    printf 'error: HOME must be an existing absolute path other than /\n' >&2
    return 1
  fi

  physical_home="$(cd "$home_dir" && pwd -P)" || return 1
  if [[ "$physical_home" == / ]]; then
    printf 'error: HOME must not resolve to /\n' >&2
    return 1
  fi
}

# ============================================================================
# ユーティリティ
# ============================================================================

# dry-run 時はコマンドの表示のみ行う実行ラッパ
run() {
  if ((dry_run)); then
    # %q で各引数を再実行可能な形にクオートして表示
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# ============================================================================
# 排他制御
# ============================================================================

# symlink(2) で競合ディレクトリ配下への誤作成を防ぐ
create_symlink_exclusive() {
  perl -MErrno=EEXIST -e '
    if (symlink($ARGV[0], $ARGV[1])) {
      exit 0;
    }
    exit($! == EEXIST ? 1 : 2);
  ' "$1" "$2"
}

# 固定ロックから参照できる、自スクリプトの一意な世代名だけを許可
is_lock_generation_name() {
  [[ "$1" != */* && "$1" == .link-dotfiles.lock.generation.?????? ]]
}

# PID と開始時刻を組み合わせ、PID 再利用後の別プロセスを所有者と誤認しない
process_start_identity() {
  local identity

  identity="$(LC_ALL=C TZ=UTC /bin/ps -o lstart= -o command= -p "$1" 2>/dev/null)" ||
    return 1
  identity="${identity#"${identity%%[![:space:]]*}"}"
  identity="${identity%"${identity##*[![:space:]]}"}"
  [[ -n "$identity" ]] || return 1
  printf '%s\n' "$identity"
}

# 連続観測するディレクトリの同一性を識別
path_identity() {
  local identity

  identity="$(stat -f '%d:%i' "$1" 2>/dev/null)" ||
    identity="$(stat -c '%d:%i' "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$identity"
}

write_owner_identity() {
  printf '%s\n%s\n' "$2" "$3" >"$1"
}

# FIFO やシンボリックリンクを読まず、通常ファイルの所有者情報だけを取得
read_owner_identity() {
  local owner_file="$1"

  OWNER_IDENTITY_PID=
  OWNER_IDENTITY_START=
  if [[ -f "$owner_file" && ! -L "$owner_file" ]]; then
    {
      IFS= read -r OWNER_IDENTITY_PID || true
      IFS= read -r OWNER_IDENTITY_START || true
    } <"$owner_file"
  fi
}

is_complete_owner_identity() {
  [[ "$1" =~ ^[0-9]+$ && -n "$2" ]] || return 1
  ((10#$1 > 1))
}

is_live_owner_identity() {
  local current_start

  is_complete_owner_identity "$1" "$2" || return 1
  current_start="$(process_start_identity "$1")" || return 1
  [[ "$current_start" == "$2" ]]
}

is_live_legacy_owner_pid() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 > 1)) && kill -0 "$1" 2>/dev/null
}

read_lock_owner() {
  local generation_dir="$1"

  read_owner_identity "$generation_dir/owner"
  LOCK_OWNER="$OWNER_IDENTITY_PID"
  LOCK_OWNER_START="$OWNER_IDENTITY_START"
}

# 固定ロックのシンボリックリンクが指定世代を参照しているかを判定
lock_points_to_generation() {
  local expected_generation="$1"
  local current_generation=

  [[ -L "$lock_path" ]] || return 1
  current_generation="$(readlink "$lock_path")" || return 1
  [[ "$current_generation" == "$expected_generation" ]]
}

# 復旧ミューテックスを取得し、放棄済みなら回収
acquire_recovery_mutex() {
  local generation_dir="$1"
  local recovery_dir="$generation_dir/recovery"
  local owner_file="$recovery_dir/owner"
  local owner_pid=
  local owner_start=
  local observation

  if mkdir "$recovery_dir" 2>/dev/null; then
    if write_owner_identity "$owner_file" "$$" "$lock_owner_start_identity"; then
      recovery_observation=
      recovery_ownerless_attempts=0
      return 0
    fi
    rmdir "$recovery_dir" 2>/dev/null || true
    return 1
  fi

  [[ -d "$recovery_dir" && ! -L "$recovery_dir" ]] || return 1
  read_owner_identity "$owner_file"
  owner_pid="$OWNER_IDENTITY_PID"
  owner_start="$OWNER_IDENTITY_START"
  if is_live_owner_identity "$owner_pid" "$owner_start" ||
    { [[ -z "$owner_start" ]] && is_live_legacy_owner_pid "$owner_pid"; }; then
    recovery_observation=
    recovery_ownerless_attempts=0
    return 1
  fi

  observation="$recovery_dir|$owner_pid|$owner_start"
  if [[ "$observation" != "$recovery_observation" ]]; then
    recovery_observation="$observation"
    recovery_ownerless_attempts=0
  fi
  if ! is_complete_owner_identity "$owner_pid" "$owner_start" &&
    [[ ! "$owner_pid" =~ ^[0-9]+$ ]]; then
    recovery_ownerless_attempts=$((recovery_ownerless_attempts + 1))
    ((recovery_ownerless_attempts >= 10)) || return 1
  fi

  # 所有者が終了済み、または連続して不在のミューテックスだけを回収
  rm -f "$owner_file" 2>/dev/null || return 1
  rmdir "$recovery_dir" 2>/dev/null || return 1
  recovery_observation=
  recovery_ownerless_attempts=0

  mkdir "$recovery_dir" 2>/dev/null || return 1
  if ! write_owner_identity "$owner_file" "$$" "$lock_owner_start_identity"; then
    rmdir "$recovery_dir" 2>/dev/null || true
    return 1
  fi
}

release_recovery_mutex() {
  local generation_dir="$1"
  local recovery_dir="$generation_dir/recovery"
  local owner_file="$recovery_dir/owner"
  local owner_pid=
  local owner_start=

  read_owner_identity "$owner_file"
  owner_pid="$OWNER_IDENTITY_PID"
  owner_start="$OWNER_IDENTITY_START"
  [[ "$owner_pid" == "$$" && "$owner_start" == "$lock_owner_start_identity" ]] || return 1
  rm -f "$owner_file" 2>/dev/null || return 1
  rmdir "$recovery_dir" 2>/dev/null
}

# 自プロセスの世代だけを、固定ロックとの対応を再確認して解放・後始末
release_lock() {
  local owner_pid
  local owner_start
  local remove_generation=0

  if [[ -z "$lock_generation_dir" || ! -d "$lock_generation_dir" ||
    -L "$lock_generation_dir" ]]; then
    return 0
  fi

  if acquire_recovery_mutex "$lock_generation_dir"; then
    read_lock_owner "$lock_generation_dir"
    owner_pid="$LOCK_OWNER"
    owner_start="$LOCK_OWNER_START"

    if [[ "$owner_pid" == "$$" && "$owner_start" == "$lock_owner_start_identity" ]]; then
      if lock_points_to_generation "$lock_generation_name"; then
        # 同じ世代を参照している間だけ固定ロックを外す
        if rm "$lock_path" 2>/dev/null; then
          remove_generation=1
        fi
      else
        # 公開前、または固定ロックが既に別世代なら自世代だけを片付ける
        remove_generation=1
      fi
    fi

    if ((remove_generation)); then
      rm -f "$lock_generation_dir/owner" 2>/dev/null || true
    fi
    release_recovery_mutex "$lock_generation_dir" 2>/dev/null || true
    if ((remove_generation)); then
      rmdir "$lock_generation_dir" 2>/dev/null || true
    fi
  fi
}

# 固定リンクと所有者の終了を再確認して放棄済みロックを回収
recover_abandoned_lock() {
  local expected_generation="$1"
  local expected_owner="$2"
  local expected_owner_start="$3"
  local generation_dir="$backup_root/$expected_generation"
  local current_owner
  local current_owner_start

  is_lock_generation_name "$expected_generation" || return 1
  [[ -d "$generation_dir" && ! -L "$generation_dir" ]] || return 1
  acquire_recovery_mutex "$generation_dir" || return 1

  read_lock_owner "$generation_dir"
  current_owner="$LOCK_OWNER"
  current_owner_start="$LOCK_OWNER_START"
  if ! lock_points_to_generation "$expected_generation" ||
    [[ "$current_owner" != "$expected_owner" ]] ||
    [[ "$current_owner_start" != "$expected_owner_start" ]] ||
    is_live_owner_identity "$current_owner" "$current_owner_start" ||
    { [[ -z "$current_owner_start" ]] &&
      is_live_legacy_owner_pid "$current_owner"; }; then
    release_recovery_mutex "$generation_dir" 2>/dev/null || true
    return 1
  fi

  # 固定リンクを先に外し、次世代の公開後に旧世代を誤削除しないようにする
  rm "$lock_path" 2>/dev/null || {
    release_recovery_mutex "$generation_dir" 2>/dev/null || true
    return 1
  }
  rm -f "$generation_dir/owner" 2>/dev/null || true
  release_recovery_mutex "$generation_dir" 2>/dev/null || true
  rmdir "$generation_dir" 2>/dev/null || true
}

# PID だけを記録する放棄済みディレクトリロックを回収
recover_legacy_abandoned_lock() {
  local expected_owner="$1"
  local expected_identity="$2"
  local current_owner=

  [[ -n "$expected_identity" ]] || return 1
  [[ -d "$lock_path" && ! -L "$lock_path" ]] || return 1
  [[ "$(path_identity "$lock_path" 2>/dev/null || true)" == "$expected_identity" ]] || return 1
  acquire_recovery_mutex "$lock_path" || return 1
  if [[ -f "$lock_path/owner" && ! -L "$lock_path/owner" ]]; then
    IFS= read -r current_owner <"$lock_path/owner" || true
  fi

  if [[ "$(path_identity "$lock_path" 2>/dev/null || true)" != "$expected_identity" ]] ||
    [[ "$current_owner" != "$expected_owner" ]] ||
    { [[ "$current_owner" =~ ^[0-9]+$ ]] && kill -0 "$current_owner" 2>/dev/null; }; then
    release_recovery_mutex "$lock_path" 2>/dev/null || true
    return 1
  fi

  rm -f "$lock_path/owner" 2>/dev/null || true
  release_recovery_mutex "$lock_path" 2>/dev/null || return 1
  rmdir "$lock_path" 2>/dev/null
}

# 初期化済み世代への固定リンクを排他的に公開し、同一 HOME への処理を直列化
acquire_lock() {
  local attempts=0
  local max_attempts=300
  local ownerless_attempts=0
  local observed_lock_state=
  local current_lock_state=
  local current_lock_identity=
  local current_generation=
  local current_generation_dir=
  local legacy_lock=0
  local publish_status
  local owner_pid
  local owner_start
  local owner_is_live=0

  ((dry_run)) && return 0

  if ! command -v perl >/dev/null 2>&1; then
    printf 'error: perl is required for atomic dotfiles link locking\n' >&2
    return 1
  fi

  mkdir -p "$backup_root" || return
  lock_path="$backup_root/.link-dotfiles.lock"

  lock_generation_dir="$(mktemp -d "$backup_root/.link-dotfiles.lock.generation.XXXXXX")" ||
    return
  lock_generation_name="${lock_generation_dir##*/}"
  lock_owner_start_identity="$(process_start_identity "$$")" || {
    rmdir "$lock_generation_dir" 2>/dev/null || true
    return 1
  }
  if ! is_lock_generation_name "$lock_generation_name" ||
    ! write_owner_identity "$lock_generation_dir/owner" "$$" "$lock_owner_start_identity"; then
    rm -f "$lock_generation_dir/owner" 2>/dev/null || true
    rmdir "$lock_generation_dir" 2>/dev/null || true
    lock_generation_dir=
    lock_generation_name=
    return 1
  fi
  # 公開前の通常終了やシグナルでも、外から参照されない自世代だけを清掃
  trap 'release_lock' EXIT

  while true; do
    # 所有者を含む世代を作り終えた後、固定パスへシンボリックリンクを原子的に公開
    publish_status=0
    create_symlink_exclusive "$lock_generation_name" "$lock_path" 2>/dev/null ||
      publish_status=$?
    if ((publish_status == 0)); then
      if lock_points_to_generation "$lock_generation_name"; then
        return 0
      fi
    elif ((publish_status != 1)); then
      printf 'error: failed to publish dotfiles link lock: %s\n' "$lock_path" >&2
      return 1
    fi

    owner_pid=
    owner_start=
    current_generation=
    current_lock_identity=
    legacy_lock=0
    if [[ -L "$lock_path" ]]; then
      current_generation="$(readlink "$lock_path" 2>/dev/null || true)"
      if is_lock_generation_name "$current_generation"; then
        current_generation_dir="$backup_root/$current_generation"
        if [[ -d "$current_generation_dir" && ! -L "$current_generation_dir" ]]; then
          read_lock_owner "$current_generation_dir"
          owner_pid="$LOCK_OWNER"
          owner_start="$LOCK_OWNER_START"
        fi
      fi
    elif [[ -d "$lock_path" && ! -L "$lock_path" ]]; then
      legacy_lock=1
      current_lock_identity="$(path_identity "$lock_path" 2>/dev/null || true)"
      if [[ -f "$lock_path/owner" && ! -L "$lock_path/owner" ]]; then
        IFS= read -r owner_pid <"$lock_path/owner" || true
      fi
    fi

    current_lock_state="$current_generation|$legacy_lock|$current_lock_identity|$owner_pid|$owner_start"
    if [[ "$current_lock_state" != "$observed_lock_state" ]]; then
      ownerless_attempts=0
      observed_lock_state="$current_lock_state"
    fi

    # ミューテックス内で世代と所有者の終了を再確認して回収
    owner_is_live=0
    if [[ -n "$current_generation" ]]; then
      if is_live_owner_identity "$owner_pid" "$owner_start" ||
        { [[ -z "$owner_start" ]] && is_live_legacy_owner_pid "$owner_pid"; }; then
        owner_is_live=1
      fi
    elif ((legacy_lock)) && is_live_legacy_owner_pid "$owner_pid"; then
      # PID だけの所有者情報でも稼働中プロセスを保護
      owner_is_live=1
    fi

    if [[ -n "$current_generation" && "$owner_pid" =~ ^[0-9]+$ ]] &&
      ((owner_is_live == 0)); then
      recover_abandoned_lock "$current_generation" "$owner_pid" "$owner_start" && continue
    elif ((legacy_lock)) && [[ "$owner_pid" =~ ^[0-9]+$ ]] &&
      ((owner_is_live == 0)); then
      recover_legacy_abandoned_lock "$owner_pid" "$current_lock_identity" && continue
    elif { [[ -n "$current_generation" ]] && [[ ! "$owner_pid" =~ ^[0-9]+$ ]]; } ||
      { ((legacy_lock)) && [[ ! "$owner_pid" =~ ^[0-9]+$ ]]; }; then
      ownerless_attempts=$((ownerless_attempts + 1))
      if ((ownerless_attempts >= 10)); then
        if [[ -n "$current_generation" ]]; then
          recover_abandoned_lock "$current_generation" "$owner_pid" "$owner_start" && continue
        else
          recover_legacy_abandoned_lock "$owner_pid" "$current_lock_identity" && continue
        fi
        ownerless_attempts=0
      fi
    else
      ownerless_attempts=0
    fi

    if ((attempts >= max_attempts)); then
      printf 'error: timed out waiting for dotfiles link lock: %s\n' "$lock_path" >&2
      return 1
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
}

# ============================================================================
# リンク・バックアップ用ユーティリティ
# ============================================================================

# シンボリックリンク作成結果のサマリを出力 (dry-run 時は "would link" に切り替え)
report_link() {
  local verb='linked'
  ((dry_run)) && verb='would link'
  printf '%s: %s -> %s\n' "$verb" "$1" "$2"
}

# $HOME からの相対パスをバックアップ先における同じ相対パスへ変換
backup_path() {
  printf '%s/%s' "$backup_dir" "${1#"$HOME"/}"
}

# 秒が同じ再実行でも衝突しないバックアップ世代を確保
ensure_backup_dir() {
  local timestamp
  local candidate
  local suffix=0

  [[ -n "$backup_dir" ]] && return 0

  timestamp="$(date +%Y%m%d%H%M%S)"
  candidate="$backup_root/$timestamp"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    suffix=$((suffix + 1))
    printf -v candidate '%s/%s-%06d' "$backup_root" "$timestamp" "$suffix"
  done

  backup_dir="$candidate"
  if ((dry_run)); then
    return 0
  fi

  if ! mkdir "$backup_dir"; then
    printf 'error: failed to create a unique backup directory: %s\n' "$backup_dir" >&2
    backup_dir=
    return 1
  fi
  printf '%s\n' 'link-dotfiles-v1' >"$backup_dir/.dotfiles-backup-generation"
}

# 古いバックアップを backup_keep 世代だけ残して削除
prune_backups() {
  local root="$backup_root"
  local candidate
  local name
  [[ -d "$root" ]] || return 0

  # 14 桁名とマーカー付き連番名だけを削除候補にする
  {
    while IFS= read -r candidate; do
      name="${candidate##*/}"
      if [[ "$name" =~ ^[0-9]{14}$ ]] ||
        { [[ "$name" =~ ^[0-9]{14}-[0-9]{6}$ ]] &&
          [[ -f "$candidate/.dotfiles-backup-generation" ]]; }; then
        printf '%s\n' "$candidate"
      fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print)
    # dry-run では未作成の今回分 backup_dir も削除候補の算出に含める
    if ((dry_run && backup_created)) &&
      [[ "${backup_dir%/*}" == "$root" ]] &&
      [[ "${backup_dir##*/}" =~ ^[0-9]{14}(-[0-9]{6})?$ ]]; then
      printf '%s\n' "$backup_dir"
    fi
  } |
    sort -r |
    tail -n +$((backup_keep + 1)) |
    while IFS= read -r backup; do
      run rm -rf "$backup"
    done
}

# 既存リンクが指定 source を指しているかを判定
is_correct_symlink() {
  [[ -L "$1" && "$(readlink "$1")" == "$2" ]]
}

# 自リポジトリ由来の管理対象外シンボリックリンクだけを削除
remove_obsolete_symlink() {
  local relative="$1"
  local source="$repo_dir/$relative"
  local target="$HOME/$relative"

  is_correct_symlink "$target" "$source" || return 0
  run rm "$target"
}

# ============================================================================
# リンク作成
# ============================================================================

# repo_dir の relative を $HOME 配下にシンボリックリンクとして作成し、既存の実体は退避
link_file() {
  local relative="$1"
  local source="$repo_dir/$relative"
  local target="$HOME/$relative"

  # -L も見るのは壊れたシンボリックリンクを source として扱うため (-e は壊れたリンクで false)
  if [[ ! -e "$source" && ! -L "$source" ]]; then
    printf 'missing source: %s\n' "$source" >&2
    return 1
  fi

  if is_correct_symlink "$target" "$source"; then
    printf 'ok: %s -> %s\n' "$target" "$source"
    return 0
  fi

  run mkdir -p "$(dirname "$target")" || return

  if [[ -L "$target" ]]; then
    run rm "$target" || return
  elif [[ -e "$target" ]]; then
    # 実体 (ファイルまたはディレクトリ) はバックアップへ退避
    local backup
    ensure_backup_dir || return
    backup="$(backup_path "$target")"
    run mkdir -p "$(dirname "$backup")" || return
    run mv -n "$target" "$backup" || return
    if ((!dry_run)) && [[ -e "$target" || -L "$target" ]]; then
      printf 'error: backup destination already exists: %s\n' "$backup" >&2
      return 1
    fi
    backup_created=1
  fi

  # -h で競合するディレクトリリンクを辿らず、配下への誤作成を防ぐ
  run ln -sh "$source" "$target" || return
  report_link "$target" "$source"
}

# ============================================================================
# Codex
# ============================================================================

# config.toml より優先される /etc/codex/managed_config.toml の残存を警告
warn_legacy_codex_managed_config() {
  local target="/etc/codex/managed_config.toml"

  [[ -e "$target" || -L "$target" ]] || return 0

  printf 'warning: %s exists and has higher precedence than /etc/codex/config.toml\n' "$target" >&2
  printf '         remove it if you want Codex App local config to override dotfiles defaults\n' >&2
}

# Codex ベース設定を /etc/codex/config.toml へ sudo でシンボリックリンク作成
link_codex_system_config() {
  local source="$repo_dir/.config/codex/config.toml"
  local target="/etc/codex/config.toml"

  if [[ ! -e "$source" ]]; then
    printf 'missing source: %s\n' "$source" >&2
    return 1
  fi

  if is_correct_symlink "$target" "$source"; then
    printf 'ok: %s -> %s\n' "$target" "$source"
    return 0
  fi

  # link_file と異なりシステム領域 (/etc) のファイルは退避せず、競合時は中断
  if [[ -L "$target" ]]; then
    printf 'existing symlink is different: %s -> %s\n' "$target" "$(readlink "$target")" >&2
    return 1
  elif [[ -e "$target" ]]; then
    printf 'existing file: %s\n' "$target" >&2
    printf 'move or remove it before installing the Codex base config symlink\n' >&2
    return 1
  fi

  run sudo mkdir -p "$(dirname "$target")" || return
  run sudo ln -s "$source" "$target" || return
  report_link "$target" "$source"
}

# ============================================================================
# エントリポイント
# ============================================================================

# CLI 引数を解釈し、リンク作成・Codex 関連処理・バックアップ整理を実行
main() {
  # CLI 引数を解釈
  while (($#)); do
    case "$1" in
    --dry-run)
      dry_run=1
      ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      usage >&2
      return 2
      ;;
    esac
    shift
  done

  validate_environment || return
  backup_root="$home_dir/.dotfiles-backup"
  acquire_lock || return

  # 管理対象ファイル一覧、リポジトリ相対パスと $HOME 相対パスは同一 (順序は挙動に影響なし)
  local files=(
    # shell
    ".bash_profile"
    ".bashrc"
    ".zshenv"
    ".zshrc"
    ".shell/functions/aws.sh"
    ".shell/functions/git-worktree.sh"
    # terminal
    ".wezterm.lua"
    ".config/starship.toml"
    # keyboard (karabiner.json 単体の symlink では Karabiner が設定変更を検知できないためディレクトリごとリンク)
    ".config/karabiner"
    # AI エージェント
    ".config/agents/AGENTS.md"
    ".codex/AGENTS.md"
    ".codex/browser/config.toml"
    ".claude/CLAUDE.md"
    ".claude/settings.json"
    ".claude/hooks/inject-guidelines-context.sh"
    ".claude/hooks/pre-bash-guard.sh"
    ".claude/hooks/statusline.sh"
    # AWS プロファイル復元
    ".aws/load-active-profile.sh"
  )

  # 各ファイルを $HOME 配下にリンクし、失敗したものを記録
  local file
  local -a failed_items
  failed_items=()

  # 管理対象外の Zsh 専用リンクを、自リポジトリ由来の場合だけ除去
  if ! remove_obsolete_symlink ".zsh/functions/git-worktree.zsh"; then
    failed_items+=(".zsh/functions/git-worktree.zsh (obsolete symlink)")
  fi

  for file in "${files[@]}"; do
    if ! link_file "$file"; then
      failed_items+=("$file")
    fi
  done

  # Codex ベース設定 (/etc/codex/config.toml) を sudo でリンク
  warn_legacy_codex_managed_config
  if ! link_codex_system_config; then
    failed_items+=("/etc/codex/config.toml")
  fi

  # バックアップディレクトリの後処理 (dry-run 表示 / 完了報告 / 世代整理)
  if ((dry_run)); then
    # 実行時に発生する世代整理もそのまま表示
    if ((backup_created)); then
      prune_backups
    fi
    printf 'dry run complete\n'
  elif [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
    printf 'backups: %s\n' "$backup_dir"
    # 実バックアップが発生した場合のみ世代整理
    if ((backup_created)); then
      prune_backups
      printf 'kept latest %d backup generations\n' "$backup_keep"
    fi
  fi

  # 失敗があれば一覧を stderr に出して非ゼロ終了
  if ((${#failed_items[@]} > 0)); then
    printf 'failed items:\n' >&2
    printf '  %s\n' "${failed_items[@]}" >&2
    return 1
  fi
}

main "$@"
