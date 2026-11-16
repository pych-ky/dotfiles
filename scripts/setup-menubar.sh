#!/usr/bin/env bash
# メニューバーの表示・配置

set -euo pipefail

changed_count=0

# 管理キーが異なる場合だけ更新
write_default() {
  local domain="$1" key="$2" type="$3" value="$4"
  local expected="$4"

  case "$type:$value" in
  -bool:true) expected=1 ;;
  -bool:false) expected=0 ;;
  esac

  [[ "$(defaults read "$domain" "$key" 2>/dev/null)" != "$expected" ]] || return 0
  defaults write "$domain" "$key" "$type" "$value"
  changed_count=$((changed_count + 1))
}

## Stats

write_default eu.exelban.Stats CombinedModules -bool false
write_default eu.exelban.Stats keep_menubar_positions -bool false

for module in Bluetooth Clock GPU Remote Sensors; do
  write_default eu.exelban.Stats "${module}_state" -bool false
done

while read -r module widget position; do
  write_default eu.exelban.Stats "${module}_state" -bool true
  write_default eu.exelban.Stats "${module}_widget" -string "$widget"
  write_default eu.exelban.Stats "${module}_oneView" -bool false
  write_default eu.exelban.Stats \
    "NSStatusItem Preferred Position ${module}_${widget}" -float "$position"
done <<'WIDGETS'
CPU mini 506
RAM mini 459
Disk mini 412
Network speed 341
Battery battery 299
WIDGETS

## アプリ

write_default com.cisco.secureclient.gui "NSStatusItem Preferred Position Item-0" -float 591
write_default com.microsoft.wdav.tray "NSStatusItem Preferred Position Item-0" -float 553
write_default org.p0deje.Maccy showInStatusBar -bool false

## macOS 標準項目

# 位置は右端からの距離。OS 更新後は並びを確認
write_default com.apple.controlcenter "NSStatusItem Preferred Position WiFi" -float 261
write_default com.apple.TextInputMenuAgent "NSStatusItem Preferred Position Item-0" -float 217
write_default com.apple.Spotlight "NSStatusItem Preferred Position Item-0" -float 185
write_default com.apple.controlcenter "NSStatusItem Preferred Position BentoBox-0" -float 143

write_default com.apple.controlcenter "NSStatusItem VisibleCC WiFi" -bool true
write_default com.apple.controlcenter "NSStatusItem VisibleCC BentoBox-0" -bool true
write_default com.apple.controlcenter "NSStatusItem VisibleCC Clock" -bool true
write_default com.apple.TextInputMenuAgent "NSStatusItem VisibleCC Item-0" -bool true
write_default com.apple.Spotlight "NSStatusItem VisibleCC Item-0" -bool true

write_default com.apple.menuextra.clock ShowDate -int 0
write_default com.apple.menuextra.clock ShowDayOfWeek -bool true

if ((changed_count > 0)); then
  printf 'changed: updated menu bar settings\n'
fi
if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
  printf 'ok: Menu bar settings\n'
  if ((changed_count > 0)); then
    printf 'info: display changes may require an app restart or re-login\n'
  fi
fi
