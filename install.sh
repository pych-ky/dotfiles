#!/usr/bin/env bash
#
# ============================================================================
# dotfiles を $HOME 配下にシンボリックリンク展開するスクリプト
# ============================================================================

set -euo pipefail

# ============================================================================
# グローバル設定
# ============================================================================

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"    # このスクリプトを置いているリポジトリのルート
backup_dir="${HOME}/.dotfiles-backup/$(date +%Y%m%d%H%M%S)" # 今回実行分のバックアップ先
dry_run=0                                                   # 1 のとき実コマンドを実行せず内容のみ表示
backup_created=0                                            # 退避が 1 件以上発生したかを示すフラグ
backup_keep=5                                               # 保持するバックアップ世代数

# 使い方を標準出力に表示
usage() {
  cat <<'EOF'
Usage: ./install.sh [--dry-run] [-h | --help]

Create symlinks from this repository into $HOME.
Existing regular files and directories are moved to ~/.dotfiles-backup/<timestamp>/ first.

Options:
  --dry-run   Show actions without changing files.
  -h, --help  Show this help and exit.
EOF
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

# 古いバックアップを backup_keep 世代だけ残して削除
prune_backups() {
  local root="$HOME/.dotfiles-backup"
  [[ -d "$root" ]] || return 0

  # タイムスタンプ降順に並べ、先頭 backup_keep 件以降を削除対象化
  {
    find "$root" -mindepth 1 -maxdepth 1 -type d -print
    # dry-run では未作成の今回分 backup_dir も削除候補の算出に含める
    if ((dry_run && backup_created)); then
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
    backup="$(backup_path "$target")"
    run mkdir -p "$(dirname "$backup")" || return
    run mv "$target" "$backup" || return
    backup_created=1
  fi

  run ln -s "$source" "$target" || return
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

  # 管理対象ファイル一覧、リポジトリ相対パスと $HOME 相対パスは同一 (順序は挙動に影響なし)
  local files=(
    # shell
    ".bash_profile"
    ".bashrc"
    ".zshenv"
    ".zshrc"
    ".shell/functions/aws.sh"
    ".zsh/functions/git-worktree.zsh"
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
  elif [[ -d "$backup_dir" ]]; then
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
