# dotfiles

macOS・シェル・開発ツール・AI エージェントの個人用設定。

## 一括セットアップ

macOS、対話可能なローカル端末、`sudo` 権限が必要。
スクリプト自体には `sudo` を付けない。

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

設定の多くはリンクされ、編集が実環境に反映される。
macOS 設定の一部は再ログイン後に反映される。

警告・未実施項目を解消し、[手動セットアップ](#手動セットアップ)へ進む。

## 個別セットアップ

### Homebrew パッケージ

```sh
brew bundle --no-upgrade --file=macos/Brewfile       # 不足パッケージのインストール
brew bundle upgrade --file=macos/Brewfile            # 管理対象パッケージのアップグレード
```

### シンボリックリンク

```sh
./scripts/link-dotfiles.sh --dry-run   # 事前確認のみ
./scripts/link-dotfiles.sh             # リンク作成
```

通常ファイル・ディレクトリは `~/.dotfiles-backup/` に退避し、最新 5 世代を保持する。
事前確認で差異を警告されたら、端末の変更をリポジトリか `~/.zshrc.local` などへ統合してから実行する。

次の設定は通常ファイルとしてコピーする。

- `~/.codex/browser/config.toml`: Browser Use の設定読み込みがシンボリックリンクを拒否するため
- `~/.codex/cli.config.toml` と `~/.codex/orca.config.toml`: CLI と Orca のモデル切替を別々に保存するため
- `~/Library/Application Support/orca/codex-runtime-home/home/orca.config.toml`: Orca 専用 HOME からの起動でも Orca プロファイルを使うため
- `~/.orca/keybindings.json`: Orca が保存時にファイルを置き換え、シンボリックリンクが外れるため
- `~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/Library/Application Support/Software/ComputerUseAppApprovals.json`: ChatGPT/Codex がリンク先の変更を検知できないため

これらをアプリで変更した場合は、次回実行前に共通設定として管理する差分だけを対応するリポジトリのファイルへ取り込む。

Claude の共通設定は `etc/claude-code/settings.json` の1ファイルで管理する。
共通設定の変更後は `scripts/link-dotfiles.sh` を再実行し、Claude Code を再起動する。

- IDE 拡張・Desktop: `/Library/Application Support/ClaudeCode/managed-settings.json` を使うが、組織配布の managed settings が優先される。コピー先は不在・旧リンク・前回設置時の SHA-256 と一致する場合だけ更新する
- 端末・Orca のペイン: `claude` シェル関数が `--settings` で共通設定を渡す。素の起動は `command claude` を使う
- `~/.claude/settings.json`: Git 管理外の通常ファイルとし、Orca のフック・個人のプラグイン・`/model` を保存する。セットアップは Playwright の Edge 接続先だけを反映し、その他のユーザー設定とプロジェクトの `.claude/settings.local.json` は保持する

Orca は設定を同期するため、共通設定を重複させず、専用ファイルを dotfiles へリンクしない。
Orca のキーバインド変更は `scripts/link-dotfiles.sh` でコピー後、キーボード設定で再読み込みするか再起動する。

### Git 共通設定

```sh
./scripts/setup-git.sh
```

### macOS・Typeless・Orca

```sh
./scripts/setup-macos.sh
./scripts/setup-typeless.sh
./scripts/setup-orca.sh
```

電源管理の設定には事前の `sudo` 認証が必要。

Orca の起動中は設定の反映をスキップするため、Orca を終了してから実行する。

### メニューバー

```sh
./scripts/setup-menubar.sh
```

アプリのメニューバーへの表示許可は「システム設定 > メニューバー」で設定する。

### Codex の設定

`~/.codex/config.toml` には端末固有の設定だけを置く。

対話シェルは `--profile cli`、Orca の Codex CLI は `--profile orca` を使い、それぞれのモデル・エフォートを分ける。
Orca は起動引数でも Sol / Ultra を指定し、セッション中のモデル切替でプロファイルが書き変わっても、新規起動は Sol / Ultra に戻す。
シェル関数を経由しない通常 CLI の起動では `--no-daemon --profile cli` を付ける。
プロファイルは起動時の `CODEX_HOME` 配下にある同名の `.config.toml` に保存される。Orca の通常の `config.toml` は `~/.codex/config.toml` と同期されるため、独立設定には使わない。
Codex 画面と Chrome / Edge 拡張の既定モデルは現行版では `~/.codex/config.toml` を共有する。

共通の権限プロファイルは `etc/codex/config.toml` で管理する。
設定変更後は新規タスクで「保護付きフルアクセス」が選ばれていることを確認する。
既存タスクは旧承認方式を引き継ぐ。
組み込みの「フルアクセス」を選び直すと承認方式が `never` に戻る。

### 非公開 Codex Custom Pets

```sh
./scripts/setup-pets.sh
```

導入先・退避・更新手順は [Pets の README](https://github.com/pych-ky/codex-custom-pets#readme) を参照。

### 非公開 Agent Skills

```sh
./scripts/setup-skills.sh
```

導入・更新手順は [Agent Skills の README](https://github.com/pych-ky/agent-skills#readme) を参照。

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
  - Edge の `edge://inspect/#remote-debugging` で「Allow remote debugging for this browser instance」を有効にする（[接続方式](https://playwright.dev/mcp/configuration/browser-extension)）

### キーボード

外付けキーボードは Mac モードを使う。

#### Keychron K8 Pro 本体の移行

1. USB 接続し、本体を Cable・Mac モードにする
2. [VIA](https://usevia.app/) の Save + Load から [移行用レイアウト](macos/keychron_k8_pro_ansi_rgb.layout.json) を読み込む
   - 機種定義が必要なら、[Keychron 公式配布](https://www.keychron.com/pages/firmware-and-json-files-of-the-keychron-qmk-k-pro-and-k-max-series-keyboards)の K8 Pro ANSI RGB v1.7 を使う
3. Karabiner の Keychron 機器設定で Simple Modifications を空にする
4. 左 Ctrl 位置でのコピー、かな・英数、F13、Fn 音量操作を確認する

復元時は旧レイアウトを読み込み、Karabiner の Keychron 機器設定に左 Control / Option / Command を各々同じキーへ変換する 3 件を追加する。
