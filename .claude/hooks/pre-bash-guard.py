#!/usr/bin/env python3
"""Bash コマンドの静的検査"""

import ast
import json
import os
import re
import sys
from dataclasses import dataclass, field
from urllib.parse import unquote, urlsplit


class Denied(Exception):
    """deny として返す危険操作"""


class ParseError(Exception):
    """解析不能（終了コード 2）"""


class UnsupportedSyntax(Exception):
    """通常の権限判定へ委ねる未対応構文"""


def deny(reason):
    """理由付きで拒否"""
    raise Denied(reason)


SECRET_OUTPUT_REASON = "資格情報や秘密値を直接出力・取得する操作は許可していません。"
EXEC_OVERRIDE_REASON = "保護機構や認証処理を迂回する実行設定は許可していません。"
DESTRUCTIVE_REASON = "強制的な変更破棄、検証の迂回、ディスクの破壊は許可していません。"
SAFE_ENV_NAMES = set("""
    PATH HOME PWD OLDPWD USER LOGNAME SHELL TERM
    LANG LC_ALL LC_CTYPE TZ TMPDIR TMP TEMP EDITOR
    VISUAL PAGER MANPAGER COLORTERM TERM_PROGRAM SHLVL
    AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION
    AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE KUBECONFIG
    GH_CONFIG_DIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
    CODEX_HOME VIRTUAL_ENV CONDA_DEFAULT_ENV PYTHONPATH NODE_ENV
""".split())

CLI_VALUE_OPTIONS = {
    command: set(options.split())
    for command, options in {
        "aws": "--ca-bundle --cli-binary-format --cli-connect-timeout --cli-error-format --cli-input-json --cli-input-yaml --cli-read-timeout --color --endpoint-url --output --profile --query --region",
        "az": "--name --output --query --resource-group --subscription --vault-name -g -n -o",
        "docker": "--config --context --filter --format --host --log-level --tlscacert --tlscert --tlskey -H -f",
        "gcloud": "--account --configuration --format --impersonate-service-account --project",
        "gh": "--config --host --hostname --repo -R",
        "ghtkn": "--config --log-level -c",
        "git": "--config --config-env --exec-path --git-dir --namespace --super-prefix --work-tree -C -c",
        "kubectl": "--as --as-group --cache-dir --certificate-authority --client-certificate --client-key --cluster --context --field-selector --kubeconfig --namespace --output --password --request-timeout --selector --server --token --user --username -l -n -o -s -v",
        "npm": "--cache --call --editor --location --message --otp --tag --workspace -L -c -m -w",
        "op": "--account --config --encoding --format --session --vault",
        "pnpm": "--dir --filter --reporter -F",
        "security": "-C -D -P -a -c -d -f -j -l -o -p -s -t",
        "terraform": "-backup -chdir -lock-timeout -plugin-dir -replace -state -state-out -target -var -var-file",
        "terragrunt": "--config --log-level --terragrunt-config --terragrunt-tfpath --terragrunt-working-dir --tf-path --working-dir",
        "uv": "--cache-dir --color --config-file --directory --project",
        "vault": "-address -ca-cert -field -format -mount -namespace",
    }.items()
}
CLI_VALUE_OPTIONS["oc"] = CLI_VALUE_OPTIONS["kubectl"]
# nopt の String 値は、先頭が - なら次のオプション扱い
CLI_STRING_OPTIONS = {
    "npm": {"--call", "--editor", "--message", "--tag", "-c", "-m"},
    "pnpm": {"--dir", "--reporter", "-C"},
}
COMPOSE_VALUE_OPTIONS = set("""
    --ansi --env-file -f --file --parallel --profile
    --progress --project-directory -p --project-name
""".split())
PACKAGE_CONFIG_ALIASES = {
    "npm": {"c": "config", "con": "config", "conf": "config", "confi": "config", "g": "config get", "ge": "config get", "get": "config get"},
    "pnpm": {"c": "config", "get": "config get"},
}

SECRET_SUBCOMMANDS = {
    "az": {"account get-access-token", "acr credential show", "ad app credential reset", "ad sp credential reset", "keyvault secret download", "keyvault secret show", "storage account generate-sas", "storage account keys list", "storage account keys renew"},
    "gcloud": {"auth application-default print-access-token", "auth print-access-token", "auth print-identity-token", "iam service-accounts keys create", "secrets versions access", "sql generate-login-token"},
    "ghtkn": {"exec", "get", "git-credential"},
    "op": {"connect token create", "document get", "inject", "item get", "plugin run", "read", "run", "service-account create", "signin"},
    "uv": {"auth helper", "auth token"},
    "vault": {"kv get", "operator generate-root", "operator init", "print token", "read", "token create", "token lookup", "unwrap", "write"},
}
AWS_SECRET_OPERATIONS = {
    service: set(operations.split())
    for service, operations in {
        "acm": "export-certificate get-acme-external-account-binding-credentials",
        "amplify": "create-app create-branch delete-app delete-branch get-app get-branch list-apps list-branches update-app update-branch",
        "amplifybackend": "create-token get-token",
        "amplifyuibuilder": "exchange-code-for-token refresh-token",
        "apigateway": "create-api-key get-api-key get-api-keys update-api-key",
        "appstream": "create-app-block-builder-streaming-url create-image-builder-streaming-url create-streaming-url",
        "appsync": "create-api-key list-api-keys update-api-key",
        "athena": "create-presigned-notebook-url get-session-endpoint",
        "bedrock-agentcore": "get-resource-api-key get-resource-oauth2-token get-resource-payment-token get-workload-access-token get-workload-access-token-for-jwt get-workload-access-token-for-user-id",
        "chime": "create-bot get-bot list-bots regenerate-security-token update-bot",
        "chime-sdk-meetings": "batch-create-attendee create-attendee create-meeting-with-attendees get-attendee list-attendees update-attendee-capabilities",
        "cloudfront": "sign",
        "codeartifact": "get-authorization-token",
        "codebuild": "start-sandbox-connection",
        "codecatalyst": "create-access-token start-dev-environment-session",
        "codepipeline": "get-job-details get-third-party-job-details poll-for-jobs",
        "cognito-identity": "get-credentials-for-identity get-open-id-token get-open-id-token-for-developer-identity",
        "cognito-idp": "add-user-pool-client-secret admin-initiate-auth admin-respond-to-auth-challenge associate-software-token create-user-pool-client describe-user-pool-client get-tokens-from-refresh-token initiate-auth respond-to-auth-challenge update-user-pool-client",
        "configure": "export-credentials",
        "connect": "create-auth-code get-federation-token start-web-rtc-contact",
        "connectparticipant": "create-participant-connection",
        "customer-profiles": "get-upload-job-path",
        "datazone": "get-environment-credentials",
        "deadline": "assume-fleet-role-for-read assume-fleet-role-for-worker assume-queue-role-for-read assume-queue-role-for-user assume-queue-role-for-worker",
        "devicefarm": "create-test-grid-url",
        "dsql": "generate-db-connect-admin-auth-token generate-db-connect-auth-token",
        "ec2": "create-key-pair get-password-data",
        "ecr": "get-authorization-token get-login-password",
        "ecr-public": "get-authorization-token get-login-password",
        "eks": "get-token",
        "eks-auth": "assume-role-for-pod-identity",
        "emr": "get-cluster-session-credentials get-on-cluster-app-ui-presigned-url get-persistent-app-ui-presigned-url get-session-endpoint",
        "emr-containers": "get-managed-endpoint-session-credentials",
        "emr-serverless": "get-session-endpoint",
        "finspace-data": "get-external-data-view-access-details get-programmatic-access-credentials reset-user-password",
        "gamelift": "create-build get-compute-access get-compute-auth-token get-instance-access get-player-connection-details request-upload-credentials",
        "glue": "get-session-endpoint",
        "grafana": "create-workspace-api-key create-workspace-service-account-token",
        "history": "list show",
        "iam": "create-access-key create-service-specific-credential reset-service-specific-credential",
        "iot": "create-keys-and-certificate create-provisioning-claim",
        "iotsecuretunneling": "open-tunnel rotate-tunnel-access-token",
        "ivs": "batch-get-stream-key create-channel create-stream-key get-stream-key",
        "ivs-realtime": "create-ingest-configuration create-participant-token create-stage get-ingest-configuration update-ingest-configuration",
        "ivschat": "create-chat-token",
        "kms": "decrypt derive-shared-secret generate-data-key generate-data-key-pair",
        "lakeformation": "assume-decorated-role-with-saml get-temporary-data-location-credentials get-temporary-glue-partition-credentials get-temporary-glue-table-credentials",
        "lambda-microvms": "create-microvm-auth-token create-microvm-shell-auth-token",
        "license-manager": "create-token get-access-token",
        "lightsail": "create-bucket-access-key create-container-service-registry-login create-key-pair download-default-key-pair get-bucket-access-keys get-instance-access-details get-relational-database-master-user-password",
        "mediapackage": "configure-logs create-channel describe-channel list-channels rotate-channel-credentials rotate-ingest-endpoint-credentials update-channel",
        "mwaa": "create-cli-token create-web-login-token",
        "pca-connector-scep": "create-challenge get-challenge-password",
        "pcs": "register-compute-node-group-instance",
        "quicksight": "generate-embed-url-for-anonymous-user generate-embed-url-for-registered-user generate-embed-url-for-registered-user-with-identity get-dashboard-embed-url get-session-embed-url",
        "rds": "generate-db-auth-token",
        "redshift": "get-cluster-credentials get-cluster-credentials-with-iam get-identity-center-auth-token",
        "redshift-serverless": "get-credentials get-identity-center-auth-token",
        "route53domains": "retrieve-domain-auth-code transfer-domain-to-another-aws-account",
        "route53globalresolver": "create-access-token get-access-token",
        "s3": "presign",
        "s3api": "create-session",
        "s3control": "get-data-access",
        "sagemaker": "create-partner-app-presigned-url create-presigned-domain-url create-presigned-mlflow-app-url create-presigned-mlflow-tracking-server-url create-presigned-notebook-instance-url start-session",
        "secretsmanager": "batch-get-secret-value get-secret-value",
        "signin": "create-oauth2-token create-oauth2-token-with-iam",
        "ssm": "create-activation get-access-token resume-session",
        "sso": "get-role-credentials",
        "sso-oidc": "create-token create-token-with-iam register-client",
        "storagegateway": "describe-chap-credentials",
        "sts": "assume-role assume-role-with-saml assume-role-with-web-identity assume-root get-delegated-access-token get-federation-token get-session-token get-web-identity-token",
        "wafv2": "create-api-key list-api-keys",
        "wickr": "create-data-retention-bot-challenge get-oidc-info get-opentdf-config register-oidc-config register-opentdf-config",
        "workmail": "assume-impersonation-role",
        "workspaces-thin-client": "create-environment get-environment list-environments update-environment",
    }.items()
}
# 指定を拒否する git 設定
GIT_EXEC_KEYS = {
    "core.hookspath", "core.askpass", "credential.helper",
    "uploadpack.packobjectshook",
}
# 値をシェルコードとして検査する git 設定
GIT_COMMAND_KEYS = {
    "core.pager", "core.editor", "core.sshcommand", "core.gitproxy",
    "core.fsmonitor", "sequence.editor", "diff.external", "gpg.program",
    "gpg.openpgp.program",
}
# --format で許す非秘密フィールド
CONTAINER_SAFE_FIELDS = set("""
    id ids name names image imageid status state
    running paused restarting dead exitcode pid ports
    size sizewritable sizerootfs created createdat startedat
    finishedat repository tag digest repotags repodigests
    architecture os ostype serverversion version apiversion
    memory memtotal ncpu containers containersrunning
    containerspaused containersstopped images driver platform
""".split())


def option_values(args, names):
    """分離・=・短縮結合形式のオプション値"""
    values = []
    index = 0
    while index < len(args):
        argument = args[index]
        if argument == "--":
            break
        if argument in names:
            if index + 1 < len(args):
                values.append(args[index + 1])
                index += 1
        else:
            name, separator, value = argument.partition("=")
            if separator and name in names:
                values.append(value)
            else:
                for name in names:
                    if len(name) == 2 and name.startswith("-") and argument.startswith(name) and len(argument) > 2:
                        values.append(argument[2:])
                        break
        index += 1
    return values


def has_option(args, names, short="", value_options=(), negated=()):
    """後の否定形を反映したオプションの有効性"""
    found = False
    args = iter(args)
    for argument in args:
        if argument == "--":
            break
        if argument in value_options:
            next(args, None)
            continue
        if value_options and argument.startswith("-") and not argument.startswith("--"):
            for offset, flag in enumerate(argument[1:], 1):
                if "-" + flag in value_options:
                    if offset == len(argument) - 1:
                        next(args, None)
                    argument = argument[:offset]
                    break
        name, separator, value = argument.partition("=")
        if name in negated:
            found = False
        elif name in names and (not separator or value.casefold() not in {"false", "0", "no", "off"}):
            found = True
        if short and re.fullmatch(r"-[A-Za-z]+", argument) and any(flag in argument[1:] for flag in short):
            found = True
    return found


def cli_words(command, args, extra_values=()):
    """オプション・値を除く引数列"""
    values = CLI_VALUE_OPTIONS.get(command, set()) | set(extra_values)
    words = []
    index = 0
    while index < len(args):
        argument = args[index]
        if argument == "--":
            words.extend(args[index + 1:])
            break
        current_values = values
        if command == "docker" and words == ["compose"]:
            current_values = values | COMPOSE_VALUE_OPTIONS
        if argument in current_values:
            optional = argument in CLI_STRING_OPTIONS.get(command, ()) and index + 1 < len(args) and re.match(r"-{1,2}[^-]", args[index + 1])
            index += 1 if optional else 2
            continue
        if not argument.startswith("-") or argument == "-":
            words.append(argument)
        index += 1
    return words


def matches_subcommand(words, forms):
    """空白区切りの形式との前方一致"""
    return any(words[:len(parts)] == parts for parts in map(str.split, forms))


def secret_name(name):
    """変数名・設定キーの秘密語を判定"""
    normalized = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).upper()
    normalized = re.sub(r"[^A-Z0-9]+", "_", normalized)
    if normalized in SAFE_ENV_NAMES:
        return False
    words = set(normalized.split("_"))
    secret_words = {"TOKEN", "TOKENS", "SECRET", "SECRETS", "PASSWORD", "PASSWD", "APIKEY", "ACCESSKEY", "CREDENTIAL", "CREDENTIALS", "AUTHORIZATION", "PROXY"}
    return normalized == "SSH_AUTH_SOCK" or bool(words & secret_words) or any(
        marker in "_" + normalized + "_"
        for marker in ("_API_KEY_", "_ACCESS_KEY_", "_PRIVATE_KEY_")
    )


def git_exec_key(key):
    """実行・認証・取得先を差し替える git 設定を判定"""
    key = key.casefold()
    return key in GIT_EXEC_KEYS or key == "include.path" or key.startswith("includeif.") or any(
        key.startswith(prefix) and key.endswith(suffix)
        for prefix, suffix in (("credential.", ".helper"), ("credential.", ".askpass"), ("protocol.", ".allow"), ("url.", ".insteadof"), ("url.", ".pushinsteadof"), ("filter.", ".clean"), ("filter.", ".smudge"), ("filter.", ".process"))
    )


def resolve_path(path, cwd, normalize=os.path.normpath):
    """cwd 基準でパスを正規化し、基準不明の相対パスは None"""
    if not os.path.isabs(path):
        if cwd is None:
            return None
        path = os.path.join(cwd, path)
    return normalize(path)


def git_command_context(args, cwd):
    """グローバルオプション終端と -C 適用後の cwd"""
    global_options = CLI_VALUE_OPTIONS["git"]
    index = 0
    while index < len(args) and args[index].startswith("-"):
        argument = args[index]
        index += 2 if argument in global_options else 1
    for directory in option_values(args[:index], {"-C"}):
        if "$" in directory or UNKNOWN_ARGUMENT in directory:
            cwd = None
            continue
        cwd = resolve_path(os.path.expanduser(directory), cwd, os.path.realpath)
    return index, cwd


def git_alias_directory(args, cwd):
    """shell alias の実行位置"""
    index, cwd = git_command_context(args, cwd)
    work_trees = option_values(args[:index], {"--work-tree"})
    if "--bare" in args[:index]:
        return cwd
    # shell alias の実行位置はリポジトリ直下
    directory = os.path.realpath(cwd) if cwd is not None else None
    if directory is not None and not option_values(args[:index], {"--git-dir"}):
        while not os.path.exists(os.path.join(directory, ".git")):
            parent = os.path.dirname(directory)
            if parent == directory:
                return cwd
            directory = parent
    if work_trees:
        if "$" in work_trees[-1] or UNKNOWN_ARGUMENT in work_trees[-1]:
            return None
        return resolve_path(os.path.expanduser(work_trees[-1]), cwd, os.path.realpath)
    return directory


def inspect_git(args, words, cwd):
    """実行設定の差し替え・秘密出力・破壊操作を検査"""
    for setting in option_values(args, {"--config-env"}):
        if git_exec_key(setting.split("=", 1)[0]):
            deny(EXEC_OVERRIDE_REASON)
    for setting in option_values(args, {"-c", "--config"}):
        key, _, value = setting.partition("=")
        if key.casefold() in {"core.pager", "pager"} and value in {"", "cat"}:
            continue
        if key.casefold() == "core.fsmonitor" and value.casefold() == "false":
            continue
        if key.casefold() == "ssh.variant" and value in {"ssh", "plink", "putty", "tortoiseplink", "simple", "auto"}:
            continue
        if git_exec_key(key):
            deny(EXEC_OVERRIDE_REASON)
        if key.casefold() in GIT_COMMAND_KEYS and value:
            scan(value, cwd)
        elif key.casefold().startswith("alias.") and value.startswith("!"):
            scan(value[1:], git_alias_directory(args, cwd))
    for value in option_values(args, {"--receive-pack", "--upload-pack", "--exec"}):
        scan(value, cwd)
    if any(argument.startswith("--exec-path=") for argument in args):
        deny(EXEC_OVERRIDE_REASON)
    if has_option(args, {"--help", "-h"}):
        return
    if matches_subcommand(words, {"credential fill"}) or (words and words[0].startswith("credential-")):
        deny(SECRET_OUTPUT_REASON)
    if words[:1] == ["config"]:
        config_words = cli_words("git", args, {"--file", "-f", "--blob", "--type", "-t", "--default", "--comment", "--value", "--url"})[1:]
        verbs = {"list", "get", "set", "unset", "edit", "rename-section", "remove-section"}
        verb = config_words[0] if config_words and config_words[0] in verbs else ""
        operands = config_words[1:] if verb else config_words
        mutates = verb in {"set", "unset", "edit", "rename-section", "remove-section"} or has_option(args, {"--add", "--unset", "--unset-all", "--replace-all", "--rename-section", "--remove-section", "--edit", "-e"})
        removes = verb in {"unset", "remove-section"} or has_option(args, {"--unset", "--unset-all", "--remove-section"})
        reads = not mutates and (verb in {"list", "get"} or has_option(args, {"--list", "--get", "--get-all", "--get-regexp", "--get-urlmatch"}, "l") or not verb and len(operands) == 1)
        names_only = has_option(args, {"--name-only"}) and not has_option(args, {"--no-name-only"})
        regex_read = has_option(args, {"--get-regexp"}) or verb == "get" and has_option(args, {"--regexp"})
        if not names_only and (verb == "list" or has_option(args, {"--list"}, "l") or reads and regex_read):
            deny(SECRET_OUTPUT_REASON)
        if reads and not names_only and any(secret_name(key) or "extraheader" in key.casefold() for key in operands):
            deny(SECRET_OUTPUT_REASON)
        url_read = has_option(args, {"--get-urlmatch"}) or verb == "get" and bool(option_values(args, {"--url"}))
        if reads and not names_only and url_read and operands and "." not in operands[0]:
            deny(SECRET_OUTPUT_REASON)
        if not reads and not removes and any(git_exec_key(key) for key in operands):
            deny(EXEC_OVERRIDE_REASON)
        if not reads and not removes and len(operands) > 1:
            key, value = operands[:2]
            if key.casefold() in GIT_COMMAND_KEYS:
                scan(value, cwd)
            elif key.casefold().startswith("alias.") and value.startswith("!"):
                scan(value[1:], git_alias_directory(args, cwd))
    if not words:
        return
    command = words[0]
    # commit の -n は --no-verify、push・clean の -n は --dry-run
    if command in {"push", "clean", "commit"}:
        value_options = CLI_VALUE_OPTIONS["git"] | {
            "commit": {"-m", "--message", "-F", "--file", "--author", "--date", "--reedit-message", "--reuse-message", "--fixup", "--squash", "--trailer", "-t", "--template", "--cleanup", "--pathspec-from-file", "-U", "--unified", "--inter-hunk-context"},
            "clean": {"-e", "--exclude"},
            "push": {"--repo", "--receive-pack", "--exec", "-o", "--push-option", "--recurse-submodules"},
        }[command]
        if has_option(args, {"--dry-run"}, "n" if command != "commit" else "", value_options, negated={"--no-dry-run"}):
            return
    if command == "reflog" and has_option(args, {"--dry-run"}, "n", CLI_VALUE_OPTIONS["git"], negated={"--no-dry-run"}):
        return
    if command == "push" and (has_option(args, {"--force", "--mirror", "--prune"}, "f") or any(word.startswith("+") for word in words[1:])):
        deny(DESTRUCTIVE_REASON)
    if command == "reset" and has_option(args, {"--hard"}):
        deny(DESTRUCTIVE_REASON)
    if command == "clean" and has_option(args, {"--force"}, "f"):
        deny(DESTRUCTIVE_REASON)
    if command in {"commit", "merge", "rebase", "push"} and has_option(args, {"--no-verify"}, "n" if command == "commit" else ""):
        deny(DESTRUCTIVE_REASON)
    if command in {"checkout", "switch"} and has_option(args, {"--force", "--discard-changes"}, "f"):
        deny(DESTRUCTIVE_REASON)
    if matches_subcommand(words, {"filter-branch", "stash clear", "reflog expire", "reflog delete"}):
        deny(DESTRUCTIVE_REASON)


def inspect_security(args, words):
    """キーチェーンの秘密出力を検査"""
    # 対話モードは標準入力から任意のサブコマンドを受け取る
    if has_option(args, set(), "i"):
        deny(SECRET_OUTPUT_REASON)
    if has_option(args, {"--help", "-h"}) or words[:1] == ["help"]:
        return
    if not words:
        deny(SECRET_OUTPUT_REASON)
    command = words[0]
    if command in {"dump-keychain", "export-smartcard"}:
        deny(SECRET_OUTPUT_REASON)
    if command in {"find-generic-password", "find-internet-password"} and has_option(args, set(), "wg"):
        deny(SECRET_OUTPUT_REASON)
    if command == "export":
        types = option_values(args, {"-t"})
        if not types or any(value not in {"certs", "pubKeys"} for value in types):
            deny(SECRET_OUTPUT_REASON)


def inspect_aws(args, words):
    """AWS の秘密取得を検査"""
    if has_option(args, {"--version"}):
        return
    # オプション値の help をヘルプ要求と誤認しない
    help_words = []
    index = 0
    while index < len(args):
        argument = args[index]
        name, separator, _ = argument.partition("=")
        if name in CLI_VALUE_OPTIONS["aws"]:
            index += 1 if separator else 2
            continue
        if argument not in {"--debug", "--no-verify-ssl", "--no-paginate", "--no-sign-request", "--no-cli-pager"}:
            help_words.append(argument)
        index += 1
    if 1 <= len(help_words) <= 3 and help_words[-1] == "help" and all(not word.startswith("-") for word in help_words):
        return
    if has_option(args, {"--debug"}):
        deny(SECRET_OUTPUT_REASON)
    if len(words) < 2:
        return
    service, operation = words[:2]
    # --generate-cli-skeleton は標準 API にだけ適用
    custom = {("configure", "export-credentials"), ("cloudfront", "sign"), ("codecommit", "credential-helper"), ("ecr", "get-login-password"), ("ecr-public", "get-login-password"), ("eks", "get-token"), ("rds", "generate-db-auth-token"), ("s3", "presign")}
    if (service, operation) not in custom and service not in {"history", "dsql"} and has_option(args, {"--generate-cli-skeleton"}):
        return
    if service == "apigateway" and operation in {"get-api-key", "get-api-keys"} and not has_option(args, {"--include-value", "--include-values"}):
        return
    if operation in AWS_SECRET_OPERATIONS.get(service, set()):
        deny(SECRET_OUTPUT_REASON)
    if service == "ssm" and operation in {"get-parameter", "get-parameters", "get-parameters-by-path", "get-parameter-history"}:
        if has_option(args, {"--with-decryption"}):
            deny(SECRET_OUTPUT_REASON)
    if service == "configure" and operation in {"get", "set"} and len(words) > 2 and secret_name(words[2]):
        deny(SECRET_OUTPUT_REASON)
    if matches_subcommand(words, {"codecommit credential-helper get"}):
        deny(SECRET_OUTPUT_REASON)
    # login --dry-run はトークンを表示する
    if service == "codeartifact" and operation == "login" and has_option(args, {"--dry-run"}):
        deny(SECRET_OUTPUT_REASON)


def inspect_gh(args, words, cwd):
    """トークン出力・API・子コマンドを検査"""
    if has_option(args, {"--help", "-h"}) or words[:1] == ["help"]:
        return
    if matches_subcommand(words, {"auth token", "auth git-credential"}):
        deny(SECRET_OUTPUT_REASON)
    if words[:2] == ["auth", "status"] and has_option(args, {"--show-token"}, "t"):
        deny(SECRET_OUTPUT_REASON)
    if words[:2] == ["config", "get"] and any(secret_name(word) for word in words[2:]):
        deny(SECRET_OUTPUT_REASON)
    if matches_subcommand(words, {"repo clone", "codespace ssh"}) and "--" in args:
        child = args[args.index("--") + 1:]
        inspect_argv((["git", "clone"] if words[:2] == ["repo", "clone"] else ["ssh"]) + child, cwd, 1)
    if words[:1] == ["api"]:
        endpoints = cli_words("gh", args, {"-X", "--method", "-H", "--header", "-f", "-F", "--field", "--raw-field", "--input", "--jq", "-q", "--template", "-t", "--cache", "--preview"})[1:]
        for endpoint in endpoints:
            path = "/" + unquote(urlsplit(endpoint).path).strip("/")
            if re.search(r"/(?:registration-token|remove-token|generate-jitconfig|access_tokens|oauth/token)(?:/|$)", path):
                deny(SECRET_OUTPUT_REASON)
            if re.search(r"/(?:app-manifests/[^/]+/conversions|applications/[^/]+/token(?:/scoped)?)$", path):
                deny(SECRET_OUTPUT_REASON)


def inspect_terraform(args, words, cwd):
    """state・output の出力とコマンド差し替えを検査"""
    for value in option_values(args, {"--tf-path", "--terragrunt-tfpath", "--shell", "--terragrunt-iam-assume-role-command"}):
        scan(value, cwd)
    if has_option(args, {"--help", "-help", "-h"}):
        return
    while words and words[0] in {"run", "run-all", "stack"}:
        words = words[1:]
    if matches_subcommand(words, {"state pull", "state show"}):
        deny(SECRET_OUTPUT_REASON)
    if words[:1] == ["show"] and has_option(args, {"-json", "--json"}):
        deny(SECRET_OUTPUT_REASON)
    if words[:1] == ["output"] and (len(words) > 1 or has_option(args, {"-raw", "-json", "--raw", "--json"})):
        deny(SECRET_OUTPUT_REASON)


def inspect_kubernetes(command, args, words):
    """Secret・トークン・kubeconfig の出力を検査"""
    if has_option(args, {"--help", "-h"}):
        return
    if matches_subcommand(words, {"create token", "serviceaccounts new-token", "serviceaccounts create-kubeconfig"}):
        deny(SECRET_OUTPUT_REASON)
    if words[:1] in (["get"], ["describe"]) and len(words) > 1:
        resources = words[1].casefold().split(",")
        if any(resource.split("/", 1)[0].split(".", 1)[0] in {"secret", "secrets"} for resource in resources):
            deny(SECRET_OUTPUT_REASON)
    if words[:2] == ["config", "view"] and has_option(args, {"--raw"}):
        deny(SECRET_OUTPUT_REASON)
    if words[:1] == ["get"] and any(re.search(r"/secrets(?:[/?]|$)", value) for value in option_values(args, {"--raw"})):
        deny(SECRET_OUTPUT_REASON)
    if command == "oc" and words[:1] == ["whoami"] and has_option(args, {"--show-token"}, "t"):
        deny(SECRET_OUTPUT_REASON)
    if command == "oc" and words[:2] == ["registry", "login"] and has_option(args, {"--to", "--registry-config", "-a"}):
        deny(SECRET_OUTPUT_REASON)


def safe_container_format(value):
    """テンプレートの参照フィールドを検査"""
    references = re.findall(r"\{\{([^{}]*)\}\}", value)
    if not references:
        return False
    for reference in references:
        reference = reference.strip()
        if reference == ".Config.Image":
            continue
        if not re.fullmatch(r"\.[A-Za-z][A-Za-z0-9.]*", reference):
            return False
        if any(field.casefold() not in CONTAINER_SAFE_FIELDS for field in reference[1:].split(".")):
            return False
    return True


def inspect_container(args, words):
    """設定・環境変数の出力と特権実行を検査"""
    if has_option(args, {"--help"}):
        return
    formats = option_values(args, {"--format", "-f"})
    safe_format = bool(formats) and all(safe_container_format(value) for value in formats)
    if matches_subcommand(words, {"inspect", "container inspect", "image inspect", "service inspect", "info", "system info", "history", "image history"}) and not safe_format:
        deny(SECRET_OUTPUT_REASON)
    if matches_subcommand(words, {"context export", "stack config", "pass get", "pass run"}):
        deny(SECRET_OUTPUT_REASON)
    if matches_subcommand(words, {"compose config", "compose convert"}):
        if has_option(args, {"--environment"}) or not has_option(args, {"--services", "--volumes", "--profiles", "--images", "--networks", "--hash", "--quiet"}, "q"):
            deny(SECRET_OUTPUT_REASON)
    if matches_subcommand(words, {"ps", "container ls", "container ps", "compose ps"}):
        if has_option(args, {"--no-trunc"}) and not safe_format:
            deny(SECRET_OUTPUT_REASON)
        if formats and not all(value.casefold() in {"table", "pretty"} or safe_container_format(value) for value in formats):
            deny(SECRET_OUTPUT_REASON)
    if matches_subcommand(words, {"top", "container top", "compose top"}):
        # top の既定出力はプロセス引数を含む
        if not option_values(args, {"-o"}):
            deny(SECRET_OUTPUT_REASON)
        inspect_process("ps", args)
    if has_option(args, {"--privileged", "--use-api-socket"}):
        deny(EXEC_OVERRIDE_REASON)


def inspect_environment(command, args, words):
    """環境・シェル変数の一括出力と秘密値の表示を検査"""
    if command == "printenv":
        if has_option(args, {"--help", "--version"}):
            return
        if not words or any(secret_name(word) for word in words):
            deny(SECRET_OUTPUT_REASON)
    if command == "set" and not args:
        deny(SECRET_OUTPUT_REASON)
    if command in {"export", "declare", "typeset"}:
        if not words or has_option(args, set(), "p"):
            deny(SECRET_OUTPUT_REASON)
        if command != "export" and any("=" not in word and secret_name(word) for word in words):
            deny(SECRET_OUTPUT_REASON)


def inspect_process(command, args):
    """プロセスの引数・環境変数の表示を検査"""
    if command == "ps":
        if has_option(args, {"--help"}) or args == ["-L"]:
            return
        bsd = args[0] if args and re.fullmatch(r"[A-Za-z]+", args[0]) else ""
        if "e" in bsd or has_option(args, set(), "E"):
            deny(SECRET_OUTPUT_REASON)
        formats = option_values(args, {"-o", "--format"})
        if has_option(args, {"-O"}):
            deny(SECRET_OUTPUT_REASON)
        if formats:
            if any(field.split("=", 1)[0].casefold() in {"args", "cmd", "command", "env", "environ"} for value in formats for field in re.split(r"[\s,]+", value)):
                deny(SECRET_OUTPUT_REASON)
        elif "c" not in bsd and not has_option(args, set(), "c"):
            deny(SECRET_OUTPUT_REASON)
    elif command == "pgrep":
        if has_option(args, {"--list-full"}, "a") or has_option(args, set(), "f") and has_option(args, set(), "l"):
            deny(SECRET_OUTPUT_REASON)
    elif command == "launchctl":
        words = cli_words(command, args)
        if matches_subcommand(words, {"export", "print", "print-cache", "dumpstate"}):
            deny(SECRET_OUTPUT_REASON)
        if words[:1] == ["getenv"] and (len(words) < 2 or secret_name(words[1])):
            deny(SECRET_OUTPUT_REASON)
    elif command == "sysctl":
        if any(word.casefold().startswith("kern.procargs") for word in args):
            deny(SECRET_OUTPUT_REASON)


def inspect_packages(command, args, words):
    """パッケージ設定の秘密出力を検査"""
    if has_option(args, {"--help", "--version", "-h"}):
        return
    if command in {"pip", "pip3"}:
        if matches_subcommand(words, {"config list", "config debug"}):
            deny(SECRET_OUTPUT_REASON)
        if words[:2] == ["config", "get"] and any(word.rsplit(".", 1)[-1].casefold() in {"index-url", "extra-index-url", "proxy"} for word in words[2:]):
            deny(SECRET_OUTPUT_REASON)
    if command in {"npm", "pnpm"}:
        # pnpm 11 の pm・with <version|current> は後続コマンドを実行
        if command == "pnpm":
            if words[:1] == ["pm"]:
                words = words[1:]
            if words[:1] == ["with"]:
                words = words[2:]
        if words and words[0] in PACKAGE_CONFIG_ALIASES[command]:
            words = PACKAGE_CONFIG_ALIASES[command][words[0]].split() + words[1:]
        if command == "npm" and (matches_subcommand(words, {"config list", "config ls"}) or words in (["config", "get"], ["config"])):
            deny(SECRET_OUTPUT_REASON)
        if words[:2] == ["config", "get"] and any(secret_name(word) or "_auth" in word.casefold() for word in words[2:]):
            deny(SECRET_OUTPUT_REASON)


def inspect_cli(command, args, cwd):
    """秘密出力・実行設定の差し替え・破壊操作を検査"""
    words = cli_words(command, args)
    if command.startswith(("docker-credential-", "git-credential-")):
        deny(SECRET_OUTPUT_REASON)
    if command == "security":
        inspect_security(args, words)
    elif command == "git":
        inspect_git(args, words, cwd)
    elif command == "aws":
        inspect_aws(args, words)
    elif command == "gh":
        inspect_gh(args, words, cwd)
    elif command in {"terraform", "terragrunt"}:
        inspect_terraform(args, words, cwd)
    elif command in {"kubectl", "oc"}:
        inspect_kubernetes(command, args, words)
    elif command == "docker":
        inspect_container(args, words)
    elif command in {"printenv", "set", "export", "declare", "typeset"}:
        inspect_environment(command, args, words)
    elif command in {"ps", "pgrep", "launchctl", "sysctl"}:
        inspect_process(command, args)
    elif command in {"ssh", "scp", "sftp"}:
        for setting in option_values(args, {"-o"}):
            if "=" not in setting:
                setting = setting.replace(" ", "=", 1)
            name, _, value = setting.partition("=")
            if name.casefold() in {"proxycommand", "localcommand", "remotecommand"}:
                scan(value, cwd)
    elif command in SECRET_SUBCOMMANDS:
        if has_option(args, {"--help", "-h"}) or words[:1] == ["help"]:
            return
        if command == "gcloud" and words[:1] in (["alpha"], ["beta"], ["preview"]):
            words = words[1:]
        if matches_subcommand(words, SECRET_SUBCOMMANDS[command]):
            deny(SECRET_OUTPUT_REASON)
        if command == "vault" and words[:1] == ["login"]:
            if not has_option(args, {"-no-print"}) or has_option(args, {"-token-only"}):
                deny(SECRET_OUTPUT_REASON)
        if command == "az" and words[:2] == ["acr", "login"] and has_option(args, {"--expose-token"}):
            deny(SECRET_OUTPUT_REASON)
    elif command in {"rosa", "ocm"}:
        if not has_option(args, {"--help", "-h"}):
            if matches_subcommand(words, {"token", "create admin"}) or has_option(args, {"--token", "--show-token"}):
                deny(SECRET_OUTPUT_REASON)
            if words[:1] == ["config"] and (len(words) == 1 or any(secret_name(word) for word in words[1:])):
                deny(SECRET_OUTPUT_REASON)
    elif command == "fc":
        deny(SECRET_OUTPUT_REASON)
    elif command == "history":
        if not args or args == ["--"] or has_option(args, set(), "anrw") or re.fullmatch(r"-?\d+", args[0]):
            deny(SECRET_OUTPUT_REASON)
        if has_option(args, set(), "p") and any("!" in word or word.startswith("^") for word in words):
            deny(SECRET_OUTPUT_REASON)
    elif command == "hash" and has_option(args, {"-p"}):
        deny(EXEC_OVERRIDE_REASON)
    elif command == "rsync" and has_option(args, {"--password-file"}):
        deny(SECRET_OUTPUT_REASON)
    elif command == "diskutil" and words and words[0].casefold() in {"erasedisk", "erasevolume", "partitiondisk", "zerodisk", "randomdisk", "secureerase"}:
        deny(DESTRUCTIVE_REASON)
    elif command.startswith("mkfs") or command in {"newfs", "newfs_apfs", "newfs_hfs"}:
        if not has_option(args, {"--help", "--version", "-h"}):
            deny(DESTRUCTIVE_REASON)
    elif command == "wipefs" and has_option(args, {"--all", "--offset"}, "ao"):
        deny(DESTRUCTIVE_REASON)
    elif command == "fdisk" and has_option(args, set(), "eiu"):
        deny(DESTRUCTIVE_REASON)
    elif command == "dd" and any(argument.startswith(("of=/dev/disk", "of=/dev/rdisk", "of=/dev/sd", "of=/dev/nvme")) for argument in args):
        deny(DESTRUCTIVE_REASON)
    if re.fullmatch(r"pip(?:[._-]?\d+(?:[._-]\d+)*)?", command):
        inspect_packages("pip", args, cli_words(command, args, {"--python", "--proxy", "--timeout", "--retries", "--cert", "--client-cert", "--cache-dir", "--log"}))
    elif command in {"npm", "pnpm"}:
        inspect_packages(command, args, cli_words(command, args, {"--prefix", "--userconfig", "--globalconfig", "--registry", "--loglevel", "-C"}))


# ホームからの相対パス
CREDENTIAL_LOCATIONS = (
    ".aws/credentials", ".aws/config", ".aws/login", ".aws/sso", ".aws/cli",
    ".ssh", ".gnupg", ".docker/config.json", ".config/gh/hosts.yml",
    ".config/gcloud", ".config/containers/auth.json", ".local/share/uv/credentials",
    ".ocm.json", ".config/ocm/ocm.json", "Library/Application Support/ocm/ocm.json",
    ".config/helm/repositories.yaml", ".config/helm/registry/config.json",
    "Library/Preferences/helm/repositories.yaml", "Library/Preferences/helm/registry/config.json",
    ".kube/config", ".codex/auth.json", ".codex/.credentials.json", ".codex/shell_snapshots",
    ".claude/.credentials.json", ".claude/shell-snapshots", ".claude/backups",
    ".claude.json", ".claude.json.backup", ".terraform.d/credentials.tfrc.json",
    ".terraformrc", ".vault-token", ".azure", ".cargo/credentials.toml",
    ".cargo/credentials", ".curlrc", ".wgetrc", ".bundle/config",
    ".config/composer/auth.json", ".composer/auth.json", ".config/pypoetry/auth.toml",
    "Library/Application Support/pypoetry/auth.toml", ".config/pip/pip.conf",
    ".pip/pip.conf", "Library/Application Support/pip/pip.conf",
    ".zsh_sessions", ".bash_sessions", "Library/Keychains",
)
# ホーム外でも保護するパス断片
CREDENTIAL_FRAGMENTS = tuple(path.casefold() for path in CREDENTIAL_LOCATIONS) + (
    "gh/hosts.yml", "gcloud/application_default_credentials.json", "gcloud/credentials.db",
    "gcloud/access_tokens.db", "ocm/ocm.json", "helm/repositories.yaml",
    "helm/registry/config.json", "uv/credentials", "cargo/credentials.toml", "composer/auth.json",
)
CREDENTIAL_NAMES = set("""
    .git-credentials .netrc .pgpass .pg_service.conf pg_service.conf
    .pypirc .zsh_history .bash_history fish_history pip.conf
""".split())
CREDENTIAL_SUFFIXES = (".p12", ".pfx", ".p8", ".ppk", ".key", ".keystore", ".jks", ".kdbx")
CREDENTIAL_PATH_VARIABLES = set("""
    AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE KUBECONFIG GH_CONFIG_DIR
    GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CREDENTIALS CLOUDSDK_CONFIG
    DOCKER_CONFIG REGISTRY_AUTH_FILE TF_CLI_CONFIG_FILE OCM_CONFIG
    HELM_REPOSITORY_CONFIG HELM_REGISTRY_CONFIG PGPASSFILE PGSERVICEFILE
    PIP_CONFIG_FILE NETRC
    AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE AWS_LOGIN_CACHE_DIRECTORY
    AWS_WEB_IDENTITY_TOKEN_FILE AZURE_CONFIG_DIR BUNDLE_USER_CONFIG
    CARGO_HOME COMPOSER_HOME DOCKER_CERT_PATH GNUPGHOME
    HELM_CONFIG_HOME PGSSLKEY PGSYSCONFDIR UV_CREDENTIALS_DIR WGETRC
""".split())


def path_spellings(value, cwd):
    """本文を読まず、ホーム表記・symlink を解決"""
    if UNKNOWN_ARGUMENT in value:
        return set()
    if value.startswith(("file://", "fileb://")):
        value = unquote(urlsplit(value).path)
    home = os.path.expanduser("~")
    # HOME は置換文字列として再解釈せず挿入
    value = re.sub(r"\$(?:HOME\b|\{HOME\})", lambda _match: home, value)
    value = os.path.expanduser(value)
    if cwd is None and not os.path.isabs(value):
        # cwd 不明でも既知の秘密名を検査
        return {"./" + os.path.normpath(value).casefold()}
    path = value if os.path.isabs(value) else os.path.join(cwd, value)
    return {os.path.normpath(path).casefold(), os.path.realpath(path).casefold()}


def credential_path(value, cwd):
    """認証情報を指すパス・変数参照を判定"""
    if not value or value == "-":
        return False
    variables = re.findall(r"\$(?:\{([A-Za-z_][A-Za-z_0-9]*)[^}]*\}|([A-Za-z_][A-Za-z_0-9]*))", value)
    if any((braced or plain).upper() in CREDENTIAL_PATH_VARIABLES for braced, plain in variables):
        return True
    if re.match(r"[A-Za-z][A-Za-z0-9+.-]*://", value) and not value.startswith(("file://", "fileb://")):
        return False
    for path in path_spellings(value, cwd):
        parts = path.split("/")
        name = parts[-1]
        if any(part.startswith(".env") or part in {"secrets", "credentials"} for part in parts):
            return True
        if name in CREDENTIAL_NAMES or ".tfstate" in name or name.endswith(CREDENTIAL_SUFFIXES):
            return True
        if name.endswith(".json") and re.search(r"(?:^|[-_.])(?:service[-_]account|client[-_]secret)(?:[-_.]|$)", name):
            return True
        if not name.endswith(".pub") and name.startswith(("id_rsa", "id_dsa", "id_ecdsa", "id_ed25519")):
            return True
        public_key = name.endswith((".pub", ".crt", ".cer")) or bool(re.search(r"(?:^|[-_.])public(?:[-_.]|$)", name))
        if not public_key and name.endswith((".pem", ".der")) and re.search(r"(?:^|[-_.])(?:key|priv|private|privkey|privatekey)(?:[-_.]|$)", name):
            return True
        normalized = re.sub(r"(?<=/)\.codex-account-[^/]+(?=/)", ".codex", path)
        for fragment in CREDENTIAL_FRAGMENTS:
            if fragment == ".ssh" and public_key:
                continue
            if "/" + fragment + "/" in normalized + "/":
                return True
    return False


def path_exposes_credentials(value, cwd):
    """認証情報・保管先の親ディレクトリを判定"""
    if credential_path(value, cwd):
        return True
    if re.search(r"(?:^|/)\.codex-account-[^/]+/?$", value, re.IGNORECASE):
        return True
    home = os.path.expanduser("~")
    protected = [os.path.join(home, path).casefold() for path in CREDENTIAL_LOCATIONS]
    protected.append("/library/keychains")
    directories = {
        "/".join(parts[:index])
        for fragment in CREDENTIAL_FRAGMENTS
        for parts in [fragment.split("/")]
        for index in range(1, len(parts))
    }
    if any(path.endswith("/" + directory) for path in path_spellings(value, cwd) for directory in directories):
        return True
    return any(
        target.startswith(path.rstrip("/") + "/")
        for path in path_spellings(value, cwd)
        if os.path.isabs(path)
        for target in protected
    )


def path_arguments(args, value_options=()):
    """位置引数と既知のオプション値を分離"""
    operands, values = [], {}
    index = 0
    while index < len(args):
        argument = args[index]
        index += 1
        if argument == "--":
            operands.extend(args[index:])
            break
        if not argument.startswith("-") or argument == "-":
            operands.append(argument)
            continue
        option, separator, value = argument.partition("=")
        if option not in value_options and not argument.startswith("--"):
            for offset, letter in enumerate(argument[1:], 1):
                if "-" + letter in value_options:
                    option = "-" + letter
                    value = argument[offset + 1:]
                    separator = bool(value)
                    break
        if option not in value_options:
            continue
        if not separator:
            if index == len(args):
                deny("ファイル入力オプションの値がありません。")
            value = args[index]
            index += 1
        values.setdefault(option, []).append(value)
    return operands, values


GIT_CONTENT_OPTIONS = set("""
    --output -o --pathspec-from-file
    -G -S --word-diff-regex --grep --author --committer
    --date --since --until --after --before --encoding
    --max-count -n --skip -L -O --contents
    --stat-width --stat-name-width --stat-graph-width --stat-count
""".split())


def git_metadata_only(operation, args):
    """パッチを出さないメタデータ表示を判定"""
    metadata, patch, names_only = operation in {"log", "reflog"}, False, False
    index = 0
    while index < len(args) and args[index] != "--":
        argument = args[index]
        option, separator, _value = argument.partition("=")
        index += 1
        if option in GIT_CONTENT_OPTIONS:
            if option in {"-L", "--word-diff-regex"}:
                patch = True
            if option.startswith("--stat-"):
                metadata = True
            index += not separator
        elif option in {"--name-only", "--name-status", "--quiet"}:
            names_only = True
        # 統計とパッチは併存し、no-patch は先行パッチを解除
        elif option in {"--stat", "--numstat", "--shortstat", "--summary", "--raw", "--dirstat", "--dirstat-by-file", "--compact-summary"}:
            metadata = True
        elif option == "--no-patch":
            metadata, patch = True, False
        elif option in {"--patch", "--patch-with-stat", "--patch-with-raw", "--word-diff", "--color-words", "--check", "--cc", "--dd", "--remerge-diff", "--binary", "--unified", "--function-context"}:
            patch = True
        elif argument.startswith("-") and not argument.startswith("--"):
            for flag in argument[1:]:
                if "-" + flag in GIT_CONTENT_OPTIONS:
                    if flag == "L":
                        patch = True
                    break
                elif flag == "s":
                    metadata, patch = True, False
                elif flag in "puUcWL":
                    patch = True
    return names_only or (metadata and not patch)


def check_path(value, cwd, recursive=False):
    """認証情報のパスを拒否（recursive は保管先の親も対象）"""
    predicate = path_exposes_credentials if recursive else credential_path
    if predicate(value, cwd):
        deny("認証情報ファイルの直接読み取り・持ち出しは許可していません。")


def check_path_values(values, options, cwd):
    """オプション値のパスを検査"""
    for option in options:
        for value in values.get(option, []):
            check_path(value, cwd)


def inspect_grep_paths(args, cwd):
    """grep・rg の検索対象ファイルを検査"""
    operands, values = path_arguments(args, {
        "-e", "--regexp", "-f", "--file", "-g", "--glob", "--iglob", "-t", "--type",
        "-T", "--type-not", "-A", "-B", "-C", "-m", "--max-count", "--context",
        "--color", "--colors", "--encoding", "--exclude", "--exclude-dir", "--include",
        "--ignore-file", "--exclude-from", "--replace", "--type-add", "--type-clear", "--max-depth",
    })
    check_path_values(values, {"-f", "--file", "--ignore-file", "--exclude-from"}, cwd)
    if not values.keys() & {"-e", "--regexp", "-f", "--file"}:
        operands = operands[1:]
    return operands, cwd


def inspect_filter_paths(command, args, cwd):
    """フィルターの入力ファイルを検査"""
    program_options = {"-e", "--expression", "-f", "--file"}
    if command in {"awk", "gawk", "mawk", "nawk"}:
        program_options |= {"-F", "-v"}
    # BSD sed の -i '' は空の拡張子
    if command in {"sed", "gsed"}:
        args = [argument for index, argument in enumerate(args) if not (index and args[index - 1] == "-i" and argument == "")]
    if command in {"jq", "yq"}:
        program_options = {"-f", "--from-file", "--indent"}
        remaining = []
        index = 0
        while index < len(args):
            argument = args[index]
            if argument in {"--arg", "--argjson", "--slurpfile", "--rawfile"}:
                if index + 2 >= len(args):
                    deny("ファイル入力オプションの値がありません。")
                if argument in {"--slurpfile", "--rawfile"}:
                    check_path(args[index + 2], cwd)
                index += 3
            else:
                remaining.append(argument)
                index += 1
        args = remaining
    operands, values = path_arguments(args, program_options)
    check_path_values(values, {"-f", "--file", "--from-file"}, cwd)
    if not values.keys() & {"-e", "--expression", "-f", "--file", "--from-file"}:
        operands = operands[1:]
    if command in {"awk", "gawk", "mawk", "nawk"}:
        operands = [operand for operand in operands if not re.match(r"[A-Za-z_][A-Za-z_0-9]*=", operand)]
    return operands, cwd


def inspect_reader_paths(command, args, cwd):
    """ファイル読取コマンドの入力を検査"""
    reader_options = {
        "cmp": "--bytes --ignore-initial -i -n",
        "cut": "--bytes --characters --delimiter --fields -b -c -d -f",
        "diff": "--exclude --exclude-from --label -F -I -L -X -x",
        "file": "--exclude --files-from --magic-file -e -f -m",
        "head": "--bytes --lines -c -n",
        "hexdump": "-e -f -n -s",
        "less": "-P -T -j -p -t -x -z",
        "md5": "-s",
        "more": "-n",
        "nl": "-b -d -f -h -i -l -n -s -v -w",
        "od": "-A -N -j -t -w",
        "paste": "--delimiters -d",
        "shasum": "--algorithm -a",
        "sort": "--buffer-size --field-separator --files0-from --key --output --random-source --temporary-directory -S -T -k -o -t",
        "strings": "-e -n -t",
        "tail": "--bytes --lines --sleep-interval -c -n -s",
        "uniq": "-f -s -w",
        "wc": "--files0-from",
        "xxd": "-c -g -l -o -s",
    }
    if command in {"base64", "base32"}:
        operands, values = path_arguments(args, {"-i", "--input", "-o", "--output", "-w", "--wrap"})
        check_path_values(values, {"-i", "--input"}, cwd)
    else:
        operands, values = path_arguments(args, set(reader_options.get(command, "").split()))
    check_path_values(values, {"--files0-from", "--random-source"}, cwd)
    if command in {"hexdump", "file"}:
        check_path_values(values, {"-f", "--files-from", "-m", "--magic-file"}, cwd)
    if command == "diff":
        check_path_values(values, {"-X", "--exclude-from"}, cwd)
    # 第2位置引数は出力先
    if command in {"uniq", "xxd"}:
        operands = operands[:1]
    return operands, cwd


def inspect_copy_paths(command, args, cwd):
    """コピー元の認証情報・保管先の親を検査"""
    copy_options = {
        "cp": "--suffix --target-directory -S -t",
        "rsync": "--exclude --exclude-from --files-from --include --include-from --password-file --rsh -e",
        "scp": "-D -F -J -P -S -c -i -l -o",
    }
    operands, values = path_arguments(args, set(copy_options[command].split()))
    check_path_values(values, {"--exclude-from", "--include-from", "--files-from", "--password-file"}, cwd)
    sources = operands if values.keys() & {"-t", "--target-directory"} else operands[:-1]
    for source in sources:
        if command in {"scp", "rsync"} and ":" in source:
            source = source.split(":", 1)[1]
        check_path(source, cwd, recursive=True)


def inspect_dd_paths(args, cwd):
    """dd の入力ファイルを検査"""
    for argument in args:
        if argument.startswith("if="):
            check_path(argument[3:], cwd)


def inspect_git_paths(args, cwd):
    """git の読取対象ファイルを検査"""
    index, cwd = git_command_context(args, cwd)
    if index >= len(args):
        return
    operation, args = args[index], args[index + 1:]
    file_options = {"--pathspec-from-file"}
    if operation in {"commit", "tag", "merge", "notes", "fmt-merge-msg"}:
        file_options |= {"-F", "--file"}
    if operation == "commit":
        file_options |= {"-t", "--template"}
    value_options = set(file_options)
    if operation in {"show", "diff", "diff-files", "diff-index", "diff-tree", "difftool", "log", "reflog", "format-patch", "whatchanged"}:
        value_options |= GIT_CONTENT_OPTIONS
    elif operation in {"blame", "annotate"}:
        file_options |= {"--contents", "-S", "--ignore-revs-file"}
        value_options |= file_options | {"-L", "--ignore-rev", "--date"}
    elif operation in {"commit", "tag", "merge", "notes", "fmt-merge-msg"}:
        value_options |= {"-m", "--message", "-u", "--ref"}
    if operation == "archive":
        value_options |= {"--format", "--prefix", "--remote", "--exec", "--add-file", "--add-virtual-file"}
        file_options.add("--add-file")
    operands, values = path_arguments(args, value_options)
    check_path_values(values, file_options | {"--contents", "-O"}, cwd)
    if operation == "log":
        for selection in values.get("-L", []):
            if ":" in selection:
                check_path(selection.rsplit(":", 1)[1], cwd)
    if operation in {"show", "cat-file"}:
        for operand in operands:
            if ":" in operand:
                path = re.sub(r"^:[0-3]:", ":", operand).split(":", 1)[1]
                check_path(path, cwd)
    if operation in {"show", "diff", "diff-files", "diff-index", "diff-tree", "log", "reflog"} and git_metadata_only(operation, args):
        return
    if operation not in {"show", "diff", "diff-files", "diff-index", "diff-tree", "difftool", "log", "reflog", "grep", "archive", "cat-file", "blame", "annotate", "format-patch", "fast-export", "checkout-index", "whatchanged"}:
        return
    if operation == "grep":
        inspect_paths("grep", args, cwd)
        return
    return operands, cwd


def inspect_openssl_paths(args, cwd):
    """openssl の入力ファイルを検査"""
    input_options = {"-in", "-inkey", "-key", "-cert", "-CAfile", "-CApath", "-config", "-extfile", "-signkey", "-untrusted", "-chain", "-certfile"}
    # 接続用の鍵・証明書は出力しない
    if args[:1] in (["s_client"], ["s_server"]):
        input_options -= {"-key", "-cert", "-CAfile", "-CApath"}
    _operands, values = path_arguments(args, input_options | {"-out", "-keyout", "-writerand"})
    check_path_values(values, input_options, cwd)


def inspect_tar_paths(args, cwd):
    """作成元・読み込むアーカイブ・入力リストを検査"""
    normalized = list(args)
    # 旧形式では先頭の - を省略できる
    if normalized and not normalized[0].startswith("-"):
        normalized[0] = "-" + normalized[0]
    operands, values = path_arguments(normalized, {"-f", "--file", "-C", "--directory", "-T", "--files-from", "-X", "--exclude-from", "--exclude", "--transform"})
    creating = any(argument == "--create" or (argument.startswith("-") and not argument.startswith("--") and any(flag in argument[1:] for flag in "cru")) for argument in normalized)
    check_path_values(values, {"-T", "--files-from", "-X", "--exclude-from"}, cwd)
    if not creating:
        check_path_values(values, {"-f", "--file"}, cwd)
        return
    for directory in values.get("-C", []) + values.get("--directory", []):
        cwd = resolve_path(directory, cwd)
    for operand in operands:
        check_path(operand, cwd, recursive=True)


def gh_file_options(args, direct_options, indirect_options, ignored_options):
    """サブコマンドごとのファイル指定の短縮形を補正"""
    direct_options, indirect_options = set(direct_options), set(indirect_options)
    ignored_options = ignored_options | {
        "-a", "--add", "-b", "--body", "-d", "--desc", "-f", "--filename",
        "-t", "--title", "-n", "--notes", "--notes-start-tag", "--target",
        "--discussion-category", "--type", "-s", "--source", "-T",
    }
    words, _values = path_arguments(args, direct_options | indirect_options | ignored_options)
    pair = tuple(words[:2])
    if pair in {
        ("issue", "comment"), ("issue", "create"), ("issue", "edit"),
        ("pr", "comment"), ("pr", "create"), ("pr", "edit"), ("pr", "merge"),
        ("pr", "review"), ("pr", "revert"), ("release", "create"), ("release", "edit"),
    }:
        direct_options.add("-F")
        indirect_options.discard("-F")
    if pair == ("pr", "create"):
        direct_options |= {"-T", "--template"}
    elif pair in {("repo", "create"), ("repo", "new")}:
        direct_options |= {"-s", "--source"}
    elif pair == ("gist", "edit"):
        direct_options |= {"-a", "--add"}
    elif pair in {("secret", "set"), ("variable", "set")}:
        direct_options.add("-f")
    elif pair == ("attestation", "verify"):
        direct_options.add("-b")
    return direct_options, indirect_options, ignored_options, pair


def inspect_transfer_paths(command, args, cwd):
    """送信・読み込むファイルを検査"""
    direct_options, indirect_options, ignored_options = (
        set(options.split())
        for options in {
            "curl": (
                "--config --upload-file -K -T",
                "--data --data-binary --data-urlencode --form --header --json --proxy-header -F -H -d",
                "--cacert --capath --cert --data-raw --form-string --key --netrc-file --output --proxy --proxy-cert --proxy-key --request --user -E -X -o -u -x",
            ),
            "gh": (
                "--body-file --bundle --env-file --input --notes-file",
                "--field -F",
                "--header --hostname --jq --method --raw-field --repo --template -H -R -X -f",
            ),
            "wget": (
                "--body-file --config --input-file --post-file -i",
                "",
                "--ca-certificate --certificate --load-cookies --output-document --output-file --private-key -O -o",
            ),
        }[command]
    )
    pair = ()
    if command == "gh":
        direct_options, indirect_options, ignored_options, pair = gh_file_options(args, direct_options, indirect_options, ignored_options)
    operands, values = path_arguments(args, direct_options | indirect_options | ignored_options | {"--url"})
    check_path_values(values, direct_options, cwd)
    for option in indirect_options:
        for value in values.get(option, []):
            source = None
            if option in {"-F", "--form", "--field"}:
                for marker in ("=@", "=<"):
                    if marker in value:
                        source = value.split(marker, 1)[1].split(";", 1)[0]
            elif value.startswith("@"):
                source = value[1:]
            elif option == "--data-urlencode" and "@" in value and "=" not in value.split("@", 1)[0]:
                source = value.split("@", 1)[1]
            if source is not None:
                for path in source.split(","):
                    check_path(path.removeprefix("@"), cwd)
    for value in operands + values.get("--url", []):
        if value.startswith(("file://", "fileb://")):
            check_path(value, cwd)
    if command == "gh":
        start = None
        if pair in {("gist", "create"), ("gist", "new"), ("ssh-key", "add"), ("gpg-key", "add"), ("attestation", "verify"), ("attestation", "download")}:
            start = 2
        elif pair in {("release", "create"), ("release", "new"), ("release", "upload"), ("gist", "edit")} or operands[:3] == ["repo", "deploy-key", "add"]:
            start = 3
        if start is not None:
            # release アセットは file#label で表示名を指定
            for value in operands[start:]:
                check_path(value.split("#", 1)[0] if pair[0] == "release" else value, cwd)


def inspect_container_paths(args, cwd):
    """コンテナへ渡すファイル・マウント・build context・socket を検査"""
    operands, values = path_arguments(args, {"-v", "--volume", "--mount", "--secret", "--env-file", "-f", "--file", "--build-context", "--config", "-H", "--host", "--name", "-e", "--env", "--build-arg", "-t", "--tag"})
    if not {"build", "run", "create", "cp", "compose"}.intersection(operands):
        return
    if "--use-api-socket" in args:
        deny("ホストの socket をコンテナへ渡す操作は許可していません。")
    if "--secret" in values:
        deny("secret をコンテナへ渡す操作は許可していません。")
    check_path_values(values, {"--env-file"}, cwd)
    if "build" in operands:
        check_path_values(values, {"-f", "--file"}, cwd)
    elif "compose" in operands:
        operations = operands[operands.index("compose") + 1:]
        boundary = args.index(operations[0]) if operations else len(args)
        _operands, compose_values = path_arguments(args[:boundary], {"-f", "--file"})
        check_path_values(compose_values, {"-f", "--file"}, cwd)
    for value in values.get("-v", []) + values.get("--volume", []):
        source = value.split(":", 1)[0]
        if source.endswith(".sock"):
            deny("ホストの socket をコンテナへ渡す操作は許可していません。")
        # パス表記以外は named volume
        if source.startswith(("/", ".", "~", "$")):
            check_path(source, cwd, recursive=True)
    for value in values.get("--mount", []):
        fields = dict(part.split("=", 1) for part in value.split(",") if "=" in part)
        source = fields.get("source", fields.get("src", ""))
        if source.endswith(".sock"):
            deny("ホストの socket をコンテナへ渡す操作は許可していません。")
        if source and fields.get("type", "bind") == "bind":
            check_path(source, cwd, recursive=True)
    if "cp" in operands and len(operands) >= 3:
        source = operands[operands.index("cp") + 1]
        check_path(source.split(":", 1)[-1], cwd, recursive=True)
    if "build" in operands and operands[-1] != "build":
        check_path(operands[-1], cwd, recursive=True)
    for value in values.get("--build-context", []):
        check_path(value.partition("=")[2], cwd, recursive=True)


def inspect_paths(command, args, cwd):
    """読み取り・送信するファイルの認証情報を検査"""
    if command in {"echo", "printf", "test", "[", "[[", "ls", "stat", "touch", "mkdir", "chmod", "chown", "chgrp", "rm", "rmdir", "mv", "ln"}:
        return
    if command in {"grep", "egrep", "fgrep", "rg"}:
        result = inspect_grep_paths(args, cwd)
    elif command in {"sed", "gsed", "awk", "gawk", "mawk", "nawk", "jq", "yq"}:
        result = inspect_filter_paths(command, args, cwd)
    elif command in {"cat", "head", "tail", "less", "more", "nl", "wc", "sort", "uniq", "cut", "paste", "od", "xxd", "hexdump", "strings", "base64", "base32", "md5", "md5sum", "sha1sum", "sha256sum", "shasum", "cksum", "file", "diff", "cmp", "comm"}:
        result = inspect_reader_paths(command, args, cwd)
    elif command in {"cp", "scp", "rsync"}:
        result = inspect_copy_paths(command, args, cwd)
    elif command == "dd":
        result = inspect_dd_paths(args, cwd)
    elif command == "git":
        result = inspect_git_paths(args, cwd)
    elif command == "openssl":
        result = inspect_openssl_paths(args, cwd)
    elif command == "tar":
        result = inspect_tar_paths(args, cwd)
    elif command in {"curl", "wget", "gh"}:
        result = inspect_transfer_paths(command, args, cwd)
    elif command == "docker":
        result = inspect_container_paths(args, cwd)
    else:
        for argument in args:
            value = argument.partition("=")[2] if "=" in argument else argument
            if value.startswith(("file://", "fileb://")):
                check_path(value, cwd)
        return
    if result is None:
        return
    operands, cwd = result
    for operand in operands:
        check_path(operand, cwd)


SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
SEPARATORS = {";", "&", "&&", "||", "|", "|&", "(", ")", "{", "}", "\n", ";;", ";&", ";;&"}
REDIRECTIONS = {"<", ">", ">>", "<>", ">|", "<<", "<<-", "<<<", "<&", ">&", "&>", "&>>"}
OPERATORS = sorted(SEPARATORS | REDIRECTIONS, key=len, reverse=True)
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(?:\[[^]]*\])?\+?=(.*)$", re.S)
PARAMETER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# 代入を拒否する実行設定変数
EXECUTION_VARIABLES = set("""
    BASH_ENV ENV ZDOTDIR SHELLOPTS SUDO_ASKPASS
    GIT_ASKPASS GIT_EXEC_PATH
    GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
    GIT_CONFIG_PARAMETERS GIT_TEMPLATE_DIR
    DOCKER_CLI_PLUGIN_EXTRA_DIRS
""".split())
EXECUTION_PREFIXES = ("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")
# 値をシェルコードとして検査
COMMAND_VARIABLES = set("""
    SUDO_EDITOR GIT_SSH GIT_SSH_COMMAND GIT_EDITOR GIT_SEQUENCE_EDITOR
    GIT_PAGER GH_PAGER GH_EDITOR GH_BROWSER PAGER EDITOR VISUAL
    BROWSER AWS_PAGER MANPAGER TG_TF_PATH TERRAGRUNT_TFPATH
    npm_config_call npm_config_script_shell
""".split())
PROXIES = {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "FTP_PROXY", "PIP_PROXY"}
# 代入可・展開不可の変数
REFERENCE_VARIABLES = {"SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_AGENT_INFO", "DOCKER_HOST"}


@dataclass
class Word:
    """シェルの語・展開変数名・引用・コマンド置換"""
    value: str
    parameters: set = field(default_factory=set)
    quoted: bool = False
    substitutions: list = field(default_factory=list)


def ansi_c_quote(text, index):
    """$'...' の値と閉じ引用符の次の位置"""
    value = bytearray()
    escapes = dict(zip("abefnrtvE", "\a\b\x1b\f\n\r\t\v\x1b"))
    while index < len(text):
        char = text[index]
        index += 1
        if char == "'":
            return os.fsdecode(bytes(value)), index
        if char != "\\":
            value.extend(os.fsencode(char))
            continue
        if index >= len(text):
            break
        escape = text[index]
        index += 1
        if escape in escapes:
            char = escapes[escape]
        elif escape in "\\'\"?":
            char = escape
        elif escape in "01234567xuU":
            if escape in "01234567":
                index -= 1
                pattern, base = r"[0-7]{1,3}", 8
            else:
                width = {"x": 2, "u": 4, "U": 8}[escape]
                pattern, base = r"[0-9a-fA-F]{1," + str(width) + "}", 16
            match = re.match(pattern, text[index:])
            if not match:
                raise ParseError("invalid ANSI-C escape")
            number = int(match.group(), base)
            index += len(match.group())
            if escape not in "uU":
                number %= 256
                if number == 0:
                    raise ParseError("NUL in ANSI-C quote")
                value.append(number)
                continue
            char = chr(number)
        elif escape == "c":
            if index >= len(text) or not text[index].isascii() or text[index] == "\\":
                raise ParseError("unsupported ANSI-C control escape")
            char = chr(127 if text[index] == "?" else ord(text[index].upper()) & 31)
            index += 1
        else:
            char = "\\" + escape
        if "\0" in char:
            raise ParseError("NUL in ANSI-C quote")
        value.extend(os.fsencode(char))
    raise ParseError("unterminated ANSI-C quote")


def heredoc_delimiter(text, index):
    """引用解除後の区切り語・次の位置（コマンド置換は None）"""
    delimiter, quote, substituted, started = [], None, False, False
    while index < len(text):
        char = text[index]
        if quote == "'":
            if char == "'":
                quote = None
            else:
                delimiter.append(char)
            index += 1
            continue
        if char == "\\":
            if index + 1 >= len(text):
                raise ParseError("unfinished shell escape")
            following = text[index + 1]
            if following != "\n":
                if quote == '"' and following not in '$`"\\':
                    delimiter.append("\\")
                delimiter.append(following)
                started = True
            index += 2
            continue
        if char in "'\"":
            if quote == char:
                quote = None
            elif quote is None:
                quote = char
            else:
                delimiter.append(char)
            started = True
            index += 1
            continue
        if quote is None:
            if char in " \t":
                if started:
                    break
                index += 1
                continue
            if char in "\r\n|&;()<>":
                break
            if text.startswith('$"', index):
                index += 1
                continue
            if text.startswith("$'", index):
                decoded, index = ansi_c_quote(text, index + 2)
                delimiter.append(decoded)
                started = True
                continue
        # 区切り語を展開せず、範囲不明のコマンド置換は除外
        if char == "`" or text.startswith("$(", index):
            substituted = started = True
            index += 1
            continue
        if text.startswith("${", index):
            end = group_end(text, index + 2, "{", "}")
            body = text[index + 2:end]
            if body.startswith("!") or re.search(r"@P$", body):
                deny("間接参照・再評価によるパラメータ展開は許可していません。")
            delimiter.append(text[index:end + 1])
            started = True
            index = end + 1
            continue
        if char == "$":
            match = PARAMETER.match(text, index + 1)
            if match:
                name = match.group()
                delimiter.append("$" + name)
                started = True
                index = match.end()
                continue
        delimiter.append(char)
        started = True
        index += 1
    if quote:
        raise ParseError("unterminated shell quote")
    if not started:
        raise ParseError("heredoc delimiter is missing")
    return None if substituted else "".join(delimiter), index


def heredoc_body(text, index, delimiter, strip_tabs):
    """heredoc 本文と区切り語直後の位置"""
    body = []
    while index < len(text):
        end = text.find("\n", index)
        end = len(text) if end < 0 else end
        line = text[index:end]
        if strip_tabs:
            index += len(line) - len(line.lstrip("\t"))
            line = line.lstrip("\t")
        if line.rstrip("\r") == delimiter:
            return "".join(body), index + len(delimiter)
        body.append(line + "\n")
        index = end + 1
    raise ParseError("unterminated heredoc")


def group_end(text, start, opening, closing, heredocs=False):
    """引用を飛ばして展開の終端を探す"""
    depth, quote, index = 1, None, start
    pending, arithmetic, comment, backtick = [], [], False, False
    while index < len(text):
        char = text[index]
        if quote is None and text.startswith("$'", index):
            _, index = ansi_c_quote(text, index + 2)
            continue
        if char == "\\" and quote != "'":
            index += 2
            continue
        if heredocs and not comment and quote != "'" and text.startswith("$(", index) and not text.startswith("$((", index):
            # 入れ子のコマンド置換は引用も独立
            index = group_end(text, index + 2, "(", ")", heredocs=True) + 1
            continue
        if quote:
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif heredocs and char == "`":
            # バッククォートの heredoc は shell_tokens で処理
            backtick = not backtick
        elif heredocs and text.startswith("((", index):
            # 二重括弧内の << は左シフト
            arithmetic.append(depth)
            depth += 2
            index += 2
            continue
        elif char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if not depth:
                return index
            while arithmetic and depth <= arithmetic[-1]:
                arithmetic.pop()
            # 閉じた括弧内の heredoc は本文を読めない
            pending = [item for item in pending if item[0] <= depth]
        elif heredocs and char == "#" and text[index - 1] in " \t\n;&|(":
            # コメント内も引用・括弧を追跡し、heredoc は無視
            comment = True
        elif heredocs and not comment and not backtick and not arithmetic and text.startswith("<<", index):
            if text.startswith("<<<", index):
                index += 3
                continue
            strip_tabs = text.startswith("<<-", index)
            delimiter, index = heredoc_delimiter(text, index + (3 if strip_tabs else 2))
            if delimiter is not None:
                pending.append((depth, delimiter, strip_tabs))
            continue
        elif heredocs and char == "\n":
            comment = False
            if pending and not backtick:
                _, delimiter, strip_tabs = pending.pop(0)
                body, index = heredoc_body(text, index + 1, delimiter, strip_tabs)
                # heredoc 本文の余分な閉じ括弧はシェルにより終端扱い
                level = 0
                for item in body:
                    level += (item == opening) - (item == closing)
                    if level < 0:
                        raise ParseError("unbalanced heredoc body")
                # 区切り語の後の閉じ括弧はシェルにより解釈が異なる
                if any(line.startswith(delimiter) and closing in line for line in body.split("\n")):
                    raise ParseError("ambiguous heredoc terminator")
                continue
        index += 1
    raise ParseError("unterminated shell expansion")


def shell_tokens(text, literal=False):
    """引用・演算子を区別し、変数値・関数・実行結果は推論しない"""
    tokens, pending = [], []
    value, parameters, substitutions = [], set(), []
    quote, quoted, started = None, False, False
    index = 0

    def flush():
        """語の確定・heredoc 本文の予約"""
        nonlocal value, parameters, substitutions, quoted, started
        if started:
            word = Word("".join(value), parameters, quoted, substitutions)
            if tokens and tokens[-1] in ("<<", "<<-"):
                pending.append((len(tokens), word.value, tokens[-1] == "<<-", quoted))
            tokens.append(word)
        value, parameters, substitutions, quoted, started = [], set(), [], False, False

    while index < len(text):
        char = text[index]
        if quote == "'":
            if char == "'":
                quote = None
            else:
                value.append(char)
            index += 1
            continue
        if not literal and quote is None and text.startswith("$'", index):
            decoded, index = ansi_c_quote(text, index + 2)
            value.append(decoded)
            quoted = started = True
            continue
        if not literal and quote is None and text.startswith('$"', index):
            index += 1
            continue
        if char == "\\":
            if index + 1 >= len(text):
                raise ParseError("unfinished shell escape")
            following = text[index + 1]
            if following != "\n":
                if (quote == '"' or literal) and following not in '$`"\\':
                    value.append("\\")
                value.append(following)
                started = True
            index += 2
            continue
        if not literal and char in "'\"":
            if quote == char:
                quote = None
            elif quote is None:
                quote = char
            else:
                value.append(char)
            quoted = started = True
            index += 1
            continue
        if char == "`":
            end = index + 1
            while end < len(text) and text[end] != "`":
                end += 2 if text[end] == "\\" else 1
            if end >= len(text):
                raise ParseError("unterminated command substitution")
            substitutions.append(text[index + 1:end])
            value.append("$()")
            started = True
            index = end + 1
            continue
        if text.startswith("$(", index) or (quote is None and text[index:index + 2] in {"<(", ">("}):
            arithmetic = text.startswith("$((", index)
            end = group_end(text, index + 2, "(", ")", heredocs=not arithmetic)
            body = text[index + 2:end]
            if arithmetic:
                _, inner = shell_tokens(body[1:-1], literal=True)
                substitutions.extend(inner)
                parameters.update(PARAMETER.findall(body))
            else:
                substitutions.append(body)
            value.append("$()")
            started = True
            index = end + 1
            continue
        if text.startswith("${", index):
            end = group_end(text, index + 2, "{", "}")
            body = text[index + 2:end]
            if body.startswith("!") or re.search(r"@P$", body):
                deny("間接参照・再評価によるパラメータ展開は許可していません。")
            match = PARAMETER.match(body)
            if match and not body[match.end():].startswith(("+", ":+")):
                parameters.add(match.group())
            _, inner = shell_tokens(body, literal=True)
            substitutions.extend(inner)
            # heredoc 区切り語の HOME は展開しない
            heredoc_word = tokens and tokens[-1] in ("<<", "<<-")
            value.append(os.path.expanduser("~") if body == "HOME" and not heredoc_word else text[index:end + 1])
            started = True
            index = end + 1
            continue
        if char == "$":
            match = PARAMETER.match(text, index + 1)
            if match:
                name = match.group()
                parameters.add(name)
                heredoc_word = tokens and tokens[-1] in ("<<", "<<-")
                value.append(os.path.expanduser("~") if name == "HOME" and not heredoc_word else "$" + name)
                started = True
                index = match.end()
                continue
        if not literal and quote is None:
            if char == "#" and not started:
                end = text.find("\n", index)
                index = len(text) if end < 0 else end
                continue
            if char in " \t\r":
                flush()
                index += 1
                continue
            operator = next((op for op in OPERATORS if text.startswith(op, index)), None)
            if operator:
                flush()
                tokens.append(operator)
                index += len(operator)
                if operator == "\n":
                    for token_index, delimiter, strip_tabs, is_quoted in pending:
                        body, index = heredoc_body(text, index, delimiter, strip_tabs)
                        end = text.find("\n", index)
                        index = len(text) if end < 0 else end + 1
                        names, inner = set(), []
                        if not is_quoted:
                            expanded, inner = shell_tokens(body, literal=True)
                            for word in expanded:
                                names.update(word.parameters)
                        tokens[token_index] = Word(body, names, is_quoted, inner)
                    pending.clear()
                continue
        value.append(char)
        started = True
        index += 1
    if quote:
        raise ParseError("unterminated shell quote")
    flush()
    if pending:
        raise ParseError("heredoc body is missing")
    return tokens, [body for token in tokens if isinstance(token, Word) for body in token.substitutions]


def inspect_assignment(value, cwd):
    """代入による実行設定の差し替え・秘密値の平文指定を検査"""
    match = ASSIGNMENT.match(value)
    if not match:
        return
    name, content = match.groups()
    if name == "GOOGLE_CREDENTIALS":
        if content and (any(char in content for char in "{}\r\n$") or not content.startswith(("/", "./", "../"))):
            deny("GOOGLE_CREDENTIALS には静的なファイルパスだけを指定してください。")
        return
    if name in EXECUTION_VARIABLES or name.startswith(EXECUTION_PREFIXES):
        deny(EXEC_OVERRIDE_REASON)
    if name in COMMAND_VARIABLES and content:
        scan(content, cwd)
    if name.upper() in PROXIES:
        if "@" in content:
            deny("proxy の認証情報を引数へ載せることは許可していません。")
    elif name not in CREDENTIAL_PATH_VARIABLES | REFERENCE_VARIABLES and secret_name(name) and content:
        deny("秘密値を持つ環境変数への平文の代入は許可していません。")


def sensitive_parameter(name):
    """展開を拒否する変数を判定"""
    return name not in CREDENTIAL_PATH_VARIABLES and (
        secret_name(name)
        or name in REFERENCE_VARIABLES or name.upper() in PROXIES
    )


# ラッパー: 値付きオプション・フラグ
WRAPPER_OPTIONS = {
    command: (set(values.split()), set(flags.split()))
    for command, (values, flags) in {
        "!": ("", ""),
        "arch": ("-arch -d -e", "-32 -64 -arm64 -arm64e -c -i386 -x86_64 -x86_64h"),
        "builtin": ("", ""),
        "caffeinate": ("-t -w", "-d -i -m -s -u"),
        "command": ("", "-p"),
        "coproc": ("", ""),
        "env": ("--chdir --unset -C -u", "--ignore-environment --null -0 -i"),
        "exec": ("--argv0 -a", "-c -l"),
        "nice": ("--adjustment -n", ""),
        "nohup": ("", ""),
        "sudo": ("--chdir --close-from --group --host --prompt --user -C -D -g -h -p -u", "--list --non-interactive --preserve-env --validate -E -H -K -b -k -l -n -v"),
        "time": ("--format --output -f -o", "--append --portability --verbose -a -l -p -v"),
        "timeout": ("--kill-after --signal -k -s", "--foreground --preserve-status --verbose -v"),
        "xargs": ("--max-args --max-procs --replace -E -I -J -L -P -n -s", "--no-run-if-empty --null -0 -p -r -t -x"),
    }.items()
}
# 動的引数の目印（シェル引数に現れない NUL）
UNKNOWN_ARGUMENT = "\0"


def unwrap(command, args, cwd, inherited_assignments):
    """ラッパーから子コマンドの引数・cwd を抽出"""
    value_options, flags = WRAPPER_OPTIONS[command]
    args = list(args)
    assignments, replacements, index = [], [], 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            index += 1
            break
        if arg in {"--help", "--version"} or command == "sudo" and arg == "-V":
            return [], cwd
        if command == "command" and arg in {"-v", "-V"}:
            return [], cwd
        if command == "arch" and arg == "-h":
            return [], cwd
        if command == "xargs" and arg in {"-i", "--replace"}:
            replacements.append(("-I", "{}"))
            index += 1
            continue
        if command == "xargs" and arg.startswith("-i"):
            arg = args[index] = "-I" + arg[2:]
        if ASSIGNMENT.match(arg):
            inspect_assignment(arg, cwd)
            if arg.startswith(("TF_CLI_ARGS=", "TF_CLI_ARGS_")):
                assignments.append(arg)
            index += 1
            continue
        if not arg.startswith("-") or arg == "-":
            break
        if not arg.startswith("--") and len(arg) > 2 and arg not in value_options | flags:
            expanded = []
            for offset, letter in enumerate(arg[1:], 1):
                short = "-" + letter
                if short in value_options:
                    expanded.append(short)
                    if arg[offset + 1:]:
                        expanded.append(arg[offset + 1:])
                    break
                if short not in flags:
                    raise UnsupportedSyntax("unsupported wrapper option")
                expanded.append(short)
            args[index:index + 1] = expanded
            arg = args[index]
        option, separator, value = arg.partition("=")
        if option in value_options:
            if not separator:
                index += 1
                if index >= len(args):
                    raise ParseError("wrapper option argument is missing")
                value = args[index]
            if command == "env" and option in {"-u", "--unset"}:
                inherited_assignments.pop(value, None)
            if command == "arch" and option == "-e":
                inspect_assignment(value, cwd)
            if command == "xargs" and option in {"-I", "-J", "--replace"}:
                if not value:
                    raise ParseError("empty xargs replacement")
                replacements.append((option, value))
            if option in {"-D", "--chdir"} or command == "env" and option == "-C":
                if "$" in value:
                    raise UnsupportedSyntax("dynamic working directory")
                cwd = resolve_path(os.path.expanduser(value), cwd, os.path.abspath)
        elif command == "env" and arg in {"-i", "--ignore-environment"}:
            inherited_assignments.clear()
        elif arg not in flags:
            raise UnsupportedSyntax("unsupported wrapper option")
        index += 1
    # timeout の先頭位置引数は時間
    if command == "timeout" and index < len(args):
        index += 1
    child = args[index:]
    if command == "xargs":
        child = child or ["echo"]
        # 標準入力の値は未確定
        if not replacements:
            child.append(UNKNOWN_ARGUMENT)
        for option, value in replacements:
            if option == "-J":
                try:
                    position = child.index(value, 1)
                except ValueError:
                    child.append(UNKNOWN_ARGUMENT)
                else:
                    child[position] = UNKNOWN_ARGUMENT
            else:
                child[1:] = [UNKNOWN_ARGUMENT if value in arg else arg for arg in child[1:]]
    return assignments + child if child else [], cwd


# インタプリタ: コードフラグ・値付きオプション
INTERPRETER_OPTIONS = {
    "awk": ("", "-F -f -v"),
    "gawk": ("", "-F -f -v"),
    "node": ("ep", "--import --input-type --loader --require -r"),
    "perl": ("eE", "-I -M"),
    "php": ("r", "-c -d"),
    "python": ("c", "--check-hash-based-pycs -W -X"),
    "ruby": ("e", "--backtrace-limit --crash-report --disable --enable --encoding --external-encoding --internal-encoding --parser -C -E -I -r"),
}
CODE_READERS = {"open", "read_text", "read_bytes", "readFile", "readFileSync", "file_get_contents", "readfile"}
# AppleScript の文字列を検査から除外
STRING_LITERAL = re.compile(r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*' ''', re.S | re.X)


def mask_code(language, code, cwd, depth):
    """コメント・静的文字列を除き、補間式を別途検査"""
    strings, executable = [], []
    index = 0
    while index < len(code):
        char = code[index]
        line_comment = char == "#" and language != "node"
        line_comment |= language in {"node", "php"} and code.startswith("//", index)
        if line_comment:
            end = code.find("\n", index)
            index = len(code) if end < 0 else end
            continue
        if language in {"node", "php"} and code.startswith("/*", index):
            end = code.find("*/", index + 2)
            if end < 0:
                raise ParseError("unterminated code comment")
            executable.append(" ")
            index = end + 2
            continue
        if char not in "'\"`":
            executable.append(char)
            index += 1
            continue
        if char == "`" and language != "node":
            deny("直接コードからのコマンド置換は許可していません。")
        quote, value = char, []
        index += 1
        while index < len(code) and code[index] != quote:
            if code[index] == "\\":
                value.append(code[index:index + 2])
                index += 2
                continue
            prefix = code[index:index + 2]
            interpolated = (
                language == "ruby" and quote == '"' and prefix == "#{"
                or language == "node" and quote == "`" and prefix == "${"
                or language == "perl" and quote == '"' and prefix in {"${", "@{"}
                or language == "php" and quote == '"' and prefix in {"${", "{$"}
            )
            if interpolated:
                start = index + (1 if prefix == "{$" else 2)
                end = group_end(code, start, "{", "}")
                inspect_code(language, code[start:end], cwd, depth + 1)
                index = end + 1
                continue
            if quote != "'" and language in {"perl", "php"} and re.match(r"\$_?ENV\b", code[index:]):
                deny("コードからの環境変数取得は許可していません。")
            value.append(code[index])
            index += 1
        if index >= len(code):
            raise ParseError("unterminated code string")
        strings.append("".join(value))
        executable.append("__string_{}__".format(len(strings) - 1))
        index += 1
    return "".join(executable), strings


def qualified_name(node, aliases):
    """import 別名を解いた完全修飾名"""
    if isinstance(node, ast.Name):
        return aliases.get(node.id, node.id)
    if isinstance(node, ast.Attribute):
        return qualified_name(node.value, aliases) + "." + node.attr
    if isinstance(node, ast.Call):
        name = qualified_name(node.func, aliases)
        if name in {"getattr", "builtins.getattr"}:
            if len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and isinstance(node.args[1].value, str):
                return qualified_name(node.args[0], aliases) + "." + node.args[1].value
        elif name in {"__import__", "builtins.__import__"}:
            if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                return node.args[0].value
    return ""


def inspect_python_process(name, node, cwd, depth):
    """Python の静的な子コマンド・再評価コードを検査"""
    process_args = node.args[1:] if name.startswith("os.spawn") else node.args
    argument = process_args[0] if process_args else next((item.value for item in node.keywords if item.arg == "args"), None)
    if name in {"eval", "exec", "builtins.eval", "builtins.exec"}:
        if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
            inspect_code("python", argument.value, cwd, depth + 1)
    elif name in {"subprocess.Popen", "subprocess.run", "subprocess.call", "subprocess.check_call", "subprocess.check_output", "subprocess.getoutput", "subprocess.getstatusoutput"}:
        options = {item.arg: item.value.value for item in node.keywords if isinstance(item.value, ast.Constant)}
        directory = options.get("cwd")
        child_cwd = resolve_path(directory, cwd) if isinstance(directory, str) else cwd
        child = argument.elts if isinstance(argument, (ast.List, ast.Tuple)) else [argument]
        if child and all(isinstance(item, ast.Constant) and isinstance(item.value, str) for item in child):
            child = [item.value for item in child]
            if options.get("shell") or name in {"subprocess.getoutput", "subprocess.getstatusoutput"}:
                child = [options.get("executable") or "/bin/sh", "-c"] + child
            elif isinstance(options.get("executable"), str):
                child[0] = options["executable"]
            inspect_argv(child, child_cwd, depth + 1)
    elif re.match(r"os\.(?:system|popen|exec\w*|spawn\w*|posix_spawnp?)$", name):
        if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
            if name in {"os.system", "os.popen"}:
                scan(argument.value, cwd, depth + 1)
            elif len(process_args) > 1:
                child = process_args[1].elts if isinstance(process_args[1], (ast.List, ast.Tuple)) else process_args[1:]
                if all(isinstance(item, ast.Constant) and isinstance(item.value, str) for item in child):
                    inspect_argv([argument.value] + [item.value for item in child[1:]], cwd, depth + 1)


def inspect_python_code(code, cwd, depth):
    """Python の秘密取得・子コマンドを検査"""
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError) as error:
        raise UnsupportedSyntax("unsupported inline Python") from error
    aliases = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            aliases.update((item.asname or item.name, item.name) for item in node.names)
        elif isinstance(node, ast.ImportFrom):
            aliases.update((item.asname or item.name, (node.module or "") + "." + item.name) for item in node.names)

    for node in ast.walk(tree):
        if isinstance(node, ast.Subscript) and qualified_name(node.value, aliases) == "os.environ":
            if isinstance(node.slice, ast.Constant) and secret_name(str(node.slice.value)):
                deny("コードからの秘密環境変数の取得は許可していません。")
        if not isinstance(node, ast.Call):
            continue
        name = qualified_name(node.func, aliases)
        if name in {"getattr", "builtins.getattr"}:
            name = qualified_name(node, aliases)
        try:
            inspect_python_process(name, node, cwd, depth)
        except UnsupportedSyntax:
            pass
        if name in {"os.getenv", "os.environ.get"}:
            key = node.args[0] if node.args else next((item.value for item in node.keywords if item.arg == "key"), None)
            if isinstance(key, ast.Constant) and isinstance(key.value, str) and secret_name(key.value):
                deny("コードからの秘密環境変数の取得は許可していません。")
        if (
            name in {"dict", "list", "print"}
            and any(qualified_name(item, aliases) == "os.environ" for item in node.args)
            or name in {"os.environ.items", "os.environ.values"}
        ):
            deny("環境変数の一括取得は許可していません。")
        if name.rsplit(".", 1)[-1] in CODE_READERS:
            receiver = node.func.value if isinstance(node.func, ast.Attribute) else None
            sources = node.args[:1] + ([receiver] if receiver is not None else [])
            sources.extend(item.value for item in node.keywords if item.arg in {"file", "filename", "path"})
            literals = [
                item.value
                for source in sources
                for item in ast.walk(source)
                if isinstance(item, ast.Constant) and isinstance(item.value, str)
            ]
            if any(credential_path(value, cwd) for value in literals):
                deny("コードによる認証情報ファイルの直接読み取りは許可していません。")


def masked_call_options(language, options, strings, cwd):
    """shell 指定・子プロセスの cwd を抽出"""
    shell, child_cwd = False, cwd
    for key, setting in re.findall(r"([A-Za-z_0-9]+)\s*:\s*([A-Za-z_0-9]+)", options or ""):
        key_literal = re.fullmatch(r"__string_(\d+)__", key)
        if key_literal:
            key = strings[int(key_literal.group(1))]
        if key == "shell":
            shell = setting == "true" or setting.startswith("__string_")
        if key == "cwd" and language == "node":
            directory = re.fullmatch(r"__string_(\d+)__", setting)
            if directory:
                value = strings[int(directory.group(1))]
                if os.path.isabs(value) or cwd is not None:
                    child_cwd = resolve_path(value, cwd)
    return shell, child_cwd


def inspect_masked_calls(language, executable, strings, cwd, depth):
    """静的に決まる子コマンドを検査"""
    calls = (
        r"\b(eval|exec|execSync|execFile|execFileSync|spawn|spawnSync|system|popen|shell_exec|passthru|proc_open)"
        r"\s*\(?\s*__string_(\d+)__(?:\s*,\s*\[([^\]]*)\])?(?:\s*,\s*\{([^{}]*)\})?"
    )
    for match in re.finditer(calls, executable):
        name, literal, array, options = match.groups()
        value = strings[int(literal)]
        shell, child_cwd = masked_call_options(language, options, strings, cwd)
        child = []
        if array is not None:
            child = (
                [strings[int(index)] for index in re.findall(r"__string_(\d+)__", array)]
                if re.fullmatch(r"\s*(?:__string_\d+__\s*,?\s*)*", array)
                else None
            )
        elif language == "node" and name in {"execFile", "execFileSync", "spawn", "spawnSync"} and options is None:
            if re.match(r"\s*,", executable[match.end():]):
                child = None
        arguments = None
        if language in {"ruby", "perl"} and name in {"system", "exec", "spawn"}:
            arguments = re.match(r"(?:\s*,\s*__string_\d+__)+(?=\s*(?:,?\s*\)|;|\n|$))", executable[match.end():])
            if arguments:
                child = [strings[int(index)] for index in re.findall(r"__string_(\d+)__", arguments.group())]
            elif re.match(r"\s*,", executable[match.end():]):
                child = None
        try:
            if name == "eval":
                inspect_code(language, value, cwd, depth + 1)
            elif child is None:
                continue
            elif shell:
                scan(" ".join([value] + child), child_cwd, depth + 1)
            elif (
                array is not None or arguments is not None
                or name in {"execFile", "execFileSync", "spawnSync"}
                or name == "spawn" and language != "ruby"
            ):
                inspect_argv([value] + child, child_cwd, depth + 1)
            else:
                scan(value, child_cwd, depth + 1)
        except UnsupportedSyntax:
            pass


def inspect_masked_code(language, code, cwd, depth):
    """Python 以外の秘密取得・子コマンドを検査"""
    executable, strings = mask_code(language, code, cwd, depth)
    inspect_masked_calls(language, executable, strings, cwd, depth)
    for match in re.finditer(r"\b(?:open|readFile|readFileSync|file_get_contents|readfile|read|file|filebase64)\s*\(?\s*(?:pathexpand\s*\(\s*)?__string_(\d+)__", executable):
        if credential_path(strings[int(match.group(1))], cwd):
            deny("コードによる認証情報ファイルの直接読み取りは許可していません。")
    for match in re.finditer(r"\b(?:process\.env|ENV|_ENV)\b", executable):
        access = re.match(r"\s*(?:\.([A-Za-z_][A-Za-z_0-9]*)|[\[{]\s*(?:__string_(\d+)__|([A-Za-z_][A-Za-z_0-9]*))\s*[\]}])", executable[match.end():])
        if not access:
            deny("環境変数の一括取得は許可していません。")
        attribute, literal, key = access.groups()
        if attribute in {"fetch", "get"}:
            call = re.match(r"\s*\(?\s*__string_(\d+)__", executable[match.end() + access.end():])
            if not call:
                continue
            name = strings[int(call.group(1))]
        else:
            name = strings[int(literal)] if literal is not None else attribute or key
        if secret_name(name):
            deny("コードからの秘密環境変数の取得は許可していません。")


def inspect_code(language, code, cwd, depth=0):
    """直接記述されたファイル操作・秘密取得・プロセス起動だけを検査"""
    if depth > 32:
        raise ParseError("nested code limit exceeded")
    if UNKNOWN_ARGUMENT in code:
        raise UnsupportedSyntax("dynamic inline code")
    if language == "python":
        inspect_python_code(code, cwd, depth)
    else:
        inspect_masked_code(language, code, cwd, depth)


def interpreter_input(command, args):
    """入力形式と、位置引数をファイルとして読むかを判定"""
    code_flags, value_options = INTERPRETER_OPTIONS[command]
    value_flags = set(value_options.split())
    # 残りを結合値にするフラグ
    attached_flags = {"perl": "CDFimx", "ruby": "CEFix"}.get(command, "")
    # 値は1文字
    single_flags = "K" if command == "ruby" else ""
    # 値は : 以降
    colon_flags = {"perl": "dV", "ruby": "W"}.get(command, "")
    # perl の -a / -F は -n を暗黙に有効化
    reads_flags = {"perl": "npaF", "ruby": "np"}.get(command, "")
    no_run_flags = {"perl": "ch?v", "ruby": "ch"}.get(command, "")
    no_run_options = {
        "perl": {"--help", "--version"},
        "ruby": {"--help", "--version", "--copyright", "--yydebug"},
    }.get(command, set())
    chunks, script, operands, index = [], None, [], 0
    reads = command in {"awk", "gawk"}
    no_run = False
    while index < len(args):
        arg = args[index]
        if arg == "--":
            operands = args[index + 1:]
            script = operands[0] if operands else None
            break
        if arg == "-":
            script, operands = arg, args[index:]
            break
        if arg in value_flags:
            index += 2
            continue
        if arg.startswith("--"):
            if arg in no_run_options:
                no_run = True
            elif command == "ruby" and (arg == "--dump" or arg.startswith("--dump=")):
                value = arg.partition("=")[2]
                if arg == "--dump":
                    index += 1
                    if index >= len(args):
                        raise ParseError("dump option is missing")
                    value = args[index]
                no_run = no_run or any(
                    item.partition("+")[0]
                    in {"version", "copyright", "usage", "help", "yydebug", "syntax", "parsetree", "insns"}
                    for item in re.split(r"[\s,]+", value)
                )
            elif arg in {"--eval", "--print"}:
                if index + 1 >= len(args):
                    raise ParseError("inline code is missing")
                index += 1
                chunks.append(args[index])
            elif arg.startswith(("--eval=", "--print=")):
                chunks.append(arg.partition("=")[2])
        elif arg.startswith("-"):
            skip = False
            for position, flag in enumerate(arg[1:], 1):
                if skip:
                    skip = False
                    continue
                if flag in single_flags:
                    skip = True
                    continue
                if flag in colon_flags and (
                    arg[position + 1:position + 2] == ":"
                    or command == "perl" and flag == "d" and arg[position + 1:position + 3] == "t:"
                ):
                    break
                if flag in reads_flags:
                    reads = True
                if flag in no_run_flags:
                    no_run = True
                if "-" + flag in value_flags:
                    if not arg[position + 1:]:
                        index += 1
                    break
                if flag in attached_flags:
                    break
                is_module = command == "python" and flag == "m"
                if is_module or flag in code_flags:
                    value = arg[position + 1:]
                    if not value:
                        index += 1
                        if index >= len(args):
                            raise ParseError("Python module is missing" if is_module else "inline code is missing")
                        value = args[index]
                    if is_module:
                        return None, [value] + args[index + 1:], None, [], False
                    chunks.append(value)
                    break
        else:
            if command in {"awk", "gawk"} and not chunks:
                chunks.append(arg)
                operands = args[index + 1:]
            else:
                script, operands = arg, args[index:]
            break
        if chunks and command == "python":
            operands = args[index + 1:]
            break
        index += 1
    return "\n".join(chunks) if chunks else None, None, script, operands, reads and not no_run


def script_uses_stdin(path):
    """標準入力を指すスクリプトのパスか判定"""
    if UNKNOWN_ARGUMENT in path:
        raise UnsupportedSyntax("dynamic script path")
    if path in {"/dev/stdin", "/dev/fd/0", "/proc/self/fd/0"}:
        return True
    if re.match(r"^/(?:dev|proc/(?:self|\d+))/fd/", path):
        raise UnsupportedSyntax("uninspected script file descriptor")
    return False


def pop_assignments(argv, cwd):
    """先頭の代入を検査・除去し、terraform 用の値を抽出"""
    assignments = {}
    while argv and (match := ASSIGNMENT.match(argv[0])):
        assignment = argv.pop(0)
        inspect_assignment(assignment, cwd)
        name, value = match.groups()
        if name == "TF_CLI_ARGS" or name.startswith("TF_CLI_ARGS_"):
            assignments[name] = value
    return assignments


def env_split_args(args):
    """静的な env -S を引数へ展開"""
    for index, arg in enumerate(args):
        if arg in {"-S", "--split-string"} or arg.startswith("--split-string="):
            joined = "=" in arg
            if not joined and index + 1 >= len(args):
                raise ParseError("env split string is missing")
            value = arg.partition("=")[2] if joined else args[index + 1]
            split, nested = shell_tokens(value)
            if nested or any(not isinstance(word, Word) for word in split):
                raise UnsupportedSyntax("unsupported env split string")
            return args[:index] + [word.value for word in split] + args[index + (1 if joined else 2):]
    return args


def inspect_wrapper(command, args, assignments, cwd, depth, stdin, external):
    """子コマンドと env の一括出力を検査"""
    child, child_cwd = unwrap(command, args, cwd, assignments)
    if command == "env" and not child and not has_option(args, {"--help", "--version"}):
        deny("環境変数の一括出力は許可していません。")
    if child:
        child = [name + "=" + value for name, value in assignments.items()] + child
        if command == "xargs":
            inspect_argv(child, child_cwd, depth + 1, None, True)
        else:
            inspect_argv(child, child_cwd, depth + 1, stdin, external)


def terraform_args(command, args, assignments):
    """静的な TF_CLI_ARGS をサブコマンド直後へ挿入"""
    words = cli_words(command, args)
    while words and words[0] in {"run", "run-all", "stack"}:
        words = words[1:]
    if not words:
        return args
    additional = []
    for name in ("TF_CLI_ARGS", "TF_CLI_ARGS_" + words[0]):
        split, nested = shell_tokens(assignments.get(name, ""))
        if not nested and all(isinstance(word, Word) and not word.parameters for word in split):
            additional.extend(word.value for word in split)
    position = args.index(words[0]) + 1
    return args[:position] + additional + args[position:]


def inspect_recursive_removal(args, cwd):
    """再帰削除の対象がルート・ホーム全体か検査"""
    for target in args:
        if target.startswith("-") or UNKNOWN_ARGUMENT in target:
            continue
        path = resolve_path(os.path.expanduser(target), cwd, os.path.realpath)
        if path is None:
            continue
        path = path.rstrip("/") or "/"
        home = os.path.realpath(os.path.expanduser("~"))
        if path in {"/", home} or path.startswith("/*") or path.startswith(home + "/*"):
            deny("ルート・ホーム全体の再帰削除は許可していません。")


def inspect_container_exec(command, args, cwd, depth, stdin, external):
    """コンテナ内の子コマンド・引き渡す資格情報を検査"""
    if "--" in args and any(word in args[:args.index("--")] for word in {"exec", "rsh", "run"}):
        inspect_argv(args[args.index("--") + 1:], cwd, depth + 1, stdin, external)
    elif "exec" in args or "rsh" in args:
        operation = "exec" if "exec" in args else "rsh"
        words = cli_words(command, args[args.index(operation) + 1:], {"-e", "--env", "-u", "--user", "-w", "--workdir", "-c", "--container"})
        if len(words) > 1:
            inspect_argv(words[1:], cwd, depth + 1, stdin, external)
    if command == "docker":
        for value in option_values(args, {"-e", "--env", "--build-arg"}):
            name = value.partition("=")[0]
            # -e NAME（値なし）はホストの値を継承
            if sensitive_parameter(name) or name in CREDENTIAL_PATH_VARIABLES and "=" not in value:
                deny("資格情報をコンテナの環境へ渡すことは許可していません。")
        if has_option(args, {"--ssh"}):
            deny("認証エージェントをコンテナへ転送することは許可していません。")


def inspect_shell(args, cwd, depth, stdin, external):
    """-c・スクリプトを検査し、標準入力を読む起動だけ入力を検査"""
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"--rcfile", "--init-file"} or arg.startswith(("--rcfile=", "--init-file=")):
            deny("シェル起動ファイルの差し替えは許可していません。")
        if arg in {"-o", "-O", "+o", "+O"}:
            index += 2
            continue
        if arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]:
            if index + 1 >= len(args):
                raise ParseError("shell command string is missing")
            scan(args[index + 1], cwd, depth + 1, stdin, external)
            return
        if not arg.startswith("-"):
            if credential_path(arg, cwd):
                deny("認証情報ファイルをスクリプトとして読み込むことは許可していません。")
            if not script_uses_stdin(arg):
                return
            break
        index += 1
    if external:
        raise UnsupportedSyntax("uninspected shell input")
    if stdin is not None:
        scan(stdin, cwd, depth + 1)


def inspect_eval(command, args, cwd, depth, stdin, external):
    """eval・trap のシェルコードを検査"""
    values = args[1:] if args[:1] == ["--"] else args
    if values and values[0] not in {"-", "", "-l", "-p"}:
        scan(" ".join(values) if command == "eval" else values[0], cwd, depth + 1, stdin, external)


def inspect_source(args, cwd, depth, stdin, external):
    """source のファイル・標準入力を検査"""
    if args[:1] == ["--"]:
        args = args[1:]
    if args and credential_path(args[0], cwd):
        deny("認証情報ファイルの source は許可していません。")
    if args and script_uses_stdin(args[0]):
        if external:
            raise UnsupportedSyntax("uninspected source input")
        if stdin is not None:
            scan(stdin, cwd, depth + 1)


def inspect_osascript(args, stdin):
    """AppleScript からのシェル起動を検査"""
    for code in option_values(args, {"-e"}) + ([stdin] if stdin is not None else []):
        executable = STRING_LITERAL.sub('""', code)
        if re.search(r"\bdo\s+shell\s+script\b", executable, re.I):
            deny("AppleScript からのシェル起動は許可していません。")


def inspect_find(args, cwd, depth):
    """-exec 系の子コマンドを検査"""
    for index, arg in enumerate(args):
        if arg in {"-exec", "-execdir", "-ok", "-okdir"}:
            end = index + 1
            while end < len(args) and args[end] not in {";", "+"}:
                end += 1
            if end == len(args):
                raise ParseError("unterminated find executor")
            inspect_argv(args[index + 1:end], cwd, depth + 1)


def inspect_submodule_foreach(args, cwd, depth):
    """submodule foreach の子コマンドを検査"""
    index = args.index("foreach")
    if "submodule" in args[:index] and index + 1 < len(args):
        scan(args[index + 1], cwd, depth + 1)


def inspect_runner(command, args, cwd, depth):
    """ランナーの子コマンドを検査"""
    for code in option_values(args, {"-c", "--command", "--call"}):
        scan(code, cwd, depth + 1)
    if "--" in args:
        inspect_argv(args[args.index("--") + 1:], cwd, depth + 1)
    elif command in {"npx", "npm", "pnpm", "mise"}:
        # exe は npm だけが exec の短縮形（npx ではパッケージ名）
        runners = {"exec", "exe", "x"} if command == "npm" else {"exec", "x"}
        start = next((index + 1 for index, arg in enumerate(args) if arg in runners), 0 if command == "npx" else len(args))
        if start < len(args) and not args[start].startswith("-"):
            inspect_argv(args[start:], cwd, depth + 1)


def inspect_interpreter_operands(language, operands, cwd):
    """インタプリタが読む位置引数を検査"""
    for operand in operands:
        # awk の var=value は変数代入
        if language in {"awk", "gawk"} and re.match(r"[A-Za-z_][A-Za-z_0-9]*=", operand):
            continue
        check_path(operand, cwd)


def inspect_interpreter(language, args, cwd, depth, stdin, external):
    """コード・入力ファイルを検査"""
    code, module, script, operands, reads = interpreter_input(language, args)
    if module is not None:
        if UNKNOWN_ARGUMENT in module[0]:
            raise UnsupportedSyntax("dynamic Python module")
        if module[0] in {"pip", "pip3"}:
            inspect_argv(module, cwd, depth + 1)
        return
    if code is None and credential_path(script, cwd):
        deny("認証情報ファイルをコードとして読み込むことは許可していません。")
    unsupported = None
    try:
        if code is not None:
            inspect_code(language, code, cwd)
        else:
            uses_stdin = not script or script == "-" or script_uses_stdin(script)
            if uses_stdin and external:
                raise UnsupportedSyntax("uninspected interpreter input")
            if uses_stdin and stdin is not None:
                inspect_code(language, stdin, cwd)
    except UnsupportedSyntax as error:
        # コード未対応でも入力ファイルは検査する
        unsupported = error
    if reads:
        inspect_interpreter_operands(language, operands, cwd)
    if unsupported is not None:
        raise unsupported


def inspect_argv(argv, cwd, depth, stdin=None, external=False):
    """単純コマンドを検査（stdin は静的入力、external は未検査入力の有無）"""
    if depth > 32:
        raise ParseError("nested command limit exceeded")
    assignments = pop_assignments(argv, cwd)
    if not argv:
        return
    command = os.path.basename(argv[0]).casefold()
    args = argv[1:]
    if "$" in command or "`" in command or UNKNOWN_ARGUMENT in command:
        raise UnsupportedSyntax("dynamic command name")
    command = {"pn": "pnpm", "podman": "docker", "nerdctl": "docker"}.get(command, command)
    if command in {"export", "readonly", "declare", "typeset", "local", "env", "sudo"}:
        for arg in args:
            inspect_assignment(arg, cwd)
    if (
        command in {"read", "mapfile", "readarray"}
        and any(arg in EXECUTION_VARIABLES for arg in args)
        or command == "printf"
        and any(name in EXECUTION_VARIABLES for name in option_values(args, {"-v"}))
    ):
        deny("組み込みコマンドによる実行設定の差し替えは許可していません。")
    if command == "env":
        args = env_split_args(args)
    if command in WRAPPER_OPTIONS:
        inspect_wrapper(command, args, assignments, cwd, depth, stdin, external)
        return
    if command in {"terraform", "terragrunt"}:
        args = terraform_args(command, args, assignments)
    inspect_cli(command, args, cwd)
    inspect_paths(command, args, cwd)
    if command in {"terraform", "terragrunt"} and "console" in cli_words(command, args) and stdin is not None:
        inspect_code("terraform", stdin, cwd, depth + 1)
    if command == "rm" and has_option(args, {"--recursive"}, "rR"):
        inspect_recursive_removal(args, cwd)
    if command in {"kubectl", "oc", "docker"}:
        inspect_container_exec(command, args, cwd, depth, stdin, external)
    if command in SHELLS:
        inspect_shell(args, cwd, depth, stdin, external)
    elif command in {"eval", "trap"}:
        inspect_eval(command, args, cwd, depth, stdin, external)
    elif command in {"source", "."}:
        inspect_source(args, cwd, depth, stdin, external)
    elif command == "osascript":
        inspect_osascript(args, stdin)
    elif command == "find":
        inspect_find(args, cwd, depth)
    elif command == "git" and "foreach" in args:
        inspect_submodule_foreach(args, cwd, depth)
    elif command in {"npx", "npm", "pnpm", "yarn", "mise", "flock", "script"}:
        inspect_runner(command, args, cwd, depth)
    language = re.sub(r"\d+(?:\.\d+)*$", "", command)
    if language in INTERPRETER_OPTIONS:
        inspect_interpreter(language, args, cwd, depth, stdin, external)


def changed_directory(argv, cwd):
    """cd 後の cwd を返し、追跡不能なら UnsupportedSyntax"""
    assignments = []
    while argv and ASSIGNMENT.match(argv[0]):
        assignments.append(argv.pop(0))
    while argv and argv[0] in {"builtin", "command"}:
        argv, _ = unwrap(argv[0], argv[1:], cwd, {})
    directory_variables = {"HOME", "CDPATH", "OLDPWD", "PWD"}
    if argv and argv[0] in {"export", "readonly", "declare", "typeset", "local"}:
        assignments.extend(argv[1:])
    if (
        any(
            (match := ASSIGNMENT.match(value)) and match.group(1) in directory_variables
            for value in assignments
        )
        or argv and (
            argv[0] in {"unset", "read", "mapfile", "readarray"}
            and any(arg in directory_variables for arg in argv[1:])
            or argv[0] == "printf"
            and any(name in directory_variables for name in option_values(argv[1:], {"-v"}))
        )
    ):
        raise UnsupportedSyntax("changed directory environment")
    if argv and argv[0] in {"eval", "source", ".", "pushd", "popd", "trap", "time"}:
        raise UnsupportedSyntax("untracked working directory")
    if not argv or argv[0] != "cd":
        return cwd
    args, physical = argv[1:], False
    while args and args[0].startswith("-") and args[0] != "-":
        option, args = args[0], args[1:]
        if option == "--":
            break
        if not re.fullmatch(r"-[LP]+", option):
            raise UnsupportedSyntax("unsupported cd option")
        physical = option[-1] == "P"
    if not args:
        args = [os.path.expanduser("~")]
    if len(args) != 1 or args[0] == "-" or any(char in args[0] for char in "$`*?["):
        raise UnsupportedSyntax("dynamic working directory")
    path = resolve_path(os.path.expanduser(args[0]), cwd, os.path.realpath if physical else os.path.abspath)
    return path if path is None or os.path.isdir(path) else cwd


def scan(text, cwd, depth=0, input_text=None, input_external=False):
    """cwd を追跡しながらシェルコードを検査"""
    initial_cwd = cwd
    if depth > 32:
        raise ParseError("nested command limit exceeded")
    if UNKNOWN_ARGUMENT in text:
        raise UnsupportedSyntax("dynamic shell code")
    tokens, nested = shell_tokens(text)
    spelling = [token.value if isinstance(token, Word) and not token.quoted else token for token in tokens]
    bomb = [":", "(", ")", "{", ":", "|", ":", "&", "}"]
    if any(spelling[index:index + len(bomb)] == bomb for index in range(len(spelling))):
        deny("fork bomb は許可していません。")
    sequential, command_start = True, True
    for index, token in enumerate(tokens):
        if isinstance(token, Word):
            if not command_start:
                continue
            if not token.quoted and (
                token.value in {"if", "for", "select", "while", "until", "case", "function", "coproc"}
                or tokens[index + 1:index + 3] == ["(", ")"]
            ):
                sequential = False
                break
            command_start = not token.quoted and (
                token.value in {"!", "time", "-p"} or bool(ASSIGNMENT.match(token.value))
            )
        elif token in {"&&", "||", "|", "|&", "&", "{", "}"} or token in REDIRECTIONS:
            sequential = False
            break
        elif token in SEPARATORS:
            command_start = True
    # 文脈不明なら開始位置で展開を検査
    if not sequential:
        for body in nested:
            scan(body, cwd, depth + 1, input_text, input_external)
    unit, piped, cwd_stack = [], False, []
    continued = False
    for token_index, token in enumerate(tokens + ["\n"]):
        if isinstance(token, Word) or token not in SEPARATORS:
            unit.append(token)
            continue
        # &&・| 直後の改行はコマンド列を継続
        if token == "\n" and not unit and continued:
            continue
        argv, words, stdin, external = [], [], input_text, piped or input_external
        index = 0
        while index < len(unit):
            item = unit[index]
            fd = None
            if isinstance(item, Word) and item.value.isdigit() and index + 1 < len(unit) and isinstance(unit[index + 1], str) and unit[index + 1] in REDIRECTIONS:
                fd = int(item.value)
                index += 1
                item = unit[index]
            if isinstance(item, str) and item in REDIRECTIONS:
                index += 1
                if index >= len(unit) or not isinstance(unit[index], Word):
                    raise ParseError("redirection operand is missing")
                operand = unit[index]
                words.append(operand)
                input_fd = fd == 0 or fd is None and item.startswith("<")
                if item in {"<", "<>"}:
                    if credential_path(operand.value, cwd):
                        deny("認証情報ファイルを標準入力へ読み込むことは許可していません。")
                    if input_fd:
                        external = True
                elif item in {"<<", "<<-", "<<<"}:
                    if input_fd:
                        stdin, external = operand.value, False
                elif item in {"<&", ">&"} and input_fd and operand.value != "-":
                    external = True
                elif item in {">", ">>", ">|"} and re.match(r"^/dev/(?:disk|rdisk|sd|nvme)", operand.value):
                    deny("ディスクデバイスへの書き込みは許可していません。")
            elif isinstance(item, Word):
                argv.append(item.value)
                words.append(item)
            else:
                raise ParseError("unsupported shell operator")
            index += 1
        while argv and argv[0] in {"if", "then", "elif", "else", "while", "until", "do", "!"}:
            argv.pop(0)
        function_header = (
            token == "(" and len(argv) == 1
            and tokens[token_index + 1:token_index + 2] == [")"]
        ) and all(not word.quoted and not word.parameters and not word.substitutions for word in words)
        if sequential:
            for word in words:
                for body in word.substitutions:
                    scan(body, cwd, depth + 1, input_text, input_external)
        # 存在・空の test は値を出力しない
        presence = len(argv) in {3, 4} and argv[0] in {"test", "[", "[["} and argv[1] in {"-e", "-f", "-n", "-z"}
        if not presence and any(sensitive_parameter(name) for word in words for name in word.parameters):
            deny("秘密値を持つ環境変数の明示展開は許可していません。")
        if argv and not function_header and argv[0] not in {"for", "select", "case", "in", "esac", "fi", "done", "function"}:
            try:
                inspect_argv(argv.copy(), cwd, depth, stdin, external)
                if not piped and token not in {"|", "|&", "&"}:
                    cwd = changed_directory(argv, cwd)
            except UnsupportedSyntax:
                if sequential:
                    sequential = False
                    for body in nested:
                        scan(body, initial_cwd, depth + 1, input_text, input_external)
        if token == "(":
            cwd_stack.append(cwd)
        elif token == ")" and cwd_stack:
            cwd = cwd_stack.pop()
        unit = []
        piped = token in {"|", "|&"}
        continued = token in {"&&", "||", "|", "|&"}


def main():
    """Bash・Monitor 入力の検査と deny 出力"""
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict) or not isinstance(event.get("tool_name"), str):
            raise ParseError("invalid hook input")
        if event["tool_name"] not in {"Bash", "Monitor"}:
            return 0
        tool_input = event.get("tool_input")
        if not isinstance(tool_input, dict):
            raise ParseError("tool_input must be an object")
        cwd = event.get("cwd", os.getcwd())
        if not isinstance(cwd, str) or not os.path.isabs(cwd):
            raise ParseError("cwd must be an absolute path")
        # WebSocket 監視ではコマンドを実行しない
        if event["tool_name"] == "Monitor" and "ws" in tool_input:
            ws = tool_input["ws"]
            if not isinstance(ws, dict) or not isinstance(ws.get("url"), str):
                raise ParseError("ws.url must be a string")
            if "command" not in tool_input:
                return 0
        if not isinstance(tool_input.get("command"), str):
            raise ParseError("command must be a string")
        scan(tool_input["command"], cwd)
    except Denied as error:
        json.dump({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny",
            "permissionDecisionReason": str(error),
        }}, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
    except (ParseError, ValueError, TypeError, IndexError, OSError, RecursionError):
        print("pre-bash-guard: 入力を安全に解析できませんでした。", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
