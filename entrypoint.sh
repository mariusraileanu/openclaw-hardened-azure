#!/bin/bash
set -euo pipefail

# Per-user data isolation: when USER_SLUG is set (Azure Container Apps),
# store all state under /app/data/<slug>/ so each user gets their own
# config, sessions, and memory on the shared NFS volume.
DATA_ROOT="/app/data"
if [[ -n "${USER_SLUG:-}" ]]; then
  # Validate USER_SLUG to prevent path traversal (e.g. "../../etc")
  if [[ ! "${USER_SLUG}" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
    echo "FATAL: USER_SLUG contains invalid characters: '${USER_SLUG}'" >&2
    exit 1
  fi
  DATA_ROOT="/app/data/${USER_SLUG}"

  # Validate required environment variables (only on Azure, not local dev)
  : "${COMPASS_API_KEY:?COMPASS_API_KEY is required}"

  # Signal is optional — warn if partially configured
  if [[ -n "${SIGNAL_BOT_NUMBER:-}" && -z "${SIGNAL_USER_PHONE:-}" ]]; then
    echo "WARNING: SIGNAL_BOT_NUMBER is set but SIGNAL_USER_PHONE is missing — Signal channel will be disabled" >&2
  fi

  # Build the full Signal HTTP URL from components (only if all pieces present).
  # SIGNAL_CLI_URL = base URL (e.g. http://host)
  # SIGNAL_PROXY_AUTH_TOKEN = optional auth token (embedded as path segment)
  # Result: http://host/user/+PHONE/TOKEN  (client appends /api/v1/events etc.)
  if [[ -n "${SIGNAL_CLI_URL:-}" && -n "${SIGNAL_USER_PHONE:-}" ]]; then
    SIGNAL_HTTP_URL="${SIGNAL_CLI_URL}/user/${SIGNAL_USER_PHONE}"
    if [[ -n "${SIGNAL_PROXY_AUTH_TOKEN:-}" ]]; then
      SIGNAL_HTTP_URL="${SIGNAL_HTTP_URL}/${SIGNAL_PROXY_AUTH_TOKEN}"
    fi
    export SIGNAL_HTTP_URL
  fi
fi

# Ensure config and data directories exist
mkdir -p "${DATA_ROOT}/.openclaw"

# Override OpenClaw's state/config paths to point at the per-user directory
export OPENCLAW_CONFIG_FILE="${DATA_ROOT}/.openclaw/openclaw.json"
export OPENCLAW_STATE_DIR="${DATA_ROOT}/.openclaw"

# Initialize config if not exists (first boot or fresh NFS share).
# The template uses ${VAR} placeholders — envsubst resolves them from
# the container's environment (COMPASS_API_KEY, SIGNAL_BOT_NUMBER, etc.).
if [[ ! -f "${OPENCLAW_CONFIG_FILE}" ]]; then
  echo "Initializing default enterprise config from example..."
  if command -v envsubst &>/dev/null; then
    envsubst < /app/config/openclaw.json.example > "${OPENCLAW_CONFIG_FILE}"
  else
    # Fallback: manual sed substitution for key variables
    sed \
      -e "s|\${COMPASS_BASE_URL}|${COMPASS_BASE_URL:-https://api.core42.ai/v1}|g" \
      -e "s|\${COMPASS_API_KEY}|${COMPASS_API_KEY}|g" \
      -e "s|\${OPENCLAW_GATEWAY_AUTH_TOKEN}|${OPENCLAW_GATEWAY_AUTH_TOKEN:-}|g" \
      -e "s|\${SIGNAL_BOT_NUMBER}|${SIGNAL_BOT_NUMBER:-}|g" \
      -e "s|\${SIGNAL_HTTP_URL}|${SIGNAL_HTTP_URL:-}|g" \
      -e "s|\${SIGNAL_USER_PHONE}|${SIGNAL_USER_PHONE:-}|g" \
      -e "s|\${OPENCLAW_STATE_DIR}|${OPENCLAW_STATE_DIR}|g" \
      /app/config/openclaw.json.example > "${OPENCLAW_CONFIG_FILE}"
  fi
  chmod 600 "${OPENCLAW_CONFIG_FILE}"

  # If Signal is not configured, disable the channel in the generated config
  if [[ -z "${SIGNAL_BOT_NUMBER:-}" || -z "${SIGNAL_USER_PHONE:-}" ]]; then
    python3 -c "
import json, os
cfg_path = os.environ['OPENCLAW_CONFIG_FILE']
with open(cfg_path) as f:
    cfg = json.load(f)
ch = cfg.get('channels', {}).get('signal')
if ch:
    ch['enabled'] = False
    ch['autoStart'] = False
    # Remove allowlist policy when there are no valid senders — newer OpenClaw
    # versions reject dmPolicy=allowlist with an empty/placeholder allowFrom.
    allow = ch.get('allowFrom', [])
    if not allow or all(not s or s.startswith('\${') for s in allow):
        ch.pop('dmPolicy', None)
        ch.pop('allowFrom', None)
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(f'Signal not configured — disabled signal channel in {cfg_path}')
" 2>/dev/null || echo "WARNING: failed to disable signal channel (python3 unavailable or JSON parse error)"
  fi
fi

# Always patch the Compass provider baseUrl and apiKey in openclaw.json on every boot.
# This ensures env var changes propagate to existing users without requiring a config wipe.
if [[ -f "${OPENCLAW_CONFIG_FILE}" ]]; then
  python3 -c "
import json, os
cfg_path = os.environ['OPENCLAW_CONFIG_FILE']
base_url = os.environ.get('COMPASS_BASE_URL', 'https://api.core42.ai/v1')
api_key = os.environ.get('COMPASS_API_KEY', '')
with open(cfg_path) as f:
    cfg = json.load(f)
compass = cfg.get('models', {}).get('providers', {}).get('compass', {})
changed = False
if compass and compass.get('baseUrl') != base_url:
    compass['baseUrl'] = base_url
    changed = True
if compass and api_key and compass.get('apiKey') != api_key:
    compass['apiKey'] = api_key
    changed = True
if changed:
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(f'Patched Compass provider (baseUrl={base_url}) in {cfg_path}')
" 2>/dev/null || echo "WARNING: failed to patch Compass provider config"
fi

# Always patch the signal httpUrl in openclaw.json on every boot.
# This ensures env var changes (e.g., new auth tokens, URL updates) propagate
# to existing users without requiring a config wipe.
if [[ -n "${SIGNAL_HTTP_URL:-}" && -f "${OPENCLAW_CONFIG_FILE}" ]]; then
  python3 -c "
import json, sys, os
cfg_path = os.environ['OPENCLAW_CONFIG_FILE']
url = os.environ['SIGNAL_HTTP_URL']
with open(cfg_path) as f:
    cfg = json.load(f)
ch = cfg.get('channels', {}).get('signal', {})
if ch:
    ch['httpUrl'] = url
    ch['enabled'] = True
    ch['autoStart'] = False  # httpUrl mode: don't spawn local signal-cli
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(f'Patched signal httpUrl and re-enabled channel in {cfg_path}')
" 2>/dev/null || echo "WARNING: failed to patch signal httpUrl (python3 unavailable or JSON parse error)"
fi

# Copy workspace template on first boot (if not already present on NFS).
# The template is baked into the image at /app/config/workspace/.
if [[ ! -d "${OPENCLAW_STATE_DIR}/workspace" ]]; then
  echo "Copying workspace template to ${OPENCLAW_STATE_DIR}/workspace/ ..."
  cp -r /app/config/workspace "${OPENCLAW_STATE_DIR}/workspace"
fi

# Always resolve env var placeholders in skill docs on every boot.
# This ensures GRAPH_MCP_URL changes propagate to existing workspaces
# (same pattern as the Compass baseUrl and Signal httpUrl patching above).
SKILL_FILE="${OPENCLAW_STATE_DIR}/workspace/skills/m365-graph-gateway/SKILL.md"
if [[ -n "${GRAPH_MCP_URL:-}" ]] && [[ -f "${SKILL_FILE}" ]]; then
  # Re-template from the image source (which has ${GRAPH_MCP_URL} placeholders)
  # to ensure we always get a clean substitution even if the file was previously
  # written with stale or missing values.
  SOURCE_SKILL="/app/config/workspace/skills/m365-graph-gateway/SKILL.md"
  if [[ -f "${SOURCE_SKILL}" ]]; then
    echo "Resolving GRAPH_MCP_URL in m365-graph-gateway SKILL.md ..."
    envsubst '${GRAPH_MCP_URL}' < "${SOURCE_SKILL}" > "${SKILL_FILE}.tmp" \
      && mv "${SKILL_FILE}.tmp" "${SKILL_FILE}"
  fi
fi

# Always resolve env var placeholders in AGENTS.md on every boot.
# AGENTS.md is loaded on every request and contains ${GRAPH_MCP_URL} placeholders
# for the M365 gateway instructions.
AGENTS_FILE="${OPENCLAW_STATE_DIR}/workspace/AGENTS.md"
SOURCE_AGENTS="/app/config/workspace/AGENTS.md"
if [[ -n "${GRAPH_MCP_URL:-}" ]] && [[ -f "${SOURCE_AGENTS}" ]]; then
  echo "Resolving GRAPH_MCP_URL in AGENTS.md ..."
  envsubst '${GRAPH_MCP_URL}' < "${SOURCE_AGENTS}" > "${AGENTS_FILE}.tmp" \
    && mv "${AGENTS_FILE}.tmp" "${AGENTS_FILE}"
fi

# Clean up legacy workspace/instructions/ directory from NFS.
# M365 gateway instructions are now in AGENTS.md only; the separate
# instructions/ dir was redundant and wasted context-window tokens.
LEGACY_INSTR_DIR="${OPENCLAW_STATE_DIR}/workspace/instructions"
if [[ -d "${LEGACY_INSTR_DIR}" ]]; then
  echo "Removing legacy workspace/instructions/ dir (content lives in AGENTS.md)..."
  rm -rf "${LEGACY_INSTR_DIR}"
fi

# Always remove the 'instructions' key from openclaw.json if it exists.
# OpenClaw does not support this config key and will reject the config.
if [[ -f "${OPENCLAW_CONFIG_FILE}" ]]; then
  python3 -c "
import json, os
cfg_path = os.environ['OPENCLAW_CONFIG_FILE']
with open(cfg_path) as f:
    cfg = json.load(f)
if 'instructions' in cfg:
    del cfg['instructions']
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(f'Removed invalid instructions key from {cfg_path}')
" 2>/dev/null || echo "WARNING: failed to clean instructions key from openclaw.json"
fi

# Patch gateway auth config on every boot.
# - Local dev (no USER_SLUG): mode=none + loopback proxy (no external access)
# - Azure (USER_SLUG set):    mode=token + LAN binding (token-authenticated access)
if [[ -f "${OPENCLAW_CONFIG_FILE}" ]]; then
  python3 -c "
import json, os
cfg_path = os.environ['OPENCLAW_CONFIG_FILE']
is_azure = bool(os.environ.get('USER_SLUG'))
with open(cfg_path) as f:
    cfg = json.load(f)
gw = cfg.setdefault('gateway', {})
changed = False

auth = gw.setdefault('auth', {})
if is_azure:
    # Azure: token auth with the gateway shared secret
    token = os.environ.get('OPENCLAW_GATEWAY_AUTH_TOKEN', '')
    if auth.get('mode') != 'token' and token:
        auth['mode'] = 'token'
        auth['token'] = token
        changed = True
    elif token and auth.get('token') != token:
        auth['token'] = token
        changed = True
else:
    # Local dev: no auth (loopback proxy makes all connections local)
    if auth.get('mode') != 'none':
        auth['mode'] = 'none'
        auth.pop('token', None)
        changed = True

# controlUi config depends on binding mode
ui = gw.setdefault('controlUi', {})
if is_azure:
    # Azure (LAN binding): non-loopback requires origin fallback flag
    if not ui.get('dangerouslyAllowHostHeaderOriginFallback'):
        ui['dangerouslyAllowHostHeaderOriginFallback'] = True
        changed = True
    # Strip flags that only apply to local dev
    if ui.pop('dangerouslyDisableDeviceAuth', None) is not None:
        changed = True
else:
    # Local dev (loopback): strip flags that are unnecessary
    for key in ['dangerouslyAllowHostHeaderOriginFallback', 'dangerouslyDisableDeviceAuth']:
        if key in ui:
            del ui[key]
            changed = True
# Remove empty controlUi block
if 'controlUi' in gw and not gw['controlUi']:
    del gw['controlUi']
    changed = True

if changed:
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    env_label = 'Azure (token)' if is_azure else 'local (none)'
    print(f'Patched gateway auth config [{env_label}] in {cfg_path}')
" 2>/dev/null || echo "WARNING: failed to patch gateway auth config"
fi

# Always clean up invalid Signal dmPolicy/allowFrom on existing configs.
# Newer OpenClaw versions reject dmPolicy=allowlist when allowFrom is empty.
if [[ -f "${OPENCLAW_CONFIG_FILE}" ]]; then
  python3 -c "
import json, os
cfg_path = os.environ['OPENCLAW_CONFIG_FILE']
with open(cfg_path) as f:
    cfg = json.load(f)
ch = cfg.get('channels', {}).get('signal', {})
if not ch.get('enabled', True):
    allow = ch.get('allowFrom', [])
    if ch.get('dmPolicy') == 'allowlist' and (not allow or all(not s or s.startswith('\${') for s in allow)):
        ch.pop('dmPolicy', None)
        ch.pop('allowFrom', None)
        with open(cfg_path, 'w') as f:
            json.dump(cfg, f, indent=2)
        print(f'Removed invalid Signal dmPolicy/allowFrom in {cfg_path}')
" 2>/dev/null || echo "WARNING: failed to clean Signal dmPolicy config"
fi

# Always ensure the Tavily plugin and web search provider are configured.
# This patches existing openclaw.json files (on NFS) so all users get the
# native Tavily plugin without a config wipe. Also injects the TAVILY_API_KEY
# directly into the config as belt-and-suspenders (the runtime also checks
# process.env.TAVILY_API_KEY, but Azure KV secret-ref env vars can be empty
# at startup in edge cases).
if [[ -f "${OPENCLAW_CONFIG_FILE}" ]]; then
  python3 -c "
import json, os
cfg_path = os.environ['OPENCLAW_CONFIG_FILE']
tavily_key = os.environ.get('TAVILY_API_KEY', '')
with open(cfg_path) as f:
    cfg = json.load(f)
changed = False

# Ensure plugins.entries.tavily exists and is enabled
plugins = cfg.setdefault('plugins', {})
entries = plugins.setdefault('entries', {})
tavily = entries.setdefault('tavily', {})
if not tavily.get('enabled'):
    tavily['enabled'] = True
    changed = True
ws = tavily.setdefault('config', {}).setdefault('webSearch', {})
if ws.get('baseUrl') != 'https://api.tavily.com':
    ws['baseUrl'] = 'https://api.tavily.com'
    changed = True

# Inject the API key from env into config (belt-and-suspenders).
# The runtime checks config first, then env — this ensures both paths work.
if tavily_key and ws.get('apiKey') != tavily_key:
    ws['apiKey'] = tavily_key
    changed = True

# Ensure tools.web.search.provider is set to tavily
tools = cfg.setdefault('tools', {})
web = tools.setdefault('web', {})
search = web.setdefault('search', {})
if search.get('provider') != 'tavily':
    search['provider'] = 'tavily'
    changed = True

if changed:
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(f'Patched Tavily plugin config in {cfg_path}')
" 2>/dev/null || echo "WARNING: failed to patch Tavily plugin config"
fi

# Remove the legacy tavily-search skill from existing workspaces (replaced
# by the native Tavily plugin configured above). Safe to run on every boot;
# the rm is a no-op once the directory is gone.
LEGACY_TAVILY="${OPENCLAW_STATE_DIR}/workspace/skills/tavily-search"
if [[ -d "${LEGACY_TAVILY}" ]]; then
  echo "Removing legacy tavily-search skill (replaced by native plugin)..."
  rm -rf "${LEGACY_TAVILY}"
fi

# Bridge env var naming: Azure KV sets OPENCLAW_GATEWAY_AUTH_TOKEN,
# but the CLI --token flag reads OPENCLAW_GATEWAY_TOKEN (without _AUTH_).
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_AUTH_TOKEN:-}"

# Write env vars to a profile so interactive `exec` shells inherit them.
# Usage: `source /etc/profile.d/openclaw.sh` or automatic via bash login shell.
{
cat > /etc/profile.d/openclaw.sh <<PROFILE_EOF
export OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_FILE}"
export OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR}"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}"
PROFILE_EOF
chmod 644 /etc/profile.d/openclaw.sh
} 2>/dev/null || true

# Also write to .bashrc for non-login interactive shells (az containerapp exec)
{
  echo "export OPENCLAW_CONFIG_FILE=\"${OPENCLAW_CONFIG_FILE}\""
  echo "export OPENCLAW_STATE_DIR=\"${OPENCLAW_STATE_DIR}\""
  echo "export OPENCLAW_GATEWAY_TOKEN=\"${OPENCLAW_GATEWAY_TOKEN}\""
} >> "${HOME}/.bashrc" 2>/dev/null || true

if [ $# -eq 0 ]; then
  if [[ -n "${USER_SLUG:-}" ]]; then
    # Azure: bind to LAN (0.0.0.0) with token auth so the Container Apps
    # ingress can reach the gateway.  Auth is enforced via the shared secret.
    exec openclaw gateway --allow-unconfigured --bind lan --port 18789
  else
    # Local dev: run a TCP proxy on 0.0.0.0:18789 forwarding to 127.0.0.1:18790.
    # This makes the gateway see all inbound connections as coming from loopback,
    # satisfying isLocalClient checks for Control UI device-auth scopes.
    # The gateway binds to loopback-only (auth.mode=none is safe for loopback).
    node /app/loopback-proxy.mjs 18789 18790 &
    exec openclaw gateway --allow-unconfigured --bind loopback --port 18790
  fi
else
  exec openclaw "$@"
fi
