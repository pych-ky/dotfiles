#!/usr/bin/env bash
#
# ============================================================================
# macOS システム設定のうちデフォルトから変更している項目を適用するスクリプト
# ============================================================================
#
# 現行環境でデフォルト値から意図的に変更していた項目のみを対象とする。
# 冪等なので何度実行してもよい。一部の項目は再ログイン後に反映される。

set -euo pipefail

if ((EUID == 0)); then
  printf 'error: do not run macos/defaults.sh with sudo or as root\n' >&2
  exit 1
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'error: macos/defaults.sh supports macOS only\n' >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ログイン時に開くアプリ (システム設定 > 一般 > ログイン項目と拡張機能)
login_item_apps=(
  /Applications/Rectangle.app
  /Applications/Typeless.app
  /Applications/logioptionsplus.app
)

# Rectangle の終了待機は 0.2 秒間隔で最大 10 秒とする
rectangle_shutdown_max_attempts=50
rectangle_shutdown_interval=0.2
rectangle_restart_pending=0

# Rectangle の終了をタイムアウト付きで待機
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

# import 前に停止した Rectangle を一度だけ再起動
restart_rectangle() {
  ((rectangle_restart_pending)) || return 0
  rectangle_restart_pending=0
  open -a Rectangle
}

# 終了時に Rectangle の稼働状態を復元し、終了コードを保持
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

# デスクトップのアイコンの並べ方を設定
# (DesktopViewSettings は入れ子の辞書で、defaults write では同じ辞書にある
#  アイコンサイズなどの表示設定ごと置き換わるため、現在の設定を書き出して
#  該当キーだけ差し替えてから読み込む)
set_desktop_arrangement() {
  local value="$1"
  local keypath
  local plist

  plist="$(defaults export com.apple.finder -)"

  # デスクトップの表示オプションを保存していない端末には入れ子の辞書が無い
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

# 未登録のアプリだけをログイン項目に追加 (登録済みなら何もしない)
add_login_item() {
  local app_path="$1"

  osascript - "$app_path" <<'APPLESCRIPT'
on run argv
  set targetPath to item 1 of argv
  tell application "System Events"
    set existingPaths to path of every login item
    -- 末尾のスラッシュの有無で取りこぼして二重登録しないよう両方を照合する
    if existingPaths contains targetPath then return
    if existingPaths contains (targetPath & "/") then return
    make new login item at end with properties {path:targetPath, hidden:false}
  end tell
end run
APPLESCRIPT
}

# ============================================================================
# キーボード
# ============================================================================

# キーのリピート速度を最速に、リピート入力認識までの時間を最短に
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15

# F1、F2 などのキーを標準のファンクションキーとして使用
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true

# スペル自動修正・文頭の自動大文字化・スマート引用符/ダッシュ・ピリオド自動挿入を無効化
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

# インライン予測テキストを無効化
defaults write NSGlobalDomain NSAutomaticInlinePredictionEnabled -bool false

# ============================================================================
# 日本語入力 (再ログイン後に反映)
# ============================================================================

# ライブ変換を無効化
defaults write com.apple.inputmethod.Kotoeri JIMPrefLiveConversionKey -bool false

# 推測候補表示を無効化
defaults write com.apple.inputmethod.Kotoeri JIMPrefPredictiveCandidateKey -bool false

# 入力中の自動修正を無効化
defaults write com.apple.inputmethod.Kotoeri JIMPrefAutocorrectionKey -bool false

# 句読点で変換を無効化
defaults write com.apple.inputmethod.Kotoeri JIMPrefConvertWithPunctuationKey -bool false

# ============================================================================
# マウス / トラックパッド
# ============================================================================

# ナチュラルスクロールを無効化
defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false

# マウスの軌跡の速さ (好みに応じて調整)
defaults write NSGlobalDomain com.apple.mouse.scaling -float 3

# ============================================================================
# 外観 (再ログイン後に完全反映)
# ============================================================================

# ダークモード
defaults write NSGlobalDomain AppleInterfaceStyle -string Dark

# ============================================================================
# Dock / Mission Control
# ============================================================================

# Dock に提案および最近使用したアプリを表示しない
defaults write com.apple.dock show-recents -bool false

# Dock のアイコンサイズ
defaults write com.apple.dock tilesize -int 72

# 最新の使用状況に基づいて操作スペースを自動的に並べ替えない
defaults write com.apple.dock mru-spaces -bool false

# ============================================================================
# Finder
# ============================================================================

# 隠しファイルを表示
defaults write com.apple.finder AppleShowAllFiles -bool true

# すべてのファイル名拡張子を表示
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# パスバーを表示
defaults write com.apple.finder ShowPathbar -bool true

# デフォルトの表示スタイルをリスト表示に
defaults write com.apple.finder FXPreferredViewStyle -string Nlsv

# デスクトップのアイコンをグリッドに沿って並べる
set_desktop_arrangement grid

# ============================================================================
# メニューバー / コントロールセンター
# ============================================================================

# 音量アイコンをメニューバーに常時表示
defaults write com.apple.controlcenter "NSStatusItem Visible Sound" -bool true

# ============================================================================
# ログイン項目 (System Events へのオートメーション許可が必要)
# ============================================================================

# ログイン時にアプリを開く。
# Rectangle は自身の launchOnLogin でも同梱ヘルパーを登録するが、そちらは
# 「バックグラウンドでの実行を許可」側なので、ここでの登録とは別枠になる
for login_item_app in "${login_item_apps[@]}"; do
  if [[ ! -d "$login_item_app" ]]; then
    printf 'warning: skipped login item for missing %s\n' "$login_item_app" >&2
    continue
  fi

  # オートメーションが未許可の端末では失敗するため、警告して続行する
  add_login_item "$login_item_app" ||
    printf 'warning: failed to add login item %s\n' "$login_item_app" >&2
done

# ============================================================================
# Rectangle (ウィンドウ管理)
# ============================================================================

# 稼働中に設定を書き換えると終了時に旧値で上書きされうるため、import 前に終了
if pgrep -xq Rectangle; then
  rectangle_restart_pending=1
  trap 'restore_rectangle_on_exit "$?"' EXIT
  killall Rectangle 2>/dev/null || true
  # 終了時の設定書き戻しと import が競合しないよう終了を待つ
  wait_for_rectangle_exit
fi

# エクスポート済みの設定 (ショートカット・スナップ挙動) を取り込み
defaults import com.knollsoft.Rectangle "$script_dir/rectangle.plist"

# ============================================================================
# 電源管理 (認証済み sudo が必要。未認証時はプロンプトを出さず警告して続行)
# ============================================================================

# 電源アダプタ接続時は自動スリープさせない
sudo -n pmset -c sleep 0 2>/dev/null || printf 'warning: skipped pmset sleep setting\n' >&2

# ============================================================================
# 反映
# ============================================================================

# 設定を反映するため関連プロセスを再起動
killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true
killall ControlCenter 2>/dev/null || true

# Rectangle を再起動して復旧 trap を解除
restart_rectangle
trap - EXIT

printf 'done: some settings take effect after re-login\n'
