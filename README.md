# dotfiles

個人環境向けの dotfiles です。
`install.sh` がリポジトリ内の管理対象ファイルを `$HOME` 配下へシンボリックリンクとして配置します。

## インストール

```sh
./install.sh --dry-run   # 事前確認のみ
./install.sh             # リンク作成
```

既存の通常ファイルは `~/.dotfiles-backup/<timestamp>/` へ退避し、既存のシンボリックリンクはリンク先が異なる場合のみ張り替えます。
バックアップは最新 5 世代のみ保持し、新しい退避が発生した実行時にそれより古い世代を削除します。
管理対象の一覧は `install.sh` の `files` 配列を参照してください。

## Codex のシステム設定

`install.sh` は Codex のベース設定を `/etc/codex/config.toml` へ sudo でシンボリックリンクします。
ローカルユーザー設定は `~/.codex/config.toml` に置き、このリポジトリでは管理しません。
