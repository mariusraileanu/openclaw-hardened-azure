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

fi

# Ensure config and data directories exist
mkdir -p "${DATA_ROOT}/.openclaw"

# Override OpenClaw's state/config paths to point at the per-user directory
export OPENCLAW_CONFIG_FILE="${DATA_ROOT}/.openclaw/openclaw.json"
export OPENCLAW_STATE_DIR="${DATA_ROOT}/.openclaw"

# Build deterministic runtime config from versioned template tooling.
# This replaces repeated per-feature mutation blocks with one schema-safe build.
if command -v python3 >/dev/null 2>&1; then
  /app/platform/scripts/build_config.py \
    --template /app/config/openclaw.json.template \
    --output "${OPENCLAW_CONFIG_FILE}"
  chmod 600 "${OPENCLAW_CONFIG_FILE}"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "Runtime config checksum: $(sha256sum "${OPENCLAW_CONFIG_FILE}" | awk '{print $1}')"
  fi
else
  echo "FATAL: python3 is required to build runtime config" >&2
  exit 1
fi

# Copy workspace template on first boot (if not already present on NFS).
# The template is baked into the image at /app/config/workspace/.
if [[ ! -d "${OPENCLAW_STATE_DIR}/workspace" ]]; then
  echo "Copying workspace template to ${OPENCLAW_STATE_DIR}/workspace/ ..."
  cp -r /app/config/workspace "${OPENCLAW_STATE_DIR}/workspace"
fi

# Refresh AGENTS.md from image source on every boot to pick up structural
# changes (e.g. slimmed M365 section) on existing NFS workspaces.
# Must run BEFORE render_workspaces.py which appends the Board Access section.
AGENTS_FILE="${OPENCLAW_STATE_DIR}/workspace/AGENTS.md"
SOURCE_AGENTS="/app/config/workspace/AGENTS.md"
if [[ -f "${SOURCE_AGENTS}" ]]; then
  cp "${SOURCE_AGENTS}" "${AGENTS_FILE}"
fi

echo "Refreshing board workspaces and base board-routing rules ..."
/app/platform/scripts/render_workspaces.py

if [[ -d "/app/plugins/board-router" ]]; then
  # Remove any stale installed copy so `plugins install` can overwrite cleanly.
  # The data volume persists across container restarts; without this, the
  # install command errors with "plugin already exists".
  rm -rf "${OPENCLAW_STATE_DIR}/extensions/board-router"
  echo "Installing local board-router plugin ..."
  openclaw plugins install /app/plugins/board-router || {
    echo "FATAL: failed to install board-router plugin" >&2
    exit 1
  }
fi

# Copy dynamically-generated skills into /app/skills/ (the built-in skills
# directory probed first by the runtime) so it finds them without falling back
# to the workspace copy.  Use cp instead of ln -s because the runtime rejects
# symlinks that escape the skills root directory.
BOARD_ROUTING_SKILL="${OPENCLAW_STATE_DIR}/workspace/skills/board-routing/SKILL.md"
if [[ -f "${BOARD_ROUTING_SKILL}" ]]; then
  mkdir -p /app/skills/board-routing
  cp "${BOARD_ROUTING_SKILL}" /app/skills/board-routing/SKILL.md
fi

# Always refresh m365-graph-gateway SKILL.md from image source on every boot.
# Creates the file if missing (e.g., workspace was seeded before the skill existed)
# and resolves ${GRAPH_MCP_URL} placeholders when the env var is set.
SKILL_FILE="${OPENCLAW_STATE_DIR}/workspace/skills/m365-graph-gateway/SKILL.md"
SOURCE_SKILL="/app/config/workspace/skills/m365-graph-gateway/SKILL.md"
if [[ -f "${SOURCE_SKILL}" ]]; then
  mkdir -p "$(dirname "${SKILL_FILE}")"
  if [[ -n "${GRAPH_MCP_URL:-}" ]]; then
    echo "Refreshing m365-graph-gateway SKILL.md (with GRAPH_MCP_URL) ..."
    envsubst '${GRAPH_MCP_URL}' < "${SOURCE_SKILL}" > "${SKILL_FILE}.tmp" \
      && mv "${SKILL_FILE}.tmp" "${SKILL_FILE}"
  else
    echo "Refreshing m365-graph-gateway SKILL.md ..."
    cp "${SOURCE_SKILL}" "${SKILL_FILE}"
  fi
fi

# Always refresh TOOL_CONTRACT.md from image source so updated gateway contract
# docs are propagated to existing NFS workspaces on every boot.
CONTRACT_FILE="${OPENCLAW_STATE_DIR}/workspace/skills/m365-graph-gateway/references/TOOL_CONTRACT.md"
SOURCE_CONTRACT="/app/config/workspace/skills/m365-graph-gateway/references/TOOL_CONTRACT.md"
if [[ -f "${SOURCE_CONTRACT}" ]]; then
  echo "Refreshing m365-graph-gateway TOOL_CONTRACT.md ..."
  mkdir -p "$(dirname "${CONTRACT_FILE}")"
  cp "${SOURCE_CONTRACT}" "${CONTRACT_FILE}"
fi

# Clean up legacy workspace/instructions/ directory from NFS.
# M365 gateway instructions now live in the m365-graph-gateway SKILL.md;
# the separate instructions/ dir was redundant.
LEGACY_INSTR_DIR="${OPENCLAW_STATE_DIR}/workspace/instructions"
if [[ -d "${LEGACY_INSTR_DIR}" ]]; then
  echo "Removing legacy workspace/instructions/ dir (content lives in AGENTS.md)..."
  rm -rf "${LEGACY_INSTR_DIR}"
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

# Pre-seed the main webchat session so the Control UI shows it even when
# heartbeat.isolatedSession is true.  The heartbeat gets its own session
# (agent:main:main:heartbeat) and the Control UI has no "New Chat" button,
# so without this seed the user only sees the heartbeat conversation.
SESSIONS_DIR="${OPENCLAW_STATE_DIR}/agents/main/sessions"
SESSIONS_JSON="${SESSIONS_DIR}/sessions.json"

# Force a blank session on every boot (local dev).  This clears stale
# context that persists across restarts due to continuation-skip.
if [[ "${OPENCLAW_FRESH_SESSION:-}" == "true" ]] && [[ -d "${SESSIONS_DIR}" ]]; then
  echo "OPENCLAW_FRESH_SESSION: wiping sessions for a clean start ..."
  rm -rf "${SESSIONS_DIR}"
fi

_need_seed=false
if [[ ! -f "${SESSIONS_JSON}" ]]; then
  _need_seed=true
elif ! python3 -c "import json,sys; d=json.load(open(sys.argv[1])); exit(0 if 'agent:main:main' in d else 1)" "${SESSIONS_JSON}" 2>/dev/null; then
  _need_seed=true
fi
if [[ "${_need_seed}" == "true" ]]; then
  echo "Seeding main webchat session ..."
  mkdir -p "${SESSIONS_DIR}"
  python3 -c "
import json, os, sys, time, uuid
sessions_json = sys.argv[1]
data = {}
if os.path.exists(sessions_json):
    with open(sessions_json) as f:
        data = json.load(f)
sid = str(uuid.uuid4())
data['agent:main:main'] = {
    'sessionId': sid,
    'updatedAt': int(time.time() * 1000),
    'chatType': 'direct'
}
with open(sessions_json, 'w') as f:
    json.dump(data, f, indent=2)
# Create empty session history file
open(os.path.join(os.path.dirname(sessions_json), sid + '.jsonl'), 'a').close()
print(f'Seeded session {sid}')
" "${SESSIONS_JSON}"
fi

if [ $# -eq 0 ]; then
  # Run the HTTP reverse proxy on 0.0.0.0:18789 (the ingress target port).
  # It routes POST /api/messages → 127.0.0.1:3978 (Teams webhook) and
  # everything else → 127.0.0.1:18790 (OpenClaw gateway).
  # The gateway binds to loopback only, so auth.mode=none is safe.
  node /app/channels/loopback-proxy.mjs 18789 18790 3978 &
  exec openclaw gateway --allow-unconfigured --bind loopback --port 18790
else
  exec openclaw "$@"
fi
