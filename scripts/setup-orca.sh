#!/usr/bin/env bash
# Orca 共通設定の反映

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_common_library="$repo_dir/lib/setup-common.sh"
if [[ ! -f "$setup_common_library" || -L "$setup_common_library" ]]; then
  printf 'error: setup common library is missing or unsafe: %s\n' "$setup_common_library" >&2
  exit 1
fi
# shellcheck source=lib/setup-common.sh
source "$setup_common_library"

if ((EUID == 0)); then
  printf 'error: do not run scripts/setup-orca.sh with sudo or as root\n' >&2
  exit 1
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'error: scripts/setup-orca.sh supports macOS only\n' >&2
  exit 1
fi

setup_validate_home || exit 1

orca_app=/Applications/Orca.app
if [[ ! -d "$orca_app" ]]; then
  orca_app="$HOME/Applications/Orca.app"
fi
if [[ ! -d "$orca_app" ]]; then
  printf 'skipped: Orca is not installed\n'
  exit 0
fi

process_status=0
pgrep -xq Orca || process_status=$?
case "$process_status" in
0)
  printf 'skipped: Orca is running\n'
  exit 3
  ;;
1) ;;
*)
  printf 'error: could not determine whether Orca is running\n' >&2
  exit 1
  ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required\n' >&2
  exit 1
fi

data_dir="$HOME/Library/Application Support/orca"
profile_index="$data_dir/orca-profile-index.json"
managed_settings="$repo_dir/macos/orca.json"

if [[ ! -f "$profile_index" ]]; then
  printf 'skipped: launch and quit Orca once, then run scripts/setup-orca.sh\n'
  exit 0
fi

profile_id="$(jq -er '.activeProfileId | strings | select(test("^[A-Za-z0-9_-]+$"))' "$profile_index")"
settings_file="$data_dir/profiles/$profile_id/orca-data.json"
settings_db="$data_dir/profiles/$profile_id/profile-state.db"

jq -e 'type == "object"' "$managed_settings" >/dev/null

# SQLite の整合性管理は Orca 内蔵の保存処理に任せる
if [[ -e "$settings_db" || -L "$settings_db" ]]; then
  if [[ -L "$settings_db" || ! -f "$settings_db" ]]; then
    printf 'error: Orca profile database must be a regular file: %s\n' "$settings_db" >&2
    exit 1
  fi
  env -u NODE_OPTIONS -u NODE_REPL_EXTERNAL_MODULE ELECTRON_RUN_AS_NODE=1 \
    "$orca_app/Contents/MacOS/Orca" --input-type=commonjs - \
    "$orca_app" "$data_dir" "$profile_id" "$managed_settings" <<'JAVASCRIPT'
const fs = require("node:fs");
const path = require("node:path");
const { isDeepStrictEqual } = require("node:util");

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function mergeSettings(current, managed) {
  const merged = { ...current };
  for (const [key, value] of Object.entries(managed)) {
    merged[key] = isObject(current[key]) && isObject(value)
      ? mergeSettings(current[key], value)
      : value;
  }
  return merged;
}

function main() {
  const [appPath, dataDir, profileId, managedFile] = process.argv.slice(2);
  const mainDir = path.join(appPath, "Contents/Resources/app.asar.unpacked/out/main");
  const chunksDir = path.join(mainDir, "chunks");
  const authorityFiles = fs.readdirSync(chunksDir).filter((name) =>
    /^profile-state-sqlite-authority-.*\.js$/.test(name));
  if (authorityFiles.length !== 1) {
    throw new Error("unsupported Orca profile-state API");
  }
  // 内部モジュールは短縮された export 名に依存せず、必要なメソッドで特定
  const methods = ["readAcceptedState", "readInitialState", "writeSerializedDomains", "close"];
  const authorities = Object.values(require(path.join(chunksDir, authorityFiles[0])))
    .filter((value) => typeof value === "function" &&
      methods.every((method) => typeof value.prototype?.[method] === "function"));
  if (authorities.length !== 1) {
    throw new Error("unsupported Orca profile-state API");
  }
  const Authority = authorities[0];
  const { acquireProfileStateMaintenance } = require(path.join(
    mainDir, "persistence/profile-state/profile-state-access.js"));
  const settingsFile = path.join(dataDir, "profiles", profileId, "orca-data.json");
  const databaseFile = path.join(dataDir, "profiles", profileId, "profile-state.db");
  const managed = JSON.parse(fs.readFileSync(managedFile, "utf8"));
  if (!isObject(managed)) throw new Error("Orca managed settings must be an object");

  // Orca の同時起動と設定更新を排他し、既存プロファイルの整合性を確認
  const maintenance = acquireProfileStateMaintenance(dataDir);
  let authority;
  try {
    maintenance.assertProfile(profileId, settingsFile, databaseFile);
    authority = new Authority(databaseFile, profileId);
    const snapshot = fs.existsSync(settingsFile)
      ? authority.readAcceptedState(fs.readFileSync(settingsFile, "utf8"))
      : authority.readInitialState();
    if (!snapshot) throw new Error("Orca profile JSON and SQLite state are inconsistent");
    const current = snapshot.takeParsedState()?.settings;
    if (!isObject(current)) throw new Error("Orca profile settings must be an object");
    const merged = mergeSettings(current, managed);
    // エージェントごとの環境は空オブジェクトも明示的な設定として置換
    merged.agentDefaultEnv = { ...current.agentDefaultEnv, ...managed.agentDefaultEnv };
    if (isDeepStrictEqual(current, merged)) return;

    authority.writeSerializedDomains([{ domain: "settings", payload: JSON.stringify(merged) }]);
    console.log(`changed: updated Orca settings: ${databaseFile}`);
  } finally {
    try {
      authority?.close();
    } finally {
      maintenance.release();
    }
  }
}

try {
  main();
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
}
JAVASCRIPT
  if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
    printf 'ok: Orca settings\n'
  fi
  exit 0
fi

if [[ -L "$settings_file" || ! -f "$settings_file" ]]; then
  printf 'error: Orca profile data must be an existing regular file: %s\n' "$settings_file" >&2
  exit 1
fi

jq -e '.settings | type == "object"' "$settings_file" >/dev/null

# エージェントごとの環境は空オブジェクトも明示的な設定として置換
settings_filter=".settings *= \$managed[0] | .settings.agentDefaultEnv += \$managed[0].agentDefaultEnv"

# 一致している場合は書き換えずに終了
if jq -e --slurpfile managed "$managed_settings" \
  ". == ($settings_filter)" "$settings_file" >/dev/null; then
  if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
    printf 'ok: Orca settings\n'
  fi
  exit 0
fi

temporary_settings="$(mktemp "$settings_file.XXXXXX")"
trap 'rm -f -- "$temporary_settings"' EXIT

# 未指定の設定・アカウント・作業状態を保持
jq --slurpfile managed "$managed_settings" \
  "$settings_filter" "$settings_file" >"$temporary_settings"
mv -- "$temporary_settings" "$settings_file"
trap - EXIT
printf 'changed: updated Orca settings: %s\n' "$settings_file"
if [[ ${DOTFILES_BOOTSTRAP:-0} != 1 ]]; then
  printf 'ok: Orca settings\n'
fi
