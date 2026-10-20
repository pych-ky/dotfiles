#!/usr/bin/env bash
# dotfiles の配置・退避

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_root=
backup_dir=
backup_target=
backup_compare_target=  # dry-run では退避元、通常は退避先
dry_run=0
backup_created=0
backup_keep=5
backup_diffs=()
managed_targets=()
MANAGED_BLOCK_MARKER='MANAGED BY RANCHER DESKTOP'

setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' \
    "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

# 使い方を表示
usage() {
  cat <<'EOF'
使い方: ./scripts/link-dotfiles.sh [--dry-run] [-h | --help]

$HOME 配下へリンクし、既存の実体は ~/.dotfiles-backup/<timestamp>[-<sequence>]/ へ退避。
コピー: Codex Browser 設定、CLI・Orca プロファイル、Orca キー設定、Computer Use 常時許可一覧

sudo が必要な設定:
  Codex: /etc/codex/config.toml へリンク（既存ファイル・別リンクとは競合）
  Claude: /Library/Application Support/ClaudeCode/managed-settings.json へコピー
Claude managed 設定は dotfiles 設置分のみ更新し、外部変更は保持。
~/.claude/settings.json は Playwright の Edge 接続先だけ更新。
コピーの理由・設定の使い分けは README.md を参照。

オプション:
  --dry-run   変更せず実行内容を表示
  -h, --help  ヘルプを表示して終了
EOF
}

# root 実行を拒否・HOME を検証
validate_environment() {
  if ((EUID == 0)); then
    printf 'error: do not run scripts/link-dotfiles.sh with sudo or as root\n' >&2
    return 1
  fi

  setup_validate_home
}

# コマンドを実行（dry-run は表示のみ）
run() {
  if ((dry_run)); then
    printf 'info: would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# 作成したリンクを表示
report_link() {
  ((dry_run)) && return 0
  printf 'changed: linked %s -> %s\n' "$1" "$2"
}

# 退避してリンク・コピーし、差分を記録
install_file() {
  local mode="$1" source_relative="$2" target_relative="${3:-$2}"
  local source="$repo_dir/$source_relative" target="$HOME/$target_relative"
  local different=0

  if [[ "$mode" == copy ]]; then
    if [[ ! -f "$source" || -L "$source" ]]; then
      printf 'error: missing regular source: %s\n' "$source" >&2
      return 1
    fi
    if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$source" "$target"; then
      return 0
    fi
  else
    if [[ ! -e "$source" && ! -L "$source" ]]; then
      printf 'error: missing source: %s\n' "$source" >&2
      return 1
    fi
    is_correct_symlink "$target" "$source" && return 0
  fi

  run mkdir -p "$(dirname "$target")" || return
  backup_existing_target "$target" || return
  if [[ -e "$backup_compare_target" ]]; then
    if [[ "$mode" == copy ]]; then
      cmp -s "$backup_compare_target" "$source" || different=1
    elif [[ -e "$source" ]]; then
      diff -rq "$backup_compare_target" "$source" >/dev/null 2>&1 || different=1
    fi
  fi
  if ((different)); then
    if ((dry_run)); then
      backup_diffs+=("$target (planned backup: $backup_target)")
    else
      backup_diffs+=("$target (backup: $backup_target)")
    fi
  fi

  if [[ "$mode" == copy ]]; then
    run cp -p "$source" "$target" || return
    if ((!dry_run)); then
      printf 'changed: copied %s <- %s\n' "$target" "$source"
    fi
  else
    if [[ -f "$backup_compare_target" ]] &&
      grep -qF "$MANAGED_BLOCK_MARKER" "$backup_compare_target" 2>/dev/null; then
      managed_targets+=("$target")
    fi
    # -h でディレクトリリンク内への作成を防ぐ
    run ln -sh "$source" "$target" || return
    report_link "$target" "$source"
  fi
}

# 同秒でも衝突しない退避先を確保
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
  backup_target="$backup_dir/${target#"$HOME"/}"
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

# 保持世代を超えた退避先を削除
prune_backups() {
  local candidate
  local name
  [[ -d "$backup_root" ]] || return 0

  {
    while IFS= read -r candidate; do
      name="${candidate##*/}"
      if [[ "$name" =~ ^[0-9]{14}$ ]] ||
        { [[ "$name" =~ ^[0-9]{14}-[0-9]{6}$ ]] &&
          [[ -f "$candidate/.dotfiles-backup-generation" ]]; }; then
        printf '%s\n' "$candidate"
      fi
    done < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -print)
    # dry-run でも今回分を世代数に含める
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

# 指定先へのリンクか判定
is_correct_symlink() {
  [[ -L "$1" && "$(readlink "$1")" == "$2" ]]
}

# 自リポジトリの廃止リンクを削除
remove_obsolete_symlink() {
  local source_relative="$1"
  local target_relative="${2:-$1}"
  local source="$repo_dir/$source_relative"
  local target="$HOME/$target_relative"

  is_correct_symlink "$target" "$source" || return 0
  run rm "$target" || return
  if ((!dry_run)); then
    printf 'changed: removed obsolete link: %s\n' "$target"
  fi
}

# 優先される旧 managed_config.toml を警告
warn_legacy_codex_managed_config() {
  local target="/etc/codex/managed_config.toml"

  [[ -e "$target" || -L "$target" ]] || return 0

  printf 'warning: %s exists and has higher precedence than /etc/codex/config.toml\n' "$target" >&2
  printf '         remove it if you want Codex App local config to override dotfiles defaults\n' >&2
}

# Codex の基本設定を /etc/codex/config.toml へリンク
link_codex_system_config() {
  local source="$repo_dir/etc/codex/config.toml"
  local target="/etc/codex/config.toml"

  if [[ ! -e "$source" ]]; then
    printf 'error: missing source: %s\n' "$source" >&2
    return 1
  fi

  if is_correct_symlink "$target" "$source"; then
    return 0
  fi

  if [[ -L "$target" ]]; then
    printf 'error: existing symlink is different: %s -> %s\n' "$target" "$(readlink "$target")" >&2
    return 1
  elif [[ -e "$target" ]]; then
    printf 'error: existing file: %s\n' "$target" >&2
    printf '       move or remove it before installing the Codex base config symlink\n' >&2
    return 1
  fi

  run sudo mkdir -p "$(dirname "$target")" || return
  run sudo ln -s "$source" "$target" || return
  report_link "$target" "$source"
}

# Claude の Playwright 接続先を Edge に設定
configure_claude_browser() {
  local source="$repo_dir/etc/claude-code/settings.json"
  local user_settings="$HOME/.claude/settings.json"
  local endpoint input_file="$user_settings" temporary_settings physical_repo_dir
  endpoint="$(jq -er '.env.PLAYWRIGHT_MCP_CDP_ENDPOINT' "$source")" || return

  if [[ -L "$user_settings" && (-f "$user_settings" || ! -e "$user_settings") ]]; then
    physical_repo_dir="$(cd "$repo_dir" && pwd -P)" || return
    case "$(readlink -f "$user_settings" 2>/dev/null)" in
    "$physical_repo_dir"/*)
      input_file=/dev/null
      if ((dry_run)); then
        printf 'info: would replace obsolete link with Playwright Edge settings: %s\n' "$user_settings"
        return 0
      fi
      ;;
    esac
  fi

  if [[ "$input_file" != /dev/null &&
    (-L "$user_settings" || (-e "$user_settings" && ! -f "$user_settings")) ]]; then
    printf 'error: Claude user settings must be a regular file: %s\n' "$user_settings" >&2
    return 1
  fi
  if [[ -f "$input_file" ]]; then
    if ! jq -se 'length == 1 and (.[0] | type == "object" and
      ((has("env") | not) or (.env | type == "object")))' "$input_file" >/dev/null; then
      printf 'error: Claude user settings must contain one JSON object with an optional env object: %s\n' "$user_settings" >&2
      return 1
    fi
    if jq -e --arg endpoint "$endpoint" \
      '.env.PLAYWRIGHT_MCP_CDP_ENDPOINT == $endpoint' "$input_file" >/dev/null; then
      return 0
    fi
  fi
  if ((dry_run)); then
    printf 'info: would configure Playwright Edge connection: %s\n' "$user_settings"
    return 0
  fi

  mkdir -p "$(dirname "$user_settings")" || return
  [[ -f "$input_file" ]] || input_file=/dev/null
  temporary_settings="$(mktemp "$user_settings.XXXXXX")" || return
  if ! jq -s --arg endpoint "$endpoint" \
    '(if length == 0 then {} else .[0] end) | .env.PLAYWRIGHT_MCP_CDP_ENDPOINT = $endpoint' \
    "$input_file" >"$temporary_settings"; then
    rm -f -- "$temporary_settings"
    return 1
  fi
  if ! mv -- "$temporary_settings" "$user_settings"; then
    rm -f -- "$temporary_settings"
    return 1
  fi
  printf 'changed: configured Playwright Edge connection: %s\n' "$user_settings"
}

# dotfiles 由来の managed 設定だけ更新
install_claude_managed_config() {
  local source="$repo_dir/etc/claude-code/settings.json"
  local target="/Library/Application Support/ClaudeCode/managed-settings.json"
  local hash_record="$backup_root/.claude-managed-settings.sha256"
  local source_hash target_hash

  if [[ ! -f "$source" || -L "$source" ]] || ! command -v jq >/dev/null 2>&1; then
    printf 'error: Claude managed settings and jq are required\n' >&2
    return 1
  fi
  jq -e 'type == "object"' "$source" >/dev/null || return
  source_hash="$(shasum -a 256 "$source" | awk '{print $1}')" || return

  if [[ -L "$target" ]]; then
    if ! is_correct_symlink "$target" "$source" &&
      ! is_correct_symlink "$target" "$repo_dir/etc/claude-code/managed-settings.json"; then
      printf 'skipped: Claude managed settings symlink was not installed by dotfiles: %s\n' "$target"
      return 0
    fi
  elif [[ -e "$target" ]]; then
    if [[ ! -f "$target" || ! -f "$hash_record" || -L "$hash_record" ]] ||
      ! target_hash="$(shasum -a 256 "$target" | awk '{print $1}')" ||
      [[ "$target_hash" != "$(cat "$hash_record")" ]]; then
      printf 'skipped: Claude managed settings were not installed by dotfiles or have changed: %s\n' "$target"
      return 0
    fi
    [[ "$source_hash" != "$target_hash" ]] || return 0
  fi

  if [[ -L "$hash_record" || (-e "$hash_record" && ! -f "$hash_record") ]]; then
    printf 'error: Claude managed settings hash record must be a regular file: %s\n' "$hash_record" >&2
    return 1
  fi
  run sudo mkdir -p "$(dirname "$target")" || return
  if [[ -L "$target" ]]; then
    run sudo rm "$target" || return
  fi
  run sudo install -m 0644 "$source" "$target" || return
  if ((dry_run)); then
    printf 'info: would record Claude managed settings SHA-256: %s\n' "$hash_record"
  else
    printf '%s\n' "$source_hash" >"$hash_record" || return
    printf 'changed: copied %s <- %s\n' "$target" "$source"
  fi
}

# dotfiles を配置・退避
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
    ## シェル

    ".aws/load-active-profile.sh"
    ".bash_profile"
    ".bashrc"
    ".shell/functions/aws.sh"
    ".shell/functions/claude.sh"
    ".shell/functions/codex.sh"
    ".shell/functions/ghq.sh"
    ".shell/functions/git-worktree.sh"
    ".zprofile"
    ".zshenv"
    ".zshrc"

    ## ターミナル

    ".config/ghostty/config.ghostty"
    ".config/starship.toml"
    ".wezterm.lua"

    ## 開発ツール

    ".config/gh/config.yml"
    ".config/git/ignore"
    ".config/mise/config.toml"

    ## キー入力

    # Karabiner の変更検知のためディレクトリごとリンク
    ".config/karabiner"

    ## AI エージェント

    ".claude/CLAUDE.md"
    ".claude/hooks/pre-bash-guard.py"
    ".claude/hooks/pre-bash-guard.sh"
    ".claude/hooks/statusline.sh"
    ".config/agents/AGENTS.md"
    ".copilot/settings.json"
    ".copilot/statusline.sh"
  )

  local file
  local failed_items=()

  for file in \
    .claude/hooks/inject-guidelines-context.sh \
    .claude/keybindings.json \
    .zsh/functions/git-worktree.zsh; do
    if ! remove_obsolete_symlink "$file"; then
      failed_items+=("$file (obsolete symlink)")
    fi
  done

  if ! remove_obsolete_symlink ".config/codex/rules/authenticated-cli.rules" ".codex/rules/authenticated-cli.rules"; then
    failed_items+=(".codex/rules/authenticated-cli.rules (obsolete symlink)")
  fi

  for file in "${files[@]}"; do
    if ! install_file link "$file"; then
      failed_items+=("$file")
    fi
  done

  if ! configure_claude_browser; then
    failed_items+=("Claude browser settings")
  fi

  if ! install_claude_managed_config; then
    failed_items+=("Claude managed settings")
  fi

  local computer_use_approvals="Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/Library/Application Support/Software/ComputerUseAppApprovals.json"
  if ! install_file copy "macos/computer-use-app-approvals.json" "$computer_use_approvals"; then
    failed_items+=("$computer_use_approvals")
  fi

  for file in .codex/browser/config.toml .codex/cli.config.toml .codex/orca.config.toml; do
    if ! install_file copy "$file"; then
      failed_items+=("$file")
    fi
  done

  if [[ "$(uname -s)" == Darwin ]]; then
    local orca_codex_profile="Library/Application Support/orca/codex-runtime-home/home/orca.config.toml"
    if ! install_file copy ".codex/orca.config.toml" "$orca_codex_profile"; then
      failed_items+=("$orca_codex_profile")
    fi
  fi

  if ! install_file copy ".orca/keybindings.json"; then
    failed_items+=(".orca/keybindings.json")
  fi

  if ! install_file link ".config/agents/AGENTS.md" ".codex/AGENTS.md"; then
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
  elif [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
    printf 'info: backup directory: %s\n' "$backup_dir"
    if ((backup_created)); then
      prune_backups
      printf 'info: backup retention: up to %d generations\n' "$backup_keep"
    fi
  fi

  if ((${#backup_diffs[@]} > 0)); then
    if ((dry_run)); then
      printf 'warning: files to replace differ from the repository version:\n' >&2
    else
      printf 'warning: replaced files differed from the repository version:\n' >&2
    fi
    printf '  %s\n' "${backup_diffs[@]}" >&2
    printf '         review the differences and merge intended changes into the corresponding repository files\n' >&2
  fi

  if ((${#managed_targets[@]} > 0)); then
    printf 'warning: these files contain a tool-managed block (%s):\n' \
      "$MANAGED_BLOCK_MARKER" >&2
    printf '  %s\n' "${managed_targets[@]}" >&2
    printf '         after linking, the tool would write into the repository itself\n' >&2
    printf '         switch the tool to manual PATH management before relinking\n' >&2
  fi

  if ((${#failed_items[@]} > 0)); then
    printf 'error: dotfiles setup failed for:\n' >&2
    printf '  %s\n' "${failed_items[@]}" >&2
    return 1
  fi

  if ((dry_run)); then
    printf 'ok: Dotfiles (dry-run; no files changed)\n'
  elif [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
    printf 'ok: Dotfiles\n'
    printf 'info: restart Codex to apply configuration changes; see README.md > Codex の設定\n'
  fi
}

main "$@"
