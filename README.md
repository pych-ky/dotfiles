# dotfiles

個人環境向けの dotfiles です。
新しい Mac では `bootstrap.sh` が Homebrew の導入からパッケージ・シンボリックリンク・macOS 設定の適用までを一括で行います。

## セットアップ (新しい Mac)

```sh
git clone <このリポジトリ> && cd dotfiles
./bootstrap.sh
```

実行内容は次の通りです。各ステップは冪等なので途中で失敗しても再実行できます。

1. Homebrew の導入 (未導入時、Xcode Command Line Tools も同時に導入)
2. `Brewfile` に基づく CLI / GUI アプリ / npm グローバルの一括インストール
3. zsh プラグイン (zsh-autosuggestions, fast-syntax-highlighting) の取得
4. `install.sh` による dotfiles のシンボリックリンク展開
5. `macos/defaults.sh` による macOS 設定の適用
6. Claude Code CLI の導入 (未導入時)

終了後は下記の「手動セットアップ」を実施してください。

## 個別実行

### install.sh (シンボリックリンク展開)

```sh
./install.sh --dry-run   # 事前確認のみ
./install.sh             # リンク作成
```

既存の通常ファイルは `~/.dotfiles-backup/<timestamp>/` へ退避し、既存のシンボリックリンクはリンク先が異なる場合のみ張り替えます。
バックアップは最新 5 世代のみ保持し、新しい退避が発生した実行時にそれより古い世代を削除します。
管理対象の一覧は `install.sh` の `files` 配列を参照してください。

### Brewfile (パッケージ管理)

```sh
brew bundle --file=Brewfile           # 一括インストール
brew bundle check --file=Brewfile     # 不足パッケージの確認
brew bundle cleanup --file=Brewfile   # Brewfile にないパッケージの確認 (削除は --force)
```

新しくツールを入れたら `Brewfile` にも追記して同期を保ちます。

### macos/defaults.sh (macOS 設定)

macOS のデフォルト値から意図的に変更している項目のみを `defaults write` で適用します。
キーボードリピート速度、Dock、Finder、日本語入力、Rectangle の設定などを含みます。
電源管理 (`pmset`) の変更に sudo が必要です。
日本語入力・外観 (ダークモード)・ファンクションキーの設定は再ログイン後に反映されます。

## Codex のシステム設定

`install.sh` は Codex のベース設定を `/etc/codex/config.toml` へ sudo でシンボリックリンクします。
ローカルユーザー設定は `~/.codex/config.toml` に置き、このリポジトリでは管理しません。

## 手動セットアップ

スクリプト化できない (またはあえてしていない) 項目:

- システム設定
  - プライバシーとセキュリティ > フルディスクアクセス / アクセシビリティ (Claude など必要なものだけ)
  - 一般 > ログイン項目と拡張機能
  - サウンド > 入出力デバイスの指定
  - マウス > 軌跡の速さ (defaults.sh の値を好みに応じて調整)
  - キーボード > テキスト入力 > テキスト置換 (ユーザー辞書)
    - `しかく` → `■` / `やじるし` → `→` / `かっこ` → `「」`
  - ロック画面 > ディスプレイをオフにするまでの時間 (defaults.sh では「オフにしない」を設定)
- Finder > 設定 > サイドバー > ホームにチェック
- Karabiner-Elements: Devices で使用中のキーボードを対象化
- VS Code: Settings Sync にサインイン (設定・拡張はこのリポジトリでは管理しない)
- 各種アカウントへのサインイン: 1Password / Raycast / Slack / Notion など
- 個別インストーラ: プリンタドライバ / VPN クライアント / エレコム マウスアシスタント / Typeless

## このリポジトリで管理しないもの

- Git の設定 (`~/.gitconfig`)・gh (GitHub CLI): 端末ごとに個別設定する
- 認証情報 (`~/.ssh`、`~/.aws` のクレデンシャル、gh のトークンなど): 1Password 等で別途移行する
- VS Code の設定・拡張: VS Code Settings Sync で同期する
