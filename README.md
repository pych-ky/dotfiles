# dotfiles

macOS・シェル・開発ツール・AI エージェントの個人用設定。

## 一括セットアップ

macOS、対話可能なローカル端末、`sudo` 権限が必要。
スクリプト自体には `sudo` を付けない。

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

Homebrew（未導入時は Xcode Command Line Tools も）と不足ツールを導入する。
Homebrew が認証キャッシュを無効化するため、冒頭の `sudo` 認証後も再認証を求められる場合がある。
終了状態が 0 でも失敗内容と `skipped steps` を確認し、原因・認証・前提を整えて再実行する。
完了後は「[手動セットアップ](#手動セットアップ)」へ進む。

設定の多くはシンボリックリンクで、編集は実環境にも反映される。
公開できない情報は「[非公開設定](#非公開設定dotfiles-private)」で管理する。

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

### GitHub の認証

通常の Git / `gh` は HTTPS と `gh` の保存済み認証を使う。

```sh
gh auth login --hostname github.com --git-protocol https
```

組織固有 URL に [ghtkn](https://github.com/suzuki-shunsuke/ghtkn) の helper を使う端末は、非公開設定に従って追加認証する。

```sh
ghtkn init   # 対象の GitHub App の Client ID を設定する
ghtkn auth   # デバイスフローで認証する
```

両 CLI とも、URL の手動起動と Enter による自動起動を重ねない。
`gh auth login` はコードのコピー後に Enter を押す。

## 非公開設定（dotfiles-private）

**このリポジトリは公開。**
組織固有設定・非公開の個人情報は `dotfiles-private` で管理する。
`bootstrap.sh` はアクセス可能な場合だけ取得して `setup.sh` を実行する（`DOTFILES_PRIVATE_SKIP=1` で省略）。

- `~/.gitconfig.local`: `user.name` / `user.email`（自動推測は無効）、組織固有の `includeIf`・認証 helper
- `~/.zshrc.local` / `~/.bashrc.local`: シェルの個別設定
- `~/.config/dotfiles/denylist.txt`: 公開リポジトリへの混入防止パターン（未配置時は組織固有文字列を検査しない）
- `~/.config/dotfiles/work-remotes.txt`: 組織の remote URL の識別条件

認証情報は非公開リポジトリにも置かず、1Password などで移行する。
GitHub 認証は端末ごとに取り直す。
`~/.kube`・`~/.docker` などの機密・端末固有データや、AI エージェントのアカウント固有接続は管理対象外。

## AI エージェントの起動と注意事項

平文の認証情報を環境変数に設定せず、新しいターミナルから起動する。

```sh
claude
codex
```

任意コードの隔離はなく、ブラウザのサイト操作・履歴取得・ファイル転送は自動承認される。
認証・承認の規約、保護範囲と残存リスクは [SECURITY.md](SECURITY.md) を参照。

## 個別セットアップ

### シンボリックリンク

```sh
./scripts/link-dotfiles.sh --dry-run   # 事前確認のみ
./scripts/link-dotfiles.sh             # リンク作成
```

既存の通常ファイル・ディレクトリは `~/.dotfiles-backup/<timestamp>[-<sequence>]/` に退避し、スクリプトが作成した最新 5 世代を保持する。
差異を警告されたら、端末の変更をリポジトリか `~/.zshrc.local` などへ統合して再リンクする。

- `~/.claude/settings.json`: コピー（既存設定は `jq` で公開側を優先してマージし、同じ ID がない個人のプラグイン・marketplace は保持）
- `~/.codex/browser/config.toml`: コピー
- `/etc/codex/config.toml`: リンク（`~/.codex/config.toml` で上書き可能）

端末固有設定の旧 `sandbox_mode` / `[sandbox_workspace_write]` は削除する。
`sandbox_mode` が残ると公開側の `default_permissions` が使われない。

#### Codex App の権限

リンク後は Codex を終了し、各端末の承認メニューで「保護付きフルアクセス」を選び、新しいタスクを開始する。
最後に選んだ権限が `default_permissions` より優先され、既存タスクは承認方式を引き継ぐ。
組み込みの「フルアクセス」は `approval_policy = "never"` で上書きし、承認が必要な Computer Use の接続も拒否される場合がある。

### Git 共通設定

Git 2.37 以上が必要。

```sh
./scripts/setup-git.sh
```

`~/.gitconfig` 全体は置き換えず、共通項目とグローバルフックを設定する。
認証は「[GitHub の認証](#github-の認証)」に従い、push URL を含め URL にトークン・パスワードを埋め込まない。
secretlint が未導入・実行不能でもコミットを止める。
単独導入は設定のリンク後に行う。

```sh
mise install aqua:secretlint/secretlint
```

### Homebrew パッケージ

```sh
brew bundle --no-upgrade --file=macos/Brewfile       # 不足パッケージのインストール
brew bundle upgrade --file=macos/Brewfile            # 管理対象パッケージのアップグレード
```

`bootstrap.sh` は一括アップグレードしないが、Homebrew 本体・パッケージ情報・不足パッケージの依存関係は更新される場合がある。
任意の GUI アプリは [Brewfile](macos/Brewfile) のコメントアウトを外して `brew bundle` を再実行するか、別途導入する。

### シェルのファジー検索

新しいターミナルで `cghq`（Zsh では `Ctrl+G` も可）を使い、ghq 管理のリポジトリを検索して移動する。
`cghq dotfiles` のように初期検索語を指定できる。

### macOS と Typeless

```sh
./macos/defaults.sh
./macos/setup-typeless.sh
```

日本語入力・外観・ファンクションキーは再ログイン後に反映される。
電源管理の変更には事前の `sudo` 認証が必要。

Typeless の設定には macOS・`jq` が必要で、[管理する設定](macos/typeless.json)だけを反映する。
変更時は Typeless を終了し、旧ショートカットの移行を求められたら一度起動・終了して再実行する。

### キーボード

共通設定は [Karabiner](.config/karabiner/karabiner.json)、ターミナルは [WezTerm](.wezterm.lua)、VS Code は Settings Sync で管理する。

- 左 Control / Option / Command → Command / Control / Option、Caps Lock → Control
- 右 Command / Option → かな / 英数
- `Cmd+Space` → Raycast
- WezTerm・VS Code 統合ターミナルの `Cmd+C` → 選択中はコピー、未選択時は処理中断

`Cmd` は OS に送るキーで、Windows の左 Ctrl 位置で操作できる。
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

Git・jq・macOS 標準の `lockf` が必要。

```sh
./pets/setup.sh
```

`${CODEX_HOME:-$HOME/.codex}` に導入し、再実行時は既存ペットをその配下の `pets/.backups` に退避して置き換える。
導入後は Codex の `Settings → Pets` で `Refresh` を実行する。

#### 更新

以下を実行し、dotfiles に戻って `./pets/setup.sh` を再実行する。

```sh
cd "${CODEX_CUSTOM_PETS_REPO_DIR:-$HOME/ghq/github.com/pych-ky/codex-custom-pets}"
git switch main
git pull --ff-only
```

### 非公開 Agent Skills

```sh
./skills/setup.sh
```

`~/.agents/skills`・`~/.claude/skills` にリンクし、同名の未管理オブジェクトは上書きしない。
導入後は新しい Codex セッションで確認する。
選択・単体導入・クラウドルーティン・自動委譲の設定は [Agent Skills の README](https://github.com/pych-ky/agent-skills#readme) を参照。

#### 更新

```sh
repository_dir="${AGENT_SKILLS_REPO_DIR:-$HOME/ghq/github.com/pych-ky/agent-skills}"
git -C "$repository_dir" pull --ff-only
"$repository_dir/setup.sh"
```

### Pets・Skills の導入設定

既存チェックアウトは自動更新しない。
初回アクセス失敗時は既定で警告してスキップする。
`CODEX_CUSTOM_PETS_SKIP=1` / `AGENT_SKILLS_SKIP=1` で導入から除外できる。
取得先やアクセス失敗をエラーにする設定は [Pets](pets/setup.sh) / [Skills](skills/setup.sh) を参照。
