# セキュリティポリシー

サポート対象はデフォルトブランチの最新版のみ。

## AI エージェントからの機密情報遮断

禁止・許可・承認条件は [共通規約](.config/agents/AGENTS.md) に従う。
秘密値の直接取得・持ち出し、重大な破壊、保護機構の迂回を制限し、認証済み CLI の内部認証は許可する。
ユーザー承認と規約に従う運用であり、改ざん耐性のある実行時境界ではない。

- [共通 PreToolUse ガード](.claude/hooks/pre-bash-guard.py): コマンド・直接渡したコードや設定から、既知の危険操作を拒否する
- [Claude Code の設定](.claude/settings.json): 固定コマンドと認証情報の `Read` を拒否する
  - 同じパスへの Edit / Write・認識可能な Bash ファイル操作も対象とし、任意スクリプト・CLI 内部の間接アクセスには適用しない
- [Codex の権限](.config/codex/config.toml): ルートの読み書き・ネットワークを許可し、エージェント自身の認証情報・バックアップ、shell 履歴・snapshot を固定 deny にする
  - アカウント別保存先も対象とし、会話履歴・session transcript・file history・paste cache は固定 deny にしない

フックはエージェント・permission mode によらず deny だけを返し、それ以外は無出力で通常の権限判定へ委ねる。
起動失敗・不正入力・内部エラーは終了コード `2` で拒否し、有効な未対応構文は通常の判定へ進める。
Claude Code は `auto` mode で、個別の `Bash` allow を置かず、hard deny 以外を classifier が判断する。
filesystem sandbox は CLI の設定・認証ストア・ネットワークを妨げるため無効とし、`excludedCommands` やドメイン・パス allowlist は設けない。

外部 CLI が使う認証ストア・秘密鍵・`.env`・Keychain などは Codex の filesystem deny に入れず、直接取得を規約とガードで拒否する。
Codex 自身の認証は `~/.codex/auth.json` に保存し、Codex の filesystem deny と Claude Code の `Read` deny で保護する。
Codex の shell snapshot は無効化し、Claude Code の snapshot は直接参照を拒否する。

**ガードは任意コードの隔離境界ではない。**
保存済み script・通常ファイルの `source`・間接生成したコードやパス・未知 CLI/API・ディレクトリ内の資格情報を網羅しない。
継承した非秘密の認証・実行設定は利用者管理として信頼し、内容を検査しない。
コマンドが通過しても安全性や承認を保証せず、秘密値への到達を防ぐには秘密を返さない broker・別ユーザー・コンテナ・VM などの隔離が必要になる。

## 運用上の制約

- 認証情報の平文を環境変数に設定しない新規ターミナルから起動し、認証を credential helper・Keychain・認証エージェントへ委譲する
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` は既定以外の permission mode と競合するため使わない
- ホーム外では Claude Code をプロジェクトルートから起動する
- Codex の固定 deny は書き込み・移動・削除も拒否するため、対象データの更新はユーザーが端末で行う
- Claude Code の `bypassPermissions` はコンテナ・VM などの隔離環境だけで使う
- `GIT_TERMINAL_PROMPT=0` と `AWS_PAGER=""` を維持し、認証待ち・対話処理を防ぐ
- Codex は非秘密の認証・実行設定と保存先を継承し、秘密値名だけを filter する
  - `TOKEN_FILE` なども落とす既定除外は使わない
  - JSON とパスを兼用する `GOOGLE_CREDENTIALS` は除外し、パスは `GOOGLE_APPLICATION_CREDENTIALS` で渡す

### GitHub と AWS の認証

- GitHub は SSH へ移行せず、HTTPS と `gh auth git-credential` を使う
  - 通常の Git helper と `gh` は `gh auth login` の認証を使う
  - 組織固有 URL の Git helper だけ非公開設定で `ghtkn git-credential` に切り替え、8 時間で失効する User Access Token を使う
  - `ghtkn` は実行元の競合を避けるため mise だけで導入する
- `gh auth login`・`ghtkn auth` など秘密を出さない認証状態変更はガードで許可し、事前確認は共通規約に従う
  - token を出力する `op signin` は拒否する
- AWS は `aws-use` で `AWS_PROFILE` を切り替え、認証情報を環境変数へ展開する `aws-env` は使わない
  - 一時認証情報をシェルへ載せず、既存の credential provider 環境変数も値を展開せず設定有無だけ確認する
- `~/.aws/config` は [秘密値も保存できる](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html)ため、SSO の非秘密設定だけでも全文を直接読まない
  - AWS CLI の内部利用と `aws configure get region` など非秘密の項目参照は許可する
  - `~/.aws/login`・CLI alias を含む AWS 管理下のパスは filesystem deny に入れない

### 保護設定の変更

認証情報パスを変更する際は、適用範囲に応じて共通規約・Claude Code の `Read` deny・共通ガードを更新する。
`.env` で始まる雛形も保護し、`~/**/.env.*` は維持する。
雛形には `env.example` などを使う。

- Claude Code のユーザー設定では、ホーム以下を `Read(~/**/...)`、起動・現在ディレクトリ直下を `Read(./...)` で指定する
- `Read(/...)` は `~/.claude` 相対、システム絶対パスは `Read(//...)` とする
- macOS の `/etc` は symlink のため、固定パスは必要に応じて `/private/etc` も deny する
- `Bash(...)` の `*` は末尾だけに置く（途中でも前方一致しか効かないため）
- Codex の filesystem deny に外部 CLI が利用しうる認証材を追加しない

## 未完了の対策

以下は未実施で、記載した残存リスクを受容する暫定運用。

- 管理設定の root 所有化・managed-only lock: Claude Code の設定は通常ファイル、フックは追跡ファイルへの symlink のため、エージェントが制限自体を編集できる
- Keychain IPC の OS 拒否・別ユーザー境界: 標準の `security` 秘密出力は拒否するが、Security.framework の直接呼び出しは判定できない
  - 共通規約の絶対禁止と会社の EDR による検知・確認を前提とする
- Git の追跡済み内容・履歴の安全な仲介: 既知パスの直接取得は拒否するが、パスなしの広い差分・履歴参照、blob ID・glob・pathspec magic は網羅しない
  - 秘密を commit しないことが前提で、誤 commit 後の Git object database からの除去・表示の仲介は未導入
- AWS の署名ブローカー・隔離 runner、GitHub 認証の broker / wrapper: CLI が SSO キャッシュや認証ストアへ直接到達できる
  - `credential_process` が生の認証情報を AI 制御下へ返すだけの構成は最終解としない
- AI 専用 Docker デーモン・VM: ホストのソケットへ接続する
  - 既知の資格情報・保管先・socket の直接指定は拒否するが、通常フォルダの再帰走査や Compose・`.dockerignore` の評価は行わず、build context・mount への資格情報混入リスクが残る
- AI 専用 Chrome プロファイル・Computer Use の固定承認: 個人用プロファイルを接続しない前提を運用で守り、macOS 全アプリ共通の固定承認は未導入
- コマンド・インタプリタの OS 隔離: Claude Code の Bash と Codex のコマンドを隔離していない
  - `terraform plan` / `apply` などのプラグインや動的コードも、限定 wrapper・broker・隔離 runner が必要
- ブローカーの検証: socket の最終 allowlist と実認証を伴うエンドツーエンド検証は未実施

Chrome 拡張・外部ブラウザ機能は有効で、[Browser 設定](.codex/browser/config.toml)はサイト利用・履歴取得・ファイル転送を `never_ask` で自動承認し、CDP フルアクセスも有効。
Computer Use は別の承認境界で、`Always allow` を選んだアプリは以後の確認を省略する。
ログイン済みサイトの表示内容・セッション権限による操作と、履歴取得・ファイル転送の確認省略は残存リスクとする。

## 非公開での報告

脆弱性・認証情報の露出は、公開 Issue ではなく [GitHub の非公開脆弱性報告](https://github.com/pych-ky/dotfiles/security/advisories/new)へ報告する。
秘密情報そのものは記載せず、分かる範囲で再現手順・影響範囲・修正案を記載する。
報告確認後、必要に応じて修正・認証情報の失効またはローテーションを行う。
