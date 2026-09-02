#!/usr/bin/env python3
"""危険な Bash コマンドを検出する PreToolUse スキャナー。"""

import json
import os
import re
import shlex
import sys
from posixpath import normpath
from urllib.parse import unquote, urlsplit


# ============================================================================
# 定数
# ============================================================================

RM_CONFIRM_REASON = (
    "rm -rf / rm -Rf / rm --recursive --force は不可逆なため、実行前に確認してください。"
)
SUDO_REASON = "sudo の使用は Claude からは許可していません。"
HASH_REBIND_REASON = "hash -p によるコマンドパスの再束縛は許可していません。"
PIPE_SHELL_REASON = "curl / wget ... | sh / bash 形式のコマンドは許可していません。"
SHELL_STDIN_REASON = "内容を安全に検証できない標準入力を shell script として実行できません。"
SOURCE_FILE_CONFIRM_REASON = (
    "source / . で読み込むファイルの中身は静的に検査できません。"
    "内容を確認してから実行してください。"
)
PARSE_REASON = "Bash コマンドを安全に解析できませんでした。"
KEYCHAIN_SECRET_REASON = (
    "macOS キーチェーンに保存された秘密値を出力する操作は許可していません "
    "(公開証明書を出力する find-certificate は対象外)。"
)
KEYCHAIN_CONFIRM_REASON = (
    "キーチェーンの状態を変更しうる security の操作は、実行前に確認してください。"
)
CREDENTIAL_TOOL_REASON = (
    "認証情報を標準出力へ返す、または子プロセスへ渡すコマンドの実行は"
    "許可していません。"
)
CREDENTIAL_TOOL_CONFIRM_REASON = (
    "認証状態を変更する操作は AI が自動で行わず、実行前に確認してください。"
)
CREDENTIAL_FILE_CHANGE_CONFIRM_REASON = (
    "認証情報として保護しているパスを変更する操作は、実行前に確認してください。"
)
GH_TOKEN_REASON = "gh auth token によるトークンの取得は許可していません。"
GH_API_SECRET_REASON = (
    "gh api で runner token や installation access token などの"
    "認証情報を返す endpoint は呼び出せません。"
)
AWS_EXPORT_REASON = (
    "AWS の認証情報・機密値を標準出力へ返すコマンドの実行は許可していません。"
)
AWS_CONFIGURE_SECRET_REASON = (
    "AWS の credential 設定は configure get で出力したり、"
    "configure set の平文引数で保存したりできません。"
)
AWS_PAGER_REASON = (
    "AWS CLI の pager を外部コマンドへ差し替える環境変数やオプションは"
    "許可していません。"
)
DOCKER_MOUNT_REASON = (
    "認証情報を含むパスを docker のボリューム・ビルドコンテキストとして"
    "渡すことは許可していません。"
)
DOCKER_OUTPUT_REASON = (
    "コンテナの環境変数・ビルド引数・プロセス引数を含みうる出力は"
    "認証情報を tool output へ載せるため許可していません。"
)
DOCKER_ENV_REASON = (
    "認証情報らしい環境変数をコンテナへ引き継ぐことは許可していません。"
)
DOCKER_SOCKET_REASON = (
    "ホストの socket をコンテナへ渡す操作は許可していません "
    "(コンテナ側から、この検査を通らない新しいマウントを作れるため)。"
)
ENV_DUMP_REASON = "printenv / env による環境変数の一括出力は許可していません。"
DESTRUCTIVE_CONFIRM_REASON = (
    "取り消せない、または検査を迂回する操作のため、実行前に確認してください。"
)
AUTH_CHANGE_CONFIRM_REASON = (
    "認証状態を変更する操作は AI が自動で行わず、実行前に確認してください。"
)
TERRAFORM_CONSOLE_REASON = (
    "terraform / terragrunt の console は file() などで任意のファイルを"
    "読めるため許可していません。"
)
PROMPT_EXPANSION_REASON = (
    "${変数@P} は値をプロンプトとして再評価し、その中の $(...) を実行するため"
    "許可していません。"
)
EDITOR_SHELL_ESCAPE_REASON = (
    "エディタや sqlite3 から shell へ抜ける指定は、検査を迂回して任意の"
    "コマンドを起動できるため許可していません。"
)

# 認証情報を扱うコマンドを、サブコマンド単位で分類する。
# {コマンド: (値を取るグローバルオプション, deny するサブコマンド語の並び,
#            確認を求めるサブコマンド語の並び)}
# ここに載らないサブコマンド (ghtkn info など) は秘密値を出さないため通す
CREDENTIAL_TOOL_SUBCOMMANDS = {
    "ghtkn": (
        {"-c", "--config", "--log-level"},
        {
            # 標準出力へトークンを返す / 子プロセスの環境へ渡す
            ("get",),
            ("exec",),
            # helper は git から内部的に呼ばせる。直接実行はトークンの取得になる
            ("git-credential",),
        },
        {
            # 認証状態を変える操作。AI が自動で始めず、利用者が開始する
            ("auth",),
            ("revoke",),
            ("init",),
            ("agent", "start"),
            ("agent", "stop"),
            ("agent", "lock"),
            ("agent", "unlock"),
            ("agent", "reset"),
        },
    ),
    "op": (
        {"--account", "--session", "--vault", "--format", "--config", "--encoding"},
        {
            ("read",),
            ("inject",),
            ("run",),
            ("plugin", "run"),
            ("item", "get"),
            ("document", "get"),
            ("connect", "token", "create"),
            ("service-account", "create"),
            # signin は session token を標準出力へ返す。
            ("signin",),
        },
        {
            ("signout",),
        },
    ),
    "uv": (
        {"--cache-dir", "--color", "--config-file", "--directory", "--project"},
        {
            ("auth", "token"),
            ("auth", "helper"),
        },
        {
            ("auth", "login"),
            ("auth", "logout"),
        },
    ),
}

# security のサブコマンドは、保存済みの秘密値を出すものだけを deny する。
# 公開証明書を出す find-certificate や一覧系は通し、キーチェーンの状態を
# 変えうる操作 (unlock-keychain など) は確認へ回す
SECURITY_SECRET_SUBCOMMANDS = {"dump-keychain", "export-smartcard"}
SECURITY_PASSWORD_SUBCOMMANDS = {
    "find-generic-password",
    "find-internet-password",
}
# パスワード本体を出力させる短いオプション (-w: 標準出力, -g: 標準エラー出力)
SECURITY_PASSWORD_FLAGS = {"w", "g"}
SECURITY_SAFE_SUBCOMMANDS = {
    "find-generic-password",
    "find-internet-password",
    "find-certificate",
    "find-identity",
    "list-keychains",
    "default-keychain",
    "login-keychain",
    "show-keychain-info",
    "verify-cert",
    "error",
    "help",
}
# security のグローバルオプション。-p はプロンプト文字列を値として取るため、
# 消費しないと次の語をサブコマンドと誤認する
SECURITY_VALUE_OPTIONS = {"-p"}
# 値を取らないグローバルフラグ。既知にしておかないと、次の語を値と解釈する
# 候補まで展開され、秘密を出さない参照操作まで確認へ回ってしまう
SECURITY_BOOLEAN_OPTIONS = {"-q", "-v", "-l", "-h"}
# 対話モードは任意のサブコマンドを標準入力から受け取れるため、静的に検査できない
SECURITY_INTERACTIVE_FLAG = "i"

# サブコマンド判定のために「次の語を値として消費する」グローバルオプション。
# これらを消費してから位置引数 (サブコマンド語) の並びを見ることで、
# 値がサブコマンドを押し出すことによる誤検知・すり抜けの両方を防ぐ。
#
# 未知のオプションは値を取るかどうか分からないため、両方の解釈を候補として
# 展開する (subcommand_word_candidates)。以下はその探索の打ち切り条件
SUBCOMMAND_WORD_LIMIT = 4
SUBCOMMAND_CANDIDATE_LIMIT = 64

GH_VALUE_OPTIONS = {
    "--repo",
    "-R",
    "--hostname",
    "-X",
    "--method",
    "-H",
    "--header",
    "-q",
    "--jq",
    "--template",
    "--input",
    "-f",
    "--raw-field",
    "-F",
    "--field",
    "--cache",
    "-c",
    "--codespace",
}
# 認証・秘密の状態を変える gh の操作。理由を具体的に示すため個別に持つ
# (これ以外の状態変更は GH_READONLY_* の allowlist から漏れる形で確認へ回る)
GH_CONFIRM_SUBCOMMANDS = {
    ("auth", "login"),
    ("auth", "logout"),
    ("auth", "refresh"),
    ("auth", "setup-git"),
    ("auth", "switch"),
    ("secret", "set"),
    ("secret", "delete"),
    ("variable", "set"),
    ("variable", "delete"),
    ("ssh-key", "add"),
    ("ssh-key", "delete"),
    ("gpg-key", "add"),
    ("gpg-key", "delete"),
}
# 読み取りだけで済む gh の動詞 (第 2 語)。
# ここに無い操作は、外部の状態を変えうるものとして確認へ回す
GH_READONLY_VERBS = {
    "get",
    "list",
    "view",
    "status",
    "checks",
    "diff",
    "check",
    "ls",
    "watch",
    "verify",
}
# 自由な位置引数を取る、読み取りだけの gh 操作 (前方一致で判定)。
# 書き込みになる `gh api` の呼び方は gh_writes_through_api が別途判定する
GH_READONLY_PREFIXES = {
    ("api",),
    ("browse",),
    ("completion",),
    ("help",),
    ("search",),
    ("status",),
    ("version",),
    ("accessibility",),
    ("preview",),
    ("gitignore",),
    ("license",),
}
# 下位動詞を持つため、語数まで一致させないと読み取りと言えない gh 操作。
# `gh codespace ports` は参照だが、`gh codespace ports visibility 3000:public` は
# 公開範囲の変更になる
GH_READONLY_EXACT = {
    ("codespace", "logs"),
    ("codespace", "ports"),
    ("cs", "logs"),
    ("cs", "ports"),
}
# 別のコマンド (git / ssh) へ引数を素通しする gh のサブコマンド。
# `--` の後ろは受け取り側のオプションになるため、この検査を迂回できる
GH_PASSTHROUGH_SUBCOMMANDS = {
    ("repo", "clone"),
    ("repo", "fork"),
    ("repo", "sync"),
    ("codespace", "ssh"),
    ("codespace", "cp"),
    ("codespace", "logs"),
    ("cs", "ssh"),
    ("cs", "cp"),
    ("cs", "logs"),
}
GH_PASSTHROUGH_REASON = (
    "gh から git / ssh へ素通しされる引数 (`--` 以降) は検査できないため"
    "許可していません (core.hooksPath や ProxyCommand で任意のコマンドを"
    "起動できます)。"
)
# gh に外部コマンドを起動させる環境変数
# gh api で外部の状態を変える指定。
# 明示した HTTP method に加えて、フィールド指定は暗黙に POST になる
GH_API_VALUE_OPTIONS = {"-X", "--method", "-H", "--header", "-q", "--jq", "-t"}
GH_API_WRITE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
GH_API_WRITE_OPTIONS = {
    "-f",
    "--raw-field",
    "-F",
    "--field",
    "--input",
}
GH_FILE_INPUT_OPTIONS = {
    "--body-file",
    "--bundle",
    "--custom-trusted-root",
    "--env-file",
    "--input",
    "--notes-file",
    "--tuf-root",
}
GH_API_SECRET_ENDPOINTS = (
    re.compile(
        r"^/(?:repos/[^/]+/[^/]+|orgs/[^/]+|enterprises/[^/]+)/"
        r"actions/runners/(?:registration-token|remove-token|generate-jitconfig)$"
    ),
    re.compile(r"^/app/installations/[^/]+/access_tokens$"),
    re.compile(r"^/app-manifests/[^/]+/conversions$"),
    re.compile(r"^/applications/[^/]+/token(?:/scoped)?$"),
)
GH_EXEC_ENV_VARS = {
    "GH_PAGER",
    "PAGER",
    "GH_EDITOR",
    "EDITOR",
    "VISUAL",
    "GH_BROWSER",
    "BROWSER",
}

# terraform / terragrunt の console は file() などで任意のファイルを
# 読めるため拒否する。
TERRAFORM_DENIED_SUBCOMMANDS = {("console",)}
# state には平文の秘密値が含まれうる。標準出力へ返す操作は拒否する
TERRAFORM_SECRET_SUBCOMMANDS = {
    ("state", "pull"),
    ("state", "show"),
}
# 出力に平文の秘密値が載るオプション。
# 引数なしの `terraform output` は sensitive を伏せるため対象外
TERRAFORM_SECRET_OPTIONS = {
    ("output",): {"-raw", "-json", "--raw", "--json"},
    ("show",): {"-json", "--json"},
}
# terragrunt は `run --all destroy` / `run-all destroy` のように、
# 本来のサブコマンドを wrapper で包む。判定前にこの wrapper を剥がす
TERRAFORM_WRAPPER_SUBCOMMANDS = {"run", "run-all", "stack"}
TERRAFORM_CONFIRM_SUBCOMMANDS = {
    ("login",),
    ("logout",),
    ("apply",),
    ("destroy",),
    ("refresh",),
    ("import",),
    ("taint",),
    ("untaint",),
    ("force-unlock",),
    ("state", "rm"),
    ("state", "mv"),
    ("state", "push"),
    ("state", "replace-provider"),
    ("workspace", "delete"),
    # test は helper resource を実際に作って壊すため、plan/validate とは違う
    ("test",),
    # プロバイダやモジュールを取得して、サンドボックス外で実行できる状態にする
    ("init",),
    ("get",),
    ("providers", "lock"),
    ("providers", "mirror"),
    # state を持つ新しい workspace を作る
    ("workspace", "new"),
}
TERRAFORM_VALUE_OPTIONS = {
    "-chdir",
    "--chdir",
    "--working-dir",
    "--terragrunt-config",
    "-state",
    "-state-out",
    "-var",
    "-var-file",
    "-out",
    "-generate-config-out",
    "-target",
    "-replace",
    "-backup",
    "-backend-config",
    "-lock-timeout",
    "-parallelism",
    "-from-module",
    "-plugin-dir",
}
# 指定した実行ファイル・コマンドをそのまま起動する terragrunt のオプション
TERRAFORM_EXEC_OPTIONS = {
    "--auth-provider-cmd",
    "--terragrunt-auth-provider-cmd",
    "--tf-path",
    "--terragrunt-tfpath",
    "--iac-engine",
    "--terragrunt-iac-engine",
}
TERRAFORM_EXEC_OPTION_REASON = (
    "terragrunt に実行するコマンドや実行ファイルを指定するオプションは、"
    "サンドボックス外で任意のプロセスを起動できるため許可していません。"
)
# オプションと同じことを環境変数でできる指定。
# TF_CLI_ARGS / TF_CLI_ARGS_<command> は、コマンドラインに書いていない
# `-json` のような秘密を出すオプションを後から差し込める
TERRAFORM_EXEC_ENV_VARS = {
    "TF_REATTACH_PROVIDERS",
    "TG_TF_PATH",
    "TERRAGRUNT_TFPATH",
    "TG_IAC_ENGINE",
    "TERRAGRUNT_IAC_ENGINE",
    "TG_AUTH_PROVIDER_CMD",
    "TERRAGRUNT_AUTH_PROVIDER_CMD",
}
TERRAFORM_EXEC_ENV_PREFIXES = ("TF_CLI_ARGS",)
TERRAFORM_EXEC_ENV_REASON = (
    "terraform / terragrunt の実行ファイル・引数を差し替える環境変数の"
    "指定は許可していません "
    "(コマンドラインに現れないオプションを後から差し込めるため)。"
)
TERRAFORM_SECRET_REASON = (
    "terraform の state や出力には平文の秘密値が含まれうるため、"
    "それを標準出力へ返す操作は許可していません。"
)
AWS_GLOBAL_VALUE_OPTIONS = {
    "--profile",
    "--region",
    "--output",
    "--endpoint-url",
    "--query",
    "--ca-bundle",
    "--cli-read-timeout",
    "--cli-connect-timeout",
    "--color",
    "--cli-binary-format",
    "--cli-auto-prompt",
}
AWS_GLOBAL_BOOLEAN_OPTIONS = {
    "--debug",
    "--no-verify-ssl",
    "--no-paginate",
    "--no-sign-request",
    "--no-cli-pager",
    "--no-cli-auto-prompt",
    "--version",
}
AWS_VALUE_OPTIONS = AWS_GLOBAL_VALUE_OPTIONS | {
    "--page-size",
    "--max-items",
    "--starting-token",
}
AWS_DEBUG_OPTIONS = frozenset(
    "--debug"[:length] for length in range(len("--d"), len("--debug") + 1)
)
AWS_SSM_WITH_DECRYPTION_OPTIONS = frozenset(
    "--with-decryption"[:length]
    for length in range(len("--w"), len("--with-decryption") + 1)
)
AWS_SSM_NO_WITH_DECRYPTION_OPTIONS = frozenset(
    "--no-with-decryption"[:length]
    for length in range(len("--no-w"), len("--no-with-decryption") + 1)
)
AWS_DRY_RUN_OPTIONS = frozenset(
    "--dry-run"[:length]
    for length in range(len("--dr"), len("--dry-run") + 1)
)
AWS_NO_DRY_RUN_OPTIONS = frozenset(
    "--no-dry-run"[:length]
    for length in range(len("--no-d"), len("--no-dry-run") + 1)
)
AWS_CODEARTIFACT_DRY_RUN_OPTIONS = AWS_DRY_RUN_OPTIONS
AWS_DEPLOY_IAM_USER_ARN_OPTIONS = frozenset(
    "--iam-user-arn"[:length]
    for length in range(len("--ia"), len("--iam-user-arn") + 1)
)
AWS_CLI_SKELETON_VALUES = frozenset({"input", "yaml-input", "output"})
PIP_VALUE_OPTIONS = {
    "--cache-dir",
    "--cert",
    "--client-cert",
    "--log",
    "--proxy",
    "--python",
    "--retries",
    "--timeout",
}
PIP_BOOLEAN_OPTIONS = {
    "--debug",
    "--global",
    "--help",
    "--isolated",
    "--local",
    "--no-input",
    "--site",
    "--user",
    "--verbose",
    "--version",
}
PIP_SECRET_CONFIG_NAMES = {"index-url", "extra-index-url", "proxy"}
PIP_EXECUTABLE_RE = re.compile(r"^pip(?:[._-]?[0-9]+(?:[._-][0-9]+)*)?$")
PNPM_SECRET_CONFIG_NAMES = {"auth", "authtoken", "password"}
GIT_VALUE_OPTIONS = {
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--super-prefix",
    "--exec-path",
    "--attr-source",
    "--config-env",
}
# 環境変数の一括出力になりうる組み込みコマンドと、その出力オプション
ENV_DUMP_COMMANDS = {"printenv", "set", "export", "declare", "typeset"}
# 値を表示しても認証情報にならない、標準的な診断用変数。
# printenv はこの固定名だけを許可し、任意名や一括表示には広げない。
SAFE_PRINTENV_NAMES = frozenset(
    {
        "AWS_DEFAULT_PROFILE",
        "AWS_DEFAULT_REGION",
        "AWS_PROFILE",
        "AWS_REGION",
        "HOME",
        "LANG",
        "LC_ALL",
        "LOGNAME",
        "PATH",
        "PWD",
        "SHELL",
        "TERM",
        "TMPDIR",
        "USER",
    }
)

# allexport (`set -a`) の間、これらの組み込みが作った変数もそのまま環境変数になる。
# {コマンド: 値を取るオプション} — 値と代入先の名前を取り違えないために要る
ALLEXPORT_ASSIGNING_BUILTINS = {
    "read": {"-a", "-d", "-i", "-n", "-N", "-p", "-t", "-u"},
    "readonly": set(),
    "declare": set(),
    "typeset": set(),
    "local": set(),
    "mapfile": {"-d", "-n", "-O", "-s", "-u", "-C", "-c"},
    "readarray": {"-d", "-n", "-O", "-s", "-u", "-C", "-c"},
}
# 代入先を `-v <名前>` で指定する組み込み
ALLEXPORT_NAME_OPTIONS = {"printf": {"-v"}}

# 認証情報や復号済みの機密値を標準出力へ返す AWS のサブコマンド
AWS_CREDENTIAL_SUBCOMMANDS = {
    ("configure", "export-credentials"),
    ("sts", "get-session-token"),
    ("sts", "assume-role"),
    ("sts", "assume-root"),
    ("kms", "generate-data-key"),
    ("kms", "generate-data-key-pair"),
    ("kms", "generate-random"),
    ("ec2", "create-key-pair"),
    ("ec2", "get-password-data"),
    ("redshift", "get-cluster-credentials"),
    ("redshift", "get-cluster-credentials-with-iam"),
    ("apigateway", "get-api-keys"),
    ("apigateway", "get-api-key"),
    ("lightsail", "get-instance-access-details"),
    ("sts", "assume-role-with-web-identity"),
    ("sts", "assume-role-with-saml"),
    ("sts", "get-federation-token"),
    ("ecr", "get-login-password"),
    ("ecr", "get-authorization-token"),
    ("ecr-public", "get-login-password"),
    ("ecr-public", "get-authorization-token"),
    ("secretsmanager", "get-secret-value"),
    ("secretsmanager", "batch-get-secret-value"),
    ("secretsmanager", "get-random-password"),
    ("codeartifact", "get-authorization-token"),
    ("cognito-idp", "initiate-auth"),
    ("cognito-idp", "admin-initiate-auth"),
    ("iam", "create-access-key"),
    ("iam", "create-login-profile"),
    ("iam", "update-login-profile"),
    ("eks", "get-token"),
    ("rds", "generate-db-auth-token"),
    ("kms", "decrypt"),
    ("sso", "get-role-credentials"),
    ("sso-oidc", "create-token"),
    ("acm", "export-certificate"),
    ("acm", "get-acme-external-account-binding-credentials"),
    ("amplifyuibuilder", "exchange-code-for-token"),
    ("amplifyuibuilder", "refresh-token"),
    ("apigateway", "create-api-key"),
    ("appsync", "create-api-key"),
    ("appsync", "list-api-keys"),
    ("appsync", "update-api-key"),
    ("athena", "create-presigned-notebook-url"),
    ("athena", "get-session-endpoint"),
    ("bedrock-agentcore", "get-resource-oauth2-token"),
    ("cloudfront", "sign"),
    ("codecatalyst", "create-access-token"),
    ("codecommit", "credential-helper", "get"),
    ("cognito-identity", "get-credentials-for-identity"),
    ("cognito-idp", "admin-respond-to-auth-challenge"),
    ("cognito-idp", "create-user-pool-client"),
    ("cognito-idp", "describe-user-pool-client"),
    ("cognito-idp", "get-tokens-from-refresh-token"),
    ("cognito-idp", "respond-to-auth-challenge"),
    ("cognito-idp", "update-user-pool-client"),
    ("connect", "get-federation-token"),
    ("datazone", "get-environment-credentials"),
    ("deadline", "assume-fleet-role-for-read"),
    ("deadline", "assume-fleet-role-for-worker"),
    ("deadline", "assume-queue-role-for-read"),
    ("deadline", "assume-queue-role-for-user"),
    ("deadline", "assume-queue-role-for-worker"),
    ("dsql", "generate-db-connect-admin-auth-token"),
    ("dsql", "generate-db-connect-auth-token"),
    ("emr", "get-cluster-session-credentials"),
    ("emr", "get-session-endpoint"),
    ("emr-serverless", "get-session-endpoint"),
    ("finspace-data", "get-external-data-view-access-details"),
    ("finspace-data", "get-programmatic-access-credentials"),
    ("gamelift", "create-build"),
    ("gamelift", "get-compute-access"),
    ("gamelift", "get-compute-auth-token"),
    ("gamelift", "get-instance-access"),
    ("gamelift", "request-upload-credentials"),
    ("glue", "get-session-endpoint"),
    ("grafana", "create-workspace-api-key"),
    ("grafana", "create-workspace-service-account-token"),
    ("iam", "create-service-specific-credential"),
    ("iam", "reset-service-specific-credential"),
    ("iot", "create-keys-and-certificate"),
    ("iot", "create-provisioning-claim"),
    ("lakeformation", "assume-decorated-role-with-saml"),
    ("lakeformation", "get-temporary-data-location-credentials"),
    ("lakeformation", "get-temporary-glue-partition-credentials"),
    ("lakeformation", "get-temporary-glue-table-credentials"),
    ("license-manager", "get-access-token"),
    ("lightsail", "create-bucket-access-key"),
    ("lightsail", "create-container-service-registry-login"),
    ("lightsail", "get-bucket-access-keys"),
    ("lightsail", "get-relational-database-master-user-password"),
    ("redshift-serverless", "get-credentials"),
    ("route53domains", "transfer-domain-to-another-aws-account"),
    ("s3api", "create-session"),
    ("s3", "presign"),
    ("s3control", "get-data-access"),
    ("signin", "create-oauth2-token"),
    ("signin", "create-oauth2-token-with-iam"),
    ("ssm", "get-access-token"),
    ("sso-oidc", "create-token-with-iam"),
    ("sso-oidc", "register-client"),
    ("sts", "get-delegated-access-token"),
    ("amplify", "create-app"),
    ("amplify", "create-branch"),
    ("amplify", "delete-app"),
    ("amplify", "delete-branch"),
    ("amplify", "get-app"),
    ("amplify", "get-branch"),
    ("amplify", "list-apps"),
    ("amplify", "list-branches"),
    ("amplify", "update-app"),
    ("amplify", "update-branch"),
    ("amplifybackend", "create-token"),
    ("amplifybackend", "get-token"),
    ("apigateway", "update-api-key"),
    ("appstream", "create-app-block-builder-streaming-url"),
    ("appstream", "create-image-builder-streaming-url"),
    ("appstream", "create-streaming-url"),
    ("bedrock-agentcore", "get-resource-api-key"),
    ("bedrock-agentcore", "get-resource-payment-token"),
    ("bedrock-agentcore", "get-workload-access-token"),
    ("bedrock-agentcore", "get-workload-access-token-for-jwt"),
    ("bedrock-agentcore", "get-workload-access-token-for-user-id"),
    ("bedrock-agentcore", "process-payment"),
    ("chime", "create-bot"),
    ("chime", "get-bot"),
    ("chime", "list-bots"),
    ("chime", "regenerate-security-token"),
    ("chime", "update-bot"),
    ("chime-sdk-meetings", "batch-create-attendee"),
    ("chime-sdk-meetings", "create-attendee"),
    ("chime-sdk-meetings", "create-meeting-with-attendees"),
    ("chime-sdk-meetings", "get-attendee"),
    ("chime-sdk-meetings", "list-attendees"),
    ("chime-sdk-meetings", "update-attendee-capabilities"),
    ("codebuild", "start-sandbox-connection"),
    ("codecatalyst", "start-dev-environment-session"),
    ("codepipeline", "get-job-details"),
    ("codepipeline", "get-third-party-job-details"),
    ("codepipeline", "poll-for-jobs"),
    ("cognito-identity", "get-open-id-token"),
    ("cognito-identity", "get-open-id-token-for-developer-identity"),
    ("cognito-idp", "add-user-pool-client-secret"),
    ("cognito-idp", "associate-software-token"),
    ("connect", "create-auth-code"),
    ("connect", "start-web-rtc-contact"),
    ("connecthealth", "get-patient-insights-job"),
    ("connectparticipant", "create-participant-connection"),
    ("customer-profiles", "get-upload-job-path"),
    ("devicefarm", "create-test-grid-url"),
    ("ec2", "export-verified-access-instance-client-configuration"),
    ("eks-auth", "assume-role-for-pod-identity"),
    ("emr", "get-on-cluster-app-ui-presigned-url"),
    ("emr", "get-persistent-app-ui-presigned-url"),
    ("emr-containers", "get-managed-endpoint-session-credentials"),
    ("evs", "get-depot-url"),
    ("finspace-data", "reset-user-password"),
    ("gamelift", "get-player-connection-details"),
    ("gameliftstreams", "create-stream-session-admin-shell"),
    ("glue", "batch-get-jobs"),
    ("glue", "get-job"),
    ("glue", "get-jobs"),
    ("inspector2", "create-code-security-integration"),
    ("inspector2", "get-code-security-integration"),
    ("iot", "get-topic-rule"),
    ("iot-managed-integrations", "create-account-association"),
    ("iot-managed-integrations", "get-account-association"),
    ("iot-managed-integrations", "start-account-association-refresh"),
    ("iot-managed-integrations", "create-provisioning-profile"),
    ("iot-managed-integrations", "list-discovered-devices"),
    ("iotsecuretunneling", "open-tunnel"),
    ("iotsecuretunneling", "rotate-tunnel-access-token"),
    ("iotwireless", "associate-aws-account-with-partner-account"),
    ("ivs", "batch-get-stream-key"),
    ("ivs", "create-channel"),
    ("ivs", "create-stream-key"),
    ("ivs", "get-stream-key"),
    ("ivs-realtime", "create-ingest-configuration"),
    ("ivs-realtime", "get-ingest-configuration"),
    ("ivs-realtime", "update-ingest-configuration"),
    ("ivs-realtime", "create-participant-token"),
    ("ivs-realtime", "create-stage"),
    ("ivschat", "create-chat-token"),
    ("kms", "derive-shared-secret"),
    ("lambda-microvms", "create-microvm-auth-token"),
    ("lambda-microvms", "create-microvm-shell-auth-token"),
    ("lexv2-models", "describe-bot-recommendation"),
    ("lexv2-models", "start-bot-recommendation"),
    ("lexv2-models", "update-bot-recommendation"),
    ("license-manager", "create-token"),
    ("lightsail", "create-key-pair"),
    ("lightsail", "download-default-key-pair"),
    ("marketplace-agreement", "get-agreement-entitlements"),
    ("mediapackage", "configure-logs"),
    ("mediapackage", "create-channel"),
    ("mediapackage", "describe-channel"),
    ("mediapackage", "list-channels"),
    ("mediapackage", "rotate-channel-credentials"),
    ("mediapackage", "rotate-ingest-endpoint-credentials"),
    ("mediapackage", "update-channel"),
    ("mwaa", "create-cli-token"),
    ("mwaa", "create-web-login-token"),
    ("pca-connector-scep", "create-challenge"),
    ("pca-connector-scep", "get-challenge-password"),
    ("pcs", "register-compute-node-group-instance"),
    ("quicksight", "generate-embed-url-for-anonymous-user"),
    ("quicksight", "generate-embed-url-for-registered-user"),
    ("quicksight", "generate-embed-url-for-registered-user-with-identity"),
    ("quicksight", "get-dashboard-embed-url"),
    ("quicksight", "get-session-embed-url"),
    ("redshift", "get-identity-center-auth-token"),
    ("redshift-serverless", "get-identity-center-auth-token"),
    ("route53domains", "retrieve-domain-auth-code"),
    ("route53globalresolver", "create-access-token"),
    ("route53globalresolver", "get-access-token"),
    ("sagemaker", "create-partner-app-presigned-url"),
    ("sagemaker", "create-presigned-domain-url"),
    ("sagemaker", "create-presigned-mlflow-app-url"),
    ("sagemaker", "create-presigned-mlflow-tracking-server-url"),
    ("sagemaker", "create-presigned-notebook-instance-url"),
    ("sagemaker", "start-session"),
    ("socialmessaging", "associate-whatsapp-business-account"),
    ("ssm", "create-activation"),
    ("ssm", "resume-session"),
    ("storagegateway", "describe-chap-credentials"),
    ("sts", "get-web-identity-token"),
    ("wafv2", "create-api-key"),
    ("wafv2", "list-api-keys"),
    ("wickr", "create-data-retention-bot-challenge"),
    ("wickr", "get-oidc-info"),
    ("wickr", "get-opentdf-config"),
    ("wickr", "register-oidc-config"),
    ("wickr", "register-opentdf-config"),
    ("workmail", "assume-impersonation-role"),
    ("workspaces-thin-client", "create-environment"),
    ("workspaces-thin-client", "get-environment"),
    ("workspaces-thin-client", "list-environments"),
    ("workspaces-thin-client", "update-environment"),
    ("history", "list"),
    ("history", "show"),
}
# AWS CLI の独自コマンド。標準 API 専用の --generate-cli-skeleton 例外から外す。
AWS_CUSTOM_CREDENTIAL_SUBCOMMANDS = {
    ("configure", "export-credentials"),
    ("cloudfront", "sign"),
    ("codecommit", "credential-helper", "get"),
    ("dsql", "generate-db-connect-admin-auth-token"),
    ("dsql", "generate-db-connect-auth-token"),
    ("ecr", "get-login-password"),
    ("ecr-public", "get-login-password"),
    ("eks", "get-token"),
    ("history", "list"),
    ("history", "show"),
    ("rds", "generate-db-auth-token"),
    ("s3", "presign"),
}
AWS_SAFE_DRY_RUN_SUBCOMMANDS = {
    ("ec2", "create-key-pair"),
    ("ec2", "get-password-data"),
    ("ec2", "export-verified-access-instance-client-configuration"),
    ("kms", "decrypt"),
    ("kms", "derive-shared-secret"),
    ("kms", "generate-data-key"),
    ("kms", "generate-data-key-pair"),
}
AWS_SSM_DECRYPT_SUBCOMMANDS = {
    ("ssm", "get-parameter"),
    ("ssm", "get-parameter-history"),
    ("ssm", "get-parameters"),
    ("ssm", "get-parameters-by-path"),
}
# 認証状態を変える AWS の操作。利用者が開始するものとして確認へ回す
AWS_CONFIRM_SUBCOMMANDS = {
    ("login",),
    ("logout",),
    ("sso", "login"),
    ("sso", "logout"),
    ("configure", "sso"),
    ("configure", "sso-session"),
    ("configure", "set"),
    ("configure", "import"),
}
AWS_PAGER_ENV_VARS = {"AWS_PAGER", "PAGER"}
AWS_HELP_PAGER_ENV_VARS = {"MANPAGER", "PAGER"}
# `aws configure get <name>` は保存済みの設定値を出力する。
# region のような無害な項目もあるため、名前が認証情報を指す場合だけ拒否する
AWS_CONFIGURE_SECRET_MARKERS = frozenset(
    {
        "aws_access_key_id",
        "aws_secret_access_key",
        "aws_session_token",
        "aws_security_token",
    }
)

# gcloud / az のリリーストラック接頭辞。サブコマンドの位置をずらす
RELEASE_TRACK_PREFIXES = {"alpha", "beta", "preview", "gcloud"}
SECRET_TOOL_REASON = (
    "認証情報や復号済みの値を標準出力へ返すコマンドの実行は許可していません。"
)
PROCESS_INSPECTION_REASON = (
    "他プロセスの環境変数や完全な引数には認証情報が含まれうるため、"
    "それらを直接出力する操作は許可していません。"
)
SHELL_HISTORY_REASON = (
    "シェル履歴には過去に入力した認証情報が含まれうるため、"
    "履歴を直接出力する操作は許可していません。"
)

# 認証情報を標準出力へ返すコマンドとサブコマンドの対応。
# {コマンド: (値を取るグローバルオプション, {サブコマンド語の並び, ...})}
# サブコマンド語は先頭からの一致で判定する
SECRET_TOOL_SUBCOMMANDS = {
    "vault": (
        {"-address", "-namespace", "-format", "-field", "-mount", "-ca-cert"},
        {
            ("kv", "get"),
            ("read",),
            # write は PKI の秘密鍵・transit の復号結果・動的認証情報を返す
            ("write",),
            ("login",),
            ("unwrap",),
            ("token", "create"),
            ("token", "lookup"),
            ("print", "token"),
            ("operator", "init"),
            ("operator", "generate-root"),
        },
    ),
    "gcloud": (
        {
            "--project",
            "--account",
            "--format",
            "--configuration",
            "--impersonate-service-account",
        },
        {
            ("auth", "print-access-token"),
            ("auth", "print-identity-token"),
            ("auth", "application-default", "print-access-token"),
            ("secrets", "versions", "access"),
            ("iam", "service-accounts", "keys", "create"),
            ("sql", "generate-login-token"),
        },
    ),
    "az": (
        {
            "--subscription",
            "--output",
            "-o",
            "--query",
            "--resource-group",
            "-g",
            "--vault-name",
            "--name",
            "-n",
        },
        {
            ("account", "get-access-token"),
            ("keyvault", "secret", "show"),
            ("keyvault", "secret", "download"),
            ("keyvault", "key", "download"),
            ("keyvault", "certificate", "download"),
            ("ad", "sp", "credential", "reset"),
            ("ad", "app", "credential", "reset"),
            ("storage", "account", "keys", "list"),
            ("storage", "account", "keys", "renew"),
            ("storage", "account", "generate-sas"),
            ("acr", "credential", "show"),
        },
    ),
}

# kubectl は他と形が違うため個別に扱う
KUBECTL_VALUE_OPTIONS = {
    "-n",
    "--namespace",
    "-o",
    "--output",
    "--context",
    "--kubeconfig",
    "--cluster",
    "--user",
    "-l",
    "--selector",
    "--server",
    "-s",
    "--kuberc",
    "--proxy-url",
    "--loglevel",
    "--token",
    "--as",
    "--as-group",
    "--as-uid",
    "--as-user-extra",
    "--cache-dir",
    "--certificate-authority",
    "--client-certificate",
    "--client-key",
    "--cluster",
    "--field-selector",
    "--log-flush-frequency",
    "--password",
    "--profile",
    "--profile-output",
    "--request-timeout",
    "--tls-server-name",
    "--username",
    "-v",
    "--v",
    "--vmodule",
}
KUBECTL_REMOTE_CHILD_VALUE_OPTIONS = KUBECTL_VALUE_OPTIONS | {
    "-c",
    "--container",
    "-f",
    "--filename",
    "--pod-running-timeout",
    "--shell",
}
# 認証情報を標準出力へ返す kubectl のサブコマンド (config view --raw と get secret は個別に判定)
KUBECTL_SECRET_SUBCOMMANDS = {
    ("create", "token"),
}
ROSA_OCM_SECRET_CONFIG_NAMES = {
    "access_token",
    "client_secret",
    "password",
    "refresh_token",
}

# 認証状態を変える操作。deny ではなく確認へ回す。
# {コマンド: (値を取るグローバルオプション, {サブコマンド語の並び, ...})}
AUTH_CHANGE_SUBCOMMANDS = {
    "gcloud": (
        {"--project", "--account", "--format", "--configuration"},
        {
            ("auth", "login"),
            ("auth", "revoke"),
            ("auth", "application-default", "login"),
            ("auth", "application-default", "revoke"),
        },
    ),
    "az": (
        {"--subscription", "--output", "-o", "--query"},
        {("login",), ("logout",)},
    ),
    "vault": (
        {"-address", "-namespace", "-format", "-field", "-mount", "-ca-cert"},
        {
            ("login",),
            ("auth", "enable"),
            ("auth", "disable"),
            ("token", "revoke"),
        },
    ),
}

# サンドボックス外で実行される docker から、マウント経由での参照を禁止するパス
SENSITIVE_MOUNT_PATHS = (
    ".aws",
    ".ssh",
    ".kube",
    ".docker",
    ".gnupg",
    ".codex",
    ".claude",
    ".config/gh",
    ".netrc",
    ".terraform.d",
    "Library/Keychains",
)
SENSITIVE_ABSOLUTE_MOUNT_PATHS = ("/Library/Keychains",)
CREDENTIAL_FILE_REASON = (
    "認証情報ファイルを引数に取るコマンドの実行は許可していません。"
)
# ホーム基準の相対パスで表した認証情報の格納場所。
# .aws/load-active-profile.sh のような同じディレクトリ配下の無害なファイルまで
# 拒否しないよう、ディレクトリ全体ではなく実際の格納先だけを列挙する
CREDENTIAL_FILE_COMPONENTS = (
    ".aws/credentials",
    ".aws/config",
    ".aws/login",
    ".aws/sso",
    ".aws/cli",
    ".ssh",
    ".gnupg",
    ".docker/config.json",
    ".config/gh/hosts.yml",
    ".config/gcloud",
    ".config/containers/auth.json",
    ".local/share/uv/credentials",
    ".ocm.json",
    ".config/ocm/ocm.json",
    "Library/Application Support/ocm/ocm.json",
    ".config/helm/repositories.yaml",
    ".config/helm/registry/config.json",
    "Library/Preferences/helm/repositories.yaml",
    "Library/Preferences/helm/registry/config.json",
    ".kube/config",
    ".codex/auth.json",
    ".codex/history.jsonl",
    ".codex/sessions",
    ".codex/archived_sessions",
    ".codex/shell_snapshots",
    ".claude/.credentials.json",
    ".claude/history.jsonl",
    ".claude/projects",
    ".claude/file-history",
    ".claude/paste-cache",
    ".claude/shell-snapshots",
    ".claude.json",
    ".claude.json.backup",
    ".claude/backups",
    ".terraform.d/credentials.tfrc.json",
    ".terraformrc",
    ".vault-token",
    ".azure",
    ".cargo/credentials.toml",
    ".cargo/credentials",
    ".curlrc",
    ".wgetrc",
    ".bundle/config",
    ".config/composer/auth.json",
    ".composer/auth.json",
    ".config/pypoetry/auth.toml",
    "Library/Application Support/pypoetry/auth.toml",
    ".config/pip/pip.conf",
    ".pip/pip.conf",
    "Library/Application Support/pip/pip.conf",
    ".zsh_sessions",
    ".bash_sessions",
    "Library/Keychains",
)
CREDENTIAL_ABSOLUTE_PATHS = ("/Library/Keychains",)
# パスの位置に関係なく認証情報とみなすファイル名
CREDENTIAL_FILE_NAMES = (
    ".git-credentials",
    ".netrc",
    ".pgpass",
    ".pg_service.conf",
    "pg_service.conf",
    ".npmrc",
    ".pypirc",
    ".zsh_history",
    ".bash_history",
    "fish_history",
    "pip.conf",
    "key.pem",
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
)
# パスの位置に関係なく認証情報の置き場とみなすディレクトリ名。
# .gitignore が secrets/ と credentials/ を除外しているのと対にする
CREDENTIAL_DIRECTORY_NAMES = ("secrets", "credentials")
# 基準ディレクトリを差し替えても保管先を指す部分パス。
# gh は XDG_CONFIG_HOME があればそちらを設定・認証情報の置き場にする
CREDENTIAL_PATH_FRAGMENTS = (
    "gh/hosts.yml",
    "gcloud/application_default_credentials.json",
    "gcloud/credentials.db",
    "gcloud/access_tokens.db",
    "ocm/ocm.json",
    "helm/repositories.yaml",
    "helm/registry/config.json",
    "uv/credentials",
    ".cargo/credentials.toml",
    "cargo/credentials.toml",
    ".composer/auth.json",
    "composer/auth.json",
)
# 拡張子だけで認証情報と判断できる秘密鍵・証明書ストア
CREDENTIAL_FILE_SUFFIXES = (
    ".p12",
    ".pfx",
    ".p8",
    ".ppk",
    ".key",
    ".keystore",
    ".jks",
    ".kdbx",
)
# PEM / DER は公開証明書にも使われるため、境界付きの秘密鍵名だけを対象にする
PRIVATE_KEY_CONTAINER_SUFFIXES = (".pem", ".der")
PRIVATE_KEY_STEM_NAMES = (
    "priv",
    "private",
    "client-key",
    "client_key",
    "server-key",
    "server_key",
    "tls-key",
    "tls_key",
)
PRIVATE_KEY_STEM_MARKERS = (
    "privkey",
    "priv-key",
    "priv_key",
    "privatekey",
    "private-key",
    "private_key",
)
PRIVATE_KEY_STEM_PREFIXES = ("priv-", "priv_")
PRIVATE_KEY_STEM_SUFFIXES = ("-priv", "_priv", "-private", "_private")
# 静的 path deny と異なり `.pub` を除外できるため、`id_ed25519_work` のような
# 接尾辞付き秘密鍵も前方一致で対象にする
CREDENTIAL_FILE_PREFIXES = ("id_rsa", "id_dsa", "id_ecdsa", "id_ed25519")
# 名前の途中に現れても保管先とみなす部分文字列。
# terraform state は平文の秘密値を含みうるうえ、`terraform.tfstate.backup` の
# ように接尾辞が変わるため、接尾辞ではなく部分一致で見る
CREDENTIAL_FILE_INFIXES = (".tfstate",)
# 環境変数ファイル。Claude の作業ディレクトリ・ホーム向け Read deny と対にする。
# 値を持たない雛形は追跡してよいため、除外する
DOTENV_TEMPLATE_NAMES = (
    ".env.example",
    ".env.sample",
    ".env.template",
    ".env.dist",
)

# $HOME / ${HOME} の展開先は一意なので、解析の前に実際のパスへ置き換える。
# こうすると `~` と同じ経路で判定でき、`-v "$HOME":/host` のように
# ホーム全体を渡す指定も見えるようになる。
# 空白やシェル記号を含むホームは、置き換えると語の分割やクォートの意味が
# 変わってしまうため、その場合だけ従来どおりマーカーのままにする
HOME_PATH = os.path.expanduser("~")
HOME_IS_SUBSTITUTABLE = (
    bool(HOME_PATH) and re.fullmatch(r"[A-Za-z0-9_./-]+", HOME_PATH) is not None
)

# 相対パスの基準。PreToolUse イベントの cwd で上書きする (main を参照)。
# これが無いと `-v ../../..:/host` のような指定を解決できない
WORKING_DIRECTORY = os.getcwd()

# `--flag=true` のように値で有効化される真偽オプションの値
# Docker が使う pflag は `t` / `T` も true として受け取る
BOOLEAN_TRUE_VALUES = {"true", "t", "1", "yes", "y", "on"}

# 名前で機密とみなす環境変数。値そのものが秘密か、認証エージェントへ届く。
# 展開の中身は解決できないため、この名前が使われたことをマーカーへ残す
SENSITIVE_PARAMETER_NAMES = {
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "GPG_AGENT_INFO",
    "DOCKER_HOST",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_ACCESS_KEY_ID",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "NPM_TOKEN",
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "COMPOSER_AUTH",
    "HELM_KUBETOKEN",
    "PGPASSWORD",
}
# 値ではなく、認証エージェントや接続先を指す通常設定。
NON_SECRET_RUNTIME_PARAMETER_NAMES = {
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "GPG_AGENT_INFO",
    "DOCKER_HOST",
}
# 値そのものは秘密でないが、認証情報の保存先を指す環境変数。
# 内容読み取りは拒否し、厳密な test -e / test -f だけは許可する。
CREDENTIAL_PATH_PARAMETER_NAMES = {
    "AWS_CONFIG_FILE",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
    "AWS_LOGIN_CACHE_DIRECTORY",
    "AWS_SHARED_CREDENTIALS_FILE",
    "AWS_WEB_IDENTITY_TOKEN_FILE",
    "AZURE_CONFIG_DIR",
    "BUNDLE_USER_CONFIG",
    "CARGO_HOME",
    "CLOUDSDK_CONFIG",
    "COMPOSER_HOME",
    "DOCKER_CERT_PATH",
    "DOCKER_CONFIG",
    "GH_CONFIG_DIR",
    "GNUPGHOME",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "HELM_CONFIG_HOME",
    "HELM_REGISTRY_CONFIG",
    "HELM_REPOSITORY_CONFIG",
    "KUBECONFIG",
    "NETRC",
    "NPM_CONFIG_USERCONFIG",
    "OCM_CONFIG",
    "PGPASSFILE",
    "PGSERVICEFILE",
    "PGSSLKEY",
    "PGSYSCONFDIR",
    "PIP_CONFIG_FILE",
    "REGISTRY_AUTH_FILE",
    "TF_CLI_CONFIG_FILE",
    "UV_CREDENTIALS_DIR",
    "WGETRC",
    "npm_config_userconfig",
}
PROXY_PARAMETER_NAMES = frozenset(
    {
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "FTP_PROXY",
        "PIP_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "ftp_proxy",
        "pip_proxy",
    }
)
CREDENTIAL_VARIABLE_REASON = (
    "認証情報を持つ環境変数へ平文を設定したり、その値をコマンドの引数へ"
    "展開したりする操作は許可していません。"
)

DOCKER_VALUE_OPTIONS = {
    "-H",
    "--host",
    "-c",
    "--context",
    "--config",
    "--log-level",
    "--tlscacert",
    "--tlscert",
    "--tlskey",
}
# CLI プラグインの探索先を差し替える環境変数。
DOCKER_EXEC_ENV_VARS = {
    "DOCKER_CLI_PLUGIN_EXTRA_DIRS",
}
# 認証情報そのものをビルドへ渡す環境変数。
# 外部状態の変更 (確認) ではなく、認証情報の受け渡しとして拒否する
DOCKER_CREDENTIAL_ENV_VARS = {
    "BUILDX_BAKE_GIT_AUTH_TOKEN",
    "BUILDX_BAKE_GIT_AUTH_HEADER",
}
# SSH agent の socket をビルドへ渡す環境変数
DOCKER_SSH_ENV_VARS = {"BUILDX_BAKE_GIT_SSH"}
DOCKER_EXEC_ENV_REASON = (
    "docker の CLI プラグイン探索先を差し替える環境変数の指定は"
    "許可していません (別の実行体へ向けられるため)。"
)
DOCKER_MOUNT_OPTIONS = {"-v", "--volume", "--mount"}
# ファイルの内容をそのままコンテナへ渡すオプション。マウントと同じ経路になる
DOCKER_FILE_OPTIONS = {"--env-file", "--label-file", "--secret", "--build-context"}
# ホストの環境変数をコンテナへ引き継ぐオプション
DOCKER_ENV_OPTIONS = {"-e", "--env", "--build-arg"}
# build / buildx build の値付きオプション。main context 以外の既存
# ディレクトリを context と誤認しないため、位置引数から値を除く。
DOCKER_BUILD_VALUE_OPTIONS = {
    "--add-host",
    "--allow",
    "--annotation",
    "--attest",
    "--build-arg",
    "--build-context",
    "--builder",
    "--cache-from",
    "--cache-to",
    "--call",
    "--cgroup-parent",
    "--cpu-period",
    "--cpu-quota",
    "-c",
    "--cpu-shares",
    "--cpuset-cpus",
    "--cpuset-mems",
    "-f",
    "--file",
    "--iidfile",
    "--isolation",
    "--label",
    "--metadata-file",
    "-m",
    "--memory",
    "--memory-swap",
    "--network",
    "--no-cache-filter",
    "-o",
    "--output",
    "--platform",
    "--policy",
    "--print",
    "--progress",
    "--provenance",
    "--resource",
    "--sbom",
    "--secret",
    "--security-opt",
    "--shm-size",
    "--ssh",
    "-t",
    "--tag",
    "--target",
    "--ulimit",
}
DOCKER_BUILD_SHORT_BOOLEAN_FLAGS = {"D", "q"}
DOCKER_COMPOSE_VALUE_OPTIONS = {
    "--ansi",
    "--env-file",
    "-f",
    "--file",
    "--parallel",
    "--profile",
    "--progress",
    "--project-directory",
    "-p",
    "--project-name",
}
# run / create / exec / service create で child の直前に置ける値付き option。
# 共通する build option を再利用し、各 `--help` に載る残りを補う。
# 未知 option は下の候補探索で両方の解釈を残すため、新しい option が増えても
# 検査が緩むことはない。
DOCKER_EXEC_CHILD_VALUE_OPTIONS = (DOCKER_BUILD_VALUE_OPTIONS - {"-t"}) | set(
    """
    -a -e -h -l -p -u -v -w
    --annotation --attach --blkio-weight --blkio-weight-device --cap-add --cap-drop
    --cgroupns --cidfile --config --constraint --container-label --cpu-count
    --cpu-percent --cpu-rt-period --cpu-rt-runtime --cpus --credential-spec
    --detach-keys --device --device-cgroup-rule --device-read-bps --device-read-iops
    --device-write-bps --device-write-iops --dns --dns-option --dns-search
    --domainname --endpoint-mode --entrypoint --env --env-file --expose --file
    --generic-resource --gpus --group --group-add --health-cmd --health-interval
    --health-retries --health-start-interval --health-start-period --health-timeout
    --host --hostname --index --io-maxbandwidth --io-maxiops --ip --ip6 --ipc
    --isolation --label-file --limit-cpu --limit-memory --limit-pids --link
    --link-local-ip --log-driver --log-opt --mac-address --max-concurrent
    --memory-reservation --memory-swappiness --mode --mount --name --network-alias
    --oom-score-adj --pid --pids-limit --placement-pref --profile --project-directory
    --project-name --publish --pull --replicas --replicas-max-per-node --reserve-cpu
    --reserve-memory --restart --restart-condition --restart-delay
    --restart-max-attempts --restart-window --rollback-delay --rollback-failure-action
    --rollback-max-failure-ratio --rollback-monitor --rollback-order
    --rollback-parallelism --runtime --stop-grace-period --stop-signal --stop-timeout
    --storage-opt --sysctl --tmpfs --update-delay --update-failure-action
    --update-max-failure-ratio --update-monitor --update-order --update-parallelism
    --user --userns --uts --volume --volume-driver --volumes-from --workdir
    """.split()
)
# run / create / exec 系で値を取らない共通オプション。child 境界の探索では、
# これらを値付きかもしれない未知 option として分岐させない。
DOCKER_EXEC_CHILD_BOOLEAN_OPTIONS = {
    "-d",
    "--detach",
    "--help",
    "-i",
    "--interactive",
    "--init",
    "--no-healthcheck",
    "--no-resolve-image",
    "--no-tty",
    "--oom-kill-disable",
    "-P",
    "--privileged",
    "--publish-all",
    "-q",
    "--quiet",
    "--read-only",
    "--remove-orphans",
    "--rm",
    "--service-ports",
    "--sig-proxy",
    "-t",
    "-T",
    "--tty",
    "--use-aliases",
    "--use-api-socket",
    "--with-registry-auth",
}
DOCKER_EXEC_CHILD_SHORT_BOOLEAN_FLAGS = {
    option[1:]
    for option in DOCKER_EXEC_CHILD_BOOLEAN_OPTIONS
    if option.startswith("-") and not option.startswith("--") and len(option) == 2
}
DOCKER_GLOBAL_SHORT_BOOLEAN_FLAGS = {"D", "v"}
CONTAINER_COMPOSE_CONFIG_SAFE_OPTIONS = {
    "-q",
    "--quiet",
    "--hash",
    "--images",
    "--models",
    "--profiles",
    "--services",
    "--volumes",
}
# 読み取りだけで済む docker の操作。
# ここに無い操作は、外部やホストの状態を変えうるものとして確認へ回す。
# `inspect` / `history` / `compose config` は、下の個別判定で安全な固定 format
# または集約出力だと確認できた形だけここへ到達する。
CONTAINER_READONLY_SUBCOMMANDS = (
    ("inspect",),
    ("history",),
    ("ps",),
    ("top",),
    ("images",),
    ("info",),
    ("version",),
    ("logs",),
    ("stats",),
    ("port",),
    ("diff",),
    ("search",),
    ("events",),
    ("help",),
    ("image", "ls"),
    ("image", "inspect"),
    ("image", "history"),
    ("container", "ls"),
    ("container", "top"),
    ("container", "inspect"),
    ("container", "logs"),
    ("container", "port"),
    ("container", "diff"),
    ("container", "stats"),
    ("volume", "ls"),
    ("network", "ls"),
    ("secret", "inspect"),
    ("system", "df"),
    ("system", "info"),
    ("system", "events"),
    ("context", "ls"),
    ("context", "show"),
    ("context", "export"),
    ("builder", "ls"),
    ("buildx", "ls"),
    ("buildx", "version"),
    ("compose", "ps"),
    ("compose", "top"),
    ("compose", "config"),
    ("compose", "convert"),
    ("compose", "ls"),
    ("compose", "logs"),
    ("compose", "images"),
    ("compose", "port"),
    ("compose", "events"),
    ("compose", "version"),
    ("plugin", "ls"),
    ("pass", "get"),
    ("pass", "ls"),
    ("pass", "run"),
    ("service", "inspect"),
    ("node", "ls"),
    ("stack", "config"),
)
# 読み取り側のサブコマンドに付いても状態を変えるオプション。
# `docker buildx inspect --bootstrap` はビルダーのコンテナを起動する
CONTAINER_STATE_CHANGING_OPTIONS = {"--bootstrap"}
# 読み取りでも、切り詰めを解除すると引数やラベルが丸ごと出る
CONTAINER_UNSAFE_OUTPUT_OPTIONS = {"--no-trunc"}
# 出力テンプレートで参照してよいフィールド。
# 危険なフィールド名を並べる方式は `json` や `{{index . "Command"}}` で
# すり抜けられるため、安全と分かるフィールドだけを許す allowlist にする
CONTAINER_SAFE_FORMAT_FIELDS = {
    "id",
    "containerid",
    "name",
    "names",
    "image",
    "imageid",
    "repository",
    "tag",
    "digest",
    "status",
    "state",
    "health",
    "createdat",
    "createdsince",
    "runningfor",
    "size",
    "networks",
    "network",
    "ports",
    "publishers",
    "service",
    "project",
    "driver",
    "scope",
    "mountpoint",
    "platform",
    "type",
    # docker stats
    "container",
    "cpuperc",
    "memusage",
    "memperc",
    "netio",
    "blockio",
    "pids",
    # docker version (`{{.Server.Version}}` のような入れ子も、
    # 構成要素がすべてここに載っている場合だけ通す)
    "server",
    "serverversion",
    "client",
    "version",
    "apiversion",
    "minapiversion",
    "gitcommit",
    "buildtime",
    "goversion",
    "os",
    "arch",
    "kernelversion",
    "experimental",
}
# 親要素全体は危険でも、この完全パスだけは秘密値を含まない。
CONTAINER_SAFE_FORMAT_PATHS = {("config", "image")}
CONTAINER_FORMAT_REFERENCE_RE = re.compile(r"\{\{([^{}]*)\}\}")
CONTAINER_FORMAT_FIELD_RE = re.compile(
    r"^(?:\.[A-Za-z][A-Za-z0-9]*)+$"
)
EXTERNAL_STATE_CONFIRM_REASON = (
    "サンドボックス外で外部やホストの状態を変えうる操作のため、"
    "実行前に確認してください。"
)
# BuildKit の --secret は id=/src=/env=/type= のフィールド形式を取る。
# env= はホストの環境変数をそのままビルドへ渡し、src= が無い場合は
# id= と同じ名前の環境変数を暗黙に読む
DOCKER_SECRET_ENV_FIELDS = {"env"}
DOCKER_SECRET_PATH_FIELDS = {"src", "source", "file"}
DOCKER_SECRET_ID_FIELDS = {"id"}
# SSH agent の socket と秘密鍵をビルドへ転送するオプション
DOCKER_SSH_OPTIONS = {"--ssh"}
# buildx bake は `--set TARGET.FIELD=VALUE` で各ターゲットの設定を上書きできる。
# secret / ssh / context はビルド用のオプションと同じ意味を持つ
DOCKER_BAKE_OPTIONS = {"--set"}
DOCKER_BAKE_SECRET_FIELDS = {"secret", "secrets"}
DOCKER_BAKE_SSH_FIELDS = {"ssh"}
DOCKER_BAKE_PATH_FIELDS = {"context", "contexts", "dockerfile"}
# buildx の entitlement。ビルドコンテキストの外を読み書きできるようになる
DOCKER_ALLOW_OPTIONS = {"--allow"}
DOCKER_RISKY_ENTITLEMENTS = {
    "fs",
    "fs.read",
    "fs.write",
    "security.insecure",
    "network.host",
}
DOCKER_ENTITLEMENT_REASON = (
    "buildx の --allow はビルドコンテキストの外を読み書きできるようにするため"
    "許可していません。"
)
DOCKER_SSH_REASON = (
    "docker の --ssh は SSH agent の socket や秘密鍵をビルドへ渡すため"
    "許可していません。"
)
# コンテナから Docker API へ到達できる指定。
# コンテナ側で、この検査を通らないマウントを新たに作れてしまう
DOCKER_API_SOCKET_OPTIONS = {"--use-api-socket"}
# ホストの socket をコンテナへ渡すマウント (docker.sock, ssh-agent など)
SOCKET_PATH_SUFFIX = ".sock"
# 拡張子を持たない socket の置き場 (macOS の launchd や gpg-agent など)
SOCKET_PATH_MARKERS = (
    "/listeners",
    "com.apple.launchd",
    "/s.gpg-agent",
    "/agent.",
)
# ビルドコンテキストを引数に取るサブコマンド (末尾の位置引数がホストのパスになる)
DOCKER_BUILD_SUBCOMMANDS = (
    ("build",),
    ("buildx", "build"),
    ("buildx", "b"),
    ("builder", "build"),
    ("image", "build"),
)
# ホストとコンテナの間でファイルを直接やり取りするサブコマンド
DOCKER_COPY_SUBCOMMANDS = (
    ("cp",),
    ("container", "cp"),
    ("compose", "cp"),
)
CONTAINER_COMMANDS = {"docker", "podman", "nerdctl"}
# 名前だけで認証情報とみなす環境変数の部分文字列。
# Codex の既定除外 (*KEY* / *SECRET* / *TOKEN*) と同じ考え方で、
# 値を見ずに名前で判定する
CREDENTIAL_ENV_MARKERS = (
    "KEY",
    "SECRET",
    "TOKEN",
    "PASSWORD",
    "PASSWD",
    "CREDENTIAL",
)
# シェル変数の展開を判定するときは、`_` で区切った語単位で照合する。
# 部分一致にすると KEYBOARD_LAYOUT や SECRETARY のような無関係な名前まで拾う
CREDENTIAL_ENV_WORDS = frozenset(
    {
        "KEY",
        "KEYS",
        "SECRET",
        "SECRETS",
        "TOKEN",
        "TOKENS",
        "PASSWORD",
        "PASSWORDS",
        "PASSWD",
        "CREDENTIAL",
        "CREDENTIALS",
        "APIKEY",
        "PRIVATEKEY",
    }
)

# git に渡すと外部コマンドを起動する設定キー。
# git -c <key>=<コマンド> は、ここまでの検査をすべて迂回して任意の実行体を起こせる
GIT_EXEC_CONFIG_KEYS = {
    "core.pager",
    "core.editor",
    "core.sshcommand",
    "core.fsmonitor",
    "core.hookspath",
    "core.askpass",
    "core.gitproxy",
    "sequence.editor",
    "diff.external",
    "credential.helper",
    "gpg.program",
    "gpg.openpgp.program",
    "ssh.variant",
    "filter.lfs.process",
    "filter.lfs.clean",
    "filter.lfs.smudge",
    "uploadpack.packobjectshook",
}
# 別ファイルを読み込ませる設定キー。読み込ませた先で alias や
# credential.helper、core.hooksPath を定義できるため、上と同じ扱いにする
GIT_INCLUDE_CONFIG_PREFIXES = ("include.path", "includeif.")
# URL 単位で書ける設定キー。`credential.https://example.com.helper` のように
# 途中に任意の語が入るため、完全一致ではなく (先頭, 末尾) の組で照合する。
# protocol.<name>.allow は ext:: リモートを解禁し、任意コマンドの起動になる
GIT_EXEC_CONFIG_KEY_SHAPES = (
    ("credential.", "helper"),
    ("credential.", "askpass"),
    ("protocol.", "allow"),
    ("url.", "insteadof"),
    ("url.", "pushinsteadof"),
)
# 同じ効果を持つ環境変数 (代入形式で前置される)
GIT_EXEC_ENV_VARS = {
    "GIT_PAGER",
    "PAGER",
    "GIT_EDITOR",
    "GIT_SEQUENCE_EDITOR",
    "GIT_SSH",
    "GIT_SSH_COMMAND",
    "GIT_EXTERNAL_DIFF",
    "GIT_ASKPASS",
    "SSH_ASKPASS",
    "LESSOPEN",
    "LESSCLOSE",
    "GIT_PROXY_COMMAND",
    # 設定そのものを注入する環境変数。-c と同じことができる
    "GIT_CONFIG",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_COUNT",
    # 1 つの文字列に設定をまとめて注入する。-c と同じことができる
    "GIT_CONFIG_PARAMETERS",
    "GIT_EXEC_PATH",
    "GIT_TEMPLATE_DIR",
}
# 連番の接尾辞を持つため、前方一致で判定する環境変数
GIT_EXEC_ENV_PREFIXES = ("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")
# 取り消しにくい、またはフックを迂回する git 操作。
# {サブコマンド: (長いオプション, 短いフラグ 1 文字)}
# 両方が空の場合は、オプションによらず確認へ回す
# `git push` 固有の、値を取るオプションと確認が要るオプション
GIT_PUSH_VALUE_OPTIONS = {
    "--repo",
    "-o",
    "--push-option",
    "--receive-pack",
    "--exec",
    "--recurse-submodules",
    "--signed",
    "--force-with-lease",
}
GIT_PUSH_CONFIRM_OPTIONS = {"--mirror", "--prune"}
# remote 側で起動するプログラムを指定するオプション。
# remote がローカルパスの場合はそのまま任意のコマンドの起動になる
GIT_EXEC_PATH_OPTIONS = {"--receive-pack", "--upload-pack", "--exec"}
GIT_CONFIRM_OPTIONS = {
    "push": (
        {"--force", "--force-with-lease", "--force-if-includes", "--delete", "--no-verify"},
        {"f", "d"},
    ),
    "reset": ({"--hard"}, set()),
    "clean": ({"--force"}, {"f"}),
    "commit": ({"--no-verify"}, {"n"}),
    "merge": ({"--no-verify"}, set()),
    "rebase": ({"--no-verify"}, set()),
    "filter-branch": (set(), set()),
    # 作業ツリーの変更を捨てる。restore は捨てるのが既定の動作
    "restore": (set(), set()),
    "switch": ({"--discard-changes", "--force"}, {"f"}),
    # `git checkout -- <path>` も同じく変更を捨てる (`--` は下で別途見る)
    "checkout": ({"--force"}, {"f"}),
    # 参照を消す操作
    "branch": ({"--delete", "--force"}, {"d", "D"}),
    "tag": ({"--delete"}, {"d"}),
    "update-ref": ({"--delete"}, {"d"}),
    "worktree": ({"--force"}, {"f"}),
    # 到達不能オブジェクトの削除。reflog ごと消えると復元できない
    "prune": (set(), set()),
    "gc": ({"--prune"}, set()),
}
# 語の並びで判る、取り消しにくい git 操作
GIT_CONFIRM_SUBCOMMANDS = {
    ("stash", "clear"),
    ("stash", "drop"),
    ("reflog", "expire"),
    ("reflog", "delete"),
    ("submodule", "deinit"),
    ("worktree", "remove"),
    ("worktree", "prune"),
}
# `git config` の読み取り形式と書き込み・編集形式。
# 書き込みは設定ファイルへ残り、後続の git から効いてしまう
# (`-c` の一時指定と同じ経路が永続化する)
GIT_CONFIG_VALUE_OPTIONS = {
    "-f",
    "--file",
    "--blob",
    "--type",
    "-t",
    "--default",
    "--comment",
    "--value",
    "--url",
}
GIT_CONFIG_READ_OPTIONS = {
    "--get",
    "--get-all",
    "--get-regexp",
    "--get-urlmatch",
    "--get-color",
    "--get-colorbool",
    "--list",
    "-l",
}
GIT_CONFIG_READ_SUBCOMMANDS = {"list", "get"}
GIT_CONFIG_WRITE_OPTIONS = {
    "--add",
    "--unset",
    "--unset-all",
    "--replace-all",
    "--rename-section",
    "--remove-section",
    "--edit",
    "-e",
}
GIT_CONFIG_WRITE_SUBCOMMANDS = {
    "set",
    "unset",
    "edit",
    "rename-section",
    "remove-section",
}
GIT_EXEC_INJECTION_REASON = (
    "外部コマンドを起動させる git の設定 (core.pager など) や "
    "同等の環境変数の指定は許可していません "
    "(検査を迂回して任意のコマンドを起動できるため)。"
)
GIT_CONFIG_SECRET_REASON = (
    "git config で認証情報を含みうる proxy / HTTP header 設定を表示する操作は"
    "許可していません。"
)

# インタプリタへコードを直接渡すオプション。
# 渡された中身はシェルとして解析できないため、静的検査が及ばない。
# awk は第 1 位置引数がコード本体になる点が他と異なる
INTERPRETER_CODE_OPTIONS = {
    "awk": {"-e", "--source"},
    "gawk": {"-e", "--source"},
    "perl": {"-e", "-E"},
    "python": {"-c"},
    "python3": {"-c"},
    "ruby": {"-e"},
    "node": {"-e", "-p", "--eval", "--print"},
    "php": {"-r"},
    "osascript": {"-e"},
}
# コード本体が第 1 位置引数になるインタプリタ
INTERPRETER_POSITIONAL_CODE = {"awk", "gawk"}
# 値を取らない短縮フラグ。`perl -we 'コード'` のようにコードオプションと
# ひとかたまりに書かれた形を分解するために読み飛ばす
INTERPRETER_FLAG_LETTERS = {
    "perl": "wnpacsTdWXuvVh",
    "ruby": "nplacdwvy",
    "node": "i",
    "python": "BEIObdisuvqx",
    "python3": "BEIObdisuvqx",
    "php": "nqvzh",
    "awk": "",
    "gawk": "",
    "osascript": "hi",
}
# 直後の数字だけを値として取る短縮オプション。
# `perl -0777e 'コード'` は `-0777` と `-e` の並びなので、数字を食べてから
# 走査を続けないと `-e` に届かない
INTERPRETER_DIGIT_LETTERS = {
    "perl": "0lC",
    "ruby": "WT0",
    "node": "",
    "python": "",
    "python3": "",
    "php": "",
    "awk": "",
    "gawk": "",
    "osascript": "",
}
# 塊の残り全部 (無ければ次の引数) を値として取る短縮オプション。
# ここから先はオプションではなく値なので、走査を打ち切る
INTERPRETER_VALUE_LETTERS = {
    "perl": "IiFmMDx",
    "ruby": "IrEKCFxi",
    "node": "r",
    "python": "WXQm",
    "python3": "WXQm",
    "php": "d",
    "awk": "Ffv",
    "gawk": "Ffv",
    "osascript": "ls",
}
INTERPRETER_CLUSTER_REASON = (
    "インタプリタの短縮オプションを構文どおり分解できませんでした。"
)
# python3.13 や perl5.38 のようにバージョンが付いた名前も同じインタプリタ。
# 名前が違うだけで検査を素通りしないよう、末尾の版数を落として突き合わせる
INTERPRETER_VERSION_SUFFIX_RE = re.compile(r"[0-9]+(?:[._][0-9]+)*$")
# 渡されたコードの中で外部コマンドを起動する構成要素。
# 識別子は語の区切りで照合する (部分一致にすると "filesystem" が "system" に
# 当たって無害なコードまで拒否してしまう)
INTERPRETER_EXEC_IDENTIFIERS = (
    "popen",
    "spawn",
    "spawnSync",
    "subprocess",
    "child_process",
    "shell_exec",
    "passthru",
    "proc_open",
    "open3",
    "qx",
    "do shell script",
    "do script",
)
# 識別子として書かれていなくても外部コマンドの起動になる記法。
# バックティックや %x{} が意味を持つのは一部の言語だけなので、言語ごとに持つ
# (Python のコードに含まれるバックティックまで拒否すると、文書の生成すら止まる)
INTERPRETER_EXEC_LITERALS = {
    "perl": ("`",),
    "ruby": ("`", "%x"),
    "php": ("`",),
}
# 語の並びでは表せない外部起動の書き方。casefold 済みのコードへ当てる。
# exec / spawn は接尾辞の組み合わせが多いため、族としてまとめて見る
INTERPRETER_EXEC_PATTERNS = (
    r"(?<![a-z0-9_])exec[lv][pe]*(?![a-z0-9_])",
    r"(?<![a-z0-9_])spawn[lv][pe]*(?![a-z0-9_])",
    r"(?<![a-z0-9_])posix_spawnp?(?![a-z0-9_])",
    # os.system / os.exec* のようにモジュール名を伴う形。
    # platform.system() のような無害な同名 API と区別するため、
    # 素の `system` は言語ごとの一覧 (INTERPRETER_LANGUAGE_IDENTIFIERS) で見る
    r"(?<![a-z0-9_])os\.(?:system|popen|exec|spawn)",
)
# 素の識別子で外部コマンドを起動する言語。
# 語の前にモジュール名が付かない書き方が正式な言語だけを対象にする
INTERPRETER_LANGUAGE_IDENTIFIERS = {
    "perl": ("system", "exec"),
    "ruby": ("system", "exec"),
    "php": ("system", "exec"),
    "awk": ("system",),
    "gawk": ("system",),
}
# awk はパイプで外部コマンドを起動する。`||` や区切り文字としての `|` と
# 区別するため、コマンド文字列か getline が続く場合だけ対象にする
AWK_EXEC_PATTERNS = (
    r"(?<!\|)\|(?!\|)\s*&?\s*getline",
    r"(?:print|printf)[^;}\n]*(?<!\|)\|(?!\|)",
)
INTERPRETER_LANGUAGE_PATTERNS = {
    "awk": AWK_EXEC_PATTERNS,
    "gawk": AWK_EXEC_PATTERNS,
}
# 実行対象を実行時に組み立てる構成要素。
# これがあると識別子の照合をすり抜けられるため、解析不能として拒否する
INTERPRETER_OBFUSCATION_IDENTIFIERS = (
    "__import__",
    "importlib",
    "getattr",
    "eval",
    "compile",
    "globals",
    "builtins",
    "require",
    "Function",
    "constructor",
)
INTERPRETER_OBFUSCATION_REASON = (
    "実行対象を実行時に組み立てるコードは、静的に検査できないため"
    "許可していません。"
)
INTERPRETER_EXEC_REASON = (
    "インタプリタへ直接渡したコードから外部コマンドを起動する操作は"
    "許可していません (コードの内容を静的に検査できないため)。"
)
INTERPRETER_CODE_CONFIRM_REASON = (
    "インタプリタへ直接渡したコードはシェルとして解析できないため、"
    "内容を確認してから実行してください。"
)
# bypassPermissions では確認ダイアログが出ないため、確認理由はそのまま拒否になる。
# ただしインタプリタへ渡したコードだけは例外にする。
# 既知の認証情報パス、外部プロセスの起動、難読化はモードによらず deny 済み。
# ここを拒否にすると、bypassPermissions では一切のスクリプト処理ができなくなる
BYPASS_ALLOWED_CONFIRMATIONS = {INTERPRETER_CODE_CONFIRM_REASON}

# npm の値を取るグローバルオプション。
# `npm --prefix . exec -c '<コマンド>'` のように、サブコマンドの前に置ける
NPM_VALUE_OPTIONS = {
    "--prefix",
    "-C",
    "--workspace",
    "-w",
    "--registry",
    "--userconfig",
    "--globalconfig",
    "--cache",
    "--package",
    "-p",
    "--loglevel",
    "--tag",
    "--omit",
    "--include",
    "--node-options",
    "--color",
    "--depth",
    "--userAgent",
    "--script-shell",
    "--shell",
}
# 値を取らない npm / npx のオプション。
# これと NPM_VALUE_OPTIONS のどちらにも無いオプションは、値を取るかどうかを
# 決められないため、子 argv の境界を確定できたとき以外は解析不能として閉じる
NPM_BOOLEAN_OPTIONS = {
    "-y",
    "--yes",
    "--no",
    "--no-install",
    "--install",
    "-g",
    "--global",
    "--silent",
    "--quiet",
    "--prefer-online",
    "--prefer-offline",
    "--offline",
    "--ignore-existing",
    "--shell-auto-fallback",
    "--workspaces",
    "--no-workspaces",
    "--include-workspace-root",
    "--if-present",
    "--foreground-scripts",
    "--ignore-scripts",
    "--dry-run",
    "--json",
    "--long",
    "--parseable",
    "--version",
    "-v",
    "--help",
    "-h",
    "--verbose",
    "--usage",
}
# npm の真偽オプションは `--no-` を付けて打ち消せる。
# 個別に並べても追いつかないため、接頭辞でも判定する
NPM_BOOLEAN_OPTION_PREFIXES = ("--no-",)
# 受け取った文字列を shell として実行するラッパー。
# サンドボックスや、ここまでの検査を丸ごと迂回できるため、中身を解析し直す。
# {コマンド: (実行を意味するサブコマンド語, コマンド文字列を取るオプション)}
# サブコマンド語は「位置引数として解析した結果」ではなく「その語が現れるか」で
# 見る。npm は未知のオプションが値を取るかどうかを静的に決められないため
# (`npm --color always exec -c ...`)、位置での解析は当てにならない
SHELL_STRING_WRAPPERS = {
    "npx": (frozenset(), {"-c", "--call"}),
    # `npm x` は `npm exec` の別名
    "npm": (frozenset({"exec", "x"}), {"-c", "--call"}),
    "pnpm": (frozenset(), {"-c"}),
    "script": (frozenset(), {"-c", "--command"}),
    "flock": (frozenset(), {"-c"}),
}
# 位置引数をそのまま子プロセスとして起こすパッケージランナー。
# {コマンド: 実行を意味するサブコマンド語 (空なら位置引数がそのまま子コマンド)}
PACKAGE_RUNNER_SUBCOMMANDS = {
    "npm": frozenset({"exec", "x"}),
    "pnpm": frozenset({"exec", "dlx"}),
    "npx": frozenset(),
}
# npm_config_call はそのままコマンド文字列の指定になる。
NPM_EXEC_ENV_NAMES = {"npm_config_call", "npm_config_script_shell"}
NPM_CONFIG_ENV_REASON = (
    "npm に実行コマンドや shell を指定する環境変数は許可していません。"
)
SHELL_STARTUP_ENV_VARS = {"BASH_ENV", "ENV", "ZDOTDIR"}
SHELL_OPTION_ENV_VARS = {"SHELLOPTS"}
TRACKED_SHELL_OPTIONS = {"allexport", "keyword", "xtrace"}

# 起動元から継承される値はコマンド文字列に現れない。任意コマンドの起動や
# 暗黙の引数追加に使える名前だけを、値そのものではなく空・非空へ畳んで追跡する。
INHERITED_EXEC_ENV_NAMES = (
    GIT_EXEC_ENV_VARS
    | GH_EXEC_ENV_VARS
    | TERRAFORM_EXEC_ENV_VARS
    | AWS_PAGER_ENV_VARS
    | AWS_HELP_PAGER_ENV_VARS
    | DOCKER_EXEC_ENV_VARS
    | DOCKER_CREDENTIAL_ENV_VARS
    | DOCKER_SSH_ENV_VARS
    | SHELL_STARTUP_ENV_VARS
    | SHELL_OPTION_ENV_VARS
)
INHERITED_EXEC_ENV_PREFIXES = GIT_EXEC_ENV_PREFIXES + TERRAFORM_EXEC_ENV_PREFIXES
INHERITED_NONEMPTY_MARKER = "__inherited_nonempty_environment_value__"
# `--` の後ろを、そのまま別プロセスの argv として起こすラッパー
ARGV_WRAPPER_SUBCOMMANDS = {"mise": {"exec", "x"}}
# `script <出力ファイル> <コマンド...>` (macOS 形式) の値を取るオプション
SCRIPT_VALUE_OPTIONS = {"-F", "-t"}
# 文字列を shell へ渡す git のサブコマンド
GIT_SHELL_STRING_SUBCOMMANDS = (("submodule", "foreach"),)
# 引数に <revision>:<path> の object name を取り、内容を出力しうる操作。
GIT_REVISION_PATH_SUBCOMMANDS = {
    "archive",
    "cat-file",
    "diff",
    "difftool",
    "grep",
    "log",
    "show",
}
GIT_FILE_INPUT_OPTIONS = {"--file", "--template", "--pathspec-from-file"}
TERRAFORM_FILE_INPUT_OPTIONS = {
    "-backend-config",
    "-chdir",
    "-from-module",
    "-plugin-dir",
    "-state",
    "-var-file",
    "--terragrunt-config",
    "--terragrunt-working-dir",
    "--working-dir",
}

# エディタ・sqlite3 から shell へ抜ける指定。
# どちらも「検査を通らない子プロセス」を作る口になる
VIM_COMMANDS = {"vim", "nvim", "vi", "view", "ex", "vimdiff", "nview"}
VIM_COMMAND_OPTIONS = {"-c", "--cmd"}
VIM_SHELL_ESCAPE_RE = re.compile(
    # 行頭・`|`・`:` の直後の `!` は、Ex コマンドとしての shell 実行
    r"(?:^|\||:)\s*(?:sil(?:ent)?!?\s+)?!"
    r"|(?<![A-Za-z0-9_])(?:system|systemlist|term_start|job_start)\s*\("
    r"|(?:^|\||:)\s*ter(?:m|minal)?(?![A-Za-z0-9_])",
    re.IGNORECASE,
)
SQLITE_COMMANDS = {"sqlite3", "sqlite"}
SQLITE_COMMAND_OPTIONS = {"-cmd"}
SQLITE_SHELL_ESCAPE_RE = re.compile(
    r"^\s*\.(?:shell|system|excel|www|load)(?![A-Za-z0-9_])",
    re.IGNORECASE | re.MULTILINE,
)
SQLITE_PIPE_OUTPUT_RE = re.compile(
    r"^\s*\.(?:once|output|import)(?![A-Za-z0-9_])[^\n]*\|",
    re.IGNORECASE | re.MULTILINE,
)

PUNCTUATION = ";&|()<>\n"
LITERAL_PUNCTUATION_ENCODE = {
    character: chr(0xE100 + index) for index, character in enumerate(PUNCTUATION)
}
LITERAL_PUNCTUATION_DECODE = {
    ord(encoded): character for character, encoded in LITERAL_PUNCTUATION_ENCODE.items()
}
QUOTED_WORD_MARKER = chr(0xE200)
LITERAL_PUNCTUATION_DECODE[ord(QUOTED_WORD_MARKER)] = None
CONTROL_OPERATORS = {
    ";",
    ";;",
    ";&",
    ";;&",
    "&",
    "&&",
    "|",
    "|&",
    "||",
    "\n",
    "(",
    ")",
}
PIPE_OPERATORS = {"|", "|&"}
SHELL_COMMANDS = {"bash", "dash", "ksh", "sh", "zsh"}
SHELL_FD0_PATHS = {"/dev/fd/0", "/dev/stdin", "/proc/self/fd/0"}
SHELL_STDIN_PATHS = {"-"} | SHELL_FD0_PATHS
REDIRECTIONS = {
    "<",
    ">",
    "<<",
    ">>",
    "<<<",
    "<>",
    "<&",
    ">&",
    ">|",
    "&>",
    "&>>",
}
# 被演算子がファイルパスになるリダイレクト (ヒアドキュメントと FD 複製を除く)
FILE_REDIRECTIONS = {"<", ">", ">>", "<>", ">|", "&>", "&>>"}
PUNCTUATION_OPERATORS = tuple(
    sorted(
        CONTROL_OPERATORS | REDIRECTIONS | {"((", "))", "()"},
        key=len,
        reverse=True,
    )
)
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]*\])?\+?=.*$", re.S)
ARRAY_ASSIGNMENT_RE = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]*\])?\+?=$", re.S
)
XARGS_REPLACEMENT_MARKER = "__xargs_replacement__"
UNQUOTED_EXPANSION_MARKER = "__unquoted_expansion__"
QUOTED_EXPANSION_MARKER = "__quoted_expansion__"
# 機密とみなす変数の展開に付ける印。展開マーカーの直後へ足すため、
# 「動的な語かどうか」を見る既存の判定 (部分一致) はそのまま働く
SENSITIVE_PARAMETER_SUFFIX = "__sensitive_parameter__"
CREDENTIAL_PATH_PARAMETER_SUFFIX = "__credential_path_parameter__"
# `${var@P}` は値をプロンプトとして再評価する。値の中の `$(...)` がそこで
# 実行されるため、静的には中身が分からない
PROMPT_EXPANSION_MARKER = "__prompt_expansion__"
PROMPT_EXPANSION_RE = re.compile(r"^[!#]?[A-Za-z_@*][A-Za-z0-9_]*(?:\[[^]]*\])?@P$")
DYNAMIC_COMMAND_MARKERS = {
    "__arithmetic_expansion__",
    "__command_substitution__",
    "__process_substitution__",
    UNQUOTED_EXPANSION_MARKER,
    QUOTED_EXPANSION_MARKER,
    XARGS_REPLACEMENT_MARKER,
}
NESTED_COMMAND_MARKER_RE = re.compile(
    r"__(?:command|process)_substitution__(\d+)__"
)
ARITHMETIC_EXPRESSION_MARKER_RE = re.compile(
    r"__arithmetic_expansion__([0-9a-f]*)__"
)
ARITHMETIC_COMMAND_MARKER_RE = re.compile(r"__arithmetic_command__([0-9a-f]*)__")
PARAMETER_ASSIGNMENT_MARKER_RE = re.compile(
    r"__parameter_assignment__([0-9a-f]*)__"
)
NON_STDIN_FD_PATH_RE = re.compile(r"^/(?:dev/fd|proc/self/fd)/[1-9][0-9]*$")
# 算術式の中の代入 (`i = 0`、`i += 1` など)。`==` とは区別する
ARITHMETIC_ASSIGNMENT_RE = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:[+\-*/%&|^]|<<|>>)?=(?!=)(.*)$", re.S
)
ARITHMETIC_MUTATION_NAME_RE = re.compile(
    r"^\s*(?:\+\+|--)?([A-Za-z_][A-Za-z0-9_]*)\s*"
    r"(?:(?:[+\-*/%&|^]|<<|>>)?=(?!=)|\+\+|--)",
    re.S,
)
# 引用なしヒアドキュメント本文の中のパラメータ展開
HEREDOC_PARAMETER_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
ARITHMETIC_UNKNOWN_CONFIRM_REASON = (
    "算術式が未知の変数に依存しています。bash は変数の値を式として再評価するため、"
    "内容を確認してから実行してください。"
)
ASSIGNMENT_PARTS_RE = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*)(?:\[([^]]*)\])?(\+?)=(.*)$", re.S
)


# ============================================================================
# 字句・構文解析
# ============================================================================

class ArithmeticUnknownValueError(Exception):
    """算術式が未知の変数に依存し、値を確かめられないことを表す。

    bash は算術評価で変数の値を式として再評価するため、値が分からないと
    コマンド起動を含まないと言い切れない。ただしシェルの呼び出しは 1 回ごとに
    独立しており、同じコマンド内で代入された値は追跡できている。
    そこで「未知」は解析不能 (fail closed) ではなく確認へ回す。
    """


class ShellScanError(Exception):
    pass


def add_reason(reasons, reason):
    if reason not in reasons:
        reasons.append(reason)


def command_basename(word):
    return os.path.basename(word.rstrip("/")) if "/" in word else word


def positional_argument_indexes(arguments, value_options):
    """オプションとその値を除いた位置引数の index を順に返す。

    `value_options` に含まれるオプションは次の語を値として消費する。
    `--opt=value` 形式や `--` 以降の扱いも考慮する。
    """
    indexes = []
    skip_next = False
    end_of_options = False
    for index, argument in enumerate(arguments):
        if end_of_options:
            indexes.append(index)
            continue
        if skip_next:
            skip_next = False
            continue
        if argument == "--":
            end_of_options = True
            continue
        if argument.startswith("-") and argument != "-":
            option = argument.split("=", 1)[0]
            if "=" not in argument and option in value_options:
                skip_next = True
            continue
        indexes.append(index)
    return indexes


def docker_short_option_cluster(argument, value_options, boolean_flags):
    """pflag の短縮 flag cluster を (末尾の値付き option, 連結値) に分ける。

    pflag は最後以外を boolean shorthand として扱うため、`-itvPATH` は
    `-i -t -v PATH`、`-DHsocket` は `-D -H socket` と同じ意味になる。
    値付き option が無い boolean cluster は空の option を返し、未知の文字を
    含む cluster は None を返す。
    """
    if (
        not argument.startswith("-")
        or argument.startswith("--")
        or argument == "-"
    ):
        return None
    short_value_flags = {
        option[1:]: option
        for option in value_options
        if option.startswith("-") and not option.startswith("--") and len(option) == 2
    }
    cluster = argument[1:]
    for position, flag in enumerate(cluster):
        if flag in boolean_flags:
            continue
        option = short_value_flags.get(flag)
        if option is None:
            return None
        joined = cluster[position + 1 :]
        if joined.startswith("="):
            joined = joined[1:]
        return option, joined if joined else None
    return "", None


def docker_short_option_occurrences(arguments, value_options, boolean_flags):
    """短縮 cluster 内の値付き option と値・元 argv index を返す。"""
    occurrences = []
    for index, argument in enumerate(arguments):
        parsed = docker_short_option_cluster(
            argument, value_options, boolean_flags
        )
        if parsed is None:
            continue
        option, joined = parsed
        if not option:
            continue
        indexes = {index}
        if joined is not None:
            value = joined
        elif index + 1 < len(arguments):
            value = arguments[index + 1]
            indexes.add(index + 1)
        else:
            continue
        occurrences.append((option, value, indexes))
    return occurrences


def docker_build_argument_indexes(arguments):
    """Docker build の短縮 flag cluster を解釈して位置引数を返す。"""
    value_options = DOCKER_VALUE_OPTIONS | DOCKER_BUILD_VALUE_OPTIONS
    indexes = []
    skip_next = False
    end_of_options = False
    for index, argument in enumerate(arguments):
        if end_of_options:
            indexes.append(index)
            continue
        if skip_next:
            skip_next = False
            continue
        if argument == "--":
            end_of_options = True
            continue
        if argument.startswith("--"):
            option = argument.split("=", 1)[0]
            if "=" not in argument and option in value_options:
                skip_next = True
            continue
        if argument.startswith("-") and argument != "-":
            parsed = docker_short_option_cluster(
                argument,
                value_options,
                DOCKER_BUILD_SHORT_BOOLEAN_FLAGS,
            )
            if parsed is not None:
                option, joined = parsed
                if option and joined is None:
                    skip_next = True
            continue
        indexes.append(index)
    return indexes


def docker_build_subcommand_words(arguments):
    return [arguments[index] for index in docker_build_argument_indexes(arguments)]


def subcommand_words(arguments, value_options):
    """オプションとその値を除いた位置引数 (サブコマンド語) を順に返す。"""
    return [
        arguments[index]
        for index in positional_argument_indexes(arguments, value_options)
    ]


def subcommand_word_candidates(
    arguments, value_options, word_limit=SUBCOMMAND_WORD_LIMIT, boolean_options=()
):
    """未知のオプションが値を取る場合も含めた、位置引数の並びの候補を返す。

    `value_options` は手で列挙するため必ず漏れが出る。漏れたオプションの値は
    位置引数として数えられ、サブコマンドの位置をずらして検査をすり抜ける
    (`aws --cli-binary-format raw-in-base64-out secretsmanager get-secret-value` など)。
    そこで未知のオプションは「値を取る」「取らない」の両方へ分岐させ、
    どれか 1 つでも拒否対象に一致すれば拒否する。

    判定に必要なのは先頭数語だけなので、語数を打ち切って候補を併合する。
    それでも候補が増えすぎる場合は、静的に判断できないものとして例外にする。
    """
    states = {((), False, False)}
    for argument in arguments:
        next_states = set()
        for words, skip_next, end_of_options in states:
            if end_of_options:
                next_states.add(
                    (append_subcommand_word(words, argument, word_limit), False, True)
                )
                continue
            if skip_next:
                next_states.add((words, False, False))
                continue
            if argument == "--":
                next_states.add((words, False, True))
                continue
            if argument.startswith("-") and argument != "-":
                option = argument.split("=", 1)[0]
                if "=" in argument:
                    next_states.add((words, False, False))
                elif option in value_options:
                    next_states.add((words, True, False))
                elif option in boolean_options:
                    next_states.add((words, False, False))
                elif len(words) >= word_limit:
                    # 判定に使う語が揃った後は、値を取るかどうかで結果が変わらない
                    next_states.add((words, False, False))
                else:
                    next_states.add((words, False, False))
                    next_states.add((words, True, False))
                continue
            next_states.add(
                (append_subcommand_word(words, argument, word_limit), False, False)
            )
        if len(next_states) > SUBCOMMAND_CANDIDATE_LIMIT:
            raise ShellScanError("too many subcommand parses to check")
        states = next_states
    return {words for words, _, _ in states}


def append_subcommand_word(words, argument, word_limit):
    """判定に必要な語数までに切り詰めて位置引数を足す。"""
    if len(words) >= word_limit:
        return words
    return words + (argument,)


def subcommand_candidates_match(candidates, expected):
    """候補のどれかが、先頭からの語の並び `expected` に一致するかを返す。"""
    return any(words[: len(expected)] == expected for words in candidates)


def aws_configure_setting_is_secret(setting):
    """profile 接頭辞を除いた AWS 設定名が credential を指すかを返す。"""
    return setting.strip().casefold().rsplit(".", 1)[-1] in AWS_CONFIGURE_SECRET_MARKERS


def aws_option_enabled(arguments, names):
    """`--` より前にある AWS の真偽オプションが有効かを返す。"""
    for argument in arguments:
        if argument == "--":
            break
        name, separator, value = argument.partition("=")
        if name not in names:
            continue
        if not separator or value.strip().casefold() in BOOLEAN_TRUE_VALUES:
            return True
    return False


def aws_last_option_value(arguments, names):
    """`--` より前にある最後の AWS option 値を返す。"""
    value = None
    pending = False
    for argument in arguments:
        if argument == "--":
            break
        if pending:
            value = argument
            pending = False
            continue
        name, separator, joined_value = argument.partition("=")
        if name not in names:
            continue
        if separator:
            value = joined_value
        else:
            value = None
            pending = True
    return value


def aws_last_boolean_option_enabled(arguments, positive_names, negative_names):
    """AWS の正負 flag を順に走査し、最後に指定された状態を返す。"""
    enabled = False
    for argument in arguments:
        if argument == "--":
            break
        name, separator, value = argument.partition("=")
        if name in positive_names:
            enabled = not separator or value.strip().casefold() in BOOLEAN_TRUE_VALUES
        elif name in negative_names:
            enabled = False
    return enabled


def aws_global_version_requested(arguments):
    """dispatch 前に終了する完全形の global --version を検出する。"""
    for argument in arguments:
        if argument == "--":
            return False
        if argument == "--version":
            return True
    return False


def environment_value_state(name, values, tainted_names):
    """環境変数の実効状態を absent / empty / nonempty / unknown で返す。"""
    if name in values:
        return "nonempty" if values[name] else "empty"
    if name in tainted_names:
        return "unknown"
    return "absent"


def environment_override_is_nonempty(names, values, tainted_names, prefixes=()):
    """対象環境変数が空でない値へ差し替えられたかを判定する。"""
    for name in set(values) | set(tainted_names):
        if name not in names and not name.startswith(prefixes):
            continue
        if environment_value_state(name, values, tainted_names) in {
            "nonempty",
            "unknown",
        }:
            return True
    return False


def aws_external_pager_is_nonempty(arguments, candidates, values, tainted_names):
    """AWS CLI が実際に選ぶ外部 pager が差し替えられているかを返す。"""
    help_requested = any(words and words[-1] == "help" for words in candidates)
    if help_requested:
        # terminal help は通常出力とは別実装で、MANPAGER、PAGER の順に使う。
        for name in ("MANPAGER", "PAGER"):
            state = environment_value_state(name, values, tainted_names)
            if state != "absent":
                return state in {"nonempty", "unknown"}
        return False

    if boolean_option_enabled(arguments, {"--no-cli-pager"}):
        return False
    aws_pager_state = environment_value_state(
        "AWS_PAGER", values, tainted_names
    )
    if aws_pager_state != "absent":
        return aws_pager_state in {"nonempty", "unknown"}
    return environment_value_state("PAGER", values, tainted_names) in {
        "nonempty",
        "unknown",
    }


def aws_help_invocation(arguments, expected):
    """既知の global option 以外が `<service> <operation> help` かを返す。

    未知 option を推測して除くと、その値が `help` の場合をローカル help と
    誤認しうる。ここでは完全に把握している global option だけを除去する。
    """
    words = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return False
        name, separator, _ = argument.partition("=")
        if name in AWS_GLOBAL_VALUE_OPTIONS:
            if separator:
                index += 1
                continue
            if index + 1 >= len(arguments):
                return False
            index += 2
            continue
        if argument in AWS_GLOBAL_BOOLEAN_OPTIONS:
            index += 1
            continue
        if argument.startswith("-") and argument != "-":
            return False
        words.append(argument)
        index += 1
    return tuple(words) == expected + ("help",)


def aws_cli_skeleton_requested(arguments):
    """標準 API を実行しない正式形の --generate-cli-skeleton を検出する。"""
    found = False
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return False
        if argument.startswith("--generate-cli-skeleton="):
            if argument.split("=", 1)[1] not in AWS_CLI_SKELETON_VALUES:
                return False
            found = True
        elif argument == "--generate-cli-skeleton":
            found = True
            if (
                index + 1 < len(arguments)
                and arguments[index + 1] in AWS_CLI_SKELETON_VALUES
            ):
                index += 1
            elif (
                index + 1 < len(arguments)
                and not arguments[index + 1].startswith("-")
            ):
                return False
        index += 1
    return found


def aws_dry_run_enabled(arguments):
    """省略形を含む --dry-run / --no-dry-run の最後の指定を返す。"""
    return aws_last_boolean_option_enabled(
        arguments, AWS_DRY_RUN_OPTIONS, AWS_NO_DRY_RUN_OPTIONS
    )


def pip_invocation_arguments(command, arguments):
    """pip / versioned pip / `python -m pip` の pip argv を返す。"""
    if PIP_EXECUTABLE_RE.fullmatch(command):
        return arguments
    if interpreter_name(command) not in {"python", "python3"}:
        return None

    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "-m":
            if index + 1 >= len(arguments):
                return None
            return (
                arguments[index + 2 :]
                if arguments[index + 1].casefold() == "pip"
                else None
            )
        if argument.startswith("-m") and not argument.startswith("--"):
            return arguments[index + 1 :] if argument[2:].casefold() == "pip" else None
        if argument in {"-W", "-X", "--check-hash-based-pycs"}:
            index += 2
            continue
        if argument.startswith(("-W", "-X")) and len(argument) > 2:
            index += 1
            continue
        if argument.startswith("--check-hash-based-pycs="):
            index += 1
            continue
        if argument.startswith("-") and argument != "-":
            index += 1
            continue
        return None
    return None


def normalized_pip_config_leaf(setting):
    """pip の config key を比較用の option 名へ正規化する。"""
    return setting.casefold().replace("_", "-").rsplit(".", 1)[-1]


def pip_config_reveals_credentials(arguments):
    """pip config が credential を含みうる保存値を出力するかを返す。"""
    if arguments and arguments[-1] in {"--help", "-h"}:
        help_candidates = subcommand_word_candidates(
            arguments[:-1],
            PIP_VALUE_OPTIONS,
            4,
            boolean_options=PIP_BOOLEAN_OPTIONS,
        )
        if any(
            words[:2] in {("config", "list"), ("config", "debug")}
            and len(words) == 2
            or words[:2] == ("config", "get")
            and len(words) == 3
            and normalized_pip_config_leaf(words[2]) in PIP_SECRET_CONFIG_NAMES
            for words in help_candidates
        ):
            return False
    candidates = subcommand_word_candidates(
        arguments,
        PIP_VALUE_OPTIONS,
        4,
        boolean_options=PIP_BOOLEAN_OPTIONS,
    )
    for words in candidates:
        if len(words) < 2 or words[0].casefold() != "config":
            continue
        action = words[1].casefold()
        if action in {"list", "debug"}:
            return True
        if (
            action == "get"
            and len(words) > 2
            and normalized_pip_config_leaf(words[2]) in PIP_SECRET_CONFIG_NAMES
        ):
            return True
    return False


def pnpm_config_reveals_credentials(arguments):
    """pnpm config get が .npmrc の認証値を平文で返す形かを判定する。"""
    if (
        len(arguments) == 4
        and arguments[:2] == ["config", "get"]
        and arguments[-1] in {"--help", "-h"}
    ):
        return False
    candidates = subcommand_word_candidates(arguments, set(), 3)
    for words in candidates:
        if len(words) < 3 or words[:2] != ("config", "get"):
            continue
        leaf = words[2].casefold().rsplit(":", 1)[-1].lstrip("_")
        leaf = leaf.replace("-", "").replace("_", "")
        if leaf in PNPM_SECRET_CONFIG_NAMES:
            return True
    return False


def npm_config_reveals_proxy_credentials(arguments):
    """npm config の一括表示が proxy 環境変数を平文で返す形かを判定する。"""
    if arguments and arguments[-1] in {"--help", "-h"}:
        help_words = arguments[:-1]
        if (
            help_words in (["g"], ["ge"], ["get"])
            or len(help_words) == 2
            and help_words[0] in {"g", "ge", "get"}
            and normalized_pip_config_leaf(help_words[1])
            in {"proxy", "https-proxy"}
            or len(help_words) == 2
            and help_words[0] in {"c", "con", "conf", "confi", "config"}
            and help_words[1] in {"get", "list", "ls"}
            or len(help_words) == 3
            and help_words[0] in {"c", "con", "conf", "confi", "config"}
            and help_words[1] == "get"
            and normalized_pip_config_leaf(help_words[2])
            in {"proxy", "https-proxy"}
        ):
            return False
    candidates = subcommand_word_candidates(arguments, set(), 3)
    safe_json = boolean_option_enabled(arguments, {"--json"}) and not any(
        argument == "--no-json"
        or (
            argument.startswith("--json=")
            and argument.split("=", 1)[1].casefold() not in BOOLEAN_TRUE_VALUES
        )
        for argument in arguments
    )
    safe_long = boolean_option_enabled(
        arguments, {"--long"}, short_flags={"l"}
    ) and not any(
        argument == "--no-long"
        or (
            argument.startswith(("--long=", "-l="))
            and argument.split("=", 1)[1].casefold() not in BOOLEAN_TRUE_VALUES
        )
        for argument in arguments
    )
    for words in candidates:
        if not words:
            continue
        command = words[0]
        if command in {"g", "ge", "get"} and len(words) >= 2:
            if normalized_pip_config_leaf(words[1]) in {"proxy", "https-proxy"}:
                return True
        if command in {"g", "ge", "get"} and len(words) == 1:
            return not safe_long
        if command not in {"c", "con", "conf", "confi", "config"} or len(
            words
        ) < 2:
            continue
        action = words[1]
        if action in {"list", "ls"}:
            return not (safe_json or safe_long)
        if action == "get" and len(words) == 2:
            return not safe_long
        if action == "get" and len(words) >= 3:
            if normalized_pip_config_leaf(words[2]) in {"proxy", "https-proxy"}:
                return True
    return False


def mount_sources(arguments):
    """docker run / create のボリューム指定から、ホスト側のパスを取り出す。

    -v /host:/container、--volume=/host:/container、
    --mount type=bind,source=/host,target=/c の 3 形式に対応する。
    """
    sources = []
    pending = None
    for argument in arguments:
        if pending is not None:
            value = argument
            option = pending
            pending = None
        elif argument in DOCKER_MOUNT_OPTIONS:
            pending = argument
            continue
        elif "=" in argument and argument.split("=", 1)[0] in DOCKER_MOUNT_OPTIONS:
            option, _, value = argument.partition("=")
        elif argument.startswith("-v") and len(argument) > 2:
            # -v/host:/container のように値を連結した形式
            option, value = "-v", argument[2:]
        else:
            continue

        # --mount はフィールド形式、-v は `:` 区切り。
        # docker はフィールド名の大文字小文字を区別しない
        if option in {"--mount", "--tmpfs"} or value.casefold().startswith("type="):
            for field in value.split(","):
                key, _, field_value = field.partition("=")
                if key.strip().casefold() in {"source", "src"} and field_value:
                    sources.append(field_value)
        else:
            # -v 形式: ホスト側は最初の : より前 (Windows ドライブ表記は扱わない)
            host = value.split(":", 1)[0]
            if host:
                sources.append(host)
    for option, value, _indexes in docker_short_option_occurrences(
        arguments,
        DOCKER_EXEC_CHILD_VALUE_OPTIONS,
        DOCKER_EXEC_CHILD_SHORT_BOOLEAN_FLAGS,
    ):
        if option != "-v":
            continue
        host = value.split(":", 1)[0]
        if host:
            sources.append(host)
    return sources


def bind_mount_sources(arguments):
    """ホストディレクトリを読む bind mount の source だけを返す。"""
    sources = []
    pending = None
    for argument in arguments:
        if pending is not None:
            value = argument
            option = pending
            pending = None
        elif argument in DOCKER_MOUNT_OPTIONS:
            pending = argument
            continue
        elif "=" in argument and argument.split("=", 1)[0] in DOCKER_MOUNT_OPTIONS:
            option, _, value = argument.partition("=")
        elif argument.startswith("-v") and len(argument) > 2:
            option, value = "-v", argument[2:]
        else:
            continue

        if option == "--mount" or value.casefold().startswith("type="):
            fields = {}
            for field in value.split(","):
                key, separator, field_value = field.partition("=")
                if separator:
                    fields[key.strip().casefold()] = field_value
            if fields.get("type", "").casefold() != "bind":
                continue
            source = fields.get("source") or fields.get("src")
            if source:
                sources.append(source)
            continue

        # -v / --volume の bare name は named volume。明示的なパスだけを bind とみなす。
        source = value.split(":", 1)[0]
        expanded = expand_home(source)
        if (
            source in {".", ".."}
            or path_contains_expansion(source)
            or os.path.isabs(expanded)
            or source.startswith(("./", "../", "~"))
            or "/" in source
        ):
            sources.append(source)
    for option, value, _indexes in docker_short_option_occurrences(
        arguments,
        DOCKER_EXEC_CHILD_VALUE_OPTIONS,
        DOCKER_EXEC_CHILD_SHORT_BOOLEAN_FLAGS,
    ):
        if option != "-v":
            continue
        source = value.split(":", 1)[0]
        expanded = expand_home(source)
        if (
            source in {".", ".."}
            or path_contains_expansion(source)
            or os.path.isabs(expanded)
            or source.startswith(("./", "../", "~"))
            or "/" in source
        ):
            sources.append(source)
    return sources


def container_mount_argument_indexes(arguments):
    """Docker mount 指定の option と値がある引数位置を返す。"""
    indexes = set()
    options = DOCKER_MOUNT_OPTIONS | {"--tmpfs"}
    skip_next = False
    for index, argument in enumerate(arguments):
        if skip_next:
            indexes.add(index)
            skip_next = False
            continue
        if argument in options:
            indexes.add(index)
            skip_next = True
            continue
        if argument.startswith("-v") and argument != "-v":
            indexes.add(index)
            continue
        if any(argument.startswith(option + "=") for option in options):
            indexes.add(index)
    for option, _value, occurrence_indexes in docker_short_option_occurrences(
        arguments,
        DOCKER_EXEC_CHILD_VALUE_OPTIONS,
        DOCKER_EXEC_CHILD_SHORT_BOOLEAN_FLAGS,
    ):
        if option == "-v":
            indexes.update(occurrence_indexes)
    return indexes


def container_environment_argument_indexes(arguments):
    """Docker の -e / --env / --build-arg と値がある引数位置を返す。"""
    indexes = set()
    skip_next = False
    for index, argument in enumerate(arguments):
        if skip_next:
            indexes.add(index)
            skip_next = False
            continue
        if argument in DOCKER_ENV_OPTIONS:
            indexes.add(index)
            skip_next = True
            continue
        if argument.startswith("-e") and argument != "-e":
            indexes.add(index)
            continue
        if any(
            argument.startswith(option + "=")
            for option in {"--env", "--build-arg"}
        ):
            indexes.add(index)
    for option, _value, occurrence_indexes in docker_short_option_occurrences(
        arguments,
        DOCKER_EXEC_CHILD_VALUE_OPTIONS,
        DOCKER_EXEC_CHILD_SHORT_BOOLEAN_FLAGS,
    ):
        if option == "-e":
            indexes.update(occurrence_indexes)
    return indexes


def container_cp_destination_argument_indexes(arguments):
    """docker cp が内容を読み取らない destination の位置を返す。"""
    indexes = positional_argument_indexes(
        arguments, DOCKER_VALUE_OPTIONS | DOCKER_EXEC_CHILD_VALUE_OPTIONS
    )
    words = [arguments[index] for index in indexes]
    for expected in DOCKER_COPY_SUBCOMMANDS:
        if tuple(words[: len(expected)]) != expected:
            continue
        operand_indexes = indexes[len(expected) :]
        if len(operand_indexes) < 2:
            return set()
        source_index, destination_index = operand_indexes[-2:]
        source_is_container = docker_cp_operand_is_container_path(
            arguments[source_index]
        )
        destination_is_container = docker_cp_operand_is_container_path(
            arguments[destination_index]
        )
        if source_is_container != destination_is_container:
            return {destination_index}
        return set()
    return set()


def container_cp_container_source_paths(arguments):
    """container -> host の cp が読み出す container 内パスを返す。"""
    indexes = positional_argument_indexes(
        arguments, DOCKER_VALUE_OPTIONS | DOCKER_EXEC_CHILD_VALUE_OPTIONS
    )
    words = [arguments[index] for index in indexes]
    for expected in DOCKER_COPY_SUBCOMMANDS:
        if tuple(words[: len(expected)]) != expected:
            continue
        operands = words[len(expected) :]
        if len(operands) < 2:
            return []
        source, destination = operands[-2:]
        if docker_cp_operand_is_container_path(
            source
        ) and not docker_cp_operand_is_container_path(destination):
            return [source.split(":", 1)[1]]
        return []
    return []


def boolean_option_enabled(arguments, names, short_flags=frozenset()):
    """真偽オプションが有効になっているかを、表記のゆれを含めて判定する。

    `--flag`、`--flag=true`、`-t` のいずれでも有効とみなし、
    `--flag=false` のように明示的に無効化された指定は数えない。
    """
    for argument in arguments:
        name, separator, value = argument.partition("=")
        if name in names:
            if not separator or value.strip().casefold() in BOOLEAN_TRUE_VALUES:
                return True
            continue
        if (
            short_flags
            and name.startswith("-")
            and not name.startswith("--")
            and name != "-"
            and short_flags & set(name[1:])
        ):
            if not separator or value.strip().casefold() in BOOLEAN_TRUE_VALUES:
                return True
    return False


def expand_home(path):
    """`~`、`~user`、`$HOME` をホームのパスへ展開する (できない場合はそのまま)。

    bash は `~<ユーザー名>/` も同じホームへ展開するため、この表記も解決する。
    """
    for prefix in ("${HOME}", "$HOME"):
        if path == prefix:
            return HOME_PATH
        if path.startswith(prefix + "/"):
            return HOME_PATH + path[len(prefix) :]
    if path.startswith("~"):
        head = path.split("/", 1)[0]
        if not path_contains_expansion(head):
            expanded = os.path.expanduser(head)
            if expanded != head:
                return expanded + path[len(head) :]
    return path


def resolve_against_working_directory(path):
    """相対パスを cwd 基準で解決し、symlink と `..` を畳む。

    存在しないパスでも、辿れる範囲まで解決される。
    """
    if not os.path.isabs(path):
        path = os.path.join(WORKING_DIRECTORY, path)
    return os.path.realpath(path)


def resolved_parameter_value(name):
    """展開先が一意に決まるパラメータを、実際の値へ解決する。

    解決できない場合は None を返し、従来どおりマーカーへ置き換えさせる。
    """
    if name == "HOME" and HOME_IS_SUBSTITUTABLE:
        return HOME_PATH
    return None


def parameter_is_sensitive(name):
    """名前だけで機密とみなす環境変数かどうかを判定する。

    環境変数の慣習に合わせて、すべて大文字の名前だけを対象にする
    (`for key in ...` のような小文字の一時変数まで拾わないため)。
    照合は `_` で区切った語単位で行う。部分一致にすると KEYBOARD_LAYOUT や
    SECRETARY のような無関係な名前まで拾ってしまう。
    """
    if name in CREDENTIAL_PATH_PARAMETER_NAMES:
        return False
    if name in PROXY_PARAMETER_NAMES:
        return True
    if not name or name != name.upper():
        return False
    if name in SENSITIVE_PARAMETER_NAMES:
        return True
    return bool(set(name.split("_")) & CREDENTIAL_ENV_WORDS)


def prompt_expansion_marker(parameter):
    """`${var@P}` のときだけ、再評価を示すマーカーを返す。"""
    return (
        PROMPT_EXPANSION_MARKER
        if PROMPT_EXPANSION_RE.match(parameter.strip())
        else ""
    )


def expansion_marker(base, name):
    """パラメータ展開へ、秘密値または認証ファイルのパスという印を付ける。"""
    marker = base
    if parameter_is_sensitive(name):
        return marker + SENSITIVE_PARAMETER_SUFFIX
    if name in CREDENTIAL_PATH_PARAMETER_NAMES:
        return marker + CREDENTIAL_PATH_PARAMETER_SUFFIX
    return marker


def braced_expansion_marker(base, parameter, parameter_sanitized):
    """`${...}` の基底変数と operator operand の機密 taint を保持する。"""
    match = re.match(r"^!?([A-Za-z_][A-Za-z0-9_]*)", parameter)
    marker = base
    if match:
        name = match.group(1)
        operator = parameter[match.end() :]
        # `${name+word}` / `${name:+word}` は name の値自体を展開しない。
        if parameter.startswith("!") or not operator.startswith(("+", ":+")):
            marker = expansion_marker(base, name)
    if contains_sensitive_parameter(parameter_sanitized):
        marker += SENSITIVE_PARAMETER_SUFFIX
    if contains_credential_path_parameter(parameter_sanitized):
        marker += CREDENTIAL_PATH_PARAMETER_SUFFIX
    return marker


def contains_sensitive_parameter(value):
    """機密とみなす変数の展開を含むかどうかを判定する。"""
    return SENSITIVE_PARAMETER_SUFFIX in value


def contains_credential_path_parameter(value):
    """認証情報の保存先を指す変数の展開を含むかどうかを判定する。"""
    return CREDENTIAL_PATH_PARAMETER_SUFFIX in value


def sensitive_test_only_checks_presence(command, arguments):
    """test / [ / [[ が機密変数の空・非空だけを判定する形かを返す。"""
    operands = list(arguments)
    if command == "[" and operands[-1:] == ["]"]:
        operands.pop()
    elif command == "[[" and operands[-1:] == ["]]"]:
        operands.pop()
    elif command not in {"test", "[", "[["}:
        return False

    def safe_sensitive_operand(value):
        allowed_markers = {QUOTED_EXPANSION_MARKER}
        if command == "[[":
            # [[ ]] は word splitting / pathname expansion を行わない。
            allowed_markers.add(UNQUOTED_EXPANSION_MARKER)
        return contains_sensitive_parameter(value) and not any(
            marker in value
            for marker in DYNAMIC_COMMAND_MARKERS - allowed_markers
        )

    if len(operands) == 2 and operands[0] in {"-n", "-z"}:
        return safe_sensitive_operand(operands[1])
    if len(operands) == 3 and operands[1] in {"=", "==", "!="}:
        left, _operator, right = operands
        return (
            safe_sensitive_operand(left)
            and right == ""
            or left == ""
            and safe_sensitive_operand(right)
        )
    return False


def path_contains_expansion(path):
    """パスに解決できない展開 (変数・コマンド置換など) が残っているかを返す。

    呼び出し時点では $VAR や $(...) はマーカー文字列に置換されているため、
    生の `$` ではなくマーカーの有無で判定する。
    """
    if "$" in path or "`" in path:
        return True
    return any(marker in path for marker in DYNAMIC_COMMAND_MARKERS)


def mount_is_sensitive(source):
    """マウント元が認証情報を含むパスを指しているかを判定する。

    `~` と `$HOME` は展開先が一意なので解決してから判定する。それ以外の展開
    ($PWD など) は解決できないため、機密パスの構成要素を含む場合だけ拒否する
    (解決できない全てを拒否すると、正当なマウントまで妨げてしまう)。
    """
    home = HOME_PATH
    path = expand_home(source)

    # $SSH_AUTH_SOCK のように、名前だけで機密と分かる変数の展開
    if contains_sensitive_parameter(path) or contains_credential_path_parameter(path):
        return True

    # この時点で $VAR や $(...) はマーカーへ置換済みなので、`$` ではなく
    # マーカーの有無で「解決できない展開を含むか」を判定する
    if not path_contains_expansion(path):
        # cwd を基準に解決し、symlink と `..` を畳んでから突き合わせる。
        # macOS の既定ファイルシステムは大文字小文字を区別しないため casefold する
        resolved = resolve_against_working_directory(path).casefold()
        if resolved in {"/", "/users", "/home", os.path.realpath(home).casefold()}:
            return True
        for relative in SENSITIVE_MOUNT_PATHS:
            sensitive = os.path.realpath(os.path.join(home, relative)).casefold()
            # 機密パスそのもの・その配下に加えて、その「親」も拒否する。
            # 親をマウントすると、配下の機密パスがそのままコンテナから見える
            if (
                resolved == sensitive
                or resolved.startswith(sensitive + os.sep)
                or sensitive.startswith(resolved.rstrip(os.sep) + os.sep)
            ):
                return True
        for absolute in SENSITIVE_ABSOLUTE_MOUNT_PATHS:
            sensitive = os.path.realpath(absolute).casefold()
            if (
                resolved == sensitive
                or resolved.startswith(sensitive + os.sep)
                or sensitive.startswith(resolved.rstrip(os.sep) + os.sep)
            ):
                return True
        return False

    # 解決できない展開を含む場合は、機密パスの構成要素の有無で判定する
    folded = path.casefold()
    return any(relative.casefold() in folded for relative in SENSITIVE_MOUNT_PATHS)


def basename_is_dotenv(basename):
    """ファイル名が値を持つ環境変数ファイルかどうかを判定する。"""
    folded = basename.casefold()
    if folded == ".env":
        return True
    return folded.startswith(".env.") and folded not in {
        name.casefold() for name in DOTENV_TEMPLATE_NAMES
    }


def basename_is_credential(basename):
    """ファイル名だけで認証情報とみなすかを判定する (casefold 済みを受け取る)。"""
    if basename in {name.casefold() for name in CREDENTIAL_FILE_NAMES}:
        return True
    if basename_is_dotenv(basename):
        return True
    # 公開鍵 (.pub) は秘密ではないので、前方一致から外す
    if not basename.endswith(".pub") and basename.startswith(
        tuple(prefix.casefold() for prefix in CREDENTIAL_FILE_PREFIXES)
    ):
        return True
    if any(basename.endswith(suffix) for suffix in CREDENTIAL_FILE_SUFFIXES):
        return True
    stem, suffix = os.path.splitext(basename)
    if suffix in PRIVATE_KEY_CONTAINER_SUFFIXES and (
        stem in PRIVATE_KEY_STEM_NAMES
        or any(marker in stem for marker in PRIVATE_KEY_STEM_MARKERS)
        or stem.startswith(PRIVATE_KEY_STEM_PREFIXES)
        or stem.endswith(PRIVATE_KEY_STEM_SUFFIXES)
    ):
        return True
    if basename.endswith(".json") and any(
        marker in basename
        for marker in (
            "service-account",
            "service_account",
            "application_default_credentials",
        )
    ):
        return True
    return any(infix in basename for infix in CREDENTIAL_FILE_INFIXES)


def path_holds_credential_directory(path):
    """パスの構成要素に secrets/ や credentials/ が含まれるかを判定する。

    パスとして書かれている場合だけ対象にする
    (URL の一部や `gcloud secrets list` のような語は対象外)。
    """
    if "://" in path or "/" not in path:
        return False
    components = [
        component
        for component in path.replace("\\", "/").split("/")
        if component not in ("", ".", "..")
    ]
    return any(
        component.casefold() in CREDENTIAL_DIRECTORY_NAMES for component in components
    )


def argument_looks_like_local_path(path):
    """一般引数が package / repo 名ではなくローカルパスらしいかを返す。"""
    if path_contains_expansion(path):
        return True
    expanded = expand_home(path)
    if (
        os.path.isabs(expanded)
        or path in {".", ".."}
        or path.startswith(("./", "../", "~", "$HOME/", "${HOME}/"))
        or "/" in path
        and path.split("/", 1)[0].startswith(".")
    ):
        return True
    return False


def path_ends_with_credential_directory(path):
    """パスと確定した値の末尾が secrets / credentials かを判定する。"""
    if "://" in path:
        return False
    normalized = collapse_path_separators(path.replace("\\", "/")).rstrip("/")
    return normalized.rsplit("/", 1)[-1].casefold() in CREDENTIAL_DIRECTORY_NAMES


def path_contains_credential_fragment(path):
    """標準の認証情報パスを、先頭側の構成要素境界を含めて判定する。"""
    normalized = collapse_path_separators(path.replace("\\", "/")).casefold()
    bounded = "/" + normalized.lstrip("/")
    return any(
        "/" + fragment.casefold() in bounded
        for fragment in CREDENTIAL_PATH_FRAGMENTS
    )


def path_contains_credential_component(path):
    """既知の認証情報パスを、前後の構成要素境界を含めて判定する。"""
    normalized = collapse_path_separators(path.replace("\\", "/")).casefold()
    bounded = "/" + normalized.strip("/")
    for component in CREDENTIAL_FILE_COMPONENTS:
        marker = "/" + component.casefold().strip("/")
        start = 0
        while True:
            position = bounded.find(marker, start)
            if position < 0:
                break
            end = position + len(marker)
            if end == len(bounded) or bounded[end] == "/":
                return True
            start = position + 1
    return False


def resolved_path_is_credential(candidate, check_directories):
    """解決済みの絶対パスが認証情報を指すかを判定する (casefold 済みを受け取る)。

    symlink をたどった先で初めて `.env` や `*.tfstate` になる場合があるため、
    元の表記に当てた判定をここでも当て直す。
    ただし保管先ディレクトリの判定は、元の表記がパスとして書かれていたときだけ
    当てる。cwd 基準で解決すると、`gcloud secrets list` の `secrets` のような
    ただの語まで `<cwd>/secrets` というパスの形になってしまうため。
    """
    if basename_is_credential(os.path.basename(candidate.rstrip("/"))):
        return True
    if path_contains_credential_component(candidate):
        return True
    if check_directories and path_holds_credential_directory(candidate):
        return True
    if check_directories and path_contains_credential_fragment(candidate):
        return True
    for component in CREDENTIAL_FILE_COMPONENTS:
        sensitive = os.path.realpath(os.path.join(HOME_PATH, component)).casefold()
        if candidate == sensitive or candidate.startswith(sensitive + os.sep):
            return True
    for absolute in CREDENTIAL_ABSOLUTE_PATHS:
        sensitive = os.path.realpath(absolute).casefold()
        if candidate == sensitive or candidate.startswith(sensitive + os.sep):
            return True
    return False


def argument_is_credential_path(
    argument,
    path_context=False,
):
    """引数が認証情報ファイルを指しているかを判定する。

    `~` と `$HOME` は展開先が一意なので解決してから判定する。相対パスは cwd
    基準で解決したうえで、ホーム基準でも突き合わせる (cwd が $HOME の場合に
    `.ssh/id_rsa` のような指定で到達できるため)。
    表記そのものと、symlink をたどった実体の両方を見る。
    """
    home = HOME_PATH

    # 非 file URL はローカルの認証情報パスではない。file:// / fileb:// は
    # argument_path_candidates がローカル部分を別候補として取り出す。
    if "://" in argument and not argument.casefold().startswith(
        ("file://", "fileb://")
    ):
        return False

    if contains_credential_path_parameter(argument):
        return True

    if argument in ("${HOME}", "$HOME", "~"):
        # ホームそのものは対象外 (ls ~ を拒否しない)
        return False
    path = expand_home(argument)

    # macOS の既定ファイルシステムは大文字小文字を区別しないため、
    # ~/.SSH/ID_ED25519 のような表記でも同じ場所に届く。
    # 比較はすべて casefold して揃える
    basename = os.path.basename(path.rstrip("/")).casefold()

    # グロブはファイル名を特定できない。ディレクトリ側だけで判定する
    # (`find . -name '*.pem'` のような検索まで拒否しないため)
    if any(character in basename for character in "*?["):
        parent = os.path.dirname(path)
        return bool(parent) and directory_holds_credentials(parent)

    if basename_is_credential(basename):
        return True

    # secrets/ や credentials/ のような置き場は、位置に関係なく対象にする
    if path_holds_credential_directory(path) and (
        path_context or argument_looks_like_local_path(path)
    ):
        return True

    # 区切りの重複や `.` / `..` を畳んでから突き合わせる。
    # `gh//hosts.yml` のような 1 文字の追加で判定が外れないようにする
    folded_path = collapse_path_separators(path).casefold()
    if path_contains_credential_component(folded_path) and (
        path_context or argument_looks_like_local_path(path)
    ):
        return True
    # 保管先を指す部分パス。`$XDG_CONFIG_HOME/gh/hosts.yml` のように
    # 基準ディレクトリを差し替えられても届くよう、位置に依存せず見る
    if path_contains_credential_fragment(folded_path) and (
        path_context or argument_looks_like_local_path(path)
    ):
        return True

    if path_contains_expansion(path):
        # 解決できない展開が残る場合は構成要素の有無で判定する
        return any(
            component.casefold() in folded_path
            for component in CREDENTIAL_FILE_COMPONENTS
        )

    if "://" in path:
        # URL はローカルパスではない。cwd 基準で解決すると `://` が `:/` へ
        # 畳まれて、ただの URL がローカルパスの形になってしまう
        return False

    # cwd 基準とホーム基準の双方で突き合わせる。
    # cwd は PreToolUse イベントから受け取る (WORKING_DIRECTORY)
    bases = [
        path if os.path.isabs(path) else os.path.join(WORKING_DIRECTORY, path)
    ]
    if not os.path.isabs(path):
        bases.append(os.path.join(home, path))

    for base in bases:
        # 保管先ディレクトリの判定は、パスとして書かれていたときと、
        # symlink をたどって初めて構成要素が増えたときだけ当てる。
        # 常に当てると `gcloud secrets list` の `secrets` が cwd 基準で
        # `<cwd>/secrets` というパスの形になり、ただの語まで拒否してしまう
        check_directories = (
            path_context
            or argument_looks_like_local_path(path)
            or os.path.islink(base)
        )
        if resolved_path_is_credential(
            os.path.realpath(base).casefold(), check_directories
        ):
            return True
    return False


def collapse_path_separators(path):
    """区切りの重複と `.` / `..` を畳んで、部分一致の判定に使える形にする。

    展開マーカーが残っていても壊さないよう、`os.path.normpath` は使わない。
    """
    parts = []
    for part in path.replace("\\", "/").split("/"):
        if part == "" or part == ".":
            continue
        if part == ".." and parts and parts[-1] != "..":
            parts.pop()
            continue
        parts.append(part)
    collapsed = "/".join(parts)
    return "/" + collapsed if path.startswith("/") else collapsed


def directory_holds_credentials(directory):
    """ディレクトリが認証情報の保管先そのもの、またはその親かを判定する。

    `~/.aws/*` のようにファイル名を特定できない指定でも、
    展開先に保管先が含まれるなら拒否する。
    """
    path = expand_home(directory)
    if path_contains_expansion(path):
        folded = path.casefold()
        return any(
            component.casefold() in folded for component in CREDENTIAL_FILE_COMPONENTS
        )

    resolved = resolve_against_working_directory(path).casefold()
    for component in CREDENTIAL_FILE_COMPONENTS:
        sensitive = os.path.realpath(os.path.join(HOME_PATH, component)).casefold()
        if (
            resolved == sensitive
            or resolved.startswith(sensitive + os.sep)
            or sensitive.startswith(resolved.rstrip(os.sep) + os.sep)
        ):
            return True
    for absolute in CREDENTIAL_ABSOLUTE_PATHS:
        sensitive = os.path.realpath(absolute).casefold()
        if (
            resolved == sensitive
            or resolved.startswith(sensitive + os.sep)
            or sensitive.startswith(resolved.rstrip(os.sep) + os.sep)
        ):
            return True
    return False


def argument_path_candidates(argument):
    """1 つの引数に埋め込まれたパス表記を、判定対象として取り出す。

    `--opt=PATH`、`-oPATH`、`@PATH`、`key=@PATH` のようにオプションや
    フィールド名と連結された指定は、引数そのものを見るだけでは
    認証情報ファイルだと分からない。
    入れ子 (`-Fbody=@.env`) もあるため、取り出せなくなるまで剥がす。
    """
    candidates = []
    pending = [argument]
    seen = set()
    while pending:
        value = pending.pop()
        if not value or value in seen:
            continue
        seen.add(value)
        candidates.append(value)

        # AWS CLI などの file:// / fileb:// はローカルファイル取込指定。
        for prefix in ("fileb://", "file://"):
            if value.casefold().startswith(prefix) and len(value) > len(prefix):
                tail = value[len(prefix) :]
                pending.extend((tail, unquote(tail)))
                break

        # curl / gh api のファイル指定 (@PATH)
        if value.startswith("@") and len(value) > 1:
            pending.append(value[1:])
            continue
        if value.startswith("-") and value != "-":
            if "=" in value:
                pending.append(value.split("=", 1)[1])
            elif not value.startswith("--") and len(value) > 2:
                # -F.env のように短いオプションへ値を連結した形式
                pending.append(value[2:])
            continue
        # gh api -F body=@PATH のようなフィールド指定。
        # 値が @ で始まる場合だけ辿る (無関係な key=value を拾わないため)
        _, separator, tail = value.partition("=")
        if separator and tail.startswith("@"):
            pending.append(tail)
    return candidates


def argument_references_credential_path(argument, path_context=False):
    """引数そのもの、または引数へ連結されたパスが認証情報を指すかを判定する。"""
    return any(
        argument_is_credential_path(candidate, path_context=path_context)
        for candidate in argument_path_candidates(argument)
    )


def credential_path_existence_check(command, arguments):
    """内容を読まず、1パスの存在・通常ファイル判定だけを行う形かを返す。"""
    if command == "test":
        return len(arguments) == 2 and arguments[0] in {"-e", "-f"}
    if command == "[":
        return (
            len(arguments) == 3
            and arguments[0] in {"-e", "-f"}
            and arguments[2] == "]"
        )
    if command == "[[":
        return (
            len(arguments) == 3
            and arguments[0] in {"-e", "-f"}
            and arguments[2] == "]]"
        )
    return False


def option_value_argument_indexes(arguments, options):
    """明示した output option の値を持つ argv index を返す。"""
    options = set(options)
    short_options = {
        option
        for option in options
        if option.startswith("-")
        and not option.startswith("--")
        and len(option) == 2
    }
    indexes = set()
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            break
        option, separator, _value = argument.partition("=")
        if option in options:
            if separator:
                indexes.add(index)
            elif index + 1 < len(arguments):
                indexes.add(index + 1)
                index += 1
        elif any(
            argument.startswith(short) and len(argument) > len(short)
            for short in short_options
        ):
            indexes.add(index)
        index += 1
    return indexes


TAR_SHORT_VALUE_FLAGS = {"b", "C", "f", "g", "I", "K", "L", "N", "T", "V", "X"}


def tar_argument_state(arguments):
    """tar のmode・archive・値付きfile optionを一度だけ解析する。"""
    state = {
        "create": False,
        "extract": False,
        "archive": None,
        "archive_indexes": set(),
        "consumed_indexes": set(),
        "file_inputs": [],
        "directories": [],
        "legacy_cluster_index": None,
    }

    def record_value(flag, value, indexes):
        state["consumed_indexes"].update(indexes)
        if flag == "f":
            state["archive"] = value
            state["archive_indexes"].update(indexes)
        elif flag in {"T", "X"}:
            state["file_inputs"].append(value)
        elif flag == "C":
            state["directories"].append(value)

    index = 0
    if arguments and re.fullmatch(r"[A-Za-z]+", arguments[0]):
        state["legacy_cluster_index"] = 0
        cluster = arguments[0]
        state["create"] = "c" in cluster
        state["extract"] = "x" in cluster
        value_index = 1
        for flag in cluster:
            if flag not in TAR_SHORT_VALUE_FLAGS or value_index >= len(arguments):
                continue
            record_value(flag, arguments[value_index], {value_index})
            value_index += 1
        index = value_index

    long_value_options = {
        "--directory": "C",
        "--exclude-from": "X",
        "--file": "f",
        "--files-from": "T",
    }
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            break
        if argument == "--create":
            state["create"] = True
        elif argument in {"--extract", "--get"}:
            state["extract"] = True
        elif argument.startswith("--"):
            option, separator, joined = argument.partition("=")
            flag = long_value_options.get(option)
            if flag is not None and separator:
                record_value(flag, joined, {index})
            elif flag is not None and index + 1 < len(arguments):
                record_value(flag, arguments[index + 1], {index + 1})
                index += 1
        elif argument.startswith("-") and argument != "-":
            cluster = argument[1:]
            for position, flag in enumerate(cluster):
                if flag in TAR_SHORT_VALUE_FLAGS:
                    joined = cluster[position + 1 :].lstrip("=")
                    if joined:
                        record_value(flag, joined, {index})
                    elif index + 1 < len(arguments):
                        record_value(flag, arguments[index + 1], {index + 1})
                        index += 1
                    break
                state["create"] = state["create"] or flag == "c"
                state["extract"] = state["extract"] or flag == "x"
        index += 1
    return state


def ssh_keygen_non_generation(arguments):
    modes = {
        "-B", "-c", "-D", "-e", "-F", "-H", "-i", "-l", "-L", "-M",
        "-k", "-p", "-Q", "-R", "-r", "-s", "-Y", "-y",
    }
    for argument in arguments:
        option = argument.split("=", 1)[0]
        if option in modes:
            return True
        if not option.startswith("-") or option.startswith("--"):
            continue
        for flag in option[1:]:
            if "-" + flag in modes:
                return True
            if flag in {"f", "I", "N", "V", "z"}:
                break
    return False


def credential_path_argument_roles(command, arguments):
    """標準コマンドの path 引数を read / change / non-file に分ける。"""
    reads = set()
    changes = set()
    non_files = set()

    if command in {"echo", "printf"}:
        non_files.update(range(len(arguments)))
        return reads, changes, non_files

    interpreter = interpreter_name(command)
    if interpreter in INTERPRETER_CODE_OPTIONS:
        non_files.update(interpreter_code_argument_indexes(interpreter, arguments))

    if command == "dd":
        for index, argument in enumerate(arguments):
            operand, separator, _path = argument.partition("=")
            if separator and operand == "if":
                reads.add(index)
            elif separator and operand == "of":
                changes.add(index)

    if command in {"grep", "egrep", "fgrep", "rg"}:
        non_files.update(grep_non_file_argument_indexes(command, arguments))
    elif command in {"sed", "gsed"}:
        non_files.update(sed_program_argument_indexes(arguments))
    elif command in {"awk", "gawk", "mawk", "nawk"}:
        non_files.update(awk_program_argument_indexes(arguments))
    elif command in {"jq", "yq"}:
        non_files.update(jq_argument_roles(command, arguments)[1])
    elif command == "find":
        non_files.update(find_predicate_argument_indexes(arguments))
    elif command == "git":
        non_files.update(git_non_file_argument_indexes(arguments))
    elif command == "gh":
        non_files.update(gh_non_file_argument_indexes(arguments))
    elif command == "curl":
        non_files.update(
            option_value_argument_indexes(
                arguments, {"--data-raw", "--form-string"}
            )
        )
    elif command == "ssh-keygen":
        non_files.update(option_value_argument_indexes(arguments, {"-F", "-R"}))

    if command == "security":
        changes.update(security_public_export_output_indexes(arguments))

    if command in {"terraform", "terragrunt"}:
        changes.update(
            option_value_argument_indexes(
                arguments,
                {"-backup", "-generate-config-out", "-out", "-state-out"},
            )
        )

    output_options = {
        "curl": {
            "-c", "--cookie-jar", "-D", "--dump-header", "-o", "--output",
            "--output-dir", "--trace", "--trace-ascii",
        },
        "wget": {
            "-o", "--output-file", "-O", "--output-document", "-P",
            "--directory-prefix", "--save-cookies", "--warc-file",
        },
        "openssl": {"-out", "-keyout", "-writerand"},
        "unzip": {"-d"},
    }
    if command in output_options:
        changes.update(
            option_value_argument_indexes(arguments, output_options[command])
        )

    if command == "gh":
        cp_indexes = gh_codespace_cp_operand_indexes(arguments)
        if len(cp_indexes) >= 2 and not gh_codespace_cp_operand_is_remote(
            arguments[cp_indexes[-1]]
        ):
            changes.add(cp_indexes[-1])
        words = subcommand_words(
            arguments,
            GH_VALUE_OPTIONS | {"-D", "--dir", "-O", "--output"},
        )
        if words[:2] == ["release", "download"]:
            changes.update(
                option_value_argument_indexes(
                    arguments, {"-D", "--dir", "-O", "--output"}
                )
            )
        elif words[:2] == ["run", "download"]:
            changes.update(
                option_value_argument_indexes(arguments, {"-D", "--dir"})
            )

    if command in {"kubectl", "oc"}:
        cp_indexes = kubectl_cp_operand_indexes(arguments)
        if len(cp_indexes) == 2:
            reads.add(cp_indexes[0])
            changes.add(cp_indexes[1])

    if command == "git":
        indexes = positional_argument_indexes(arguments, GIT_VALUE_OPTIONS)
        words = [arguments[index] for index in indexes]
        if words[:1] == ["restore"]:
            restore_indexes = positional_argument_indexes(
                arguments,
                GIT_VALUE_OPTIONS | {"-s", "--source", "--pathspec-from-file"},
            )
            changes.update(restore_indexes[1:])
        elif words[:1] in (["rm"], ["mv"]):
            changes.update(indexes[1:])
        elif words[:1] == ["checkout"] and "--" in arguments:
            separator = arguments.index("--")
            changes.update(index for index in indexes if index > separator)
        words = subcommand_words(
            arguments,
            GIT_VALUE_OPTIONS
            | {"-o", "--output", "--output-directory"},
        )
        if words[:1] == ["archive"]:
            changes.update(
                option_value_argument_indexes(arguments, {"-o", "--output"})
            )
        elif words[:1] == ["format-patch"]:
            changes.update(
                option_value_argument_indexes(
                    arguments, {"-o", "--output-directory"}
                )
            )

    if command == "tar":
        tar_state = tar_argument_state(arguments)
        if tar_state["create"]:
            changes.update(tar_state["archive_indexes"])
        if tar_state["extract"]:
            changes.update(
                option_value_argument_indexes(arguments, {"-C", "--directory"})
            )
        elif not tar_state["create"]:
            non_files.update(
                option_value_argument_indexes(arguments, {"-C", "--directory"})
            )
        non_files.update(
            option_value_argument_indexes(
                arguments, {"--exclude", "--transform", "--use-compress-program"}
            )
        )

    if command == "sort":
        reads.update(
            option_value_argument_indexes(
                arguments, {"--files0-from", "--random-source"}
            )
        )
        value_options = {
            "-k", "--key", "-o", "--output", "-S", "--buffer-size",
            "-t", "--field-separator", "-T", "--temporary-directory",
            "--batch-size", "--compress-program", "--files0-from",
            "--parallel", "--random-source",
        }
        reads.update(positional_argument_indexes(arguments, value_options))
        changes.update(
            option_value_argument_indexes(arguments, {"-o", "--output"})
        )

    if command == "uniq":
        indexes = positional_argument_indexes(
            arguments,
            {
                "-f", "--skip-fields", "-s", "--skip-chars",
                "-w", "--check-chars",
            },
        )
        if indexes:
            reads.add(indexes[0])
        if len(indexes) > 1:
            changes.add(indexes[1])

    if command == "zip":
        indexes = positional_argument_indexes(
            arguments,
            {
                "-b", "--temp-path", "-n", "--suffixes", "-P", "--password",
                "--out",
            },
        )
        if indexes:
            out_indexes = option_value_argument_indexes(arguments, {"--out"})
            if out_indexes:
                reads.add(indexes[0])
                changes.update(out_indexes)
            else:
                changes.add(indexes[0])
            reads.update(indexes[1:])
        pattern_mode = False
        for index, argument in enumerate(arguments):
            if argument in {"-i", "--include", "-x", "--exclude"}:
                pattern_mode = True
                continue
            if pattern_mode:
                non_files.add(index)
        reads.difference_update(non_files)

    if command == "unzip":
        indexes = positional_argument_indexes(
            arguments, {"-d", "-P", "--password"}
        )
        if indexes:
            reads.add(indexes[0])
            non_files.update(indexes[1:])

    if command == "ssh-keygen":
        ssh_value_options = {
            "-E", "-I", "-M", "-N", "-O", "-P", "-R", "-S", "-V",
            "-Y", "-Z", "-a", "-b", "-C", "-D", "-f", "-F", "-g",
            "-m", "-n", "-r", "-s", "-t", "-w", "-z",
        }
        ssh_options = {argument.split("=", 1)[0] for argument in arguments}
        ssh_positionals = positional_argument_indexes(arguments, ssh_value_options)
        if ssh_options & {"-Y", "-Q", "-k"}:
            reads.update(ssh_positionals)
        if "-M" in ssh_options:
            changes.update(ssh_positionals)
        if ssh_keygen_non_generation(arguments):
            reads.update(option_value_argument_indexes(arguments, {"-f", "-s"}))
        else:
            changes.update(option_value_argument_indexes(arguments, {"-f"}))

    if command in {"cat", "tac"}:
        reads.update(positional_argument_indexes(arguments, set()))
    elif command in {"head", "tail"}:
        reads.update(
            positional_argument_indexes(
                arguments, {"-c", "--bytes", "-n", "--lines", "--pid"}
            )
        )
    elif command in {"cp", "install"}:
        value_options = {"-S", "--suffix", "-t", "--target-directory"}
        if command == "install":
            value_options |= {
                "-B",
                "--backup",
                "-f",
                "--group",
                "-g",
                "-m",
                "--mode",
                "-o",
                "--owner",
            }
        indexes = positional_argument_indexes(arguments, value_options)
        target_directory_indexes = set()
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument in {"-t", "--target-directory"}:
                if index + 1 < len(arguments):
                    target_directory_indexes.add(index + 1)
                index += 2
                continue
            if argument.startswith("--target-directory=") or (
                argument.startswith("-t") and len(argument) > 2
            ):
                target_directory_indexes.add(index)
            index += 1
        if command == "install" and boolean_option_enabled(
            arguments, {"--directory"}, short_flags={"d"}
        ):
            changes.update(indexes)
        elif target_directory_indexes:
            reads.update(indexes)
            changes.update(target_directory_indexes)
        elif len(indexes) >= 2:
            reads.update(indexes[:-1])
            changes.add(indexes[-1])
    elif command == "mv":
        changes.update(range(len(arguments)))
    elif command in {
        "mkdir",
        "mkfifo",
        "rm",
        "rmdir",
        "tee",
        "touch",
        "truncate",
        "unlink",
    }:
        changes.update(range(len(arguments)))

    return reads, changes, non_files


def credential_path_argument_value(command, argument):
    """path role を持つ引数から、実際のパス部分を返す。"""
    if command == "dd":
        operand, separator, path = argument.partition("=")
        if separator and operand in {"if", "of"}:
            return path
    return argument


def credential_identifier_argument_indexes(command, arguments):
    """認証情報名と同じでも、コマンド構文上ファイルでない引数位置を返す。"""
    identifier_names = set(CREDENTIAL_DIRECTORY_NAMES)
    if command == "gcloud":
        value_options = SECRET_TOOL_SUBCOMMANDS["gcloud"][0]
        indexes = positional_argument_indexes(arguments, value_options)
        position = 0
        while (
            position < len(indexes)
            and arguments[indexes[position]] in RELEASE_TRACK_PREFIXES
        ):
            position += 1
        if position < len(indexes) and arguments[indexes[position]] == "secrets":
            return {indexes[position]}
        return set()

    if command in CONTAINER_COMMANDS:
        child_operands = container_child_operand_candidates(arguments)
        ignored = set(child_operands)
        for operand in child_operands:
            ignored.update(range(operand + 1, len(arguments)))
        indexes = positional_argument_indexes(
            arguments,
            DOCKER_VALUE_OPTIONS | DOCKER_EXEC_CHILD_VALUE_OPTIONS,
        )
        words = tuple(arguments[index] for index in indexes)
        host_path_commands = (
            *DOCKER_BUILD_SUBCOMMANDS,
            *DOCKER_COPY_SUBCOMMANDS,
            ("import",),
            ("image", "import"),
            ("load",),
            ("image", "load"),
            ("secret", "create"),
            ("config", "create"),
            ("context", "import"),
            ("plugin", "create"),
        )
        if not any(
            words[: len(expected)] == expected for expected in host_path_commands
        ):
            ignored.update(
                index
                for index in indexes[1:]
                if arguments[index].casefold() in identifier_names
            )
        return ignored

    if command == "git":
        indexes = positional_argument_indexes(arguments, GIT_VALUE_OPTIONS)
        words = [arguments[index] for index in indexes]
        if words[:1] in (["branch"], ["switch"]):
            return {
                index
                for index in indexes[1:]
                if arguments[index].casefold() in identifier_names
            }
        if words[:1] in (["ls-files"], ["check-ignore"]):
            metadata_value_options = {
                "-x",
                "--exclude",
                "-X",
                "--exclude-from",
                "--exclude-per-directory",
                "--format",
                "--with-tree",
            }
            metadata_indexes = positional_argument_indexes(
                arguments, GIT_VALUE_OPTIONS | metadata_value_options
            )
            return set(metadata_indexes[1:])
        metadata_pathspec_indexes = git_metadata_only_pathspec_indexes(
            arguments, indexes, words
        )
        if metadata_pathspec_indexes:
            return metadata_pathspec_indexes
        return set()

    if command == "gh":
        indexes = positional_argument_indexes(arguments, GH_VALUE_OPTIONS)
        words = [arguments[index] for index in indexes]
        if words[:2] in (["repo", "view"], ["pr", "view"]):
            return {
                index
                for index in indexes[2:]
                if arguments[index].casefold() in identifier_names
            }
        return set()

    package_actions = {
        "npm": {"add", "i", "install"},
        "pnpm": {"add", "i", "install"},
    }
    if command in package_actions:
        indexes = positional_argument_indexes(arguments, set())
        words = [arguments[index] for index in indexes]
        if words[:1] and words[0] in package_actions[command]:
            return {
                index
                for index in indexes[1:]
                if arguments[index].casefold() in identifier_names
            }
    return set()


def gh_codespace_cp_operand_indexes(arguments):
    """gh codespace cp の source / destination index を返す。"""
    value_options = (
        GH_VALUE_OPTIONS
        | GH_FILE_INPUT_OPTIONS
        | {"-p", "--profile", "--repo-owner"}
    )
    indexes = positional_argument_indexes(arguments, value_options)
    words = [arguments[index] for index in indexes]
    if tuple(words[:2]) not in {("codespace", "cp"), ("cs", "cp")}:
        return []
    return indexes[2:]


def gh_codespace_cp_operand_is_remote(operand):
    """codespace cp の `remote:PATH` operand かを見る。"""
    return operand.casefold().startswith("remote:")


def kubectl_cp_operand_indexes(arguments):
    """kubectl/oc cp の source / destination index を返す。"""
    indexes = positional_argument_indexes(
        arguments,
        KUBECTL_REMOTE_CHILD_VALUE_OPTIONS | {"--retries"},
    )
    if not indexes or arguments[indexes[0]] != "cp":
        return []
    operands = indexes[1:]
    return operands if len(operands) == 2 else []


def kubectl_cp_operand_path(operand):
    """[namespace/]pod:PATH は remote path、その他は local path を返す。"""
    _pod, separator, path = operand.partition(":")
    return path if separator else operand


def gh_non_file_argument_indexes(arguments):
    """gh の query / literal text / output template argv index を返す。"""
    non_files = option_value_argument_indexes(arguments, {"-q", "--jq"})
    text_options = {"-S", "--search", "-b", "--body", "-t", "--title"}
    indexes = positional_argument_indexes(arguments, GH_VALUE_OPTIONS | text_options)
    words = [arguments[index] for index in indexes]
    prefix = tuple(words[:2])
    if prefix in {("issue", "list"), ("pr", "list")}:
        non_files.update(
            option_value_argument_indexes(arguments, {"-S", "--search"})
        )
    if prefix in {("issue", "create"), ("pr", "create")}:
        non_files.update(
            option_value_argument_indexes(
                arguments, {"-b", "--body", "-t", "--title"}
            )
        )
    if words[:2] != ["pr", "create"]:
        non_files.update(option_value_argument_indexes(arguments, {"--template"}))
    if words[:1] == ["search"] and len(indexes) > 2:
        non_files.update(indexes[2:])
    return non_files


def gh_file_ingress_references(arguments):
    """gh が外部サービスへ送るローカルファイル・ディレクトリを返す。"""
    references = list(
        option_values_with_joined(arguments, GH_FILE_INPUT_OPTIONS)
    )
    gist_edit_value_options = {
        "-a",
        "--add",
        "-d",
        "--desc",
        "-f",
        "--filename",
        "-r",
        "--remove",
    }
    indexes = positional_argument_indexes(
        arguments,
        GH_VALUE_OPTIONS | GH_FILE_INPUT_OPTIONS,
    )
    words = [arguments[index] for index in indexes]

    if words[:2] in (["repo", "create"], ["repo", "new"]):
        references.extend(
            option_values_with_joined(arguments, {"-s", "--source"})
        )
    elif words[:2] == ["pr", "create"]:
        references.extend(
            option_values_with_joined(arguments, {"-T", "--template"})
        )

    short_body_file_subcommands = {
        ("issue", "comment"),
        ("issue", "create"),
        ("issue", "edit"),
        ("pr", "comment"),
        ("pr", "create"),
        ("pr", "edit"),
        ("pr", "merge"),
        ("pr", "review"),
        ("pr", "revert"),
        ("release", "create"),
        ("release", "edit"),
    }
    if tuple(words[:2]) in short_body_file_subcommands:
        references.extend(option_values_with_joined(arguments, {"-F"}))
    if words[:2] == ["gist", "edit"]:
        references.extend(
            option_values_with_joined(arguments, {"-a", "--add"})
        )
        gist_indexes = positional_argument_indexes(
            arguments,
            GH_VALUE_OPTIONS | GH_FILE_INPUT_OPTIONS | gist_edit_value_options,
        )
        gist_words = [arguments[index] for index in gist_indexes]
        # ID の後に残る positional は --filename で選んだ gist file の
        # replacement として読むローカルファイル。
        references.extend(gist_words[3:])

    if words[:2] in (["secret", "set"], ["variable", "set"]):
        references.extend(
            option_values_with_joined(arguments, {"-f", "--env-file"})
        )
    if words[:1] == ["api"]:
        references.extend(
            value
            for value in gh_api_option_values(
                arguments, {"-F", "--field"}
            )
            if value.startswith("@") or "=@" in value
        )
    if words[:2] == ["attestation", "verify"]:
        references.extend(option_values_with_joined(arguments, {"-b"}))

    release_create_value_options = {
        "--discussion-category",
        "-n",
        "--notes",
        "--notes-start-tag",
        "--target",
        "-t",
        "--title",
    }
    attestation_value_options = {
        "-d",
        "--digest-alg",
        "-L",
        "--limit",
        "-o",
        "--owner",
        "--predicate-type",
    }
    positional_specs = (
        (("release", "create"), 3, release_create_value_options),
        (("release", "new"), 3, release_create_value_options),
        (("release", "upload"), 3, set()),
        (("gist", "create"), 2, gist_edit_value_options),
        (("gist", "new"), 2, gist_edit_value_options),
        (("ssh-key", "add"), 2, {"-t", "--title", "--type"}),
        (("gpg-key", "add"), 2, {"-t", "--title"}),
        (("repo", "deploy-key", "add"), 3, {"-t", "--title"}),
        (("attestation", "download"), 2, attestation_value_options),
        (
            ("attestation", "verify"),
            2,
            attestation_value_options
            | {
                "-b",
                "--cert-identity",
                "-i",
                "--cert-identity-regex",
                "--cert-oidc-issuer",
                "--format",
                "--signer-digest",
                "--signer-repo",
                "--signer-workflow",
                "--source-digest",
                "--source-ref",
                "-t",
            },
        ),
    )
    for prefix, start, value_options in positional_specs:
        scoped_words = subcommand_words(
            arguments,
            GH_VALUE_OPTIONS | GH_FILE_INPUT_OPTIONS | value_options,
        )
        if tuple(scoped_words[: len(prefix)]) == prefix:
            positional = scoped_words[start:]
            if prefix in {
                ("release", "create"),
                ("release", "new"),
                ("release", "upload"),
            }:
                positional = [asset.split("#", 1)[0] for asset in positional]
            references.extend(positional)
            break

    verify_words = subcommand_words(
        arguments,
        GH_VALUE_OPTIONS
        | GH_FILE_INPUT_OPTIONS
        | {"--format", "-t", "--template"},
    )
    if verify_words[:2] == ["release", "verify-asset"]:
        operands = verify_words[2:]
        if operands:
            references.append(operands[-1])

    cp_indexes = gh_codespace_cp_operand_indexes(arguments)
    if len(cp_indexes) >= 2:
        source_indexes = cp_indexes[:-1]
        destination = arguments[cp_indexes[-1]]
        if gh_codespace_cp_operand_is_remote(destination):
            references.extend(
                arguments[index]
                for index in source_indexes
                if not gh_codespace_cp_operand_is_remote(arguments[index])
            )
        else:
            references.extend(
                arguments[index].split(":", 1)[1]
                for index in source_indexes
                if gh_codespace_cp_operand_is_remote(arguments[index])
            )

    # Cobra / pflag は boolean shorthand の後ろに、値付き shorthand と値を
    # 連結できる (`-dTFILE` など)。通常の `-TFILE` 抽出だけでは先頭の
    # boolean に隠れるため、ファイル入力を持つ command の正式な flag だけを
    # command ごとに解釈する。
    short_cluster_inputs = (
        (
            ("repo", "create"),
            {"-s"},
            {"-d", "-g", "-h", "-l", "-p", "-r", "-R", "-s", "-t"},
            {"c"},
        ),
        (
            ("repo", "new"),
            {"-s"},
            {"-d", "-g", "-h", "-l", "-p", "-r", "-R", "-s", "-t"},
            {"c"},
        ),
        (
            ("pr", "create"),
            {"-F", "-T"},
            {"-a", "-B", "-b", "-F", "-H", "-l", "-m", "-p", "-r", "-R", "-T", "-t"},
            {"d", "e", "f", "w"},
        ),
        (("issue", "comment"), {"-F"}, {"-b", "-F", "-R"}, {"e", "w"}),
        (
            ("issue", "create"),
            {"-F"},
            {"-a", "-b", "-F", "-l", "-m", "-p", "-R", "-T", "-t"},
            {"e", "w"},
        ),
        (("pr", "comment"), {"-F"}, {"-b", "-F", "-R"}, {"e", "w"}),
        (
            ("pr", "merge"),
            {"-F"},
            {"-A", "-b", "-F", "-R", "-t"},
            {"d", "m", "r", "s"},
        ),
        (("pr", "review"), {"-F"}, {"-b", "-F", "-R"}, {"a", "c", "r"}),
        (("pr", "revert"), {"-F"}, {"-b", "-F", "-R", "-t"}, {"d"}),
        (
            ("release", "create"),
            {"-F"},
            {"-F", "-n", "-R", "-t"},
            {"d", "p"},
        ),
        (
            ("release", "new"),
            {"-F"},
            {"-F", "-n", "-R", "-t"},
            {"d", "p"},
        ),
        (
            ("secret", "set"),
            {"-f"},
            {"-a", "-b", "-e", "-f", "-o", "-r", "-R", "-v"},
            {"u"},
        ),
    )
    for prefix, file_options, value_options, boolean_flags in short_cluster_inputs:
        if tuple(words[: len(prefix)]) != prefix:
            continue
        references.extend(
            value
            for option, value, _indexes in docker_short_option_occurrences(
                arguments, value_options, boolean_flags
            )
            if option in file_options
        )
    return references


def terraform_file_ingress_references(arguments):
    """Terraform / Terragrunt がサンドボックス外で読むパスを返す。"""
    references = option_values_with_joined(
        arguments, TERRAFORM_FILE_INPUT_OPTIONS
    )
    indexes = positional_argument_indexes(
        arguments, TERRAFORM_VALUE_OPTIONS | TERRAFORM_FILE_INPUT_OPTIONS
    )
    words = [arguments[index] for index in indexes]
    if words[:1] in (["apply"], ["show"], ["fmt"]):
        references.extend(words[1:])
    elif words[:2] == ["state", "push"]:
        references.extend(words[2:])
    return references


def clustered_option_values(arguments, targets, value_options, boolean_flags):
    """短縮 option cluster から対象 option の値だけを返す。"""
    return [
        value
        for option, value, _indexes in docker_short_option_occurrences(
            arguments, value_options, boolean_flags
        )
        if option in targets
    ]


GREP_SHORT_BOOLEAN_FLAGS = {
    "a", "b", "c", "E", "F", "G", "H", "h", "I", "i", "J", "L", "l",
    "M", "n", "O", "o", "P", "q", "R", "r", "S", "s", "U", "v", "w",
    "X", "x", "z", "Z",
}
SED_SHORT_BOOLEAN_FLAGS = {"a", "E", "l", "n", "r", "s", "u"}


def grep_short_option_occurrences(arguments):
    return docker_short_option_occurrences(
        arguments, {"-e", "-f"}, GREP_SHORT_BOOLEAN_FLAGS
    )


def sed_short_option_occurrences(arguments):
    return docker_short_option_occurrences(
        arguments, {"-e", "-f"}, SED_SHORT_BOOLEAN_FLAGS
    )


def grep_non_file_argument_indexes(command, arguments):
    """grep / rg の pattern・glob・数値などの argv index を返す。"""
    common_value_options = {
        "-A", "--after-context", "-B", "--before-context",
        "-C", "--context", "-D", "--devices", "-d", "--directories",
        "-e", "--regexp", "-f", "--file", "-m", "--max-count",
        "--binary-files", "--exclude", "--exclude-dir", "--exclude-from",
        "--include", "--label",
    }
    value_options = common_value_options
    if command == "rg":
        value_options |= {
            "-E", "--encoding", "-g", "--glob", "-j", "--threads",
            "-M", "--max-columns", "--max-depth", "--max-filesize",
            "--path-separator", "-r", "--replace", "--sort", "--sortr",
            "-t", "--type", "-T", "--type-not", "--type-add",
            "--type-clear", "--engine", "--pre", "--pre-glob",
        }
    non_file_options = value_options - {"-f", "--file", "--exclude-from"}
    non_files = option_value_argument_indexes(arguments, non_file_options)
    occurrences = grep_short_option_occurrences(arguments)
    for option, _value, indexes in occurrences:
        if option == "-e":
            non_files.update(indexes)
    has_pattern_option = bool(
        option_values_with_joined(
            arguments, {"-e", "--regexp", "-f", "--file"}
        )
        or occurrences
    )
    if not has_pattern_option:
        indexes = positional_argument_indexes(arguments, value_options)
        if indexes:
            non_files.add(indexes[0])
    return non_files


def sed_program_argument_indexes(arguments):
    """sed の expression（script file ではない）argv index を返す。"""
    script_options = {"-e", "--expression", "-f", "--file"}
    non_files = option_value_argument_indexes(arguments, {"-e", "--expression"})
    non_files.update(
        option_value_argument_indexes(arguments, {"-i", "--in-place"})
    )
    occurrences = sed_short_option_occurrences(arguments)
    for option, _value, indexes in occurrences:
        if option == "-e":
            non_files.update(indexes)
    if not option_values_with_joined(arguments, script_options) and not occurrences:
        indexes = positional_argument_indexes(arguments, script_options)
        if indexes:
            non_files.add(indexes[0])
    return non_files


def awk_program_argument_indexes(arguments):
    """awk の program・代入・field separator argv index を返す。"""
    program_options = {"-e", "--source", "-f", "--file"}
    value_options = program_options | {
        "-F", "--field-separator", "-v", "--assign", "-W",
    }
    non_files = option_value_argument_indexes(
        arguments,
        {"-e", "--source", "-F", "--field-separator", "-v", "--assign", "-W"},
    )
    if not option_values_with_joined(arguments, program_options):
        indexes = positional_argument_indexes(arguments, value_options)
        if indexes:
            non_files.add(indexes[0])
    return non_files


def find_predicate_argument_indexes(arguments):
    """find の name/path/regex predicate argv index を返す。"""
    return option_value_argument_indexes(
        arguments,
        {
            "-name", "-iname", "-path", "-ipath", "-wholename",
            "-iwholename", "-regex", "-iregex", "-lname", "-ilname",
        },
    )


def grep_file_ingress_references(command, arguments):
    """grep / rg が pattern とは別に読む file operand を返す。"""
    common_value_options = {
        "-A", "--after-context", "-B", "--before-context",
        "-C", "--context", "-D", "--devices", "-d", "--directories",
        "-e", "--regexp", "-f", "--file", "-m", "--max-count",
        "--binary-files", "--exclude", "--exclude-dir", "--exclude-from",
        "--include", "--label",
    }
    if command == "rg":
        value_options = common_value_options | {
            "-E", "--encoding", "-g", "--glob", "-j", "--threads",
            "-M", "--max-columns", "--max-depth", "--max-filesize",
            "--path-separator", "-r", "--replace", "--sort", "--sortr",
            "-t", "--type", "-T", "--type-not", "--type-add",
            "--type-clear", "--engine", "--pre", "--pre-glob",
        }
    else:
        value_options = common_value_options

    pattern_options = {"-e", "--regexp", "-f", "--file"}
    occurrences = grep_short_option_occurrences(arguments)
    cluster_values = [value for _option, value, _indexes in occurrences]
    references = option_values_with_joined(
        arguments, {"-f", "--file", "--exclude-from"}
    )
    references.extend(
        value for option, value, _indexes in occurrences
        if option == "-f"
    )
    indexes = positional_argument_indexes(arguments, value_options)
    has_pattern_option = bool(
        option_values_with_joined(arguments, pattern_options) or cluster_values
    )
    if not has_pattern_option and indexes:
        indexes = indexes[1:]
    references.extend(arguments[index] for index in indexes)
    return references


def sed_file_ingress_references(arguments):
    """sed が expression とは別に読む script file / input file を返す。"""
    script_options = {"-e", "--expression", "-f", "--file"}
    references = option_values_with_joined(arguments, {"-f", "--file"})
    occurrences = sed_short_option_occurrences(arguments)
    cluster_values = [value for _option, value, _indexes in occurrences]
    references.extend(
        value for option, value, _indexes in occurrences
        if option == "-f"
    )
    indexes = positional_argument_indexes(arguments, script_options)
    has_script_option = bool(
        option_values_with_joined(arguments, script_options) or cluster_values
    )
    if not has_script_option and indexes:
        indexes = indexes[1:]
    references.extend(arguments[index] for index in indexes)
    return references


def awk_file_ingress_references(arguments):
    """awk が program とは別に読む program file / input file を返す。"""
    program_options = {"-e", "--source", "-f", "--file"}
    value_options = program_options | {
        "-F", "--field-separator", "-v", "--assign", "-W",
    }
    references = option_values_with_joined(arguments, {"-f", "--file"})
    indexes = positional_argument_indexes(arguments, value_options)
    has_program_option = bool(
        option_values_with_joined(arguments, program_options)
    )
    if not has_program_option and indexes:
        indexes = indexes[1:]
    references.extend(
        arguments[index]
        for index in indexes
        if not ASSIGNMENT_RE.match(arguments[index])
    )
    return references


def jq_argument_roles(command, arguments):
    """jq / yq の file input と filter/value argv index を返す。"""
    file_options = {"-f", "--from-file", "-L", "--split-exp-file"}
    one_value_options = file_options | {
        "--expression", "--indent", "-I", "-o", "--output-format",
        "-p", "--input-format",
    }
    two_value_options = {"--arg", "--argjson"}
    two_value_file_options = {"--argfile", "--rawfile", "--slurpfile"}
    references = []
    positional = []
    non_files = set()
    filter_from_file = False
    null_input = False
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if command == "yq" and argument in {"-n", "--null-input"}:
            null_input = True
        if argument == "--":
            positional.extend(enumerate(arguments[index + 1 :], index + 1))
            break
        option, separator, joined = argument.partition("=")
        if option in one_value_options:
            filter_from_file = filter_from_file or option in {"-f", "--from-file"}
            if separator:
                if option in file_options:
                    references.append(joined)
                else:
                    non_files.add(index)
                index += 1
                continue
            if index + 1 < len(arguments):
                if option in file_options:
                    references.append(arguments[index + 1])
                else:
                    non_files.add(index + 1)
                index += 2
                continue
        if option in two_value_options | two_value_file_options:
            if index + 2 < len(arguments):
                if option in two_value_file_options:
                    references.append(arguments[index + 2])
                    non_files.add(index + 1)
                else:
                    non_files.update({index + 1, index + 2})
                index += 3
                continue
        if argument.startswith("-f") and len(argument) > 2:
            filter_from_file = True
            references.append(argument[2:])
        elif argument.startswith("-L") and len(argument) > 2:
            references.append(argument[2:])
        elif not argument.startswith("-") or argument == "-":
            positional.append((index, argument))
        index += 1

    if command == "yq" and positional and positional[0][1] in {
        "e", "ea", "eval", "eval-all",
    }:
        non_files.add(positional[0][0])
        positional = positional[1:]
    if filter_from_file:
        references.extend(value for _index, value in positional)
    elif command == "yq" and len(positional) == 1:
        if null_input:
            non_files.add(positional[0][0])
        else:
            references.append(positional[0][1])
    else:
        if positional:
            non_files.add(positional[0][0])
        references.extend(value for _index, value in positional[1:])
    return references, non_files


def jq_file_ingress_references(command, arguments):
    return jq_argument_roles(command, arguments)[0]


def curl_file_ingress_references(arguments):
    direct_file_options = {
        "-K", "--config", "-T", "--upload-file", "-E", "--cert", "--key",
        "--cacert", "--capath", "--netrc-file", "--proxy-cert", "--proxy-key",
        "--proxy-cacert",
    }
    references = option_values_with_joined(arguments, direct_file_options)
    references.extend(
        clustered_option_values(
            arguments,
            {"-E", "-K", "-T"},
            {
                "-A", "-b", "-c", "-C", "-d", "-D", "-e", "-E", "-F",
                "-h", "-H", "-K", "-m", "-o", "-P", "-Q", "-r", "-t", "-T",
                "-u", "-U", "-w", "-x", "-X", "-y", "-Y", "-z",
            },
            {
                "#", "0", "1", "2", "3", "4", "6", "a", "B", "f", "g",
                "G", "i", "I", "j", "J", "k", "l", "L", "M", "n", "N",
                "O", "p", "q", "R", "s", "S", "v", "V", "Z",
            },
        )
    )
    at_file_options = {
        "-d", "--data", "--data-ascii", "--data-binary", "--data-urlencode",
        "--json", "-H", "--header", "-F", "--form",
    }
    for option in at_file_options:
        for value in option_values_with_joined(arguments, {option}):
            if value.startswith("@"):
                references.append(value[1:])
            elif option in {"--data-urlencode"} and "@" in value:
                references.append(value.split("@", 1)[1])
            elif option in {"-F", "--form"}:
                for marker in ("=@", "=<"):
                    if marker in value:
                        references.append(value.split(marker, 1)[1])
                        break
    return references


def wget_file_ingress_references(arguments):
    references = option_values_with_joined(
        arguments,
        {
            "-i", "--input-file", "--config", "--load-cookies", "--certificate",
            "--private-key", "--ca-certificate",
        },
    )
    references.extend(
        clustered_option_values(
            arguments,
            {"-i"},
            {"-a", "-A", "-B", "-D", "-e", "-i", "-l", "-o", "-O", "-P", "-R", "-t", "-T", "-U", "-w"},
            {"b", "c", "d", "E", "F", "H", "h", "k", "m", "N", "n", "p", "q", "r", "S", "v", "V", "x"},
        )
    )
    return references


def openssl_file_ingress_references(arguments):
    return option_values_with_joined(
        arguments,
        {
            "-in", "-key", "-inkey", "-cert", "-CAfile", "-CApath", "-config",
            "-extfile", "-signkey", "-untrusted", "-chain", "-certfile",
        },
    )


def ssh_keygen_file_ingress_references(arguments):
    if not ssh_keygen_non_generation(arguments):
        return []
    references = option_values_with_joined(arguments, {"-f", "-s"})
    references.extend(
        clustered_option_values(
            arguments,
            {"-f", "-s"},
            {"-E", "-I", "-M", "-N", "-O", "-P", "-R", "-S", "-V", "-Y", "-Z", "-a", "-b", "-C", "-D", "-f", "-F", "-g", "-m", "-n", "-r", "-s", "-t", "-w", "-z"},
            {"A", "B", "c", "e", "H", "i", "K", "k", "L", "l", "p", "q", "Q", "U", "u", "v", "y"},
        )
    )
    return references


def tar_file_ingress_references(arguments):
    """tar が読む archive file または create の入力パスを返す。"""
    if not arguments:
        return []
    state = tar_argument_state(arguments)
    references = list(state["file_inputs"])
    if state["create"]:
        references.extend(state["directories"])
    if not state["create"]:
        if state["archive"] not in {None, "-"}:
            references.append(state["archive"])
        return references
    value_options = {
        "-C", "--directory", "-f", "--file", "-T", "--files-from",
        "--exclude", "--exclude-from", "--transform",
        "--use-compress-program",
    }
    indexes = positional_argument_indexes(arguments, value_options)
    ignored = state["archive_indexes"] | state["consumed_indexes"]
    if state["legacy_cluster_index"] is not None:
        ignored.add(state["legacy_cluster_index"])
    references.extend(
        arguments[index] for index in indexes if index not in ignored
    )
    return references


def git_cat_file_outputs_batch_contents(option):
    """cat-file の blob 内容を返す batch option（有効な省略形を含む）を見る。"""
    name = option.split("=", 1)[0]
    if name == "--batch":
        return True
    shortest = "--batch-co"
    full = "--batch-command"
    return len(name) >= len(shortest) and full.startswith(name)


def git_cat_file_only_reads_metadata(candidates, arguments):
    """cat-file の存在・型・sizeだけを返す mode かを判定する。"""
    if not subcommand_candidates_match(candidates, ("cat-file",)):
        return False
    options = arguments[: arguments.index("--")] if "--" in arguments else arguments
    if any(
        git_cat_file_outputs_batch_contents(option) for option in options
    ):
        return False
    if any(option in {"-p", "--textconv", "--filters"} for option in options):
        return False
    return any(option in {"-e", "-t", "-s"} for option in options)


def git_status_outputs_patch(arguments, command_index):
    """status の -v/--verbose（差分本文を出す指定）が有効かを見る。"""
    end = arguments.index("--") if "--" in arguments else len(arguments)
    for argument in arguments[command_index + 1 : end]:
        option = argument.split("=", 1)[0]
        if option.startswith("--"):
            if len(option) >= len("--v") and "--verbose".startswith(option):
                return True
            continue
        if option.startswith("-") and option != "-" and "v" in option[1:]:
            return True
    return False


def git_metadata_only_pathspec_indexes(arguments, indexes=None, words=None):
    """内容を読まない Git 操作の path / object 引数を返す。"""
    if indexes is None:
        indexes = positional_argument_indexes(arguments, GIT_VALUE_OPTIONS)
    if words is None:
        words = [arguments[index] for index in indexes]
    if not words:
        return set()
    command = words[0]
    if command in {"status", "check-attr", "ls-tree"}:
        if command == "status" and git_status_outputs_patch(arguments, indexes[0]):
            return set()
        return set(indexes[1:])
    if command == "rm" and boolean_option_enabled(arguments, {"--cached"}):
        return set(indexes[1:])
    if command == "restore" and boolean_option_enabled(
        arguments, {"--staged"}, short_flags={"S"}
    ) and not boolean_option_enabled(
        arguments, {"--worktree"}, short_flags={"W"}
    ):
        return set(indexes[1:])
    if command == "clean" and boolean_option_enabled(
        arguments, {"--dry-run"}, short_flags={"n"}
    ):
        return set(indexes[1:])
    if command == "reset" and "--" in arguments:
        separator = arguments.index("--")
        return {index for index in indexes if index > separator}
    return set()


def git_literal_content_pathspecs(arguments):
    """本文を出す標準 Git 操作に直接書かれた literal pathspec を返す。"""
    indexes = positional_argument_indexes(arguments, GIT_VALUE_OPTIONS)
    words = [arguments[index] for index in indexes]
    status_with_patch = bool(
        words
        and words[0] == "status"
        and git_status_outputs_patch(arguments, indexes[0])
    )
    reflog_with_patch = bool(
        words
        and words[0] == "reflog"
        and boolean_option_enabled(arguments, {"--patch"}, short_flags={"p"})
    )
    if not words or words[0] not in {
        "annotate",
        "archive",
        "blame",
        "checkout-index",
        "diff",
        "diff-files",
        "diff-index",
        "diff-tree",
        "difftool",
        "fast-export",
        "format-patch",
        "grep",
        "log",
        "reflog",
        "show",
        "status",
        "whatchanged",
    } or (words[0] == "status" and not status_with_patch) or (
        words[0] == "reflog" and not reflog_with_patch
    ):
        return []

    if "--" in arguments:
        references = arguments[arguments.index("--") + 1 :]
    elif words[0] in {"annotate", "blame"}:
        references = words[-1:]
    elif words[0] == "checkout-index":
        references = words[1:]
    elif words[0] == "grep":
        references = [
            arguments[index]
            for index in indexes[1:]
            if index not in git_non_file_argument_indexes(arguments)
        ]
    elif words[0] == "status":
        references = words[1:]
    elif words[0] == "archive":
        archive_value_options = {
            "--format",
            "--prefix",
            "-o",
            "--output",
            "--remote",
            "--exec",
            "--add-file",
            "--add-virtual-file",
        }
        archive_words = subcommand_words(
            arguments, GIT_VALUE_OPTIONS | archive_value_options
        )
        references = archive_words[2:] if len(archive_words) > 2 else []
    else:
        return []

    return [
        reference
        for reference in references
        if not any(character in reference for character in "*?[")
        and not reference.startswith(":")
    ]


def git_file_ingress_references(arguments):
    """git が明示的な file option から読むパスを返す。"""
    references = option_values_with_joined(arguments, GIT_FILE_INPUT_OPTIONS)
    git_words = subcommand_words(
        arguments, GIT_VALUE_OPTIONS | {"-e", "--regexp", "-f", "--file"}
    )
    if git_words[:1] == ["grep"]:
        references.extend(option_values_with_joined(arguments, {"-f", "--file"}))
        references.extend(
            value
            for option, value, _indexes in docker_short_option_occurrences(
                arguments, {"-e", "-f"}, GREP_SHORT_BOOLEAN_FLAGS
            )
            if option == "-f"
        )
    # Git の parse-options も boolean shorthand と値付き shorthand を連結
    # できる。一方 `-F` は grep では fixed-strings なので、message file として
    # 読む command にだけ限定して cluster を解釈する。
    scoped_words = subcommand_words(
        arguments, GIT_VALUE_OPTIONS | GIT_FILE_INPUT_OPTIONS | {"--ref"}
    )
    short_cluster_inputs = (
        (
            ("commit",),
            {"-F", "-t"},
            GIT_VALUE_OPTIONS | {"-C", "-c", "-F", "-m", "-t", "-u"},
            {"a", "e", "i", "n", "o", "p", "q", "s", "v"},
        ),
        (
            ("tag",),
            {"-F"},
            GIT_VALUE_OPTIONS | {"-F", "-m", "-u"},
            {"a", "e", "f", "s"},
        ),
        (
            ("merge",),
            {"-F"},
            GIT_VALUE_OPTIONS | {"-F", "-m", "-s", "-X"},
            {"e", "n", "q", "v"},
        ),
        (
            ("notes", "add"),
            {"-F"},
            GIT_VALUE_OPTIONS | {"--ref", "-C", "-c", "-F", "-m"},
            {"e", "f"},
        ),
        (
            ("notes", "append"),
            {"-F"},
            GIT_VALUE_OPTIONS | {"--ref", "-C", "-c", "-F", "-m"},
            {"e"},
        ),
        (
            ("fmt-merge-msg",),
            {"-F"},
            GIT_VALUE_OPTIONS | {"-F", "-m"},
            set(),
        ),
    )
    for prefix, file_options, value_options, boolean_flags in short_cluster_inputs:
        if tuple(scoped_words[: len(prefix)]) != prefix:
            continue
        references.extend(
            value
            for option, value, _indexes in docker_short_option_occurrences(
                arguments, value_options, boolean_flags
            )
            if option in file_options
        )
    return references


def git_non_file_argument_indexes(arguments):
    """Git の検索pattern・format argv indexを返す。"""
    non_files = option_value_argument_indexes(
        arguments,
        {"--format", "--grep", "--pretty", "--word-diff-regex", "-G", "-S"},
    )
    indexes = positional_argument_indexes(
        arguments, GIT_VALUE_OPTIONS | {"-e", "--regexp", "-f", "--file"}
    )
    words = [arguments[index] for index in indexes]
    if words[:1] != ["grep"]:
        return non_files
    occurrences = docker_short_option_occurrences(
        arguments, {"-e", "-f"}, GREP_SHORT_BOOLEAN_FLAGS
    )
    non_files.update(option_value_argument_indexes(arguments, {"-e", "--regexp"}))
    for option, _value, occurrence_indexes in occurrences:
        if option == "-e":
            non_files.update(occurrence_indexes)
    has_pattern_option = bool(
        option_values_with_joined(arguments, {"-e", "--regexp", "-f", "--file"})
        or occurrences
    )
    if not has_pattern_option and len(indexes) > 1:
        non_files.add(indexes[1])
    return non_files


def command_file_ingress_references(command, arguments):
    if command == "gh":
        return gh_file_ingress_references(arguments)
    if command in {"terraform", "terragrunt"}:
        return terraform_file_ingress_references(arguments)
    if command == "git":
        return git_file_ingress_references(arguments)
    if command in {"grep", "egrep", "fgrep", "rg"}:
        return grep_file_ingress_references(command, arguments)
    if command in {"sed", "gsed"}:
        return sed_file_ingress_references(arguments)
    if command in {"awk", "gawk", "mawk", "nawk"}:
        return awk_file_ingress_references(arguments)
    if command in {"jq", "yq"}:
        return jq_file_ingress_references(command, arguments)
    if command == "curl":
        return curl_file_ingress_references(arguments)
    if command == "wget":
        return wget_file_ingress_references(arguments)
    if command == "openssl":
        return openssl_file_ingress_references(arguments)
    if command == "ssh-keygen":
        return ssh_keygen_file_ingress_references(arguments)
    if command == "tar":
        return tar_file_ingress_references(arguments)
    return []


def strip_release_track_prefixes(candidates):
    """`gcloud beta ...` のようなリリーストラック接頭辞を剥がした候補を足す。"""
    stripped = set(candidates)
    for words in candidates:
        while words and words[0] in RELEASE_TRACK_PREFIXES:
            words = words[1:]
            stripped.add(words)
    return stripped


def exact_local_help_invocation(arguments, protected_forms):
    """保護対象の完全なサブコマンドに help だけを付けた形かを見る。"""
    return bool(
        arguments
        and arguments[-1] in {"--help", "-h"}
        and tuple(arguments[:-1]) in protected_forms
    )


def secret_tool_help_invocation(command, arguments):
    """今回保護する secret 出力サブコマンドの完全なローカル help 形かを返す。"""
    if not arguments or arguments[-1] not in {"--help", "-h"}:
        return False
    words = tuple(arguments[:-1])

    entry = SECRET_TOOL_SUBCOMMANDS.get(command)
    if entry is not None:
        candidates = {words}
        stripped = words
        while stripped and stripped[0] in RELEASE_TRACK_PREFIXES:
            stripped = stripped[1:]
            candidates.add(stripped)
        return any(candidate in entry[1] for candidate in candidates)

    if command in {"ocm", "rosa"}:
        if words == ("token",):
            return True
        if command == "rosa" and words == ("create", "admin"):
            return True
        return (
            len(words) == 3
            and words[:2] == ("config", "get")
            and words[2].casefold() in ROSA_OCM_SECRET_CONFIG_NAMES
        )

    if command not in {"kubectl", "oc"}:
        return False
    if words in {
        ("create", "token"),
        ("config", "view", "--raw"),
        ("config", "view", "--raw=true"),
        ("whoami", "-t"),
        ("whoami", "-t=true"),
        ("whoami", "--show-token"),
        ("whoami", "--show-token=true"),
    }:
        return True
    if len(words) == 2 and words[0] in {"get", "extract"}:
        return words[1] in {"secret", "secrets"} or words[1].startswith(
            ("secret/", "secrets/")
        )
    if command == "kubectl":
        return False
    return words in {
        ("sa", "create-kubeconfig"),
        ("sa", "get-token"),
        ("sa", "new-token"),
        ("serviceaccounts", "create-kubeconfig"),
        ("serviceaccounts", "get-token"),
        ("serviceaccounts", "new-token"),
    }


def vault_login_hides_token(arguments):
    """vault login が token を表示せず helper へ保存する形かを見る。"""
    candidates = subcommand_word_candidates(
        arguments,
        SECRET_TOOL_SUBCOMMANDS["vault"][0] | {"-method", "-path"},
        1,
    )
    if not subcommand_candidates_match(candidates, ("login",)):
        return False

    no_print = False
    unsafe_boolean = False
    for argument in arguments:
        name, separator, value = argument.partition("=")
        enabled = not separator or value.strip().casefold() in BOOLEAN_TRUE_VALUES
        if name == "-no-print":
            no_print = enabled
        elif name in {"-no-store", "-token-only"}:
            unsafe_boolean = unsafe_boolean or enabled
        elif name in {"-field", "-format"}:
            return False
    return no_print and not unsafe_boolean


def secret_tool_invocation(command, arguments):
    """認証情報を出力するサブコマンドの呼び出しかどうかを判定する。"""
    if secret_tool_help_invocation(command, arguments):
        return False
    if command == "vault" and vault_login_hides_token(arguments):
        return False
    entry = SECRET_TOOL_SUBCOMMANDS.get(command)
    if entry is not None:
        value_options, subcommands = entry
        candidates = strip_release_track_prefixes(
            subcommand_word_candidates(arguments, value_options, 5)
        )
        return any(
            subcommand_candidates_match(candidates, expected)
            for expected in subcommands
        )

    if command in {"ocm", "rosa"}:
        candidates = subcommand_word_candidates(arguments, set(), 3)
        if subcommand_candidates_match(candidates, ("token",)):
            return True
        if command == "rosa" and subcommand_candidates_match(
            candidates, ("create", "admin")
        ):
            return True
        return any(
            len(words) > 2
            and words[:2] == ("config", "get")
            and words[2].casefold() in ROSA_OCM_SECRET_CONFIG_NAMES
            for words in candidates
        )

    if command not in {"kubectl", "oc"}:
        return False

    candidates = subcommand_word_candidates(arguments, KUBECTL_VALUE_OPTIONS, 3)
    for expected in KUBECTL_SECRET_SUBCOMMANDS:
        if subcommand_candidates_match(candidates, expected):
            return True
    # config view --raw は認証トークンを平文で出力する
    if subcommand_candidates_match(
        candidates, ("config", "view")
    ) and boolean_option_enabled(arguments, {"--raw"}):
        return True
    # get secret / get secrets / get secret/<name>。
    # secretproviderclass のような別リソースまで拾わないよう、前方一致にしない
    if any(
        len(words) > 1
        and words[0] == "get"
        and (
            words[1] in {"secret", "secrets"}
            or words[1].startswith(("secret/", "secrets/"))
        )
        for words in candidates
    ):
        return True

    if command != "oc":
        return False
    if subcommand_candidates_match(
        candidates, ("whoami",)
    ) and boolean_option_enabled(
        arguments, {"--show-token"}, short_flags={"t"}
    ):
        return True
    if any(
        len(words) > 1
        and words[0] == "extract"
        and (
            words[1] in {"secret", "secrets"}
            or words[1].startswith(("secret/", "secrets/"))
        )
        for words in candidates
    ):
        return True
    return any(
        words[:2]
        in {
            ("sa", "create-kubeconfig"),
            ("sa", "get-token"),
            ("sa", "new-token"),
            ("serviceaccounts", "create-kubeconfig"),
            ("serviceaccounts", "get-token"),
            ("serviceaccounts", "new-token"),
        }
        for words in candidates
    )


def oc_registry_login_exposes_auth_file(arguments, environment_names):
    """oc registry login が認証ファイルを任意パスへ書き出す形かを返す。"""
    candidates = subcommand_word_candidates(arguments, KUBECTL_VALUE_OPTIONS, 2)
    if not subcommand_candidates_match(candidates, ("registry", "login")):
        return False
    if "REGISTRY_AUTH_FILE" in environment_names:
        return True
    return any(
        argument in {"-a", "--registry-config", "--to"}
        or argument.startswith(("-a", "--registry-config=", "--to="))
        for argument in arguments
    )


def credential_tool_decision(command, arguments):
    """認証情報を扱うコマンドの判定を deny / ask / None で返す。

    サブコマンド単位で分け、秘密値を出さない参照操作 (ghtkn info など) は通す。
    """
    entry = CREDENTIAL_TOOL_SUBCOMMANDS.get(command)
    if entry is None:
        return None

    if command == "op" and arguments in (
        ["signin", "--help"],
        ["signin", "-h"],
    ):
        return None

    if (
        command == "uv"
        and len(arguments) == 3
        and arguments[:2]
        in (
            ["auth", "token"],
            ["auth", "helper"],
            ["auth", "login"],
            ["auth", "logout"],
        )
        and arguments[2] in {"--help", "-h"}
    ):
        return None

    value_options, denied, confirmed = entry
    if (
        arguments
        and arguments[-1] in {"--help", "-h"}
        and tuple(arguments[:-1]) in denied
    ):
        return None
    candidates = subcommand_word_candidates(arguments, value_options)
    for expected in denied:
        if subcommand_candidates_match(candidates, expected):
            return "deny"
    for expected in confirmed:
        if subcommand_candidates_match(candidates, expected):
            return "ask"
    return None


def security_export_only_reads_public_items(arguments):
    """export の実効 item type が certs / pubKeys と明示されたかを見る。"""
    try:
        index = arguments.index("export") + 1
    except ValueError:
        return False

    item_type = None
    value_options = {"-k", "-t", "-f", "-P", "-o"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return False
        if argument in value_options:
            if index + 1 >= len(arguments):
                return False
            if argument == "-t":
                item_type = arguments[index + 1]
            index += 2
            continue
        if argument.startswith("-") and argument != "-":
            option = argument[:2]
            if option in value_options and len(argument) > 2:
                if option == "-t":
                    item_type = argument[2:].lstrip("=")
                index += 1
                continue
            if set(argument[1:]) <= {"w", "p"}:
                index += 1
                continue
            return False
        return False
    return item_type is not None and item_type.casefold() in {"certs", "pubkeys"}


def security_public_export_output_indexes(arguments):
    """公開物だけを export する場合の出力先引数を返す。"""
    if not security_export_only_reads_public_items(arguments):
        return set()
    indexes = set()
    index = arguments.index("export") + 1
    while index < len(arguments):
        argument = arguments[index]
        if argument == "-o":
            indexes.add(index + 1)
            index += 2
            continue
        if argument.startswith("-o") and len(argument) > 2:
            indexes.add(index)
        index += 1
    return indexes


def security_decision(arguments):
    """security コマンドの判定を deny / ask / None で返す。

    `-p` はプロンプト文字列を値として取るため、消費してから位置引数を見る。
    対話モード (`-i`) とサブコマンドを伴わない呼び出しは、実行する内容を
    静的に決められない (標準入力から秘密値の出力を指示できる) ため拒否する。
    """
    if (
        len(arguments) == 2
        and not arguments[0].startswith("-")
        and arguments[1] in {"-h", "--help"}
    ):
        return None

    if any(
        argument.startswith("-")
        and not argument.startswith("--")
        and SECURITY_INTERACTIVE_FLAG in argument[1:]
        for argument in arguments
    ):
        return "deny"

    candidates = subcommand_word_candidates(
        arguments, SECURITY_VALUE_OPTIONS, 1, SECURITY_BOOLEAN_OPTIONS
    )
    if all(not words for words in candidates):
        # サブコマンドを伴わない security は、実行する内容を静的に決められない
        return "deny"

    subcommands = {words[0] for words in candidates}
    if subcommands & SECURITY_SECRET_SUBCOMMANDS:
        return "deny"
    if "export" in subcommands:
        return None if security_export_only_reads_public_items(arguments) else "deny"
    if subcommands & SECURITY_PASSWORD_SUBCOMMANDS and any(
        argument.startswith("-")
        and not argument.startswith("--")
        and SECURITY_PASSWORD_FLAGS & set(argument[1:])
        for argument in arguments
    ):
        return "deny"
    if subcommands <= SECURITY_SAFE_SUBCOMMANDS:
        return None
    return "ask"


def container_environment_specs(arguments):
    """-e / --env / --build-arg の名前と明示値を取り出す。"""
    specs = []
    values = option_values_with_joined(arguments, DOCKER_ENV_OPTIONS)
    values.extend(
        value
        for option, value, _indexes in docker_short_option_occurrences(
            arguments,
            DOCKER_EXEC_CHILD_VALUE_OPTIONS,
            DOCKER_EXEC_CHILD_SHORT_BOOLEAN_FLAGS,
        )
        if option == "-e"
    )
    for spec in values:
        name, separator, value = spec.partition("=")
        specs.append((name, value if separator else None))
    specs.extend(bake_environment_specs(arguments))
    return specs


def proxy_value_contains_credentials(value):
    """proxy の明示値に userinfo があるか、静的に確定できないかを返す。"""
    if path_contains_expansion(value):
        return True
    try:
        parsed = urlsplit(value if "://" in value else "//" + value)
    except ValueError:
        return True
    return parsed.username is not None or parsed.password is not None


def environment_name_holds_secret_value(name):
    """変数名がパスや agent socket ではなく秘密値そのものを表すか返す。"""
    if name in CREDENTIAL_PATH_PARAMETER_NAMES:
        return False
    if name in NON_SECRET_RUNTIME_PARAMETER_NAMES:
        return False
    return parameter_is_sensitive(name)


def environment_value_reveals_credential(name, value):
    """既知または未知の値が、認証情報を環境へ渡す形かを返す。"""
    if name in PROXY_PARAMETER_NAMES:
        return value is None or bool(value) and proxy_value_contains_credentials(value)
    if not environment_name_holds_secret_value(name):
        return False
    return value is None or bool(value)


def inherited_execution_environment():
    """危険な実行差し替え変数だけを、秘密値を保持せず継承する。"""
    inherited = {}
    for name in os.environ:
        if not (
            name in INHERITED_EXEC_ENV_NAMES
            or name.startswith(INHERITED_EXEC_ENV_PREFIXES)
            or name.casefold() in NPM_EXEC_ENV_NAMES
        ):
            continue
        if name == "SHELLOPTS":
            inherited[name] = ":".join(
                option
                for option in sorted(TRACKED_SHELL_OPTIONS)
                if option in os.environ[name].split(":")
            )
        else:
            inherited[name] = (
                INHERITED_NONEMPTY_MARKER if os.environ[name] else ""
            )
    return inherited


def printf_static_assignment_value(arguments):
    """printf -v の結果が単純な静的文字列なら返す。"""
    index = 0
    target_seen = False
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            index += 1
            break
        if argument == "-v":
            if index + 1 >= len(arguments):
                return None
            target_seen = True
            index += 2
            continue
        if argument.startswith("-v") and argument != "-v":
            target_seen = True
            index += 1
            continue
        if argument.startswith("-") and argument != "-":
            index += 1
            continue
        break
    if not target_seen or index >= len(arguments):
        return None
    format_string = arguments[index]
    if contains_expansion_or_marker(format_string):
        return None
    # %% 以外の変換指定があれば、後続引数を評価しないと結果を確定できない。
    if re.search(r"%(?:[^%]|$)", format_string):
        return None
    return format_string.replace("%%", "%")


def assignment_reveals_credential(assignment):
    """環境変数への代入が平文の認証情報をプロセスへ渡す形か返す。"""
    match = ASSIGNMENT_PARTS_RE.match(assignment)
    if not match:
        return False
    name, _subscript, _append, value = match.groups()
    return environment_value_reveals_credential(name, value)


def container_environment_spec_reveals_secret(name, value):
    """Docker の環境指定がホストの秘密値を渡す形かを返す。"""
    if value is None:
        # NAME だけならホストの同名変数を暗黙に継承する。
        return name_is_credential_variable(name) or name in PROXY_PARAMETER_NAMES

    if name in CREDENTIAL_PATH_PARAMETER_NAMES:
        # NAME=VALUE はコンテナ内のパスを設定するだけで、ホスト内容を渡さない。
        return False
    if name in PROXY_PARAMETER_NAMES:
        return proxy_value_contains_credentials(value)
    return name_is_credential_variable(name)


def parse_field_spec(value):
    """`id=x,src=y` 形式の値を、フィールドの辞書として取り出す。"""
    fields = {}
    for field in value.split(","):
        key, separator, field_value = field.partition("=")
        if separator:
            fields[key.strip()] = field_value
    return fields


def bake_overrides(arguments):
    """buildx bake の `--set TARGET.FIELD[.SUBKEY]=VALUE` を分解して返す。

    公式の指定は `targetpattern.key[.subkey]=value` で、`+=` による追加も取る。
    危険な種別かどうかはターゲット名の次の語 (key) だけで決まる。それ以降は
    その key のサブキー (`secret.<id>` の id など) なので、独立したフィールドと
    して扱うと `target.args.ssh` のような普通の build argument まで拒否してしまう。
    """
    overrides = []
    for value in file_option_values(arguments, DOCKER_BAKE_OPTIONS):
        target, separator, override = value.partition("=")
        if not separator:
            continue
        # `+=` の `+` と、配列指定 (secret[0] など) の添字を落とす
        parts = [
            part.strip().rstrip("+").split("[", 1)[0]
            for part in target.split(".")
        ]
        if len(parts) < 2:
            continue
        overrides.append((parts[1], parts[2:], override))
    return overrides


def bake_environment_specs(arguments):
    """bake の `--set TARGET.args.NAME[=VALUE]` を環境指定として返す。"""
    specs = []
    for setting in file_option_values(arguments, DOCKER_BAKE_OPTIONS):
        target, separator, value = setting.partition("=")
        parts = [
            part.strip().rstrip("+").split("[", 1)[0]
            for part in target.split(".")
        ]
        if len(parts) < 3 or parts[1] != "args" or not parts[2]:
            continue
        specs.append((parts[2], value if separator else None))
    return specs


def container_grants_filesystem_entitlement(arguments):
    """buildx の `--allow` でビルドコンテキスト外の読み書きを許すかを判定する。"""
    values = file_option_values(arguments, DOCKER_ALLOW_OPTIONS)
    values.extend(
        override
        for field, _subkeys, override in bake_overrides(arguments)
        if field == "entitlements"
    )
    for value in values:
        for entitlement in value.split(","):
            if entitlement.split("=", 1)[0].strip() in DOCKER_RISKY_ENTITLEMENTS:
                return True
    return False


def container_secret_fields(arguments):
    """秘密の指定を、フィールドの辞書として取り出す。

    `--secret` に加えて、buildx bake の `--set TARGET.secret=...` も見る。
    """
    entries = [
        parse_field_spec(value)
        for value in file_option_values(arguments, {"--secret"})
    ]
    for field, _subkeys, override in bake_overrides(arguments):
        if field in DOCKER_BAKE_SECRET_FIELDS:
            entries.append(parse_field_spec(override))
    return entries


def container_uses_host_environment_secret(arguments):
    """`--secret` がホストの環境変数から秘密を取る形かどうかを判定する。

    `type=env` では `env=` / `src=` / `source=` / `id=` が環境変数名を指す。
    type の省略時も、`env=NAME` と path 指定を伴わない `id=NAME` はホストの
    同名環境変数を読む。いずれも変数名の見た目によらず拒否する。
    """
    for fields in container_secret_fields(arguments):
        if fields.get("type", "").casefold() == "env":
            return True
        if DOCKER_SECRET_ENV_FIELDS & fields.keys():
            return True
        if not DOCKER_SECRET_PATH_FIELDS & fields.keys() and (
            DOCKER_SECRET_ID_FIELDS & fields.keys()
        ):
            return True
    return False


def container_uses_host_file_secret(arguments):
    """`--secret src/source/file=` がホストのファイルを渡す形かを返す。"""
    return any(
        fields.get("type", "").casefold() != "env"
        and bool(DOCKER_SECRET_PATH_FIELDS & fields.keys())
        for fields in container_secret_fields(arguments)
    )


def container_forwards_ssh_agent(arguments):
    """SSH agent の socket や秘密鍵をビルドへ渡す指定かどうかを判定する。

    `--ssh` に加えて、buildx bake の `--set TARGET.ssh=...` も同じ意味を持つ。
    """
    if file_option_values(arguments, DOCKER_SSH_OPTIONS):
        return True
    return any(
        field in DOCKER_BAKE_SSH_FIELDS
        for field, _subkeys, _override in bake_overrides(arguments)
    )


def container_exposes_api_socket(arguments):
    """コンテナから Docker API へ到達できる指定かどうかを判定する。"""
    return boolean_option_enabled(arguments, DOCKER_API_SOCKET_OPTIONS)


def reference_is_socket(source):
    """コンテナへ渡す対象がホストの socket かどうかを判定する。

    拡張子だけでは macOS の launchd socket (`.../Listeners`) を拾えないため、
    よく使う socket の置き場も名前で見る。
    """
    folded = source.casefold()
    if os.path.basename(source.rstrip("/")).casefold().endswith(SOCKET_PATH_SUFFIX):
        return True
    return any(marker in folded for marker in SOCKET_PATH_MARKERS)


def name_is_credential_variable(name):
    """変数名だけで認証情報とみなすかを判定する。

    コンテナへ明示的に渡す指定は「秘密を渡すこと」が目的になりやすいため、
    シェル変数の展開より広く、部分一致と既知の機密変数名の両方で見る。
    """
    upper = name.upper()
    if upper in SENSITIVE_PARAMETER_NAMES or upper in CREDENTIAL_PATH_PARAMETER_NAMES:
        return True
    return any(marker in upper for marker in CREDENTIAL_ENV_MARKERS)


def docker_cp_operand_is_container_path(operand):
    """docker cp の operand が CONTAINER:PATH 形式かを返す。"""
    expanded = expand_home(operand)
    if os.path.isabs(expanded) or operand.startswith(("./", "../", "~")):
        return False
    return ":" in operand


def container_command_input_references(arguments):
    """Docker の各サブコマンドが直接読むホスト側 file / directory を返す。"""
    words = subcommand_words(arguments, DOCKER_VALUE_OPTIONS)
    if words[:1] == ["compose"]:
        words = subcommand_words(
            arguments, DOCKER_VALUE_OPTIONS | DOCKER_COMPOSE_VALUE_OPTIONS
        )
    files = []
    directories = []

    option_inputs = (
        (("load",), {"-i", "--input"}),
        (("image", "load"), {"-i", "--input"}),
        (("compose",), {"-f", "--file", "--project-directory"}),
        (("compose", "run"), {"--env-from-file"}),
        (("buildx", "bake"), {"-f", "--file"}),
        (("buildx", "create"), {"--buildkitd-config"}),
        (("buildx", "imagetools", "create"), {"-f", "--file"}),
        (("buildx", "history", "import"), {"-f", "--file"}),
        (("stack", "deploy"), {"-c", "--compose-file"}),
        (("stack", "config"), {"-c", "--compose-file"}),
        (("trust", "signer", "add"), {"--key"}),
        (("swarm", "ca"), {"--ca-cert", "--ca-key"}),
    )
    for prefix, options in option_inputs:
        if tuple(words[: len(prefix)]) != prefix:
            continue
        values = option_values_with_joined(arguments, options)
        if prefix in {("stack", "deploy"), ("stack", "config")}:
            values = [part for value in values for part in value.split(",")]
        files.extend(values)
        if prefix == ("compose",):
            directories.extend(
                option_values_with_joined(arguments, {"--project-directory"})
            )

    is_build_command = any(
        tuple(words[: len(prefix)]) == prefix
        for prefix in DOCKER_BUILD_SUBCOMMANDS
    )
    if is_build_command:
        files.extend(option_values_with_joined(arguments, {"-f", "--file"}))

    short_cluster_inputs = (
        (
            (("load",), ("image", "load")),
            {"-i"},
            DOCKER_VALUE_OPTIONS | {"-i", "--input"},
            {"D", "q"},
        ),
        (
            DOCKER_BUILD_SUBCOMMANDS,
            {"-f"},
            DOCKER_VALUE_OPTIONS | DOCKER_BUILD_VALUE_OPTIONS,
            DOCKER_BUILD_SHORT_BOOLEAN_FLAGS,
        ),
        (
            (("stack", "deploy"),),
            {"-c"},
            DOCKER_VALUE_OPTIONS | {"-c", "--compose-file"},
            {"D", "d", "q"},
        ),
        (
            (("buildx", "bake"),),
            {"-f"},
            DOCKER_VALUE_OPTIONS | {"-c", "-f", "-l", "--file"},
            {"D"},
        ),
        (
            (("buildx", "imagetools", "create"),),
            {"-f"},
            DOCKER_VALUE_OPTIONS | {"-c", "-f", "-l", "-t", "--file"},
            {"D"},
        ),
        (
            (("buildx", "history", "import"),),
            {"-f"},
            DOCKER_VALUE_OPTIONS | {"-c", "-f", "-l", "--file"},
            {"D"},
        ),
    )
    for prefixes, file_options, value_options, boolean_flags in short_cluster_inputs:
        if not any(
            tuple(words[: len(prefix)]) == prefix for prefix in prefixes
        ):
            continue
        files.extend(
            value
            for option, value, _indexes in docker_short_option_occurrences(
                arguments, value_options, boolean_flags
            )
            if option in file_options
        )

    if tuple(words[:2]) == ("buildx", "bake") or is_build_command:
        for value in option_values_with_joined(arguments, {"--policy"}):
            policy_files = []
            for field in value.split(","):
                key, separator, field_value = field.partition("=")
                if separator and key.strip() == "filename":
                    policy_files.append(field_value)
            files.extend(policy_files or [value])

    if tuple(words[:2]) in {("context", "create"), ("context", "update")}:
        for value in option_values_with_joined(arguments, {"--docker"}):
            fields = parse_field_spec(value)
            files.extend(
                fields[key] for key in ("ca", "cert", "key") if key in fields
            )

    positional_inputs = (
        (("import",), 0, {"-c", "--change", "-m", "--message", "--platform"}),
        (
            ("image", "import"),
            0,
            {"-c", "--change", "-m", "--message", "--platform"},
        ),
        (("secret", "create"), 1, {"-d", "--driver", "-l", "--label"}),
        (("config", "create"), 1, {"-l", "--label", "--template-driver"}),
        (("context", "import"), 1, set()),
        (("plugin", "create"), 1, set()),
        (("trust", "key", "load"), 0, {"--name"}),
    )
    for prefix, operand_index, value_options in positional_inputs:
        command_words = subcommand_words(
            arguments, DOCKER_VALUE_OPTIONS | value_options
        )
        if tuple(command_words[: len(prefix)]) != prefix:
            continue
        operands = command_words[len(prefix) :]
        if operand_index >= len(operands):
            continue
        reference = operands[operand_index]
        files.append(reference)
        if prefix == ("plugin", "create"):
            directories.append(reference)

    return files, directories


def container_host_references(arguments, words, build_words, cp_words):
    """コンテナへホスト側の内容を渡す指定から、対象のパスを取り出す。

    ボリューム、`--env-file` などのファイル指定、`--secret src=` のような
    キー付きの値、ビルドコンテキストの位置引数をまとめて返す。
    """
    references = list(bind_mount_sources(arguments))
    command_files, _command_directories = container_command_input_references(
        arguments
    )
    references.extend(command_files)
    for value in file_option_values(arguments, DOCKER_FILE_OPTIONS - {"--secret"}):
        for field in value.split(","):
            key, separator, field_value = field.partition("=")
            if not separator:
                references.append(key)
            elif key.strip() not in DOCKER_SECRET_ENV_FIELDS:
                # env= はパスではなく環境変数名なので container_environment_names で見る
                references.append(field_value)

    for field, _subkeys, override in bake_overrides(arguments):
        if field in DOCKER_BAKE_PATH_FIELDS:
            references.append(override)

    # `--secret src=` と、bake の `--set TARGET.secret.<id>=src=` の指す
    # ホスト側のパス。ここへ入れないと認証情報パスの検査に掛からない
    for fields in container_secret_fields(arguments):
        if fields.get("type", "").casefold() == "env":
            continue
        for key in DOCKER_SECRET_PATH_FIELDS:
            if key in fields:
                references.append(fields[key])

    for expected in DOCKER_BUILD_SUBCOMMANDS:
        if tuple(build_words[: len(expected)]) == expected:
            operands = build_words[len(expected) :]
            if operands:
                references.append(operands[-1])
            break

    # docker cp はホストとコンテナの間でパスを直接やり取りする
    for expected in DOCKER_COPY_SUBCOMMANDS:
        if tuple(cp_words[: len(expected)]) == expected:
            operands = cp_words[len(expected) :]
            if len(operands) >= 2:
                source, destination = operands[-2:]
                # ホストからコンテナへ渡すコピー元だけを検査する。
                if not docker_cp_operand_is_container_path(
                    source
                ) and docker_cp_operand_is_container_path(destination):
                    references.append(source)
            break
    return references


def container_directory_ingress_references(
    arguments, words, build_words, cp_words
):
    """ホストのディレクトリをコンテナ側へ渡す可能性がある参照を返す。"""
    references = []

    references.extend(bind_mount_sources(arguments))
    _command_files, command_directories = container_command_input_references(
        arguments
    )
    references.extend(command_directories)

    # build / buildx build / image build の位置引数。未知オプションの値が混ざっても、
    # 実在するローカルディレクトリだけを後段で走査する。
    for expected in DOCKER_BUILD_SUBCOMMANDS:
        if tuple(build_words[: len(expected)]) == expected:
            operands = build_words[len(expected) :]
            if operands:
                references.append(operands[-1])
            break

    # 追加 build context は NAME=PATH の右辺がホスト側の参照になる。
    for value in file_option_values(arguments, {"--build-context"}):
        _name, separator, context = value.partition("=")
        references.append(context if separator else value)

    for field, _subkeys, override in bake_overrides(arguments):
        if field in {"context", "contexts"}:
            references.append(override)

    # cp は host -> container のコピー元だけが ingress になる。
    for expected in DOCKER_COPY_SUBCOMMANDS:
        if tuple(cp_words[: len(expected)]) == expected:
            operands = cp_words[len(expected) :]
            if len(operands) >= 2:
                source, destination = operands[-2:]
                if not docker_cp_operand_is_container_path(
                    source
                ) and docker_cp_operand_is_container_path(destination):
                    references.append(source)
            break
    return references


def directory_ingress_references_credentials(reference):
    """ローカル ingress の配下に既知の認証情報名があるかを名前だけで調べる。"""
    if not reference or reference == "-" or "://" in reference:
        return False
    if path_contains_expansion(reference):
        # 実行時に決まる通常の context は一律に止めず、EDR の残余境界とする。
        return False

    resolved = resolve_against_working_directory(expand_home(reference))
    if not os.path.lexists(resolved):
        return False
    if path_contains_credential_component(resolved):
        return True
    if path_ends_with_credential_directory(resolved):
        return True
    if not os.path.isdir(resolved):
        return False

    def raise_walk_error(error):
        raise error

    try:
        for current, directories, files in os.walk(
            resolved, followlinks=False, onerror=raise_walk_error
        ):
            for name in directories + files:
                candidate = os.path.join(current, name)
                relative = os.path.relpath(candidate, resolved)
                folded_name = name.casefold()
                if (
                    basename_is_credential(folded_name)
                    or path_contains_credential_component(candidate)
                    or path_holds_credential_directory(relative)
                    or path_ends_with_credential_directory(relative)
                    or path_contains_credential_component(relative)
                    or path_contains_credential_fragment(relative)
                    or (
                        os.path.islink(candidate)
                        and argument_is_credential_path(candidate)
                    )
                ):
                    return True
    except OSError:
        # Docker に渡す範囲を確認できない場合は内容を送らせない。
        return True
    return False


def container_reveals_secret(words, arguments):
    """明示的に環境値や build command を返す container 参照を判定する。"""
    words = tuple(words)
    if container_ps_reveals_process_arguments(words, arguments):
        return True
    if container_top_reveals_process_arguments(words, arguments):
        return True
    if words[:2] in {("pass", "get"), ("pass", "run")}:
        # Docker Secrets Engine が se:// 参照を解決し、平文を host child の
        # 環境変数へ渡すか、keystore の秘密値を返す。
        # 秘密を出さない完全な help 形だけは通す。
        return arguments[-1:] not in (["-h"], ["--help"])
    templates = option_values_with_joined(arguments, {"-f", "--format"})
    safe_format = bool(templates) and all(
        container_format_is_safe(template) for template in templates
    )
    inspect_commands = (
        ("inspect",),
        ("container", "inspect"),
        ("image", "inspect"),
        ("service", "inspect"),
    )
    info_commands = (("info",), ("system", "info"))
    local_help_commands = inspect_commands + (
        ("history",),
        ("image", "history"),
        ("compose", "config"),
        ("compose", "convert"),
        ("stack", "config"),
        ("top",),
        ("container", "top"),
        ("compose", "top"),
        ("context", "export"),
        *info_commands,
    )
    if arguments[-1:] in (["--help"], ["-h"]) and words in local_help_commands:
        return False
    if any(words[: len(command)] == command for command in inspect_commands):
        return not safe_format
    if any(words[: len(command)] == command for command in info_commands):
        return not safe_format
    if words[:2] == ("context", "export"):
        return True
    if words[:1] == ("history",) or words[:2] == ("image", "history"):
        return not safe_format
    if words[:2] == ("stack", "config"):
        return True
    if words[:2] not in {("compose", "config"), ("compose", "convert")}:
        return False
    if boolean_option_enabled(arguments, {"--environment"}):
        return True
    safe_summary = boolean_option_enabled(
        arguments,
        CONTAINER_COMPOSE_CONFIG_SAFE_OPTIONS - {"--hash"},
        short_flags={"q"},
    ) or any(
        argument == "--hash" or argument.startswith("--hash=")
        for argument in arguments
    )
    return not safe_summary


def container_ps_reveals_process_arguments(words, arguments):
    """ps の完全な command/args 列を出す指定を判定する。"""
    commands = (("ps",), ("container", "ls"), ("compose", "ps"))
    if not any(words[: len(command)] == command for command in commands):
        return False
    if arguments[-1:] in (["--help"], ["-h"]):
        return False
    templates = option_values_with_joined(arguments, {"--format"})
    if templates:
        if any(not container_ps_format_is_safe(template) for template in templates):
            return True
        return boolean_option_enabled(arguments, {"--no-trunc"}) and any(
            container_ps_format_is_default(template) for template in templates
        )
    return boolean_option_enabled(arguments, {"--no-trunc"})


def container_top_reveals_process_arguments(words, arguments):
    """top の既定出力または危険な ps 列指定を判定する。"""
    if words[:2] == ("compose", "top"):
        return arguments[-1:] not in (["--help"], ["-h"])
    if words[:1] == ("top",):
        operand_position = 1
    elif words[:2] == ("container", "top"):
        operand_position = 2
    else:
        return False
    if arguments[-1:] in (["--help"], ["-h"]):
        return False
    indexes = positional_argument_indexes(arguments, DOCKER_VALUE_OPTIONS)
    if len(indexes) <= operand_position:
        return True
    ps_arguments = arguments[indexes[operand_position] + 1 :]
    return process_inspection_reveals_credentials("ps", ps_arguments)


def container_debug_option_values(arguments, options):
    """docker debug 固有の値付き option を取り出す。"""
    value_options = DOCKER_VALUE_OPTIONS | {
        "-c",
        "--command",
        "-l",
        "--host",
        "--shell",
        "--tool",
    }
    return pflag_option_values(arguments, options, value_options, {"D"})


def scanner_reveals_secret(scanner):
    """container child の出力へ認証情報を載せる拒否理由があるかを見る。"""
    secret_reasons = {
        AWS_CONFIGURE_SECRET_REASON,
        AWS_EXPORT_REASON,
        CREDENTIAL_FILE_REASON,
        CREDENTIAL_TOOL_REASON,
        CREDENTIAL_VARIABLE_REASON,
        DOCKER_OUTPUT_REASON,
        ENV_DUMP_REASON,
        GH_API_SECRET_REASON,
        GH_TOKEN_REASON,
        KEYCHAIN_SECRET_REASON,
        PROCESS_INSPECTION_REASON,
        SECRET_TOOL_REASON,
        SHELL_HISTORY_REASON,
    }
    return bool(secret_reasons & set(scanner.reasons))


def container_debug_reveals_secret(arguments):
    """docker debug --command が認証情報を表示する形を判定する。"""
    words = subcommand_words(
        arguments,
        DOCKER_VALUE_OPTIONS
        | {"-c", "--command", "-l", "--host", "--shell", "--tool"},
    )
    if words[:1] != ["debug"]:
        return False
    for command in container_debug_option_values(
        arguments, {"-c", "--command"}
    ):
        scanner = CommandScanner()
        scanner.scan(command)
        if scanner_reveals_secret(scanner):
            return True
    return False


def container_child_reveals_secret(arguments):
    """docker exec 等の直接 child が認証情報を出力する形かを判定する。"""
    for operand in container_child_operand_candidates(arguments):
        outer_arguments = arguments[:operand]
        outer_words = subcommand_words(
            outer_arguments,
            DOCKER_VALUE_OPTIONS
            | DOCKER_COMPOSE_VALUE_OPTIONS
            | DOCKER_EXEC_CHILD_VALUE_OPTIONS,
        )
        if outer_words[:1] == ["create"] or outer_words[:2] in (
            ["container", "create"],
            ["service", "create"],
        ):
            continue
        if boolean_option_enabled(
            outer_arguments, {"--detach"}, short_flags={"d"}
        ):
            continue
        child = arguments[operand + 1 :]
        entrypoints = option_values_with_joined(
            arguments[:operand], {"--entrypoint"}
        )
        entrypoint = entrypoints[-1] if entrypoints else ""
        candidates = [[entrypoint, *child]] if entrypoint else ([child] if child else [])
        for candidate in candidates:
            scanner = CommandScanner()
            scanner.inspect_argv(candidate, 0)
            if scanner_reveals_secret(scanner):
                return True
    return False


def container_child_operand_candidates(arguments):
    """run / create / exec の image・container・service operand候補を返す。"""
    indexes = positional_argument_indexes(
        arguments,
        DOCKER_VALUE_OPTIONS,
    )
    words = [arguments[index] for index in indexes]
    if words[:1] == ["compose"]:
        indexes = positional_argument_indexes(
            arguments,
            DOCKER_VALUE_OPTIONS | DOCKER_COMPOSE_VALUE_OPTIONS,
        )
        words = [arguments[index] for index in indexes]
    if words[:1] in (["create"], ["exec"], ["run"]) and len(words) >= 2:
        start = indexes[0] + 1
    elif words[:2] in (
        ["container", "create"],
        ["container", "exec"],
        ["container", "run"],
        ["service", "create"],
    ) and len(words) >= 3:
        start = indexes[1] + 1
    elif words[:2] in (["compose", "exec"], ["compose", "run"]) and len(words) >= 3:
        start = indexes[1] + 1
    else:
        return set()

    value_options = DOCKER_EXEC_CHILD_VALUE_OPTIONS
    pending = {start}
    visited = set()
    candidates = set()
    while pending:
        index = pending.pop()
        if index in visited or index >= len(arguments):
            continue
        visited.add(index)
        argument = arguments[index]
        if argument == "--":
            if index + 1 < len(arguments):
                candidates.add(index + 1)
            continue
        if argument.startswith("-") and argument != "-":
            option = argument.split("=", 1)[0]
            clustered = docker_short_option_cluster(
                argument,
                value_options,
                DOCKER_EXEC_CHILD_SHORT_BOOLEAN_FLAGS,
            )
            if clustered is not None:
                clustered_option, joined = clustered
                pending.add(
                    index + 1
                    if not clustered_option or joined is not None
                    else index + 2
                )
            elif "=" in argument:
                pending.add(index + 1)
            elif option in value_options:
                pending.add(index + 2)
            elif option in DOCKER_EXEC_CHILD_BOOLEAN_OPTIONS or (
                not argument.startswith("--")
                and len(argument) > 2
                and all(
                    flag in DOCKER_EXEC_CHILD_SHORT_BOOLEAN_FLAGS
                    for flag in argument[1:]
                )
            ):
                pending.add(index + 1)
            continue
        candidates.add(index)
    return candidates


def container_option_arguments(arguments):
    """Docker 自身が解釈する範囲を child argv より前に限定する。"""
    candidates = container_child_operand_candidates(arguments)
    return arguments if not candidates else arguments[: max(candidates)]


def file_option_values(arguments, options):
    """`--opt VALUE` と `--opt=VALUE` の両形式から値を取り出す。"""
    values = []
    pending = False
    for argument in arguments:
        if pending:
            values.append(argument)
            pending = False
            continue
        if argument in options:
            pending = True
            continue
        if "=" in argument and argument.split("=", 1)[0] in options:
            values.append(argument.split("=", 1)[1])
    return values


def git_injects_command(arguments, assignments):
    """git へ外部コマンドを仕込む指定が含まれるかを判定する。

    `-c <key>=<command>` と、同じ効果を持つ環境変数の前置代入の両方を見る。
    キーの比較は git と同じく大文字小文字を区別しない。
    """
    # 環境変数名は大文字小文字を区別する。`pager=cat git status` の `pager` は
    # git に何の影響も与えないため、正確な大文字名だけを照合する
    for name in assignments:
        if name in GIT_EXEC_ENV_VARS or name.startswith(GIT_EXEC_ENV_PREFIXES):
            return True

    pending = False
    for argument in arguments:
        if pending:
            pending = False
            if config_key_injects_command(argument):
                return True
            continue
        # clone / submodule は --config も同じ効果を持つ
        if argument in {"-c", "--config"}:
            pending = True
            continue
        # -c<key>=<value> / --config=<key>=<value> の連結形式
        for prefix in ("-c", "--config=", "--config-env="):
            if argument.startswith(prefix) and len(argument) > len(prefix):
                if config_key_injects_command(argument[len(prefix) :]):
                    return True
    return False


def config_key_injects_command(setting):
    """`<key>=<value>` の key が、外部コマンドや別設定ファイルを持ち込むかを返す。

    include.path / includeIf.*.path は、読み込ませた先で alias や
    credential.helper、core.hooksPath を定義できるため同じ扱いにする。
    """
    key = setting.split("=", 1)[0].strip().casefold()
    if key in GIT_EXEC_CONFIG_KEYS or key.startswith("alias."):
        return True
    if key.startswith(GIT_INCLUDE_CONFIG_PREFIXES):
        return True
    # `credential.https://example.com.helper` のように、途中に URL が入る形。
    # 完全一致では拾えないため、先頭と末尾の組で照合する
    return any(
        key.startswith(prefix) and key.rsplit(".", 1)[-1] == leaf
        for prefix, leaf in GIT_EXEC_CONFIG_KEY_SHAPES
    )


def git_needs_confirmation(candidates, arguments):
    """取り消しにくい、またはフックを迂回する git 操作かどうかを判定する。

    `git push origin main --force` のようにオプションが後ろに来ても効くよう、
    サブコマンドとオプションを別々に見る。
    """
    long_options = {
        argument.split("=", 1)[0] for argument in arguments if argument.startswith("--")
    }
    short_flags = set()
    for argument in arguments:
        if (
            argument.startswith("-")
            and not argument.startswith("--")
            and argument != "-"
        ):
            short_flags.update(argument[1:].split("=", 1)[0])

    for expected in GIT_CONFIRM_SUBCOMMANDS:
        if subcommand_candidates_match(candidates, expected):
            return True

    for words in candidates:
        if not words:
            continue
        # `git checkout -- <path>` は作業ツリーの変更を捨てる
        if words[0] == "checkout" and "--" in arguments:
            return True
        # index だけを戻す `git restore --staged` は作業ツリーを壊さない
        if (
            words[0] == "restore"
            and ("--staged" in long_options or "S" in short_flags)
            and "--worktree" not in long_options
            and "W" not in short_flags
        ):
            continue
        entry = GIT_CONFIRM_OPTIONS.get(words[0])
        if entry is None:
            continue
        expected_long, expected_short = entry
        if not expected_long and not expected_short:
            return True
        if long_options & expected_long or short_flags & expected_short:
            return True
    return False


def strip_terraform_wrappers(candidates):
    """terragrunt の wrapper (`run --all` など) を剥がした候補を足して返す。

    wrapper を剥がした形も候補に含めることで、`terragrunt run --all destroy` を
    `destroy` と同じ判断にできる。
    """
    stripped = set(candidates)
    for words in candidates:
        while words and words[0] in TERRAFORM_WRAPPER_SUBCOMMANDS:
            words = words[1:]
            stripped.add(words)
    return stripped


def gh_writes_through_api(candidates, arguments):
    """`gh api` が外部の状態を変える呼び出しかどうかを判定する。

    `-X DELETE` のような明示指定と、フィールド指定による暗黙の POST を見る。
    """
    if not subcommand_candidates_match(candidates, ("api",)):
        return False

    methods = gh_api_option_values(arguments, {"-X", "--method"})
    if methods:
        method = methods[-1]
        if contains_expansion_or_marker(method):
            # 実行時に決まる method は書き込みかどうか分からない
            return True
        if method.strip().upper() in GH_API_WRITE_METHODS:
            return True
        # GET / HEAD を明示した呼び出しは、フィールド指定があっても照会になる
        return False

    return bool(gh_api_option_values(arguments, GH_API_WRITE_OPTIONS)) or any(
        argument.split("=", 1)[0] in GH_API_WRITE_OPTIONS
        or (
            argument.startswith("-")
            and not argument.startswith("--")
            and len(argument) > 2
            and argument[:2] in GH_API_WRITE_OPTIONS
        )
        for argument in arguments
    )


def option_values_with_joined(arguments, options):
    """`-X VALUE`、`--method=VALUE`、`-XVALUE` の 3 形式から値を取り出す。"""
    values = list(file_option_values(arguments, options))
    short_options = {
        option
        for option in options
        if option.startswith("-") and not option.startswith("--") and len(option) == 2
    }
    for argument in arguments:
        for option in short_options:
            if argument.startswith(option) and len(argument) > len(option):
                values.append(argument[len(option) :])
    return values


def pflag_option_values(arguments, targets, value_options, boolean_flags):
    """pflag の値付き option を元の argv 順で一度ずつ取り出す。"""
    targets = set(targets)
    values = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            break
        if argument.startswith("--"):
            option, separator, joined = argument.partition("=")
            if option not in value_options:
                index += 1
                continue
            if separator:
                if option in targets:
                    values.append(joined)
                index += 1
                continue
            if index + 1 < len(arguments):
                if option in targets:
                    values.append(arguments[index + 1])
                index += 2
            else:
                index += 1
            continue
        if argument.startswith("-") and argument != "-":
            parsed = docker_short_option_cluster(
                argument, value_options, boolean_flags
            )
            if parsed is None:
                index += 1
                continue
            option, joined = parsed
            if not option:
                index += 1
                continue
            if joined is not None:
                if option in targets:
                    values.append(joined)
                index += 1
                continue
            if index + 1 < len(arguments):
                if option in targets:
                    values.append(arguments[index + 1])
                index += 2
            else:
                index += 1
            continue
        index += 1
    return values


def gh_api_option_values(arguments, options):
    """gh api の boolean shorthand に隠れた option も取り出す。"""
    api_value_options = {
        "-F",
        "--field",
        "-H",
        "--header",
        "--hostname",
        "--input",
        "-p",
        "--preview",
        "-q",
        "--jq",
        "-f",
        "--raw-field",
        "-t",
        "--template",
        "-X",
        "--method",
        "--cache",
    }
    return pflag_option_values(arguments, options, api_value_options, {"i"})


def normalized_gh_api_request(candidates, arguments):
    """静的な `gh api` 呼び出しの method と endpoint path を返す。"""
    methods = gh_api_option_values(arguments, {"-X", "--method"})
    if methods and contains_expansion_or_marker(methods[-1]):
        return None, set()
    if methods:
        method = methods[-1].strip().upper()
    elif gh_api_option_values(arguments, GH_API_WRITE_OPTIONS) or any(
        argument.split("=", 1)[0] in GH_API_WRITE_OPTIONS
        or (
            argument.startswith("-")
            and not argument.startswith("--")
            and len(argument) > 2
            and argument[:2] in GH_API_WRITE_OPTIONS
        )
        for argument in arguments
    ):
        method = "POST"
    else:
        method = "GET"

    endpoints = set()
    for words in candidates:
        if len(words) < 2 or words[0] != "api":
            continue
        endpoint = words[1]
        if contains_expansion_or_marker(endpoint):
            continue
        parsed = urlsplit(
            endpoint
            if "://" in endpoint
            else "https://api.github.com/" + endpoint.lstrip("/")
        )
        path = unquote(parsed.path).replace("\\", "/")
        path = "/" + "/".join(part for part in path.split("/") if part)
        endpoints.add(normpath(path).casefold())
    return method, endpoints


def gh_api_reveals_secret(candidates, arguments):
    """静的な POST が一時 credential を返す GitHub endpoint かを判定する。"""
    if not subcommand_candidates_match(candidates, ("api",)):
        return False
    method, endpoints = normalized_gh_api_request(candidates, arguments)
    if method != "POST":
        return False
    return any(
        pattern.match(endpoint)
        for endpoint in endpoints
        for pattern in GH_API_SECRET_ENDPOINTS
    )


def contains_expansion_or_marker(value):
    """値が実行時に決まる (展開の結果である) かどうかを判定する。"""
    return path_contains_expansion(value)


def gh_changes_external_state(arguments):
    """gh の呼び出しが読み取りだけで済まないかどうかを判定する。

    状態を変える操作を列挙し切るのは無理なので、読み取りと分かる形を
    allowlist にして、そこから漏れたものを確認へ回す。
    下位動詞を持つ操作は語数まで一致させる (前方一致だけだと
    `gh codespace ports visibility 3000:public` を読み取りと誤認する)。
    """
    words = tuple(subcommand_words(arguments, GH_VALUE_OPTIONS))
    # `gh` 単体や `gh pr` のような名詞だけの呼び出しはヘルプ表示
    if len(words) <= 1:
        return False
    if any(words[: len(expected)] == expected for expected in GH_READONLY_PREFIXES):
        return False
    if words in GH_READONLY_EXACT:
        return False
    return words[1] not in GH_READONLY_VERBS


def git_push_needs_confirmation(arguments):
    """`git push` が remote の ref を強制更新・削除する形かどうかを判定する。

    先頭の `+` は非早送りの上書き、`:<ref>` は remote の ref 削除、
    `--mirror` と `--prune` は remote 側の ref をまとめて消す。
    refspec は位置が一定しない (`--repo` で remote を指定できる) ため、
    `push` 以降の位置引数をすべて見る。remote 名は `+` や `:` で始まらない。
    """
    words = subcommand_words(arguments, GIT_VALUE_OPTIONS | GIT_PUSH_VALUE_OPTIONS)
    if words[:1] != ["push"]:
        return False
    if {argument.split("=", 1)[0] for argument in arguments} & GIT_PUSH_CONFIRM_OPTIONS:
        return True
    for refspec in words[1:]:
        if refspec.startswith("+"):
            return True
        # `:` 単独は matching push であって削除ではない
        if refspec.startswith(":") and len(refspec) > 1:
            return True
        if path_contains_expansion(refspec):
            # 実行時に決まる refspec は、強制更新や削除か判断できない
            return True
    return False


def git_config_needs_confirmation(arguments):
    """`git -c` で remote の push 動作を上書きしているかを判定する。"""
    for setting in git_config_settings(arguments):
        key = setting.split("=", 1)[0].strip().casefold()
        if key.startswith("remote.") and key.rsplit(".", 1)[-1] in {
            "push",
            "mirror",
            "receivepack",
        }:
            return True
    return False


def git_config_written_keys(arguments):
    """`git config` が設定ファイルへ書き込む形なら、対象のキーを返す。

    書き込みは `-c` の一時指定と違って設定ファイルへ残るため、
    後続の `git` からも効いてしまう。
    読み取りと明示された形 (`--get` / `--list` / `config get` / `config list`)
    以外は書き込みとみなす。戻り値は (書き込みか, キーの一覧)。
    """
    words = subcommand_words(arguments, GIT_VALUE_OPTIONS | GIT_CONFIG_VALUE_OPTIONS)
    if words[:1] != ["config"]:
        return False, []
    operands = words[1:]
    options = {argument.split("=", 1)[0] for argument in arguments}

    # 値付きオプションの一覧に漏れがあると、その値が位置引数へずれ込んで
    # キーの位置が変わる。危険なキーを取り落とさないよう、書き込みと判断した
    # ときは位置を絞らず全オペランドを見る
    if options & GIT_CONFIG_WRITE_OPTIONS:
        return True, operands
    if operands and operands[0] in GIT_CONFIG_WRITE_SUBCOMMANDS:
        return True, operands[1:]
    if options & GIT_CONFIG_READ_OPTIONS:
        return False, []
    if operands and operands[0] in GIT_CONFIG_READ_SUBCOMMANDS:
        return False, []
    # `git config <key> <value>` は書き込み、`git config <key>` は読み取り
    if len(operands) >= 2:
        return True, operands
    return False, []


def git_config_reveals_credentials(arguments):
    """git config が認証付き proxy / HTTP header を表示する形かを返す。"""
    words = subcommand_words(arguments, GIT_VALUE_OPTIONS | GIT_CONFIG_VALUE_OPTIONS)
    if words[:1] != ["config"]:
        return False
    options = {argument.split("=", 1)[0] for argument in arguments}
    if "--name-only" in options:
        return False
    operands = words[1:]
    list_option = any(
        option == "-l"
        or (
            option.startswith("-")
            and not option.startswith("--")
            and "l" in option[1:].split("f", 1)[0]
        )
        or (
            len(option) >= len("--lis")
            and "--list".startswith(option)
        )
        for option in options
    )
    if list_option or operands[:1] == ["list"]:
        return True

    query_option = None
    for option in options:
        if option in {"--get", "--get-all", "--get-urlmatch"}:
            query_option = option
            break
        if len(option) >= len("--get-reg") and "--get-regexp".startswith(option):
            query_option = "--get-regexp"
            break
    if operands[:1] == ["get"]:
        query_option = "--get-regexp" if "--regexp" in options else "get"
        operands = operands[1:]
    elif query_option is None and len(operands) == 1:
        query_option = "implicit"
    if query_option is None or not operands:
        return False

    key = operands[0].casefold()
    if query_option == "--get-regexp":
        if any(marker in key for marker in DYNAMIC_COMMAND_MARKERS):
            return False
        try:
            pattern = re.compile(key, re.IGNORECASE)
        except re.error:
            return False
        return any(
            pattern.search(candidate)
            for candidate in (
                "http.proxy",
                "http.https://example.invalid.proxy",
                "http.http://example.invalid.proxy",
                "http.extraheader",
                "http.https://example.invalid.extraheader",
                "remote.origin.proxy",
            )
        )
    return key in {"http.proxy", "http.extraheader"} or (
        key.startswith("http.")
        and key.endswith((".proxy", ".extraheader"))
    ) or (
        key.startswith("remote.")
        and key.endswith(".proxy")
        and len(key) > len("remote..proxy")
    )


def git_config_settings(arguments):
    """`-c` / `--config` で渡された `<key>=<value>` を順に返す。"""
    settings = []
    pending = False
    for argument in arguments:
        if pending:
            pending = False
            settings.append(argument)
            continue
        if argument in {"-c", "--config"}:
            pending = True
            continue
        for prefix in ("-c", "--config=", "--config-env="):
            if argument.startswith(prefix) and len(argument) > len(prefix):
                settings.append(argument[len(prefix) :])
                break
    return settings


def terraform_reveals_secret(candidates, arguments):
    """terraform が平文の秘密値を標準出力へ返す形かどうかを判定する。

    引数なしの `terraform output` は sensitive を伏せるため対象にしない。
    名前を指定した output と `-raw` / `-json`、`state pull` / `state show`、
    `show -json` は state の中身をそのまま出す。
    """
    for expected in TERRAFORM_SECRET_SUBCOMMANDS:
        if subcommand_candidates_match(candidates, expected):
            return True

    options = {argument.split("=", 1)[0] for argument in arguments}
    for expected, secret_options in TERRAFORM_SECRET_OPTIONS.items():
        if not subcommand_candidates_match(candidates, expected):
            continue
        if options & secret_options:
            return True
        # 名前を指定した output は、sensitive でもそのまま表示する
        if expected == ("output",) and any(
            len(words) > len(expected) for words in candidates
        ):
            return True
    return False


def container_changes_state(words, arguments):
    """コンテナ操作が読み取りだけで済まないかどうかを判定する。

    docker はサンドボックス外で走り、ホストと外部レジストリの双方を変えられる。
    変更操作を列挙し切るのは無理なので、読み取りと分かる形を allowlist にして、
    そこから漏れたものを確認へ回す。
    読み取りのサブコマンドでも、状態を変えるオプションが付けば対象にする。
    """
    if not words:
        # `docker` 単体はヘルプ表示
        return False
    options = {argument.split("=", 1)[0] for argument in arguments}
    if options & CONTAINER_STATE_CHANGING_OPTIONS:
        return True
    # 切り詰めを解除する、または安全と言えないフィールドを指す出力指定は、
    # 読み取りでも tool output へ平文を載せる経路になる
    templates = option_values_with_joined(arguments, {"--format"})
    ps_commands = (("ps",), ("container", "ls"), ("compose", "ps"))
    is_ps_command = any(
        tuple(words[: len(command)]) == command for command in ps_commands
    )
    if boolean_option_enabled(arguments, CONTAINER_UNSAFE_OUTPUT_OPTIONS) and not (
        templates
        and all(container_format_is_safe(template) for template in templates)
    ):
        return True
    for template in templates:
        if not (
            container_ps_format_is_safe(template)
            if is_ps_command
            else container_format_is_safe(template)
        ):
            return True
    return not any(
        tuple(words[: len(expected)]) == expected
        for expected in CONTAINER_READONLY_SUBCOMMANDS
    )


def container_format_is_safe(template):
    """`--format` の指定が、安全と分かるフィールドだけを出すかを判定する。

    `json` のような全体出力や `{{index . "Command"}}` のような間接参照は、
    フィールド名の文字列一致で弾けないため、参照の形そのものを制限する。
    """
    references = CONTAINER_FORMAT_REFERENCE_RE.findall(template)
    if not references:
        # `json` のようにテンプレートですらない指定は、全フィールドが出る
        return False
    for reference in references:
        token = reference.strip()
        if not CONTAINER_FORMAT_FIELD_RE.match(token):
            return False
        # 入れ子の参照は、構成要素がすべて安全な場合だけ通す
        # (`.Server.Version` は通し、`.Config.Env` は通さない)
        components = tuple(
            component.casefold() for component in token[1:].split(".")
        )
        if components in CONTAINER_SAFE_FORMAT_PATHS:
            continue
        if any(
            component.casefold() not in CONTAINER_SAFE_FORMAT_FIELDS
            for component in components
        ):
            return False
    return True


def container_ps_format_is_default(template):
    """ps の切り詰められた既定表を選ぶ format directive かを見る。"""
    return template.strip().casefold() in {"pretty", "table"}


def container_ps_format_is_safe(template):
    """ps の既定表、または安全なフィールドだけの template かを見る。"""
    return container_ps_format_is_default(template) or container_format_is_safe(
        template
    )


def interpreter_cluster_code(command, token):
    """短縮オプションの塊から、コード本体と「次の引数がコードか」を返す。

    `node -pe 'コード'` は `-p` と `-e` の 2 つのフラグで、コードは次の引数。
    `perl -e'コード'` は `-e` に続く残りがコード本体。両者は同じ書き方に
    見えるため、残りがすべてオプション文字なら塊が続いていると解釈し、
    決め切れない側も候補として残す (候補が増えても判定が緩むことはない)。
    """
    options = INTERPRETER_CODE_OPTIONS.get(command, set())
    code_letters = {
        option[1:]
        for option in options
        if len(option) == 2 and option.startswith("-")
    }
    flag_letters = INTERPRETER_FLAG_LETTERS.get(command, "")
    digit_letters = INTERPRETER_DIGIT_LETTERS.get(command, "")
    value_letters = INTERPRETER_VALUE_LETTERS.get(command, "")
    letters = token[1:]
    code = []
    index = 0
    while index < len(letters):
        letter = letters[index]
        if letter in code_letters:
            rest = letters[index + 1 :]
            if not rest:
                return code, True
            code.append(rest)
            # 残りがすべてオプション文字なら、まだ塊が続いている可能性がある
            if not all(
                character in code_letters
                or character in flag_letters
                or character in digit_letters
                or character in value_letters
                for character in rest
            ):
                return code, False
            index += 1
            continue
        if letter in digit_letters:
            index += 1
            while index < len(letters) and letters[index].isdigit():
                index += 1
            continue
        if letter in value_letters:
            # ここから先はこのオプションの値であって、オプションではない
            return code, False
        if letter in flag_letters:
            index += 1
            continue
        # 解釈できない文字。この先にコードオプションが残っているなら、
        # どこからがコード本体なのかを決められない
        if any(character in code_letters for character in letters[index:]):
            raise ShellScanError("interpreter option cluster cannot be interpreted")
        break
    return code, False


def interpreter_code_arguments(command, arguments):
    """インタプリタへ直接渡されたコード本体を取り出す。"""
    options = INTERPRETER_CODE_OPTIONS.get(command)
    if not options:
        return []

    code = []
    pending = False
    for argument in arguments:
        if pending:
            code.append(argument)
            pending = False
            continue
        if argument in options:
            pending = True
            continue
        # --eval=CODE のように `=` で連結された形式
        name, separator, value = argument.partition("=")
        if separator and name in options:
            code.append(value)
            continue
        # `-e'CODE'` / `-pe 'CODE'` / `-we 'CODE'` のような短縮オプションの塊
        if argument.startswith("-") and not argument.startswith("--"):
            cluster_code, cluster_pending = interpreter_cluster_code(
                command, argument
            )
            code.extend(cluster_code)
            pending = cluster_pending

    if command in INTERPRETER_POSITIONAL_CODE and not code:
        # awk はコード本体が第 1 位置引数。-f はファイル指定なので対象外
        if "-f" not in arguments and not any(
            argument.startswith("-f") for argument in arguments
        ):
            for argument in arguments:
                if not argument.startswith("-"):
                    code.append(argument)
                    break
    return code


def interpreter_code_argument_indexes(command, arguments):
    """インタプリタへ直接渡されたコード本体の argv 位置を返す。"""
    options = INTERPRETER_CODE_OPTIONS.get(command)
    if not options:
        return set()

    indexes = set()
    pending = False
    for index, argument in enumerate(arguments):
        if pending:
            indexes.add(index)
            pending = False
            continue
        if argument in options:
            pending = True
            continue
        name, separator, _value = argument.partition("=")
        if separator and name in options:
            indexes.add(index)
            continue
        if argument.startswith("-") and not argument.startswith("--"):
            cluster_code, cluster_pending = interpreter_cluster_code(
                command, argument
            )
            if cluster_code:
                indexes.add(index)
            pending = cluster_pending

    if command in INTERPRETER_POSITIONAL_CODE and not indexes:
        if "-f" not in arguments and not any(
            argument.startswith("-f") for argument in arguments
        ):
            for index, argument in enumerate(arguments):
                if not argument.startswith("-"):
                    indexes.add(index)
                    break
    return indexes


def interpreter_reads_stdin_script(command, arguments):
    """インタプリタが標準入力からスクリプトを読む形かどうかを判定する。

    `python3 -` のような明示指定と、スクリプトもコードも与えられていない
    呼び出し (`python3 <<EOF`) の両方が対象になる。
    """
    if command not in INTERPRETER_CODE_OPTIONS:
        return False
    if interpreter_code_arguments(command, arguments):
        return False
    for argument in arguments:
        if argument == "-":
            return True
        if not argument.startswith("-"):
            # スクリプトファイルや awk のプログラムが指定されている
            return False
    return True


def interpreter_name(command):
    """python3.13 のような版数付きの名前を、既知のインタプリタ名へ寄せる。"""
    if command in INTERPRETER_CODE_OPTIONS:
        return command
    stripped = INTERPRETER_VERSION_SUFFIX_RE.sub("", command)
    return stripped if stripped in INTERPRETER_CODE_OPTIONS else command


def shell_string_wrapper_commands(command, arguments):
    """ラッパーが shell へ渡すコマンド文字列を取り出す。"""
    entry = SHELL_STRING_WRAPPERS.get(command)
    if entry is None:
        return []
    subcommands, options = entry
    if subcommands and not any(argument in subcommands for argument in arguments):
        return []
    return option_values_with_joined(arguments, options)


def package_runner_argv(command, arguments):
    """npm / npx / pnpm が子プロセスとして起こす argv を返す。

    `--` があればそこが境界。無い場合はランナー側のオプションを構文どおり
    読み飛ばすが、値を取るか判らないオプションが残ると境界を決められないため
    解析不能として閉じる (`npx --color always rm -rf ./x` を取り落とさない)。
    `-c` の文字列指定は shell として別途解析するため、ここでは扱わない。
    """
    subcommands = PACKAGE_RUNNER_SUBCOMMANDS.get(command)
    if subcommands is None:
        return []
    if option_values_with_joined(arguments, {"-c", "--call"}):
        return []

    index = 0
    if subcommands:
        for position, argument in enumerate(arguments):
            if argument in subcommands:
                index = position + 1
                break
        else:
            return []

    # `--` の後ろは無条件に子 argv
    if "--" in arguments[index:]:
        tail = arguments[arguments.index("--", index) + 1 :]
        return [list(tail)] if tail else []

    while index < len(arguments):
        argument = arguments[index]
        if not argument.startswith("-") or argument == "-":
            break
        option = argument.split("=", 1)[0]
        if "=" in argument and option in NPM_VALUE_OPTIONS | NPM_BOOLEAN_OPTIONS:
            index += 1
            continue
        if option in NPM_BOOLEAN_OPTIONS or option.startswith(
            NPM_BOOLEAN_OPTION_PREFIXES
        ):
            index += 1
            continue
        if option in NPM_VALUE_OPTIONS:
            index += 2
            continue
        raise ShellScanError("package runner option cannot be interpreted")

    tail = arguments[index:]
    return [list(tail)] if tail else []


def argv_wrapper_commands(command, arguments):
    """`mise exec -- cmd args` のように、`--` の後ろを argv として起こす形を返す。"""
    subcommands = ARGV_WRAPPER_SUBCOMMANDS.get(command)
    if not subcommands or "--" not in arguments:
        return []
    separator = arguments.index("--")
    if not any(
        word in subcommands
        for word in arguments[:separator]
        if not word.startswith("-")
    ):
        return []
    tail = arguments[separator + 1 :]
    return [tail] if tail else []


def kubectl_remote_child_argv(command, arguments):
    """kubectl/oc exec と oc rsh が remote container で起こす argv を返す。"""
    if command not in {"kubectl", "oc"}:
        return []
    indexes = positional_argument_indexes(arguments, KUBECTL_VALUE_OPTIONS)
    if not indexes:
        return []
    subcommand_index = indexes[0]
    subcommand = arguments[subcommand_index]
    if subcommand != "exec" and not (command == "oc" and subcommand == "rsh"):
        return []

    index = subcommand_index + 1
    target_seen = False
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            tail = arguments[index + 1 :]
            return [tail] if target_seen and tail else []
        if argument.startswith("-") and argument != "-":
            option = argument.split("=", 1)[0]
            if argument.startswith("--"):
                index += (
                    2
                    if "=" not in argument
                    and option in KUBECTL_REMOTE_CHILD_VALUE_OPTIONS
                    else 1
                )
            else:
                parsed = docker_short_option_cluster(
                    argument,
                    KUBECTL_REMOTE_CHILD_VALUE_OPTIONS,
                    {"i", "q", "t"},
                )
                if parsed is not None and parsed[0] and parsed[1] is None:
                    index += 2
                else:
                    index += 1
            continue
        if not target_seen:
            target_seen = True
            index += 1
            continue
        return [arguments[index:]]
    return []


def script_command_argv(command, arguments):
    """macOS 形式の `script <出力ファイル> <コマンド...>` の argv を返す。

    出力ファイルより後ろは子コマンドの引数なので、`-rf` のようにオプションに
    見える語も落とさずそのまま渡す。`-c <文字列>` の形は shell へ渡す文字列
    として別途解析する。
    """
    if command != "script":
        return []
    if option_values_with_joined(arguments, {"-c", "--command"}):
        return []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in SCRIPT_VALUE_OPTIONS:
            index += 2
            continue
        if argument.startswith("-") and argument != "-":
            index += 1
            continue
        break
    tail = arguments[index + 1 :]
    return [tail] if tail else []


def editor_shell_escape(command, arguments):
    """エディタ・sqlite3 から shell へ抜ける指定かどうかを判定する。"""
    if command in VIM_COMMANDS:
        values = list(option_values_with_joined(arguments, VIM_COMMAND_OPTIONS))
        values.extend(
            argument[1:] for argument in arguments if argument.startswith("+")
        )
        return any(VIM_SHELL_ESCAPE_RE.search(value) for value in values)
    if command in SQLITE_COMMANDS:
        values = list(option_values_with_joined(arguments, SQLITE_COMMAND_OPTIONS))
        values.extend(
            argument for argument in arguments if not argument.startswith("-")
        )
        return any(
            SQLITE_SHELL_ESCAPE_RE.search(value)
            or SQLITE_PIPE_OUTPUT_RE.search(value)
            for value in values
        )
    return False


def code_starts_process(command, code_arguments):
    """渡されたコードが外部コマンドを起動する形かどうかを判定する。

    識別子は語の区切りで照合する。文字列連結などで難読化されると当たらないため、
    これは「明らかな起動を止める」ための判定であって境界ではない。
    検査しきれない分は、コードを渡す実行そのものを確認へ回すことで補う。
    """
    literals = INTERPRETER_EXEC_LITERALS.get(command, ())
    identifiers = INTERPRETER_EXEC_IDENTIFIERS + INTERPRETER_LANGUAGE_IDENTIFIERS.get(
        command, ()
    )
    patterns = INTERPRETER_EXEC_PATTERNS
    language_patterns = INTERPRETER_LANGUAGE_PATTERNS.get(command, ())
    for code in code_arguments:
        lowered = code.casefold()
        if any(literal in lowered for literal in literals):
            return True
        if code_contains_identifier(lowered, identifiers):
            return True
        if any(re.search(pattern, lowered) for pattern in patterns):
            return True
        # awk のパイプ判定は、文字列リテラルを外してから見る。
        # `print "a|b"` や `split($0, a, "|")` を起動と誤認しないため
        if language_patterns:
            stripped = strip_string_literals(lowered)
            if any(re.search(pattern, stripped) for pattern in language_patterns):
                return True
    return False


def strip_string_literals(code):
    """ダブルクォートで囲まれた文字列を取り除く (エスケープを考慮する)。"""
    output = []
    index = 0
    while index < len(code):
        character = code[index]
        if character != '"':
            output.append(character)
            index += 1
            continue
        index += 1
        while index < len(code) and code[index] != '"':
            index += 2 if code[index] == "\\" else 1
        index += 1
    return "".join(output)


def code_contains_identifier(lowered_code, identifiers):
    """コード中に、語の区切りで一致する識別子があるかを判定する。"""
    for identifier in identifiers:
        pattern = r"(?<![A-Za-z0-9_])" + re.escape(identifier.casefold())
        if identifier.isidentifier():
            pattern += r"(?![A-Za-z0-9_])"
        if re.search(pattern, lowered_code):
            return True
    return False


def code_builds_target_dynamically(code_arguments):
    """実行対象を実行時に組み立てるコードかどうかを判定する。"""
    return any(
        code_contains_identifier(code.casefold(), INTERPRETER_OBFUSCATION_IDENTIFIERS)
        for code in code_arguments
    )


def static_string_literals(code):
    """インタプリタコードから静的な文字列リテラル候補を取り出す。"""
    literals = []
    index = 0
    while index < len(code):
        quote = code[index]
        if quote not in {"'", '"', "`"}:
            index += 1
            continue
        start = index
        delimiter = quote * 3 if code.startswith(quote * 3, index) else quote
        index += len(delimiter)
        value = []
        while index < len(code):
            if code.startswith(delimiter, index):
                end = index + len(delimiter)
                literals.append(("".join(value), start, end))
                index = end
                break
            if code[index] == "\\" and index + 1 < len(code):
                escaped = code[index + 1]
                if escaped in {"\\", "'", '"', "`", "/"}:
                    value.append(escaped)
                else:
                    value.extend(("\\", escaped))
                index += 2
                continue
            value.append(code[index])
            index += 1
        else:
            # コメント中の apostrophe などを文字列開始と誤認しても、後続の
            # 正しいリテラルまで走査を打ち切らない。
            index = start + 1

    candidates = [value for value, _start, _end in literals]
    if not literals:
        return candidates

    combined = literals[0][0]
    previous_end = literals[0][2]
    for value, start, end in literals[1:]:
        separator = code[previous_end:start]
        if re.fullmatch(r"\s*(?:[+.]\s*)?", separator):
            combined += value
            candidates.append(combined)
        else:
            combined = value
        previous_end = end
    return candidates


def code_references_credential_path(code_arguments):
    """コード内の静的文字列が既知の認証情報パスを指すかを判定する。"""
    return any(
        argument_references_credential_path(candidate, path_context=True)
        for code in code_arguments
        for candidate in static_string_literals(code)
    )


def env_dump_arguments(command, arguments):
    """環境変数の値を出力する形の呼び出しかどうかを判定する。

    printenv は固定した安全な変数名だけを許可する。set / export / declare /
    typeset は、一覧形式、表示オプション、または機密名の指定で値を出力する。
    """
    if command == "printenv":
        names = []
        end_of_options = False
        for argument in arguments:
            if not end_of_options and argument == "--":
                end_of_options = True
                continue
            if not end_of_options and argument == "-0":
                continue
            if not end_of_options and argument.startswith("-"):
                return True
            names.append(argument)
        return not names or any(name not in SAFE_PRINTENV_NAMES for name in names)
    option_clusters = []
    positional = []
    parsing_options = True
    for argument in arguments:
        if parsing_options and argument == "--":
            parsing_options = False
            continue
        if (
            parsing_options
            and len(argument) > 1
            and argument[0] in "-+"
        ):
            option_clusters.append((argument[0], argument[1:].split("=", 1)[0]))
        else:
            parsing_options = False
            positional.append(argument)
    if command == "set":
        return not arguments
    if command in {"export", "declare", "typeset"}:
        # -p と +p はどちらも値を表示し、組み合わせた短縮形 (-px 等) もある。
        if any("p" in letters for _, letters in option_clusters):
            return True
        if command in {"declare", "typeset"}:
            # zsh の -m は属性変更を伴わないとき、pattern に一致する値を表示する。
            match_enabled = False
            has_attribute_option = False
            for sign, letters in option_clusters:
                for letter in letters:
                    if letter == "m":
                        match_enabled = sign == "-"
                    elif letter != "p":
                        has_attribute_option = True
            if match_enabled and not has_attribute_option:
                return True
            if not option_clusters:
                for operand in positional:
                    if "=" in operand:
                        continue
                    match = re.match(r"^[A-Za-z_][A-Za-z0-9_]*", operand)
                    if match and parameter_is_sensitive(match.group(0)):
                        return True
        return not positional
    return False


def process_inspection_reveals_credentials(command, arguments):
    """process command が環境または完全な argv を明示出力するかを返す。"""
    if command == "ps":
        first = arguments[:1]
        bsd_flags = (
            set(first[0])
            if first and re.fullmatch(r"[A-Za-z]+", first[0])
            else set()
        )
        dashed_flags = {
            flag
            for argument in arguments
            if re.fullmatch(r"-[A-Za-z]+", argument)
            for flag in argument[1:]
        }
        if "e" in bsd_flags:
            return True
        if "E" in dashed_flags:
            return True

        # -O は既定形式へ列を追加するため、完全な command 列が残る。
        if any(
            re.fullmatch(r"-[A-Za-z]*O.*", argument) for argument in arguments
        ):
            return True

        format_values = option_values_with_joined(arguments, {"-o"})
        for index, argument in enumerate(arguments):
            match = re.fullmatch(r"-[A-Za-z]*o(.*)", argument)
            if not match:
                continue
            if match.group(1):
                format_values.append(match.group(1))
            elif index + 1 < len(arguments):
                format_values.append(arguments[index + 1])
        for value in format_values:
            fields = {
                field.partition("=")[0].strip().casefold()
                for field in re.split(r"[\s,]+", value)
                if field
            }
            if fields & {"args", "cmd", "command", "env"}:
                return True
        if format_values:
            # -o は既定の command 列を置き換える。-ww は選んだ安全な列の
            # 幅を広げるだけなので、この場合は拒否理由にならない。
            return False

        # -L は出力キーワードの一覧、-c は完全な argv の代わりに実行体名を出す。
        if "L" in dashed_flags or "c" in dashed_flags or "c" in bsd_flags:
            return False
        # macOS の既定形式には完全な command line が含まれる。
        return True

    if command == "pgrep":
        if any(argument.split("=", 1)[0] == "--list-full" for argument in arguments):
            return True
        short_flags = {
            flag
            for argument in arguments
            if argument.startswith("-") and not argument.startswith("--")
            for flag in argument[1:].split("=", 1)[0]
        }
        return {"f", "l"} <= short_flags

    if command == "launchctl":
        words = subcommand_words(arguments, set())
        if not words:
            return False
        if words[0] in {"export", "print", "print-cache", "dumpstate"}:
            return True
        return (
            words[0] == "getenv"
            and len(words) > 1
            and parameter_is_sensitive(words[1])
        )

    if command == "sysctl":
        return any(
            not argument.startswith("-")
            and argument.split("=", 1)[0].casefold().startswith("kern.procargs")
            for argument in arguments
        )
    return False


def shell_history_reveals_credentials(command, arguments):
    """history / fc が履歴本文を標準出力へ返す形かを判定する。"""
    if command == "fc":
        # fc は履歴を一覧表示するか、履歴本文を editor へ渡して再実行する。
        return True
    if command != "history":
        return False
    if not arguments or arguments == ["--"]:
        return True
    flags = set()
    operands = []
    end_of_options = False
    for argument in arguments:
        if not end_of_options and argument == "--":
            end_of_options = True
            continue
        if not end_of_options and re.fullmatch(r"-[A-Za-z]+", argument):
            flags.update(argument[1:])
            continue
        operands.append(argument)
    # 履歴を別ファイルへ複製すると、そのファイルを経由して読める。
    if flags & {"a", "n", "r", "w"}:
        return True
    if "p" in flags:
        return not operands or any(
            "!" in operand
            or operand.startswith("^")
            or command_word_is_dynamic(operand)
            for operand in operands
        )
    first = (
        arguments[1]
        if arguments[:1] == ["--"] and len(arguments) > 1
        else arguments[0]
    )
    return re.fullmatch(r"-?[0-9]+", first) is not None


def strip_launcher_options(arguments, value_options):
    """先頭のオプション (と値) を飛ばし、実行コマンド以降の argv を返す。

    arch / caffeinate のように「オプションの後に実行コマンド」を取る
    ランチャーを unwrap するために使う。
    """
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return arguments[index + 1 :]
        if argument.startswith("-") and argument != "-":
            option = argument.split("=", 1)[0]
            if "=" not in argument and option in value_options:
                index += 2
            else:
                index += 1
            continue
        break
    return arguments[index:]


def arithmetic_expression_marker(expression):
    return "__arithmetic_expansion__" + expression.encode("utf-8").hex() + "__"


def arithmetic_command_marker(expression):
    return "__arithmetic_command__" + expression.encode("utf-8").hex() + "__"


def parameter_assignment_marker(parameter):
    """`${name=word}` / `${name:=word}` の代入を後段へ渡す。"""
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*:?=", parameter, re.S):
        return ""
    return "__parameter_assignment__" + parameter.encode("utf-8").hex() + "__"


def parameter_arithmetic_markers(parameter):
    """パラメーター展開で算術評価される添字・部分文字列式をマーカー化する。"""
    match = re.match(
        r"^[!#]?(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])",
        parameter,
    )
    if not match:
        return ""
    cursor = match.end()
    markers = []
    if parameter.startswith("!") and cursor == len(parameter):
        # 間接展開先の配列添字などは再評価される
        indirect_name = parameter[1:]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", indirect_name):
            markers.append(arithmetic_expression_marker(indirect_name))
    if cursor < len(parameter) and parameter[cursor] == "[":
        subscript_start = cursor + 1
        cursor = subscript_start
        depth = 1
        while cursor < len(parameter) and depth:
            if parameter[cursor] == "[":
                depth += 1
            elif parameter[cursor] == "]":
                depth -= 1
            cursor += 1
        if depth:
            raise ShellScanError("unterminated parameter array subscript")
        subscript = parameter[subscript_start : cursor - 1]
        if subscript not in {"@", "*"}:
            markers.append(arithmetic_expression_marker(subscript))
    if (
        cursor < len(parameter)
        and parameter[cursor] == ":"
        and (
            cursor + 1 >= len(parameter)
            or parameter[cursor + 1] not in "-=+?"
        )
    ):
        markers.append(arithmetic_expression_marker(parameter[cursor + 1 :]))
    return "".join(markers)


def decode_ansi_c(value):
    """Bash の $'...' でコマンド名に使われる代表的なエスケープを復元する。"""
    escapes = {
        "a": "\a",
        "b": "\b",
        "e": "\x1b",
        "E": "\x1b",
        "f": "\f",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "v": "\v",
        "\\": "\\",
        "'": "'",
        '"': '"',
    }
    result = []
    index = 0
    while index < len(value):
        if value[index] != "\\" or index + 1 >= len(value):
            result.append(value[index])
            index += 1
            continue

        escaped = value[index + 1]
        if escaped in escapes:
            result.append(escapes[escaped])
            index += 2
            continue
        if escaped in "01234567":
            match = re.match(r"[0-7]{1,3}", value[index + 1 :])
            result.append(chr(int(match.group(0), 8)))
            index += 1 + len(match.group(0))
            continue
        if escaped == "x":
            match = re.match(r"[0-9A-Fa-f]{1,2}", value[index + 2 :])
            if match:
                result.append(chr(int(match.group(0), 16)))
                index += 2 + len(match.group(0))
                continue
        if escaped == "u":
            match = re.match(r"[0-9A-Fa-f]{1,4}", value[index + 2 :])
            if match:
                result.append(chr(int(match.group(0), 16)))
                index += 2 + len(match.group(0))
                continue
        if escaped == "U":
            match = re.match(r"[0-9A-Fa-f]{1,8}", value[index + 2 :])
            if match:
                result.append(chr(int(match.group(0), 16)))
                index += 2 + len(match.group(0))
                continue

        # Bash は未知のエスケープでもバックスラッシュを保持する
        result.append("\\" + escaped)
        index += 2

    return "".join(result)


def find_backtick_end(text, start):
    index = start
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == "`":
            return index
        index += 1
    raise ShellScanError("unterminated backtick command substitution")


def starts_alternate_command_substitution(text, index):
    return text.startswith("${|", index) or (
        text.startswith("${", index)
        and index + 2 < len(text)
        and text[index + 2].isspace()
    )


def find_arithmetic_end(text, start):
    """$(( の内容開始位置から、対応する )) の直後を返す。"""
    depth = 2
    quote = None
    index = start
    while index < len(text):
        character = text[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            elif text.startswith("$(", index) and not text.startswith("$((", index):
                index = find_parenthesized_end(text, index + 2)
            else:
                index += 1
            continue

        if character == "\\":
            index += 2
        elif character in {"'", '"'}:
            quote = character
            index += 1
        elif character == "`":
            index = find_backtick_end(text, index + 1) + 1
        elif text.startswith("$((", index):
            index = find_arithmetic_end(text, index + 3)
        elif text.startswith("$(", index):
            index = find_parenthesized_end(text, index + 2)
        elif character == "(":
            depth += 1
            index += 1
        elif character == ")":
            depth -= 1
            index += 1
            if depth == 0:
                return index
        else:
            index += 1
    raise ShellScanError("unterminated arithmetic expansion")


def find_parameter_expansion_end(text, start):
    """${ の内容開始位置から、クォートと入れ子を考慮して対応する } の直後を返す。"""
    depth = 1
    quote = None
    index = start
    while index < len(text):
        character = text[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            elif text.startswith("${", index):
                depth += 1
                index += 2
            elif text.startswith("$(", index):
                index = find_parenthesized_end(text, index + 2)
            elif character == "}":
                depth -= 1
                index += 1
                if depth == 0:
                    return index
            else:
                index += 1
            continue

        if character == "\\":
            index += 2
        elif character in {"'", '"'}:
            quote = character
            index += 1
        elif text.startswith("${", index):
            depth += 1
            index += 2
        elif text.startswith("$(", index):
            index = find_parenthesized_end(text, index + 2)
        elif character == "}":
            depth -= 1
            index += 1
            if depth == 0:
                return index
        else:
            index += 1
    raise ShellScanError("unterminated parameter expansion")


def find_parenthesized_end(text, start):
    """$( / <( / >( の内容開始位置から、対応する ) の直後を返す。"""
    depth = 1
    quote = None
    case_states = []
    at_command_start = True
    coproc_name_pending = False
    time_command_pending = False
    command_prefixes = {
        "if",
        "then",
        "elif",
        "else",
        "while",
        "until",
        "do",
        "!",
    }
    index = start
    while index < len(text):
        character = text[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            elif character == "`":
                index = find_backtick_end(text, index + 1) + 1
            elif text.startswith("$((", index):
                index = find_arithmetic_end(text, index + 3)
            elif text.startswith("$(", index):
                index = find_parenthesized_end(text, index + 2)
            elif text.startswith("${", index):
                index = find_parameter_expansion_end(text, index + 2)
            else:
                index += 1
            continue

        if (
            character == "#"
            and (
                index == start
                or text[index - 1].isspace()
                or text[index - 1] in ";&|()<>"
            )
        ):
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline + 1
            at_command_start = True
            continue
        if text.startswith("<<", index) and not text.startswith("<<<", index):
            # ネストしたヒアドキュメントを安全に読み飛ばせない場合は拒否する
            raise ShellScanError("heredoc in command substitution is unsupported")
        if (
            time_command_pending
            and character == "-"
            and (index == start or text[index - 1].isspace())
        ):
            option_end = index + 1
            while option_end < len(text) and not (
                text[option_end].isspace() or text[option_end] in ";&|()<>"
            ):
                option_end += 1
            if text[index:option_end] in {"-p", "--"}:
                index = option_end
                continue

        # case パターンの閉じ括弧はコマンド置換自体の閉じ括弧ではない
        in_case_pattern = case_states and case_states[-1]["mode"] == "pattern"
        if in_case_pattern:
            state = case_states[-1]
            if character.isspace():
                index += 1
                continue
            if (
                state["at_start"]
                and text.startswith("esac", index)
                and (
                    index + 4 == len(text)
                    or not (text[index + 4].isalnum() or text[index + 4] == "_")
                )
            ):
                case_states.pop()
                at_command_start = False
                index += 4
                continue
            if character == "(" and state["at_start"]:
                state["at_start"] = False
                index += 1
                continue
            if character == "(":
                state["pattern_depth"] += 1
                state["at_start"] = False
                index += 1
                continue
            if character == ")":
                if state["pattern_depth"]:
                    state["pattern_depth"] -= 1
                else:
                    state["mode"] = "body"
                    at_command_start = True
                index += 1
                continue
            if character == "|" and state["pattern_depth"] == 0:
                state["at_start"] = True
                index += 1
                continue
            state["at_start"] = False

        if case_states and case_states[-1]["mode"] == "body":
            for terminator in (";;&", ";;", ";&"):
                if text.startswith(terminator, index):
                    case_states[-1] = {
                        "mode": "pattern",
                        "pattern_depth": 0,
                        "at_start": True,
                    }
                    at_command_start = True
                    index += len(terminator)
                    break
            else:
                terminator = None
            if terminator is not None:
                continue

        if character.isalpha() or character == "_":
            end = index + 1
            while end < len(text) and (text[end].isalnum() or text[end] == "_"):
                end += 1
            word = text[index:end]
            at_word_boundary = (
                (
                    index == start
                    or text[index - 1].isspace()
                    or text[index - 1] in ";&|()<>"
                )
                and (
                    end == len(text)
                    or text[end].isspace()
                    or text[end] in ";&|()<>")
                )
            if not in_case_pattern and at_word_boundary:
                if case_states and case_states[-1]["mode"] == "word":
                    case_states[-1]["mode"] = "await_in"
                    at_command_start = False
                elif (
                    word == "in"
                    and case_states
                    and case_states[-1]["mode"] == "await_in"
                ):
                    case_states[-1] = {
                        "mode": "pattern",
                        "pattern_depth": 0,
                        "at_start": True,
                    }
                    at_command_start = True
                elif word == "case" and at_command_start:
                    case_states.append({"mode": "word"})
                    at_command_start = False
                    coproc_name_pending = False
                    time_command_pending = False
                elif (
                    word == "esac"
                    and at_command_start
                    and case_states
                    and case_states[-1]["mode"] == "body"
                ):
                    case_states.pop()
                    at_command_start = False
                elif word == "coproc" and at_command_start:
                    coproc_name_pending = True
                    time_command_pending = False
                    at_command_start = True
                elif coproc_name_pending and at_command_start:
                    coproc_name_pending = False
                    at_command_start = True
                elif word == "time" and at_command_start:
                    time_command_pending = True
                    at_command_start = True
                elif at_command_start and word in command_prefixes:
                    at_command_start = True
                else:
                    coproc_name_pending = False
                    time_command_pending = False
                    at_command_start = False
            elif not in_case_pattern and (
                index == start
                or text[index - 1].isspace()
                or text[index - 1] in ";&|()<>"
            ):
                if case_states and case_states[-1]["mode"] == "word":
                    case_states[-1]["mode"] = "await_in"
                coproc_name_pending = False
                time_command_pending = False
                at_command_start = False
            index = end
            continue

        if character == "\\":
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index += 2
        elif character in {"'", '"'}:
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            quote = character
            index += 1
        elif character == "`":
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index = find_backtick_end(text, index + 1) + 1
        elif text.startswith("$((", index):
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index = find_arithmetic_end(text, index + 3)
        elif text.startswith("$(", index):
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index = find_parenthesized_end(text, index + 2)
        elif text.startswith("${", index):
            if case_states and case_states[-1]["mode"] == "word":
                case_states[-1]["mode"] = "await_in"
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = False
            index = find_parameter_expansion_end(text, index + 2)
        elif character == "(":
            depth += 1
            time_command_pending = False
            at_command_start = True
            index += 1
        elif character == ")":
            depth -= 1
            at_command_start = False
            index += 1
            if depth == 0:
                return index
        elif character in ";&|\n":
            coproc_name_pending = False
            time_command_pending = False
            at_command_start = True
            index += 1
        elif character == "{":
            time_command_pending = False
            at_command_start = True
            index += 1
        else:
            if not character.isspace() and character not in "<>":
                if case_states and case_states[-1]["mode"] == "word":
                    case_states[-1]["mode"] = "await_in"
                coproc_name_pending = False
                time_command_pending = False
                at_command_start = False
            index += 1
    raise ShellScanError("unterminated command substitution")


def remove_shell_line_continuations(command):
    """シングルクォート外のバックスラッシュ改行をトークン化前に除去する。"""
    output = []
    quote = None
    index = 0
    while index < len(command):
        character = command[index]
        if (
            character == "\\"
            and index + 1 < len(command)
            and command[index + 1] == "\n"
        ):
            if quote != "'":
                index += 2
                continue
        output.append(character)
        if quote is None and character in {"'", '"'}:
            quote = character
        elif quote == character:
            quote = None
        if character == "\\" and quote != "'" and index + 1 < len(command):
            output.append(command[index + 1])
            index += 2
        else:
            index += 1
    return "".join(output)


def strip_shell_comments(command):
    """引用符外かつ単語先頭の # から改行までをコメントとして除去する。"""
    output = []
    quote = None
    at_word_start = True
    index = 0
    while index < len(command):
        character = command[index]
        if quote is None:
            if command.startswith("$(", index):
                if command.startswith("$((", index):
                    closing = find_arithmetic_end(command, index + 3)
                else:
                    closing = find_parenthesized_end(command, index + 2)
                output.append(command[index:closing])
                index = closing
                at_word_start = False
                continue
            if (
                character in {"<", ">"}
                and index + 1 < len(command)
                and command[index + 1] == "("
            ):
                closing = find_parenthesized_end(command, index + 2)
                output.append(command[index:closing])
                index = closing
                at_word_start = False
                continue
            if command.startswith("${", index):
                closing = find_parameter_expansion_end(command, index + 2)
                output.append(command[index:closing])
                index = closing
                at_word_start = False
                continue
            if character == "`":
                closing = find_backtick_end(command, index + 1) + 1
                output.append(command[index:closing])
                index = closing
                at_word_start = False
                continue
        if quote is None and character == "#" and at_word_start:
            while index < len(command) and command[index] != "\n":
                index += 1
            continue
        output.append(character)
        if quote is None:
            if character in {"'", '"'}:
                quote = character
                at_word_start = False
            elif character == "\\" and index + 1 < len(command):
                output.append(command[index + 1])
                index += 1
                at_word_start = False
            else:
                at_word_start = character.isspace() or character in ";&|()<>"
        elif character == quote:
            quote = None
            at_word_start = False
        elif character == "\\" and quote == '"' and index + 1 < len(command):
            output.append(command[index + 1])
            index += 1
        index += 1
    return "".join(output)


def mask_literal_punctuation(command):
    """引用された単語とリテラルの区切り文字を構文トークンから区別できるようマスクする。"""
    output = []
    quote = None
    index = 0
    while index < len(command):
        character = command[index]
        if quote is None:
            if character in {"'", '"'}:
                quote = character
                output.append(character)
                output.append(QUOTED_WORD_MARKER)
                index += 1
            elif character == "\\" and index + 1 < len(command):
                escaped = command[index + 1]
                if escaped in LITERAL_PUNCTUATION_ENCODE:
                    output.append(LITERAL_PUNCTUATION_ENCODE[escaped])
                else:
                    output.append(character + escaped)
                index += 2
            else:
                output.append(character)
                index += 1
            continue

        if character == quote:
            quote = None
            output.append(character)
            index += 1
        elif character == "\\" and quote == '"' and index + 1 < len(command):
            escaped = command[index + 1]
            output.append(character)
            output.append(LITERAL_PUNCTUATION_ENCODE.get(escaped, escaped))
            index += 2
        else:
            output.append(LITERAL_PUNCTUATION_ENCODE.get(character, character))
            index += 1
    return "".join(output)


def decode_literal_punctuation(value):
    return value.translate(LITERAL_PUNCTUATION_DECODE)


def mask_arithmetic_for_heredocs(command):
    """算術式内の << をヒアドキュメント演算子と誤認しないよう、改行以外を空白化する。"""
    masked = list(command)
    quote = None
    index = 0
    while index < len(command):
        character = command[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            elif command.startswith("$((", index):
                closing = find_arithmetic_end(command, index + 3)
                for position in range(index, closing):
                    if command[position] not in "\r\n":
                        masked[position] = " "
                index = closing
            else:
                index += 1
            continue

        if character == "\\":
            index += 2
        elif character in {"'", '"'}:
            quote = character
            index += 1
        elif command.startswith("$((", index):
            closing = find_arithmetic_end(command, index + 3)
            for position in range(index, closing):
                if command[position] not in "\r\n":
                    masked[position] = " "
            index = closing
        elif command.startswith("((", index):
            closing = find_arithmetic_end(command, index + 2)
            for position in range(index, closing):
                if command[position] not in "\r\n":
                    masked[position] = " "
            index = closing
        else:
            index += 1
    return "".join(masked)


def parse_heredoc_word(line, start):
    index = start
    while index < len(line) and line[index] in " \t":
        index += 1

    value = []
    quoted = False
    while index < len(line):
        character = line[index]
        if character in " \t\r\n;&|()<>":
            break
        if character == "\\":
            quoted = True
            if index + 1 < len(line):
                value.append(line[index + 1])
                index += 2
            else:
                index += 1
            continue
        if line.startswith("$'", index):
            quoted = True
            cursor = index + 2
            raw = []
            while cursor < len(line):
                if line[cursor] == "\\" and cursor + 1 < len(line):
                    raw.append(line[cursor : cursor + 2])
                    cursor += 2
                elif line[cursor] == "'":
                    break
                else:
                    raw.append(line[cursor])
                    cursor += 1
            if cursor >= len(line):
                raise ShellScanError("unterminated ANSI-C quote in heredoc delimiter")
            value.append(decode_ansi_c("".join(raw)))
            index = cursor + 1
            continue
        if character == "'":
            quoted = True
            closing = line.find("'", index + 1)
            if closing < 0:
                raise ShellScanError("unterminated quote in heredoc delimiter")
            value.append(line[index + 1 : closing])
            index = closing + 1
            continue
        if character == '"' or line.startswith('$"', index):
            quoted = True
            index += 2 if line.startswith('$"', index) else 1
            while index < len(line) and line[index] != '"':
                if line[index] == "\\" and index + 1 < len(line):
                    escaped = line[index + 1]
                    if escaped in {'$', '`', '"', "\\"}:
                        value.append(escaped)
                        index += 2
                    elif escaped == "\n":
                        index += 2
                    else:
                        value.append("\\" + escaped)
                        index += 2
                else:
                    value.append(line[index])
                    index += 1
            if index >= len(line):
                raise ShellScanError("unterminated quote in heredoc delimiter")
            index += 1
            continue
        value.append(character)
        index += 1

    return "".join(value), quoted, index


def heredocs_on_line(line):
    heredocs = []
    quote = None
    index = 0
    at_word_start = True
    while index < len(line):
        character = line[index]
        if quote == "'":
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                index += 2
            elif character == '"':
                quote = None
                index += 1
            else:
                index += 1
            continue

        if character == "\\":
            index += 2
            at_word_start = False
        elif character in {"'", '"'}:
            quote = character
            index += 1
            at_word_start = False
        elif character == "#" and at_word_start:
            break
        elif line.startswith("<<<", index):
            index += 3
            at_word_start = True
        elif line.startswith("<<", index):
            index += 2
            strip_tabs = False
            if index < len(line) and line[index] == "-":
                strip_tabs = True
                index += 1
            delimiter, quoted, index = parse_heredoc_word(line, index)
            if not delimiter:
                raise ShellScanError("missing heredoc delimiter")
            heredocs.append((delimiter, strip_tabs, quoted))
            at_word_start = False
        else:
            at_word_start = character.isspace() or character in ";&|()<>"
            index += 1
    return heredocs


def strip_heredoc_bodies(command):
    """本文をトークンから除き、各本文と引用有無を出現順で返す。"""
    lines = command.splitlines(True)
    scan_lines = mask_arithmetic_for_heredocs(command).splitlines(True)
    output = []
    heredoc_regions = []
    index = 0
    while index < len(lines):
        header = lines[index]
        output.append(header)
        pending = heredocs_on_line(scan_lines[index])
        index += 1

        for delimiter, strip_tabs, quoted in pending:
            body = []
            found = False
            while index < len(lines):
                line = lines[index]
                comparison = line.rstrip("\r\n")
                if strip_tabs:
                    comparison = comparison.lstrip("\t")
                output.append("\n" if line.endswith(("\n", "\r")) else "")
                index += 1
                if comparison == delimiter:
                    found = True
                    break
                body.append(line)
            heredoc_regions.append(("".join(body), quoted))
            if not found:
                raise ShellScanError("unterminated heredoc")

    return "".join(output), heredoc_regions


def collect_substitutions(command, nested=None, mark_unquoted_fields=True):
    """ネストしたコマンドを回収し、外側の shlex 用には無害な単語へ置換する。"""
    output = []
    if nested is None:
        nested = []

    def register_nested(body, kind="command"):
        marker = "__{}_substitution__{}__".format(kind, len(nested))
        nested.append(body)
        return marker

    quote = None
    index = 0
    while index < len(command):
        character = command[index]
        if quote == "'":
            output.append(character)
            if character == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if character == "\\":
                output.append(command[index : index + 2])
                index += 2
            elif character == '"':
                output.append(character)
                quote = None
                index += 1
            elif character == "`":
                closing = find_backtick_end(command, index + 1)
                body = command[index + 1 : closing].replace("\\`", "`")
                output.append(register_nested(body))
                index = closing + 1
            elif command.startswith("$((", index):
                closing = find_arithmetic_end(command, index + 3)
                arithmetic = command[index + 3 : closing - 2]
                arithmetic_sanitized, _ = collect_substitutions(
                    arithmetic,
                    nested,
                    mark_unquoted_fields=False,
                )
                markers = "".join(
                    match.group(0)
                    for match in NESTED_COMMAND_MARKER_RE.finditer(arithmetic_sanitized)
                )
                output.append(
                    arithmetic_expression_marker(arithmetic_sanitized) + markers
                )
                index = closing
            elif command.startswith("$(", index):
                closing = find_parenthesized_end(command, index + 2)
                output.append(register_nested(command[index + 2 : closing - 1]))
                index = closing
            elif starts_alternate_command_substitution(command, index):
                raise ShellScanError("alternate command substitution is unsupported")
            elif command.startswith("${", index):
                closing = find_parameter_expansion_end(command, index + 2)
                parameter = command[index + 2 : closing - 1]
                resolved = resolved_parameter_value(parameter)
                if resolved is not None:
                    output.append(resolved)
                    index = closing
                    continue
                parameter_sanitized, _ = collect_substitutions(
                    parameter,
                    nested,
                    mark_unquoted_fields=False,
                )
                output.append(
                    braced_expansion_marker(
                        QUOTED_EXPANSION_MARKER,
                        parameter,
                        parameter_sanitized,
                    )
                    + parameter_assignment_marker(parameter_sanitized)
                    + parameter_arithmetic_markers(parameter_sanitized)
                    + prompt_expansion_marker(parameter)
                )
                index = closing
            elif character == "$" and index + 1 < len(command):
                parameter_start = index + 1
                if (
                    command[parameter_start].isalpha()
                    or command[parameter_start] == "_"
                ):
                    parameter_end = parameter_start + 1
                    while parameter_end < len(command) and (
                        command[parameter_end].isalnum()
                        or command[parameter_end] == "_"
                    ):
                        parameter_end += 1
                    name = command[parameter_start:parameter_end]
                    resolved = resolved_parameter_value(name)
                    output.append(
                        resolved
                        if resolved is not None
                        else expansion_marker(QUOTED_EXPANSION_MARKER, name)
                    )
                    index = parameter_end
                elif (
                    command[parameter_start].isdigit()
                    or command[parameter_start] in "*@#?-$!_"
                ):
                    output.append(QUOTED_EXPANSION_MARKER)
                    index += 2
                else:
                    output.append(character)
                    index += 1
            else:
                output.append(character)
                index += 1
            continue

        if character == "\\":
            output.append(command[index : index + 2])
            index += 2
        elif command.startswith("$'", index):
            cursor = index + 2
            raw = []
            while cursor < len(command):
                if command[cursor] == "\\" and cursor + 1 < len(command):
                    raw.append(command[cursor : cursor + 2])
                    cursor += 2
                elif command[cursor] == "'":
                    break
                else:
                    raw.append(command[cursor])
                    cursor += 1
            if cursor >= len(command):
                raise ShellScanError("unterminated ANSI-C quote")
            output.append(shlex.quote(decode_ansi_c("".join(raw))))
            index = cursor + 1
        elif command.startswith('$"', index):
            output.append('"')
            quote = '"'
            index += 2
        elif character in {"'", '"'}:
            output.append(character)
            quote = character
            index += 1
        elif character == "`":
            closing = find_backtick_end(command, index + 1)
            body = command[index + 1 : closing].replace("\\`", "`")
            output.append(UNQUOTED_EXPANSION_MARKER + register_nested(body))
            index = closing + 1
        elif command.startswith("$((", index):
            closing = find_arithmetic_end(command, index + 3)
            arithmetic = command[index + 3 : closing - 2]
            arithmetic_sanitized, _ = collect_substitutions(
                arithmetic,
                nested,
                mark_unquoted_fields=False,
            )
            markers = "".join(
                match.group(0)
                for match in NESTED_COMMAND_MARKER_RE.finditer(arithmetic_sanitized)
            )
            output.append(
                UNQUOTED_EXPANSION_MARKER
                + arithmetic_expression_marker(arithmetic_sanitized)
                + markers
            )
            index = closing
        elif command.startswith("$(", index):
            closing = find_parenthesized_end(command, index + 2)
            output.append(
                UNQUOTED_EXPANSION_MARKER
                + register_nested(command[index + 2 : closing - 1])
            )
            index = closing
        elif command.startswith("((", index):
            closing = find_arithmetic_end(command, index + 2)
            arithmetic = command[index + 2 : closing - 2]
            arithmetic_sanitized, _ = collect_substitutions(
                arithmetic,
                nested,
                mark_unquoted_fields=False,
            )
            output.append("((" + arithmetic_sanitized + "))")
            index = closing
        elif starts_alternate_command_substitution(command, index):
            raise ShellScanError("alternate command substitution is unsupported")
        elif command.startswith("${", index):
            closing = find_parameter_expansion_end(command, index + 2)
            parameter = command[index + 2 : closing - 1]
            resolved = resolved_parameter_value(parameter)
            if resolved is not None:
                output.append(resolved)
                index = closing
                continue
            parameter_sanitized, _ = collect_substitutions(parameter, nested)
            markers = "".join(
                match.group(0)
                for match in NESTED_COMMAND_MARKER_RE.finditer(parameter_sanitized)
            )
            output.append(
                braced_expansion_marker(
                    UNQUOTED_EXPANSION_MARKER,
                    parameter,
                    parameter_sanitized,
                )
                + parameter_assignment_marker(parameter_sanitized)
                + parameter_arithmetic_markers(parameter_sanitized)
                + prompt_expansion_marker(parameter)
                + markers
            )
            index = closing
        elif character == "$" and index + 1 < len(command):
            parameter_start = index + 1
            if command[parameter_start].isalpha() or command[parameter_start] == "_":
                parameter_end = parameter_start + 1
                while parameter_end < len(command) and (
                    command[parameter_end].isalnum() or command[parameter_end] == "_"
                ):
                    parameter_end += 1
                name = command[parameter_start:parameter_end]
                resolved = resolved_parameter_value(name)
                output.append(
                    resolved
                    if resolved is not None
                    else expansion_marker(UNQUOTED_EXPANSION_MARKER, name)
                )
                index = parameter_end
            elif (
                command[parameter_start].isdigit()
                or command[parameter_start] in "*@#?-$!_"
            ):
                output.append(UNQUOTED_EXPANSION_MARKER)
                index += 2
            else:
                output.append(character)
                index += 1
        elif (
            character in {"<", ">"}
            and index + 1 < len(command)
            and command[index + 1] == "("
        ):
            closing = find_parenthesized_end(command, index + 2)
            output.append(
                register_nested(command[index + 2 : closing - 1], "process")
            )
            index = closing
        elif mark_unquoted_fields and character in "*?":
            output.append(UNQUOTED_EXPANSION_MARKER + character)
            index += 1
        elif mark_unquoted_fields and character == "[":
            word_start = index
            while word_start > 0 and not (
                command[word_start - 1].isspace()
                or command[word_start - 1] in ";&|()<>"
            ):
                word_start -= 1
            word_end = index + 1
            while word_end < len(command) and not (
                command[word_end].isspace() or command[word_end] in ";&|()<>"
            ):
                if command[word_end] == "]":
                    full_word_end = word_end + 1
                    while full_word_end < len(command) and not (
                        command[full_word_end].isspace()
                        or command[full_word_end] in ";&|()<>"
                    ):
                        full_word_end += 1
                    if ASSIGNMENT_RE.match(command[word_start:full_word_end]):
                        output.append(character)
                    else:
                        output.append(character + UNQUOTED_EXPANSION_MARKER)
                    break
                word_end += 1
            else:
                output.append(character)
            index += 1
        elif mark_unquoted_fields and character == "{":
            word_end = index + 1
            has_comma = False
            while word_end < len(command) and not (
                command[word_end].isspace() or command[word_end] in ";&|()<>"
            ):
                has_comma = has_comma or command[word_end] == ","
                if command[word_end] == "}":
                    output.append(
                        UNQUOTED_EXPANSION_MARKER + character
                        if has_comma
                        else character
                    )
                    break
                word_end += 1
            else:
                output.append(character)
            index += 1
        else:
            output.append(character)
            index += 1

    if quote is not None:
        raise ShellScanError("unterminated shell quote")
    return "".join(output), nested


def collect_heredoc_substitutions(body):
    """引用なしヒアドキュメントの置換・算術式・代入展開を回収する。"""
    nested = []
    arithmetic_expressions = []
    parameter_assignments = []
    index = 0
    while index < len(body):
        if body[index] == "\\":
            index += 2
        elif body[index] == "`":
            closing = find_backtick_end(body, index + 1)
            nested.append(body[index + 1 : closing])
            index = closing + 1
        elif body.startswith("$((", index):
            closing = find_arithmetic_end(body, index + 3)
            arithmetic = body[index + 3 : closing - 2]
            arithmetic_sanitized, arithmetic_nested = collect_substitutions(arithmetic)
            nested.extend(arithmetic_nested)
            arithmetic_expressions.append(arithmetic_sanitized)
            index = closing
        elif body.startswith("$(", index):
            closing = find_parenthesized_end(body, index + 2)
            nested.append(body[index + 2 : closing - 1])
            index = closing
        elif body.startswith("${", index):
            closing = find_parameter_expansion_end(body, index + 2)
            parameter = body[index + 2 : closing - 1]
            parameter_sanitized, parameter_nested = collect_substitutions(parameter)
            nested.extend(parameter_nested)
            if parameter_assignment_marker(parameter_sanitized):
                parameter_assignments.append(parameter_sanitized)
            markers = parameter_arithmetic_markers(parameter_sanitized)
            for match in ARITHMETIC_EXPRESSION_MARKER_RE.finditer(markers):
                try:
                    arithmetic_expressions.append(
                        bytes.fromhex(match.group(1)).decode("utf-8")
                    )
                except (ValueError, UnicodeDecodeError):
                    raise ShellScanError("invalid arithmetic expression marker")
            index = closing
        else:
            index += 1
    return nested, arithmetic_expressions, parameter_assignments


def expand_punctuation(token):
    if not token or any(character not in PUNCTUATION for character in token):
        return [token]
    result = []
    index = 0
    while index < len(token):
        for operator in PUNCTUATION_OPERATORS:
            if token.startswith(operator, index):
                if operator == "()":
                    result.extend(("(", ")"))
                else:
                    result.append(operator)
                index += len(operator)
                break
        else:
            result.append(token[index])
            index += 1
    return result


def shell_tokens(command):
    command = mask_literal_punctuation(command)
    lexer = shlex.shlex(command, posix=True, punctuation_chars=PUNCTUATION)
    # 引用符外の改行はコマンド区切りとして残す
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    # コメントは単語途中の # を誤認しないよう strip_shell_comments で処理済み
    lexer.commenters = ""
    try:
        raw_tokens = list(lexer)
    except ValueError as error:
        raise ShellScanError(str(error))

    tokens = []
    for token in raw_tokens:
        tokens.extend(expand_punctuation(token))
    return suppress_noncommand_groups(suppress_case_patterns(tokens))


def suppress_noncommand_groups(tokens):
    """算術コマンドと配列代入の本文をコマンド候補から除外する。"""
    result = []
    index = 0
    while index < len(tokens):
        if tokens[index] == "((":
            depth = 1
            expression = []
            index += 1
            while index < len(tokens) and depth:
                if tokens[index] == "((":
                    depth += 1
                elif tokens[index] == "))":
                    depth -= 1
                    if not depth:
                        index += 1
                        break
                if depth:
                    expression.append(tokens[index])
                index += 1
            if depth:
                raise ShellScanError("unterminated arithmetic command")
            result.append(arithmetic_command_marker(" ".join(expression)))
            continue
        if (
            ARRAY_ASSIGNMENT_RE.match(tokens[index])
            and index + 1 < len(tokens)
            and tokens[index + 1] == "("
        ):
            assignment = tokens[index]
            arithmetic_markers = []
            depth = 1
            index += 2
            while index < len(tokens) and depth:
                if tokens[index] == "(":
                    depth += 1
                elif tokens[index] == ")":
                    depth -= 1
                elif depth == 1:
                    element = decode_literal_punctuation(tokens[index])
                    if element.startswith("["):
                        closing = element.find("]")
                        if closing < 0:
                            raise ShellScanError(
                                "unterminated array assignment subscript"
                            )
                        subscript = element[1:closing]
                        if subscript.startswith(UNQUOTED_EXPANSION_MARKER):
                            # collect_substitutions が `[...]` を glob として付けたマーカー
                            subscript = subscript[len(UNQUOTED_EXPANSION_MARKER) :]
                        arithmetic_markers.append(
                            arithmetic_expression_marker(subscript)
                        )
                index += 1
            if depth:
                raise ShellScanError("unterminated array assignment")
            result.append(assignment + "".join(arithmetic_markers))
            continue
        result.append(tokens[index])
        index += 1
    return result


def suppress_case_patterns(tokens):
    """case の選択パターンをコマンド候補から除外する。"""
    result = []
    case_states = []
    at_command_start = True
    redirection_operand = False
    command_prefixes = {
        "if",
        "then",
        "elif",
        "else",
        "while",
        "until",
        "do",
        "!",
        "{",
    }
    clause_terminators = {";;", ";&", ";;&"}

    for token in tokens:
        if case_states and case_states[-1]["mode"] == "pattern":
            state = case_states[-1]
            if token == "\n":
                continue
            if state["at_start"] and token == "esac":
                result.append(token)
                case_states.pop()
                at_command_start = False
                continue
            if token and all(character in "()" for character in token):
                for character in token:
                    if state["mode"] != "pattern":
                        result.append(character)
                        at_command_start = True
                    elif character == "(" and state["at_start"]:
                        state["at_start"] = False
                    elif character == "(":
                        state["pattern_depth"] += 1
                        state["at_start"] = False
                    elif state["pattern_depth"]:
                        state["pattern_depth"] -= 1
                    else:
                        state["mode"] = "body"
                        result.append(character)
                        at_command_start = True
                continue
            if token == "|" and state["pattern_depth"] == 0:
                state["at_start"] = True
                continue
            state["at_start"] = False
            continue

        if case_states and case_states[-1]["mode"] == "word":
            result.append(token)
            if token != "\n":
                case_states[-1]["mode"] = "await_in"
            continue

        if case_states and case_states[-1]["mode"] == "await_in":
            result.append(token)
            if token == "in":
                case_states[-1] = {
                    "mode": "pattern",
                    "pattern_depth": 0,
                    "at_start": True,
                }
            continue

        if case_states and case_states[-1]["mode"] == "body":
            if token in clause_terminators:
                result.append(token)
                case_states[-1] = {
                    "mode": "pattern",
                    "pattern_depth": 0,
                    "at_start": True,
                }
                at_command_start = True
                continue
            if token == "esac" and at_command_start:
                result.append(token)
                case_states.pop()
                at_command_start = False
                continue

        if at_command_start and token == "case":
            result.append(token)
            case_states.append({"mode": "word"})
            at_command_start = False
            continue

        result.append(token)
        if token in REDIRECTIONS:
            redirection_operand = True
        elif redirection_operand:
            redirection_operand = False
        elif token in CONTROL_OPERATORS:
            at_command_start = True
        elif at_command_start and (
            token in command_prefixes or ASSIGNMENT_RE.match(token)
        ):
            continue
        else:
            at_command_start = False

    return result


def split_command_units(tokens):
    units = []
    current = []
    previous_operator = None
    group_depth = 0
    for token in tokens:
        # 括弧なしの function 定義でも本体を別コマンドにする
        function_prefix = 0
        while function_prefix < len(current) and current[function_prefix] in {
            "{",
            "then",
            "elif",
            "else",
            "do",
        }:
            function_prefix += 1
        if (
            token == "{"
            and function_prefix < len(current)
            and command_basename(current[function_prefix]) == "function"
        ):
            units.append(
                {
                    "tokens": current,
                    "before": previous_operator,
                    "after": "{",
                    "group_depth": group_depth,
                }
            )
            current = ["{"]
            previous_operator = "{"
            continue
        if token in CONTROL_OPERATORS:
            if current:
                units.append(
                    {
                        "tokens": current,
                        "before": previous_operator,
                        "after": token,
                        "group_depth": group_depth,
                    }
                )
                current = []
            if token == "(":
                group_depth += 1
            elif token == ")" and group_depth:
                group_depth -= 1
            previous_operator = token
        else:
            current.append(token)
    if current:
        units.append(
            {
                "tokens": current,
                "before": previous_operator,
                "after": None,
                "group_depth": group_depth,
            }
        )
    return units


def command_unit_state_is_uncertain(unit):
    """条件分岐・複合コマンド・pipeline 内で実行が確定しない unit か返す。"""
    return bool(
        unit["group_depth"]
        or unit["before"] in {"&&", "||", "|", "|&"}
        or unit["after"] in {"&&", "||", "|", "|&"}
        or any(
            command_basename(token)
            in {"if", "then", "elif", "else", "while", "until", "do"}
            for token in unit["tokens"]
        )
    )


def remove_redirections(tokens, heredoc_bodies, heredoc_index):
    argv = []
    input_file_operands = []
    output_file_operands = []
    stdin_commands = []
    stdin_is_external = False
    stdin_is_redirected = False
    index = 0
    while index < len(tokens):
        redirection_fd = None
        if (
            (
                tokens[index].isdigit()
                or re.match(r"^\{[A-Za-z_][A-Za-z0-9_]*\}$", tokens[index])
            )
            and index + 1 < len(tokens)
            and tokens[index + 1] in REDIRECTIONS
        ):
            redirection_fd = tokens[index]
            index += 1
        if index < len(tokens) and tokens[index] in REDIRECTIONS:
            operator = tokens[index]
            redirects_stdin = redirection_fd in {None, "0"}
            index += 1
            if index < len(tokens):
                operand = tokens[index]
                index += 1
                # リダイレクトはシェルがファイルを開くため、argv には現れない。
                # `docker run -i img < ~/.aws/credentials` のように、
                # サンドボックス外のコマンドへ内容を流し込む経路になる
                if operator in FILE_REDIRECTIONS:
                    decoded_operand = decode_literal_punctuation(operand)
                    if operator in {"<", "<>"}:
                        input_file_operands.append(decoded_operand)
                    else:
                        output_file_operands.append(decoded_operand)
                if operator == "<<":
                    if heredoc_index >= len(heredoc_bodies):
                        raise ShellScanError("heredoc body could not be associated")
                    if redirects_stdin:
                        stdin_is_redirected = True
                        stdin_is_external = False
                        stdin_commands = [heredoc_bodies[heredoc_index][0]]
                    if not heredoc_bodies[heredoc_index][1]:
                        (
                            _,
                            arithmetic_expressions,
                            parameter_assignments,
                        ) = collect_heredoc_substitutions(
                            heredoc_bodies[heredoc_index][0]
                        )
                        argv.extend(
                            arithmetic_expression_marker(expression)
                            for expression in arithmetic_expressions
                        )
                        argv.extend(
                            parameter_assignment_marker(assignment)
                            for assignment in parameter_assignments
                        )
                    heredoc_index += 1
                elif operator == "<<<" and redirects_stdin:
                    stdin_is_redirected = True
                    stdin_is_external = False
                    stdin_commands = [decode_literal_punctuation(operand)]
                elif operator in {"<", "<>"} and redirects_stdin:
                    stdin_is_redirected = True
                    stdin_is_external = True
                    stdin_commands = []
                elif (
                    (operator == "<&" and redirects_stdin)
                    or (operator == ">&" and redirection_fd == "0")
                ):
                    # Bash は `0>&3` でも FD 3 を標準入力へ複製できる
                    if operand not in {"-", "0"}:
                        stdin_is_redirected = True
                        stdin_is_external = True
                        stdin_commands = []
                    elif operand == "-":
                        stdin_is_redirected = True
                        stdin_is_external = False
                        stdin_commands = []
            continue
        argv.append(decode_literal_punctuation(tokens[index]))
        index += 1
    return (
        argv,
        stdin_commands,
        stdin_is_external,
        stdin_is_redirected,
        heredoc_index,
        input_file_operands,
        output_file_operands,
    )


# ============================================================================
# コマンド解決
# ============================================================================

def strip_control_prefixes(argv):
    executable_prefixes = {
        "if",
        "then",
        "elif",
        "else",
        "while",
        "until",
        "do",
        "!",
        "{",
    }
    declarations = {"for", "select", "case", "function", "in"}
    while argv and command_basename(argv[0]) in executable_prefixes:
        argv = argv[1:]
    if argv and command_basename(argv[0]) in {"for", "select"}:
        # ループ変数は allexport 中に環境へ載る。反復値はコマンドの argv ではない。
        return argv[:2]
    if argv and command_basename(argv[0]) in declarations:
        return []
    return argv


def unwrap_command_options(arguments):
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return arguments[index + 1 :]
        if not argument.startswith("-") or argument == "-":
            break
        if "v" in argument[1:] or "V" in argument[1:]:
            return []
        index += 1
    return arguments[index:]


def unwrap_builtin_options(arguments):
    if arguments[:1] == ["--"]:
        return arguments[1:]
    # -a/-p/-s は照会用で、後続を実行しない
    if arguments and arguments[0].startswith("-"):
        return []
    return arguments


def unwrap_exec_options(arguments):
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return arguments[index + 1 :]
        if argument in {"-a", "--argv0"}:
            index += 2
        elif argument.startswith("--argv0="):
            index += 1
        elif argument.startswith("-") and argument != "-":
            # -a が末尾なら次の単語、途中なら残りが argv[0]
            short_options = argument[1:]
            argv0_index = short_options.find("a")
            index += 2 if argv0_index == len(short_options) - 1 else 1
        else:
            break
    return arguments[index:]


def split_env_string(value):
    try:
        return shlex.split(value, posix=True)
    except ValueError as error:
        raise ShellScanError("invalid env split-string: " + str(error))


def unwrap_env(
    arguments,
    split_depth=0,
    environment=None,
    tainted_environment=None,
    assignments=None,
):
    if split_depth > 32:
        raise ShellScanError("nested env split-string depth exceeded")
    index = 0
    long_options_with_value = {"--argv0", "--chdir", "--split-string", "--unset"}
    long_options_with_optional_value = {
        "--block-signal",
        "--default-signal",
        "--ignore-signal",
    }
    long_flags = {
        "--debug",
        "--ignore-environment",
        "--list-signal-handling",
        "--null",
    }
    short_options_with_value = {"a", "C", "P", "S", "u"}
    short_flags = {"0", "i", "v"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            index += 1
            break
        if argument == "-":
            # env の単独 `-` は `-i` と同じ
            if environment is not None:
                environment.clear()
            if tainted_environment is not None:
                tainted_environment.clear()
            index += 1
            continue
        if argument in long_options_with_value:
            if index + 1 >= len(arguments):
                raise ShellScanError("env option is missing its argument")
            if argument == "--split-string":
                expanded = (
                    split_env_string(arguments[index + 1]) + arguments[index + 2 :]
                )
                return unwrap_env(
                    expanded,
                    split_depth + 1,
                    environment,
                    tainted_environment,
                    assignments,
                )
            if argument == "--unset" and environment is not None:
                environment.pop(arguments[index + 1], None)
            if argument == "--unset" and tainted_environment is not None:
                tainted_environment.discard(arguments[index + 1])
            index += 2
            continue
        if argument.startswith("--split-string="):
            expanded = (
                split_env_string(argument.split("=", 1)[1]) + arguments[index + 1 :]
            )
            return unwrap_env(
                expanded,
                split_depth + 1,
                environment,
                tainted_environment,
                assignments,
            )
        if any(argument.startswith(option + "=") for option in long_options_with_value):
            if argument.startswith("--unset=") and environment is not None:
                environment.pop(argument.split("=", 1)[1], None)
            if (
                argument.startswith("--unset=")
                and tainted_environment is not None
            ):
                tainted_environment.discard(argument.split("=", 1)[1])
            index += 1
            continue
        if argument in long_options_with_optional_value or any(
            argument.startswith(option + "=")
            for option in long_options_with_optional_value
        ):
            index += 1
            continue
        if argument in long_flags:
            if argument == "--ignore-environment" and environment is not None:
                environment.clear()
            if (
                argument == "--ignore-environment"
                and tainted_environment is not None
            ):
                tainted_environment.clear()
            index += 1
            continue
        if argument.startswith("--"):
            raise ShellScanError("unsupported env option")
        if (
            argument.startswith("-")
            and not argument.startswith("--")
            and argument != "-"
        ):
            short_options = argument[1:]
            option_index = 0
            while option_index < len(short_options):
                option = short_options[option_index]
                if option == "i" and environment is not None:
                    environment.clear()
                if option == "i" and tainted_environment is not None:
                    tainted_environment.clear()
                if option in short_options_with_value:
                    inline_value = short_options[option_index + 1 :]
                    if option == "S":
                        if inline_value:
                            split_value = inline_value
                            trailing = arguments[index + 1 :]
                        elif index + 1 < len(arguments):
                            split_value = arguments[index + 1]
                            trailing = arguments[index + 2 :]
                        else:
                            raise ShellScanError(
                                "env split-string is missing its argument"
                            )
                        return unwrap_env(
                            split_env_string(split_value) + trailing,
                            split_depth + 1,
                            environment,
                            tainted_environment,
                            assignments,
                        )
                    if not inline_value:
                        if index + 1 >= len(arguments):
                            raise ShellScanError("env option is missing its argument")
                        index += 1
                    if option == "u" and environment is not None:
                        unset_name = inline_value or arguments[index]
                        environment.pop(unset_name, None)
                    if option == "u" and tainted_environment is not None:
                        unset_name = inline_value or arguments[index]
                        tainted_environment.discard(unset_name)
                    break
                if option not in short_flags:
                    raise ShellScanError("unsupported env option")
                option_index += 1
            index += 1
            continue
        if ASSIGNMENT_RE.match(argument):
            if assignments is not None:
                assignments.append(argument)
            if environment is not None and "[" not in argument.split("=", 1)[0]:
                name, value = argument.split("=", 1)
                environment[name] = value
                if tainted_environment is not None:
                    tainted_environment.discard(name)
            index += 1
            continue
        break
    while index < len(arguments) and ASSIGNMENT_RE.match(arguments[index]):
        if assignments is not None:
            assignments.append(arguments[index])
        if environment is not None and "[" not in arguments[index].split("=", 1)[0]:
            name, value = arguments[index].split("=", 1)
            environment[name] = value
            if tainted_environment is not None:
                tainted_environment.discard(name)
        index += 1
    return arguments[index:]


def unwrap_nice(arguments):
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return arguments[index + 1 :]
        if argument in {"-n", "--adjustment"}:
            index += 2
        elif argument.startswith("--adjustment=") or re.match(r"^-\d+$", argument):
            index += 1
        elif argument.startswith("-") and argument != "-":
            index += 1
        else:
            break
    return arguments[index:]


def unwrap_time(arguments):
    index = 0
    long_options_with_value = {"--format", "--output"}
    long_flags = {"--append", "--portability", "--quiet", "--verbose"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return arguments[index + 1 :]
        if argument in long_options_with_value:
            if index + 1 >= len(arguments):
                raise ShellScanError("time option is missing its argument")
            index += 2
            continue
        if any(argument.startswith(option + "=") for option in long_options_with_value):
            index += 1
            continue
        if argument in long_flags:
            index += 1
            continue
        if argument.startswith("--"):
            raise ShellScanError("unsupported time option")
        if argument.startswith("-") and argument != "-":
            short_options = argument[1:]
            option_index = 0
            consumed_next = False
            while option_index < len(short_options):
                option = short_options[option_index]
                if option in {"f", "o"}:
                    if option_index + 1 == len(short_options):
                        if index + 1 >= len(arguments):
                            raise ShellScanError("time option is missing its argument")
                        consumed_next = True
                    break
                if option not in {"a", "h", "l", "p", "q", "v"}:
                    raise ShellScanError("unsupported time option")
                option_index += 1
            index += 2 if consumed_next else 1
            continue
        break
    return arguments[index:]


def unwrap_timeout(arguments):
    index = 0
    long_options_with_value = {"--kill-after", "--signal"}
    long_flags = {"--foreground", "--preserve-status", "--verbose"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            index += 1
            break
        if argument in long_options_with_value:
            if index + 1 >= len(arguments):
                raise ShellScanError("timeout option is missing its argument")
            index += 2
            continue
        if any(argument.startswith(option + "=") for option in long_options_with_value):
            index += 1
            continue
        if argument in long_flags:
            index += 1
            continue
        if argument.startswith("--"):
            raise ShellScanError("unsupported timeout option")
        if argument.startswith("-") and argument != "-":
            short_options = argument[1:]
            option_index = 0
            consumed_next = False
            while option_index < len(short_options):
                option = short_options[option_index]
                if option in {"k", "s"}:
                    if option_index + 1 == len(short_options):
                        if index + 1 >= len(arguments):
                            raise ShellScanError(
                                "timeout option is missing its argument"
                            )
                        consumed_next = True
                    break
                if option != "v":
                    raise ShellScanError("unsupported timeout option")
                option_index += 1
            index += 2 if consumed_next else 1
            continue
        break
    # 最初の非オプションは時間、次がコマンド
    return arguments[index + 1 :] if index < len(arguments) else []


def unwrap_xargs(arguments):
    index = 0
    replacement_mode = None
    replacement_string = None
    long_options_with_value = {
        "--arg-file",
        "--delimiter",
        "--max-args",
        "--max-chars",
        "--max-procs",
        "--process-slot-var",
    }
    long_options_with_optional_value = {"--eof", "--max-lines"}
    long_flags = {
        "--exit",
        "--interactive",
        "--no-run-if-empty",
        "--null",
        "--open-tty",
        "--show-limits",
        "--verbose",
    }
    short_options_with_value = {"a", "d", "E", "I", "J", "L", "n", "P", "R", "S", "s"}
    short_flags = {"0", "o", "p", "r", "t", "x"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            index += 1
            break
        if argument in long_options_with_value:
            if index + 1 >= len(arguments):
                raise ShellScanError("xargs option is missing its argument")
            index += 2
            continue
        if any(argument.startswith(option + "=") for option in long_options_with_value):
            index += 1
            continue
        if argument == "--replace":
            replacement_mode = "replace"
            replacement_string = "{}"
            index += 1
            continue
        if argument.startswith("--replace="):
            replacement_mode = "replace"
            replacement_string = argument.split("=", 1)[1]
            index += 1
            continue
        if argument in long_options_with_optional_value or any(
            argument.startswith(option + "=")
            for option in long_options_with_optional_value
        ):
            index += 1
            continue
        if argument in long_flags:
            index += 1
            continue
        if argument.startswith("--"):
            raise ShellScanError("unsupported xargs option")
        if argument.startswith("-") and argument != "-":
            short_options = argument[1:]
            option_index = 0
            consumed_next = False
            while option_index < len(short_options):
                option = short_options[option_index]
                if option in short_options_with_value:
                    option_value = short_options[option_index + 1 :]
                    if option_index + 1 == len(short_options):
                        if index + 1 >= len(arguments):
                            raise ShellScanError("xargs option is missing its argument")
                        option_value = arguments[index + 1]
                        consumed_next = True
                    if option in {"I", "J"}:
                        replacement_mode = "replace" if option == "I" else "insert"
                        replacement_string = option_value
                    break
                if option not in short_flags:
                    raise ShellScanError("unsupported xargs option")
                option_index += 1
            index += 2 if consumed_next else 1
            continue
        if argument == "-":
            # `-` はコマンド名として実行される引数
            break
        if argument.startswith("+"):
            raise ShellScanError("unsupported xargs option")
        else:
            break

    argv = arguments[index:]
    if replacement_mode is None:
        # 置換なしでは標準入力の単語を引数末尾へ追加する
        return (argv or ["echo"]) + [XARGS_REPLACEMENT_MARKER]
    if not replacement_string:
        raise ShellScanError("xargs replacement string is empty")
    if replacement_mode == "replace":
        return [
            argument.replace(replacement_string, XARGS_REPLACEMENT_MARKER)
            for argument in argv
        ]

    replaced = []
    replacement_pending = True
    for argument in argv:
        if replacement_pending and argument == replacement_string:
            replaced.append(XARGS_REPLACEMENT_MARKER)
            replacement_pending = False
        else:
            replaced.append(argument)
    return replaced


def shell_structure_depends_on_xargs_replacement(arguments):
    """置換値がシェルオプションまたはスクリプト引数になり得るか判定する。"""
    index = 0
    option_arguments = {"-O", "+O", "-o", "+o", "--rcfile", "--init-file"}
    while index < len(arguments):
        argument = arguments[index]
        if XARGS_REPLACEMENT_MARKER in argument:
            return True
        if argument == "--":
            return (
                index + 1 < len(arguments)
                and XARGS_REPLACEMENT_MARKER in arguments[index + 1]
            )
        if argument in option_arguments:
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if argument.startswith(("-", "+")) and len(argument) > 1:
            if "c" in argument[1:]:
                return False
            index += 1
            continue
        return False
    return False


def shell_word_is_dynamic(argument):
    return (
        UNQUOTED_EXPANSION_MARKER in argument
        or QUOTED_EXPANSION_MARKER in argument
        or "__command_substitution__" in argument
        or "__process_substitution__" in argument
        or "__arithmetic_expansion__" in argument
    )


def shell_structure_depends_on_dynamic_expansion(arguments):
    """展開値がシェルオプション・オプション引数・スクリプト引数を変え得るか判定する。"""
    index = 0
    force_stdin = False
    option_arguments = {"-O", "+O", "-o", "+o", "--rcfile", "--init-file"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return (
                not force_stdin
                and index + 1 < len(arguments)
                and shell_word_is_dynamic(arguments[index + 1])
            )
        if shell_word_is_dynamic(argument):
            return True
        if argument in option_arguments:
            if (
                index + 1 < len(arguments)
                and shell_word_is_dynamic(arguments[index + 1])
            ):
                return True
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if argument.startswith(("-", "+")) and len(argument) > 1:
            flags = argument[1:]
            if "c" in flags:
                return (
                    index + 1 < len(arguments)
                    and shell_word_is_dynamic(arguments[index + 1])
                )
            force_stdin = force_stdin or "s" in flags
            index += 1
            continue
        if force_stdin:
            return False
        return shell_word_is_dynamic(argument)
    return False


def shell_command_string(arguments):
    index = 0
    option_arguments = {"-O", "+O", "-o", "+o", "--rcfile", "--init-file"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return None
        if argument in option_arguments:
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if argument.startswith(('-', '+')) and len(argument) > 1:
            if "c" in argument[1:]:
                return arguments[index + 1] if index + 1 < len(arguments) else ""
            index += 1
            continue
        return None
    return None


def shell_option_enabled(
    arguments,
    option_name,
    short_flag,
    environment,
    tainted_environment,
):
    """子 shell が指定の set option を有効にして起動するかを返す。"""
    shellopts = environment.get("SHELLOPTS")
    enabled = (
        shellopts is not None
        and (
            contains_expansion_or_marker(shellopts)
            or option_name in shellopts.split(":")
        )
    ) or (
        "SHELLOPTS" not in environment
        and "SHELLOPTS" in tainted_environment
    )
    index = 0
    option_arguments = {"-O", "+O", "--rcfile", "--init-file"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            break
        if argument in {"-o", "+o"}:
            if index + 1 < len(arguments) and arguments[index + 1] == option_name:
                enabled = argument == "-o"
            index += 2
            continue
        if argument in option_arguments:
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if argument.startswith(("-", "+")) and len(argument) > 1:
            flags = argument[1:]
            if short_flag in flags:
                enabled = argument.startswith("-")
            if "c" in flags:
                break
            index += 1
            continue
        break
    return enabled


def shell_reads_stdin_script(arguments):
    """-c またはスクリプト引数がなく、標準入力をスクリプトとして読む呼び出しか判定する。"""
    index = 0
    force_stdin = False
    option_arguments = {"-O", "+O", "-o", "+o", "--rcfile", "--init-file"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            return (
                force_stdin
                or index + 1 >= len(arguments)
                or arguments[index + 1] in SHELL_STDIN_PATHS
            )
        if argument in option_arguments:
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if argument.startswith(("-", "+")) and len(argument) > 1:
            flags = argument[1:]
            if "c" in flags:
                return False
            force_stdin = force_stdin or "s" in flags
            index += 1
            continue
        return force_stdin or argument in SHELL_STDIN_PATHS
    return True


def shell_startup_inputs(
    command,
    arguments,
    environment,
    tainted_environment,
):
    inputs = [
        environment[name]
        for name in ("BASH_ENV", "ENV")
        if environment.get(name)
    ]
    inputs.extend(
        INHERITED_NONEMPTY_MARKER
        for name in ("BASH_ENV", "ENV")
        if name not in environment and name in tainted_environment
    )
    if command == "zsh":
        if "ZDOTDIR" in environment:
            inputs.append(environment["ZDOTDIR"] or INHERITED_NONEMPTY_MARKER)
        elif "ZDOTDIR" in tainted_environment:
            inputs.append(INHERITED_NONEMPTY_MARKER)
        elif "HOME" in environment:
            inputs.append(environment["HOME"] or INHERITED_NONEMPTY_MARKER)
        elif "HOME" in tainted_environment:
            inputs.append(INHERITED_NONEMPTY_MARKER)
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in {"--rcfile", "--init-file"}:
            if index + 1 >= len(arguments):
                raise ShellScanError("shell startup option is missing its argument")
            inputs.append(arguments[index + 1])
            index += 2
            continue
        if argument.startswith("--rcfile=") or argument.startswith("--init-file="):
            inputs.append(argument.split("=", 1)[1])
        index += 1
    return inputs


def pipeline_consumer_indexes(units, left_index):
    """同じパイプライン、またはパイプ直後の複合コマンドに属するコマンド単位を返す。"""
    first = left_index + 1
    if first >= len(units):
        return []

    indexes = []
    index = first
    while index < len(units):
        indexes.append(index)
        if units[index]["after"] not in PIPE_OPERATORS:
            break
        index += 1

    tokens = units[first]["tokens"]
    first_word = command_basename(tokens[0]) if tokens else ""
    enters_subshell = units[first]["group_depth"] > units[left_index]["group_depth"]
    if (
        not enters_subshell
        and first_word not in {"if", "while", "until", "for", "select", "case", "{"}
    ):
        return indexes

    terminators = {"fi", "done", "esac", "}"}
    index = indexes[-1] + 1
    while index < len(units):
        if (
            enters_subshell
            and units[index]["group_depth"] < units[first]["group_depth"]
        ):
            break
        indexes.append(index)
        raw = units[index]["tokens"]
        if not enters_subshell and raw and command_basename(raw[0]) in terminators:
            break
        index += 1
    return indexes


def compound_redirection_start(units, redirection_index):
    """複合コマンド末尾の標準入力リダイレクトが適用される最初のコマンド単位を返す。"""
    unit = units[redirection_index]
    tokens = unit["tokens"]
    first_word = command_basename(tokens[0]) if tokens else ""

    if unit["before"] == ")" and tokens and tokens[0] in REDIRECTIONS:
        required_depth = unit["group_depth"] + 1
        index = redirection_index - 1
        while index >= 0 and units[index]["group_depth"] >= required_depth:
            index -= 1
        return index + 1

    openers = {
        "}": {"{"},
        "fi": {"if"},
        "done": {"for", "select", "until", "while"},
        "esac": {"case"},
    }
    if first_word not in openers:
        return None
    index = redirection_index - 1
    while index >= 0:
        raw = units[index]["tokens"]
        if raw and command_basename(raw[0]) in openers[first_word]:
            return index
        index -= 1
    raise ShellScanError("compound command opener could not be associated")


def discover_function_definitions(units):
    functions = {}
    definition_indexes = set()
    index = 0
    while index < len(units):
        tokens = units[index]["tokens"]
        name = None
        body_start = None
        if (
            len(tokens) == 1
            and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", tokens[0])
            and units[index]["after"] == "("
        ):
            if index + 1 >= len(units) or units[index + 1]["before"] != ")":
                raise ShellScanError("unsupported function definition")
            name = tokens[0]
            body_start = index + 1
        elif (
            len(tokens) >= 2
            and command_basename(tokens[0]) == "function"
            and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", tokens[1])
        ):
            name = tokens[1]
            body_start = index + 1

        if name is None:
            index += 1
            continue
        if name in functions:
            raise ShellScanError("function redefinition is unsupported")
        if body_start >= len(units) or "{" not in units[body_start]["tokens"]:
            raise ShellScanError("unsupported function body")

        brace_depth = 0
        body_end = None
        for body_index in range(body_start, len(units)):
            brace_depth += units[body_index]["tokens"].count("{")
            brace_depth -= units[body_index]["tokens"].count("}")
            if brace_depth == 0:
                body_end = body_index
                break
        if body_end is None:
            raise ShellScanError("unterminated function body")
        for body_index in range(body_start, body_end):
            body_tokens = units[body_index]["tokens"]
            if (
                body_tokens
                and command_basename(body_tokens[0]) == "function"
            ) or (
                len(body_tokens) == 1
                and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", body_tokens[0])
                and units[body_index]["after"] == "("
            ):
                raise ShellScanError("nested function definition is unsupported")
        functions[name] = {
            "definition_index": index,
            "body_indexes": list(range(body_start, body_end)),
            "redirection_index": body_end,
        }
        definition_indexes.update(range(index, body_end + 1))
        index = body_end + 1
    return functions, definition_indexes


def static_function_call(argv, functions):
    argv = strip_control_prefixes(argv)
    while argv and ASSIGNMENT_RE.match(argv[0]):
        argv = argv[1:]
    while argv:
        if command_word_is_dynamic(argv[0]):
            return None
        command = command_basename(argv[0])
        if command == "time":
            argv = unwrap_time(argv[1:])
            while argv and ASSIGNMENT_RE.match(argv[0]):
                argv = argv[1:]
            continue
        if command == "coproc":
            arguments = strip_control_prefixes(argv[1:])
            if len(arguments) > 1:
                named_command = command_basename(arguments[1])
                if named_command in functions:
                    return named_command
            if arguments:
                direct_command = command_basename(arguments[0])
                if direct_command in functions:
                    return direct_command
            return None
        return command if command in functions else None
    return None


# ============================================================================
# 判定ルール
# ============================================================================

def rm_has_recursive_force(arguments):
    recursive = False
    force = False
    for argument in arguments:
        if argument == "--":
            break
        if argument == "--recursive":
            recursive = True
        elif argument == "--force":
            force = True
        elif (
            argument.startswith("-")
            and not argument.startswith("--")
            and argument != "-"
        ):
            options = argument[1:]
            recursive = recursive or "r" in options or "R" in options
            force = force or "f" in options
    return recursive and force


def hash_rebinds_command(arguments):
    for argument in arguments:
        if argument == "--":
            return False
        if command_word_is_dynamic(argument):
            raise ShellScanError("dynamic hash option")
        if argument == "-" or not argument.startswith("-"):
            return False
        if "p" in argument[1:]:
            return True
    return False


def command_word_is_dynamic(word):
    """実行コマンド名がシェル展開の結果に依存するか判定する。"""
    if any(marker in word for marker in DYNAMIC_COMMAND_MARKERS):
        return True
    if "$" in word or "`" in word:
        return True
    if word not in {"[", "[["} and any(character in word for character in "*?["):
        return True
    if word.startswith("~"):
        # `~/bin/tool` や `~user/bin/tool` は展開先が一意に決まる
        return expand_home(word).startswith("~")
    if "{" in word and "," in word and "}" in word:
        return True
    return False


def validate_arithmetic_expression(expression, values, seen=None, depth=0):
    """変数値の再評価を含め、コマンドを起動し得ない算術式だけを受理する。"""
    if depth > 32:
        raise ShellScanError("recursive arithmetic expression depth exceeded")
    if seen is None:
        seen = set()
    if (
        "$" in expression
        or "`" in expression
        or UNQUOTED_EXPANSION_MARKER in expression
        or "__command_substitution__" in expression
        or "__process_substitution__" in expression
        or "__arithmetic_expansion__" in expression
    ):
        raise ShellScanError("arithmetic expression contains a dynamic expansion")

    index = 0
    operators = set("+-*/%<>=!&|^~?:,()")
    while index < len(expression):
        character = expression[index]
        if character.isspace() or character in operators:
            index += 1
            continue
        if character.isdigit():
            number = re.match(
                r"(?:0[xX][0-9A-Fa-f]+|[0-9]+#[0-9A-Za-z@_]+|[0-9]+)",
                expression[index:],
            )
            index += len(number.group(0))
            continue
        if character.isalpha() or character == "_":
            end = index + 1
            while end < len(expression) and (
                expression[end].isalnum() or expression[end] == "_"
            ):
                end += 1
            name = expression[index:end]
            key = name
            if end < len(expression) and expression[end] == "[":
                subscript_start = end + 1
                cursor = subscript_start
                bracket_depth = 1
                while cursor < len(expression) and bracket_depth:
                    if expression[cursor] == "[":
                        bracket_depth += 1
                    elif expression[cursor] == "]":
                        bracket_depth -= 1
                    cursor += 1
                if bracket_depth:
                    raise ShellScanError("unterminated arithmetic array subscript")
                subscript = expression[subscript_start : cursor - 1]
                validate_arithmetic_expression(
                    subscript,
                    values,
                    seen.copy(),
                    depth + 1,
                )
                key = name + "[" + subscript + "]"
                end = cursor
            if key not in values or key in seen:
                raise ArithmeticUnknownValueError(
                    "arithmetic expression depends on an unknown value"
                )
            validate_arithmetic_expression(
                values[key],
                values,
                seen | {key},
                depth + 1,
            )
            index = end
            continue
        raise ShellScanError("unsupported arithmetic expression syntax")


def split_arithmetic_parts(expression):
    """算術式を、括弧の外側にある `;` で区切って返す。"""
    parts = []
    depth = 0
    start = 0
    for index, character in enumerate(expression):
        if character in "([":
            depth += 1
        elif character in ")]":
            depth = max(0, depth - 1)
        elif character == ";" and not depth:
            parts.append(expression[start:index])
            start = index + 1
    parts.append(expression[start:])
    return parts


def validate_arithmetic_sequence(expression, values):
    """`for ((init; cond; update))` のように区切られた算術式を検証する。

    先に評価される部分の代入を覚えてから後続を見る。こうしないと、
    ループ変数が常に「未知の値」になってしまう。
    """
    local_values = dict(values)
    for part in split_arithmetic_parts(expression):
        if not part.strip():
            continue
        match = ARITHMETIC_ASSIGNMENT_RE.match(part)
        if match:
            name, assigned = match.group(1), match.group(2)
            if assigned.strip():
                validate_arithmetic_expression(assigned, local_values)
            local_values[name] = assigned.strip() or "0"
            continue
        validate_arithmetic_expression(part, local_values)


def validate_nameref_target(target, values):
    if shell_word_is_dynamic(target):
        raise ShellScanError("nameref target is dynamic")
    match = re.match(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[(.*)\])?$", target, re.S)
    if not match:
        raise ShellScanError("unsupported nameref target")
    if match.group(1) is not None:
        validate_arithmetic_expression(match.group(1), values)


# ============================================================================
# コマンド走査
# ============================================================================

class CommandScanner:
    def __init__(self):
        # reasons は拒否理由、confirmations は実行前に確認を求める理由
        self.reasons = []
        self.confirmations = []
        # eval / trap / bash -c の内側からも、外側で定義された関数を辿れるようにする
        self.function_contexts = []
        self.active_functions = set()
        self.arithmetic_values = {}
        self.integer_variables = set()
        # declare -A の連想配列。添字は算術式ではなく文字列キーになる
        self.associative_variables = set()
        inherited_environment = inherited_execution_environment()
        self.shell_variables = inherited_environment.copy()
        self.exported_environment = inherited_environment.copy()
        # 一度でも export された変数名。値の追跡とは別に、増える一方で保持する。
        # 条件付き実行や関数呼び出しでは値を巻き戻すが、実際の bash では
        # 成功した export が後続コマンドへ残るため
        # (`export TF_CLI_ARGS_show=-json && terraform show`)
        self.tainted_environment = set()
        # `set -a` (allexport)。有効な間は、ただの代入も export と同じになる
        self.allexport = False
        # `set -k` (keyword)。後置された assignment word もコマンド環境へ載る
        self.keyword = False
        # xtrace 中は展開後の引数が標準エラーへ出る。機密値の存在確認例外にも効く。
        self.xtrace = False

    def check_arithmetic(self, expression):
        """算術式を検証し、未知の値に依存する場合は確認へ回す。

        同じコマンド内で代入された値は追跡できているため、ここで「未知」に
        なるのは環境から来た値か、そもそも未定義の値に限られる。
        日常的な `$((i + 1))` を解析不能で止めないよう、拒否ではなく確認にする。
        """
        try:
            validate_arithmetic_sequence(expression, self.arithmetic_values)
        except ArithmeticUnknownValueError:
            add_reason(self.confirmations, ARITHMETIC_UNKNOWN_CONFIRM_REASON)

    def record_arithmetic_assignment(self, assignment):
        match = ASSIGNMENT_PARTS_RE.match(assignment)
        if not match:
            return
        name, subscript, append, value = match.groups()
        if self.allexport:
            self.tainted_environment.add(name)
        key = name
        if subscript is not None:
            # 連想配列の添字は文字列キーであって算術式ではない
            if name not in self.associative_variables:
                self.check_arithmetic(subscript)
            key += "[" + subscript + "]"
        if append:
            if key not in self.arithmetic_values:
                value = UNQUOTED_EXPANSION_MARKER
            else:
                value = self.arithmetic_values[key] + value
        if name in self.integer_variables:
            self.check_arithmetic(value)
        self.arithmetic_values[key] = value

    def inspect_integer_declaration(self, arguments):
        integer_mode = None
        nameref_mode = None
        associative_mode = None
        export_mode = None
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument == "--":
                index += 1
                break
            if argument.startswith("-") and argument != "-":
                if "i" in argument[1:]:
                    integer_mode = True
                if "n" in argument[1:]:
                    nameref_mode = True
                if "A" in argument[1:]:
                    associative_mode = True
                if "x" in argument[1:]:
                    export_mode = True
                index += 1
                continue
            if argument.startswith("+") and argument != "+":
                if "i" in argument[1:]:
                    integer_mode = False
                if "n" in argument[1:]:
                    nameref_mode = False
                if "x" in argument[1:]:
                    export_mode = False
                index += 1
                continue
            break

        for operand in arguments[index:]:
            match = ASSIGNMENT_PARTS_RE.match(operand)
            name = match.group(1) if match else operand
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                continue
            if integer_mode is True:
                self.integer_variables.add(name)
            elif integer_mode is False:
                self.integer_variables.discard(name)
            if associative_mode is True:
                self.associative_variables.add(name)
            if match:
                if nameref_mode is True:
                    validate_nameref_target(match.group(4), self.arithmetic_values)
                self.record_arithmetic_assignment(operand)
                self.record_shell_assignment(operand)
            elif integer_mode is True:
                self.arithmetic_values.setdefault(name, "0")
            if export_mode is True:
                value = self.shell_variables.get(name)
                if not match and environment_value_reveals_credential(name, value):
                    add_reason(self.reasons, CREDENTIAL_VARIABLE_REASON)
                self.exported_environment[name] = (
                    value if value is not None else QUOTED_EXPANSION_MARKER
                )
                self.tainted_environment.add(name)
            elif export_mode is False:
                self.exported_environment.pop(name, None)

    def record_shell_assignment(self, assignment):
        match = ASSIGNMENT_PARTS_RE.match(assignment)
        if not match or match.group(2) is not None:
            return
        if assignment_reveals_credential(assignment):
            add_reason(self.reasons, CREDENTIAL_VARIABLE_REASON)
        name, _, append, value = match.groups()
        was_exported = (
            name in self.exported_environment
            or name in self.tainted_environment
        )
        if self.allexport or was_exported:
            # allexport の間は、ただの代入も export と同じ結果になる
            self.tainted_environment.add(name)
        if append:
            value = self.shell_variables.get(name, QUOTED_EXPANSION_MARKER) + value
        self.shell_variables[name] = value
        if self.allexport or was_exported:
            self.exported_environment[name] = value

    def inspect_export(self, arguments):
        unexport = False
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument == "--":
                index += 1
                break
            if argument.startswith("-") and argument != "-":
                unexport = unexport or "n" in argument[1:]
                index += 1
                continue
            break
        for operand in arguments[index:]:
            match = ASSIGNMENT_PARTS_RE.match(operand)
            name = match.group(1) if match else operand
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                continue
            if match:
                self.record_arithmetic_assignment(operand)
                self.record_shell_assignment(operand)
            elif not unexport and environment_value_reveals_credential(
                name, self.shell_variables.get(name)
            ):
                add_reason(self.reasons, CREDENTIAL_VARIABLE_REASON)
            if unexport:
                self.exported_environment.pop(name, None)
            else:
                value = self.shell_variables.get(name)
                self.exported_environment[name] = (
                    value if value is not None else QUOTED_EXPANSION_MARKER
                )
                self.tainted_environment.add(name)

    def split_leading_assignments(self, argv):
        index = 0
        while index < len(argv) and ASSIGNMENT_RE.match(argv[index]):
            index += 1
        return argv[:index], argv[index:]

    def set_allexport(self, enabled, persist):
        """allexport の有効・無効を、確実さに応じて反映する。

        有効化は常に取り込む (取り落とすと検査が緩む)。無効化は「確実に
        実行される位置」でだけ反映する。条件付き実行やサブシェルの中の
        `set +a` を信じると、実際には有効なまま検査だけが緩んでしまう。
        """
        if enabled:
            self.allexport = True
        elif persist:
            self.allexport = False

    def update_allexport(self, arguments, persist):
        """`set -a` / `set +a` / `set -o allexport` の切り替えを追う。

        `--` の後ろは位置パラメータの指定であってオプションではない。
        `set -- +a` は allexport を解除しないため、そこで読むのをやめる。
        """
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument in {"--", "-", "+"}:
                # ここから先は位置パラメータの指定
                break
            if argument in {"-o", "+o"}:
                if index + 1 < len(arguments) and arguments[index + 1] == "allexport":
                    self.set_allexport(argument == "-o", persist)
                    index += 2
                    continue
                index += 1
                continue
            if argument.startswith(("-", "+")) and len(argument) > 1:
                if "a" in argument[1:]:
                    self.set_allexport(argument.startswith("-"), persist)
                index += 1
                continue
            # `--` や位置パラメータが来たら、そこから先はオプションではない
            break

    def set_keyword(self, enabled, persist):
        """keyword の有効化は常に、無効化は確実な位置でだけ反映する。"""
        if enabled:
            self.keyword = True
        elif persist:
            self.keyword = False

    def update_keyword(self, arguments, persist):
        """`set -k` / `set +k` / `set -o keyword` の切り替えを追う。"""
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument in {"--", "-", "+"}:
                break
            if argument in {"-o", "+o"}:
                if index + 1 < len(arguments) and arguments[index + 1] == "keyword":
                    self.set_keyword(argument == "-o", persist)
                    index += 2
                    continue
                index += 1
                continue
            if argument.startswith(("-", "+")) and len(argument) > 1:
                if "k" in argument[1:]:
                    self.set_keyword(argument.startswith("-"), persist)
                index += 1
                continue
            break

    def update_xtrace(self, arguments, persist):
        """`set -x` / `set +x` / `set -o xtrace` の切り替えを追う。"""
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument in {"--", "-", "+"}:
                break
            if argument in {"-o", "+o"}:
                if index + 1 < len(arguments) and arguments[index + 1] == "xtrace":
                    if argument == "-o" or persist:
                        self.xtrace = argument == "-o"
                    index += 2
                    continue
                index += 1
                continue
            if argument.startswith(("-", "+")) and len(argument) > 1:
                if "x" in argument[1:] and (argument.startswith("-") or persist):
                    self.xtrace = argument.startswith("-")
                index += 1
                continue
            break

    def update_shopt_options(self, arguments, persist):
        """`shopt -s/-u -o` による set option の切り替えを追う。"""
        enabled = None
        shell_options = False
        names = []
        end_of_options = False
        for argument in arguments:
            if argument == "--":
                end_of_options = True
                continue
            if not end_of_options and argument.startswith("-") and argument != "-":
                flags = argument[1:]
                shell_options = shell_options or "o" in flags
                if "s" in flags:
                    enabled = True
                if "u" in flags:
                    enabled = False
                continue
            names.append(argument)
        if not shell_options or enabled is None:
            return
        for name in names:
            if command_word_is_dynamic(name):
                raise ShellScanError("dynamic shopt option name")
            if name == "allexport":
                self.set_allexport(enabled, persist)
            elif name == "keyword":
                self.set_keyword(enabled, persist)
            elif name == "xtrace" and (enabled or persist):
                self.xtrace = enabled

    def record_allexport_target(self, name, value):
        """allexport 中に組み込み等が設定した環境変数を記録する。"""
        if environment_value_reveals_credential(name, value):
            add_reason(self.reasons, CREDENTIAL_VARIABLE_REASON)
        tracked_value = value if value is not None else INHERITED_NONEMPTY_MARKER
        self.shell_variables[name] = tracked_value
        self.exported_environment[name] = tracked_value
        self.tainted_environment.add(name)

    def taint_arithmetic_targets(self, expression):
        """allexport 中の算術代入先を非空の環境変数として記録する。"""
        if not self.allexport:
            return
        for part in split_arithmetic_parts(expression):
            match = ARITHMETIC_MUTATION_NAME_RE.match(part)
            if match:
                self.record_allexport_target(
                    match.group(1), INHERITED_NONEMPTY_MARKER
                )

    def taint_builtin_targets(self, command, arguments):
        """allexport 中に、組み込みが代入する変数名を taint する。

        `readonly` / `read` / `declare` / `printf -v` などで作った変数も、
        allexport の間はそのまま環境変数になる。
        代入先を静的に決められない書き方は、取り落とすより閉じる。
        """
        if not self.allexport:
            return
        targets = []
        if command == "getopts" and len(arguments) >= 2:
            targets.append(arguments[1])
        elif command in {"for", "select"} and arguments:
            targets.append(arguments[0])
        name_options = ALLEXPORT_NAME_OPTIONS.get(command)
        if name_options is not None:
            targets.extend(option_values_with_joined(arguments, name_options))
        value_options = ALLEXPORT_ASSIGNING_BUILTINS.get(command)
        if value_options is not None:
            targets.extend(subcommand_words(arguments, value_options))
        for target in targets:
            match = ASSIGNMENT_PARTS_RE.match(target)
            name = (
                match.group(1)
                if match
                else target.split("=", 1)[0].split("[", 1)[0]
            )
            if command_word_is_dynamic(name):
                raise ShellScanError("allexport assignment target is dynamic")
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                if match:
                    value = match.group(4)
                    if match.group(3):
                        previous = self.shell_variables.get(name)
                        value = None if previous is None else previous + value
                elif command == "printf":
                    value = printf_static_assignment_value(arguments)
                elif command in {"readonly", "declare", "typeset", "local"}:
                    value = self.shell_variables.get(name)
                else:
                    value = None
                self.record_allexport_target(name, value)

    def call_environment_assignments(self, argv):
        """関数呼び出しの間だけ環境へ載る assignment word を返す。"""
        argv = strip_control_prefixes(argv)
        assignments, remaining = self.split_leading_assignments(argv)
        assignments = list(assignments)
        while remaining and command_basename(remaining[0]) == "time":
            remaining = unwrap_time(remaining[1:])
            nested, remaining = self.split_leading_assignments(remaining)
            assignments.extend(nested)
        if self.keyword and remaining:
            assignments.extend(
                argument
                for argument in remaining[1:]
                if ASSIGNMENT_RE.match(argument)
            )
        return assignments

    def apply_call_environment(self, argv):
        """関数呼び出しの一時環境を適用し、復元用の状態を返す。"""
        state = {}
        for assignment in self.call_environment_assignments(argv):
            match = ASSIGNMENT_PARTS_RE.match(assignment)
            if not match or match.group(2) is not None:
                continue
            name, _subscript, append, value = match.groups()
            if name not in state:
                state[name] = (
                    name in self.shell_variables,
                    self.shell_variables.get(name),
                    name in self.exported_environment,
                    self.exported_environment.get(name),
                    name in self.tainted_environment,
                )
            if append:
                previous = self.shell_variables.get(name)
                if previous is None and name in self.tainted_environment:
                    previous = INHERITED_NONEMPTY_MARKER
                value = (previous or "") + value
            self.shell_variables[name] = value
            self.exported_environment[name] = value
            self.tainted_environment.discard(name)
        return state

    def restore_call_environment(self, state):
        """関数呼び出しへ適用した一時環境だけを元へ戻す。"""
        for name, (
            had_shell_value,
            shell_value,
            had_exported_value,
            exported_value,
            was_tainted,
        ) in state.items():
            if had_shell_value:
                self.shell_variables[name] = shell_value
            else:
                self.shell_variables.pop(name, None)
            if had_exported_value:
                self.exported_environment[name] = exported_value
            else:
                self.exported_environment.pop(name, None)
            if was_tainted:
                self.tainted_environment.add(name)
            else:
                self.tainted_environment.discard(name)

    @staticmethod
    def changed_mapping_names(before, after):
        missing = object()
        return {
            name
            for name in set(before) | set(after)
            if before.get(name, missing) != after.get(name, missing)
        }

    def invalidate_environment_changes(
        self,
        shell_variables_before,
        exported_environment_before,
    ):
        """条件分岐や関数内で変化し得た値を unknown として残す。"""
        changed_shell = self.changed_mapping_names(
            shell_variables_before, self.shell_variables
        )
        changed_exported = self.changed_mapping_names(
            exported_environment_before, self.exported_environment
        )
        return changed_shell, changed_exported

    def apply_invalidated_environment(self, changed_shell, changed_exported):
        for name in changed_shell:
            self.shell_variables.pop(name, None)
        for name in changed_exported:
            self.exported_environment.pop(name, None)
            self.tainted_environment.add(name)

    def taint_assignment_names(self, assignments):
        """代入された変数名を、環境へ載りうるものとして覚える。"""
        for assignment in assignments:
            name = assignment.split("=", 1)[0]
            if "[" not in name:
                self.tainted_environment.add(name)

    def validate_assignments(self, assignments, persist):
        # `set -a` の間は、ただの代入もそのまま環境変数になる
        if self.allexport:
            self.taint_assignment_names(assignments)
        for assignment in assignments:
            if assignment_reveals_credential(assignment):
                add_reason(self.reasons, CREDENTIAL_VARIABLE_REASON)
            # `value="$GITHUB_TOKEN"` のように、秘密を別名へ移す代入も止める
            if contains_sensitive_parameter(assignment):
                add_reason(self.reasons, CREDENTIAL_VARIABLE_REASON)
            if persist:
                self.record_arithmetic_assignment(assignment)
                self.record_shell_assignment(assignment)
                continue
            match = ASSIGNMENT_PARTS_RE.match(assignment)
            if not match:
                continue
            name, subscript, _, value = match.groups()
            if subscript is not None and name not in self.associative_variables:
                self.check_arithmetic(subscript)
            if name in self.integer_variables:
                self.check_arithmetic(value)

    def inspect_arithmetic_expansions(self, argv):
        for argument in argv:
            for match in ARITHMETIC_EXPRESSION_MARKER_RE.finditer(argument):
                try:
                    expression = bytes.fromhex(match.group(1)).decode("utf-8")
                except (ValueError, UnicodeDecodeError):
                    raise ShellScanError("invalid arithmetic expression marker")
                self.check_arithmetic(expression)

    def inspect_parameter_assignments(self, argv):
        """代入演算子付き parameter expansion が変える変数を追跡する。"""
        for argument in argv:
            for marker in PARAMETER_ASSIGNMENT_MARKER_RE.finditer(argument):
                try:
                    parameter = bytes.fromhex(marker.group(1)).decode("utf-8")
                except (ValueError, UnicodeDecodeError):
                    raise ShellScanError("invalid parameter assignment marker")
                match = re.match(
                    r"^([A-Za-z_][A-Za-z0-9_]*)(:?=)(.*)$",
                    parameter,
                    re.S,
                )
                if not match:
                    raise ShellScanError("invalid parameter assignment")
                name, operator, value = match.groups()
                known = name in self.shell_variables
                if known and (operator == "=" or self.shell_variables[name]):
                    continue
                if not known and name in self.tainted_environment:
                    if self.allexport:
                        self.record_allexport_target(name, None)
                    continue
                self.record_shell_assignment(name + "=" + value)

    def inspect_arithmetic_commands(self, argv):
        found = False
        for argument in argv:
            for match in ARITHMETIC_COMMAND_MARKER_RE.finditer(argument):
                found = True
                try:
                    expression = bytes.fromhex(match.group(1)).decode("utf-8")
                    self.taint_arithmetic_targets(expression)
                    self.check_arithmetic(expression)
                except (ValueError, UnicodeDecodeError):
                    raise ShellScanError("invalid arithmetic command marker")
                except ShellScanError:
                    if not self.reasons:
                        raise
        if found:
            self.arithmetic_values.clear()

    def inspect_inherited_function_call(
        self,
        argv,
        depth,
        stdin_commands,
        stdin_is_external,
        inherited_contexts,
        persist_assignments=True,
    ):
        """外側のスコープで定義された関数の呼び出しなら、その本体を検査する。"""
        for context in reversed(inherited_contexts):
            (
                functions,
                definition_indexes,
                unit_argv,
                unit_stdin_commands,
                unit_stdin_is_external,
                unit_stdin_is_redirected,
                unit_persist_assignments,
                unit_after,
            ) = context
            name = static_function_call(argv, functions)
            if not name or name in self.active_functions:
                continue
            call_environment = self.apply_call_environment(argv)
            self.active_functions.add(name)
            try:
                self.inspect_function_call(
                    name,
                    functions,
                    definition_indexes,
                    unit_argv,
                    unit_stdin_commands,
                    unit_stdin_is_external,
                    unit_stdin_is_redirected,
                    unit_persist_assignments,
                    unit_after,
                    depth,
                    stdin_commands,
                    stdin_is_external,
                    persist_assignments=persist_assignments,
                )
            finally:
                self.active_functions.discard(name)
                self.restore_call_environment(call_environment)
            return True
        return False

    def inspect_function_call(
        self,
        name,
        functions,
        definition_indexes,
        unit_argv,
        unit_stdin_commands,
        unit_stdin_is_external,
        unit_stdin_is_redirected,
        unit_persist_assignments,
        unit_after,
        depth,
        stdin_commands,
        stdin_is_external,
        call_stack=None,
        persist_assignments=True,
    ):
        call_stack = call_stack or []
        if name in call_stack:
            raise ShellScanError("recursive function call is unsupported")
        body_indexes = functions[name]["body_indexes"]
        redirection_index = functions[name]["redirection_index"]
        options_before = (self.allexport, self.keyword, self.xtrace)
        localizes_options = any(
            len(unit_argv[body_index]) >= 2
            and command_basename(unit_argv[body_index][0]) == "local"
            and unit_argv[body_index][1] == "-"
            for body_index in body_indexes
        )
        if unit_stdin_is_redirected[redirection_index]:
            for body_index in body_indexes:
                body_argv = unit_argv[body_index]
                self.inspect_arithmetic_commands(body_argv)
                self.inspect_argv(
                    body_argv,
                    depth + 1,
                    unit_stdin_commands[redirection_index],
                    unit_stdin_is_external[redirection_index],
                    persist_assignments=(
                        persist_assignments
                        and unit_persist_assignments[body_index]
                    ),
                )
        for body_index in body_indexes:
            body_argv = unit_argv[body_index]
            self.inspect_arithmetic_commands(body_argv)
            self.inspect_argv(
                body_argv,
                depth + 1,
                unit_stdin_commands[body_index]
                if unit_stdin_is_redirected[body_index]
                else stdin_commands,
                unit_stdin_is_external[body_index]
                or (stdin_is_external and not unit_stdin_is_redirected[body_index]),
                persist_assignments=(
                    persist_assignments
                    and unit_persist_assignments[body_index]
                ),
            )
            nested_name = static_function_call(body_argv, functions)
            if nested_name:
                call_environment = self.apply_call_environment(body_argv)
                try:
                    self.inspect_function_call(
                        nested_name,
                        functions,
                        definition_indexes,
                        unit_argv,
                        unit_stdin_commands,
                        unit_stdin_is_external,
                        unit_stdin_is_redirected,
                        unit_persist_assignments,
                        unit_after,
                        depth + 1,
                        unit_stdin_commands[body_index]
                        if unit_stdin_is_redirected[body_index]
                        else stdin_commands,
                        unit_stdin_is_external[body_index]
                        or (
                            stdin_is_external
                            and not unit_stdin_is_redirected[body_index]
                        ),
                        call_stack + [name],
                        persist_assignments=(
                            persist_assignments
                            and unit_persist_assignments[body_index]
                        ),
                    )
                finally:
                    self.restore_call_environment(call_environment)

        for position, body_index in enumerate(body_indexes[:-1]):
            if unit_after[body_index] not in PIPE_OPERATORS:
                continue
            right_index = body_indexes[position + 1]
            if unit_stdin_is_redirected[right_index]:
                continue
            self.inspect_argv(
                unit_argv[right_index],
                depth + 1,
                stdin_is_external=True,
                persist_assignments=(
                    persist_assignments
                    and unit_persist_assignments[right_index]
                ),
            )
            nested_name = static_function_call(unit_argv[right_index], functions)
            if nested_name:
                call_environment = self.apply_call_environment(
                    unit_argv[right_index]
                )
                try:
                    self.inspect_function_call(
                        nested_name,
                        functions,
                        definition_indexes,
                        unit_argv,
                        unit_stdin_commands,
                        unit_stdin_is_external,
                        unit_stdin_is_redirected,
                        unit_persist_assignments,
                        unit_after,
                        depth + 1,
                        [],
                        True,
                        call_stack + [name],
                        persist_assignments=(
                            persist_assignments
                            and unit_persist_assignments[right_index]
                        ),
                    )
                finally:
                    self.restore_call_environment(call_environment)

        if localizes_options:
            self.allexport = self.allexport or options_before[0]
            self.keyword = self.keyword or options_before[1]
            self.xtrace = self.xtrace or options_before[2]

    def scan_child_shell(
        self,
        arguments,
        environment,
        tainted_environment,
        nested,
        depth,
        stdin_is_external=False,
        reject_function_definitions=False,
    ):
        """子 shell の起動時 option を、その内側の走査中だけ反映する。"""
        previous_options = (self.allexport, self.keyword, self.xtrace)
        self.allexport = shell_option_enabled(
            arguments,
            "allexport",
            "a",
            environment,
            tainted_environment,
        )
        self.keyword = shell_option_enabled(
            arguments,
            "keyword",
            "k",
            environment,
            tainted_environment,
        )
        self.xtrace = shell_option_enabled(
            arguments,
            "xtrace",
            "x",
            environment,
            tainted_environment,
        )
        try:
            self.scan(
                nested,
                depth,
                stdin_is_external,
                reject_function_definitions,
            )
        finally:
            self.allexport, self.keyword, self.xtrace = previous_options

    def scan(
        self,
        command,
        depth=0,
        inherited_stdin_is_external=False,
        reject_function_definitions=False,
    ):
        """外側のスコープで見えている関数を引き継いだうえで解析する。

        eval や trap、`bash -c` の中身は新しい scan として読み直すため、
        そのままでは呼び出し元で定義された関数の本体を検査できない。
        入れ子の間だけ関数表を積んでおき、抜けるときに元へ戻す。
        """
        inherited_contexts = list(self.function_contexts)
        try:
            return self._scan(
                command,
                depth,
                inherited_stdin_is_external,
                reject_function_definitions,
                inherited_contexts,
            )
        finally:
            del self.function_contexts[len(inherited_contexts) :]

    def _scan(
        self,
        command,
        depth,
        inherited_stdin_is_external,
        reject_function_definitions,
        inherited_contexts,
    ):
        if depth > 32:
            raise ShellScanError("nested shell command depth exceeded")

        without_heredocs, heredoc_bodies = strip_heredoc_bodies(command)
        without_heredocs = strip_shell_comments(
            remove_shell_line_continuations(without_heredocs)
        )
        sanitized, nested_commands = collect_substitutions(without_heredocs)
        if PROMPT_EXPANSION_MARKER in sanitized:
            add_reason(self.reasons, PROMPT_EXPANSION_REASON)
        for body, quoted in heredoc_bodies:
            if not quoted:
                heredoc_nested, _, _ = collect_heredoc_substitutions(body)
                nested_commands.extend(heredoc_nested)
                # 引用なしヒアドキュメントは本文中の展開が効く。
                # 本文はマーカー化を経ないため、変数名を直接見る
                if any(
                    parameter_is_sensitive(match.group(1))
                    and not (
                        body.startswith("${", match.start())
                        and body[match.end() :].startswith(("+", ":+"))
                    )
                    for match in HEREDOC_PARAMETER_RE.finditer(body)
                ):
                    add_reason(self.reasons, CREDENTIAL_VARIABLE_REASON)
        for nested in nested_commands:
            self.scan(nested, depth + 1, inherited_stdin_is_external)

        units = split_command_units(shell_tokens(sanitized))
        functions, definition_indexes = discover_function_definitions(units)
        if reject_function_definitions and functions:
            raise ShellScanError("function definition escapes the inspected input")
        unit_after = [unit["after"] for unit in units]
        unit_persist_assignments = [
            not command_unit_state_is_uncertain(unit) for unit in units
        ]
        resolved = []
        unit_argv = []
        unit_stdin_commands = []
        unit_stdin_is_external = []
        unit_stdin_is_redirected = []
        heredoc_index = 0
        raw_unit_argv = []
        for unit in units:
            (
                argv,
                stdin_commands,
                stdin_is_external,
                stdin_is_redirected,
                heredoc_index,
                input_file_operands,
                output_file_operands,
            ) = remove_redirections(unit["tokens"], heredoc_bodies, heredoc_index)
            for operand in input_file_operands:
                if argument_references_credential_path(
                    operand, path_context=True
                ):
                    add_reason(self.reasons, CREDENTIAL_FILE_REASON)
                    break
            for operand in output_file_operands:
                if argument_references_credential_path(
                    operand, path_context=True
                ):
                    add_reason(
                        self.confirmations, CREDENTIAL_FILE_CHANGE_CONFIRM_REASON
                    )
                    break
            raw_unit_argv.append(argv)
            unit_stdin_commands.append(stdin_commands)
            unit_stdin_is_external.append(stdin_is_external)
            unit_stdin_is_redirected.append(stdin_is_redirected)

        unit_argv = [strip_control_prefixes(argv) for argv in raw_unit_argv]
        if functions:
            # eval / trap / `bash -c` の内側から、この関数表を辿れるようにする
            self.function_contexts.append(
                (
                    functions,
                    definition_indexes,
                    unit_argv,
                    unit_stdin_commands,
                    unit_stdin_is_external,
                    unit_stdin_is_redirected,
                    unit_persist_assignments,
                    unit_after,
                )
            )
        for index, unit in enumerate(units):
            argv = raw_unit_argv[index]
            self.inspect_arithmetic_commands(argv)
            argv = unit_argv[index]
            if index in definition_indexes:
                resolved.append(None)
                continue
            state_is_uncertain = not unit_persist_assignments[index]
            if state_is_uncertain:
                self.arithmetic_values.clear()
            integer_variables_before = self.integer_variables.copy()
            shell_variables_before = self.shell_variables.copy()
            exported_environment_before = self.exported_environment.copy()
            resolved.append(
                self.inspect_argv(
                    argv,
                    depth,
                    unit_stdin_commands[index],
                    unit_stdin_is_external[index]
                    or (
                        inherited_stdin_is_external
                        and not unit_stdin_is_redirected[index]
                    ),
                    persist_assignments=not state_is_uncertain,
                )
            )
            function_name = static_function_call(argv, functions)
            if function_name or inherited_contexts:
                function_values_before = self.arithmetic_values.copy()
                function_integers_before = self.integer_variables.copy()
                function_shell_before = self.shell_variables.copy()
                function_environment_before = self.exported_environment.copy()
                call_stdin_is_external = unit_stdin_is_external[index] or (
                    inherited_stdin_is_external
                    and not unit_stdin_is_redirected[index]
                )
                if function_name:
                    call_environment = self.apply_call_environment(argv)
                    try:
                        self.inspect_function_call(
                            function_name,
                            functions,
                            definition_indexes,
                            unit_argv,
                            unit_stdin_commands,
                            unit_stdin_is_external,
                            unit_stdin_is_redirected,
                            unit_persist_assignments,
                            unit_after,
                            depth,
                            unit_stdin_commands[index],
                            call_stdin_is_external,
                            persist_assignments=not state_is_uncertain,
                        )
                    finally:
                        self.restore_call_environment(call_environment)
                else:
                    # eval / trap の内側から、外側で定義された関数を呼ぶ形
                    self.inspect_inherited_function_call(
                        argv,
                        depth,
                        unit_stdin_commands[index],
                        call_stdin_is_external,
                        inherited_contexts,
                        persist_assignments=not state_is_uncertain,
                    )
                changed_shell, changed_exported = (
                    self.invalidate_environment_changes(
                        function_shell_before,
                        function_environment_before,
                    )
                )
                # 関数内の代入は local かどうかで呼び出し元への影響が変わる。
                # 値は呼び出し前へ戻し、変わり得た名前だけ unknown として残す。
                self.arithmetic_values = function_values_before
                self.integer_variables = function_integers_before
                self.shell_variables = function_shell_before
                self.exported_environment = function_environment_before
                self.apply_invalidated_environment(
                    changed_shell,
                    changed_exported,
                )
            if state_is_uncertain:
                changed_shell, changed_exported = (
                    self.invalidate_environment_changes(
                        shell_variables_before,
                        exported_environment_before,
                    )
                )
                self.arithmetic_values.clear()
                # 実行されるか分からない位置で変わり得た値は unknown として残す。
                self.integer_variables = integer_variables_before
                self.shell_variables = shell_variables_before
                self.exported_environment = exported_environment_before
                self.apply_invalidated_environment(
                    changed_shell,
                    changed_exported,
                )

        if heredoc_index != len(heredoc_bodies):
            raise ShellScanError("heredoc body could not be associated")

        # `(bash) <<EOF` / `{ bash; } <<EOF` のリダイレクトは内部コマンドへ継承される
        for index in range(len(units)):
            if not unit_stdin_is_redirected[index]:
                continue
            start = compound_redirection_start(units, index)
            if start is None:
                continue
            for inner_index in range(start, index):
                if (
                    inner_index in definition_indexes
                    or unit_stdin_is_redirected[inner_index]
                ):
                    continue
                self.inspect_argv(
                    unit_argv[inner_index],
                    depth,
                    unit_stdin_commands[index],
                    unit_stdin_is_external[index],
                )
                function_name = static_function_call(unit_argv[inner_index], functions)
                if function_name:
                    call_environment = self.apply_call_environment(
                        unit_argv[inner_index]
                    )
                    try:
                        self.inspect_function_call(
                            function_name,
                            functions,
                            definition_indexes,
                            unit_argv,
                            unit_stdin_commands,
                            unit_stdin_is_external,
                            unit_stdin_is_redirected,
                            unit_persist_assignments,
                            unit_after,
                            depth,
                            unit_stdin_commands[index],
                            unit_stdin_is_external[index],
                            persist_assignments=False,
                        )
                    finally:
                        self.restore_call_environment(call_environment)

        for index, unit in enumerate(units):
            if index in definition_indexes:
                continue
            if unit["after"] not in PIPE_OPERATORS:
                continue
            left = resolved[index]
            for right_index in pipeline_consumer_indexes(units, index):
                if (
                    right_index in definition_indexes
                    or unit_stdin_is_redirected[right_index]
                ):
                    continue

                had_stdin_reason = SHELL_STDIN_REASON in self.reasons
                self.inspect_argv(
                    unit_argv[right_index],
                    depth,
                    stdin_is_external=True,
                )
                function_name = static_function_call(unit_argv[right_index], functions)
                if function_name:
                    call_environment = self.apply_call_environment(
                        unit_argv[right_index]
                    )
                    try:
                        self.inspect_function_call(
                            function_name,
                            functions,
                            definition_indexes,
                            unit_argv,
                            unit_stdin_commands,
                            unit_stdin_is_external,
                            unit_stdin_is_redirected,
                            unit_persist_assignments,
                            unit_after,
                            depth,
                            [],
                            True,
                            persist_assignments=False,
                        )
                    finally:
                        self.restore_call_environment(call_environment)
                nested_indexes = {
                    int(match.group(1))
                    for argument in unit_argv[right_index]
                    for match in NESTED_COMMAND_MARKER_RE.finditer(argument)
                }
                for nested_index in sorted(nested_indexes):
                    if nested_index >= len(nested_commands):
                        raise ShellScanError("nested command marker is invalid")
                    self.scan(
                        nested_commands[nested_index],
                        depth + 1,
                        inherited_stdin_is_external=True,
                    )
                gained_stdin_reason = (
                    not had_stdin_reason and SHELL_STDIN_REASON in self.reasons
                )
                if not gained_stdin_reason:
                    continue

                # `cat <<EOF | bash` は静的本文を直接検査できる
                if (
                    right_index == index + 1
                    and left
                    and left[0] == "cat"
                    and unit_stdin_commands[index]
                    and not unit_stdin_is_external[index]
                    and all(
                        argument == "-" or argument.startswith("-")
                        for argument in left[1]
                    )
                ):
                    self.reasons.remove(SHELL_STDIN_REASON)
                    for stdin_command in unit_stdin_commands[index]:
                        self.scan(stdin_command, depth + 1)
                else:
                    if left and left[0] in {"curl", "wget"}:
                        add_reason(self.reasons, PIPE_SHELL_REASON)
                break

    def inspect_argv(
        self,
        argv,
        depth,
        stdin_commands=None,
        stdin_is_external=False,
        persist_assignments=True,
    ):
        stdin_commands = stdin_commands or []
        original_argv = argv
        self.inspect_parameter_assignments(original_argv)
        effective_environment = self.exported_environment.copy()
        effective_tainted_environment = self.tainted_environment.copy()
        leading_assignments, argv = self.split_leading_assignments(argv)
        try:
            self.inspect_arithmetic_expansions(original_argv)
        except ShellScanError:
            if not self.reasons:
                raise
        if not argv:
            # 不確実な分岐でも一度記録し、呼び出し元で unknown へ畳む。
            self.validate_assignments(leading_assignments, persist=True)
            return None
        self.validate_assignments(leading_assignments, persist=False)
        # 前置代入も、直前の `export` で設定された値と同じくこのコマンドへ届く。
        # 両者を同じ環境として扱う (environment_names を参照)
        for assignment in leading_assignments:
            match = ASSIGNMENT_PARTS_RE.match(assignment)
            if match and match.group(2) is None:
                name, _subscript, append, value = match.groups()
                if append:
                    value = effective_environment.get(name, "") + value
                effective_environment[name] = value
                effective_tainted_environment.discard(name)

        if self.keyword:
            keyword_assignments = [
                argument for argument in argv[1:] if ASSIGNMENT_RE.match(argument)
            ]
            if keyword_assignments:
                self.validate_assignments(keyword_assignments, persist=False)
                argv = [argv[0]] + [
                    argument
                    for argument in argv[1:]
                    if not ASSIGNMENT_RE.match(argument)
                ]
                for assignment in keyword_assignments:
                    match = ASSIGNMENT_PARTS_RE.match(assignment)
                    if match and match.group(2) is None:
                        name, _subscript, append, value = match.groups()
                        if append:
                            value = effective_environment.get(name, "") + value
                        effective_environment[name] = value
                        effective_tainted_environment.discard(name)

        if ARITHMETIC_COMMAND_MARKER_RE.fullmatch(argv[0]):
            return None

        while argv:
            if command_word_is_dynamic(argv[0]):
                raise ShellScanError("dynamic command name")
            command = command_basename(argv[0])
            # ファイル由来のランチャーは大文字表記でも実体に解決されるため casefold する
            # (command / builtin / exec はシェル組み込みで大小文字を区別するため対象外)
            command_cf = command.casefold()
            arguments = argv[1:]

            if command == "command":
                argv = unwrap_command_options(arguments)
            elif command == "builtin":
                argv = unwrap_builtin_options(arguments)
            elif command == "exec":
                argv = unwrap_exec_options(arguments)
            elif command_cf == "env":
                env_assignments = []
                argv = unwrap_env(
                    arguments,
                    environment=effective_environment,
                    tainted_environment=effective_tainted_environment,
                    assignments=env_assignments,
                )
                self.validate_assignments(env_assignments, persist=False)
                # 実行コマンドを伴わない env は環境変数の一括出力になる
                if not any(
                    not ASSIGNMENT_RE.match(argument) for argument in argv
                ):
                    add_reason(self.reasons, ENV_DUMP_REASON)
            elif command_cf in {"nohup", "arch", "caffeinate"}:
                # arch / caffeinate はオプションの後に実行コマンドを取る
                # (値を取るオプションはスキップ済みなので、先頭の非オプション語まで進める)
                if command_cf in {"arch", "caffeinate"}:
                    launcher_values = (
                        {"-t"} if command_cf == "caffeinate" else {"-arch"}
                    )
                    argv = strip_launcher_options(arguments, launcher_values)
                else:
                    argv = arguments[1:] if arguments and arguments[0] == "--" else arguments
            elif command_cf == "nice":
                argv = unwrap_nice(arguments)
            elif command_cf == "time":
                argv = unwrap_time(arguments)
            elif command_cf == "timeout":
                argv = unwrap_timeout(arguments)
            elif command_cf == "xargs":
                argv = unwrap_xargs(arguments)
            else:
                break

            original_argv = argv
            wrapper_assignments, argv = self.split_leading_assignments(argv)
            try:
                self.inspect_arithmetic_expansions(original_argv)
            except ShellScanError:
                if not self.reasons:
                    raise
            if not argv:
                return None
            self.validate_assignments(wrapper_assignments, persist=False)
            for assignment in wrapper_assignments:
                match = ASSIGNMENT_PARTS_RE.match(assignment)
                if match and match.group(2) is None:
                    name, _subscript, append, value = match.groups()
                    if append:
                        value = effective_environment.get(name, "") + value
                    effective_environment[name] = value
                    effective_tainted_environment.discard(name)

        command = command_basename(argv[0])
        arguments = argv[1:]
        # macOS は大文字小文字を区別しないファイルシステムのため、/usr/bin/SECURITY
        # のような表記でも実体に解決される。ファイル由来コマンドの判定は casefold する
        command_cf = command.casefold()
        # このコマンドへ届きうる環境変数の名前。同じ argv の前置代入だけでなく、
        # 直前の `export` や `env` ラッパーで設定されたものも含む
        # (`export TF_CLI_ARGS_show=-json; terraform show` を取り落とさないため)。
        # 条件付き実行や関数の中の export は値を巻き戻すが、名前は taint として残す
        environment_names = set(effective_environment) | effective_tainted_environment
        pip_arguments = pip_invocation_arguments(command_cf, arguments)

        if command_cf == "rsync" and any(
            argument == "--password-file"
            or argument.startswith("--password-file=")
            for argument in arguments
        ):
            add_reason(self.reasons, CREDENTIAL_FILE_REASON)

        if command_cf == "security":
            decision = security_decision(arguments)
            if decision == "deny":
                add_reason(self.reasons, KEYCHAIN_SECRET_REASON)
            elif decision == "ask":
                add_reason(self.confirmations, KEYCHAIN_CONFIRM_REASON)
        elif command_cf in CREDENTIAL_TOOL_SUBCOMMANDS:
            decision = credential_tool_decision(command_cf, arguments)
            if decision == "deny":
                add_reason(self.reasons, CREDENTIAL_TOOL_REASON)
            elif decision == "ask":
                add_reason(self.confirmations, CREDENTIAL_TOOL_CONFIRM_REASON)
        elif pip_arguments is not None and pip_config_reveals_credentials(
            pip_arguments
        ):
            add_reason(self.reasons, SECRET_TOOL_REASON)
        elif command_cf == "pnpm" and pnpm_config_reveals_credentials(arguments):
            add_reason(self.reasons, SECRET_TOOL_REASON)
        elif command_cf == "npm" and npm_config_reveals_proxy_credentials(arguments):
            add_reason(self.reasons, ENV_DUMP_REASON)
        elif command_cf == "oc" and oc_registry_login_exposes_auth_file(
            arguments, environment_names
        ):
            add_reason(self.reasons, SECRET_TOOL_REASON)
        elif process_inspection_reveals_credentials(command_cf, arguments):
            add_reason(self.reasons, PROCESS_INSPECTION_REASON)
        elif shell_history_reveals_credentials(command_cf, arguments):
            add_reason(self.reasons, SHELL_HISTORY_REASON)
        elif command_cf.startswith("docker-credential-") or command_cf.startswith(
            "git-credential-"
        ):
            # credential helper の直接実行はトークンの取得そのものになる
            add_reason(self.reasons, CREDENTIAL_TOOL_REASON)
        elif command_cf in ENV_DUMP_COMMANDS and env_dump_arguments(
            command_cf, arguments
        ):
            add_reason(self.reasons, ENV_DUMP_REASON)
        elif command_cf == "gh":
            # 値を取るオプションを消費してから、位置引数 (サブコマンド) の並びを見る
            candidates = subcommand_word_candidates(arguments, GH_VALUE_OPTIONS, 2)
            token_help = exact_local_help_invocation(
                arguments,
                {
                    ("auth", "token"),
                    ("auth", "git-credential"),
                    ("auth", "status", "--show-token"),
                    ("auth", "status", "--show-token=true"),
                },
            )
            subcommand_help = bool(
                arguments
                and arguments[-1] in {"--help", "-h"}
                and any(words for words in candidates)
            )
            local_help = token_help or subcommand_help
            shows_token = boolean_option_enabled(
                arguments, {"--show-token"}, short_flags={"t"}
            )
            if not token_help and (
                subcommand_candidates_match(candidates, ("auth", "token"))
                or subcommand_candidates_match(candidates, ("auth", "git-credential"))
                or (
                    subcommand_candidates_match(candidates, ("auth", "status"))
                    and shows_token
                )
                or (
                    subcommand_candidates_match(candidates, ("config", "get"))
                    and any("oauth_token" in words for words in candidates)
                )
            ):
                add_reason(self.reasons, GH_TOKEN_REASON)
            if gh_api_reveals_secret(candidates, arguments):
                add_reason(self.reasons, GH_API_SECRET_REASON)
            # `--` の後ろは git / ssh のオプションになり、ここでは検査できない
            if not local_help and "--" in arguments and any(
                subcommand_candidates_match(candidates, expected)
                for expected in GH_PASSTHROUGH_SUBCOMMANDS
            ):
                add_reason(self.reasons, GH_PASSTHROUGH_REASON)
            if not local_help and any(
                subcommand_candidates_match(candidates, expected)
                for expected in GH_CONFIRM_SUBCOMMANDS
            ):
                add_reason(self.confirmations, AUTH_CHANGE_CONFIRM_REASON)
            # 読み取りと分かる形以外は、外部の状態を変えうるものとして確認へ回す
            if not local_help and gh_changes_external_state(arguments):
                add_reason(self.confirmations, EXTERNAL_STATE_CONFIRM_REASON)
            if gh_writes_through_api(candidates, arguments):
                # gh api は外部の状態をそのまま書き換えられる
                add_reason(self.confirmations, DESTRUCTIVE_CONFIRM_REASON)
            if environment_override_is_nonempty(
                GH_EXEC_ENV_VARS,
                effective_environment,
                effective_tainted_environment,
            ):
                add_reason(self.reasons, GIT_EXEC_INJECTION_REASON)
        elif command_cf in {"terraform", "terragrunt"}:
            # console は file() などで任意のファイルを読める
            # wrapper (`stack run state pull` など) を剥がしても語数が足りるよう、
            # 打ち切りを wrapper の段数ぶん深くしてから剥がす
            candidates = strip_terraform_wrappers(
                subcommand_word_candidates(arguments, TERRAFORM_VALUE_OPTIONS, 5)
            )
            terraform_help = exact_local_help_invocation(
                arguments,
                {
                    ("console",),
                    ("state", "pull"),
                    ("state", "show"),
                    ("output", "-raw"),
                    ("output", "-json"),
                    ("show", "-json"),
                },
            )
            if file_option_values(arguments, TERRAFORM_EXEC_OPTIONS):
                add_reason(self.reasons, TERRAFORM_EXEC_OPTION_REASON)
            # オプションと同じことを環境変数でもできる。
            # TF_CLI_ARGS_show=-json のように、コマンドラインに現れない
            # 秘密出力オプションを後から差し込める
            if environment_override_is_nonempty(
                TERRAFORM_EXEC_ENV_VARS,
                effective_environment,
                effective_tainted_environment,
                TERRAFORM_EXEC_ENV_PREFIXES,
            ):
                add_reason(self.reasons, TERRAFORM_EXEC_ENV_REASON)
            if not terraform_help and terraform_reveals_secret(candidates, arguments):
                add_reason(self.reasons, TERRAFORM_SECRET_REASON)
            if not terraform_help and any(
                subcommand_candidates_match(candidates, expected)
                for expected in TERRAFORM_DENIED_SUBCOMMANDS
            ):
                add_reason(self.reasons, TERRAFORM_CONSOLE_REASON)
            # `workspace select -or-create` は new と同じく workspace を作る
            creates_workspace = subcommand_candidates_match(
                candidates, ("workspace", "select")
            ) and boolean_option_enabled(arguments, {"-or-create", "--or-create"})
            if creates_workspace or any(
                subcommand_candidates_match(candidates, expected)
                for expected in TERRAFORM_CONFIRM_SUBCOMMANDS
            ):
                add_reason(self.confirmations, AUTH_CHANGE_CONFIRM_REASON)
        elif command_cf == "aws":
            candidates = subcommand_word_candidates(arguments, AWS_VALUE_OPTIONS, 4)
            exits_after_version = aws_global_version_requested(arguments)
            exposes_debug_trace = aws_option_enabled(
                arguments, AWS_DEBUG_OPTIONS
            ) and not exits_after_version
            generates_cli_skeleton = aws_cli_skeleton_requested(arguments)
            uses_safe_dry_run = aws_dry_run_enabled(arguments)
            credential_matches = {
                expected
                for expected in AWS_CREDENTIAL_SUBCOMMANDS
                if subcommand_candidates_match(candidates, expected)
            }
            unsafe_credential_matches = {
                expected
                for expected in credential_matches
                if not (
                    exits_after_version
                    or aws_help_invocation(arguments, expected)
                    or (
                        generates_cli_skeleton
                        and expected not in AWS_CUSTOM_CREDENTIAL_SUBCOMMANDS
                    )
                    or (
                        uses_safe_dry_run
                        and expected in AWS_SAFE_DRY_RUN_SUBCOMMANDS
                    )
                )
            }
            decrypt_subcommands = {
                expected
                for expected in AWS_SSM_DECRYPT_SUBCOMMANDS
                if subcommand_candidates_match(candidates, expected)
            }
            decrypts_parameter = bool(
                decrypt_subcommands
            ) and aws_last_boolean_option_enabled(
                arguments,
                AWS_SSM_WITH_DECRYPTION_OPTIONS,
                AWS_SSM_NO_WITH_DECRYPTION_OPTIONS,
            )
            exposes_decrypted_parameter = decrypts_parameter and not (
                exits_after_version or generates_cli_skeleton
            )
            exposes_codeartifact_login_token = subcommand_candidates_match(
                candidates, ("codeartifact", "login")
            ) and aws_option_enabled(arguments, AWS_CODEARTIFACT_DRY_RUN_OPTIONS)
            exposes_codeartifact_login_token = (
                exposes_codeartifact_login_token and not exits_after_version
            )
            deploy_iam_user_arn = aws_last_option_value(
                arguments, AWS_DEPLOY_IAM_USER_ARN_OPTIONS
            )
            deploy_register_creates_access_key = subcommand_candidates_match(
                candidates, ("deploy", "register")
            ) and (
                not deploy_iam_user_arn
                or contains_expansion_or_marker(deploy_iam_user_arn)
            )
            deploy_register_creates_access_key = (
                deploy_register_creates_access_key
                and not exits_after_version
                and not aws_help_invocation(arguments, ("deploy", "register"))
            )
            # credential 設定は get で出力させず、set の平文 argv にも載せない
            reads_or_writes_configured_secret = any(
                words[:2] in {("configure", "get"), ("configure", "set")}
                and len(words) > 2
                and aws_configure_setting_is_secret(words[2])
                for words in candidates
            )
            if reads_or_writes_configured_secret and not exits_after_version:
                add_reason(self.reasons, AWS_CONFIGURE_SECRET_REASON)
            if aws_external_pager_is_nonempty(
                arguments,
                candidates,
                effective_environment,
                effective_tainted_environment,
            ):
                add_reason(self.reasons, AWS_PAGER_REASON)
            if (
                unsafe_credential_matches
                or exposes_debug_trace
                or exposes_decrypted_parameter
                or exposes_codeartifact_login_token
                or deploy_register_creates_access_key
            ):
                add_reason(self.reasons, AWS_EXPORT_REASON)
            if any(
                subcommand_candidates_match(candidates, expected)
                and not exits_after_version
                and not aws_help_invocation(arguments, expected)
                for expected in AWS_CONFIRM_SUBCOMMANDS
            ):
                add_reason(self.confirmations, AUTH_CHANGE_CONFIRM_REASON)
        elif command_cf == "git":
            # git credential fill はヘルパー経由でトークンを標準出力へ出す
            # (内部利用の git push / git fetch は helper を呼ぶだけなので対象外)
            candidates = subcommand_word_candidates(arguments, GIT_VALUE_OPTIONS, 3)
            if subcommand_candidates_match(candidates, ("credential", "fill")) or any(
                words and words[0].startswith("credential-") for words in candidates
            ):
                add_reason(self.reasons, GH_TOKEN_REASON)
            if git_config_reveals_credentials(arguments):
                add_reason(self.reasons, GIT_CONFIG_SECRET_REASON)
            # git -c core.pager=<コマンド> のように、git 自身に外部コマンドを
            # 起動させる指定は、ここまでの検査をすべて迂回できる
            if (
                git_injects_command(arguments, ())
                or environment_override_is_nonempty(
                    GIT_EXEC_ENV_VARS,
                    effective_environment,
                    effective_tainted_environment,
                    GIT_EXEC_ENV_PREFIXES,
                )
                or file_option_values(arguments, GIT_EXEC_PATH_OPTIONS)
            ):
                add_reason(self.reasons, GIT_EXEC_INJECTION_REASON)
            # `git submodule foreach '<コマンド>'` は文字列を shell へ渡す
            for expected in GIT_SHELL_STRING_SUBCOMMANDS:
                for words in candidates:
                    if tuple(words[: len(expected)]) != expected:
                        continue
                    for wrapped in words[len(expected) :]:
                        if XARGS_REPLACEMENT_MARKER in wrapped:
                            raise ShellScanError("xargs replacement in git foreach")
                        self.scan(wrapped, depth + 1, stdin_is_external)
            # `git show HEAD:terraform.tfstate` のような <rev>:<path> 指定。
            # remote URL / refspec にも `:` があるため、object name を読む操作だけで見る。
            if any(
                words and words[0] in GIT_REVISION_PATH_SUBCOMMANDS
                for words in candidates
            ) and not git_cat_file_only_reads_metadata(candidates, arguments):
                for argument in arguments:
                    if argument.startswith("-") or "://" in argument:
                        continue
                    _, separator, tracked_path = argument.partition(":")
                    tracked_paths = [tracked_path] if separator else []
                    stage_path = re.match(r"^:[0-3]:(.+)$", argument)
                    if stage_path:
                        tracked_paths.append(stage_path.group(1))
                    if any(
                        argument_references_credential_path(
                            candidate, path_context=True
                        )
                        for candidate in tracked_paths
                    ):
                        add_reason(self.reasons, CREDENTIAL_FILE_REASON)
                        break
            if any(
                argument_references_credential_path(
                    pathspec, path_context=True
                )
                for pathspec in git_literal_content_pathspecs(arguments)
            ):
                add_reason(self.reasons, CREDENTIAL_FILE_REASON)
            # `git config core.hooksPath ...` は設定ファイルへ残るため、
            # 後続の git からも効いてしまう
            writes_config, written_keys = git_config_written_keys(arguments)
            if writes_config:
                if any(config_key_injects_command(key) for key in written_keys):
                    add_reason(self.reasons, GIT_EXEC_INJECTION_REASON)
                else:
                    add_reason(self.confirmations, EXTERNAL_STATE_CONFIRM_REASON)
            if (
                git_needs_confirmation(candidates, arguments)
                or git_push_needs_confirmation(arguments)
                or git_config_needs_confirmation(arguments)
            ):
                add_reason(self.confirmations, DESTRUCTIVE_CONFIRM_REASON)
        elif command_cf in CONTAINER_COMMANDS:
            # AI 専用の隔離デーモンを用意するまでの暫定 guard として、
            # ホスト側の認証情報がコンテナへ渡る経路をここで塞ぐ。
            # run / create だけでなく compose と build も同じ経路になる
            # docker は未知のオプションが多く、両解釈への展開は候補が爆発する。
            # 秘密の受け渡しはオプション名で判定できるため、ここは素直に解釈する
            words = subcommand_words(arguments, DOCKER_VALUE_OPTIONS)
            decision_words = subcommand_words(
                arguments,
                DOCKER_VALUE_OPTIONS | DOCKER_EXEC_CHILD_VALUE_OPTIONS,
            )
            if words[:1] == ["compose"]:
                decision_words = subcommand_words(
                    arguments,
                    DOCKER_VALUE_OPTIONS
                    | DOCKER_EXEC_CHILD_VALUE_OPTIONS
                    | DOCKER_COMPOSE_VALUE_OPTIONS,
                )
            build_words = docker_build_subcommand_words(arguments)
            docker_arguments = container_option_arguments(arguments)
            references = container_host_references(
                docker_arguments, words, build_words, decision_words
            )
            for source in references:
                if mount_is_sensitive(source) or argument_is_credential_path(
                    source, path_context=True
                ):
                    add_reason(self.reasons, DOCKER_MOUNT_REASON)
                    break
            if any(
                argument_is_credential_path(source, path_context=True)
                for source in container_cp_container_source_paths(docker_arguments)
            ):
                add_reason(self.reasons, DOCKER_OUTPUT_REASON)
            if any(
                directory_ingress_references_credentials(reference)
                for reference in container_directory_ingress_references(
                    docker_arguments, words, build_words, decision_words
                )
            ):
                add_reason(self.reasons, DOCKER_MOUNT_REASON)
            for name, value in container_environment_specs(docker_arguments):
                if container_environment_spec_reveals_secret(name, value):
                    add_reason(self.reasons, DOCKER_ENV_REASON)
                    break
            if container_uses_host_file_secret(docker_arguments):
                add_reason(self.reasons, DOCKER_MOUNT_REASON)
            if container_uses_host_environment_secret(docker_arguments):
                add_reason(self.reasons, DOCKER_ENV_REASON)
            if container_forwards_ssh_agent(docker_arguments):
                add_reason(self.reasons, DOCKER_SSH_REASON)
            if container_grants_filesystem_entitlement(docker_arguments):
                add_reason(self.reasons, DOCKER_ENTITLEMENT_REASON)
            # socket を渡したコンテナは、この検査を通らないマウントを作れる
            if container_exposes_api_socket(docker_arguments) or any(
                reference_is_socket(source) for source in references
            ):
                add_reason(self.reasons, DOCKER_SOCKET_REASON)
            if environment_override_is_nonempty(
                DOCKER_EXEC_ENV_VARS,
                effective_environment,
                effective_tainted_environment,
            ):
                add_reason(self.reasons, DOCKER_EXEC_ENV_REASON)
            if environment_override_is_nonempty(
                DOCKER_CREDENTIAL_ENV_VARS,
                effective_environment,
                effective_tainted_environment,
            ):
                add_reason(self.reasons, DOCKER_ENV_REASON)
            if environment_override_is_nonempty(
                DOCKER_SSH_ENV_VARS,
                effective_environment,
                effective_tainted_environment,
            ):
                add_reason(self.reasons, DOCKER_SSH_REASON)
            if container_reveals_secret(decision_words, arguments) or (
                container_child_reveals_secret(arguments)
            ) or container_debug_reveals_secret(docker_arguments):
                add_reason(self.reasons, DOCKER_OUTPUT_REASON)
            # 読み取りと分かる形以外は、外部やホストの状態を変えうるものとみなす
            if container_changes_state(decision_words, arguments):
                add_reason(self.confirmations, EXTERNAL_STATE_CONFIRM_REASON)

        # インタプリタへ直接渡したコードはシェルとして解析できない。
        # 明らかに外部コマンドを起動する形は拒否し、それ以外も
        # 文字列連結などで難読化できる以上「検査済み」とは言えないため確認へ回す。
        # python3.13 のような版数付きの名前でも検査が外れないよう正規化する
        interpreter_cf = interpreter_name(command_cf)
        if interpreter_cf in INTERPRETER_CODE_OPTIONS:
            code_arguments = interpreter_code_arguments(interpreter_cf, arguments)
            reads_stdin_code = interpreter_reads_stdin_script(interpreter_cf, arguments)
            if reads_stdin_code:
                # ヒアドキュメントなど、内容が静的に分かる標準入力は検査できる
                code_arguments = code_arguments + list(stdin_commands)
            if code_references_credential_path(code_arguments):
                add_reason(self.reasons, CREDENTIAL_FILE_REASON)
            elif code_starts_process(interpreter_cf, code_arguments):
                add_reason(self.reasons, INTERPRETER_EXEC_REASON)
            elif code_builds_target_dynamically(code_arguments):
                add_reason(self.reasons, INTERPRETER_OBFUSCATION_REASON)
            elif reads_stdin_code and stdin_is_external:
                # 内容を見られない標準入力からスクリプトを読む形
                add_reason(self.confirmations, INTERPRETER_CODE_CONFIRM_REASON)
            elif code_arguments and interpreter_cf not in INTERPRETER_POSITIONAL_CODE:
                # awk はパイプラインの整形で日常的に使うため、確認までは求めない
                # (外部コマンドの起動は上の判定で拒否する)
                add_reason(self.confirmations, INTERPRETER_CODE_CONFIRM_REASON)

        # `set -a` (allexport) の間は、ただの代入もそのまま環境変数になる
        if command == "set":
            self.update_allexport(arguments, persist_assignments)
            self.update_keyword(arguments, persist_assignments)
            self.update_xtrace(arguments, persist_assignments)
        elif command == "shopt":
            self.update_shopt_options(arguments, persist_assignments)
        # 組み込みによる代入も、allexport の間は環境変数になる
        self.taint_builtin_targets(command, arguments)

        # 受け取った文字列を shell として実行するラッパー (`npx -c` など)。
        # 中身はここまでの検査を丸ごと迂回できるため、解析し直す
        for wrapped in shell_string_wrapper_commands(command_cf, arguments):
            if XARGS_REPLACEMENT_MARKER in wrapped:
                raise ShellScanError("xargs replacement in wrapper command string")
            self.scan(wrapped, depth + 1, stdin_is_external)
        # `mise exec -- cmd` / `script out.txt cmd` / `npm exec -- cmd` のように、
        # 位置引数をそのまま別プロセスの argv として起こす形
        for wrapped_argv in (
            argv_wrapper_commands(command_cf, arguments)
            + kubectl_remote_child_argv(command_cf, arguments)
            + script_command_argv(command_cf, arguments)
            + package_runner_argv(command_cf, arguments)
        ):
            self.inspect_argv(wrapped_argv, depth + 1)

        # npm_config_call / script_shell はコマンドそのものを差し替える。
        if command_cf in PACKAGE_RUNNER_SUBCOMMANDS and any(
            name.casefold() in NPM_EXEC_ENV_NAMES
            and environment_value_state(
                name, effective_environment, effective_tainted_environment
            )
            in {"nonempty", "unknown"}
            for name in environment_names
        ):
            add_reason(self.reasons, NPM_CONFIG_ENV_REASON)

        # エディタ・sqlite3 から shell へ抜ける指定
        if editor_shell_escape(command_cf, arguments):
            add_reason(self.reasons, EDITOR_SHELL_ESCAPE_REASON)

        # vault / gcloud / az / kubectl など、認証情報を標準出力へ返すコマンド
        if secret_tool_invocation(command_cf, arguments):
            add_reason(self.reasons, SECRET_TOOL_REASON)

        if command_cf in {"kubectl", "oc"}:
            cp_indexes = kubectl_cp_operand_indexes(arguments)
            if len(cp_indexes) == 2:
                source = kubectl_cp_operand_path(arguments[cp_indexes[0]])
                destination = kubectl_cp_operand_path(arguments[cp_indexes[1]])
                if argument_references_credential_path(
                    source, path_context=True
                ):
                    add_reason(self.reasons, CREDENTIAL_FILE_REASON)
                if argument_references_credential_path(
                    destination, path_context=True
                ):
                    add_reason(
                        self.confirmations, CREDENTIAL_FILE_CHANGE_CONFIRM_REASON
                    )

        # gcloud / az / vault の認証状態を変える操作
        auth_change = AUTH_CHANGE_SUBCOMMANDS.get(command_cf)
        if auth_change is not None:
            value_options, subcommands = auth_change
            auth_candidates = subcommand_word_candidates(arguments, value_options)
            auth_help = bool(
                arguments
                and arguments[-1] in {"--help", "-h"}
                and any(
                    subcommand_candidates_match(auth_candidates, expected)
                    for expected in subcommands
                )
            )
            if not auth_help and any(
                subcommand_candidates_match(auth_candidates, expected)
                for expected in subcommands
            ):
                add_reason(self.confirmations, AUTH_CHANGE_CONFIRM_REASON)

        # CLI が明示的にローカルファイルを読む引数は、外部送信や tool output
        # への露出につながるため、パスとして検査する。
        if any(
            argument_references_credential_path(reference, path_context=True)
            for reference in command_file_ingress_references(command_cf, arguments)
        ):
            add_reason(self.reasons, CREDENTIAL_FILE_REASON)

        if command_cf == "tar":
            tar_state = tar_argument_state(arguments)
            if (
                tar_state["create"]
                and tar_state["archive"] not in {None, "-"}
                and argument_references_credential_path(
                    tar_state["archive"], path_context=True
                )
            ):
                add_reason(
                    self.confirmations, CREDENTIAL_FILE_CHANGE_CONFIRM_REASON
                )

        # その他の引数も、パス表記や既知のファイル名を含む場合は拒否する。
        # bare word は package / repo / target 名として使えるよう、存在するという
        # 理由だけではローカルパス扱いしない。
        if not credential_path_existence_check(command_cf, arguments):
            read_path_indexes, changed_path_indexes, non_file_indexes = (
                credential_path_argument_roles(command_cf, arguments)
            )
            if any(
                argument_references_credential_path(
                    credential_path_argument_value(
                        command_cf, arguments[index]
                    ),
                    path_context=True,
                )
                for index in read_path_indexes
            ):
                add_reason(self.reasons, CREDENTIAL_FILE_REASON)
            if any(
                argument_references_credential_path(
                    credential_path_argument_value(
                        command_cf, arguments[index]
                    ),
                    path_context=True,
                )
                for index in changed_path_indexes
            ):
                add_reason(
                    self.confirmations, CREDENTIAL_FILE_CHANGE_CONFIRM_REASON
                )
            ignored_path_indexes = credential_identifier_argument_indexes(
                command_cf, arguments
            )
            ignored_path_indexes |= (
                read_path_indexes | changed_path_indexes | non_file_indexes
            )
            if command_cf in CONTAINER_COMMANDS:
                docker_arguments = container_option_arguments(arguments)
                ignored_path_indexes |= (
                    container_mount_argument_indexes(docker_arguments)
                    | container_environment_argument_indexes(docker_arguments)
                    | container_cp_destination_argument_indexes(arguments)
                )
            for index, argument in enumerate(arguments):
                if index in ignored_path_indexes:
                    continue
                if argument_references_credential_path(argument):
                    add_reason(self.reasons, CREDENTIAL_FILE_REASON)
                    break

        # 認証情報を持つ環境変数の値を、そのまま引数へ展開する操作。
        # tool output やログへ平文が載るため、コマンドの種類を問わず拒否する。
        # 引数だけでなく、前置代入 (`env NAME="$TOKEN" cmd`) と、
        # 内容が分かる標準入力 (here-string / ヒアドキュメント) も見る
        sensitive_arguments = (
            []
            if not self.xtrace
            and sensitive_test_only_checks_presence(command, arguments)
            else list(arguments)
        )
        for value in (
            sensitive_arguments
            + list(effective_environment.values())
            + list(stdin_commands)
        ):
            if contains_sensitive_parameter(value):
                add_reason(self.reasons, CREDENTIAL_VARIABLE_REASON)
                break

        if command_cf == "sudo":
            add_reason(self.reasons, SUDO_REASON)
        elif command_cf == "rm":
            for argument in arguments:
                if argument == "--":
                    break
                if command_word_is_dynamic(argument):
                    raise ShellScanError("dynamic rm option")
            if rm_has_recursive_force(arguments):
                add_reason(self.confirmations, RM_CONFIRM_REASON)
        elif command == "hash":
            if hash_rebinds_command(arguments):
                add_reason(self.reasons, HASH_REBIND_REASON)
        elif command == "eval":
            if arguments and arguments[0] == "--":
                arguments = arguments[1:]
            if arguments:
                if any(XARGS_REPLACEMENT_MARKER in argument for argument in arguments):
                    raise ShellScanError("xargs replacement in eval string")
                self.scan(
                    " ".join(arguments),
                    depth + 1,
                    stdin_is_external,
                    reject_function_definitions=True,
                )
        elif command == "let":
            for expression in arguments:
                try:
                    self.taint_arithmetic_targets(expression)
                    self.check_arithmetic(expression)
                except ShellScanError:
                    if not self.reasons:
                        raise
            self.arithmetic_values.clear()
        elif command == "export":
            # 危ないのは「変数名が展開で決まる」場合で、値が展開なのは普通の使い方
            if any(
                command_word_is_dynamic(argument.split("=", 1)[0])
                for argument in arguments
            ):
                raise ShellScanError("dynamic export operand")
            self.inspect_export(arguments)
        elif command == "readonly":
            if any(
                command_word_is_dynamic(argument.split("=", 1)[0])
                for argument in arguments
            ):
                raise ShellScanError("dynamic readonly operand")
            for argument in arguments:
                if ASSIGNMENT_RE.match(argument):
                    self.record_arithmetic_assignment(argument)
                    self.record_shell_assignment(argument)
        elif command == "unset":
            unset_arguments = [
                argument
                for argument in arguments
                if argument == "--" or not argument.startswith("-")
            ]
            if any(command_word_is_dynamic(argument) for argument in unset_arguments):
                raise ShellScanError("dynamic unset operand")
            for name in unset_arguments:
                if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                    continue
                self.arithmetic_values.pop(name, None)
                self.integer_variables.discard(name)
                self.shell_variables.pop(name, None)
                self.exported_environment.pop(name, None)
                if persist_assignments:
                    # 確実に実行される unset は、環境からも確かに消える
                    self.tainted_environment.discard(name)
        elif command in {"declare", "typeset", "local"}:
            self.inspect_integer_declaration(arguments)
        elif command == "[[":
            arithmetic_comparisons = {"-eq", "-ne", "-lt", "-le", "-gt", "-ge"}
            for index, argument in enumerate(arguments):
                if argument not in arithmetic_comparisons:
                    continue
                if index == 0 or index + 1 >= len(arguments):
                    raise ShellScanError("incomplete arithmetic comparison")
                self.check_arithmetic(arguments[index - 1])
                self.check_arithmetic(arguments[index + 1])
        elif command in SHELL_COMMANDS:
            if shell_structure_depends_on_xargs_replacement(arguments):
                raise ShellScanError(
                    "xargs replacement controls shell option or script operand"
                )
            if shell_structure_depends_on_dynamic_expansion(arguments):
                raise ShellScanError(
                    "dynamic expansion controls shell option or script operand"
                )
            for startup_input in shell_startup_inputs(
                command,
                arguments,
                effective_environment,
                effective_tainted_environment,
            ):
                if shell_word_is_dynamic(startup_input):
                    raise ShellScanError("dynamic shell startup input")
                if startup_input in SHELL_STDIN_PATHS:
                    if stdin_is_external:
                        add_reason(self.reasons, SHELL_STDIN_REASON)
                    for stdin_command in stdin_commands:
                        self.scan_child_shell(
                            arguments,
                            effective_environment,
                            effective_tainted_environment,
                            stdin_command,
                            depth + 1,
                            stdin_is_external=False,
                            reject_function_definitions=True,
                        )
                elif (
                    NON_STDIN_FD_PATH_RE.match(startup_input)
                    or "__process_substitution__" in startup_input
                ):
                    add_reason(self.reasons, SHELL_STDIN_REASON)
                else:
                    raise ShellScanError("shell startup input cannot be inspected")
            nested = shell_command_string(arguments)
            if nested is not None:
                if XARGS_REPLACEMENT_MARKER in nested:
                    raise ShellScanError("xargs replacement in shell command string")
                self.scan_child_shell(
                    arguments,
                    effective_environment,
                    effective_tainted_environment,
                    nested,
                    depth + 1,
                    stdin_is_external,
                )
            elif any(NON_STDIN_FD_PATH_RE.match(argument) for argument in arguments):
                add_reason(self.reasons, SHELL_STDIN_REASON)
            elif any("__process_substitution__" in argument for argument in arguments):
                add_reason(self.reasons, SHELL_STDIN_REASON)
            elif shell_reads_stdin_script(arguments):
                if stdin_is_external:
                    add_reason(self.reasons, SHELL_STDIN_REASON)
                for stdin_command in stdin_commands:
                    self.scan_child_shell(
                        arguments,
                        effective_environment,
                        effective_tainted_environment,
                        stdin_command,
                        depth + 1,
                        stdin_is_external=False,
                        reject_function_definitions=True,
                    )
        elif command in {".", "source"}:
            source_arguments = arguments[1:] if arguments[:1] == ["--"] else arguments
            if source_arguments and source_arguments[0] in SHELL_FD0_PATHS:
                if stdin_is_external:
                    add_reason(self.reasons, SHELL_STDIN_REASON)
                for stdin_command in stdin_commands:
                    self.scan(
                        stdin_command,
                        depth + 1,
                        reject_function_definitions=True,
                    )
            elif source_arguments and (
                NON_STDIN_FD_PATH_RE.match(source_arguments[0])
                or "__process_substitution__" in source_arguments[0]
            ):
                add_reason(self.reasons, SHELL_STDIN_REASON)
            elif source_arguments:
                # 通常ファイルの読み込みは、中身を静的に検査できない。
                # 直前に生成したファイルを読ませれば、ここまでの検査を丸ごと
                # 迂回できるため、内容を確認してから実行させる
                add_reason(self.confirmations, SOURCE_FILE_CONFIRM_REASON)
        elif command == "trap":
            trap_arguments = arguments[1:] if arguments[:1] == ["--"] else arguments
            if len(trap_arguments) >= 2 and trap_arguments[0] not in {"-", ""}:
                if XARGS_REPLACEMENT_MARKER in trap_arguments[0]:
                    raise ShellScanError("xargs replacement in trap string")
                self.scan(trap_arguments[0], depth + 1, stdin_is_external)
        elif command == "find":
            if any(XARGS_REPLACEMENT_MARKER in argument for argument in arguments):
                raise ShellScanError("runtime arguments control find expression")
            index = 0
            while index < len(arguments):
                if arguments[index] not in {"-exec", "-execdir", "-ok", "-okdir"}:
                    index += 1
                    continue
                command_start = index + 1
                command_end = command_start
                while (
                    command_end < len(arguments)
                    and arguments[command_end] not in {";", "+"}
                ):
                    command_end += 1
                if command_end >= len(arguments):
                    raise ShellScanError("unterminated find executor")
                executor = [
                    argument.replace("{}", XARGS_REPLACEMENT_MARKER)
                    for argument in arguments[command_start:command_end]
                ]
                self.inspect_argv(executor, depth + 1)
                index = command_end + 1
        elif command == "coproc" and arguments:
            self.inspect_argv(strip_control_prefixes(arguments), depth + 1)
            if len(arguments) > 1 and re.match(
                r"^[A-Za-z_][A-Za-z0-9_]*$", arguments[0]
            ):
                self.inspect_argv(
                    strip_control_prefixes(arguments[1:]),
                    depth + 1,
                )
        return command, arguments


# ============================================================================
# 出力
# ============================================================================

def print_decision_json(command, decision, reasons):
    headline = (
        "危険な可能性がある Bash コマンドをブロックしました。"
        if decision == "deny"
        else "実行前に確認が必要な Bash コマンドです。"
    )
    details = "\n".join("- " + reason for reason in reasons)
    message = headline
    if decision != "deny":
        message += "\n\nCommand:\n  " + command
    message += "\n\nReasons:\n" + details
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": message,
            }
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")


def fail_closed(message):
    print("pre-bash-guard.sh: " + message, file=sys.stderr)
    return 2


# ============================================================================
# エントリポイント
# ============================================================================

def main():
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return fail_closed("invalid hook input JSON")

    if not isinstance(event, dict) or not isinstance(event.get("tool_name"), str):
        return fail_closed("invalid hook input JSON")
    if event["tool_name"] != "Bash":
        return 0

    # 相対パスの基準。イベントに cwd があればそれを使う
    # (`-v ../../..:/host` のような指定を解決するために要る)
    global WORKING_DIRECTORY
    cwd = event.get("cwd")
    if isinstance(cwd, str) and os.path.isabs(cwd):
        WORKING_DIRECTORY = cwd

    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict) or not isinstance(
        tool_input.get("command"), str
    ):
        return fail_closed("Bash hook input does not contain a string command")
    command = tool_input["command"].strip()
    if not command:
        return 0

    scanner = CommandScanner()
    try:
        scanner.scan(command)
    except (ShellScanError, ValueError, IndexError) as error:
        print("pre-bash-guard.sh: " + PARSE_REASON + " " + str(error), file=sys.stderr)
        return 2

    # Codex の PreToolUse は ask を扱わないため、deny のみ共通で強制する。
    # 確認対象は共通規約に委ね、Claude Code では従来どおり ask を返す。
    is_codex_event = isinstance(event.get("turn_id"), str)

    # 拒否理由があれば確認では通さない
    if scanner.reasons:
        print_decision_json(command, "deny", scanner.reasons)
    elif scanner.confirmations and not is_codex_event:
        # bypassPermissions では確認ダイアログが出ない。確認で止めるつもりだった
        # 操作が素通りするため、このモードでは確認理由をそのまま拒否にする
        # (サンドボックス内で完結する例外は BYPASS_ALLOWED_CONFIRMATIONS)
        if event.get("permission_mode") == "bypassPermissions":
            denied = [
                reason
                for reason in scanner.confirmations
                if reason not in BYPASS_ALLOWED_CONFIRMATIONS
            ]
            if denied:
                print_decision_json(command, "deny", denied)
        else:
            print_decision_json(command, "ask", scanner.confirmations)
    return 0


if __name__ == "__main__":
    sys.exit(main())
