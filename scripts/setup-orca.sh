#!/usr/bin/env bash
# Orca 共通設定の反映

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
orca_app=/Applications/Orca.app
data_dir="$HOME/Library/Application Support/orca"
profile_index="$data_dir/orca-profile-index.json"

if [[ ! -d "$orca_app" ]]; then
  printf 'skipped: Orca is not installed\n'
  exit 3
fi
if pgrep -xq Orca; then
  printf 'skipped: Orca is running\n'
  exit 3
fi
if [[ ! -f "$profile_index" ]]; then
  printf 'skipped: launch and quit Orca once, then run scripts/setup-orca.sh\n'
  exit 3
fi

profile_id="$(jq -er .activeProfileId "$profile_index")"

# SQLite は Orca 内蔵の保存 API 経由で更新
env -u NODE_OPTIONS -u NODE_REPL_EXTERNAL_MODULE ELECTRON_RUN_AS_NODE=1 \
  "$orca_app/Contents/MacOS/Orca" --input-type=commonjs - \
  "$orca_app" "$data_dir" "$profile_id" "$repo_dir/macos/orca.json" <<'JAVASCRIPT'
const fs = require("node:fs");
const path = require("node:path");
const { isDeepStrictEqual } = require("node:util");

// 設定オブジェクトか判定
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// 管理値を再帰的に上書き
function mergeSettings(current, managed) {
  const merged = { ...current };
  for (const [key, value] of Object.entries(managed)) {
    merged[key] = isObject(current[key]) && isObject(value)
      ? mergeSettings(current[key], value)
      : value;
  }
  return merged;
}

// Orca の保存 API で設定を反映
function main() {
  const [appPath, dataDir, profileId, managedFile] = process.argv.slice(2);
  const mainDir = path.join(appPath, "Contents/Resources/app.asar.unpacked/out/main");
  const chunksDir = path.join(mainDir, "chunks");
  const authorityFile = fs.readdirSync(chunksDir).find((name) =>
    /^profile-state-sqlite-authority-.*\.js$/.test(name));
  // 短縮された export 名には依存せず、保存 API のメソッドでクラスを特定
  const methods = ["readAcceptedState", "readInitialState", "writeSerializedDomains", "close"];
  const Authority = authorityFile && Object.values(require(path.join(chunksDir, authorityFile)))
    .find((value) => typeof value === "function" &&
      methods.every((method) => typeof value.prototype?.[method] === "function"));
  if (!Authority) throw new Error("unsupported Orca profile-state API");
  const { acquireProfileStateMaintenance } = require(path.join(
    mainDir, "persistence/profile-state/access/profile-state-access.js"));
  const settingsFile = path.join(dataDir, "profiles", profileId, "orca-data.json");
  const databaseFile = path.join(dataDir, "profiles", profileId, "profile-state.db");
  const managed = JSON.parse(fs.readFileSync(managedFile, "utf8"));

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
    // エージェント環境は空オブジェクトも置換
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
