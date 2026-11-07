#!/usr/bin/env bash
# Hermes の非秘密設定を公式 CLI の設定処理で適用

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# bootstrap では設定成功の明細だけを省略
success_filter=
if [[ ${DOTFILES_BOOTSTRAP:-0} == 1 ]]; then
  success_filter='/^✓ Set /d'
fi

python3.14 - <<'PYTHON' | sed "$success_filter"
import json
import os
from pathlib import Path
import subprocess

# 副作用のない標準モジュールで初期化だけを行い、CLI が返す Python -c に設定処理を続ける
command = json.loads(subprocess.check_output(
    ["hermes", "--print-runtime-command", "--module", "__future__"], text=True,
))
command[3] += r'''
from argparse import Namespace
import sys

prefill_messages_file = sys.argv[1]
# import 時の初期化を config set と同じ条件で行う
sys.argv = ["hermes", "config", "set"]
from hermes_cli.main import cmd_config


# 公式 CLI の設定処理で1項目を適用する
def set_hermes_config(key, value, force=False):
    cmd_config(Namespace(config_command="set", key=key, value=value, force=force))


set_hermes_config("model.provider", "openai-codex")
set_hermes_config("model.default", "gpt-6.1-sol")
set_hermes_config("model.openai_runtime", "auto")
# reasoning_effort と offer_version は実行時に参照されるが既定スキーマに未登録
set_hermes_config("agent.reasoning_effort", "max", force=True)
set_hermes_config("auth.adopt_external_logins", "false")
set_hermes_config("auth.codex_login_flow", "browser")
set_hermes_config("display.busy_input_mode", "interrupt")
set_hermes_config("display.bell_on_prompt", "true")
set_hermes_config("prefill_messages_file", prefill_messages_file)

set_hermes_config("approvals.mode", "manual")
set_hermes_config("approvals.cron_mode", "deny")
set_hermes_config("approvals.single_query_mode", "deny")
set_hermes_config("approvals.unattended_mode", "deny")
set_hermes_config("approvals.mcp_reload_confirm", "true")
set_hermes_config("approvals.destructive_slash_confirm", "true")
set_hermes_config("command_allowlist", "[]")

set_hermes_config("security.redact_secrets", "true")
set_hermes_config("security.protected_instruction_files", "true")
set_hermes_config("security.allow_private_urls", "true")
set_hermes_config("checkpoints.enabled", "true")

set_hermes_config("hooks.pre_tool_call", '[{"command":"~/.hermes/hooks/pre-tool-guard.py","timeout":10,"fail_closed":true}]')
set_hermes_config("hooks_auto_accept", "false")
set_hermes_config("mcp.auto_reload_on_config_change", "false")
set_hermes_config("curator.enabled", "false")
set_hermes_config("auxiliary.background_review.enabled", "false")
set_hermes_config("skills.external_dirs", '["~/.agents/skills"]')
set_hermes_config("skills.inline_shell", "false")
set_hermes_config("skills.guard_agent_created", "true")
set_hermes_config("skills.write_approval", "false")
set_hermes_config("delegation.max_spawn_depth", "2")
set_hermes_config("agent.disabled_toolsets", "[]")

set_hermes_config("web.search_backend", "openai-native")
set_hermes_config("web.provider_tier.keenable", "free")
set_hermes_config("web.extract_backend", "keenable")
set_hermes_config("browser.executable_path", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
set_hermes_config("browser.use_real_profile", "false")
set_hermes_config("browser.allow_private_urls", "true")

set_hermes_config("computer_use.permission_mode", "standard")
set_hermes_config("computer_use.cua_telemetry", "false")
set_hermes_config("telemetry.shared_metrics.enabled", "false")
set_hermes_config("telemetry.shared_metrics.send", "false")
set_hermes_config("telemetry.shared_metrics.offer_version", "2", force=True)
'''
command.append(str(Path.home() / ".hermes/prefill-messages.json"))
os.execv(command[0], command)
PYTHON
