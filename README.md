# dotfiles

個人環境向けの dotfiles です。
`bootstrap.sh` が macOS 設定、dotfiles のシンボリックリンク展開、Homebrew と各種 CLI の導入までをまとめて行います。

## セットアップ

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

実行内容は次の通りです。各ステップは冪等なので途中で失敗しても再実行できます。
致命ではない失敗 (廃止された cask やリンク競合など) は警告を出して続行します。

1. sudo 認証を行う (パスワード入力はここでの 1 回だけ、完了まで keep-alive)
2. `macos/defaults.sh` で macOS 設定を適用する
3. `install.sh` で dotfiles のシンボリックリンクを展開する
4. Homebrew を導入する (未導入時、Xcode Command Line Tools も同時に導入)
5. `Brewfile` に基づいて CLI / GUI アプリを一括インストールする
6. zsh プラグイン (zsh-autosuggestions, fast-syntax-highlighting) を取得する
7. Claude Code CLI と Codex CLI を導入する (未導入時)

終了後は下記の「手動セットアップ」を実施してください。

## 個別実行

### install.sh (シンボリックリンク展開)

```sh
./install.sh --dry-run   # 事前確認のみ
./install.sh             # リンク作成
```

- 既存の通常ファイルは `~/.dotfiles-backup/<timestamp>/` へ退避する
  - バックアップは最新 5 世代のみ保持する
- 既存のシンボリックリンクはリンク先が異なる場合のみ張り替える
- `.config/karabiner` はディレクトリごとリンクする
  - karabiner.json 単体の symlink では Karabiner が設定変更を検知できないため
- Codex のベース設定は `/etc/codex/config.toml` へ sudo でシンボリックリンクする
  - 端末ごとのローカル設定を `~/.codex/config.toml` で上書きできるようにするため
- 管理対象の正確な一覧は `install.sh` の `files` 配列を参照する

### Brewfile (パッケージ管理)

```sh
brew bundle --file=Brewfile           # 一括インストール
brew bundle check --file=Brewfile     # 不足パッケージの確認
brew bundle cleanup --file=Brewfile   # Brewfile にないパッケージの確認 (削除は --force)
```

### macos/defaults.sh (macOS 設定)

```sh
./macos/defaults.sh
```

- macOS のデフォルト値から意図的に変更している項目のみを `defaults write` で適用する (キーボードリピート速度、Dock、Finder、日本語入力など)
- Rectangle の設定はエクスポート済みの `macos/rectangle.plist` を import して適用する
- 電源管理 (`pmset`) の変更は認証済みの sudo (`sudo -n`) で実行する
- 日本語入力・外観 (ダークモード)・ファンクションキーの設定は再ログイン後に反映される

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
- 認証情報 (`~/.ssh`、`~/.aws` のクレデンシャル、gh のトークンなど): 1Password 等で別途移行する
- VS Code の設定・拡張: VS Code Settings Sync で同期する
