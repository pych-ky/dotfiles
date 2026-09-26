# dotfiles

macOS・シェル・開発ツール・AI エージェントの個人用設定。

## 一括セットアップ

macOS、対話可能なローカル端末、`sudo` 権限が必要。
スクリプト自体には `sudo` を付けない。

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

警告・未実施項目を解消し、[手動セットアップ](#手動セットアップ)へ進む。
設定の多くはリンクされ、編集が実環境に反映される。

## 手動セットアップ

### システムとアプリ

- システム設定 > プライバシーとセキュリティ
  - 必要なアプリにフルディスクアクセス・アクセシビリティ・入力監視を許可
  - ログイン項目の登録には、オートメーションで System Events を許可
- システム設定 > 一般 > ログイン項目と拡張機能
  - 「ログイン時に開く」: Maccy・Rectangle・Typeless の登録と Logi Options+ の未登録を確認
  - 「アプリのバックグラウンドでのアクティビティ」: Karabiner・Logi Options+・Logitech Inc をオン
  - 拡張機能 > Driver Extensions: Karabiner DriverKit VirtualHIDDevice をオン
- Rancher Desktop: リンク先への自動追記を防ぐため、Preferences > Application > Environment > Configure PATH を Manual にする
- [Maccy](https://github.com/p0deje/Maccy#usage)（`Cmd+Shift+C` で履歴）: 自動貼り付けには「Paste automatically」とアクセシビリティを許可
- VS Code: Settings Sync にサインインし、「Shell Command: Install 'code' command in PATH」を実行
- Claude Code / Codex の Linear は端末ごとに OAuth 認証
- ChatGPT の Linear はアカウントごとに Install / Connect し、初回 OAuth 認証を手動で行う
- Microsoft Edge: ChatGPT の「設定 > コンピューターの使用」から、使用するプロファイルに [ChatGPT 拡張機能](https://microsoftedge.microsoft.com/addons/detail/odlomjlbamekndcpllcnffbgeohgkmjh) を導入し、接続後に `@Edge` が選べることを確認

### GitHub の認証

Git / `gh` は HTTPS で端末ごとに認証する。

```sh
gh auth login --hostname github.com --git-protocol https
```

組織用の [ghtkn](https://github.com/suzuki-shunsuke/ghtkn) は非公開設定に従う。

```sh
ghtkn init   # 対象の GitHub App の Client ID を設定する
ghtkn auth   # デバイスフローで認証する
```

## 非公開設定（dotfiles-private）

[dotfiles-private](https://github.com/pych-ky/dotfiles-private) はアクセス可能な場合だけ自動取得・適用する。

## 個別セットアップ

### シンボリックリンク

```sh
./scripts/link-dotfiles.sh --dry-run   # 事前確認のみ
./scripts/link-dotfiles.sh             # リンク作成
```

通常ファイル・ディレクトリは `~/.dotfiles-backup/` に退避し、最新 5 世代を保持する。
差異を警告されたら、端末の変更をリポジトリか `~/.zshrc.local` などへ統合して再実行する。

`~/.codex/config.toml` には端末固有の設定だけを置く。
Orca は設定を同期するため、共通設定を重複させず、専用ファイルを dotfiles へリンクしない。
公開側の `default_permissions` を使うため、端末固有設定の旧 `sandbox_mode` / `[sandbox_workspace_write]` は削除する。

#### Codex App の権限

リンク後は Codex を終了し、承認メニューで「保護付きフルアクセス」を選んで新規タスクを開始する。
最後に選んだ権限が設定値より優先され、既存タスクは旧承認方式を引き継ぐ。
組み込みの「フルアクセス」は承認を無効化し、Computer Use の接続も拒否される場合がある。

### Git 共通設定

```sh
./scripts/setup-git.sh
mise install aqua:secretlint/secretlint
```

### Homebrew パッケージ

```sh
brew bundle --no-upgrade --file=macos/Brewfile       # 不足パッケージのインストール
brew bundle upgrade --file=macos/Brewfile            # 管理対象パッケージのアップグレード
```

### シェルのファジー検索

新規ターミナルで `cghq [検索語]`（Zsh は `Ctrl+G` も可）を使い、ghq リポジトリへ移動する。

### macOS・Typeless・Orca

```sh
./macos/defaults.sh
./macos/setup-typeless.sh
./macos/setup-orca.sh
```

macOS 設定は一部が再ログイン後に反映され、電源管理には事前の `sudo` 認証が必要。
Typeless・Orca の起動・終了を求める案内が出た場合は、その案内に従って再実行する。

### キーボード

端末の処理中断には、印字された左 `Command+C` を使う。

Orca の変更は `scripts/link-dotfiles.sh` でコピー後、キーボード設定で再読み込みするか再起動する。
Ghostty は `Ctrl+Shift+,`、Karabiner・WezTerm は自動で再読み込みする。

外付けキーボードは Mac モードを使う。
Windows 配列のみの機器は、Karabiner の機器別 Simple Modifications で `left_command → left_control`、`left_option → left_option` を指定する。

#### Keychron K8 Pro 本体の移行

1. USB 接続し、本体を Cable・Mac モードにする
2. [VIA](https://usevia.app/) の Save + Load から [移行用レイアウト](macos/keychron_k8_pro_ansi_rgb.layout.json) を読み込む
   - 機種定義が必要なら、[Keychron 公式配布](https://www.keychron.com/pages/firmware-and-json-files-of-the-keychron-qmk-k-pro-and-k-max-series-keyboards)の K8 Pro ANSI RGB v1.7 を使う
3. Karabiner の Keychron 機器設定で Simple Modifications を空にする
4. 左 Ctrl 位置でのコピー、かな・英数、F13、Fn 音量操作を確認する

復元時は旧レイアウトを読み込み、Karabiner の Keychron 機器設定に左 Control / Option / Command を各々同じキーへ変換する 3 件を追加する。

### 非公開 Codex Custom Pets

```sh
./pets/setup.sh
```

導入先・退避・更新手順は [Pets の README](https://github.com/pych-ky/codex-custom-pets#readme) を参照。
導入後は Codex の `Settings → Pets → Refresh` を実行する。

#### 更新

Pets のチェックアウトで `git switch main`・`git pull --ff-only` 後、dotfiles に戻って `./pets/setup.sh` を再実行する。

### 非公開 Agent Skills

```sh
./skills/setup.sh
```

導入後は新規 Codex セッションで確認する。
配置・選択・単体導入・クラウドルーティンは [Agent Skills の README](https://github.com/pych-ky/agent-skills#readme) を参照。

#### 更新

Agent Skills のチェックアウトで `git pull --ff-only`・`./setup.sh` を実行する。
