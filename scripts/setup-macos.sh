#!/usr/bin/env bash
# macOS 独自設定の反映

# 再実行可（一部は再ログイン後に反映）

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

# Rectangle の終了を最大 10 秒待機
rectangle_shutdown_max_attempts=50
rectangle_shutdown_interval=0.2

rectangle_restart_pending=0

# Rectangle の終了を待ち、時間切れならエラー
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

# 終了時に Rectangle を再起動し、終了コードを引き継いで終了
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

# defaults write は辞書を置換するため、既存 plist の並べ方だけを変更
set_desktop_arrangement() {
  local value="$1"
  local keypath
  local plist

  plist="$(defaults export com.apple.finder -)"

  # 表示設定の未保存端末には入れ子の辞書が無い
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

# キーリピートを最速、開始待ちを最短に
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15

# F1、F2 などを標準のファンクションキーに
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true

defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

defaults write NSGlobalDomain NSAutomaticInlinePredictionEnabled -bool false

## 日本語入力

# 再ログイン後に反映
defaults write com.apple.inputmethod.Kotoeri JIMPrefLiveConversionKey -bool false
defaults write com.apple.inputmethod.Kotoeri JIMPrefPredictiveCandidateKey -bool false
defaults write com.apple.inputmethod.Kotoeri JIMPrefAutocorrectionKey -bool false
defaults write com.apple.inputmethod.Kotoeri JIMPrefConvertWithPunctuationKey -bool false

## マウス / トラックパッド

# ナチュラルスクロールを無効化
defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false

# マウスの軌跡の速さ
defaults write NSGlobalDomain com.apple.mouse.scaling -float 3

## 外観

# 再ログイン後に完全反映
defaults write NSGlobalDomain AppleInterfaceStyle -string Dark
defaults write NSGlobalDomain AppleShowScrollBars -string Always

## Dock / Mission Control

defaults write com.apple.dock tilesize -int 72

defaults write com.apple.dock show-recents -bool false

# 使用状況による操作スペースの自動並べ替えを無効化
defaults write com.apple.dock mru-spaces -bool false

## Finder

defaults write com.apple.finder AppleShowAllFiles -bool true

defaults write NSGlobalDomain AppleShowAllExtensions -bool true

defaults write com.apple.finder ShowPathbar -bool true

# デフォルトをリスト表示に
defaults write com.apple.finder FXPreferredViewStyle -string Nlsv

set_desktop_arrangement grid

## メニューバー / コントロールセンター

defaults write com.apple.controlcenter "NSStatusItem Visible Sound" -bool true

## Rectangle (ウィンドウ管理)

# 終了時の旧設定書き戻しと import の競合を防ぐ
if pgrep -xq Rectangle; then
  rectangle_restart_pending=1
  trap 'restore_rectangle_on_exit "$?"' EXIT
  killall Rectangle 2>/dev/null || true
  wait_for_rectangle_exit
fi

# 保存済みのショートカット・スナップ設定を取り込み
defaults import com.knollsoft.Rectangle "$repo_dir/macos/rectangle.plist"

## 電源管理

# 電源接続時の自動スリープを無効化
sudo -n pmset -c sleep 0 2>/dev/null || printf 'warning: skipped pmset sleep setting\n' >&2

## 設定の反映

killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true
killall ControlCenter 2>/dev/null || true

restart_rectangle
trap - EXIT

if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
  printf 'ok: macOS settings applied\n'
  printf 'info: some settings take effect after re-login\n'
fi
