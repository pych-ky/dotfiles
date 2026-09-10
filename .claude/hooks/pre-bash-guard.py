#!/usr/bin/env python3
"""標準入力のコマンドを実行せず、既知の秘密取得・危険操作を拒否する。"""

import ast
import json
import os
import re
import sys
from dataclasses import dataclass, field
from urllib.parse import unquote, urlsplit


class Denied(Exception):
    pass


class ParseError(Exception):
    pass


class UnsupportedSyntax(Exception):
    pass


def deny(reason):
    raise Denied(reason)


# CLI の既知の秘密出力と、保護機構の迂回を拒否する。
SECRET_OUTPUT_REASON = "資格情報や秘密値を直接出力・取得する操作は許可していません。"
EXEC_OVERRIDE_REASON = "保護機構や認証処理を迂回する実行設定は許可していません。"
DESTRUCTIVE_REASON = "強制的な変更破棄、検証の迂回、ディスクの破壊は許可していません。"
SAFE_ENV_NAMES = {
    "PATH", "HOME", "PWD", "OLDPWD", "USER", "LOGNAME", "SHELL", "TERM",
    "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR", "TMP", "TEMP", "EDITOR",
    "VISUAL", "PAGER", "MANPAGER", "COLORTERM", "TERM_PROGRAM", "SHLVL",
    "AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION",
    "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "KUBECONFIG",
    "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
    "CODEX_HOME", "VIRTUAL_ENV", "CONDA_DEFAULT_ENV", "PYTHONPATH", "NODE_ENV",
}

CLI_VALUE_OPTIONS = {
    "security": {"-p", "-a", "-c", "-C", "-D", "-d", "-j", "-l", "-s", "-t", "-f", "-o", "-P"},
    "gh": {"-R", "--repo", "--hostname", "--config", "--host"},
    "ghtkn": {"-c", "--config", "--log-level"},
    "op": {"--account", "--session", "--vault", "--format", "--config", "--encoding"},
    "uv": {"--cache-dir", "--color", "--config-file", "--directory", "--project"},
    "vault": {"-address", "-namespace", "-format", "-field", "-mount", "-ca-cert"},
    "gcloud": {"--project", "--account", "--format", "--configuration", "--impersonate-service-account"},
    "az": {"--subscription", "--output", "-o", "--query", "--resource-group", "-g", "--vault-name", "--name", "-n"},
    "aws": {"--profile", "--region", "--output", "--query", "--endpoint-url", "--ca-bundle", "--cli-read-timeout", "--cli-connect-timeout", "--color", "--cli-input-json", "--cli-input-yaml", "--cli-binary-format", "--cli-error-format"},
    "git": {"-C", "-c", "--config", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env", "--super-prefix"},
    "terraform": {"-chdir", "-plugin-dir", "-var", "-var-file", "-target", "-replace", "-state", "-state-out", "-backup", "-lock-timeout"},
    "terragrunt": {"--working-dir", "--config", "--terragrunt-working-dir", "--terragrunt-config", "--log-level", "--tf-path", "--terragrunt-tfpath"},
    "kubectl": {"-n", "--namespace", "-o", "--output", "--context", "--kubeconfig", "--cluster", "--user", "-l", "--selector", "--server", "-s", "--token", "--as", "--as-group", "--cache-dir", "--certificate-authority", "--client-certificate", "--client-key", "--field-selector", "--password", "--request-timeout", "--username", "-v"},
    "docker": {"-H", "--host", "--context", "--config", "--log-level", "--tlscacert", "--tlscert", "--tlskey", "-f", "--format", "--filter"},
}
CLI_VALUE_OPTIONS["oc"] = CLI_VALUE_OPTIONS["kubectl"]
CLI_VALUE_OPTIONS["podman"] = CLI_VALUE_OPTIONS["docker"]
CLI_VALUE_OPTIONS["nerdctl"] = CLI_VALUE_OPTIONS["docker"]
COMPOSE_VALUE_OPTIONS = {
    "--ansi", "--env-file", "-f", "--file", "--parallel", "--profile",
    "--progress", "--project-directory", "-p", "--project-name",
}

# サービス名と操作名を分け、秘密を返す操作を短い表で維持する。
SECRET_SUBCOMMANDS = {
    "ghtkn": {"get", "exec", "git-credential"},
    "op": {"read", "inject", "run", "plugin run", "item get", "document get", "signin", "connect token create", "service-account create"},
    "uv": {"auth token", "auth helper"},
    "vault": {"kv get", "read", "write", "unwrap", "token create", "token lookup", "print token", "operator init", "operator generate-root"},
    "gcloud": {"auth print-access-token", "auth print-identity-token", "auth application-default print-access-token", "secrets versions access", "iam service-accounts keys create", "sql generate-login-token"},
    "az": {"account get-access-token", "keyvault secret show", "keyvault secret download", "ad sp credential reset", "ad app credential reset", "storage account keys list", "storage account keys renew", "storage account generate-sas", "acr credential show"},
}
AWS_SECRET_OPERATIONS = {
    "configure": {"export-credentials"},
    "sts": {"get-session-token", "assume-role", "assume-root", "assume-role-with-web-identity", "assume-role-with-saml", "get-federation-token", "get-delegated-access-token", "get-web-identity-token"},
    "secretsmanager": {"get-secret-value", "batch-get-secret-value"},
    "ssm": {"get-access-token", "create-activation", "resume-session"},
    "sso": {"get-role-credentials"},
    "sso-oidc": {"create-token", "create-token-with-iam", "register-client"},
    "ecr": {"get-login-password", "get-authorization-token"},
    "ecr-public": {"get-login-password", "get-authorization-token"},
    "codeartifact": {"get-authorization-token"},
    "kms": {"decrypt", "generate-data-key", "generate-data-key-pair", "derive-shared-secret"},
    "ec2": {"create-key-pair", "get-password-data"},
    "iam": {"create-access-key", "create-service-specific-credential", "reset-service-specific-credential"},
    "eks": {"get-token"},
    "eks-auth": {"assume-role-for-pod-identity"},
    "rds": {"generate-db-auth-token"},
    "redshift": {"get-cluster-credentials", "get-cluster-credentials-with-iam", "get-identity-center-auth-token"},
    "redshift-serverless": {"get-credentials", "get-identity-center-auth-token"},
    "cognito-identity": {"get-credentials-for-identity", "get-open-id-token", "get-open-id-token-for-developer-identity"},
    "cognito-idp": {"initiate-auth", "admin-initiate-auth", "respond-to-auth-challenge", "admin-respond-to-auth-challenge", "get-tokens-from-refresh-token", "add-user-pool-client-secret", "create-user-pool-client", "describe-user-pool-client", "update-user-pool-client", "associate-software-token"},
    "apigateway": {"get-api-key", "get-api-keys", "create-api-key", "update-api-key"},
    "appsync": {"create-api-key", "list-api-keys", "update-api-key"},
    "acm": {"export-certificate", "get-acme-external-account-binding-credentials"},
    "lightsail": {"create-key-pair", "download-default-key-pair", "get-instance-access-details", "get-relational-database-master-user-password", "get-bucket-access-keys", "create-bucket-access-key", "create-container-service-registry-login"},
    "iot": {"create-keys-and-certificate", "create-provisioning-claim"},
    "grafana": {"create-workspace-api-key", "create-workspace-service-account-token"},
    "s3": {"presign"},
    "s3api": {"create-session"},
    "cloudfront": {"sign"},
    "dsql": {"generate-db-connect-auth-token", "generate-db-connect-admin-auth-token"},
    "mwaa": {"create-cli-token", "create-web-login-token"},
    "storagegateway": {"describe-chap-credentials"},
    "amplify": {"create-app", "create-branch", "delete-app", "delete-branch", "get-app", "get-branch", "list-apps", "list-branches", "update-app", "update-branch"},
    "amplifybackend": {"create-token", "get-token"},
    "amplifyuibuilder": {"exchange-code-for-token", "refresh-token"},
    "appstream": {"create-app-block-builder-streaming-url", "create-image-builder-streaming-url", "create-streaming-url"},
    "athena": {"create-presigned-notebook-url", "get-session-endpoint"},
    "bedrock-agentcore": {"get-resource-oauth2-token", "get-resource-api-key", "get-resource-payment-token", "get-workload-access-token", "get-workload-access-token-for-jwt", "get-workload-access-token-for-user-id"},
    "chime": {"create-bot", "get-bot", "list-bots", "regenerate-security-token", "update-bot"},
    "chime-sdk-meetings": {"batch-create-attendee", "create-attendee", "create-meeting-with-attendees", "get-attendee", "list-attendees", "update-attendee-capabilities"},
    "codebuild": {"start-sandbox-connection"},
    "codecatalyst": {"create-access-token", "start-dev-environment-session"},
    "codepipeline": {"get-job-details", "get-third-party-job-details", "poll-for-jobs"},
    "connect": {"get-federation-token", "create-auth-code", "start-web-rtc-contact"},
    "connectparticipant": {"create-participant-connection"},
    "customer-profiles": {"get-upload-job-path"},
    "datazone": {"get-environment-credentials"},
    "deadline": {"assume-fleet-role-for-read", "assume-fleet-role-for-worker", "assume-queue-role-for-read", "assume-queue-role-for-user", "assume-queue-role-for-worker"},
    "devicefarm": {"create-test-grid-url"},
    "emr": {"get-cluster-session-credentials", "get-session-endpoint", "get-on-cluster-app-ui-presigned-url", "get-persistent-app-ui-presigned-url"},
    "emr-containers": {"get-managed-endpoint-session-credentials"},
    "emr-serverless": {"get-session-endpoint"},
    "finspace-data": {"get-external-data-view-access-details", "get-programmatic-access-credentials", "reset-user-password"},
    "gamelift": {"create-build", "get-compute-access", "get-compute-auth-token", "get-instance-access", "request-upload-credentials", "get-player-connection-details"},
    "glue": {"get-session-endpoint"},
    "iotsecuretunneling": {"open-tunnel", "rotate-tunnel-access-token"},
    "ivs": {"batch-get-stream-key", "create-channel", "create-stream-key", "get-stream-key"},
    "ivs-realtime": {"create-ingest-configuration", "get-ingest-configuration", "update-ingest-configuration", "create-participant-token", "create-stage"},
    "ivschat": {"create-chat-token"},
    "lakeformation": {"assume-decorated-role-with-saml", "get-temporary-data-location-credentials", "get-temporary-glue-partition-credentials", "get-temporary-glue-table-credentials"},
    "lambda-microvms": {"create-microvm-auth-token", "create-microvm-shell-auth-token"},
    "license-manager": {"create-token", "get-access-token"},
    "mediapackage": {"configure-logs", "create-channel", "describe-channel", "list-channels", "rotate-channel-credentials", "rotate-ingest-endpoint-credentials", "update-channel"},
    "pca-connector-scep": {"create-challenge", "get-challenge-password"},
    "pcs": {"register-compute-node-group-instance"},
    "quicksight": {"generate-embed-url-for-anonymous-user", "generate-embed-url-for-registered-user", "generate-embed-url-for-registered-user-with-identity", "get-dashboard-embed-url", "get-session-embed-url"},
    "route53domains": {"retrieve-domain-auth-code", "transfer-domain-to-another-aws-account"},
    "route53globalresolver": {"create-access-token", "get-access-token"},
    "s3control": {"get-data-access"},
    "sagemaker": {"create-partner-app-presigned-url", "create-presigned-domain-url", "create-presigned-mlflow-app-url", "create-presigned-mlflow-tracking-server-url", "create-presigned-notebook-instance-url", "start-session"},
    "signin": {"create-oauth2-token", "create-oauth2-token-with-iam"},
    "wafv2": {"create-api-key", "list-api-keys"},
    "wickr": {"create-data-retention-bot-challenge", "get-oidc-info", "get-opentdf-config", "register-oidc-config", "register-opentdf-config"},
    "workmail": {"assume-impersonation-role"},
    "workspaces-thin-client": {"create-environment", "get-environment", "list-environments", "update-environment"},
    "history": {"list", "show"},
}
GIT_EXEC_KEYS = {
    "core.hookspath", "core.askpass", "credential.helper",
    "uploadpack.packobjectshook",
}
GIT_COMMAND_KEYS = {
    "core.pager", "core.editor", "core.sshcommand", "core.gitproxy",
    "core.fsmonitor", "sequence.editor", "diff.external", "gpg.program",
    "gpg.openpgp.program",
}
CONTAINER_SAFE_FIELDS = {
    "id", "ids", "name", "names", "image", "imageid", "status", "state",
    "running", "paused", "restarting", "dead", "exitcode", "pid", "ports",
    "size", "sizewritable", "sizerootfs", "created", "createdat", "startedat",
    "finishedat", "repository", "tag", "digest", "repotags", "repodigests",
    "architecture", "os", "ostype", "serverversion", "version", "apiversion",
    "memory", "memtotal", "ncpu", "containers", "containersrunning",
    "containerspaused", "containersstopped", "images", "driver", "platform",
}


def option_values(args, names):
    """分離値、長い = 値、短い結合値を取り出す。"""
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
    """既知の値付きオプションを除いたサブコマンドと位置引数。"""
    values = CLI_VALUE_OPTIONS.get(command, set()) | set(extra_values)
    words = []
    index = 0
    while index < len(args):
        argument = args[index]
        if argument == "--":
            words.extend(args[index + 1:])
            break
        current_values = values
        if command in {"docker", "podman", "nerdctl"} and words == ["compose"]:
            current_values = values | COMPOSE_VALUE_OPTIONS
        if argument in current_values:
            index += 2
            continue
        if not argument.startswith("-") or argument == "-":
            words.append(argument)
        index += 1
    return words


def matches_subcommand(words, forms):
    return any(words[:len(form.split())] == form.split() for form in forms)


def secret_name(name):
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
    key = key.casefold()
    return key in GIT_EXEC_KEYS or key == "include.path" or key.startswith("includeif.") or any(
        key.startswith(prefix) and key.endswith(suffix)
        for prefix, suffix in (("credential.", ".helper"), ("credential.", ".askpass"), ("protocol.", ".allow"), ("url.", ".insteadof"), ("url.", ".pushinsteadof"), ("filter.", ".clean"), ("filter.", ".smudge"), ("filter.", ".process"))
    )


def inspect_git(args, words, cwd):
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
        if not names_only and has_option(args, {"--get-urlmatch"}) and operands[:1] == ["http"]:
            deny(SECRET_OUTPUT_REASON)
        if not reads and not removes and any(git_exec_key(key) for key in operands):
            deny(EXEC_OVERRIDE_REASON)
        if not reads and not removes and len(operands) > 1:
            key, value = operands[:2]
            if key.casefold() in GIT_COMMAND_KEYS:
                scan(value, cwd)
            elif key.casefold().startswith("alias.") and value.startswith("!"):
                scan(value[1:], cwd)
    if not words:
        return
    command = words[0]
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
    if command == "push" and has_option(args, {"--force", "--mirror", "--prune"}, "f"):
        deny(DESTRUCTIVE_REASON)
    if command == "push" and any(word.startswith("+") for word in words[1:]):
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
    if has_option(args, set(), "i"):
        deny(SECRET_OUTPUT_REASON)
    if has_option(args, {"--help", "-h"}) or words[:1] == ["help"]:
        return
    if not words:
        deny(SECRET_OUTPUT_REASON)
    command = words[0]
    if command in {"dump-keychain", "export-smartcard"}:
        deny(SECRET_OUTPUT_REASON)
    if command in {"find-generic-password", "find-internet-password"}:
        if has_option(args, set(), "wg"):
            deny(SECRET_OUTPUT_REASON)
    if command == "export":
        types = option_values(args, {"-t"})
        if not types or any(value not in {"certs", "pubKeys"} for value in types):
            deny(SECRET_OUTPUT_REASON)


def inspect_aws(args, words):
    if has_option(args, {"--version"}):
        return
    # API オプションの値を help と誤認しないよう、既知のグローバル指定だけを除く。
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
    custom = {("configure", "export-credentials"), ("cloudfront", "sign"), ("codecommit", "credential-helper"), ("ecr", "get-login-password"), ("ecr-public", "get-login-password"), ("eks", "get-token"), ("rds", "generate-db-auth-token"), ("s3", "presign")}
    if (service, operation) not in custom and service not in {"history", "dsql"} and has_option(args, {"--generate-cli-skeleton"}):
        return
    if service == "apigateway" and operation in {"get-api-key", "get-api-keys"}:
        if not has_option(args, {"--include-value", "--include-values"}):
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
    if service == "codeartifact" and operation == "login" and has_option(args, {"--dry-run"}):
        deny(SECRET_OUTPUT_REASON)


def inspect_gh(args, words, cwd):
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


def inspect_terraform(command, args, words, cwd):
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


def inspect_container(command, args, words):
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
        if not option_values(args, {"-o"}):
            deny(SECRET_OUTPUT_REASON)
        inspect_process("ps", args)
    if has_option(args, {"--privileged", "--use-api-socket"}):
        deny(EXEC_OVERRIDE_REASON)


def inspect_environment(command, args):
    words = cli_words(command, args)
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
    if has_option(args, {"--help", "--version", "-h"}):
        return
    if command in {"pip", "pip3"}:
        if matches_subcommand(words, {"config list", "config debug"}):
            deny(SECRET_OUTPUT_REASON)
        if words[:2] == ["config", "get"] and any(word.rsplit(".", 1)[-1].casefold() in {"index-url", "extra-index-url", "proxy"} for word in words[2:]):
            deny(SECRET_OUTPUT_REASON)
    if command in {"npm", "pnpm"}:
        if command == "npm" and (matches_subcommand(words, {"config list", "config ls"}) or words in (["config", "get"], ["config"])):
            deny(SECRET_OUTPUT_REASON)
        if words[:2] == ["config", "get"] and any(secret_name(word) or "_auth" in word.casefold() for word in words[2:]):
            deny(SECRET_OUTPUT_REASON)


def inspect_cli(command, args, cwd):
    command = os.path.basename(command).casefold()
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
        inspect_terraform(command, args, words, cwd)
    elif command in {"kubectl", "oc"}:
        inspect_kubernetes(command, args, words)
    elif command in {"docker", "podman", "nerdctl"}:
        inspect_container(command, args, words)
    elif command in {"printenv", "set", "export", "declare", "typeset"}:
        inspect_environment(command, args)
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
        inspect_packages(command, args, cli_words(command, args, {"--prefix", "--userconfig", "--globalconfig", "--registry", "--workspace", "-w", "--dir", "-C"}))


CREDENTIAL_LOCATIONS = (
    ".aws/credentials", ".aws/config", ".aws/login", ".aws/sso", ".aws/cli",
    ".ssh", ".gnupg", ".docker/config.json", ".config/gh/hosts.yml",
    ".config/gcloud", ".config/containers/auth.json", ".local/share/uv/credentials",
    ".ocm.json", ".config/ocm/ocm.json", "Library/Application Support/ocm/ocm.json",
    ".config/helm/repositories.yaml", ".config/helm/registry/config.json",
    "Library/Preferences/helm/repositories.yaml", "Library/Preferences/helm/registry/config.json",
    ".kube/config", ".codex/auth.json", ".codex/shell_snapshots",
    ".claude/.credentials.json", ".claude/shell-snapshots", ".claude/backups",
    ".claude.json", ".claude.json.backup", ".terraform.d/credentials.tfrc.json",
    ".terraformrc", ".vault-token", ".azure", ".cargo/credentials.toml",
    ".cargo/credentials", ".curlrc", ".wgetrc", ".bundle/config",
    ".config/composer/auth.json", ".composer/auth.json", ".config/pypoetry/auth.toml",
    "Library/Application Support/pypoetry/auth.toml", ".config/pip/pip.conf",
    ".pip/pip.conf", "Library/Application Support/pip/pip.conf",
    ".zsh_sessions", ".bash_sessions", "Library/Keychains",
)
CREDENTIAL_FRAGMENTS = tuple(path.casefold() for path in CREDENTIAL_LOCATIONS) + (
    "gh/hosts.yml", "gcloud/application_default_credentials.json", "gcloud/credentials.db",
    "gcloud/access_tokens.db", "ocm/ocm.json", "helm/repositories.yaml",
    "helm/registry/config.json", "uv/credentials", "cargo/credentials.toml", "composer/auth.json",
)
CREDENTIAL_NAMES = {
    ".git-credentials", ".netrc", ".pgpass", ".pg_service.conf", "pg_service.conf",
    ".npmrc", ".pypirc", ".zsh_history", ".bash_history", "fish_history", "pip.conf",
}
CREDENTIAL_SUFFIXES = (".p12", ".pfx", ".p8", ".ppk", ".key", ".keystore", ".jks", ".kdbx")
CREDENTIAL_PATH_VARIABLES = {
    "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "KUBECONFIG", "GH_CONFIG_DIR",
    "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CREDENTIALS", "CLOUDSDK_CONFIG",
    "DOCKER_CONFIG", "REGISTRY_AUTH_FILE", "TF_CLI_CONFIG_FILE", "OCM_CONFIG",
    "HELM_REPOSITORY_CONFIG", "HELM_REGISTRY_CONFIG", "PGPASSFILE", "PGSERVICEFILE",
    "PIP_CONFIG_FILE", "NETRC", "NPM_CONFIG_USERCONFIG", "NPM_CONFIG_GLOBALCONFIG",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", "AWS_LOGIN_CACHE_DIRECTORY",
    "AWS_WEB_IDENTITY_TOKEN_FILE", "AZURE_CONFIG_DIR", "BUNDLE_USER_CONFIG",
    "CARGO_HOME", "COMPOSER_HOME", "DOCKER_CERT_PATH", "GNUPGHOME",
    "HELM_CONFIG_HOME", "PGSSLKEY", "PGSYSCONFDIR", "UV_CREDENTIALS_DIR", "WGETRC",
}


def path_spellings(value, cwd):
    if UNKNOWN_ARGUMENT in value:
        return set()
    """既知のホーム表記と symlink を、ファイル本文を読まずに解決する。"""
    if value.startswith(("file://", "fileb://")):
        value = unquote(urlsplit(value).path)
    home = os.path.expanduser("~")
    value = re.sub(r"\$(?:HOME\b|\{HOME\})", lambda _match: home, value)
    value = os.path.expanduser(value)
    path = os.path.join(cwd, value)
    return {os.path.normpath(path).casefold(), os.path.realpath(path).casefold()}


def credential_path(value, cwd):
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
    """コピー・マウントでは既知の保管先の親ディレクトリも保護する。"""
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
        for target in protected
    )


def path_arguments(args, value_options=()):
    """既知の値付きオプションを除き、位置引数とオプション値を返す。"""
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


GIT_CONTENT_OPTIONS = {
    "--output", "-o", "--pathspec-from-file",
    "-G", "-S", "--word-diff-regex", "--grep", "--author", "--committer",
    "--date", "--since", "--until", "--after", "--before", "--encoding",
    "--max-count", "-n", "--skip", "-L", "-O", "--contents",
    "--stat-width", "--stat-name-width", "--stat-graph-width", "--stat-count",
}


def git_metadata_only(operation, args):
    """統計はパッチに追加され、no-patch は先行するパッチ指定を解除する。"""
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


def inspect_paths(command, args, cwd):
    def check(value, recursive=False):
        predicate = path_exposes_credentials if recursive else credential_path
        if predicate(value, cwd):
            deny("認証情報ファイルの直接読み取り・持ち出しは許可していません。")

    def check_values(values, options):
        for option in options:
            for value in values.get(option, []):
                check(value)

    if command in {"echo", "printf", "test", "[", "[[", "ls", "stat", "touch", "mkdir", "chmod", "chown", "chgrp", "rm", "rmdir", "mv", "ln"}:
        return

    if command in {"grep", "egrep", "fgrep", "rg"}:
        operands, values = path_arguments(args, {
            "-e", "--regexp", "-f", "--file", "-g", "--glob", "--iglob", "-t", "--type",
            "-T", "--type-not", "-A", "-B", "-C", "-m", "--max-count", "--context",
            "--color", "--colors", "--encoding", "--exclude", "--exclude-dir", "--include",
            "--ignore-file", "--exclude-from", "--replace", "--type-add", "--type-clear", "--max-depth",
        })
        check_values(values, {"-f", "--file", "--ignore-file", "--exclude-from"})
        if not any(option in values for option in {"-e", "--regexp", "-f", "--file"}):
            operands = operands[1:]
    elif command in {"sed", "gsed", "awk", "gawk", "mawk", "nawk", "jq", "yq"}:
        program_options = {"-e", "--expression", "-f", "--file"}
        if command in {"awk", "gawk", "mawk", "nawk"}:
            program_options |= {"-F", "-v"}
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
                        check(args[index + 2])
                    index += 3
                else:
                    remaining.append(argument)
                    index += 1
            args = remaining
        operands, values = path_arguments(args, program_options)
        check_values(values, {"-f", "--file", "--from-file"})
        if not any(option in values for option in {"-e", "--expression", "-f", "--file", "--from-file"}):
            operands = operands[1:]
        if command in {"awk", "gawk", "mawk", "nawk"}:
            operands = [operand for operand in operands if not re.match(r"[A-Za-z_][A-Za-z_0-9]*=", operand)]
    elif command in {"cat", "head", "tail", "less", "more", "nl", "wc", "sort", "uniq", "cut", "paste", "od", "xxd", "hexdump", "strings", "base64", "base32", "md5", "md5sum", "sha1sum", "sha256sum", "shasum", "cksum", "file", "diff", "cmp", "comm"}:
        reader_options = {
            "head": {"-n", "--lines", "-c", "--bytes"},
            "tail": {"-n", "--lines", "-c", "--bytes", "-s", "--sleep-interval"},
            "less": {"-p", "-P", "-x", "-z", "-j", "-t", "-T"},
            "more": {"-n"}, "nl": {"-b", "-d", "-f", "-h", "-i", "-l", "-n", "-s", "-v", "-w"},
            "wc": {"--files0-from"},
            "sort": {"-k", "--key", "-t", "--field-separator", "-T", "--temporary-directory", "-S", "--buffer-size", "-o", "--output", "--files0-from", "--random-source"},
            "uniq": {"-f", "-s", "-w"}, "cut": {"-b", "-c", "-d", "-f", "--bytes", "--characters", "--delimiter", "--fields"},
            "paste": {"-d", "--delimiters"}, "od": {"-A", "-j", "-N", "-t", "-w"},
            "xxd": {"-c", "-g", "-l", "-o", "-s"}, "hexdump": {"-e", "-f", "-n", "-s"},
            "strings": {"-n", "-t", "-e"}, "md5": {"-s"}, "shasum": {"-a", "--algorithm"},
            "file": {"-m", "--magic-file", "-f", "--files-from", "-e", "--exclude"},
            "diff": {"-I", "-L", "--label", "-x", "--exclude", "-X", "--exclude-from", "-F"},
            "cmp": {"-i", "--ignore-initial", "-n", "--bytes"},
        }
        operands, values = path_arguments(args, reader_options.get(command, set()))
        if command in {"base64", "base32"}:
            operands, values = path_arguments(args, {"-i", "--input", "-o", "--output", "-w", "--wrap"})
            check_values(values, {"-i", "--input"})
        check_values(values, {"--files0-from", "--random-source"})
        if command in {"hexdump", "file"}:
            check_values(values, {"-f", "--files-from", "-m", "--magic-file"})
        if command == "diff":
            check_values(values, {"-X", "--exclude-from"})
        if command in {"uniq", "xxd"}:
            operands = operands[:1]
    elif command in {"cp", "scp", "rsync"}:
        copy_options = {
            "cp": {"-t", "--target-directory", "-S", "--suffix"},
            "scp": {"-i", "-F", "-o", "-P", "-S", "-J", "-l", "-c", "-D"},
            "rsync": {"-e", "--rsh", "--exclude", "--include", "--exclude-from", "--include-from", "--files-from", "--password-file"},
        }
        operands, values = path_arguments(args, copy_options[command])
        check_values(values, {"--exclude-from", "--include-from", "--files-from", "--password-file"})
        sources = operands if "-t" in values or "--target-directory" in values else operands[:-1]
        for source in sources:
            if command in {"scp", "rsync"} and ":" in source:
                source = source.split(":", 1)[1]
            check(source, recursive=True)
        return
    elif command == "dd":
        for argument in args:
            if argument.startswith("if="):
                check(argument[3:])
        return
    elif command == "git":
        global_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"}
        index = 0
        while index < len(args) and args[index].startswith("-"):
            argument = args[index]
            index += 2 if argument in global_options else 1
        _operands, globals_ = path_arguments(args[:index], global_options)
        for directory in globals_.get("-C", []):
            cwd = os.path.normpath(os.path.join(cwd, directory))
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
        check_values(values, file_options | {"--contents", "-O"})
        if operation == "log":
            for selection in values.get("-L", []):
                if ":" in selection:
                    check(selection.rsplit(":", 1)[1])
        if operation in {"show", "cat-file"}:
            for operand in operands:
                if ":" in operand:
                    path = re.sub(r"^:[0-3]:", ":", operand).split(":", 1)[1]
                    check(path)
        if operation in {"show", "diff", "diff-files", "diff-index", "diff-tree", "log", "reflog"} and git_metadata_only(operation, args):
            return
        if operation not in {"show", "diff", "diff-files", "diff-index", "diff-tree", "difftool", "log", "reflog", "grep", "archive", "cat-file", "blame", "annotate", "format-patch", "fast-export", "checkout-index", "whatchanged"}:
            return
        if operation == "grep":
            inspect_paths("grep", args, cwd)
            return
    elif command == "openssl":
        input_options = {"-in", "-inkey", "-key", "-cert", "-CAfile", "-CApath", "-config", "-extfile", "-signkey", "-untrusted", "-chain", "-certfile"}
        if args[:1] in (["s_client"], ["s_server"]):
            input_options -= {"-key", "-cert", "-CAfile", "-CApath"}
        _operands, values = path_arguments(args, input_options | {"-out", "-keyout", "-writerand"})
        check_values(values, input_options)
        return
    elif command == "tar":
        normalized = list(args)
        if normalized and not normalized[0].startswith("-"):
            normalized[0] = "-" + normalized[0]
        operands, values = path_arguments(normalized, {"-f", "--file", "-C", "--directory", "-T", "--files-from", "-X", "--exclude-from", "--exclude", "--transform"})
        creating = any(argument == "--create" or (argument.startswith("-") and not argument.startswith("--") and any(flag in argument[1:] for flag in "cru")) for argument in normalized)
        check_values(values, {"-T", "--files-from", "-X", "--exclude-from"})
        if not creating:
            check_values(values, {"-f", "--file"})
            return
        for directory in values.get("-C", []) + values.get("--directory", []):
            cwd = os.path.normpath(os.path.join(cwd, directory))
        for operand in operands:
            check(operand, recursive=True)
        return
    elif command in {"curl", "wget", "gh"}:
        direct_options = {
            "curl": {"-T", "--upload-file", "-K", "--config"},
            "wget": {"-i", "--input-file", "--config", "--body-file", "--post-file"},
            "gh": {"--body-file", "--bundle", "--env-file", "--input", "--notes-file"},
        }[command]
        indirect_options = {
            "curl": {"-d", "--data", "--data-binary", "--data-urlencode", "--json", "-F", "--form", "-H", "--header", "--proxy-header"},
            "wget": set(), "gh": {"-F", "--field"},
        }[command]
        ignored_options = {
            "curl": {"-o", "--output", "-E", "--cert", "--key", "--netrc-file", "--cacert", "--capath", "--proxy-cert", "--proxy-key", "--data-raw", "--form-string", "-u", "--user", "-x", "--proxy", "-X", "--request"},
            "wget": {"-O", "--output-document", "-o", "--output-file", "--load-cookies", "--certificate", "--private-key", "--ca-certificate"},
            "gh": {"-R", "--repo", "-H", "--header", "-f", "--raw-field", "--jq", "--template", "--hostname", "--method", "-X"},
        }[command]
        if command == "gh":
            ignored_options |= {
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
        operands, values = path_arguments(args, direct_options | indirect_options | ignored_options | {"--url"})
        check_values(values, direct_options)
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
                        check(path.removeprefix("@"))
        for value in operands + values.get("--url", []):
            if value.startswith(("file://", "fileb://")):
                check(value)
        if command == "gh":
            start = None
            if pair in {("gist", "create"), ("gist", "new"), ("ssh-key", "add"), ("gpg-key", "add"), ("attestation", "verify"), ("attestation", "download")}:
                start = 2
            elif pair in {("release", "create"), ("release", "new"), ("release", "upload"), ("gist", "edit")} or operands[:3] == ["repo", "deploy-key", "add"]:
                start = 3
            if start is not None:
                for value in operands[start:]:
                    check(value.split("#", 1)[0] if pair[0] == "release" else value)
        return
    elif command in {"docker", "podman", "nerdctl"}:
        operands, values = path_arguments(args, {"-v", "--volume", "--mount", "--secret", "--env-file", "-f", "--file", "--build-context", "--config", "-H", "--host", "--name", "-e", "--env", "--build-arg", "-t", "--tag"})
        if not any(operation in operands for operation in {"build", "run", "create", "cp", "compose"}):
            return
        if "--use-api-socket" in args:
            deny("ホストの socket をコンテナへ渡す操作は許可していません。")
        if "--secret" in values:
            deny("secret をコンテナへ渡す操作は許可していません。")
        check_values(values, {"--env-file"})
        if "build" in operands:
            check_values(values, {"-f", "--file"})
        elif "compose" in operands:
            operations = operands[operands.index("compose") + 1:]
            boundary = args.index(operations[0]) if operations else len(args)
            _operands, compose_values = path_arguments(args[:boundary], {"-f", "--file"})
            check_values(compose_values, {"-f", "--file"})
        for value in values.get("-v", []) + values.get("--volume", []):
            source = value.split(":", 1)[0]
            if source.endswith(".sock"):
                deny("ホストの socket をコンテナへ渡す操作は許可していません。")
            if source.startswith(("/", ".", "~", "$")):
                check(source, recursive=True)
        for value in values.get("--mount", []):
            fields = dict(part.split("=", 1) for part in value.split(",") if "=" in part)
            source = fields.get("source", fields.get("src", ""))
            if source.endswith(".sock"):
                deny("ホストの socket をコンテナへ渡す操作は許可していません。")
            if source and fields.get("type", "bind") == "bind":
                check(source, recursive=True)
        if "cp" in operands and len(operands) >= 3:
            source = operands[operands.index("cp") + 1]
            check(source.split(":", 1)[-1], recursive=True)
        if "build" in operands and operands[-1] != "build":
            check(operands[-1], recursive=True)
        for value in values.get("--build-context", []):
            check(value.partition("=")[2], recursive=True)
        return
    else:
        for argument in args:
            value = argument.partition("=")[2] if "=" in argument else argument
            if value.startswith(("file://", "fileb://")):
                check(value)
        return
    for operand in operands:
        check(operand)


SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
SEPARATORS = {";", "&", "&&", "||", "|", "|&", "(", ")", "{", "}", "\n", ";;", ";&", ";;&"}
REDIRECTIONS = {"<", ">", ">>", "<>", ">|", "<<", "<<-", "<<<", "<&", ">&", "&>", "&>>"}
OPERATORS = sorted(SEPARATORS | REDIRECTIONS, key=len, reverse=True)
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(?:\[[^]]*\])?\+?=(.*)$", re.S)
PARAMETER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
EXECUTION_VARIABLES = {
    "BASH_ENV", "ENV", "ZDOTDIR", "SHELLOPTS", "SUDO_ASKPASS",
    "GIT_ASKPASS", "GIT_EXEC_PATH",
    "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS", "GIT_TEMPLATE_DIR",
    "DOCKER_CLI_PLUGIN_EXTRA_DIRS",
}
EXECUTION_PREFIXES = ("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")
COMMAND_VARIABLES = {
    "SUDO_EDITOR", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR",
    "GIT_PAGER", "GH_PAGER", "GH_EDITOR", "GH_BROWSER", "PAGER", "EDITOR", "VISUAL",
    "BROWSER", "AWS_PAGER", "MANPAGER", "TG_TF_PATH", "TERRAGRUNT_TFPATH",
    "npm_config_call", "npm_config_script_shell",
}
PROXIES = {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "FTP_PROXY", "PIP_PROXY"}
REFERENCE_VARIABLES = {"SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_AGENT_INFO", "DOCKER_HOST"}


@dataclass
class Word:
    value: str
    parameters: set = field(default_factory=set)
    quoted: bool = False
    heredoc: bool = False


def ansi_c_quote(text, index):
    value = []
    escapes = dict(zip("abefnrtvE", "\a\b\x1b\f\n\r\t\v\x1b"))
    while index < len(text):
        char = text[index]
        index += 1
        if char == "'":
            return "".join(value), index
        if char != "\\":
            value.append(char)
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
            if escape not in "uU":
                number %= 256
                if number >= 128:
                    raise ParseError("unsupported ANSI-C byte encoding")
            char = chr(number)
            index += len(match.group())
        elif escape == "c":
            if index >= len(text) or not text[index].isascii() or text[index] == "\\":
                raise ParseError("unsupported ANSI-C control escape")
            char = chr(127 if text[index] == "?" else ord(text[index].upper()) & 31)
            index += 1
        else:
            char = "\\" + escape
        if "\0" in char:
            raise ParseError("NUL in ANSI-C quote")
        value.append(char)
    raise ParseError("unterminated ANSI-C quote")


def group_end(text, start, opening, closing):
    """引用を飛ばし、明示された展開の終端だけを探す。"""
    depth, quote, index = 1, None, start
    while index < len(text):
        char = text[index]
        if quote is None and text.startswith("$'", index):
            _, index = ansi_c_quote(text, index + 2)
            continue
        if char == "\\" and quote != "'":
            index += 2
            continue
        if quote:
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if not depth:
                return index
        index += 1
    raise ParseError("unterminated shell expansion")


def shell_tokens(text, literal=False):
    """引用と演算子を区別する。変数値・関数・実行結果は推論しない。"""
    tokens, nested, pending = [], [], []
    value, parameters = [], set()
    quote, quoted, started = None, False, False
    index = 0

    def flush():
        nonlocal value, parameters, quoted, started
        if started:
            word = Word("".join(value), parameters, quoted)
            if tokens and tokens[-1] in ("<<", "<<-"):
                pending.append((len(tokens), word.value, tokens[-1] == "<<-", quoted))
            tokens.append(word)
        value, parameters, quoted, started = [], set(), False, False

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
            raise ParseError("locale-dependent shell quote")
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
            nested.append(text[index + 1:end])
            value.append("$()")
            started = True
            index = end + 1
            continue
        if text.startswith("$(", index) or (quote is None and text[index:index + 2] in {"<(", ">("}):
            end = group_end(text, index + 2, "(", ")")
            body = text[index + 2:end]
            if text.startswith("$((", index):
                _, inner = shell_tokens(body[1:-1], literal=True)
                nested.extend(inner)
                parameters.update(PARAMETER.findall(body))
            else:
                nested.append(body)
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
            nested.extend(inner)
            value.append(os.path.expanduser("~") if body == "HOME" else text[index:end + 1])
            started = True
            index = end + 1
            continue
        if char == "$":
            match = PARAMETER.match(text, index + 1)
            if match:
                name = match.group()
                parameters.add(name)
                value.append(os.path.expanduser("~") if name == "HOME" else "$" + name)
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
                        body = []
                        while True:
                            if index >= len(text):
                                raise ParseError("unterminated heredoc")
                            end = text.find("\n", index)
                            end = len(text) if end < 0 else end + 1
                            line = text[index:end]
                            index = end
                            compared = line.rstrip("\r\n")
                            if strip_tabs:
                                compared = compared.lstrip("\t")
                            if compared == delimiter:
                                break
                            body.append(line.lstrip("\t") if strip_tabs else line)
                        body = "".join(body)
                        names = set()
                        if not is_quoted:
                            expanded, inner = shell_tokens(body, literal=True)
                            nested.extend(inner)
                            for word in expanded:
                                names.update(word.parameters)
                        tokens[token_index] = Word(body, names, is_quoted, True)
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
    return tokens, nested


def inspect_assignment(value, cwd):
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
    return name not in CREDENTIAL_PATH_VARIABLES and (
        secret_name(name)
        or name in REFERENCE_VARIABLES or name.upper() in PROXIES
    )


WRAPPER_VALUES = {
    "sudo": {"-u", "--user", "-g", "--group", "-p", "--prompt", "-C", "--close-from", "-h", "--host", "-D", "--chdir"},
    "env": {"-u", "--unset", "-C", "--chdir"},
    "nice": {"-n", "--adjustment"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "xargs": {"-I", "-J", "-L", "-n", "-P", "-s", "-E", "--replace", "--max-args", "--max-procs"},
    "exec": {"-a", "--argv0"},
    "time": {"-f", "--format", "-o", "--output"},
    "arch": {"-arch", "-d", "-e"}, "caffeinate": {"-t", "-w"},
    "coproc": set(), "!": set(),
    "command": set(), "builtin": set(), "nohup": set(),
}
WRAPPER_FLAGS = {
    "sudo": {"-n", "-E", "-H", "-b", "-k", "-K", "-v", "-l", "--non-interactive", "--preserve-env", "--validate", "--list"},
    "env": {"-i", "--ignore-environment", "-0", "--null"},
    "nice": set(), "timeout": {"--foreground", "--preserve-status", "-v", "--verbose"},
    "xargs": {"-0", "-r", "-t", "-p", "-x", "--null", "--no-run-if-empty"},
    "exec": {"-c", "-l"}, "command": {"-p"}, "builtin": set(), "nohup": set(),
    "time": {"-p", "-l", "-v", "-a", "--portability", "--verbose", "--append"},
    "arch": {"-arm64", "-arm64e", "-x86_64", "-x86_64h", "-i386", "-32", "-64", "-c"},
    "caffeinate": {"-d", "-i", "-s", "-m", "-u"}, "coproc": set(), "!": set(),
}
UNKNOWN_ARGUMENT = "\0"


def unwrap(command, args, cwd, inherited_assignments):
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
        if not arg.startswith("--") and len(arg) > 2 and arg not in WRAPPER_VALUES[command] | WRAPPER_FLAGS[command]:
            expanded = []
            for offset, letter in enumerate(arg[1:], 1):
                short = "-" + letter
                if short in WRAPPER_VALUES[command]:
                    expanded.append(short)
                    if arg[offset + 1:]:
                        expanded.append(arg[offset + 1:])
                    break
                if short not in WRAPPER_FLAGS[command]:
                    raise UnsupportedSyntax("unsupported wrapper option")
                expanded.append(short)
            args[index:index + 1] = expanded
            arg = args[index]
        option, separator, value = arg.partition("=")
        if option in WRAPPER_VALUES[command]:
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
                cwd = os.path.abspath(os.path.join(cwd, os.path.expanduser(value)))
        elif command == "env" and arg in {"-i", "--ignore-environment"}:
            inherited_assignments.clear()
        elif arg not in WRAPPER_FLAGS[command]:
            raise UnsupportedSyntax("unsupported wrapper option")
        index += 1
    if command == "timeout" and index < len(args):
        index += 1
    child = args[index:]
    if command == "xargs":
        child = child or ["echo"]
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


INTERPRETERS = {"python", "python3", "node", "ruby", "perl", "php", "awk", "gawk"}
CODE_OPTIONS = {"python": "c", "python3": "c", "node": "ep", "ruby": "e", "perl": "eE", "php": "r", "awk": "", "gawk": ""}
CODE_READERS = {"open", "read_text", "read_bytes", "readFile", "readFileSync", "file_get_contents", "readfile"}
STRING_LITERAL = re.compile(r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*' ''', re.S | re.X)


def mask_code(language, code, cwd, depth):
    """コメントと静的文字列を除き、補間式は独立したコードとして検査する。"""
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


def inspect_code(language, code, cwd, depth=0):
    """直接記述されたファイル操作・秘密値取得・プロセス起動だけを検査する。"""
    if depth > 32:
        raise ParseError("nested code limit exceeded")
    if UNKNOWN_ARGUMENT in code:
        raise UnsupportedSyntax("dynamic inline code")
    if language in {"python", "python3"}:
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

        def qualified_name(node):
            if isinstance(node, ast.Name):
                return aliases.get(node.id, node.id)
            if isinstance(node, ast.Attribute):
                return qualified_name(node.value) + "." + node.attr
            if isinstance(node, ast.Call) and qualified_name(node.func) in {"getattr", "builtins.getattr"}:
                if len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and isinstance(node.args[1].value, str):
                    return qualified_name(node.args[0]) + "." + node.args[1].value
            if isinstance(node, ast.Call) and qualified_name(node.func) in {"__import__", "builtins.__import__"}:
                if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                    return node.args[0].value
            return ""

        for node in ast.walk(tree):
            if isinstance(node, ast.Subscript) and qualified_name(node.value) == "os.environ":
                if isinstance(node.slice, ast.Constant) and secret_name(str(node.slice.value)):
                    deny("コードからの秘密環境変数の取得は許可していません。")
            if not isinstance(node, ast.Call):
                continue
            name = qualified_name(node.func)
            if name in {"getattr", "builtins.getattr"}:
                name = qualified_name(node)
            process_args = node.args[1:] if name.startswith("os.spawn") else node.args
            argument = process_args[0] if process_args else next((item.value for item in node.keywords if item.arg == "args"), None)
            try:
                if name in {"eval", "exec", "builtins.eval", "builtins.exec"}:
                    if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
                        inspect_code(language, argument.value, cwd, depth + 1)
                elif name in {"subprocess.Popen", "subprocess.run", "subprocess.call", "subprocess.check_call", "subprocess.check_output", "subprocess.getoutput", "subprocess.getstatusoutput"}:
                    options = {item.arg: item.value.value for item in node.keywords if isinstance(item.value, ast.Constant)}
                    child_cwd = os.path.normpath(os.path.join(cwd, options["cwd"])) if isinstance(options.get("cwd"), str) else cwd
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
            except UnsupportedSyntax:
                pass
            if name in {"os.getenv", "os.environ.get"}:
                key = node.args[0] if node.args else next((item.value for item in node.keywords if item.arg == "key"), None)
                if isinstance(key, ast.Constant) and isinstance(key.value, str) and secret_name(key.value):
                    deny("コードからの秘密環境変数の取得は許可していません。")
            if (
                name in {"dict", "list", "print"}
                and any(qualified_name(item) == "os.environ" for item in node.args)
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
        return
    executable, strings = mask_code(language, code, cwd, depth)
    calls = (
        r"\b(eval|exec|execSync|execFile|execFileSync|spawn|spawnSync|system|popen|shell_exec|passthru|proc_open)"
        r"\s*\(?\s*__string_(\d+)__(?:\s*,\s*\[([^\]]*)\])?(?:\s*,\s*\{([^{}]*)\})?"
    )
    for match in re.finditer(calls, executable):
        name, literal, array, options = match.groups()
        value = strings[int(literal)]
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
                    child_cwd = os.path.normpath(os.path.join(cwd, strings[int(directory.group(1))]))
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


def interpreter_input(command, args):
    value_flags = {
        "python": {"-W", "-X", "--check-hash-based-pycs"},
        "python3": {"-W", "-X", "--check-hash-based-pycs"},
        "node": {"--input-type", "--require", "-r", "--import", "--loader"},
        "awk": {"-F", "-v", "-f"}, "gawk": {"-F", "-v", "-f"},
        "ruby": {"-I", "-r"}, "perl": {"-I", "-M"}, "php": {"-d", "-c"},
    }
    chunks, module, script, index = [], None, None, 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            script = args[index + 1] if index + 1 < len(args) else None
            break
        if arg == "-":
            script = arg
            break
        if arg in value_flags.get(command, set()):
            index += 2
            continue
        if arg.startswith("--"):
            if arg in {"--eval", "--print"}:
                if index + 1 >= len(args):
                    raise ParseError("inline code is missing")
                index += 1
                chunks.append(args[index])
            elif arg.startswith(("--eval=", "--print=")):
                chunks.append(arg.partition("=")[2])
        elif arg.startswith("-"):
            for position, flag in enumerate(arg[1:], 1):
                if "-" + flag in value_flags.get(command, set()):
                    if not arg[position + 1:]:
                        index += 1
                    break
                if command in {"python", "python3"} and flag == "m":
                    module = arg[position + 1:]
                    if not module:
                        index += 1
                        if index >= len(args):
                            raise ParseError("Python module is missing")
                        module = args[index]
                    return None, [module] + args[index + 1:], None
                if flag in CODE_OPTIONS[command]:
                    value = arg[position + 1:]
                    if not value:
                        index += 1
                        if index >= len(args):
                            raise ParseError("inline code is missing")
                        value = args[index]
                    chunks.append(value)
                    break
        else:
            if command in {"awk", "gawk"} and not chunks:
                chunks.append(arg)
            else:
                script = arg
            break
        if chunks and command in {"python", "python3"}:
            break
        index += 1
    return "\n".join(chunks) if chunks else None, module, script


def script_uses_stdin(path):
    if UNKNOWN_ARGUMENT in path:
        raise UnsupportedSyntax("dynamic script path")
    if path in {"/dev/stdin", "/dev/fd/0", "/proc/self/fd/0"}:
        return True
    if re.match(r"^/(?:dev|proc/(?:self|\d+))/fd/", path):
        raise UnsupportedSyntax("uninspected script file descriptor")
    return False


def inspect_argv(argv, cwd, depth, stdin=None, external=False):
    if depth > 32:
        raise ParseError("nested command limit exceeded")
    assignments = {}
    while argv and ASSIGNMENT.match(argv[0]):
        assignment = argv.pop(0)
        inspect_assignment(assignment, cwd)
        name, value = ASSIGNMENT.match(assignment).groups()
        if name == "TF_CLI_ARGS" or name.startswith("TF_CLI_ARGS_"):
            assignments[name] = value
    if not argv:
        return
    command = os.path.basename(argv[0]).casefold()
    args = argv[1:]
    if "$" in command or "`" in command or UNKNOWN_ARGUMENT in command:
        raise UnsupportedSyntax("dynamic command name")
    for arg in args:
        if command in {"export", "readonly", "declare", "typeset", "local", "env", "sudo"}:
            inspect_assignment(arg, cwd)
    if (
        command in {"read", "mapfile", "readarray"}
        and any(arg in EXECUTION_VARIABLES for arg in args)
        or command == "printf"
        and any(name in EXECUTION_VARIABLES for name in option_values(args, {"-v"}))
    ):
        deny("組み込みコマンドによる実行設定の差し替えは許可していません。")
    if command == "env":
        for index, arg in enumerate(args):
            if arg in {"-S", "--split-string"} or arg.startswith("--split-string="):
                joined = "=" in arg
                if not joined and index + 1 >= len(args):
                    raise ParseError("env split string is missing")
                value = arg.partition("=")[2] if joined else args[index + 1]
                split, nested = shell_tokens(value)
                if nested or any(not isinstance(word, Word) for word in split):
                    raise UnsupportedSyntax("unsupported env split string")
                args = args[:index] + [word.value for word in split] + args[index + (1 if joined else 2):]
                break
    if command in WRAPPER_VALUES:
        child, child_cwd = unwrap(command, args, cwd, assignments)
        if command == "env" and not child and not has_option(args, {"--help", "--version"}):
            deny("環境変数の一括出力は許可していません。")
        if child:
            child = [name + "=" + value for name, value in assignments.items()] + child
            if command == "xargs":
                inspect_argv(child, child_cwd, depth + 1, None, True)
            else:
                inspect_argv(child, child_cwd, depth + 1, stdin, external)
        return
    if command in {"terraform", "terragrunt"}:
        words = cli_words(command, args)
        while words and words[0] in {"run", "run-all", "stack"}:
            words = words[1:]
        if words:
            additional = []
            for name in ("TF_CLI_ARGS", "TF_CLI_ARGS_" + words[0]):
                split, nested = shell_tokens(assignments.get(name, ""))
                if not nested and all(isinstance(word, Word) and not word.parameters for word in split):
                    additional.extend(word.value for word in split)
            position = args.index(words[0]) + 1
            args = args[:position] + additional + args[position:]
    inspect_cli(command, args, cwd)
    inspect_paths(command, args, cwd)
    if command in {"terraform", "terragrunt"} and "console" in cli_words(command, args) and stdin is not None:
        inspect_code("terraform", stdin, cwd, depth + 1)
    if command == "rm" and has_option(args, {"--recursive"}, "rR"):
        for target in args:
            if target.startswith("-") or UNKNOWN_ARGUMENT in target:
                continue
            path = os.path.realpath(os.path.join(cwd, os.path.expanduser(target))).rstrip("/") or "/"
            home = os.path.realpath(os.path.expanduser("~"))
            if path in {"/", home} or path.startswith("/*") or path.startswith(home + "/*"):
                deny("ルート・ホーム全体の再帰削除は許可していません。")
    if command in {"kubectl", "oc", "docker", "podman", "nerdctl"}:
        if "--" in args and any(word in args[:args.index("--")] for word in {"exec", "rsh", "run"}):
            inspect_argv(args[args.index("--") + 1:], cwd, depth + 1, stdin, external)
        elif "exec" in args or "rsh" in args:
            operation = "exec" if "exec" in args else "rsh"
            words = cli_words(command, args[args.index(operation) + 1:], {"-e", "--env", "-u", "--user", "-w", "--workdir", "-c", "--container"})
            if len(words) > 1:
                inspect_argv(words[1:], cwd, depth + 1, stdin, external)
        if command in {"docker", "podman", "nerdctl"}:
            for value in option_values(args, {"-e", "--env", "--build-arg"}):
                name = value.partition("=")[0]
                if sensitive_parameter(name) or name in CREDENTIAL_PATH_VARIABLES and "=" not in value:
                    deny("資格情報をコンテナの環境へ渡すことは許可していません。")
            if has_option(args, {"--ssh"}):
                deny("認証エージェントをコンテナへ転送することは許可していません。")
    if command in SHELLS:
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
                if script_uses_stdin(arg):
                    if external:
                        raise UnsupportedSyntax("uninspected shell input")
                    if stdin is not None:
                        scan(stdin, cwd, depth + 1)
                return
            index += 1
        if external:
            raise UnsupportedSyntax("uninspected shell input")
        if stdin is not None:
            scan(stdin, cwd, depth + 1)
    elif command in {"eval", "trap"}:
        values = args[1:] if args[:1] == ["--"] else args
        if values and values[0] not in {"-", "", "-l", "-p"}:
            scan(" ".join(values) if command == "eval" else values[0], cwd, depth + 1, stdin, external)
    elif command in {"source", "."}:
        if args[:1] == ["--"]:
            args = args[1:]
        if args and credential_path(args[0], cwd):
            deny("認証情報ファイルの source は許可していません。")
        if args and script_uses_stdin(args[0]):
            if external:
                raise UnsupportedSyntax("uninspected source input")
            if stdin is not None:
                scan(stdin, cwd, depth + 1)
    elif command == "osascript":
        for code in option_values(args, {"-e"}) + ([stdin] if stdin is not None else []):
            executable = STRING_LITERAL.sub('""', code)
            if re.search(r"\bdo\s+shell\s+script\b", executable, re.I):
                deny("AppleScript からのシェル起動は許可していません。")
    elif command == "find":
        for index, arg in enumerate(args):
            if arg in {"-exec", "-execdir", "-ok", "-okdir"}:
                end = index + 1
                while end < len(args) and args[end] not in {";", "+"}:
                    end += 1
                if end == len(args):
                    raise ParseError("unterminated find executor")
                inspect_argv(args[index + 1:end], cwd, depth + 1)
    elif command == "git" and "foreach" in args:
        index = args.index("foreach")
        if "submodule" in args[:index] and index + 1 < len(args):
            scan(args[index + 1], cwd, depth + 1)
    elif command in {"npx", "npm", "pnpm", "yarn", "mise", "flock", "script"}:
        for code in option_values(args, {"-c", "--command", "--call"}):
            scan(code, cwd, depth + 1)
        if "--" in args:
            inspect_argv(args[args.index("--") + 1:], cwd, depth + 1)
        elif command in {"npx", "npm", "pnpm", "mise"}:
            start = next((index + 1 for index, arg in enumerate(args) if arg in {"exec", "x"}), 0 if command == "npx" else len(args))
            if start < len(args) and not args[start].startswith("-"):
                inspect_argv(args[start:], cwd, depth + 1)
    language = re.sub(r"\d+(?:\.\d+)*$", "", command)
    if language == "python":
        language = "python3"
    if language in INTERPRETERS:
        code, module, script = interpreter_input(language, args)
        if module is not None:
            if UNKNOWN_ARGUMENT in module[0]:
                raise UnsupportedSyntax("dynamic Python module")
            if module[0] in {"pip", "pip3"}:
                inspect_argv(module, cwd, depth + 1)
            return
        if code is not None:
            inspect_code(language, code, cwd)
        else:
            uses_stdin = not script or script == "-" or script_uses_stdin(script)
            if uses_stdin and external:
                raise UnsupportedSyntax("uninspected interpreter input")
            if uses_stdin and stdin is not None:
                inspect_code(language, stdin, cwd)
            if credential_path(script, cwd):
                deny("認証情報ファイルをコードとして読み込むことは許可していません。")


def scan(text, cwd, depth=0, input_text=None, input_external=False):
    if depth > 32:
        raise ParseError("nested command limit exceeded")
    if UNKNOWN_ARGUMENT in text:
        raise UnsupportedSyntax("dynamic shell code")
    tokens, nested = shell_tokens(text)
    spelling = [token.value if isinstance(token, Word) and not token.quoted else token for token in tokens]
    bomb = [":", "(", ")", "{", ":", "|", ":", "&", "}"]
    if any(spelling[index:index + len(bomb)] == bomb for index in range(len(spelling))):
        deny("fork bomb は許可していません。")
    for body in nested:
        scan(body, cwd, depth + 1, input_text, input_external)
    unit, piped = [], False
    for token in tokens + ["\n"]:
        if isinstance(token, Word) or token not in SEPARATORS:
            unit.append(token)
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
        presence = len(argv) in {3, 4} and argv[:1] in (["test"], ["["], ["[["]) and argv[1] in {"-e", "-f", "-n", "-z"}
        if not presence and any(sensitive_parameter(name) for word in words for name in word.parameters):
            deny("秘密値を持つ環境変数の明示展開は許可していません。")
        if argv and argv[0] not in {"for", "select", "case", "in", "esac", "fi", "done", "function"}:
            try:
                inspect_argv(argv, cwd, depth, stdin, external)
            except UnsupportedSyntax:
                pass
            if argv[:1] == ["cd"] and len(argv) == 2 and "$" not in argv[1]:
                cwd = os.path.abspath(os.path.join(cwd, os.path.expanduser(argv[1])))
        unit = []
        piped = token in {"|", "|&"}


def main():
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict) or not isinstance(event.get("tool_name"), str):
            raise ParseError("invalid hook input")
        if event["tool_name"] != "Bash":
            return 0
        tool_input = event.get("tool_input")
        if not isinstance(tool_input, dict) or not isinstance(tool_input.get("command"), str):
            raise ParseError("command must be a string")
        cwd = event.get("cwd", os.getcwd())
        if not isinstance(cwd, str) or not os.path.isabs(cwd):
            raise ParseError("cwd must be an absolute path")
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
