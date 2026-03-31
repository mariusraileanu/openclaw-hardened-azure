# Container Runtime Architecture

How the OpenClaw container boots, routes traffic, and manages per-user state.

## Golden Image

`Dockerfile.wrapper` wraps the upstream OpenClaw image with enterprise additions:

```
FROM ghcr.io/openclaw/openclaw:<version>

RUN apt-get install -y nano gettext-base

COPY config/openclaw.json.template  /app/config/
COPY scripts/build-openclaw-config.py /app/scripts/
COPY workspace/                     /app/config/workspace/
COPY loopback-proxy.mjs             /app/
COPY entrypoint.sh                  /app/

ENTRYPOINT ["/app/entrypoint.sh"]
```

- Runs as non-root (UID 1000)
- No secrets baked in -- everything injected via environment variables at runtime
- `gettext-base` provides `envsubst` for template resolution

## Loopback Proxy (`loopback-proxy.mjs`)

A single container hosts both the OpenClaw gateway and the Teams Bot Framework webhook. The loopback proxy multiplexes traffic on a single ingress port:

```
Internet/VNet
    |
    v
loopback-proxy.mjs  (0.0.0.0:18789, the ingress target port)
    |
    +-- POST /api/messages  -->  127.0.0.1:3978  (Teams Bot Framework SDK)
    +-- WebSocket upgrade   -->  127.0.0.1:18790  (OpenClaw gateway)
    +-- Everything else     -->  127.0.0.1:18790  (OpenClaw gateway)
```

The gateway binds to loopback only (`--bind loopback`), so `auth.mode=none` is safe -- only the proxy can reach it.

**Retry logic:** The Teams port (3978) may not be ready at container startup. The proxy retries ECONNREFUSED with exponential backoff (500ms, 1s, 2s, 4s -- ~7.5s total window).

## Boot Sequence (`entrypoint.sh`)

When the container starts with no arguments:

1. **Per-user data isolation** -- Validates `USER_SLUG` (regex: `^[a-z][a-z0-9-]{1,30}$`), sets `DATA_ROOT=/app/data/<slug>` on the shared NFS volume.

2. **Deterministic config build** -- Runs `scripts/build-openclaw-config.py` to assemble `openclaw.json` from `config/openclaw.json.template`. Logs the SHA-256 checksum for reproducibility.

3. **Fail-fast validation** -- In Azure/user mode, requires at least one channel (Signal or Teams) and rejects partial channel credentials.

4. **Workspace template copy** -- On first boot, copies the baked-in workspace (skills, tools, identity docs) from the image to the NFS volume. Subsequent boots skip this (workspace persists on NFS).

5. **Template resolution** -- Re-runs `envsubst` on `AGENTS.md` and `SKILL.md` on every boot to resolve `${GRAPH_MCP_URL}` placeholders. This ensures URL changes propagate without rebuilding the image.

6. **Legacy cleanup** -- Removes obsolete `workspace/instructions/` directory and legacy `tavily-search` skill folder from NFS.

7. **Environment bridging** -- Exports `OPENCLAW_GATEWAY_TOKEN` from `OPENCLAW_GATEWAY_AUTH_TOKEN` and writes vars to `/etc/profile.d/` and `~/.bashrc` for interactive `exec` shells.

8. **Start services** -- Launches `loopback-proxy.mjs` in background, then `exec`s `openclaw gateway --allow-unconfigured --bind loopback --port 18790`.

## NFS Volume

Each user's state lives on a shared NFS volume:

```
/app/data/
  alice/
    .openclaw/
      openclaw.json          # Runtime config (built on every boot)
      workspace/             # Skills, identity docs, agent instructions
      sessions/              # Conversation state
  bob/
    .openclaw/
      ...
```

The NFS share is mounted into the Container Apps Environment as `NfsAzureFile` type via Terraform AzAPI resources (the `azurerm` provider only supports `AzureFile`).

## Upgrading

```bash
# 1. Update the FROM line in Dockerfile.wrapper
# 2. Build and push (make-only target, no ocp equivalent)
make build-image ENV=prod IMAGE_TAG=v2.0.0

# 3. Redeploy each user
IMAGE_TAG=v2.0.0 ./platform/cli/ocp deploy user --env prod --user alice
```

When using `IMAGE_TAG=latest`, Terraform may not detect a change. Force a new revision:

```bash
az containerapp update -n ca-openclaw-prod-alice -g rg-openclaw-prod \
  --image openclawprodacr.azurecr.io/openclaw-wrapper:latest \
  --revision-suffix "$(date +%s)"
```

## Rolling Back

```bash
IMAGE_TAG=v1.0.0 ./platform/cli/ocp deploy user --env prod --user alice
```
