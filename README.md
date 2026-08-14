# dotfiles

個人用の macOS 環境を構築する dotfiles です。
`bootstrap.sh` で、OS 設定、シンボリックリンク、Homebrew、CLI、Git、非公開の Codex Custom Pets と Agent Skills をまとめてセットアップします。

## 一括セットアップ

### 前提条件

- macOS
- 対話可能なローカル端末
- `sudo` を実行できるユーザー
- このリポジトリへのアクセス

`bootstrap.sh` と、そこから呼び出す `macos/defaults.sh`、`scripts/link-dotfiles.sh`、`scripts/setup-git.sh` に `sudo` を付けないでください。

### 実行

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

### 処理内容

1. `sudo` 認証を行う
2. `macos/defaults.sh` で macOS 設定を適用する
3. `scripts/link-dotfiles.sh` でシンボリックリンクを展開する
4. Homebrew を導入する。
   未導入時は Xcode Command Line Tools も導入する
5. `macos/Brewfile` に不足する CLI・GUI アプリをインストールする
6. `scripts/setup-git.sh` で Git 共通設定を適用する
7. `zsh-autosuggestions` と `fast-syntax-highlighting` を取得する
8. 未導入の Claude Code CLI と Codex CLI を導入する
9. アクセス可能な非公開 Codex Custom Pets を取得し、収録されている全ペットをインストールする
10. アクセス可能な非公開 Agent Skills を取得し、管理 CLI で同期する

終了後は「手動セットアップ」も行ってください。

### 失敗と再実行

各処理は原則として冪等なため、途中で失敗しても再実行できます。

- 実行環境の検証または最初の `sudo` 認証に失敗すると、その場で終了する
- 独立した処理は失敗を記録して続行し、最後に一覧を表示して非ゼロで終了する
- `sudo` のタイムスタンプはバックグラウンドで延長せず、終了時に無効化する
- 各特権処理は有効なタイムスタンプを再利用し、失効時や Homebrew cask の要求時は再認証する
- Homebrew、Claude Code、Codex のリモートインストーラは、取得後に実行する

## 個別セットアップ

### シンボリックリンク

```sh
./scripts/link-dotfiles.sh --dry-run   # 事前確認のみ
./scripts/link-dotfiles.sh             # リンク作成
```

- 既存の通常ファイルとディレクトリは `~/.dotfiles-backup/<timestamp>[-<sequence>]/` に退避する
- 同じ秒の再実行は連番で別世代にし、スクリプトが生成した最新 5 世代だけを保持する
- 同じ `HOME` への並行実行は排他ロックで直列化する
- 既存のシンボリックリンクはリンク先が異なる場合のみ張り替える
- Karabiner が変更を検知できるよう、`.config/karabiner` はディレクトリごとリンクする
- Codex の基本設定を `sudo` で `/etc/codex/config.toml` にリンクし、端末固有の `~/.codex/config.toml` で上書き可能にする
- 管理対象の正確な一覧は `scripts/link-dotfiles.sh` の `files` 配列を参照する

### Git 共通設定

Git 2.37 以上が必要です。

```sh
./scripts/setup-git.sh
```

`~/.gitconfig` 全体は置き換えず、共通化する以下の 11 項目だけを設定します。

- `user.name`: コミットに表示する名前を `pych_ky` にする
- `user.email`: GitHub の noreply メールを使う
- `user.useConfigOnly`: 名前やメールの自動推測を無効にする
- `fetch.prune`: `git fetch` 時に削除済みリモートブランチの追跡参照を削除する
- `init.defaultBranch`: 新しいリポジトリの最初のブランチ名を `main` にする
- `branch.autoSetupMerge`: 同名のリモートブランチだけを自動追跡する
- `push.default`: 同名のブランチだけを push する
- `push.autoSetupRemote`: 初回 push 時に `upstream` を自動設定する
- `transfer.credentialsInUrl`: `<protocol>://<user>:<password>@...` 形式の URL を拒否する（`remote.*.pushurl` とユーザー名部分だけに指定したトークンは対象外）
- `pull.ff`: 履歴の分岐時は自動マージせず停止する
- `merge.conflictStyle`: 競合時に変更前・自分・相手を表示する

### Homebrew パッケージ

```sh
brew bundle --no-upgrade --file=macos/Brewfile        # 不足パッケージのインストール
brew bundle upgrade --file=macos/Brewfile             # 管理対象パッケージのアップグレード
brew bundle check --no-upgrade --file=macos/Brewfile  # 不足パッケージの確認
brew bundle cleanup --file=macos/Brewfile             # Brewfile にないパッケージの確認 (削除は --force)
```

- `bootstrap.sh` は `formula` と `cask` を一括アップグレードしない。
  不足パッケージの依存関係は更新される場合がある
- Homebrew 本体とパッケージ情報は自動更新される

### macOS 設定

```sh
./macos/defaults.sh
```

- macOS の既定値から意図的に変える項目だけを `defaults write` で適用する。
  対象はキーボードのリピート速度、Dock、Finder、日本語入力など
- Rectangle の設定は、エクスポート済みの `macos/rectangle.plist` を読み込んで適用する
- 電源管理（`pmset`）の変更は、認証済みの `sudo`（`sudo -n`）で実行する
- 日本語入力、外観（ダークモード）、ファンクションキーの設定は再ログイン後に反映される

### 非公開 Codex Custom Pets

#### 実行と動作

`bootstrap.sh` から呼び出されますが、単独でも実行できます。

```sh
./pets/setup.sh
```

未取得の場合は、非公開リポジトリを一時ディレクトリにクローンします。
リポジトリルート、`origin`、インストーラを検証して `$HOME/src/pych/codex-custom-pets` に配置し、`bin/install-pet --all` を実行します。

Git、jq、macOS 標準の `lockf` が必要です。
`sudo` は使いません。

#### 設定

初回クローン前のアクセス確認に失敗した場合は、既定で警告してスキップします。
以下の環境変数で動作を変更できます。

- `CODEX_CUSTOM_PETS_STRICT=1`: アクセス失敗時に `bootstrap.sh` も失敗させる
- `CODEX_CUSTOM_PETS_SKIP=1`: 導入をスキップする
- `CODEX_CUSTOM_PETS_REPO_URL`: クローン元を上書きする
- `CODEX_CUSTOM_PETS_REPO_DIR`: 保存先を絶対パスで上書きする
- `CODEX_HOME`: インストール先を上書きする。
  未指定時は `$HOME/.codex` になる

#### 更新

既存のチェックアウトは自動更新しません。
`bin/install-pet --all` がない場合は、コミット `422d80e` 以降へ更新してから再実行してください。

```sh
cd "${CODEX_CUSTOM_PETS_REPO_DIR:-$HOME/src/pych/codex-custom-pets}"
git switch main
git pull --ff-only
```

再実行時は現在のチェックアウトでペットを置き換え、既存ファイルを `${CODEX_HOME:-$HOME/.codex}/pets/.backups` に退避します。
インストール後は Codex の `Settings → Pets` で `Refresh` を実行してください。

### 非公開 Agent Skills

#### 実行と動作

`bootstrap.sh` から呼び出されますが、単独でも実行できます。

```sh
./skills/setup.sh
```

未取得の場合だけ、非公開リポジトリを一時ディレクトリにクローンします。
リポジトリルート、`origin`、管理 CLI を検証して `$HOME/src/pych/agent-skills` に配置し、公開コマンド `bin/agent-skills sync` を実行します。

Codex と Claude Code への初回インストール、既存設定の再同期、詳細な検証、`doctor` は `agent-skills` 側で行います。
Git と Python 3.9 以降が必要です。
`sudo` は使いません。

#### 設定

初回クローン前のアクセス確認に失敗した場合は、既定で警告してスキップします。
以下の環境変数で動作を変更できます。

- `AGENT_SKILLS_STRICT=1`: アクセス失敗時に `bootstrap.sh` も失敗させる
- `AGENT_SKILLS_SKIP=1`: 導入をスキップする
- `AGENT_SKILLS_REPO_URL`: クローン元を上書きする
- `AGENT_SKILLS_REPO_DIR`: 保存先を絶対パスで上書きする

#### 更新と初期導入

既存のチェックアウトは `bootstrap.sh` から自動更新しません。
更新と再同期には、チェックアウト内で Agent Skills 自身のコマンドを実行します。

```sh
cd "$HOME/src/pych/agent-skills"
./bin/agent-skills update
```

Agent Skills リポジトリは dotfiles に依存せず、単体でも初期導入できます。

```sh
git clone https://github.com/pych-ky/agent-skills.git "$HOME/src/pych/agent-skills"
cd "$HOME/src/pych/agent-skills"
./bin/agent-skills sync
```

push URL を含め、URL にトークンやパスワードを埋め込まず、Git credential helper または `gh auth setup-git` を使用してください。

## 手動セットアップ

### システムとアプリ

- システム設定
  - プライバシーとセキュリティ > フルディスクアクセス / アクセシビリティ（Claude など必要なものだけ）
  - 一般 > ログイン項目と拡張機能
  - サウンド > 入出力デバイスの指定
  - キーボード > テキスト入力 > テキスト置換（ユーザー辞書）
    - `しかく` → `■` / `やじるし` → `→` / `かっこ` → `「」`
- Finder > 設定 > サイドバー > ホームにチェック
- VS Code: Settings Sync にサインイン（設定と拡張はこのリポジトリでは管理しない）
- 各種アカウントにサインイン（1Password、Slack、Notion など）
- 個別インストーラからプリンタドライバを導入

### Claude Code の Serena MCP

`bootstrap.sh` の直後は `claude` が `PATH` にないため、新しいシェルでユーザースコープへ登録します。

```sh
claude mcp add-json -s user serena '{"type":"stdio","command":"uvx","args":["-p","3.13","--from","git+https://github.com/oraios/serena","serena","start-mcp-server","--project-from-cwd","--context","claude-code","--open-web-dashboard","false"]}'
```

- 公式プラグイン版は起動引数が不足し、ツールの重複公開と手動アクティベーションが発生するため、`settings.json` で無効化している
- `claude mcp add` の `--` 区切り形式は、`-p` などの短いオプションを含むと現行 CLI の引数解析に失敗するため、`add-json` 形式を使う
- 初回起動は `uvx` の依存取得で接続がタイムアウトする場合がある。
  キャッシュ形成後に再起動する

## このリポジトリで管理しないもの

- Git の共通設定 11 項目以外（Git LFS、認証情報など）と gh（GitHub CLI）: 端末ごとに個別設定する
- Codex のローカルユーザー設定（`~/.codex/config.toml`）: 端末ごとに個別設定する
- Claude Code のユーザースコープ MCP 登録（`~/.claude.json`）: 「手動セットアップ」の手順で端末ごとに登録する
- 非公開 Agent Skills の内容: 非公開リポジトリで管理する
- 非公開 Codex Custom Pets の内容: 非公開リポジトリで管理する
- 認証情報（`~/.ssh`、`~/.aws` のクレデンシャル、gh のトークンなど）: 1Password などで別途移行する
- VS Code の設定と拡張: VS Code Settings Sync で同期する
