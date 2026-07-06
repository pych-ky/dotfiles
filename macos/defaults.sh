#!/usr/bin/env bash
#
# ============================================================================
# macOS システム設定のうちデフォルトから変更している項目を適用するスクリプト
# ============================================================================
#
# 現行環境でデフォルト値から意図的に変更していた項目のみを対象とする。
# 冪等なので何度実行してもよい。一部の項目は再ログイン後に反映される。

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ============================================================================
# 日本語入力 (再ログイン後に反映)
# ============================================================================

# ライブ変換を無効化
defaults write com.apple.inputmethod.Kotoeri JIMPrefLiveConversionKey -bool false

# 入力中の自動修正を無効化
defaults write com.apple.inputmethod.Kotoeri JIMPrefAutocorrectionKey -bool false

# メニューバーに入力メニュー (「あ」アイコン) を表示
defaults write com.apple.TextInputMenu visible -bool true

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

# 新規ウィンドウで「最近の項目」を開く
defaults write com.apple.finder NewWindowTarget -string PfAF

# ============================================================================
# メニューバー / コントロールセンター
# ============================================================================

# 音量アイコンをメニューバーに常時表示
defaults write com.apple.controlcenter "NSStatusItem Visible Sound" -bool true

# ============================================================================
# Rectangle (ウィンドウ管理)
# ============================================================================

# 稼働中に設定を書き換えると終了時に旧値で上書きされうるため、import 前に終了
rectangle_running=0
if pgrep -xq Rectangle; then
  rectangle_running=1
  killall Rectangle 2>/dev/null || true
  # 終了時の設定書き戻しと import が競合しないよう終了を待つ
  while pgrep -xq Rectangle; do sleep 0.2; done
fi

# エクスポート済みの設定 (ショートカット・スナップ挙動) を取り込み
defaults import com.knollsoft.Rectangle "$script_dir/rectangle.plist"

# ============================================================================
# 電源管理 (sudo が必要、失敗しても後続の反映処理は続行)
# ============================================================================

# 電源アダプタ接続時は自動スリープさせない
sudo pmset -c sleep 0 || printf 'warning: skipped pmset sleep setting\n' >&2

# ディスプレイを自動的にオフにしない (好みに応じて分数を調整)
sudo pmset -a displaysleep 0 || printf 'warning: skipped pmset displaysleep setting\n' >&2

# ============================================================================
# 反映
# ============================================================================

# 設定を反映するため関連プロセスを再起動
killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true
killall ControlCenter 2>/dev/null || true

# import 前に終了させた Rectangle を再起動
if ((rectangle_running)); then
  open -a Rectangle
fi

printf 'done: some settings take effect after re-login\n'
