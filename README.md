# dotfiles

個人用の macOS 環境を構築する dotfiles です。
OS 設定、シェル、Homebrew、開発用 CLI、Git、AI エージェントをセットアップします。
アクセス可能な非公開設定・Agent Skills・Codex Custom Pets も取得して適用します。

## 一括セットアップ

macOS、対話可能なローカル端末、`sudo` を実行できるユーザー、このリポジトリへのアクセスが必要です。
以下のセットアップスクリプト自体には `sudo` を付けないでください。

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

Homebrew（未導入時は Xcode Command Line Tools も含む）、不足するアプリと開発ツールを導入し、設定を適用します。
途中で失敗した場合は、最後に表示される失敗内容を解消して再実行できます。
`skipped steps` は未実行の処理です。終了状態が 0 でも確認し、必要な認証や前提を揃えて再実行してください。
終了後は「[手動セットアップ](#手動セットアップ)」を行ってください。

設定の多くはこのリポジトリへのシンボリックリンクです。リンク後の編集は実環境にも反映されます。
認証情報、組織固有の設定、個人情報はここへ置かず、「[非公開設定](#非公開設定dotfiles-private)」に従ってください。

## 手動セットアップ

### システムとアプリ

- システム設定 > プライバシーとセキュリティで、必要なアプリだけにフルディスクアクセス・アクセシビリティ・入力監視を許可する。
  ログイン項目の登録には、オートメーションで System Events を許可する。
- システム設定 > 一般 > ログイン項目と拡張機能で、次を確認する。
  - 「ログイン時に開く」: Maccy、Rectangle、Typeless があり、Logi Options+ がない。
  - 「アプリのバックグラウンドでのアクティビティ」: Karabiner、Logi Options+、Logitech Inc をオンにする。
  - 拡張機能 > Driver Extensions: Karabiner DriverKit VirtualHIDDevice をオンにする。
- Rancher Desktop: Preferences > Application > Environment > Configure PATH を Manual にする。自動設定のままではリンク先のリポジトリへ追記される。
- [Maccy](https://github.com/p0deje/Maccy#usage): `Cmd+Shift+C` で履歴を開く。自動貼り付けには「Paste automatically」とアクセシビリティの許可が必要。
- Typeless: サインインして必要な権限を許可する。
- VS Code: Settings Sync にサインインし、コマンドパレットの「Shell Command: Install 'code' command in PATH」を実行する。
- 1Password、Slack、Notion などのアカウントにサインインする。
- Claude Code の Linear / Microsoft Docs と Codex CLI の Linear は `bootstrap.sh` で導入する。Linear の OAuth 認証は端末ごとに完了する。
- ChatGPT の Linear プラグインはアカウント単位で Install / Connect し、初回 OAuth 認証を手動で完了する。

### GitHub の認証

通常の Git / `gh` は HTTPS と `gh` の保存済み認証を使います。
AI エージェントからのログインは、利用者の依頼または承認に基づいて行います。

```sh
gh auth login --hostname github.com --git-protocol https
```

コードをコピーした後は URL を手動で開かず Enter を押すと、認証画面の重複起動を避けられます。
組織固有の URL に限って [ghtkn](https://github.com/suzuki-shunsuke/ghtkn) の helper を使う端末は、非公開側の設定に従って追加で認証してください。ghtkn は mise で導入します。

```sh
ghtkn init   # 対象の GitHub App の Client ID を設定する
ghtkn auth   # デバイスフローで認証する
```

`ghtkn auth` も URL の手動クリック・Enter・自動起動を重ねないでください。
認証は CLI や credential helper に任せ、AI エージェントへトークンを直接取り出させないでください。

## 非公開設定（dotfiles-private）

**このリポジトリは公開です。** 組織固有の設定と公開したくない個人情報は非公開の `dotfiles-private` で管理します。
`bootstrap.sh` はアクセス可能な場合だけ取得し、その `setup.sh` を実行します。不要なら `DOTFILES_PRIVATE_SKIP=1` を指定してください。

- Git の `user.name` / `user.email`、組織固有の `includeIf`・認証 helper は `~/.gitconfig.local` に置く。
- シェルの個別設定は `~/.zshrc.local` / `~/.bashrc.local` に置く。
- 公開リポジトリへの混入を防ぐパターンは `~/.config/dotfiles/denylist.txt`、組織の remote URL の識別条件は `~/.config/dotfiles/work-remotes.txt` に非公開側から配置する。
- 認証情報そのものは非公開リポジトリにも置かず、1Password などで別途移行する。GitHub 認証は端末ごとに取り直す。

`~/.kube`、`~/.docker` などの機密・端末固有ディレクトリや、AI エージェントのアカウント固有接続はこのリポジトリで管理しません。

## AI エージェントの起動と注意事項

認証情報の平文を環境変数へ設定していない、新しいターミナルセッションから起動してください。
認証は credential helper・キーチェーン・認証エージェントへ委譲します。

```sh
claude
codex
```

クレデンシャルをモデル・会話・tool output へ直接取り出すことは禁止です。認証済み CLI が内部で認証情報を利用・保管する通常操作は許可します。
設定とフックは既知の秘密取得・重大な破壊・保護機構の迂回を拒否しますが、任意コードを隔離する境界ではありません。
ブラウザのサイト操作・履歴取得・ファイル転送は自動承認されます。
運用上の制約と残存リスクは [SECURITY.md](SECURITY.md) を参照してください。

## 個別セットアップ

### シンボリックリンク

```sh
./scripts/link-dotfiles.sh --dry-run   # 事前確認のみ
./scripts/link-dotfiles.sh             # リンク作成
```

- 既存の通常ファイルとディレクトリは `~/.dotfiles-backup/<timestamp>[-<sequence>]/` に退避し、このスクリプトが作成した最新 5 世代を保持します。
  内容の差異を警告された場合は、端末ローカルの変更をリポジトリか `~/.zshrc.local` などへ統合してから再リンクしてください。
- `~/.claude/settings.json` はコピーし、再適用では公開設定を優先します。公開側に同じ ID がない個人のプラグイン・marketplace 登録は保持します。既存設定のマージには `jq` が必要です。
- `~/.codex/browser/config.toml` はコピーします。Codex の基本設定は `/etc/codex/config.toml` にリンクし、端末固有の `~/.codex/config.toml` で上書きできます。
- 端末固有設定の旧 `sandbox_mode` / `[sandbox_workspace_write]` は削除してください。`sandbox_mode` が残ると公開側の `default_permissions` が使われません。
- リンク後は Codex を終了し、新しいセッションを開始してください。

### Git 共通設定

Git 2.37 以上が必要です。

```sh
./scripts/setup-git.sh
```

`~/.gitconfig` 全体は置き換えず、共通項目とグローバルフックを設定します。
`user.name` / `user.email` は `~/.gitconfig.local` に設定してください。名前やメールの自動推測は無効です。
GitHub の通常の HTTPS 認証は `gh` に委譲します（「[GitHub の認証](#github-の認証)」を参照）。
push URL を含め、URL にトークンやパスワードを埋め込まないでください。

グローバルフックは秘密情報を検査し、リポジトリ固有フックと Git LFS のフックも実行します。
secretlint が未導入・実行不能の場合もコミットを止めます。単独で導入する場合は、設定のリンク後に実行してください。

```sh
mise install aqua:secretlint/secretlint
```

組織固有の文字列を検査する denylist は非公開側で設定します。`denylist.txt` がない端末ではこの検査は行われません。

### Homebrew パッケージ

```sh
brew bundle --no-upgrade --file=macos/Brewfile       # 不足パッケージのインストール
brew bundle upgrade --file=macos/Brewfile            # 管理対象パッケージのアップグレード
```

`bootstrap.sh` はパッケージを一括アップグレードしませんが、Homebrew 本体・パッケージ情報と、不足パッケージの依存関係は更新される場合があります。
一部の GUI アプリは [Brewfile](macos/Brewfile) でコメントアウトしています。必要に応じて別途導入するか、コメントアウトを外して `brew bundle` を再実行してください。

### macOS と Typeless

```sh
./macos/defaults.sh
./macos/setup-typeless.sh
```

macOS のキーボード、Dock、Finder、日本語入力、Rectangle などの設定を適用します。
日本語入力、外観、ファンクションキーの設定は再ログイン後に反映されます。
電源管理の変更には認証済みの `sudo` が必要です。

Typeless は macOS と `jq` が必要です。[管理する設定](macos/typeless.json)だけを反映し、アカウント別設定や機器情報は保持します。
設定を変更するときは Typeless を終了してください。旧ショートカットの移行を求められた場合は、一度起動・終了してから再実行してください。

### キーボード

共通のキー変換は [Karabiner](.config/karabiner/karabiner.json)、ターミナルは [WezTerm](.wezterm.lua) で管理します。

- 左 Control / Option / Command は Command / Control / Option に、Caps Lock は Control に変わります。
- 右 Command / Option で、かな / 英数を切り替えます。
- WezTerm・VS Code 統合ターミナルの `Cmd+C` は、選択中はコピー、未選択時は処理中断です。`Cmd` は OS に送るキーで、Windows の左 Ctrl の位置から操作できます。

外付けキーボードは Mac モードで使用してください。Windows 配列だけの機器は、Karabiner の機器別 Simple Modifications で `left_command → left_control`、`left_option → left_option` を指定します。
VS Code のキー設定は Settings Sync で管理し、このリポジトリには含めません。

#### Keychron K8 Pro 本体の移行

本体を移行する場合は、次の手順で設定します。

1. USB 接続し、本体を Cable・Mac モードにする。
2. [VIA](https://usevia.app/) の Save + Load から [移行用レイアウト](macos/keychron_k8_pro_ansi_rgb.layout.json) を読み込む。
   機種定義が必要な場合は、[Keychron 公式配布](https://www.keychron.com/pages/firmware-and-json-files-of-the-keychron-qmk-k-pro-and-k-max-series-keyboards)の K8 Pro ANSI RGB v1.7 を使う。
3. Karabiner の Keychron 機器設定では、Simple Modifications を空にする。
4. 左 Ctrl 位置でのコピー、かな・英数、F13、Fn 音量操作を確認する。

元に戻す場合は旧レイアウトを読み込み、Karabiner の Keychron 機器設定で左 Control / Option / Command をそれぞれ同じキーへ変換する 3 件を追加します。

### 非公開 Codex Custom Pets

Git、jq、macOS 標準の `lockf` が必要です。

```sh
./pets/setup.sh
```

非公開リポジトリを `$HOME/src/pych/codex-custom-pets` に取得し、収録ペットを `${CODEX_HOME:-$HOME/.codex}` にインストールします。
再実行時は既存ペットを置き換え、同ディレクトリの `pets/.backups` に退避します。
導入後は Codex の `Settings → Pets` で `Refresh` を実行してください。

#### 更新

既存のチェックアウトは自動更新しません。更新する場合は以下を実行し、dotfiles に戻って `./pets/setup.sh` を再実行します。

```sh
cd "${CODEX_CUSTOM_PETS_REPO_DIR:-$HOME/src/pych/codex-custom-pets}"
git switch main
git pull --ff-only
```

### 非公開 Agent Skills

```sh
./skills/setup.sh
```

非公開リポジトリを `$HOME/src/pych/agent-skills` に取得し、その `setup.sh` で `~/.agents/skills` と `~/.claude/skills` にリンクします。
同名の未管理オブジェクトは上書きしません。`setup.sh` は Claude のクラウドルーティン同期も行います。
導入後は新しい Codex セッションでスキルを確認してください。

スキルの選択・単体導入は [Agent Skills の README](https://github.com/pych-ky/agent-skills#readme) を参照してください。
`delegate-to-chatgpt` は通常 ChatGPT への内蔵送受信ツールがある Codex デスクトップ向けです。自動委譲する資料の許可範囲と配置手順は、同 README の「通常 ChatGPT への自動委譲」に従ってください。

#### 更新

既存のチェックアウトは自動更新しません。更新する場合は次を実行してください。

```sh
repository_dir="${AGENT_SKILLS_REPO_DIR:-$HOME/src/pych/agent-skills}"
git -C "$repository_dir" pull --ff-only
"$repository_dir/setup.sh"
```

### Pets・Skills の導入設定

Pets・Skills は初回アクセスに失敗すると、既定で警告してスキップします。
導入対象から外す場合は `CODEX_CUSTOM_PETS_SKIP=1` / `AGENT_SKILLS_SKIP=1` を指定します。
取得先の変更やアクセス失敗をエラーにする設定は [Pets](pets/setup.sh) / [Skills](skills/setup.sh) のセットアップスクリプトを参照してください。
