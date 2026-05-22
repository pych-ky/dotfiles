#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backup_dir="${HOME}/.dotfiles-backup/$(date +%Y%m%d%H%M%S)"
dry_run=0
backup_created=0
backup_keep=5

usage() {
  cat <<'EOF'
Usage: ./install.sh [--dry-run]

Create symlinks from this repository into $HOME.
Existing regular files are moved to ~/.dotfiles-backup/<timestamp>/ first.
EOF
}

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

backup_path() {
  local target="$1"
  local relative="${target#"$HOME"/}"

  printf '%s/%s' "$backup_dir" "$relative"
}

prune_backups() {
  local root="$HOME/.dotfiles-backup"
  [[ -d "$root" ]] || return 0

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
    local current
    current="$(readlink "$target")"
    if [[ "$current" == "$source" ]]; then
      printf 'ok: %s -> %s\n' "$target" "$source"
      return 0
    fi
    run rm "$target"
  elif [[ -e "$target" ]]; then
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

main() {
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
