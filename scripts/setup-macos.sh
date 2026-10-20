#!/usr/bin/env bash
# macOS 独自設定の反映

set -euo pipefail

if ((EUID == 0)); then
  printf 'error: do not run scripts/setup-macos.sh with sudo or as root\n' >&2
  exit 1
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'error: scripts/setup-macos.sh supports macOS only\n' >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rectangle_shutdown_max_attempts=50
rectangle_shutdown_interval=0.2

rectangle_restart_pending=0

# Rectangle の終了を待機
wait_for_rectangle_exit() {
  local attempts=0

  while pgrep -xq Rectangle; do
    if ((attempts >= rectangle_shutdown_max_attempts)); then
      printf 'error: timed out waiting for Rectangle to exit\n' >&2
      return 1
    fi

    sleep "$rectangle_shutdown_interval"
    attempts=$((attempts + 1))
  done
}

# 終了させた Rectangle を再起動
restart_rectangle() {
  ((rectangle_restart_pending)) || return 0
  rectangle_restart_pending=0
  open -a Rectangle
}

# 終了コードを保って Rectangle を復帰
restore_rectangle_on_exit() {
  local status="$1"
  local restart_status

  trap - EXIT
  if restart_rectangle; then
    :
  else
    restart_status=$?
    printf 'warning: failed to restart Rectangle\n' >&2
    if ((status == 0)); then
      status="$restart_status"
    fi
  fi

  exit "$status"
}

# plist の他項目を保ってデスクトップの配置を変更
set_desktop_arrangement() {
  local value="$1"
  local keypath
  local plist

  plist="$(defaults export com.apple.finder -)"

  for keypath in DesktopViewSettings DesktopViewSettings.IconViewSettings; do
    if ! printf '%s' "$plist" |
      plutil -extract "$keypath" xml1 -o /dev/null -- - >/dev/null 2>&1; then
      plist="$(printf '%s' "$plist" | plutil -insert "$keypath" -json '{}' -o - -- -)"
    fi
  done

  plist="$(
    printf '%s' "$plist" |
      plutil -replace DesktopViewSettings.IconViewSettings.arrangeBy \
        -string "$value" -o - -- -
  )"

  printf '%s' "$plist" | defaults import com.apple.finder -
}

## キーボード

# キーリピートは最速・最短
defaults write NSGlobalDomain InitialKeyRepeat -int 15
defaults write NSGlobalDomain KeyRepeat -int 2

# F1 等を標準ファンクションキーに
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true

# VS Code の ⌘+[ と競合する「次のウインドウを操作対象にする」を無効化
symbolic_hotkey="$(
  defaults export com.apple.symbolichotkeys - 2>/dev/null |
    plutil -extract AppleSymbolicHotKeys.27 xml1 -o - -- - 2>/dev/null
)" || symbolic_hotkey='<dict/>'
symbolic_hotkey="$(
  printf '%s' "$symbolic_hotkey" |
    plutil -replace enabled -bool false -o - -- -
)"
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys \
  -dict-add 27 "$symbolic_hotkey"

defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticInlinePredictionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

## 日本語入力

defaults write com.apple.inputmethod.Kotoeri JIMPrefAutocorrectionKey -bool false
defaults write com.apple.inputmethod.Kotoeri JIMPrefConvertWithPunctuationKey -bool false
defaults write com.apple.inputmethod.Kotoeri JIMPrefFullWidthNumeralCharactersKey -bool false
defaults write com.apple.inputmethod.Kotoeri JIMPrefLiveConversionKey -bool false
defaults write com.apple.inputmethod.Kotoeri JIMPrefPredictiveCandidateKey -bool false

## マウス / トラックパッド

defaults write NSGlobalDomain com.apple.mouse.scaling -float 3
defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false

## 外観

defaults write NSGlobalDomain AppleInterfaceStyle -string Dark
defaults write NSGlobalDomain AppleShowScrollBars -string Always

## Dock / Mission Control

# 使用履歴で操作スペースを並べ替えない
defaults write com.apple.dock mru-spaces -bool false
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock tilesize -int 72

## Finder

defaults write com.apple.finder AppleShowAllFiles -bool true

defaults write NSGlobalDomain AppleShowAllExtensions -bool true

defaults write com.apple.finder ShowPathbar -bool true

# Nlsv はリスト表示
defaults write com.apple.finder FXPreferredViewStyle -string Nlsv

set_desktop_arrangement grid

## メニューバー / コントロールセンター

defaults write com.apple.controlcenter "NSStatusItem Visible Sound" -bool true

## Maccy

defaults write org.p0deje.Maccy historySize -int 999

## Rectangle

# 終了時の旧設定書き戻しと import の競合を防ぐ
if pgrep -xq Rectangle; then
  rectangle_restart_pending=1
  trap 'restore_rectangle_on_exit "$?"' EXIT
  killall Rectangle 2>/dev/null || true
  wait_for_rectangle_exit
fi

defaults import com.knollsoft.Rectangle "$repo_dir/macos/rectangle.plist"

## 電源管理

sudo -n pmset -c sleep 0 2>/dev/null || printf 'warning: skipped pmset sleep setting\n' >&2

killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true
killall ControlCenter 2>/dev/null || true

restart_rectangle
trap - EXIT

if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
  printf 'ok: macOS settings applied\n'
  printf 'info: some settings take effect after re-login\n'
fi
