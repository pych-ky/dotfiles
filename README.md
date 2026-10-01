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
差異を警告されたら、端末の変更をリポジトリか `~/.zshrc.local` などへ統合して再実行する。

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

### メニューバー

```sh
./scripts/setup-menubar.sh
```

アプリのメニューバーへの表示許可は「システム設定 > メニューバー」で設定する。

### Codex App の権限

`~/.codex/config.toml` には端末固有の設定だけを置く。

個別に反映する場合は、ChatGPT/Codex を終了して次を実行する。

```sh
./scripts/setup-codex.sh --dry-run
./scripts/setup-codex.sh
```

再起動後は拡張機能のサイドパネルも開き直し、新規タスクを開始する。
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
- Rancher Desktop: リンク先への自動追記を防ぐため、Preferences > Application > Environment > Configure PATH を Manual にする
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
