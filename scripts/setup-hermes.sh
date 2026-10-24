#!/usr/bin/env bash
# Hermes の非秘密設定を公式 CLI で適用

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

hermes config set model.provider openai-codex
hermes config set model.default gpt-6.1-sol
hermes config set model.openai_runtime auto
hermes config set agent.reasoning_effort max
hermes config set auth.adopt_external_logins false
hermes config set auth.codex_login_flow browser
hermes config set display.busy_input_mode interrupt
hermes config set display.bell_on_prompt true
hermes config set prefill_messages_file "$HOME/.hermes/prefill-messages.json"

hermes config set approvals.mode manual
hermes config set approvals.cron_mode deny
hermes config set approvals.single_query_mode deny
hermes config set approvals.unattended_mode deny
hermes config set approvals.mcp_reload_confirm true
hermes config set approvals.destructive_slash_confirm true
hermes config set command_allowlist '[]'

hermes config set security.redact_secrets true
hermes config set security.protected_instruction_files true
hermes config set security.allow_private_urls true
hermes config set checkpoints.enabled true

hermes config set hooks.pre_tool_call '[{"command":"~/.hermes/hooks/pre-tool-guard.py","timeout":10,"fail_closed":true}]'
hermes config set hooks_auto_accept false
hermes config set mcp.auto_reload_on_config_change false
hermes config set curator.enabled false
hermes config set auxiliary.background_review.enabled false
hermes config set skills.external_dirs '["~/.agents/skills"]'
hermes config set skills.inline_shell false
hermes config set skills.guard_agent_created true
hermes config set skills.write_approval false
hermes config set delegation.max_spawn_depth 2
hermes config set agent.disabled_toolsets '[]'

hermes config set web.search_backend openai-native
hermes config set AGENT_BROWSER_EXECUTABLE_PATH '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'
hermes config set browser.use_real_profile false
hermes config set browser.allow_unsafe_evaluate false
hermes config set browser.restrict_evaluate true
hermes config set browser.allow_private_urls true
hermes config set browser.extension_control.enabled true

hermes config set computer_use.permission_mode standard
hermes config set computer_use.cua_telemetry false
hermes config set telemetry.shared_metrics.enabled false
hermes config set telemetry.shared_metrics.send false
hermes config set telemetry.shared_metrics.offer_version 2
