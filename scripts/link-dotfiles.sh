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
dry_run=0                                                   # 1 のとき実コマンドを実行せず内容のみ表示
backup_created=0                                            # 退避が 1 件以上発生したかを示すフラグ
backup_keep=5                                               # 保持するバックアップ世代数
backup_diffs=()                                             # リポジトリ版と内容が異なるまま退避したファイルの一覧
managed_targets=()                                          # ツールが自動追記した痕跡がある退避先の一覧
# Rancher Desktop などが rc ファイルへ自動追記するときの目印
MANAGED_BLOCK_MARKER='MANAGED BY RANCHER DESKTOP'

process_lock_library="$repo_dir/lib/process-lock.sh"
if [[ ! -f "$process_lock_library" || -L "$process_lock_library" ]]; then
  printf 'error: process lock library is missing or unsafe: %s\n' \
    "$process_lock_library" >&2
  exit 1
fi
source_working_dir="$PWD"
cd "$repo_dir" || exit 1
source lib/process-lock.sh
cd "$source_working_dir" || exit 1
unset source_working_dir

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

  if ((EUID == 0)); then
    printf 'error: do not run scripts/link-dotfiles.sh with sudo or as root\n' >&2
    return 1
  fi

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
  local source_relative="$1"
  local target_relative="${2:-$1}"
  local source="$repo_dir/$source_relative"
  local target="$HOME/$target_relative"

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
    # 端末ローカルの変更が黙って消えないよう、内容差分のある退避を記録。
    # -r でディレクトリ (.config/karabiner など) も再帰的に比較する。
    #
    # dry-run では退避を実行していないので、まだ元の場所にある target と比較する。
    # ここを飛ばすと --dry-run による事前確認で上書き消失が一切見えず、
    # 事前確認の意味がなくなる
    local compare_target="$backup"
    ((dry_run)) && compare_target="$target"
    if [[ -e "$compare_target" && -e "$source" ]] &&
      ! diff -rq "$compare_target" "$source" >/dev/null 2>&1; then
      backup_diffs+=("$target (backup: $backup)")
    fi

    # ツールが rc ファイルへ自動追記する設定のままリンクすると、
    # 追記先がリポジトリの追跡ファイルになり、リポジトリが書き換えられる
    if [[ -f "$compare_target" ]] &&
      grep -qF "$MANAGED_BLOCK_MARKER" "$compare_target" 2>/dev/null; then
      managed_targets+=("$target")
    fi
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
  if ((!dry_run)); then
    mkdir -p "$backup_root" || return
    process_lock_acquire \
      "$backup_root/.link-dotfiles.lock" \
      '.link-dotfiles.lock.generation.??????' \
      'dotfiles link' \
      30 || return
    trap 'process_lock_release' EXIT
  fi

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
    ".config/git/ignore"
    ".config/gh/config.yml"
    # keyboard (karabiner.json 単体の symlink では Karabiner が設定変更を検知できないためディレクトリごとリンク)
    ".config/karabiner"
    # 開発ツールのバージョン管理
    ".config/mise/config.toml"
    # AI エージェント
    ".config/agents/AGENTS.md"
    ".codex/browser/config.toml"
    ".claude/CLAUDE.md"
    ".claude/settings.json"
    ".claude/hooks/pre-bash-guard.py"
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

  # 廃止した注入フックのリンクを、自リポジトリ由来の場合だけ除去
  if ! remove_obsolete_symlink ".claude/hooks/inject-guidelines-context.sh"; then
    failed_items+=(".claude/hooks/inject-guidelines-context.sh (obsolete symlink)")
  fi

  for file in "${files[@]}"; do
    if ! link_file "$file"; then
      failed_items+=("$file")
    fi
  done

  # 共通ルールの正本を Codex の参照先にもリンク
  if ! link_file ".config/agents/AGENTS.md" ".codex/AGENTS.md"; then
    failed_items+=(".codex/AGENTS.md")
  fi

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

  # リポジトリ版と異なる内容を退避した場合は、統合漏れの可能性を警告
  if ((${#backup_diffs[@]} > 0)); then
    printf 'warning: replaced files differed from the repository version:\n' >&2
    printf '  %s\n' "${backup_diffs[@]}" >&2
    printf '         merge local changes into the repository or ~/.zshrc.local, then relink\n' >&2
  fi

  # 自動追記の設定が残っていると、リンク後は追記先がリポジトリの追跡ファイルになる
  if ((${#managed_targets[@]} > 0)); then
    printf 'warning: these files contain a tool-managed block (%s):\n' \
      "$MANAGED_BLOCK_MARKER" >&2
    printf '  %s\n' "${managed_targets[@]}" >&2
    printf '         after linking, the tool would write into the repository itself\n' >&2
    printf '         switch the tool to manual PATH management before relinking\n' >&2
  fi

  # 失敗があれば一覧を stderr に出して非ゼロ終了
  if ((${#failed_items[@]} > 0)); then
    printf 'failed items:\n' >&2
    printf '  %s\n' "${failed_items[@]}" >&2
    return 1
  fi
}

main "$@"
