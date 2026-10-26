#!/usr/bin/env bash
# Hermes の非秘密設定を公式 CLI で適用

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# bootstrap では設定成功の明細だけを省略
set_hermes_config() {
  if [[ ${DOTFILES_BOOTSTRAP:-0} == 1 ]]; then
    hermes config set "$@" | sed '/^✓ Set /d'
  else
    hermes config set "$@"
  fi
}

set_hermes_config model.provider openai-codex
set_hermes_config model.default gpt-6.1-sol
set_hermes_config model.openai_runtime auto
# reasoning_effort と offer_version は実行時に参照されるが既定スキーマに未登録
set_hermes_config --force agent.reasoning_effort max
set_hermes_config auth.adopt_external_logins false
set_hermes_config auth.codex_login_flow browser
set_hermes_config display.busy_input_mode interrupt
set_hermes_config display.bell_on_prompt true
set_hermes_config prefill_messages_file "$HOME/.hermes/prefill-messages.json"

set_hermes_config approvals.mode manual
set_hermes_config approvals.cron_mode deny
set_hermes_config approvals.single_query_mode deny
set_hermes_config approvals.unattended_mode deny
set_hermes_config approvals.mcp_reload_confirm true
set_hermes_config approvals.destructive_slash_confirm true
set_hermes_config command_allowlist '[]'

set_hermes_config security.redact_secrets true
set_hermes_config security.protected_instruction_files true
set_hermes_config security.allow_private_urls true
set_hermes_config checkpoints.enabled true

set_hermes_config hooks.pre_tool_call '[{"command":"~/.hermes/hooks/pre-tool-guard.py","timeout":10,"fail_closed":true}]'
set_hermes_config hooks_auto_accept false
set_hermes_config mcp.auto_reload_on_config_change false
set_hermes_config curator.enabled false
set_hermes_config auxiliary.background_review.enabled false
set_hermes_config skills.external_dirs '["~/.agents/skills"]'
set_hermes_config skills.inline_shell false
set_hermes_config skills.guard_agent_created true
set_hermes_config skills.write_approval false
set_hermes_config delegation.max_spawn_depth 2
set_hermes_config agent.disabled_toolsets '[]'

set_hermes_config web.search_backend openai-native
set_hermes_config web.provider_tier.keenable free
set_hermes_config web.extract_backend keenable
set_hermes_config AGENT_BROWSER_EXECUTABLE_PATH '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'
set_hermes_config browser.use_real_profile false
set_hermes_config browser.allow_unsafe_evaluate false
set_hermes_config browser.restrict_evaluate true
set_hermes_config browser.allow_private_urls true
set_hermes_config browser.extension_control.enabled true

set_hermes_config computer_use.permission_mode standard
set_hermes_config computer_use.cua_telemetry false
set_hermes_config telemetry.shared_metrics.enabled false
set_hermes_config telemetry.shared_metrics.send false
set_hermes_config --force telemetry.shared_metrics.offer_version 2
