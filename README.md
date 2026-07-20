# dotfiles

個人環境向けの dotfiles です。
セットアップのエントリポイントはルート直下の `bootstrap.sh` です。
macOS 設定、dotfiles のシンボリックリンク展開、Homebrew と各種 CLI の導入、private Agent Skills のセットアップまでをまとめて行います。

## セットアップ

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

実行内容は次の通りです。
各ステップは原則として冪等なので途中で失敗しても再実行できます。
致命ではない失敗 (廃止された cask やリンク競合など) は警告を出して続行します。

1. sudo 認証を行い、特権処理の終了時に timestamp を無効化する
2. `macos/defaults.sh` で macOS 設定を適用する
3. `scripts/link-dotfiles.sh` で dotfiles のシンボリックリンクを展開する
4. Homebrew を導入する (未導入時、Xcode Command Line Tools も同時に導入)
5. `macos/Brewfile` に基づいて CLI / GUI アプリを一括インストールする
6. zsh プラグイン (zsh-autosuggestions, fast-syntax-highlighting) を取得する
7. Claude Code CLI と Codex CLI を導入する (未導入時)
8. private Agent Skills を取得し、管理 CLI で同期する (アクセス可能な場合)

バックグラウンドで sudo 認証を延長しないため、処理中に timestamp が失効し、後続処理で sudo が必要になった場合は再認証を求めます。

終了後は下記の「手動セットアップ」を実施してください。

## 個別実行

### scripts/link-dotfiles.sh (シンボリックリンク展開)

```sh
./scripts/link-dotfiles.sh --dry-run   # 事前確認のみ
./scripts/link-dotfiles.sh             # リンク作成
```

- 既存の通常ファイルは `~/.dotfiles-backup/<timestamp>[-<sequence>]/` へ退避する
  - バックアップは最新 5 世代のみ保持する
  - 同じ秒の再実行は連番で別世代にし、スクリプト生成分だけを整理する
- 同じ `HOME` への並行実行は排他ロックで直列化する
- 既存のシンボリックリンクはリンク先が異なる場合のみ張り替える
- `.config/karabiner` はディレクトリごとリンクする
  - karabiner.json 単体の symlink では Karabiner が設定変更を検知できないため
- Codex のベース設定は `/etc/codex/config.toml` へ sudo でシンボリックリンクする
  - 端末ごとのローカル設定を `~/.codex/config.toml` で上書きできるようにするため
- 管理対象の正確な一覧は `scripts/link-dotfiles.sh` の `files` 配列を参照する

### macos/Brewfile (パッケージ管理)

```sh
brew bundle --file=macos/Brewfile           # 一括インストール
brew bundle check --file=macos/Brewfile     # 不足パッケージの確認
brew bundle cleanup --file=macos/Brewfile   # Brewfile にないパッケージの確認 (削除は --force)
```

### macos/defaults.sh (macOS 設定)

```sh
./macos/defaults.sh
```

- macOS のデフォルト値から意図的に変更している項目のみを `defaults write` で適用する (キーボードリピート速度、Dock、Finder、日本語入力など)
- Rectangle の設定はエクスポート済みの `macos/rectangle.plist` を import して適用する
- 電源管理 (`pmset`) の変更は認証済みの sudo (`sudo -n`) で実行する
- 日本語入力・外観 (ダークモード)・ファンクションキーの設定は再ログイン後に反映される

### skills/setup.sh (private Agent Skills)

`bootstrap.sh` はこのスクリプトを呼び出します。
Agent Skills だけをセットアップし直す場合は、個別に実行できます。

```sh
./skills/setup.sh
```

未取得の場合だけ既定の private repository を `$HOME/src/pych/agent-skills` へ clone し、公開コマンド `bin/agent-skills sync` を実行します。
clone は一時ディレクトリで行い、repository root・origin・管理 CLI を検証してから配置します。
Codex と Claude Code への初回 install、既存設定での再同期、詳細な検証、doctor は `agent-skills` 側が担当します。

- 初回 clone 前のアクセス確認に失敗した場合は警告してスキップする
- このアクセス失敗も bootstrap の失敗にする場合は `AGENT_SKILLS_STRICT=1` を指定する
- Agent Skills を導入しない端末では `AGENT_SKILLS_SKIP=1` を指定する
- clone 元は `AGENT_SKILLS_REPO_URL`、保存先は絶対パスの `AGENT_SKILLS_REPO_DIR` で上書きできる
- Git と Python 3.9 以降が必要で、sudo は使用しない

既存 checkout は bootstrap から自動更新しません。
更新と再同期は checkout 内で Agent Skills 自身のコマンドを実行します。

```sh
cd "$HOME/src/pych/agent-skills"
./bin/agent-skills update
```

Agent Skills repository は dotfiles に依存せず、単体でも初期導入できます。

```sh
git clone https://github.com/pych-ky/agent-skills.git "$HOME/src/pych/agent-skills"
cd "$HOME/src/pych/agent-skills"
./bin/agent-skills sync
```

URL に token や password を埋め込まず、Git credential helper または `gh auth setup-git` を使用してください。

## 手動セットアップ

以下は手動で行う設定です。

- システム設定
  - プライバシーとセキュリティ > フルディスクアクセス / アクセシビリティ (Claude など必要なものだけ)
  - 一般 > ログイン項目と拡張機能
  - サウンド > 入出力デバイスの指定
  - キーボード > テキスト入力 > テキスト置換 (ユーザー辞書)
    - `しかく` → `■` / `やじるし` → `→` / `かっこ` → `「」`
- Finder > 設定 > サイドバー > ホームにチェック
- VS Code: Settings Sync にサインイン (設定・拡張はこのリポジトリでは管理しない)
- Claude Code: Serena MCP を下記コマンドでユーザースコープに登録する (bootstrap.sh 直後は claude が PATH に載っていないため新しいシェルで実行する)
  - 公式プラグイン版は起動引数の不足により重複ツールの公開と手動アクティベーションが発生するため、settings.json では無効化している
  - `claude mcp add` の `--` 区切り形式は `-p` などの短いオプションを含むと現行 CLI の引数解析で失敗するため、add-json 形式で登録する
  - 登録後の初回起動は uvx の依存取得により Serena の接続がタイムアウトすることがある (uv のキャッシュ形成後の再起動で解消する)

  ```sh
  claude mcp add-json -s user serena '{"type":"stdio","command":"uvx","args":["-p","3.13","--from","git+https://github.com/oraios/serena","serena","start-mcp-server","--project-from-cwd","--context","claude-code","--open-web-dashboard","false"]}'
  ```

- 各種アカウントへのサインイン: 1Password / Slack / Notion など
- 個別インストーラ: プリンタドライバ

## このリポジトリで管理しないもの

- Git の設定 (`~/.gitconfig`)・gh (GitHub CLI): 端末ごとに個別設定する
- Codex のローカルユーザー設定 (`~/.codex/config.toml`): 端末ごとに個別設定する
- Claude Code のユーザースコープ MCP 登録 (`~/.claude.json`): 「手動セットアップ」の手順で端末ごとに登録する
- private Agent Skills の内容: private repository で管理する
- 認証情報 (`~/.ssh`、`~/.aws` のクレデンシャル、gh のトークンなど): 1Password 等で別途移行する
- VS Code の設定・拡張: VS Code Settings Sync で同期する
