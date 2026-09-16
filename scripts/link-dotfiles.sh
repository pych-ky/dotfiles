#!/usr/bin/env bash
# dotfiles を $HOME 配下へリンク・コピーし、既存の実体は退避

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_root=
backup_dir=
backup_target=
backup_compare_target= # dry-run では退避元、通常は退避先
dry_run=0
backup_created=0
backup_keep=5
backup_diffs=()    # リポジトリ版と異なる退避元
managed_targets=() # ツールの自動追記がある退避元
MANAGED_BLOCK_MARKER='MANAGED BY RANCHER DESKTOP'

setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' \
    "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

usage() {
  cat <<'EOF'
Usage: ./scripts/link-dotfiles.sh [--dry-run] [-h | --help]

Create symlinks from this repository into $HOME.
Claude settings are copied, preserving user plugin and marketplace entries.
The Codex Browser config is copied as a regular file because Codex rejects symlinks for this path.
Existing regular files and directories are moved to ~/.dotfiles-backup/<timestamp>[-<sequence>]/ first.

Options:
  --dry-run   Show actions without changing files.
  -h, --help  Show this help and exit.
EOF
}

validate_environment() {
  if ((EUID == 0)); then
    printf 'error: do not run scripts/link-dotfiles.sh with sudo or as root\n' >&2
    return 1
  fi

  setup_validate_home
}

run() {
  if ((dry_run)); then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

report_link() {
  local verb='linked'
  ((dry_run)) && verb='would link'
  printf '%s: %s -> %s\n' "$verb" "$1" "$2"
}

# ツールの書き込みをリポジトリから分離するためコピー
copy_regular_file() {
  local source_relative="$1"
  local target_relative="${2:-$1}"
  local source="$repo_dir/$source_relative"
  local target="$HOME/$target_relative"

  if [[ ! -f "$source" || -L "$source" ]]; then
    printf 'missing regular source: %s\n' "$source" >&2
    return 1
  fi

  if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$source" "$target"; then
    printf 'ok: %s (regular copy of %s)\n' "$target" "$source"
    return 0
  fi

  run mkdir -p "$(dirname "$target")" || return
  backup_existing_target "$target" || return
  if [[ -e "$backup_compare_target" ]] &&
    ! cmp -s "$backup_compare_target" "$source"; then
    backup_diffs+=("$target (backup: $backup_target)")
  fi

  run cp -p "$source" "$target" || return
  if ((dry_run)); then
    printf 'would copy: %s <- %s\n' "$target" "$source"
  else
    printf 'copied: %s <- %s\n' "$target" "$source"
  fi
}

# Claude の公開設定を優先し、個人のプラグイン登録を保持
install_claude_settings() {
  local source_relative='.claude/settings.json'
  local source="$repo_dir/$source_relative"
  local target="$HOME/$source_relative"
  local merged_settings

  if [[ ! -f "$source" || -L "$source" || ! -f "$target" ]] ||
    cmp -s "$source" "$target"; then
    copy_regular_file "$source_relative"
    return
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf 'error: jq is required to preserve Claude plugin settings; install jq and rerun\n' >&2
    return 1
  fi
  merged_settings="$(
    jq -s '
      .[0] as $base | .[1] as $current |
      reduce ["enabledPlugins", "extraKnownMarketplaces"][] as $key ($base;
        if $current | has($key) then
          .[$key] = (($current[$key] // {}) + ($base[$key] // {}))
        else
          .
        end
      )
    ' "$source" "$target"
  )" || return
  if [[ ! -L "$target" ]] &&
    cmp -s "$target" <(printf '%s\n' "$merged_settings"); then
    printf 'ok: %s (user plugin settings preserved)\n' "$target"
    return 0
  fi

  run mkdir -p "$(dirname "$target")" || return
  # マージ済みなのでリポジトリ版との差異は記録しない
  backup_existing_target "$target" || return

  if ((dry_run)); then
    printf 'would copy: %s <- %s\n' "$target" "$source"
  else
    printf '%s\n' "$merged_settings" >"$target" || return
    chmod 600 "$target" || return
    printf 'copied: %s <- %s\n' "$target" "$source"
  fi
}

backup_path() {
  printf '%s/%s' "$backup_dir" "${1#"$HOME"/}"
}

# 同秒の再実行でも衝突しない退避先を確保
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

# 実体は退避、シンボリックリンクは削除
backup_existing_target() {
  local target="$1"

  backup_target=
  backup_compare_target=

  if [[ -L "$target" ]]; then
    run rm "$target"
    return
  fi
  [[ -e "$target" ]] || return 0

  ensure_backup_dir || return
  backup_target="$(backup_path "$target")"
  run mkdir -p "$(dirname "$backup_target")" || return
  run mv -n "$target" "$backup_target" || return
  if ((!dry_run)) && [[ -e "$target" || -L "$target" ]]; then
    printf 'error: backup destination already exists: %s\n' "$backup_target" >&2
    return 1
  fi
  backup_created=1

  if ((dry_run)); then
    backup_compare_target="$target"
  else
    backup_compare_target="$backup_target"
  fi
}

prune_backups() {
  local candidate
  local name
  [[ -d "$backup_root" ]] || return 0

  # 14 桁名とマーカー付き連番名だけを削除候補にする
  {
    while IFS= read -r candidate; do
      name="${candidate##*/}"
      if [[ "$name" =~ ^[0-9]{14}$ ]] ||
        { [[ "$name" =~ ^[0-9]{14}-[0-9]{6}$ ]] &&
          [[ -f "$candidate/.dotfiles-backup-generation" ]]; }; then
        printf '%s\n' "$candidate"
      fi
    done < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -print)
    # dry-run でも未作成の今回分を世代数に含める
    if ((dry_run && backup_created)) &&
      [[ "${backup_dir%/*}" == "$backup_root" ]] &&
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

is_correct_symlink() {
  [[ -L "$1" && "$(readlink "$1")" == "$2" ]]
}

# 自リポジトリ由来の廃止リンクだけを削除
remove_obsolete_symlink() {
  local source_relative="$1"
  local target_relative="${2:-$1}"
  local source="$repo_dir/$source_relative"
  local target="$HOME/$target_relative"

  is_correct_symlink "$target" "$source" || return 0
  run rm "$target"
}

link_file() {
  local source_relative="$1"
  local target_relative="${2:-$1}"
  local source="$repo_dir/$source_relative"
  local target="$HOME/$target_relative"

  # 壊れたリンクも source として扱う
  if [[ ! -e "$source" && ! -L "$source" ]]; then
    printf 'missing source: %s\n' "$source" >&2
    return 1
  fi

  if is_correct_symlink "$target" "$source"; then
    printf 'ok: %s -> %s\n' "$target" "$source"
    return 0
  fi

  run mkdir -p "$(dirname "$target")" || return

  backup_existing_target "$target" || return
  if [[ -e "$backup_compare_target" && -e "$source" ]] &&
    ! diff -rq "$backup_compare_target" "$source" >/dev/null 2>&1; then
    backup_diffs+=("$target (backup: $backup_target)")
  fi

  if [[ -f "$backup_compare_target" ]] &&
    grep -qF "$MANAGED_BLOCK_MARKER" "$backup_compare_target" 2>/dev/null; then
    managed_targets+=("$target")
  fi

  # -h でディレクトリリンク配下への誤作成を防ぐ
  run ln -sh "$source" "$target" || return
  report_link "$target" "$source"
}

warn_legacy_codex_managed_config() {
  local target="/etc/codex/managed_config.toml"

  [[ -e "$target" || -L "$target" ]] || return 0

  printf 'warning: %s exists and has higher precedence than /etc/codex/config.toml\n' "$target" >&2
  printf '         remove it if you want Codex App local config to override dotfiles defaults\n' >&2
}

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

  # /etc の既存ファイルは退避せず、競合時は中断
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

main() {
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
  backup_root="$HOME/.dotfiles-backup"
  if ((!dry_run)); then
    mkdir -p "$backup_root" || return
    process_lock_acquire \
      "$backup_root/.link-dotfiles.lock" \
      'dotfiles link' \
      30 || return
    trap 'process_lock_release' EXIT
  fi

  local files=(
    # shell
    ".bash_profile"
    ".bashrc"
    ".zshenv"
    ".zshrc"
    ".shell/functions/aws.sh"
    ".shell/functions/git-worktree.sh"
    ".shell/functions/ghq.sh"
    # terminal
    ".wezterm.lua"
    ".config/starship.toml"
    ".config/git/ignore"
    ".config/gh/config.yml"
    # Karabiner の変更検知のためディレクトリごとリンク
    ".config/karabiner"
    ".config/mise/config.toml"
    # AI エージェント
    ".config/agents/AGENTS.md"
    ".claude/CLAUDE.md"
    ".claude/hooks/pre-bash-guard.py"
    ".claude/hooks/pre-bash-guard.sh"
    ".claude/hooks/statusline.sh"
    ".aws/load-active-profile.sh"
  )

  local file
  local failed_items=()

  for file in \
    .zsh/functions/git-worktree.zsh \
    .claude/hooks/inject-guidelines-context.sh \
    .claude/keybindings.json; do
    if ! remove_obsolete_symlink "$file"; then
      failed_items+=("$file (obsolete symlink)")
    fi
  done

  if ! remove_obsolete_symlink ".config/codex/rules/authenticated-cli.rules" ".codex/rules/authenticated-cli.rules"; then
    failed_items+=(".codex/rules/authenticated-cli.rules (obsolete symlink)")
  fi

  for file in "${files[@]}"; do
    if ! link_file "$file"; then
      failed_items+=("$file")
    fi
  done

  if ! install_claude_settings; then
    failed_items+=(".claude/settings.json")
  fi

  if ! copy_regular_file ".codex/browser/config.toml"; then
    failed_items+=(".codex/browser/config.toml")
  fi

  if ! link_file ".config/agents/AGENTS.md" ".codex/AGENTS.md"; then
    failed_items+=(".codex/AGENTS.md")
  fi

  warn_legacy_codex_managed_config
  if ! link_codex_system_config; then
    failed_items+=("/etc/codex/config.toml")
  fi

  if ((dry_run)); then
    if ((backup_created)); then
      prune_backups
    fi
    printf 'dry run complete\n'
  elif [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
    printf 'backups: %s\n' "$backup_dir"
    if ((backup_created)); then
      prune_backups
      printf 'kept latest %d backup generations\n' "$backup_keep"
    fi
  fi

  if ((${#backup_diffs[@]} > 0)); then
    printf 'warning: replaced files differed from the repository version:\n' >&2
    printf '  %s\n' "${backup_diffs[@]}" >&2
    printf '         merge local changes into the repository or ~/.zshrc.local, then relink\n' >&2
  fi

  if ((${#managed_targets[@]} > 0)); then
    printf 'warning: these files contain a tool-managed block (%s):\n' \
      "$MANAGED_BLOCK_MARKER" >&2
    printf '  %s\n' "${managed_targets[@]}" >&2
    printf '         after linking, the tool would write into the repository itself\n' >&2
    printf '         switch the tool to manual PATH management before relinking\n' >&2
  fi

  if ((${#failed_items[@]} > 0)); then
    printf 'failed items:\n' >&2
    printf '  %s\n' "${failed_items[@]}" >&2
    return 1
  fi

  if ((!dry_run)); then
    printf 'restart Codex to load updated hooks and permissions\n'
    printf 'in Codex App, select "保護付きフルアクセス" and start a new task to apply the configured approval policy\n'
    printf 'the built-in "Full access" mode overrides config.toml with approval_policy=never\n'
  fi
}

main "$@"
