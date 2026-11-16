#!/usr/bin/env bash
# dotfiles の配置・退避

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_root="$HOME/.dotfiles-backup"
backup_dir="$backup_root/$(date +%Y%m%d%H%M%S)"
backup_label=backup
dry_run=0
claude_settings_only=0
backup_diffs=()

# 使い方を表示
usage() {
  cat <<'EOF'
使い方: ./scripts/link-dotfiles.sh [--claude-settings-only] [--dry-run] [-h | --help]

$HOME 配下へリンク・コピーし、置き換える実体は ~/.dotfiles-backup/<timestamp>/ へ退避。

オプション:
  --claude-settings-only  Claude のユーザー設定・managed 設定だけ反映
  --dry-run               変更せず実行内容を表示
  -h, --help              ヘルプを表示して終了
EOF
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

# 指定先へのリンクか判定
is_correct_symlink() {
  [[ -L "$1" && "$(readlink "$1")" == "$2" ]]
}

# 既存の実体を退避してリンク・コピーし、リポジトリ版と異なる退避を記録
install_file() {
  local mode="$1"
  local source="$repo_dir/$2"
  local target="$HOME/${3:-$2}"
  local backup

  if [[ "$mode" == copy ]]; then
    [[ -f "$target" && ! -L "$target" ]] && cmp -s "$source" "$target" && return 0
  else
    is_correct_symlink "$target" "$source" && return 0
  fi

  run mkdir -p "$(dirname "$target")" || return
  if [[ -L "$target" ]]; then
    run rm "$target" || return
  elif [[ -e "$target" ]]; then
    backup="$backup_dir/${target#"$HOME"/}"
    diff -rq "$target" "$source" >/dev/null 2>&1 ||
      backup_diffs+=("$target ($backup_label: $backup)")
    run mkdir -p "$(dirname "$backup")" || return
    run mv "$target" "$backup" || return
  fi

  if [[ "$mode" == copy ]]; then
    run cp -p "$source" "$target" || return
    ((dry_run)) || printf 'changed: copied %s <- %s\n' "$target" "$source"
  else
    run ln -s "$source" "$target" || return
    ((dry_run)) || printf 'changed: linked %s -> %s\n' "$target" "$source"
  fi
}

# Codex の基本設定を /etc/codex/config.toml へリンク
link_codex_system_config() {
  local source="$repo_dir/etc/codex/config.toml"
  local target=/etc/codex/config.toml

  is_correct_symlink "$target" "$source" && return 0
  if [[ -e "$target" || -L "$target" ]]; then
    printf 'error: existing file or symlink: %s\n' "$target" >&2
    printf '       move or remove it before installing the Codex base config symlink\n' >&2
    return 1
  fi

  run sudo mkdir -p "$(dirname "$target")" || return
  run sudo ln -s "$source" "$target" || return
  ((dry_run)) || printf 'changed: linked %s -> %s\n' "$target" "$source"
}

# Claude のユーザー設定へ Playwright MCP の設定を反映
configure_claude_browser() {
  local user_settings="$HOME/.claude/settings.json"
  local input_file="$user_settings"
  local playwright_env
  local temporary_settings

  playwright_env="$(jq -c '.env | with_entries(select(.key | startswith("PLAYWRIGHT_MCP_")))' \
    "$repo_dir/etc/claude-code/settings.json")" || return
  if [[ -f "$user_settings" ]] && jq -e --argjson playwright "$playwright_env" \
    '.env as $env | all($playwright | to_entries[]; $env[.key] == .value)' \
    "$user_settings" >/dev/null; then
    return 0
  fi
  if ((dry_run)); then
    printf 'info: would configure Playwright MCP settings: %s\n' "$user_settings"
    return 0
  fi

  mkdir -p "$(dirname "$user_settings")" || return
  [[ -f "$input_file" ]] || input_file=/dev/null
  temporary_settings="$(mktemp "$user_settings.XXXXXX")" || return
  if ! jq -s --argjson playwright "$playwright_env" '(.[0] // {}) | .env += $playwright' \
    "$input_file" >"$temporary_settings" ||
    ! mv -- "$temporary_settings" "$user_settings"; then
    rm -f -- "$temporary_settings"
    return 1
  fi
  printf 'changed: configured Playwright MCP settings: %s\n' "$user_settings"
}

# dotfiles が配置した後に変更されていない managed 設定だけ更新
install_claude_managed_config() {
  local source="$repo_dir/etc/claude-code/settings.json"
  local target="/Library/Application Support/ClaudeCode/managed-settings.json"
  # 組織配布やほかの変更を上書きしないよう、配置した内容のハッシュを残す
  local hash_record="$backup_root/.claude-managed-settings.sha256"
  local source_hash
  local target_hash

  source_hash="$(shasum -a 256 "$source" | awk '{print $1}')" || return
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -L "$target" ]] ||
      ! target_hash="$(shasum -a 256 "$target" 2>/dev/null | awk '{print $1}')" ||
      [[ "$target_hash" != "$(cat "$hash_record" 2>/dev/null)" ]]; then
      printf 'skipped: Claude managed settings were not installed by dotfiles or have changed: %s\n' "$target"
      return 0
    fi
    [[ "$source_hash" != "$target_hash" ]] || return 0
  fi

  run sudo mkdir -p "$(dirname "$target")" || return
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
      backup_label='planned backup'
      ;;
    --claude-settings-only)
      claude_settings_only=1
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

  # sudo 付きで実行すると HOME に root 所有のファイルができる
  if ((EUID == 0)); then
    printf 'error: do not run scripts/link-dotfiles.sh with sudo or as root\n' >&2
    return 1
  fi
  ((dry_run)) || mkdir -p "$backup_root"

  if ((claude_settings_only)); then
    configure_claude_browser
    install_claude_managed_config
    if ((dry_run)); then
      printf 'ok: Claude Code settings (dry-run; no files changed)\n'
    else
      printf 'ok: Claude Code settings\n'
    fi
    return 0
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
    ".homebrew/brew.env"

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
    ".hermes/hooks/pre-tool-guard.py"
    ".hermes/hooks/pre-tool-guard.sh"
    ".hermes/prefill-messages.json"
  )

  local file
  local failed_items=()

  for file in "${files[@]}"; do
    install_file link "$file" || failed_items+=("$file")
  done
  install_file link ".config/agents/AGENTS.md" ".hermes/SOUL.md" || failed_items+=(".hermes/SOUL.md")

  configure_claude_browser || failed_items+=("Claude browser settings")
  install_claude_managed_config || failed_items+=("Claude managed settings")

  # アプリがリンク先の変更を検知しないためコピー
  local computer_use_approvals="Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/Library/Application Support/Software/ComputerUseAppApprovals.json"
  install_file copy "macos/computer-use-app-approvals.json" "$computer_use_approvals" ||
    failed_items+=("$computer_use_approvals")

  # Browser Use はリンク非対応、CLI・Orca プロファイルはアプリがモデル切替を保存するためコピー
  for file in .codex/browser/config.toml .codex/cli.config.toml .codex/orca.config.toml; do
    install_file copy "$file" || failed_items+=("$file")
  done
  local orca_codex_profile="Library/Application Support/orca/codex-runtime-home/home/orca.config.toml"
  install_file copy ".codex/orca.config.toml" "$orca_codex_profile" || failed_items+=("$orca_codex_profile")

  # アプリの保存でリンクが外れるためコピー
  install_file copy ".orca/keybindings.json" || failed_items+=(".orca/keybindings.json")

  install_file link ".config/agents/AGENTS.md" ".codex/AGENTS.md" || failed_items+=(".codex/AGENTS.md")
  link_codex_system_config || failed_items+=("/etc/codex/config.toml")

  if [[ -d "$backup_dir" ]]; then
    printf 'info: backup directory: %s\n' "$backup_dir"
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
