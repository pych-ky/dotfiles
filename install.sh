#!/usr/bin/env bash
#
# dotfiles を $HOME 配下にシンボリックリンクとして展開し、既存ファイルは ~/.dotfiles-backup/ に退避

set -euo pipefail

# ============================================================================
# グローバル設定
# ============================================================================

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # このスクリプトを置いているリポジトリのルート
backup_dir="${HOME}/.dotfiles-backup/$(date +%Y%m%d%H%M%S)"  # 今回実行分のバックアップ先
dry_run=0          # 1 のとき実コマンドを実行せず内容のみ表示
backup_created=0   # 退避が 1 件以上発生したかを示すフラグ
backup_keep=5      # 保持するバックアップ世代数

usage() {
  cat <<'EOF'
Usage: ./install.sh [--dry-run]

Create symlinks from this repository into $HOME.
Existing regular files are moved to ~/.dotfiles-backup/<timestamp>/ first.
EOF
}


# ============================================================================
# ユーティリティ
# ============================================================================

# dry-run 時はコマンドの表示のみ行う実行ラッパ
run() {
  if (( dry_run )); then
    printf 'DRY-RUN: %q' "$1"
    shift
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# $HOME からの相対パスをバックアップ先における同じ相対パスへ変換
backup_path() {
  local target="$1"
  local relative="${target#"$HOME"/}"

  printf '%s/%s' "$backup_dir" "$relative"
}

# 古いバックアップを backup_keep 世代だけ残して削除
prune_backups() {
  local root="$HOME/.dotfiles-backup"
  [[ -d "$root" ]] || return 0

  # ディレクトリ名がタイムスタンプ昇順なので、降順ソートして先頭から N 世代を保持
  local backups
  backups="$(find "$root" -mindepth 1 -maxdepth 1 -type d -print | sort -r)"
  local count=0
  local backup

  while IFS= read -r backup; do
    [[ -n "$backup" ]] || continue
    count=$((count + 1))
    ((count <= backup_keep)) && continue
    run rm -rf "$backup"
  done <<<"$backups"
}


# ============================================================================
# リンク作成
# ============================================================================

# repo_dir の relative を $HOME 配下にシンボリックリンクとして作成し、既存ファイルは退避
link_file() {
  local relative="$1"
  local source="$repo_dir/$relative"
  local target="$HOME/$relative"

  if [[ ! -e "$source" && ! -L "$source" ]]; then
    printf 'missing source: %s\n' "$source" >&2
    return 1
  fi

  run mkdir -p "$(dirname "$target")"

  if [[ -L "$target" ]]; then
    # 既存リンクが同一ターゲットなら冪等に何もせず終了
    local current
    current="$(readlink "$target")"
    if [[ "$current" == "$source" ]]; then
      printf 'ok: %s -> %s\n' "$target" "$source"
      return 0
    fi
    run rm "$target"
  elif [[ -e "$target" ]]; then
    # 実体ファイルがある場合のみバックアップへ退避
    local backup
    backup="$(backup_path "$target")"
    run mkdir -p "$(dirname "$backup")"
    run mv "$target" "$backup"
    backup_created=1
  fi

  run ln -s "$source" "$target"
  if (( dry_run )); then
    printf 'would link: %s -> %s\n' "$target" "$source"
  else
    printf 'linked: %s -> %s\n' "$target" "$source"
  fi
}


# ============================================================================
# エントリポイント
# ============================================================================

main() {
  # 簡易引数解析、サポートは --dry-run / --help のみ
  case "${1:-}" in
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      return 0
      ;;
  esac

  if (($#)); then
    usage >&2
    return 2
  fi

  # 管理対象ファイル一覧、リポジトリ相対パスと $HOME 相対パスは同一
  local files=(
    ".bash_profile"
    ".bashrc"
    ".zshenv"
    ".zshrc"
    ".wezterm.lua"
    ".config/agents/AGENTS.md"
    ".config/karabiner/karabiner.json"
    ".config/starship.toml"
    ".codex/AGENTS.md"
    ".codex/config.toml"
    ".claude/CLAUDE.md"
    ".claude/settings.json"
    ".claude/hooks/inject-guidelines-context.sh"
    ".claude/hooks/pre-bash-guard.sh"
    ".zsh/functions/aws.zsh"
    ".zsh/functions/git-worktree.zsh"
  )

  local file
  for file in "${files[@]}"; do
    link_file "$file"
  done

  # 実バックアップが発生した場合のみ世代整理
  if (( dry_run )); then
    printf 'dry run complete\n'
  elif [[ -d "$backup_dir" ]]; then
    printf 'backups: %s\n' "$backup_dir"
    if (( backup_created )); then
      prune_backups
      printf 'kept latest %d backup generations\n' "$backup_keep"
    fi
  fi
}

main "$@"
