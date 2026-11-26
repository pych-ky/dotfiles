# dotfiles

macOS・シェル・開発ツール・AI エージェントの個人用設定。

## 一括セットアップ

- 対話可能なローカル端末と `sudo` 権限が必要
- スクリプトには `sudo` を付けない

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

多くの設定はリンクされ、リポジトリの編集がそのまま実環境へ反映される。
macOS 設定の一部は再ログイン後に反映される。

- 完了後は[手動セットアップ](#手動セットアップ)を行う

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

- 事前確認で差異があれば、端末の変更をリポジトリや `~/.zshrc.local` などへ統合してから実行する

### 共通設定

```sh
./scripts/setup-git.sh
./scripts/setup-macos.sh
./scripts/setup-typeless.sh
./scripts/setup-orca.sh
./scripts/setup-menubar.sh
./scripts/setup-pets.sh
./scripts/setup-skills.sh
```

- `setup-macos.sh` の電源管理は、事前に `sudo -v` で認証しておく
- `setup-pets.sh`・`setup-skills.sh` は未取得のリポジトリを clone するだけで、既存の clone は更新しない
  - 更新は [Codex Custom Pets](https://github.com/pych-ky/codex-custom-pets#readme)・[Agent Skills](https://github.com/pych-ky/agent-skills#readme) の手順で行う

### Node の CLI 復元

- Node の導入・更新時に CLI の復元が失敗した場合は、原因を解消して `mise install node` を再実行する

## 設定の管理

勤務先固有の情報・設定は公開側に置かず、必要なものだけ `dotfiles-private` で管理する。

### 文章ルールと ChatGPT のカスタム指示

- 推敲ルールは[共通本文](etc/ai-instructions/japanese-writing.md)で変更し、各ツールの常時適用される指示と [ChatGPT 用本文](etc/chatgpt/custom-instructions.txt)へ反映する
- ChatGPT 用本文は全文を「設定 > パーソナライズ > ChatGPT のカスタム指示」に貼り付けて保存し、開き直して一致を確認する
- アプリ側で変更した場合は、共通ルールの変更を共通本文へ、それ以外を ChatGPT 用本文へ取り込む

### コピーする設定

Codex Browser Use・Codex CLI と Orca のプロファイル・Orca キー設定・Computer Use 常時許可一覧はリンクせずコピーする。

- アプリ側の変更は、共通化する分だけ次回セットアップ前にリポジトリへ取り込む
- Orca キー設定の反映後は、Orca のキーボード設定で再読み込みするか再起動する

### Claude Code

共通設定は `etc/claude-code/settings.json`。

- 変更後は `./scripts/link-dotfiles.sh --claude-settings-only` を実行し、Claude Code を再起動する
- 端末・Orca ペインでは `claude` 関数が `--settings` で共通設定を渡す
  - `--settings` を渡さずに起動するには `command claude` を使う
- IDE 拡張・Desktop 向けの `/Library/Application Support/ClaudeCode/managed-settings.json` は、組織配布があればそちらが優先される
- `~/.claude/settings.json` は Git 管理外で、Orca フック・プラグイン・`/model` の保存先
- Orca は設定を同期するため、専用ファイルを dotfiles へリンクせず、共通設定も重複させない

### Codex の設定

`~/.codex/config.toml` はアプリが管理する端末固有設定。
共通の既定値・権限は `etc/codex/config.toml`。

- 既定モデルの変更後は `./scripts/setup-codex.sh` で通常アプリ・Orca のモデル保存値を揃える
- シェル関数を経由しない CLI には `--no-daemon --profile cli` を付ける
- Orca は起動引数でモデルを指定するため、セッション中のモデル切替は次の起動に持ち越されない
- Codex 画面・Chrome / Edge 拡張は `~/.codex/config.toml` を共有する
  - Orca の通常の `config.toml` も同じ内容に同期されるため、Orca 専用の設定には使わない
- 権限の変更後は、新規タスクで「保護付きフルアクセス」が選ばれていることを確認する
  - 既存タスクは旧承認方式を引き継ぐ
- 組み込みの「フルアクセス」を選び直すと承認方式が `never` に戻る

### GitHub Copilot CLI

単体で起動したときの既定モデルと推論量は `.copilot/settings.json` で指定する。
`/config model` で選んだ既定モデルは `~/.copilot/settings.json` にだけ保存され、`./scripts/link-dotfiles.sh` を実行するとこのファイルの値に戻る。

- 既定モデルや推論量を変えるときは、`macos/orca.json` の `agentDefaultArgs.copilot`・`agentLaunchChoices.copilot` も揃え、`./scripts/setup-orca.sh` を実行する
- Orca のチャットは `copilot --acp` で起動し、`.copilot/settings.json` のモデルを使わない

### Hermes Agent

- 更新は `hermes update` で行う
- Homebrew 版は[公式サポート対象外](https://hermes-agent.nousresearch.com/docs/getting-started/platform-support)のため使わない
- 端末へ適用する設定は dotfiles に置き、会話・スケジュール参照用の ai-man-config には置かない
- 設定は `./scripts/setup-hermes.sh` で適用する
  - 変更はこのスクリプトに反映して再実行する
- `~/.hermes/config.yaml` はリンクせず、認証情報・会話履歴・自動生成状態も Git 管理外にする
- 認証は `hermes auth add openai-codex --type oauth --browser` で ChatGPT にログインする
  - 既存の Codex・Claude Code の認証は共有されない
- 初回起動時と変更時に `.hermes/hooks/pre-tool-guard.sh` の実行を承認し、`hermes hooks doctor` で確認する
  - 未承認の hook は実行されない
- デスクトップ操作は、通常のターミナルで `./scripts/setup-hermes-computer-use.sh` を実行し、macOS のアクセシビリティ・画面収録を許可する
  - `hermes update` 後も再実行する

ローカル実行は OS の隔離環境ではなく、ガードは直接記述された既知の危険操作を静的に検査する。
動的に組み立てたパス、`execute_code` などインタプリタへ渡すコード、起動済みプロセスへ送る標準入力、外部 CLI 内部の処理は追跡しない。
フックはプロセスの作業ディレクトリを基準にするため、`terminal` の `cd` やセッションの作業場所変更後は相対パスがずれ、見逃し・誤拒否が起こりうる。
手動承認は危険パターンに一致したコマンドが対象で、チェックポイントも shell による全変更の復旧を保証しない。

## 手動セットアップ

### システムとアプリ

- Aqua Voice: 初回起動時にログインし、マイク・アクセシビリティの利用を許可する
  - 「設定 > キーバインド > ハンズフリーを有効化」に `F13` を割り当てる
- Muse: [公式配布](https://ai.meta.com/muse/download/)からダウンロードし、`Muse.app` を `/Applications` に配置する
  - Homebrew 版は署名付き URL に対応できず無効化されている
- システム設定 > プライバシーとセキュリティ
  - 必要なアプリにフルディスクアクセス・アクセシビリティ・入力監視を許可
  - ログイン項目の登録には、オートメーションで System Events を許可
- システム設定 > 一般 > ログイン項目と拡張機能
  - 「ログイン時に開く」: Stats の登録を確認
  - 「アプリのバックグラウンドでのアクティビティ」: Karabiner・Logi Options+・Logitech Inc をオン
  - 拡張機能 > Driver Extensions: Karabiner DriverKit VirtualHIDDevice をオン
- システム設定 > メニューバー: アプリの表示を許可
- メニューバーの日本語入力メニュー > ユーザ辞書を編集
  - `しかく` → `■` / `ほし` → `★` / `やじるし` → `→` / `かっこ` → `「」` を登録
- Claude Code の Claude in Chrome
  - Edge で Chrome ウェブストアから [Claude 拡張機能](https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn) を追加し、Claude Code と同じアカウント・組織でログインする
  - Claude Code で `/chrome` を実行し、既定で有効にする項目を選ぶ
  - 初回に拡張機能が検出されなければ Edge を再起動する
- Claude Code の Playwright MCP
  - Claude Code の初回起動後、`claude plugin install playwright@claude-plugins-official --scope user` で導入する
  - Chrome 用は `claude mcp add --scope user playwright-chrome -- npx @playwright/mcp@latest --cdp-endpoint=chrome` で登録する
  - Edge の `edge://inspect/#remote-debugging` で「Allow remote debugging for this browser instance」を有効にする
  - Chrome を使う場合は `chrome://inspect/#remote-debugging` でも同じ項目を有効にする
  - 接続時にブラウザの確認ダイアログが表示されたら、接続を許可する
- GitHub Copilot CLI の Playwright MCP
  - Edge 用は `copilot mcp add playwright -- npx @playwright/mcp@latest --cdp-endpoint=msedge` で登録する
  - Chrome 用は `copilot mcp add playwright-chrome -- npx @playwright/mcp@latest --cdp-endpoint=chrome` で登録する

### Logi Options+

1. マウスの共通設定で、既定の「戻る」に `End`、「進む」に `Home` を割り当てる
2. Orca のアプリ別設定で「戻る」に「末尾に移動」(`Ctrl+End` → `Cmd+↓`)、「進む」に「先頭に移動」(`Ctrl+Home` → `Cmd+↑`) のマクロを追加する
3. 各マクロの各キー操作直前に `21ms` の待機を入れる

### キーボード

- 外付けキーボードは Mac モードを使う

#### Keychron K8 Pro のレイアウト

1. USB 接続し、本体を Cable・Mac モードにする
2. [VIA](https://usevia.app/) の Save + Load で[レイアウト](macos/keychron_k8_pro_ansi_rgb.layout.json)を読み込む
   - 機種定義が必要なら、[Keychron 公式配布](https://www.keychron.com/pages/firmware-and-json-files-of-the-keychron-qmk-k-pro-and-k-max-series-keyboards)の K8 Pro ANSI RGB v1.7 を使う
3. Karabiner の Keychron 機器設定で Simple Modifications を空にする
4. 左 Ctrl 位置でのコピー、かな・英数、F13、Fn 音量操作を確認する
