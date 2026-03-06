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
  : "${SIGNAL_BOT_NUMBER:?SIGNAL_BOT_NUMBER is required}"
  : "${SIGNAL_USER_PHONE:?SIGNAL_USER_PHONE is required}"
  : "${COMPASS_API_KEY:?COMPASS_API_KEY is required}"

  # Build the full Signal HTTP URL from components.
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
      -e "s|\${COMPASS_API_KEY}|${COMPASS_API_KEY}|g" \
      -e "s|\${OPENCLAW_GATEWAY_AUTH_TOKEN}|${OPENCLAW_GATEWAY_AUTH_TOKEN}|g" \
      -e "s|\${SIGNAL_BOT_NUMBER}|${SIGNAL_BOT_NUMBER}|g" \
      -e "s|\${SIGNAL_HTTP_URL}|${SIGNAL_HTTP_URL:-}|g" \
      -e "s|\${SIGNAL_USER_PHONE}|${SIGNAL_USER_PHONE}|g" \
      -e "s|\${OPENCLAW_STATE_DIR}|${OPENCLAW_STATE_DIR}|g" \
      /app/config/openclaw.json.example > "${OPENCLAW_CONFIG_FILE}"
  fi
  chmod 600 "${OPENCLAW_CONFIG_FILE}"
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
    ch['autoStart'] = True
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(f'Patched signal httpUrl in {cfg_path}')
" 2>/dev/null || echo "WARNING: failed to patch signal httpUrl (python3 unavailable or JSON parse error)"
fi

# Copy workspace template on first boot (if not already present on NFS).
# The template is baked into the image at /app/config/workspace/.
if [[ ! -d "${OPENCLAW_STATE_DIR}/workspace" ]]; then
  echo "Copying workspace template to ${OPENCLAW_STATE_DIR}/workspace/ ..."
  cp -r /app/config/workspace "${OPENCLAW_STATE_DIR}/workspace"

  # Resolve env var placeholders in skill docs (e.g., GRAPH_MCP_URL in SKILL.md)
  SKILL_FILE="${OPENCLAW_STATE_DIR}/workspace/skills/m365-graph-gateway/SKILL.md"
  if [[ -n "${GRAPH_MCP_URL:-}" ]] && [[ -f "${SKILL_FILE}" ]]; then
    echo "Resolving GRAPH_MCP_URL in m365-graph-gateway SKILL.md ..."
    envsubst '${GRAPH_MCP_URL}' < "${SKILL_FILE}" > "${SKILL_FILE}.tmp" \
      && mv "${SKILL_FILE}.tmp" "${SKILL_FILE}"
  fi
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
  # Start gateway with LAN binding (port configured in openclaw.json = 18789)
  exec openclaw gateway --allow-unconfigured --bind lan --port 18789
else
  exec openclaw "$@"
fi
