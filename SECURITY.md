# セキュリティポリシー

デフォルトブランチの最新版のみをサポートします。

## AI エージェントからの機密情報遮断

AI エージェント（Claude Code / Codex）にパスワード・クレデンシャル・キーチェーンの内容を渡さないことを前提に、以下の多層防御を採用しています。

1. コマンド遮断: `.claude/settings.json` の `permissions.deny` と `.claude/hooks/pre-bash-guard.py` の両方で、以下を拒否する。
   フックは実行の有無にかかわらず、これらの字句がコマンドラインに現れること自体も拒否する（プロセスのコマンドラインは監査対象であり、データとして載せただけでも認証情報へのアクセスとして扱われるため）
   - キーチェーン（`security` の全サブコマンド。`find-certificate -p` は秘密鍵を PEM で出力し、`unlock-keychain -p` はパスワードを argv に載せる）
   - GitHub / git のトークン取得と credential helper の直接実行
   - AWS の認証情報・復号値の出力（`sts` / `sso` / `sso-oidc` / `ecr` / `secretsmanager` / `kms` / `eks` / `rds`）
   - シークレット管理（`op`、`ghtkn`、HashiCorp Vault、`gcloud auth print-*-token`、`az account get-access-token`）
   - Kubernetes（`kubectl get secret`、`kubectl config view --raw`）
   - 環境変数の一括出力と、実クレデンシャルを環境変数へ展開する `aws-env`
2. 読み取り遮断: 認証情報ファイル（`~/.ssh`、`~/.aws/credentials`、`~/.kube/config`、`~/.codex/auth.json`、`~/.config/gh/hosts.yml`、`~/.git-credentials`、`~/.netrc`、`~/Library/Keychains`、秘密鍵ファイルなど）を `Read` の deny とサンドボックスの `denyRead` に登録し、さらにフックが**コマンドの引数としての指定**も拒否する。
   `excludedCommands`（`docker` / `gh` / `terraform` / `terragrunt`）はサンドボックスを迂回して `denyRead` が効かないため、この 3 層目が必要になる
3. サンドボックス: Codex は `:workspace` を継承した `hardened` 権限プロファイルを基本とし、認証情報パスの読み取りを拒否する。`AWS_*` / `AZURE_*` 環境変数も除外する。ブラウザ操作は常時承認（`always_ask`）とし、CDP フルアクセスは有効化しない（設定を置かず既定の無効のままにする）
4. 検査の迂回経路の遮断: 外部コマンドを起動させる git の設定（`core.pager` など）や同等の環境変数の指定、インタプリタへ直接渡したコードからの外部コマンド起動、コンテナへの認証情報の受け渡し（`-v` / `--mount` / `--env-file`）をフックで拒否する。
   これらは「コマンド名を見る」検査をすべて迂回できるため、個別に塞ぐ

### 判断の記録

- Claude Code の `permissions.defaultMode` は `auto` とする。
  deny に載らない未知の機密到達経路まで無確認実行になるため、`bypassPermissions` は採用しない
- `sandbox.allowUnsandboxedCommands` は `false`（Strict sandbox mode）とし、`dangerouslyDisableSandbox` による非サンドボックス再実行を禁止する
- `gh` / `docker` / `terraform` / `terragrunt` はサンドボックス外で実行する（`gh` は認証、`docker` はソケット接続に必要）。
  ただし `excludedCommands` はサンドボックスを完全に迂回し `denyRead` が効かないため、補償として `gh auth token` などのトークン表示コマンドと `docker-credential-*` を deny する。
  `docker run -v` によるマウントなど、これらのコマンド自身のファイルアクセスで機密に到達する経路は残存リスクとして受容する
- サンドボックス内の subprocess には `sandbox.credentials.envVars`（deny）と `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` で認証系の環境変数を渡さない
- credential helper が認証を内部で処理する操作（`git push` / `git fetch` など）は、トークンを表示・持ち出さない限り許容する
- Codex CLI の認証情報はキーチェーンを避けてファイル（`~/.codex/auth.json`）に保管し、Claude 側の `denyRead` に登録する。
  Codex 側でも `hardened` 権限プロファイルの filesystem deny に登録し、subprocess からの読み取りを OS サンドボックスで拒否する

## 非公開での報告

脆弱性や認証情報の露出を報告する際は、公開 Issue ではなく [GitHub の非公開脆弱性報告](https://github.com/pych-ky/dotfiles/security/advisories/new)を利用してください。

- 秘密情報そのものは記載しない
- 分かる範囲で再現手順、影響範囲、修正案を記載する

報告を確認後、必要に応じて修正し、認証情報を失効またはローテーションします。
