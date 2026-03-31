# OpenClaw Azure Platform

Shared-platform, per-user isolated deployment of [OpenClaw](https://github.com/openclaw/openclaw) on Azure Container Apps with optional Signal messaging.

## Start Here

- First-time setup: `docs/onboarding/quickstart.md`
- Day-2 operations: `docs/runbooks/day-2-operations.md`
- Destructive reset flow: `docs/runbooks/platform-reset.md`
- Deep rebuild details and caveats: `REBUILD.md`

## Operator Cheat Sheet

Use `ocp` as the primary interface. `make` remains a compatibility alias layer.

| Action | Preferred (`ocp`) | Make alias |
|--------|-------------------|------------|
| Bootstrap config | `./platform/cli/ocp config bootstrap --env dev --user alice` | `make config-bootstrap ENV=dev U=alice` |
| Run diagnostics | `./platform/cli/ocp doctor --env dev --user alice` | `make doctor ENV=dev U=alice` |
| Validate config | `./platform/cli/ocp config validate --env dev --user alice` | `make config-validate ENV=dev U=alice` |
| Plan shared infra | `./platform/cli/ocp deploy shared --env dev --plan` | `make deploy-plan ENV=dev` |
| Apply shared infra | `./platform/cli/ocp deploy shared --env dev` | `make deploy ENV=dev` |
| Deploy user app | `./platform/cli/ocp deploy user --env dev --user alice` | `make add-user ENV=dev U=alice` |
| Remove user app | `./platform/cli/ocp user remove --env dev --user alice` | `make remove-user ENV=dev U=alice` |
| Signal deploy | `./platform/cli/ocp signal deploy --env dev` | `make signal-deploy ENV=dev` |
| Reset platform | `./platform/cli/ocp reset --env dev --nuke-only` | `make nuke-all ENV=dev` |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Resource Group (e.g. rg-openclaw-prod)                             │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  VNet (internal-only)                                         │  │
│  │  ┌─────────────────────────────────────────────────────────┐  │  │
│  │  │  Container Apps Environment                             │  │  │
│  │  │                                                         │  │  │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │  │  │
│  │  │  │ ca-openclaw-  │  │ ca-openclaw-  │  │ ca-graph-    │  │  │  │
│  │  │  │ <env>-alice   │  │ <env>-bob     │  │ mcp-gw-      │  │  │  │
│  │  │  │              │  │              │  │ <env>-alice   │  │  │  │
│  │  │  └──────┬───────┘  └──────────────┘  └──────────────┘  │  │  │
│  │  │         │                                               │  │  │
│  │  │         │ (Signal messages via internal ingress)        │  │  │
│  │  │         │                                               │  │  │
│  │  │  ┌──────┴───────┐  ┌──────────────┐                    │  │  │
│  │  │  │ signal-proxy  │──│ signal-cli   │──── Signal Network │  │  │
│  │  │  │ (Go router)  │  │ (daemon)     │                    │  │  │
│  │  │  └──────────────┘  └──────────────┘                    │  │  │
│  │  └─────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌────────────┐  ┌────────────┐  ┌─────────────┐                   │
│  │ ACR        │  │ Key Vault  │  │ NFS Storage │                   │
│  │ (images)   │  │ (secrets)  │  │ (user data) │                   │
│  └────────────┘  └────────────┘  └─────────────┘                   │
└─────────────────────────────────────────────────────────────────────┘
```

**Key principles:**

- One shared resource group per environment with VNet, ACR, Key Vault, NFS storage
- Each user gets an isolated Container App with their own managed identity
- Per-user identity handles both ACR pull and per-secret Key Vault RBAC (no shared identity needed)
- All secrets stored in Key Vault, injected at runtime via managed identity
- Internal-only networking -- no public endpoints on container apps
- Golden image pattern -- upstream OpenClaw wrapped with enterprise config and boot-time patching
- NFS volume provides persistent per-user storage across container restarts

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) >= 2.50
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- An Azure subscription with Owner or Contributor + User Access Administrator roles
- Docker (only needed for local testing; ACR Tasks builds remotely)

## Environment Configuration

The project uses a **layered config model** under `config/` and loads files directly.

```bash
# 1. Bootstrap layered config for one user
./platform/cli/ocp config bootstrap --env dev --user alice

# 2. Edit sources of truth
# - config/env/dev.env
# - config/users/alice.env
# - config/local/dev.env (optional)
# - config/local/dev.alice.env (optional)

# 3. Validate
./platform/cli/ocp config validate --env dev --user alice
```

Load order remains shared first, then per-user override:

- `config/env/<env>.env`
- `config/local/<env>.env` (optional)
- `config/users/<slug>.env` (optional)
- `config/local/<env>.<slug>.env` (optional)

`config/local/` is optional. Use it only for machine-specific or unshared overrides.
It is not required for Docker local runs.

### Variable Reference — Shared Config

| Variable | Description | Default (dev) | Override needed for prod? |
|----------|-------------|---------------|--------------------------|
| `AZURE_LOCATION` | Azure region | `eastus` | Likely (e.g. `uaenorth`) |
| `AZURE_RESOURCE_GROUP` | Resource group name | `rg-openclaw-<env>` | If naming differs |
| `AZURE_CONTAINERAPPS_ENV` | CAE name | `cae-openclaw-<env>` | If naming differs |
| `AZURE_ACR_NAME` | Container registry | `openclaw<env>acr` | If naming differs |
| `AZURE_KEY_VAULT_NAME` | Key Vault name | `kvopenclaw<env>` | If naming differs |
| `NFS_SA_NAME` | NFS storage account | `nfsopenclaw<env>` | If naming differs |
| `CAE_NFS_STORAGE_NAME` | CAE storage mount name | `openclaw-nfs-<env>` | If naming differs |
| `IMAGE_TAG` | Golden image tag | `latest` | Optional |
| `COMPASS_BASE_URL` | LLM provider base URL | `https://api.core42.ai/v1` | If provider differs |
| `COMPASS_API_KEY` | LLM provider API key | -- | Yes (secret) |
| `OPENCLAW_GATEWAY_AUTH_TOKEN` | Gateway auth token | -- | Yes (secret) |
| `SIGNAL_BOT_NUMBER` | Signal bot phone (E.164) | -- | If using Signal |
| `SIGNAL_PROXY_AUTH_TOKEN` | Signal proxy auth token | -- | If using Signal |
| `SIGNAL_CLI_URL` | Signal proxy FQDN | Auto-discovered from TF | Manual for prod |

### Variable Reference — Per-User Config

| Variable | Description | Required? |
|----------|-------------|-----------|
| `SIGNAL_USER_PHONE` | User's Signal phone (E.164) | If using Signal |
| `COMPASS_API_KEY` | Override shared API key for this user | No |
| `OPENCLAW_GATEWAY_AUTH_TOKEN` | Override shared gateway token for this user | No |

### Makefile Short Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `ENV` | Environment label | `./platform/cli/ocp deploy shared --env prod` |
| `U` | User slug | `./platform/cli/ocp deploy user --env dev --user alice` |

### Naming Conventions

| Resource | Pattern | Example (prod) |
|----------|---------|----------------|
| Resource Group | `rg-openclaw-<env>` | `rg-openclaw-prod` |
| Container Apps Env | `cae-openclaw-<env>` | `cae-openclaw-prod` |
| User Container App | `ca-openclaw-<env>-<user>` | `ca-openclaw-prod-alice` |
| User Identity | `id-openclaw-<env>-<user>` | `id-openclaw-prod-alice` |
| Graph MCP Gateway | `ca-graph-mcp-gw-<env>-<user>` | `ca-graph-mcp-gw-prod-alice` |
| Signal CLI | `ca-signal-cli-<env>` | `ca-signal-cli-prod` |
| Signal Proxy | `ca-signal-proxy-<env>` | `ca-signal-proxy-prod` |
| Key Vault | `kvopenclaw<env>` or custom | `kvopenclawprod` |
| ACR | `openclaw<env>acr` or custom | `openclawprodacr` |

Dev environments use derived defaults. Production environments with externally provisioned resources override names in `config/env/prod.env` and local secret overlays.

Run `make naming-check ENV=<env>` before deploy/destroy operations to validate naming consistency.

Use `ocp` as the primary operator interface and keep `make` as compatibility aliases.
See `README.md:12` for the quick command map and `README.md:763` for the full alias table.

---

## Quick Start -- Dev Environment (Full Terraform)

If you are starting from scratch in a dev subscription where you control all resources:

### 1. Configure Environment

```bash
# Bootstrap layered config
./platform/cli/ocp config bootstrap --env dev --user alice
```

### 2. Bootstrap Shared Infrastructure

```bash
# Preview
./platform/cli/ocp deploy shared --env dev --plan

# Apply (creates RG, VNet, CAE, ACR, KV, NFS storage, Log Analytics)
./platform/cli/ocp deploy shared --env dev
```

### 3. Build the Golden Image

```bash
make build-image
```

### 4. Deploy a User

```bash
./platform/cli/ocp deploy user --env dev --user alice
```

`ocp deploy user` auto-discovers the Graph MCP gateway URL, opens firewalls temporarily for Terraform, deploys the container app, then closes firewalls.

### 5. (Optional) Deploy Signal Messaging

```bash
# Set SIGNAL_BOT_NUMBER, SIGNAL_PROXY_AUTH_TOKEN in config/env/dev.env or config/local/dev.env
./platform/cli/ocp signal deploy --env dev

# Register the bot phone number (interactive shell)
./platform/cli/ocp signal register --env dev
```

### 6. Deploy Additional Users

Adding users is purely additive — create a per-user overlay and deploy:

```bash
cp config/users/user.example.env config/users/bob.env
# Edit config/users/bob.env — set SIGNAL_USER_PHONE, optional API key overrides

./platform/cli/ocp config validate --env dev --user bob

./platform/cli/ocp deploy user --env dev --user bob
```

---

## Deploying to Production (Pre-provisioned Infrastructure)

In many organizations, shared infrastructure (resource groups, VNets, storage, etc.) is provisioned by a platform team or via separate tooling. The user-app Terraform module is designed for this -- it looks up shared resources by name via `data` sources rather than depending on Terraform remote state.

### What You Need Ready

Before deploying user containers, ensure these shared resources exist:

| Resource | Purpose |
|----------|---------|
| Resource Group | Contains all OpenClaw resources |
| VNet + Subnet | Internal networking for CAE |
| Container Apps Environment | Hosts all container apps (internal LB) |
| Azure Container Registry | Stores golden and proxy images |
| Key Vault | Stores per-user secrets (RBAC authorization mode) |
| NFS Storage Account + File Share | Persistent per-user data (Premium FileStorage) |
| CAE Storage Mount | NFS share registered as `NfsAzureFile` in the CAE |
| Log Analytics Workspace | Container logs and diagnostics |

These can be provisioned via `ocp deploy shared` (dev), ARM/Bicep templates, `az` CLI, Azure Portal, or any IaC tool.

### Step 1: Create Production Config

```bash
cp config/env/dev.env config/env/prod.env
```

Edit `config/env/prod.env` with your resource name overrides:

```bash
AZURE_ENVIRONMENT=prod
AZURE_LOCATION=uaenorth

# Override shared resource names to match your pre-provisioned infra
AZURE_RESOURCE_GROUP=rg-openclaw-prod
AZURE_CONTAINERAPPS_ENV=cae-openclaw-prod
AZURE_ACR_NAME=openclawprodacr
AZURE_KEY_VAULT_NAME=kvopenclawprod
NFS_SA_NAME=openclawprodst
CAE_NFS_STORAGE_NAME=openclaw-nfs-prod

# Shared secrets (defaults for all users — can be overridden per-user)
COMPASS_BASE_URL=https://api.core42.ai/v1
COMPASS_API_KEY=your-api-key-here
OPENCLAW_GATEWAY_AUTH_TOKEN=your-gateway-token-here
```

Then create per-user overlay files:

```bash
cp config/users/user.example.env config/users/alice.env
# Edit config/users/alice.env — set SIGNAL_USER_PHONE, optional API key overrides

./platform/cli/ocp config validate --env prod --user alice
```

### Step 2: Build and Push the Golden Image

The golden image is built remotely via ACR Tasks (no local Docker required):

```bash
make build-image ENV=prod
```

Verify deterministic runtime config assembly:

```bash
make config-determinism-check
```

If your ACR has network rules, the Makefile temporarily opens the firewall for the build.

### Step 3: Deploy the Graph MCP Gateway

The Graph MCP gateway (`ca-graph-mcp-gw-<env>-<user>`) provides Microsoft 365 integration (calendar, email, contacts via Microsoft Graph API). It is deployed separately from the user-app Terraform module.

**Deploy the gateway container:**

```bash
# Get the CAE default domain for internal FQDNs
CAE_DOMAIN=$(az containerapp env show -n cae-openclaw-prod -g rg-openclaw-prod \
  --query "properties.defaultDomain" -o tsv)

az containerapp create \
  --name ca-graph-mcp-gw-prod-alice \
  --resource-group rg-openclaw-prod \
  --environment cae-openclaw-prod \
  --image <acr>.azurecr.io/graph-mcp-gw:latest \
  --cpu 0.25 --memory 0.5Gi \
  --min-replicas 1 --max-replicas 1 \
  --ingress internal --target-port 3000 \
  --env-vars \
    "TENANT_ID=<your-azure-ad-tenant-id>" \
    "CLIENT_ID=<your-app-registration-client-id>" \
    "PORT=3000"
```

Then ensure the gateway has an NFS-backed token cache for persistence (via Terraform/AzAPI if managed in IaC, or a one-time ARM/CLI patch if managed manually).

**Verify the gateway:**

```bash
GW_FQDN="ca-graph-mcp-gw-prod-alice.internal.${CAE_DOMAIN}"

# Health check (from within the VNet or another container)
curl -s "http://${GW_FQDN}/health"

# Auth status — shows whether a Microsoft token is cached
curl -s "http://${GW_FQDN}/auth/status"
```

**First-time Microsoft auth:** The gateway uses the device-code flow. On first start, check the gateway logs for a URL and code. Open the URL in a browser, enter the code, and sign in with your Microsoft account. The token is cached on the NFS volume and survives restarts.

The user-app deployment auto-discovers the gateway FQDN at deploy time and injects it as `GRAPH_MCP_URL`.

### Step 4: Deploy the User Container App

```bash
# Dry run
./platform/cli/ocp deploy user --env prod --user alice --plan

# Deploy
./platform/cli/ocp deploy user --env prod --user alice
```

What this does:

1. Auto-discovers the Graph MCP gateway FQDN for the user
2. Temporarily opens NFS storage and Key Vault firewalls for Terraform
3. Creates a per-user managed identity with ACR pull + per-secret KV RBAC
4. Stores secrets in Key Vault (Compass API key, gateway token, MCP URL)
5. Creates the Container App with startup/liveness probes
6. Applies NFS volume + mount updates via Terraform AzAPI resources (provider-native `azapi_resource`/`azapi_update_resource` flow)
7. Closes firewalls

### Step 5: Verify

```bash
# Check container status
az containerapp show -n ca-openclaw-prod-alice -g rg-openclaw-prod \
  --query "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName}" \
  -o table

# Tail logs
az containerapp logs show -n ca-openclaw-prod-alice -g rg-openclaw-prod --tail 50
```

You should see in the logs:

```
Patched Compass provider (baseUrl=https://api.core42.ai/v1) in /app/data/alice/.openclaw/openclaw.json
[gateway] agent model: compass/gpt-5.1
[gateway] listening on ws://0.0.0.0:18789 (PID ...)
```

### Terraform State

The user-app module uses `backend "local" {}` by default. This is the recommended approach when Azure org policies block `publicNetworkAccess` on storage accounts (making remote state backends unreachable from local machines).

Each user gets a separate Terraform workspace:

```bash
# Workspaces are managed automatically by `ocp deploy user`
terraform -chdir=infra/user-app workspace list
```

If your environment supports remote state, override the backend at init time:

```bash
terraform -chdir=infra/user-app init \
  -backend-config="resource_group_name=rg-terraform-state" \
  -backend-config="storage_account_name=stterraformstate" \
  -reconfigure
```

---

## Signal Messaging Stack

Signal provides a secure messaging channel for interacting with the OpenClaw agent from a phone. The stack consists of three components:

```
Phone (Signal app)
  │
  ▼
signal-cli (daemon)          Container: ca-signal-cli-<env>
  │  - Bridges Signal network to HTTP API
  │  - NFS mount at /signal-data/signal-cli (registration state)
  │  - Port 8080, 1 replica, internal ingress only
  │  - Public image: ghcr.io/asamk/signal-cli
  │
  ▼
signal-proxy (Go router)     Container: ca-signal-proxy-<env>
  │  - Routes messages to the correct user container by phone number
  │  - Auth token verification per request
  │  - SSE fan-out for real-time message delivery
  │  - ACR image: <acr>/signal-proxy:<tag>
  │  - Port 8080, internal ingress only
  │
  ▼
User container               Container: ca-openclaw-<env>-<user>
   - Receives messages via SSE from the proxy
   - Processes with AI agent (Compass LLM)
   - Sends replies back through the proxy → signal-cli → Signal network
```

The user container's `entrypoint.sh` assembles the full Signal HTTP URL from components:

```
SIGNAL_HTTP_URL = ${SIGNAL_CLI_URL}/user/${SIGNAL_USER_PHONE}/${SIGNAL_PROXY_AUTH_TOKEN}
```

### Deploying Signal (Dev -- via Terraform)

```bash
# Set Signal vars in config/env/dev.env or config/local/dev.env
# SIGNAL_BOT_NUMBER=+15551234567
# SIGNAL_PROXY_AUTH_TOKEN=<random-token>

make signal-build          # Build & push signal-proxy image to ACR
make signal-deploy         # Deploy signal-cli + signal-proxy via Terraform
```

### Deploying Signal (Prod -- via az CLI)

When shared infrastructure has no Terraform state (provisioned externally), deploy Signal containers directly with `az` CLI or the REST API.

**1. Build and push the signal-proxy image:**

```bash
make signal-build ENV=prod
```

**2. Deploy signal-cli:**

```bash
az containerapp create \
  --name ca-signal-cli-prod \
  --resource-group rg-openclaw-prod \
  --environment cae-openclaw-prod \
  --image ghcr.io/asamk/signal-cli:latest \
  --cpu 0.5 --memory 1Gi \
  --min-replicas 1 --max-replicas 1 \
  --ingress internal --target-port 8080 \
  --args "--config" "/signal-data/signal-cli" "daemon" "--receive-mode" "on-connection" "--no-receive-stdout" "--http" "0.0.0.0:8080"
```

Then apply the NFS volume/mount update for `/signal-data` via Terraform AzAPI resources (or an equivalent ARM patch flow if deploying manually).

**3. Deploy signal-proxy:**

```bash
az containerapp create \
  --name ca-signal-proxy-prod \
  --resource-group rg-openclaw-prod \
  --environment cae-openclaw-prod \
  --image <acr>.azurecr.io/signal-proxy:latest \
  --cpu 0.25 --memory 0.5Gi \
  --min-replicas 1 --max-replicas 1 \
  --ingress internal --target-port 8080 \
  --env-vars \
    "SIGNAL_CLI_URL=http://ca-signal-cli-prod.internal.<cae-domain>" \
    "AUTH_TOKEN=<your-proxy-auth-token>"
```

> **Note:** `SIGNAL_KNOWN_PHONES` is managed automatically by `ocp signal update-phones`,
> which runs after `ocp deploy user`, `ocp user remove`, and `ocp signal deploy`
> (including their Makefile aliases). It collects
> `SIGNAL_USER_PHONE` from `config/users/*.env` plus the bot number.

**4. Set `SIGNAL_CLI_URL` in your prod shared config layer** (`config/env/prod.env` or `config/local/prod.env`) to point to the signal-proxy FQDN (not signal-cli directly):

```bash
SIGNAL_CLI_URL=http://ca-signal-proxy-prod.internal.<cae-default-domain>
```

### Registering the Signal Bot Number

Signal requires CAPTCHA verification for new number registrations:

1. Open `https://signalcaptchas.org/registration/generate` in a browser
2. Complete the CAPTCHA
3. Copy the `signalcaptcha://` token from the resulting page
4. Open a shell in the signal-cli container:

```bash
make signal-register ENV=prod
# Or directly:
az containerapp exec -n ca-signal-cli-prod -g rg-openclaw-prod --command /bin/sh
```

5. Register with the CAPTCHA token:

```bash
signal-cli --config /signal-data/signal-cli -a +YOUR_BOT_NUMBER register --captcha "signalcaptcha://..."
```

6. Enter the SMS verification code:

```bash
signal-cli --config /signal-data/signal-cli -a +YOUR_BOT_NUMBER verify CODE
```

The registration state is persisted on the NFS volume (`/signal-data/signal-cli`), so it survives container restarts.

### Signal Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Agent replies "Connection error." | LLM provider `baseUrl` misconfigured | Check `COMPASS_BASE_URL` env var; verify `openclaw.json` has the correct URL |
| No messages received | SSE connection dropped | Check signal-proxy logs; ensure signal-cli is running with 1 replica |
| `signal-cli spawn error: EACCES` | Harmless -- the app tries to run a local `signal-cli` binary | Ignore; messages flow through the HTTP proxy |
| Registration fails | CAPTCHA expired or wrong number format | Re-generate CAPTCHA; use E.164 format (`+` prefix) |

---

## Teams App Manifest and Packaging

Teams app metadata is environment-specific and generated from templates.

- Base template: `teams-app/base.manifest.json`
- Environment overlays:
  - `teams-app/env/dev.json`
  - `teams-app/env/stage.json`
  - `teams-app/env/prod.json`

Current policy:

- Single App ID across all environments.
- Environment identity is controlled by overlay content (`name`, `description`, `validDomains`, `version`).

Render and validate a single environment:

```bash
make teams-manifest ENV=dev
make teams-validate ENV=dev
```

Render all environments:

```bash
make teams-manifest-all
```

Build package zip for one environment:

```bash
make teams-package ENV=prod
```

Run the full local release gate in one command:

```bash
make teams-release-check
```

Output artifacts are written to `teams-app/dist/<env>/` and are git-ignored.

Release governance:

- Any overlay content change should include an explicit `version` bump in the same overlay file.
- `stage`/`prod` manifest changes should be reviewed using your internal approval process before publishing.
- Local release gate (run before every Teams package publish):

```bash
make teams-manifest-all
make teams-validate ENV=dev
make teams-validate ENV=stage
make teams-validate ENV=prod
make teams-package ENV=dev
make teams-package ENV=stage
make teams-package ENV=prod
```

- Optional integrity check (recommended):

```bash
sha256sum teams-app/dist/dev/openclaw-teams-dev.zip
sha256sum teams-app/dist/stage/openclaw-teams-stage.zip
sha256sum teams-app/dist/prod/openclaw-teams-prod.zip
```

---

## Golden Image

The golden image (`Dockerfile.wrapper`) wraps the upstream OpenClaw image with enterprise configuration:

```dockerfile
FROM ghcr.io/openclaw/openclaw@sha256:<digest>

# Install envsubst for config templating + nano for debugging
RUN apt-get update && apt-get install -y --no-install-recommends nano gettext-base

# Copy enterprise config template, workspace, and entrypoint
COPY openclaw.json.example /app/config/openclaw.json.example
COPY workspace/ /app/config/workspace/
COPY entrypoint.sh /app/entrypoint.sh
```

### What `entrypoint.sh` Does on Every Boot

1. **Per-user data isolation** -- Sets `DATA_ROOT=/app/data/<user_slug>` on the shared NFS volume
2. **Deterministic config build** -- Runs `scripts/build-openclaw-config.py` to assemble `openclaw.json` from `openclaw.json.example` with schema-safe validation
3. **Fail-fast validation** -- In Azure/user mode, requires at least one channel (`Signal` or `Microsoft Teams`) and rejects partial channel credentials
4. **Config checksum logging** -- Prints the runtime `openclaw.json` SHA-256 checksum for reproducibility checks across restarts
5. **Workspace template copy** -- Copies the baked-in workspace (skills, tools, identity docs) on first boot
6. **Workspace file templating** -- Re-runs `envsubst` on `AGENTS.md` and `SKILL.md` on every boot to resolve `${GRAPH_MCP_URL}` placeholders
7. **Legacy cleanup** -- Removes obsolete workspace directories and legacy tavily skill folders
8. **Starts the OpenClaw gateway** -- Binds to `0.0.0.0:18789` on the LAN interface

### Upgrading the Base Image

```bash
# 1. Update the FROM digest in Dockerfile.wrapper
# 2. Build and push
make build-image ENV=prod IMAGE_TAG=v2.0.0

# 3. Redeploy users (updates IMAGE_REF)
IMAGE_TAG=v2.0.0 ./platform/cli/ocp deploy user --env prod --user alice
```

> **Note:** When using `IMAGE_TAG=latest`, `ocp deploy user` may not trigger a new
> revision because Terraform sees no change in the image reference. Force it with:
>
> ```bash
> az containerapp update -n ca-openclaw-prod-alice -g rg-openclaw-prod \
>   --image openclawprodacr.azurecr.io/openclaw-golden:latest \
>   --revision-suffix "$(date +%s)"
> ```
>
> Alternatively, use unique image tags (e.g., `v2.0.1`) to avoid this issue entirely.

### Rolling Back

```bash
IMAGE_TAG=v1.0.0 ./platform/cli/ocp deploy user --env prod --user alice
```

---

## Local Testing

Run the golden image locally with Docker Compose:

```bash
# Set credentials in shell env
export COMPASS_API_KEY="sk-local-test"
export GRAPH_MCP_URL="http://host.docker.internal:5000"
export OPENCLAW_GATEWAY_AUTH_TOKEN="local-token"

make docker-up    # Build and start on http://localhost:18789
docker compose logs -f      # View logs
make docker-down  # Stop and remove volumes
```

If you keep local credentials in `config/local/dev.env`, you can load them first:

```bash
set -a; source config/local/dev.env; set +a
make docker-up
```

---

## Security Model

### Secrets Management

- All secrets stored in Azure Key Vault with RBAC authorization enabled
- Each user's managed identity gets `Key Vault Secrets User` scoped to their specific secrets only (not vault-wide)
- Secrets have 1-year expiration dates (KICS compliance)
- No secrets are baked into the container image or stored in source control

### Identity & Access

- Each user gets a dedicated `azurerm_user_assigned_identity`
- The identity is granted `AcrPull` on the shared ACR
- Per-secret RBAC (not per-vault) ensures users can only read their own secrets
- No shared managed identity is needed

### Network Isolation

- Container Apps Environment uses `internal_load_balancer_enabled = true`
- All container app ingress is set to `external_enabled = false`
- No public IP addresses are allocated to containers
- Inter-app communication stays within the VNet
- Storage accounts and Key Vault use `default_action = Deny` with private endpoints

### Container Hardening

- Runs as non-root user (UID 1000)
- `cap_drop: ALL` and `no-new-privileges` in Docker Compose
- Startup and liveness probes configured
- Resource limits enforced (CPU/memory)

---

## Operator Commands

Use `ocp` as the primary interface. Keep `make` as a compatibility alias layer.

### Makefile Aliases

| Target | Description |
|--------|-------------|
| `make help` | List all available targets |
| **Local** | |
| `make docker-up` | Build and start locally via Docker Compose |
| `make docker-down` | Stop and remove local container and volumes |
| **Shared Infrastructure** | |
| `make deploy` | Provision shared infra (RG, VNet, CAE, ACR, KV, NFS) |
| `make deploy-plan` | Dry-run shared infra changes |
| `make deploy-destroy` | Tear down all shared infra (**DANGER**) |
| `make tf-bootstrap-state` | Provision remote TF state backend (run once) |
| `make hygiene-check` | Fail if forbidden tracked files (state/deps/secrets/build outputs) are committed |
| `make config-bootstrap [U=x]` | Create missing config files from templates |
| `make config-audit [U=x]` | Print expected config paths and warn on deprecated root env files |
| `make config-validate [U=x]` | Validate env files against typed schema (`config/schema.json`) |
| **Golden Image** | |
| `make build-image` | Build and push golden image via ACR Tasks |
| `make show-image` | Print the full image reference |
| `make acr-login` | Authenticate Docker to ACR |
| **Signal Stack** | |
| `make signal-build` | Build and push signal-proxy image to ACR |
| `make signal-deploy` | Deploy full Signal stack (build + Terraform) |
| `make signal-plan` | Dry-run Signal deployment |
| `make signal-status` | Show status of signal-cli and signal-proxy containers |
| `make signal-register` | Open shell in signal-cli for phone registration |
| `make signal-logs-cli` | Tail signal-cli logs |
| `make signal-logs-proxy` | Tail signal-proxy logs |
| `make signal-update-phones` | Sync `SIGNAL_KNOWN_PHONES` on signal-proxy from `config/users/*.env` |
| **Per-User Deployment** | |
| `make add-user U=x` | Deploy a user's Container App |
| `make add-user-plan U=x` | Dry-run user deployment |
| `make remove-user U=x` | Destroy a user's Container App |
| `make import-user U=x R=<addr> ID=<id>` | Import existing Azure resource into user TF state |
| `make status [U=x]` | Show container status (all or specific user) |
| `make logs U=x` | Tail user's container logs |
| **Lifecycle** | |
| `make deploy-all U=x` | 1-click: shared infra + image + Signal + user app |
| `make nuke-all` | Destroy ALL users + shared infra (**DANGER**) |
| `make rebuild-all` | Rebuild shared infra + ALL users from `config/users/*.env` |
| `make full-rebuild` | Full nuke then rebuild (**DANGER**) |

All targets accept `ENV=<env>` to target a specific environment. Per-user targets require `U=<slug>`.

### Repository Hygiene (Local Guardrail)

Run this before committing:

```bash
make hygiene-check
```

It fails if forbidden tracked files are present (for example: `.terraform/`, `*.tfstate*`, `node_modules/`, local `.env.*` files, private keys, and generated dist outputs).

### Config Validation (Typed Schema)

Validate env files against the typed contract in `config/schema.json`:

```bash
make config-validate ENV=dev
make config-validate ENV=dev U=alice
```

Validation runs against layered files directly.

### Config Templates Policy

Only `*.example.env` under `config/` should be committed.
All runtime `*.env` files contain confidential data and must remain local.

### Platform Reset

Use `ocp reset` for full nuke-and-rebuild across ALL users. It discovers users from `config/users/*.env` automatically — no `--user` flag needed.

Preferred guide: `docs/runbooks/platform-reset.md`.

```bash
./platform/cli/ocp reset --env dev
./platform/cli/ocp reset --env prod
./platform/cli/ocp reset --env dev --force
./platform/cli/ocp reset --env dev --nuke-only
./platform/cli/ocp reset --env dev --rebuild-only
./platform/cli/ocp reset --env prod --force
```

Makefile aliases:

```bash
make nuke-all                          # Destroy all users + shared infra
make rebuild-all                       # Rebuild everything
make full-rebuild                      # Nuke + rebuild end-to-end
make nuke-all ENV=prod                 # Target prod
```

Production destructive guardrails:

```bash
ALLOW_PROD_DESTRUCTIVE=true \
BREAK_GLASS_TICKET=INC-12345 \
make nuke-all ENV=prod
```

- Prod destructive operations require both `ALLOW_PROD_DESTRUCTIVE=true` and `BREAK_GLASS_TICKET`.
- `BREAK_GLASS_TICKET` must match `INC-<number>` or `CHG-<number>`.
- In protected CI branch/runner contexts, `ocp reset` also requires `ALLOW_PROTECTED_DESTRUCTIVE=true`.

---

## File Structure

```
.
├── Makefile                     # Orchestration entry point
├── README.md                    # This file
├── docs/
│   ├── README.md                # Documentation index
│   ├── onboarding/
│   │   └── quickstart.md        # First-time setup path
│   └── runbooks/
│       ├── day-2-operations.md  # Standard operational commands
│       └── platform-reset.md    # Canonical reset command flow
├── REBUILD.md                   # Nuke & rebuild playbook
├── Dockerfile.wrapper           # Golden image (wraps upstream OpenClaw)
├── docker-compose.yml           # Local testing
├── entrypoint.sh                # Container entrypoint (config patching, boot logic)
├── openclaw.json.example        # Enterprise config template (${VAR} placeholders)
├── platform-reset.sh            # Internal reset engine used by `ocp reset`
├── .gitignore
├── config/
│   ├── schema.json              # Typed env schema used by config validation
│   ├── env/                     # Shared env files (only *.example.env committed)
│   ├── users/                   # Per-user env files (only *.example.env committed)
│   └── local/                   # Optional local overrides (only *.example.env committed)
├── scripts/validate-config.py   # Schema validator for env files
├── teams-app/                   # Teams app template overlays + packaging scripts
│   ├── base.manifest.json
│   ├── env/
│   │   ├── dev.json
│   │   ├── stage.json
│   │   └── prod.json
│   ├── render-manifest.mjs
│   ├── check-manifest.mjs
│   ├── package-teams-app.sh
│   ├── manifest.json            # Dev compatibility manifest (rendered from templates)
│   ├── color.png
│   └── outline.png
│
├── infra/
│   ├── bootstrap-state.sh       # Provision remote TF state backend (optional)
│   ├── shared/                  # Shared infrastructure Terraform root
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── import.sh            # Import pre-existing resources into TF state
│   └── user-app/                # Per-user Container App Terraform root
│       ├── providers.tf         # Local backend (see Terraform State section)
│       ├── variables.tf
│       ├── main.tf              # Identity, KV secrets, RBAC, Container App, NFS patch
│       └── outputs.tf
│
├── signal-proxy/                # Signal routing proxy (Go)
│   ├── main.go                  # Phone-based routing, SSE fan-out, auth
│   ├── Dockerfile
│   └── go.mod
│
└── workspace/                   # Baked into golden image, copied to NFS on first boot
    ├── SOUL.md                  # Agent personality / system prompt
    ├── IDENTITY.md              # Agent identity config
    ├── TOOLS.md                 # Available tools reference
    ├── AGENTS.md                # Core rules + M365 gateway instructions (loaded every request)
    ├── BOOTSTRAP.md             # First-boot instructions
    ├── HEARTBEAT.md             # Periodic health check config
    ├── instructions/            # Per-agent instruction files (envsubst-templated on boot)
    └── skills/                  # Agent skills (M365 gateway, search, etc.)
        ├── m365-graph-gateway/
        ├── prototype-webapp/
        └── self-improving-agent/
```

---

## Known Limitations

| Limitation | Details | Workaround |
|------------|---------|------------|
| NFS volume mount requires AzAPI resources | The `azurerm` Terraform provider only supports `AzureFile` storage type, not `NfsAzureFile` | Use Terraform AzAPI resources (`azapi_resource` for CAE storages and `azapi_update_resource` for Container Apps template patching). |
| NFS storage firewall blocks Terraform | When `default_action = Deny`, Terraform cannot manage file shares (403) | The Makefile temporarily sets `--default-action Allow`, performs the operation, then restores `Deny`. |
| ACR Tasks agents have unpredictable IPs | Network rules on ACR don't help for build agents | The Makefile temporarily allows all traffic during builds, then restores the deny rule. |
| Azure org policy may block remote TF state | `publicNetworkAccess: Disabled` on storage accounts makes remote backends unreachable | Use `backend "local" {}` (the default in this repo). |
| Dual egress IPs from deployer machines | Different Azure services see different source IPs | The Makefile auto-detects both IPs via `ifconfig.me` and `api.ipify.org`. |
| Key Vault firewall propagation is slow | IP rule changes take 1-2+ minutes to take effect | The Makefile includes a 15-second wait after firewall changes. |
| OpenClaw does not support the `instructions` config key | Unlike OpenCode (the upstream project), OpenClaw's config schema does not recognize the `instructions` key. Adding it causes the config to be rejected with `Unrecognized key` and the gateway process exits (crash-loop). | Embed instructions directly into workspace markdown files (e.g., `AGENTS.md`) which are loaded on every request. The entrypoint includes a cleanup step to remove this key from existing configs. |
| Shell tool is named `bash`, not `exec` | OpenClaw exposes the shell tool as `bash`. Workspace files referencing `exec` will silently fail to trigger tool calls. | Audit all workspace files (`SOUL.md`, `SKILL.md`, skills/) when porting from OpenCode. Use `bash` in all tool-call examples and instructions. |
| Image rebuild with same tag doesn't trigger new revision | When using `IMAGE_TAG=latest`, Terraform sees no change in the image reference and won't create a new revision. The container keeps running the old image. | Use `az containerapp update --image <ref> --revision-suffix "$(date +%s)"` to force a new revision. Or use unique tags (e.g., `v2.0.1`) instead of `latest`. |

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `az acr build` fails with 403 | ACR firewall is blocking the build agent. The Makefile handles this automatically, but if building manually: `az acr update -n <acr> --default-action Allow`, build, then restore Deny. |
| Terraform 403 on NFS/KV operations | Firewall hasn't propagated. Wait 1-2 minutes after IP rule changes, or use the Makefile which adds a 15s delay. |
| Container app in `VolumeMountFailure` | Storage mount type is wrong. Verify: `az containerapp env storage show -n <cae> -g <rg> --storage-name <mount>` -- should be `NfsAzureFile`, not `AzureFile`. |
| Key Vault name conflict on rebuild | Check for soft-deleted vault: `az keyvault list-deleted`. Recover with `az keyvault recover` or purge with `az keyvault purge`. |
| `workload_profile_name` perpetual TF drift | Azure auto-populates this field. Already handled by `lifecycle { ignore_changes }`. |
| Agent responds "Connection error." | Compass provider `baseUrl` is wrong. Check `COMPASS_BASE_URL` env var, then tail container logs to confirm `Patched Compass provider (baseUrl=...)` appears at boot. |
| Deployer gets 403 on multiple services | You may have two outbound IPs. Check both `curl -s ifconfig.me` and `curl -s https://api.ipify.org`; the Makefile `DEPLOYER_IPS` handles this automatically. |
| `signal-cli spawn error: EACCES` in logs | Harmless. The OpenClaw app tries to run a local `signal-cli` binary (which doesn't exist in the golden image). Signal messages flow through the HTTP proxy and work fine. |
| `az containerapp exec` fails in scripts | Non-TTY contexts get `termios.error`. Use `az containerapp logs show` or Log Analytics queries instead. |
| Agent says "I'm not connected to your calendar" or ignores MCP tools | Three-layer failure chain: (1) Verify Compass `baseUrl` is correct -- check logs for `Patched Compass provider`; (2) Verify `GRAPH_MCP_URL` was resolved in workspace files -- check logs for `Resolving GRAPH_MCP_URL in AGENTS.md` and confirm no literal `${GRAPH_MCP_URL}` remains; (3) Verify M365 gateway instructions are in `AGENTS.md` (not in config `instructions` key) and the gateway is healthy: `curl -s http://<gw-fqdn>/health`. |
| Rebuilt image with `latest` tag but container runs old code | Terraform doesn't detect a new image when the tag is unchanged. Force a new revision: `az containerapp update -n <app> -g <rg> --image <ref> --revision-suffix "$(date +%s)"` |

---

## Observability

Container logs are collected in Log Analytics. Use KQL queries to inspect boot behavior, debug issues, and monitor health.

### Finding the Log Analytics Workspace ID

```bash
az monitor log-analytics workspace show \
  -n law-openclaw-prod -g rg-openclaw-prod \
  --query "customerId" -o tsv
```

### KQL Query Examples

**Recent logs for a user container (last 30 minutes):**

```kql
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == 'ca-openclaw-prod-alice'
| where TimeGenerated > ago(30m)
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

**Boot/entrypoint messages (verify patching steps ran):**

```kql
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == 'ca-openclaw-prod-alice'
| where Log_s has_any ("Patched Compass", "Resolving GRAPH_MCP_URL", "Removing unsupported", "listening on")
| project TimeGenerated, Log_s
| order by TimeGenerated desc
| take 20
```

**Error-level logs across all OpenClaw containers:**

```kql
ContainerAppConsoleLogs_CL
| where ContainerAppName_s startswith 'ca-openclaw-'
| where Log_s has_any ("error", "Error", "ERROR", "FATAL", "crash")
| project TimeGenerated, ContainerAppName_s, Log_s
| order by TimeGenerated desc
| take 50
```

### Running Queries from the CLI

```bash
az monitor log-analytics query \
  --workspace <workspace-customer-id> \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'ca-openclaw-prod-alice' | where TimeGenerated > ago(1h) | project TimeGenerated, Log_s | order by TimeGenerated desc | take 20" \
  -o table
```
