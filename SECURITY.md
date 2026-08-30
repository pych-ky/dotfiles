# セキュリティポリシー

デフォルトブランチの最新版のみをサポートします。

## AI エージェントからの機密情報遮断

### 方針

守るのは次の一点です。

> 認証情報の平文を、モデル・会話コンテキスト・tool output・ログ・AI が読めるファイル・環境変数・引数・標準入力へ渡さない。
> 一方で、credential helper・認証エージェント・署名ブローカーが内部で認証する通常の Git・AWS・コンテナ操作は制限しない。

そのため、`security` や `aws` のようなコマンド名だけで一律に拒否せず、秘密値を出力するサブコマンドと、そうでないサブコマンドを分けて判断します。

`.claude/settings.json` の `permissions` は allow / deny の 2 区分だけを持ちます（`ask` は空）。
確認が要る操作は、文字列規則では表記を網羅できないため、フックが実行時に `ask` を返して扱います。

| 区分 | 決めるところ | 対象 |
| --- | --- | --- |
| deny | settings + フック | 保存済みの秘密値を出力する操作、それを持ち出す操作、検査を迂回する操作 |
| allow | settings + フック | 秘密値を出力しない参照・状態確認と、通常の開発操作 |
| ask | フックのみ | 不可逆な操作と、サンドボックス外で外部やホストの状態を変えうる操作（`bypassPermissions` では deny になる） |

### 多層防御

1. 規約: `.config/agents/AGENTS.md` が、行わないこと・行ってよいこと・確認してから行うことを定義する。
   Claude Code と Codex の双方がこのファイルを参照する
2. コマンド遮断: `.claude/settings.json` は固定したコマンド形を、`.claude/hooks/pre-bash-guard.py` は引数の意味まで含む形を判断する。
  `permissions.ask` は空とし、settings は許可または拒否へ二分する。確認はフックが `ask` を返して行う。
   フックはシェルを構文解析するため、パイプ・置換・`xargs`・関数定義を挟んでも同じ判断になる
   - キーチェーン: `security find-generic-password` / `find-internet-password` の `-w` / `-g`、`security dump-keychain`、秘密鍵や identity を含みうる `security export` は deny。実効 type を `certs` / `pubKeys` と明示した公開物だけの export は allow
     `security unlock-keychain` は秘密値を出力しないため、認証状態の変更として確認へ回す。
     `security find-certificate -p` は公開証明書の PEM 出力であり秘密鍵は出さないため allow
   - GitHub / git: `gh auth token`、`gh auth status --show-token`、credential helper の直接実行（`gh auth git-credential`、`ghtkn git-credential`、`git credential fill`、`docker-credential-*`）は deny。
     認証付き proxy / HTTP header を含みうる `git config --list` と該当設定値の取得も deny。`git config --get user.name` や `--name-only` のように秘密値を返さない参照、`gh auth status` は allow
   - GitHub トークン: `ghtkn get` / `ghtkn exec` と、runner token・JIT 設定・GitHub App token などを返す静的な `gh api` の POST は deny。`ghtkn auth` などの認証状態変更は確認へ回し、`ghtkn info` は allow
   - AWS: `configure export-credentials`、秘密の設定名に対する `configure get` / `set`、`sts assume-role*`、`sts get-session-token`、`sso get-role-credentials`、ECR の login password / authorization token、`secretsmanager get-secret-value`、`kms decrypt`、`ssm get-parameter --with-decryption`、各サービスの秘密鍵・一時認証情報・署名済み URL を返す操作と、認証情報を trace に出しうる `--debug` は deny。
     AWS は静的な prefix deny では安全な `help` まで巻き込むため、フックだけで意味を判定する。`aws sts get-caller-identity` のような非秘密操作、ローカルの `help` / `--version`、標準 API の `--generate-cli-skeleton`、秘密を返さないと確認した API の `--dry-run` は allow
   - パッケージ管理: pip の `config list` / `debug` と認証を含みうる設定の `config get`、proxy 環境変数を平文表示しうる npm の `config list` / 引数なし `config get` / proxy 設定の `get`、pnpm の認証キーに対する `config get`、保存済み認証情報を返す `uv auth token` / `auth helper` は deny。通常の install、値を伏せる pnpm の一覧、非秘密設定の参照は allow
   - シークレット管理: `op read` / `op item get` / `op inject` / `op run` / `op signin`、`vault kv get` / `vault read`、`gcloud auth print-*-token`、`az account get-access-token` などは deny
   - Kubernetes / OpenShift: `kubectl` / `oc` の Secret・token 出力、`exec` / `rsh` の子コマンドによる同じ出力、`cp` による保護対象の読み出し、`oc whoami --show-token`、token 入り kubeconfig の生成、`rosa` / `ocm` の token・秘密設定と管理者パスワードの出力は deny。`kubectl get pods`、`oc get pods`、`rosa list clusters` などは allow。`oc registry login` は通常の保存先を使う形を許可し、認証ファイルの保存先を任意パスへ差し替える形だけ deny
   - 環境変数の一括出力、shell 履歴の一覧・読み込み・書き出し、`fc` による参照、他プロセスの環境変数・完全な引数の表示は deny。`printenv PATH` のような固定した安全名、履歴展開を含まない固定文字列、安全な列だけの `ps` は allow
   - Docker の未整形 `inspect` / `info` / `history` / `compose config` / `compose convert` / `stack config`、TLS 鍵を含みうる `context export`、keystore の秘密値を返す `pass get` / `pass run`、コンテナ内の環境変数一覧、完全なプロセス引数を出す `top` と `ps --no-trunc` は deny。秘密を含まない固定 format、`compose config --services` などの集約出力、安全な列だけを指定した `top`、通常の状態確認は allow
     ローカルの build context・bind mount・追加 context・ホストからのコピー元は、内容を開かずファイル名だけを走査する。`.dockerignore` で除外済みでも、保護対象名が存在する context は安全側で deny する
   - サブコマンドの判定では、値を取るグローバルオプションの一覧に漏れがあってもすり抜けないよう、
     未知のオプションは「値を取る」「取らない」の両方を候補に展開し、どれかが該当すれば拒否する
3. 読み取り遮断: 認証情報ファイルを `Read` の deny とサンドボックスの `denyRead` の両方に登録し、さらにフックが**コマンドの引数としての指定**も拒否する。
   `excludedCommands`（`docker` / `gh` / `terraform` / `terragrunt` / `git commit` / `git push`）はサンドボックスを迂回して `denyRead` が効かないため、この 3 層目が必要になる。
   ROSA/OCM、Helm repository / registry、uv credentials store、PostgreSQL の password / service file、pip・curl・wget・Bundler・Composer・Poetry の認証設定、shell 履歴、Codex / Claude Code の会話履歴・session transcript・file history・paste cache・shell snapshot、ユーザーおよびシステムの macOS Keychain、KeePass、service account の既知ファイルも同じ対象にする。
   `.git-credentials`、`.netrc`、`.pgpass`、`.npmrc`、`.pypirc` と既知の token store は、ホーム外やワークスペース内の同名パスも対象にする。
   AWS・Kubernetes・コンテナ・GitHub・OCM・Helm・uv・PostgreSQL・パッケージ管理などの標準環境変数で保存先を差し替えた場合も、内容読み取りだけを拒否し、`test -e` / `test -f` は許可する
   `rsync --password-file` と `file://` / `fileb://` の指定も通常のパス指定として扱う
   認証情報パスの一覧を変更するときは、関連する 4 箇所を同時に更新する
4. サンドボックス: Codex は `:workspace` を継承した `hardened` 権限プロファイルを基本とし、認証情報パスの読み取りを拒否する。
   `:workspace_roots` の deny glob で、ワークスペース直下と入れ子の既知認証情報ファイルも同じように拒否する。
   環境変数は `inherit = "core"` に加え、既定除外（`*KEY*` / `*SECRET*` / `*TOKEN*`）と `[shell_environment_policy.filters]` で絞る。認証ファイルの保存先を示す変数も Codex へ継承しない。Claude はフックで内容読み取りと存在確認を分けられるが、Codex はこの変数単位の除外を安全側の制約として受け入れる
   Codex の shell snapshot は、展開済みの shell 環境を平文へ保存しないよう無効にする。Claude の shell snapshot は Bash 実行基盤が内部で使うため sandbox の `denyRead` には入れず、Read deny とフックでモデルからの直接参照だけを拒否する
   ブラウザ操作は常時承認（`always_ask`）とし、CDP フルアクセスは有効化しない（設定を置かず既定の無効のままにする）
5. 起動運用: AI エージェントは、認証情報の平文を環境変数へ設定しない新しいターミナルセッションから起動する。
  認証は credential helper・キーチェーン・認証エージェントへ委譲する
6. 検査の迂回経路の遮断: 「コマンド名を見る」検査をすべて迂回できる経路を、フックで個別に塞ぐ。
   - git の設定注入: 外部コマンドを起動させる設定（`core.pager`、`credential.helper` など）、URL 単位で書ける `credential.<url>.helper` / `protocol.<name>.allow` / `url.<base>.insteadOf`、
     別ファイルを読み込ませる `include.path` / `includeIf.*.path`、`git -c` / `--config` / `--config-env`、
     同等の環境変数（`GIT_SSH_COMMAND` など）と `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` / `GIT_CONFIG_PARAMETERS`
   - サンドボックス外で走るコマンドの任意実行口: `gh` の `alias` / `extension` / `config`、`terraform` / `terragrunt` の `console`。
     あらかじめ登録された shell alias は「知らないサブコマンド」として現れるため、`gh` / `terraform` / `git` とも既知のサブコマンド以外は拒否する
   - サンドボックス外で走るコマンドの環境変数による差し替え: `TF_CLI_ARGS` / `TF_CLI_ARGS_<command>`（コマンドラインに現れない `-json` を後から差し込める）、
     `TG_TF_PATH` / `TERRAGRUNT_TFPATH`（実行体の差し替え）、`GH_CONFIG_DIR`（alias を書いた config を読ませる）、
     `DOCKER_HOST` / `DOCKER_CONFIG` / `DOCKER_CERT_PATH` / `BUILDKIT_HOST` / `BUILDX_BUILDER`、`npm_config_*`（`npm_config_call` はコマンド文字列そのもの）。
     設定の探索先そのものを変える `HOME` / `XDG_CONFIG_HOME` は、実際にサンドボックス外を走る呼び出しに対して拒否する
     （git は `commit` / `push` のみが `excludedCommands` なので、`git status` のような参照は対象にしない）。
     判定は同じ argv の前置代入だけでなく、同じ Bash 呼び出しの中で `export` された変数も含めて行う
   - 同じことをする CLI オプション: docker の `--host` / `-H` / `--context` / `-c` / `--config` / `--tlscacert` / `--tlscert` / `--tlskey`
     （サブコマンド側の同名オプションと紛れないよう、サブコマンドより前の位置に限って見る）と、buildx の `--builder`
   - `git config` による永続化: `-c` の一時指定だけでなく、設定ファイルへ書き込む形（`git config core.hooksPath ...`、`--add`、`config set` など）も見る。
     書き込む先が外部コマンドを起動する設定キーなら deny、それ以外の書き込みは確認へ回す。
     `--get` / `--list` / `config get` / `config list` と、値を伴わない `git config <key>` は読み取りとして通す
   - インタプリタ経由の実行: 直接渡したコードから外部コマンドを起動する形は deny。
     文字列連結などで難読化できる以上「検査済み」とは言えないため、コードを渡す実行そのものも確認へ回す（`awk` は除く）。
     モジュール名を伴う起動 API だけを対象にし、`platform.system()` のような同名の無害な API は通す。
     `python3.13` のような版数付きの名前は既知のインタプリタ名へ正規化し、`node -pe` / `perl -we` / `perl -0777e` のように
     ひとかたまりに書かれた短縮オプションは、インタプリタごとのフラグ表（値を取らないもの・数字だけを取るもの・
     残り全部を取るもの）に従って分解してからコード本体を取り出す。
     分解し切れない塊の先にコードオプションが残る場合は、境界を決められないため解析不能として閉じる
   - ラッパー経由の実行: 受け取った文字列を shell へ渡す形（`npx -c`、`npm exec -c` / `npm x -c`、`pnpm -c`、`script -c`、`flock -c`、`git submodule foreach`）は中身をその場で解析し直し、
     位置引数を argv として起こす形（`mise exec -- <コマンド>`、`script <出力ファイル> <コマンド>`、`npm exec -- <コマンド>`、`npx <コマンド>`、`pnpm exec <コマンド>`）はその argv を検査する。
     npm は未知のオプションが値を取るかどうかを静的に決められない（`npm --color always exec -c ...`）ため、
     `exec` / `x` は位置ではなく「その語が現れるか」で判定する。
     子 argv の境界は `--` を最優先とし、`--` が無い場合はランナー側のオプションを構文どおり読み飛ばす。
     値を取るか判らないオプションが残ると境界を決められないため、そこで解析不能として閉じる
   - エディタ・sqlite3 からの shell escape: `vim -c ':!cmd'` / `+!cmd` / `system(...)` / `:terminal`、`sqlite3` の `.shell` / `.system` / `.load` と `.once |cmd` は deny
   - 再評価する展開: `${変数@P}` は値をプロンプトとして解釈し直し、その中の `$(...)` を実行するため deny
   - 関数本体の迂回: `eval` / `trap` の中身は新しい解析として読み直すため、外側で定義された関数表を引き継いで本体まで検査する
   - コンテナへの受け渡し: `BUILDX_BAKE_GIT_AUTH_TOKEN` / `BUILDX_BAKE_GIT_AUTH_HEADER`（認証トークンをビルドへ送る）と
     `BUILDX_BAKE_GIT_SSH`（SSH agent の socket を転送する）は、外部状態の変更ではなく認証情報の受け渡しとして deny。
     このほか `-v` / `--mount` / `--env-file` / `-e` / `--build-arg` / `--secret`（`src=` と `env=` の双方）/ ビルドコンテキスト、
     buildx bake の `--set <target>.secret.<id>=src=` / `.ssh` / `.context`、およびホストの socket（`--use-api-socket`、`*.sock` のマウント）
     このほか、入力リダイレクトやオプションへ連結した認証情報パス、通常ファイルの `source` / `.`、認証情報を持つ環境変数の引数展開も拒否する。出力リダイレクトや、方向が明確な標準コマンドによる保護対象パスへの書き込み・移動・削除は内容読み取りではないため、deny ではなく確認へ回す
     コンテナ内でも、標準 reader の file operand と `tar` が archive へ取り込む入力元には同じパス判定を適用する
     標準の proxy 変数は値の明示展開だけを拒否し、クライアントによる暗黙利用と値を返さない存在確認は許可する

### 判断の記録

- Claude Code の `permissions.defaultMode` は `auto` とする。
  `bypassPermissions` を明示的に選んだ場合、確認ダイアログが出ないため、フックの確認理由はそのまま拒否になる。
  例外はインタプリタへ直接渡したコードだけで、次の 2 点が根拠になる。
  外部プロセスの起動と難読化はモードによらず既に deny であること、
  インタプリタは `excludedCommands` ではないためサンドボックス内で動き、`denyRead` により認証情報へ到達できないこと。
  ここを拒否にすると `bypassPermissions` では一切のスクリプト処理ができなくなる。
  公式の注意どおり、`bypassPermissions` はコンテナや VM などの隔離環境でのみ使用する
- スクリプトファイルの実行（`bash x.sh`、`python3 x.py`、`./x.sh`）は、モードによらず止めない。
  これらはサンドボックス内で動くため `denyRead` が効き、その中から起動した `gh` / `git push` も同じくサンドボックス内で認証情報へ到達できない。
  一方、文字列を shell へ渡すラッパー（`npx -c` など）は中身を解析し直せるので、そちらは実際に検査する
- **この判断が守るのは「認証情報の読み取り」だけである。**
  サンドボックスの `denyRead` は読み取りしか止めないため、`bypassPermissions` で未解析のコードやスクリプトを通すと、
  ワークスペース内のファイル書き換えと、許可ドメインへの通信は防げない。
  つまり `rm -rf` や force push をフックが確認へ回していても、同じ結果を
  `python3 -c` やスクリプトから起こすことは止められない。
  破壊操作まで保証したい場合は、`bypassPermissions` を使わない（`auto` のままにする）か、
  隔離環境で動かすかのいずれかが要る
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` は使わない。
  既定以外の permission mode と競合するため、起動前に新しいターミナルセッションを開き、秘密値を環境変数へ設定しない運用とする
- `sandbox.allowUnsandboxedCommands` は `false`（Strict sandbox mode）とし、`dangerouslyDisableSandbox` による非サンドボックス再実行を禁止する
- `gh` / `docker` / `terraform` / `terragrunt` / `git commit` / `git push` はサンドボックス外で実行する。
  `gh` は認証、`docker` はソケット接続、`git commit` は pre-commit フック、`git push` は credential helper のために必要になる。
  ただし `excludedCommands` はサンドボックスを完全に迂回し `denyRead` が効かないため、補償として上記のコマンド遮断とフックを置く。
  とくに `gh` と `terraform` はコマンド名単位の除外だけでは守れない（`gh alias set x '!command'` で任意のコマンドを、
  `terraform console` の `file()` で任意のファイルを扱えるため）。既知のサブコマンド以外を拒否する guard をフックに置いている
- サンドボックス内の `git fetch` / `git pull` / `git clone` は excludedCommands に**含めない**。
  credential helper がトークンの保管先へ到達できないため非公開リポジトリでは失敗するが、認証待ちでハングしないよう `GIT_TERMINAL_PROMPT=0` を設定する。
  ここを迂回させるより、失敗させるほうを選ぶ
- GitHub の認証は SSH へ移行せず、HTTPS と通常の `gh auth git-credential` を使う。
  組織固有の URL だけ非公開側の設定で `ghtkn git-credential` に切り替え、8 時間で失効する User Access Token を使う。
  `gh auth login` と `ghtkn auth` のように秘密値を出力しない認証状態変更は、フックの確認を経て実行できる。
  session token 自体を出力する `op signin` は deny のままにする
- AWS は `aws-env`（`aws configure export-credentials` の結果を環境変数へ展開するシェル関数）を廃止し、`aws-use` による `AWS_PROFILE` の切り替えだけを残す。
  一時認証情報そのものをシェルへ載せず、既存の credential provider 環境変数も値を展開せず設定有無だけを確認する
- `permissions.ask` は空とし、settings は allow / deny に二分する。
  文字列規則だけでは表記を網羅できない操作（`rm -rf`、force push、書き込みを伴う `gh api`、
  サンドボックス外 CLI の状態変更など）は settings では書き分けず、フックが実行時に判定する。
  フックは通常モードでは `ask` を返して確認へ回し、`bypassPermissions` では確認が表示されないため deny を返す
- Claude Code の `Read` deny と Codex の `:workspace_roots` deny に `**/.env.*` を残す（`.env.example` も読めなくなる）。
  どちらの権限ルールにも安全な否定表記が無く、実値を持つ `.env.local` などを覆うほうを優先する。
  フックは雛形（`.env.example` / `.env.sample` / `.env.template` / `.env.dist`）を通す。
  **これは過剰制限が残っている箇所である**（雛形を読ませたい場合は、`env.example` のように
  `.env` で始まらない名前へ正本を置くのが現時点の回避策）
- 真偽オプションは表記を正規化して判定する。
  `--show-token` と `--show-token=true` を別物として扱うと、hard deny を表記だけで回避できる
- パスの比較はすべて casefold し、区切りの重複や `.` / `..` を畳んでから突き合わせる。
  macOS の既定ファイルシステムは大文字小文字を区別しないため `~/.SSH/ID_ED25519` でも同じ場所に届き、
  `gh//hosts.yml` のような 1 文字の追加で判定が外れてもいけない。
  `~<ユーザー名>/` も bash が同じホームへ展開するため、`~/` と同じ扱いにする
- 算術式が未知の変数に依存する場合は、解析不能ではなく確認へ回す。
  bash は変数の値を式として再評価するが、シェルの呼び出しは 1 回ごとに独立しており、
  同じコマンド内の代入は追跡できている。`for ((i = 0; i < 3; i++))` のような日常操作を止めない
- 条件付き実行や関数呼び出しで変わった変数の状態は、覚えずに捨てる。
  「合流できないから解析不能」にすると `export X=... && cmd` のような普通の操作が止まる。
  忘れた値は後続の算術式で確認へ回るだけで、実行は妨げない
- グロブはファイル名を特定できないため、ディレクトリ側だけで判定する。
  `find . -name '*.pem'` のような検索を止めずに、`~/.aws/*` のような指定は拒否する
- `secrets` / `credentials` という語は、パスとして書かれている場合だけ保管先とみなす。
  URL の一部や `gcloud secrets list` のようなサブコマンド名まで拒否しない
- terraform の state（`*.tfstate` / `*.tfstate.*`）は、CLI 経由の出力だけでなくファイルそのものを保護対象にする。
  平文の秘密値を含みうるため、`cat terraform.tfstate.backup` も `git show HEAD:terraform.tfstate` も拒否する。
  git の `<rev>:<path>` は引数の見た目がパスにならないため、`:` の後ろを切り出して判定する
- buildx bake の `--set` は、ターゲット名の**次の語だけ**を種別として見る。
  `targetpattern.key[.subkey]=value` の subkey まで種別に含めると、`target.args.ssh` のような
  普通の build argument 名が SSH 転送と誤認される
- git のサブコマンドは既知の一覧（`git help -a`）に無いものを拒否する。
  `git commit` / `git push` はサンドボックス外で走るため、`git config alias.x '!command'` で登録した
  alias から任意のコマンドを起こせてしまう
- 認証情報パスの判定は、書かれた表記と `realpath` で解決した実体の**両方**へ同じ規則を当てる。
  無害な名前の symlink を置けば、名前だけの判定は素通りしてしまう。
  ただし保管先ディレクトリ（`secrets/` / `credentials/`）の判定を解決後のパスへ常に当てると、
  `gcloud secrets list` の `secrets` が cwd 基準で `<cwd>/secrets` というパスの形になってしまう。
  そのため、パスとして書かれていたときと、実際に symlink をたどったときに限る
- `gh` と `docker` は「変更操作を列挙する」のではなく「読み取り操作を allowlist にする」。
  `gh pr create` や `docker container kill` のように、列挙から漏れた状態変更が自動実行されるのを防ぐ。
  漏れたときに起きるのは「余分な確認」であって「無断の実行」ではない側へ倒す。
  下位動詞を持つ操作は語数まで一致させる（`gh codespace ports` は参照だが
  `gh codespace ports visibility 3000:public` は公開範囲の変更になる）
- Docker の未整形 `inspect` / `info` / `compose config` / `compose convert` / `stack config` / `history`、TLS 鍵を含みうる `context export`、完全な引数を出す `top` / `compose top` / `ps --no-trunc` は hard deny にする。
  `inspect` は `.Config.Env`、`info` は認証付き proxy、Compose/Stack の config は補間後の環境、`history` はビルド引数、`top` と展開済み `ps` はプロセス引数を出すためである。固定した安全な format、集約出力、安全な `ps` 列だけを選んだ `top` は許可する
- `--format` は「危険なフィールド名を並べて弾く」のではなく「安全なフィールドだけを許す」。
  文字列の部分一致は `--format json` や `{{index . "Command"}}` ですり抜けられるため、
  参照の**形**を `{{.Field}}` / `{{.Field.Sub}}` に限り、構成要素がすべて既知の安全なフィールドの場合だけ通す。
  `docker ps --no-trunc` も完全な command 列を出すため拒否するが、`--no-trunc=false` は明示的な無効化なので通す。
  真偽値の表記は Docker が使う pflag に合わせ、`t` / `T` も true として扱う
- 危険な環境変数の判定は、同じ argv の前置代入だけでなく、同じ Bash 呼び出しの中で
  `export` された変数も対象にする。`export TF_CLI_ARGS_show=-json; terraform show` は
  前置代入と同じ結果になる。
  値は条件付き実行や関数呼び出しのあとで巻き戻すが、**変数名は taint として増える一方で保持する**。
  実際の bash では成功した `export` が後続コマンドへ残るため、
  `export GH_CONFIG_DIR=/tmp/fake && gh pr list` を通してはいけない。
  巻き戻さない代わりに `export -n` での打ち消しも追わないが、これは安全側の誤差である。
  `export` と書かれていなくても環境へ載る経路も同じ扱いにする。
  `set -a`（allexport）の間の代入と、`VAR=value fn` のように関数呼び出しへ前置した代入がそれにあたる。
  allexport 中は、ただの代入だけでなく `readonly` / `read` / `declare` / `printf -v` / `mapfile` /
  算術代入 `(( ))` の対象名も同じ扱いにする。代入先を静的に決められない書き方（`read "$name"` など）は
  取り落とすより解析不能として閉じる
- allexport の追跡は、有効化と無効化で扱いを変える。
  有効化は常に取り込み、無効化は「確実に実行される位置」でだけ反映する。
  条件付き実行やサブシェルの中の `set +a` を信じると、実際には有効なまま検査だけが緩む。
  `set -- +a` は位置パラメータの指定であって allexport の解除ではないため、`--` 以降はオプションとして読まない
- 関数呼び出しへ前置した代入の taint は、呼び出しの間だけにする。
  `VAR=value fn` の値は関数を抜けると元へ戻るため、後続の操作まで拒否すると過剰になる。
  同じ理由で、確実に実行される `unset` は taint を消す
- 環境変数名は大文字化せず、正確な名前で照合する。
  macOS のシェルは環境変数名の大文字小文字を区別するため、`pager=cat git status` の `pager` は
  git に何の影響も与えない。大文字化すると無関係な変数まで拒否してしまう
- `git restore --staged`（`--worktree` を伴わないもの）は確認しない。
  index を戻すだけで作業ツリーは壊さないため、通常の開発操作として扱う
- サブコマンドは wrapper を剥がしてから判定する。
  `terragrunt run --all destroy` と `terragrunt run-all destroy` は `destroy` と同じ判断にする
- オプションだけでなく位置引数も見る。
  `git push origin +src:dst` と `git push origin :dst` は `--force` / `--delete` と同じ効果を持つ
- 相対パスは PreToolUse イベントの `cwd` を基準に `realpath` で解決する。
  文字列の部分一致では `../../..` や symlink をたどれない
- コンテナへのマウントは、保護パスの配下だけでなく**親**も拒否する。
  `~/.config` をマウントすれば `~/.config/gh/hosts.yml` がそのまま見える
- `Bash(...)` のパターンでは `*` を末尾にだけ置く。
  途中に置いても前方一致しか効かず、覆えていないことに気付けないため
- 「コマンドラインに現れる字句そのものを拒否する」規則は廃止した。
  文書の grep のような無害な操作まで止まる一方、実行経路はシェルの構文解析で判断できるため
- Codex CLI の認証情報はキーチェーンを避けてファイル（`~/.codex/auth.json`）に保管し、Claude 側の `denyRead` と Codex 側の権限プロファイルの双方に登録する
- Codex の Chrome 拡張と外部ブラウザ機能は無効化しない。
  ログイン済みブラウザは Cookie 経由で機密に到達しうるため、専用プロファイルが用意されるまでは常時承認のままにする
- URL 限定 helper に使う `ghtkn` の導入元は mise に一本化する。
  Homebrew と二重に宣言すると、shim と実体のどちらが動くかが端末の状態で変わる

## 未完了の対策

ここまでの整備は「dotfiles の整理と、隔離が入るまでの暫定 guard」までです。強制力のある境界にはなっていません。
以下は**まだ実施していません**。現時点の構成は、AI エージェントが自分に課された制限そのものを書き換えられる状態です。

- 管理設定の root 所有化。
  `/Library/Application Support/ClaudeCode/managed-settings.json`、`/etc/codex/requirements.toml`、フックの `root:wheel` 所有化、managed-only lock は未導入。
  `.claude/settings.json`、`.claude/hooks/`、`git-hooks/` はいずれも追跡ファイルへのシンボリックリンクであり、エージェントが編集できる。
  現状の遮断は「改ざん耐性のある強制」ではなく「既定の運用」である
- Codex からの macOS Keychain API 呼び出し。
  `~/Library/Keychains` などの filesystem deny は Keychain ファイルの直接読み取りを止めるが、`securityd` を介した Keychain API まで遮断するものではない。
  Claude Code はフックで標準の `security` 秘密出力コマンドを拒否する一方、Codex には同等の実行前フックがない。
  現時点では AGENTS の絶対禁止と会社の EDR による検知・確認を前提とし、Keychain IPC の OS レベル拒否や別ユーザー境界は導入していない
- Git の追跡済み内容と履歴に対する広い参照。
  `.env` のように既知の認証情報パスをそのまま指定した形は拒否するが、パスを省略した `git diff` / `git show` / `git log -p` / `git archive` や `.` / `*` まで一律には拒否しない。glob や pathspec magic を使った任意の変形も完全には照合しない。
  通常の Git 操作を維持するため、認証情報を commit しないことを前提とする。誤って commit した認証情報を Git object database から取り除いて表示内容を安全に仲介する仕組みは未導入
- AWS の署名ブローカー、または認証済みの隔離 runner。
  `aws-env` を廃止したため一時認証情報はシェルに載らないが、代わりの安全な受け渡し口はまだ無い。
  `credential_process` が生の認証情報を AI 制御下のプロセスへ返すだけの構成は、最終解としない
- AI 専用の隔離 Docker デーモン、または VM。
  現在の `docker` はホストのソケットへ接続するため、コンテナ経由の持ち出しはフックの暫定 guard だけで塞いでいる。
  静的解析で読み切れない経路（Compose ファイルの中身など）は残存リスクとして受容している
- AI 専用の Chrome プロファイル。
  個人用プロファイルを接続しない前提を、設定ではなく運用で守っている段階
- `gh` / `terraform` / `terragrunt` を `excludedCommands` に残したままにしている。
  既知のサブコマンドだけを通す guard を置いたが、`terraform plan` / `apply` はプロバイダのプラグインバイナリを
  サンドボックス外で実行するため、原理的には任意のコードが動く。
  限定した wrapper／ブローカー、または隔離 runner を用意するまでの残存リスクとして受容している
- インタプリタへ渡したコードの検査。
  外部コマンドの起動と、実行対象を実行時に組み立てる書き方（`__import__`、`eval`、`require` など）は
  deny にしたが、識別子の照合である以上、境界にはならない。
  検査しきれない分は実行そのものを ask にして補っているが、最終的には OS レベルの隔離が要る
- AI エージェントからの GitHub 認証。
  通常の Git helper と `gh` は `gh auth login` の認証を使い、組織固有 URL の Git helper だけは非公開側で ghtkn に切り替える。
  どちらも保管先へ安全に到達できないサンドボックス内の操作には、秘密値を返さない broker か wrapper が別途要る
- 各ブローカー socket の最終的な allowlist と、実認証を伴うエンドツーエンド検証

## 非公開での報告

脆弱性や認証情報の露出を報告する際は、公開 Issue ではなく [GitHub の非公開脆弱性報告](https://github.com/pych-ky/dotfiles/security/advisories/new)を利用してください。

- 秘密情報そのものは記載しない
- 分かる範囲で再現手順、影響範囲、修正案を記載する

報告を確認後、必要に応じて修正し、認証情報を失効またはローテーションします。
