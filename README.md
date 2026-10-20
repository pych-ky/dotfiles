# dotfiles

macOS・シェル・開発ツール・AI エージェントの個人用設定。

## 一括セットアップ

macOS・対話可能なローカル端末・`sudo` 権限が必要。
スクリプトには `sudo` を付けない。

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

多くの設定はリンクされ、編集が実環境へ反映される。
macOS 設定の一部は再ログイン後に反映される。

警告・未実施項目を解消し、[手動セットアップ](#手動セットアップ)へ進む。

## 個別セットアップ

### Homebrew パッケージ

```sh
brew bundle --no-upgrade --file=macos/Brewfile
brew bundle upgrade --file=macos/Brewfile
```

### シンボリックリンク

```sh
./scripts/link-dotfiles.sh --dry-run
./scripts/link-dotfiles.sh
```

通常ファイル・ディレクトリは `~/.dotfiles-backup/` に最新 5 世代を退避する。
事前確認で差異があれば、端末の変更をリポジトリや `~/.zshrc.local` などへ統合してから実行する。

### 共通設定

```sh
./scripts/setup-git.sh
./scripts/setup-macos.sh
./scripts/setup-typeless.sh
./scripts/setup-orca.sh
./scripts/setup-menubar.sh
```

電源管理には事前の `sudo` 認証が必要。
アプリの表示許可は「システム設定 > メニューバー」で設定する。

### 非公開リポジトリ

- Codex Custom Pets: `./scripts/setup-pets.sh`（[導入先・退避・更新手順](https://github.com/pych-ky/codex-custom-pets#readme)）
- Agent Skills: `./scripts/setup-skills.sh`（[導入・更新手順](https://github.com/pych-ky/agent-skills#readme)）

## 設定の管理

### コピーする設定

アプリ側の変更は、共通化する分だけ次回セットアップ前にリポジトリへ取り込む。

- Browser Use: リンク非対応
- Codex CLI・Orca プロファイル: モデル切替を別々に保存し、Orca 専用 HOME にも配置
- Orca キー設定: アプリの保存でリンクが外れる。反映後はキーボード設定で再読み込みするか再起動する
- Computer Use 常時許可一覧: アプリがリンク先の変更を検知しない

配置先は [scripts/link-dotfiles.sh](scripts/link-dotfiles.sh) を参照。

### Claude Code

共通設定は `etc/claude-code/settings.json`。
変更後は `scripts/link-dotfiles.sh` を再実行し、Claude Code を再起動する。

- 端末・Orca ペイン: `claude` 関数の `--settings` で共通設定を使用。素の起動は `command claude`
- IDE 拡張・Desktop: `/Library/Application Support/ClaudeCode/managed-settings.json` に配置するが、組織配布が優先。dotfiles 設置分のみ更新し、外部からの変更は保持
- `~/.claude/settings.json`: Git 管理外のユーザー設定（Orca フック・プラグイン・`/model`）。セットアップは Playwright の Edge 接続先だけ反映

プロジェクトの `.claude/settings.local.json` は保持する。
Orca は設定を同期するため専用ファイルを dotfiles へリンクせず、共通設定を重複させない。

### Codex の設定

`~/.codex/config.toml` は端末固有設定だけを置く。

- 対話シェル: `--profile cli`。シェル関数を経由しない通常 CLI には `--no-daemon --profile cli` を付ける
- Orca: `--profile orca`。起動引数の Sol / Ultra により、セッション中のモデル切替は新規起動に持ち越さない
- プロファイル保存先: 起動時の `CODEX_HOME` 配下の同名 `.config.toml`
- 共通の既定モデル: Codex 画面・Chrome / Edge 拡張は `~/.codex/config.toml` を共有。Orca の通常の `config.toml` も同ファイルと同期するため、Orca 専用設定には使わない

共通権限は `etc/codex/config.toml`。

- 変更後は新規タスクで「保護付きフルアクセス」の選択を確認する。既存タスクは旧承認方式を引き継ぐ
- 組み込みの「フルアクセス」を選び直すと承認方式が `never` に戻る

## 手動セットアップ

### システムとアプリ

- システム設定 > プライバシーとセキュリティ
  - 必要なアプリにフルディスクアクセス・アクセシビリティ・入力監視を許可
  - ログイン項目の登録には、オートメーションで System Events を許可
- システム設定 > 一般 > ログイン項目と拡張機能
  - 「ログイン時に開く」: Maccy・Rectangle・Stats・Typeless の登録を確認
  - 「アプリのバックグラウンドでのアクティビティ」: Karabiner・Logi Options+・Logitech Inc をオン
  - 拡張機能 > Driver Extensions: Karabiner DriverKit VirtualHIDDevice をオン
- メニューバーの日本語入力メニュー > ユーザ辞書を編集
  - `しかく` → `■` / `ほし` → `★` / `やじるし` → `→` / `かっこ` → `「」` を登録
- Claude Code の Playwright MCP
  - Claude Code の初回起動後、`claude plugin install playwright@claude-plugins-official --scope user` で導入する
  - Edge の `edge://inspect/#remote-debugging` で「Allow remote debugging for this browser instance」を有効にする（[接続方式](https://playwright.dev/mcp/configuration/browser-extension)）

### Logi Options+

1. マウスの共通設定で、既定の「戻る」に `End`、「進む」に `Home` を割り当てる
2. Orca のアプリ別設定で「戻る」に「末尾に移動」(`Ctrl+End` → `Cmd+↓`)、「進む」に「先頭に移動」(`Ctrl+Home` → `Cmd+↑`) のマクロを追加する
3. 各マクロの各キー操作直前に `21ms` の待機を入れる

### キーボード

外付けキーボードは Mac モードを使う。

#### Keychron K8 Pro 本体の移行

1. USB 接続し、本体を Cable・Mac モードにする
2. [VIA](https://usevia.app/) の Save + Load で旧レイアウトを保存し、[移行用レイアウト](macos/keychron_k8_pro_ansi_rgb.layout.json) を読み込む
   - 機種定義が必要なら、[Keychron 公式配布](https://www.keychron.com/pages/firmware-and-json-files-of-the-keychron-qmk-k-pro-and-k-max-series-keyboards)の K8 Pro ANSI RGB v1.7 を使う
3. Karabiner の Keychron 機器設定で Simple Modifications を空にする
4. 左 Ctrl 位置でのコピー、かな・英数、F13、Fn 音量操作を確認する

復元時は旧レイアウトを読み込み、Karabiner の Keychron 機器設定で左 Control / Option / Command を各々同じキーへ変換する 3 件を追加する。
