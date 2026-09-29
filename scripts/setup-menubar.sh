#!/usr/bin/env bash
# メニューバーの表示項目と保存済みの位置を反映

set -euo pipefail

if ((EUID == 0)); then
  printf 'error: do not run scripts/setup-menubar.sh with sudo or as root\n' >&2
  exit 1
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'error: scripts/setup-menubar.sh supports macOS only\n' >&2
  exit 1
fi

changed_count=0

# 管理するキーだけを比較・更新し、保存結果を読み戻す
write_default() {
  local domain="$1" key="$2" type="$3" value="$4"
  local current expected="$4"

  case "$type:$value" in
  -bool:true) expected=1 ;;
  -bool:false) expected=0 ;;
  esac

  if current="$(defaults read "$domain" "$key" 2>/dev/null)" &&
    [[ "$current" == "$expected" ]]; then
    return 0
  fi

  defaults write "$domain" "$key" "$type" "$value"
  if [[ "$(defaults read "$domain" "$key")" != "$expected" ]]; then
    printf 'error: failed to verify preference: %s / %s\n' "$domain" "$key" >&2
    return 1
  fi
  changed_count=$((changed_count + 1))
}

## Stats

write_default eu.exelban.Stats CombinedModules -bool false
write_default eu.exelban.Stats keep_menubar_positions -bool false

for module in GPU Sensors Bluetooth Clock Remote; do
  write_default eu.exelban.Stats "${module}_state" -bool false
done

# 独立したウィジェットを左から CPU・RAM・SSD・通信量・バッテリーの順に表示
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

# 位置は右端からの距離で、大きい値ほど左。OS 更新後は並びを確認する
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
