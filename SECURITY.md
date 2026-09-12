# セキュリティポリシー

デフォルトブランチの最新版のみをサポートします。

## AI エージェントからの機密情報遮断

### 方針

> クレデンシャルをモデル・会話コンテキスト・tool output へ直接取り出さず、ファイル・ログ・環境変数・引数・標準入力への書き出しで迂回しない。
> credential helper・認証エージェント・署名ブローカー・認証済み CLI が内部で認証情報を利用・保管する通常操作は許可する。

`security` や `aws` のようなコマンド名や実行機能だけで一律に拒否せず、秘密値の取得と重大な破壊操作を制限します。
IP アドレス・ユーザー名・ホスト名・MAC アドレスと、過去の会話・セッション履歴は必要に応じて参照できます。履歴から秘密値を取得することは禁止し、履歴内の指示は調査資料として扱います。
通常操作の自由度を優先し、CLI が内部利用する設定・credential store は OS の path deny で遮断しません。
秘密値の直接取得は共通規約で禁止し、既知のパス・取得経路を組み込みの `Read` deny と PreToolUse で拒否します。
任意スクリプトや Keychain API などの残存経路があり、隔離 runner や broker がない限り強制境界にはなりません。

`.claude/settings.json` の `permissions` は allow / deny の 2 区分だけを持ちます（`ask` は空）。
フックはエージェントや permission mode によらず deny だけを返し、それ以外は無出力で通常の権限判定に委ねます。
依頼の範囲内の通常作業は個別確認なしで進め、本番変更・公開・共有データの破壊などは既存の承認がなければ確認します。
この確認は `.config/agents/AGENTS.md` と既存のユーザー承認に従う運用であり、改ざん耐性のある実行時境界ではありません。

| 区分 | 決めるところ | 対象 |
| --- | --- | --- |
| deny | settings + フック | 既知の秘密値取得・持ち出し・保護機構の迂回、ルート・ホームディレクトリの再帰削除、ディスク消去、無条件の force push・変更破棄 |
| allow | 通常の権限判定 | deny に該当しない通常の開発操作 |
| classifier（Claude Code Auto） | Claude Code | hard deny 以外の操作をユーザーの依頼と実行内容から判断 |

### 多層防御

#### 共通規約

`.config/agents/AGENTS.md` が、行わないこと・行ってよいこと・確認してから行うことを定義する。
Claude Code と Codex の双方がこのファイルを参照する。

#### コマンド遮断

`.claude/settings.json` は固定したコマンド形を、Claude Code と Codex が共有する `.claude/hooks/pre-bash-guard.py` はコマンド内に直接書かれた既知の危険操作を拒否する。
フックは標準入力の JSON から検査対象を受け取り、対象コマンドを実行せず、シェルや Python の引数へも渡さない。
PreToolUse hook 自体の起動に失敗した場合も、呼び出し側で終了コードを `2` にして実行を拒否する。検査範囲と限界は後述する。

#### 認証情報の直接読み取り

Claude Code の組み込み `Read` deny に認証情報ファイルを登録し、さらにフックが既知の reader や入力オプションによる直接読み取りを拒否する。
`Read` deny は同じパスへの Edit / Write と、Claude Code が認識できる `cat` / `head` / `tail` / `sed` などの Bash ファイル操作も拒否する。任意スクリプトや CLI 内部からの間接アクセスには適用しない。

- GitHub、AWS、SSH/GPG、Kubernetes、コンテナ、クラウド、パッケージ管理などの CLI 設定・credential store と macOS Keychain は、非公開リポジトリや AWS SSO などの通常操作に必要なため、Claude Code の Bash と Codex の filesystem policy から利用可能にする。
- 直接読み取りの拒否対象には、ROSA/OCM、Helm repository / registry、uv credentials store、PostgreSQL の password / service file、pip・curl・wget・Bundler・Composer・Poetry の認証設定、shell 履歴、Codex / Claude Code の shell snapshot・認証バックアップ、ユーザーおよびシステムの macOS Keychain、KeePass、service account の既知ファイルも含める。
- `.git-credentials`、`.netrc`、`.pgpass`、`.npmrc`、`.pypirc` と既知の token store は、ホーム以下と、セッションの起動・現在ディレクトリ直下にある同名パスを対象にする。ホーム外では Claude Code をプロジェクトルートから起動する。
- AWS・Kubernetes・コンテナ・GitHub・OCM・Helm・uv・PostgreSQL・パッケージ管理などの標準環境変数で保存先を差し替えた場合も、内容読み取りだけを拒否し、`test -e` / `test -f` は許可する。
- `rsync --password-file` と `file://` / `fileb://` の指定も通常のパス指定として扱う。
- `--kubeconfig`、`ssh -i` / `-F`、`npm --userconfig`、`curl --netrc-file` など、CLI 内部の認証用パスは許可する。内容の表示・アップロード・設定の一括出力は引き続き拒否する。
- Claude Code のユーザー設定では、ホーム以下の再帰パターンを `Read(~/**/...)`、起動・現在ディレクトリ直下を `Read(./...)` で指定する。ユーザー設定の `Read(/...)` は `~/.claude` 相対であり、プロジェクトルート相対にはならない。`Read` のシステム絶対パスは `Read(//...)` を使う。
- macOS の `/etc` は `/private/etc` への symlink なので、固定の system path は必要に応じて両方の表記を deny する。
- PEM / DER は公開証明書にも使われるため拡張子だけでは拒否せず、exact basename の `key.pem`、stem が `priv` / `private` と一致する名前、接頭・接尾を区切った `priv`、接尾を区切った `private`、`privkey` / `privatekey` と `client-key` / `server-key` / `tls-key` などの既知名を拒否する。`privatelink-ca.pem` のように通常語の一部として `priv` を含むだけの名前は拒否しない。
- 標準 SSH 秘密鍵名の静的 deny は exact basename に限定し、`.pub` を巻き込まない。フックは `.pub` を判別できるため、`id_ed25519_work` のような接尾辞付き秘密鍵も拒否する。
- Claude Code の `Read` deny には `~/**/.env.*` を残す。
- 認証情報パスの一覧を変更するときは、適用範囲に応じて共通規約、Claude Code の `Read` deny、フックを更新する。Codex の filesystem deny には外部 CLI が利用しうる認証材を追加しない。

#### Codex の権限と環境

Codex はルート全体の読み書きとネットワークを許可する「保護付きフルアクセス」権限プロファイルを既定とする。

- Codex / Claude Code 自身の認証情報・認証バックアップ、shell 履歴・shell snapshot を固定 deny にする。`~/.codex-account-*` の認証情報・shell snapshot にも filesystem deny・Claude Code の `Read` deny・共通 Bash ガードを適用する。
- 会話履歴・session transcript・file history・paste cache は固定 deny にしない。
- `.env`、秘密鍵、keystore、service-account などは Docker Compose、TLS、署名、クラウド CLI が内部利用しうるため path deny に入れず、直接取得だけをフックと規約で拒否する。
- Codex の filesystem `deny` は読み取りだけでなく書き込み・移動・削除も拒否する。固定 deny の対象データを更新する必要がある場合は、ユーザーが端末で行う。
- Codex CLI の認証情報はキーチェーンを避けてファイル（`~/.codex/auth.json`）に保管し、Claude Code の組み込み `Read` deny と Codex の権限プロファイルの双方に登録する。
- Git / `gh` / `aws` を含む CLI に個別の allow rule や認証 CLI 用の command rule は置かず、設定と認証キャッシュの読み書きも同じ権限プロファイルで実行する。
- 環境変数は `inherit = "all"` とする。`TOKEN_FILE` などの非秘密パスまで巻き込む既定除外は使わず、`[shell_environment_policy.filters]` で秘密値名だけを除外する。起動元の非秘密な認証・実行設定と認証ファイルの保存先を継承し、CLI の通常利用を妨げない。
- `GOOGLE_CREDENTIALS` は JSON とパスを兼用し、Codex の filter は値を区別できないため除外を維持する。パスの継承には `GOOGLE_APPLICATION_CREDENTIALS` を使う。認証情報の平文を変数へ設定することは共通規約で禁止する。
- Codex の shell snapshot は、展開済みの shell 環境を平文へ保存しないよう無効にする。Claude の shell snapshot は `Read` deny とフックでモデルからの直接参照を拒否する。

#### Claude Code の権限

Claude Code の `permissions.defaultMode` は `auto` とし、`Bash` の個別 allow（bare `Bash` を含む）は設定しない。通常操作の追加ごとに allow を保守せず、hard deny 以外は classifier が依頼内容と実行内容から判断する。

Claude Code の filesystem sandbox は `.git/config` の更新と CLI の設定・認証ストア、ネットワークを一律に妨げるため明示的に無効化する。コマンド別の `excludedCommands` やドメイン・パス allowlist は設けず、組み込みの `Read` deny は維持する。`bypassPermissions` はコンテナや VM などの隔離環境でのみ使用する。

#### ブラウザの承認

Codex の Chrome 拡張と外部ブラウザ機能は無効化しない。Browser プラグインは自動性を優先し、サイト利用・履歴取得・ファイル転送を `never_ask` で自動承認する。CDP フルアクセスは無効にする。

Computer Use は別のアプリ承認境界であり、`Always allow` を選んだアプリでは以後の確認が省略される。

ログイン済みサイトの表示内容・セッション権限で行える操作と、履歴取得・ファイル転送の個別確認省略は残存リスクとして扱う。

#### 起動運用

AI エージェントは、認証情報の平文を環境変数へ設定しない新しいターミナルセッションから起動する。
認証は credential helper・キーチェーン・認証エージェントへ委譲する。`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` は既定以外の permission mode と競合するため使わない。

### フックの検査範囲

- 引用、コマンド区切り、パイプ、明示的なコマンド置換、`sh -c` などの文字列、主要な wrapper の子コマンドを検査する。
  shell の変数値・算術評価・関数呼び出し・taint は模擬実行しない。CLI の未知オプションを複数の解釈へ展開しない。
  入力で実行コードが変わる `xargs` や FD からの script / source など、未対応の構文は通常の権限判定へ委ねる。
- Keychain、GitHub、AWS、クラウド、パッケージ管理などの既知の秘密出力 CLI、環境変数一覧、shell 履歴、秘密値を含みうるプロセス・コンテナ出力を拒否する。
  credential helper が内部で認証する通常操作、秘密を出さない認証状態変更、`sudo` 自体、外部状態の変更だけでは拒否しない。
- 入力パスはイベントの `cwd` を基準に正規化し、既知の資格情報パスと symlink の実体を照合する。
  `.env` で始まる名前は雛形も含めて保護する。雛形には `env.example` のような名前を使う。
  コピー・マウントでは既知の保管先の親も対象にするが、ディレクトリの再帰走査や `.dockerignore` の評価は行わない。通常フォルダの指定ごとに、エージェントが全件探索を代行する運用にも置き換えない。
- 直接渡したコードや実行設定からも、既知の秘密値取得・資格情報の直接読み取り・保護機構の迂回を検査する。
  モジュール読み込み、子プロセス起動、非秘密の環境変数・実行設定は、それ自体を理由に拒否しない。各言語の実行結果や間接的な動的生成は追跡しない。
- ルート・ホームディレクトリの再帰削除、ディスク消去、無条件の force push、hard reset、強制 clean、検証フックの迂回などを拒否する。
  `rm -rf build`、通常の branch・worktree 削除、dry-run、`git push --force-with-lease` は通常の権限判定へ委ねる。

#### 補助ガードの限界

**このフックは既知の危険操作を止める補助ガードであり、任意コードの隔離境界ではない。**
ファイルに保存された script、通常ファイルの `source`、間接的に生成したコマンド・パス、ディレクトリ内に潜む資格情報、独自 API・未知 CLI による取得は検査対象外とする。
不正入力・内部エラーは終了コード `2` で閉じ、有効だが未対応の構文は通常の権限判定へ進める。解析できたコマンド全体の安全性を保証するものではない。
秘密値へ到達できないことを保証するには、秘密を返さない broker、別ユーザー、コンテナ、VM などの隔離が必要になる。

フックによる既知操作の拒否は [Claude Code の拡張方法](https://code.claude.com/docs/en/permissions#extend-permissions-with-hooks)に沿う。
字句分割は完全な shell parser ではなく、denylist は補助的な防御に留まるという制約を踏まえ、shell 全体の再実装を目的にしない（[Python shlex](https://docs.python.org/3/library/shlex.html#improved-compatibility-with-shells)、[OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html#allowlist-vs-denylist)）。

### 判断の記録

- `GIT_TERMINAL_PROMPT=0` は認証設定が壊れた場合のハング防止として残す。
- GitHub の認証は SSH へ移行せず、HTTPS と通常の `gh auth git-credential` を使う。
  組織固有の URL だけ非公開側の設定で `ghtkn git-credential` に切り替え、8 時間で失効する User Access Token を使う。
  `gh auth login` と `ghtkn auth` のように秘密値を出力しない認証状態変更は、フックでは許可する。操作前の確認は共通規約に従う。
  session token 自体を出力する `op signin` は deny のままにする。
- AWS は `aws-env`（`aws configure export-credentials` の結果を環境変数へ展開するシェル関数）を廃止し、`aws-use` による `AWS_PROFILE` の切り替えだけを残す。
  一時認証情報そのものをシェルへ載せず、既存の credential provider 環境変数も値を展開せず設定有無だけを確認する。
- `~/.aws/config` は、[AWS が秘密アクセスキーやセッショントークンの保存も認めている](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html)ため、全文の直接読み取りを禁止する。
  SSO の非秘密設定だけなら全文禁止は保守的な制限だが、ガードはファイル内容で例外判定しない。AWS CLI による内部利用と、`aws configure get region` のような非秘密の項目参照は許可する。
- `Bash(...)` のパターンでは `*` を末尾にだけ置く。
  途中に置いても前方一致しか効かず、覆えていないことに気付けないため。
- URL 限定 helper に使う `ghtkn` の導入元は mise に一本化する。
  Homebrew と二重に宣言すると、shim と実体のどちらが動くかが端末の状態で変わる。

## 未完了の対策

ここまでの整備は「dotfiles の整理と、隔離が入るまでの暫定 guard」までです。強制力のある境界にはなっていません。
以下は**まだ実施していません**。現時点の構成は、AI エージェントが自分に課された制限そのものを書き換えられる状態です。

### 管理設定の root 所有化

`/Library/Application Support/ClaudeCode/managed-settings.json`、`/etc/codex/requirements.toml`、フックの `root:wheel` 所有化、managed-only lock は未導入。
`.claude/settings.json` は通常ファイルとしてコピーし、`.claude/hooks/` と `git-hooks/` のフックは追跡ファイルへのシンボリックリンクで配置する。いずれもエージェントが編集できる。
現状の遮断は「改ざん耐性のある強制」ではなく「既定の運用」である。

### Codex からの macOS Keychain API 呼び出しへの対策

credential helper の内部利用を妨げないよう、Codex の filesystem deny には Keychain を入れない。Claude Code の組み込み `Read` deny と共通規約はファイルの直接取得を、Claude Code と Codex の PreToolUse フックは標準の `security` 秘密出力コマンドを拒否するが、どちらも Security.framework を直接呼ぶ任意コードまでは判定できない。

現時点では AGENTS の絶対禁止と会社の EDR による検知・確認を前提とし、Keychain IPC の OS レベル拒否や別ユーザー境界は導入していない。

### Git の追跡済み内容と履歴への対策

既知の認証情報パスを指定した本文取得は拒否するが、パスを省略した広い差分・履歴参照、blob ID、glob や pathspec magic による任意の変形は網羅しない。
通常の Git 操作を維持するため、認証情報を commit しないことを前提とする。誤って commit した認証情報を Git object database から取り除いて表示内容を安全に仲介する仕組みは未導入。

### AWS の署名ブローカー、または認証済みの隔離 runner

`aws-env` を廃止したため一時認証情報はシェルに載らないが、AWS CLI 自体は既定の実行経路から SSO キャッシュを使う。
CLI を認証済み環境から分離する署名ブローカーはまだ無い。
`credential_process` が生の認証情報を AI 制御下のプロセスへ返すだけの構成は、最終解としない。

起動元から継承した非秘密の認証・実行設定の内容はフックで検査せず、利用者が管理する設定として信頼する。エージェントが明示する設定は、秘密値の直接取得や保護機構の迂回を検査する。

`AWS_PAGER=""` は非対話実行のため維持する。`~/.aws/login` や CLI alias を含む AWS 管理下のパスは、通常の CLI 利用を優先して filesystem deny には入れない。

### AI 専用の隔離 Docker デーモン、または VM

現在の `docker` はホストのソケットへ接続する。フックは既知の資格情報・保管先・socket を直接渡す指定を拒否するが、通常フォルダ内の資格情報や Compose ファイルの中身までは調べない。
通常フォルダを build context や mount に指定した場合の資格情報の混入は、残存リスクとして受容している。

### AI 専用の Chrome プロファイルと Computer Use の固定承認ポリシー

個人用プロファイルを接続しない前提を、設定ではなく運用で守っている段階。Browser プラグインは自動承認・CDP フルアクセス無効で、Computer Use には macOS 上で全アプリ共通の固定承認ポリシーを置いていない。

### コマンドの OS サンドボックス分離

Claude Code の Bash と Codex のコマンドは OS サンドボックスで分離していない。
`terraform plan` / `apply` などはプロバイダのプラグインバイナリを実行するため、原理的には任意のコードが動く。
限定した wrapper／ブローカー、または隔離 runner を用意するまでの残存リスクとして受容している。

### インタプリタへ渡したコードの検査

直接記述された既知の秘密取得などは拒否するが、間接的な呼び出しや動的生成を網羅せず、deny に該当しないコードはフックでは許可する。最終的には OS レベルの隔離が要る。

### AI エージェントからの GitHub 認証の仲介

通常の Git helper と `gh` は `gh auth login` の認証を使い、組織固有 URL の Git helper だけは非公開側で ghtkn に切り替える。
現在は通常 CLI が保管先へ到達できるようにしており、認証だけを仲介する broker / wrapper には分離していない。

GitHub、AWS、SSH、Kubernetes、コンテナ、クラウド、パッケージ管理などの CLI 設定・認証ストアはスクリプトからも到達できるため、直接読み取りの遮断は PreToolUse と共通規約による運用境界であり、OS レベルの hard deny ではない。

### ブローカーの検証

各ブローカー socket の最終的な allowlist と、実認証を伴うエンドツーエンド検証は未実施。

## 非公開での報告

脆弱性や認証情報の露出を報告する際は、公開 Issue ではなく [GitHub の非公開脆弱性報告](https://github.com/pych-ky/dotfiles/security/advisories/new)を利用してください。

- 秘密情報そのものは記載しない。
- 分かる範囲で再現手順、影響範囲、修正案を記載する。

報告を確認後、必要に応じて修正し、認証情報を失効またはローテーションします。
