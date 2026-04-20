# OpenClaw Azure Platform

Shared-platform, per-user isolated deployment of [OpenClaw](https://github.com/openclaw/openclaw) on Azure Container Apps with optional Signal and Teams messaging.

## Start Here

| Guide | Path |
|-------|------|
| First-time setup | [`docs/onboarding/quickstart.md`](docs/onboarding/quickstart.md) |
| Production deployment | [`docs/runbooks/production-deploy.md`](docs/runbooks/production-deploy.md) |
| Container runtime | [`docs/architecture/container-runtime.md`](docs/architecture/container-runtime.md) |
| Teams relay & manifest | [`docs/architecture/teams-relay.md`](docs/architecture/teams-relay.md) |
| Signal messaging stack | [`docs/architecture/signal-stack.md`](docs/architecture/signal-stack.md) |
| Observability & KQL | [`docs/runbooks/observability.md`](docs/runbooks/observability.md) |
| Destructive reset flow | [`docs/runbooks/platform-reset.md`](docs/runbooks/platform-reset.md) |

## Operator Cheat Sheet

Use `ocp` as the primary interface. `make` remains a compatibility alias layer. Run `make help` for the full target list.

| Action | Preferred (`ocp`) | Make alias |
|--------|-------------------|------------|
| Bootstrap config | `./platform/cli/ocp config bootstrap --env dev --user alice` | `make config-bootstrap ENV=dev U=alice` |
| Run diagnostics | `./platform/cli/ocp doctor --env dev --user alice` | `make doctor ENV=dev U=alice` |
| Validate config | `./platform/cli/ocp config validate --env dev --user alice` | `make config-validate ENV=dev U=alice` |
| Plan shared infra | `./platform/cli/ocp deploy shared --env dev --plan` | `make deploy-plan ENV=dev` |
| Apply shared infra | `./platform/cli/ocp deploy shared --env dev` | `make deploy ENV=dev` |
| Deploy user app | `./platform/cli/ocp deploy user --env dev --user alice` | `make add-user ENV=dev U=alice` |
| Remove user app | `./platform/cli/ocp user remove --env dev --user alice` | `make remove-user ENV=dev U=alice` |
| Request-level usage (relay logs) | `./platform/cli/ocp usage --env prod --hours 24` | — |
| Message usage table (48h/7d/14d/30d) | `./platform/cli/ocp usage --env prod --source sessions` | — |
| Signal deploy | `./platform/cli/ocp signal deploy --env dev` | `make signal-deploy ENV=dev` |
| Check Graph auth identity | `./platform/cli/ocp graph auth-check --env prod --user alice --user bob` | — |
| Reset platform | `./platform/cli/ocp reset --env dev --nuke-only` | `make nuke-all ENV=dev` |

## Architecture

```
+---------------------------------------------------------------------------+
|  Resource Group (e.g. rg-openclaw-prod)                                   |
|                                                                           |
|  +---------------------------------------------------------------------+ |
|  |  VNet (internal-only)                                                | |
|  |  +----------------------------------------------------------------+ | |
|  |  |  Container Apps Environment                                     | | |
|  |  |                                                                 | | |
|  |  |  +----------------+  +----------------+  +------------------+   | | |
|  |  |  | ca-openclaw-   |  | ca-openclaw-   |  | ca-graph-mcp-gw- |  | | |
|  |  |  | <env>-alice    |  | <env>-bob      |  | <env>-alice      |  | | |
|  |  |  +-------+--------+  +----------------+  +------------------+   | | |
|  |  |          |                                                      | | |
|  |  |          | (Signal messages via internal ingress)               | | |
|  |  |          |                                                      | | |
|  |  |  +-------+--------+  +----------------+                        | | |
|  |  |  | signal-proxy   |--| signal-cli     |---- Signal Network     | | |
|  |  |  | (Go router)    |  | (daemon)       |                        | | |
|  |  |  +----------------+  +----------------+                        | | |
|  |  +----------------------------------------------------------------+ | |
|  +---------------------------------------------------------------------+ |
|                                                                           |
|  +--------------+  +--------------+  +---------------+                    |
|  | ACR          |  | Key Vault    |  | NFS Storage   |                    |
|  | (images)     |  | (secrets)    |  | (user data)   |                    |
|  +--------------+  +--------------+  +---------------+                    |
+---------------------------------------------------------------------------+
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

Load order (shared first, then per-user override):

1. `config/env/<env>.env`
2. `config/local/<env>.env` (optional)
3. `config/users/<slug>.env` (optional)
4. `config/local/<env>.<slug>.env` (optional)

`config/local/` is optional -- use it only for machine-specific or unshared overrides.

### Variable Reference -- Shared Config

| Variable | Description | Default (dev) | Override needed for prod? |
|----------|-------------|---------------|--------------------------|
| `AZURE_LOCATION` | Azure region | `eastus` | Likely |
| `AZURE_RESOURCE_GROUP` | Resource group name | `rg-openclaw-<env>` | If naming differs |
| `AZURE_CONTAINERAPPS_ENV` | CAE name | `cae-openclaw-<env>` | If naming differs |
| `AZURE_ACR_NAME` | Container registry | `openclaw<env>acr` | If naming differs |
| `AZURE_KEY_VAULT_NAME` | Key Vault name | `kvopenclaw<env>` | If naming differs |
| `NFS_SA_NAME` | NFS storage account | `nfsopenclaw<env>` | If naming differs |
| `CAE_NFS_STORAGE_NAME` | CAE storage mount name | `openclaw-nfs-<env>` | If naming differs |
| `IMAGE_TAG` | Golden image tag | `latest` | Optional |
| `COMPASS_BASE_URL` | LLM provider base URL | `https://api.core42.ai/v1` | If provider differs |
| `COMPASS_API_KEY` | LLM provider API key | -- | Yes (secret) |
| `SIGNAL_BOT_NUMBER` | Signal bot phone (E.164) | -- | If using Signal |
| `SIGNAL_PROXY_AUTH_TOKEN` | Signal proxy auth token | -- | If using Signal |
| `SIGNAL_CLI_URL` | Signal proxy FQDN | Auto-discovered from TF | Manual for prod |

### Teams Identity Registry

- Teams relay resolves per-user routing from Azure Table Storage (`userrouting`) using `activity.from.aadObjectId`.
- Routing records include `aad_object_id`, `user_slug`, `upstream_url`, `status`, and `updated_at`.
- Manage routing records with `ocp teams routing upsert|get|disable`.

### Variable Reference -- Per-User Config

| Variable | Description | Required? |
|----------|-------------|-----------|
| `SIGNAL_USER_PHONE` | User's Signal phone (E.164) | If using Signal |
| `COMPASS_API_KEY` | Override shared API key for this user | No |

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

Run `make naming-check ENV=<env>` before deploy/destroy operations to validate naming consistency.

## Teams App Manifest

Teams app metadata is environment-specific and generated from templates in `teams-app/`. See [`docs/architecture/teams-relay.md`](docs/architecture/teams-relay.md) for the full relay architecture.

```bash
./platform/cli/ocp teams manifest --env dev     # Render manifest
./platform/cli/ocp teams validate --env dev     # Validate manifest
./platform/cli/ocp teams package --env prod     # Build distributable zip
./platform/cli/ocp teams release-check          # Full local release gate
```

Output artifacts are written to `teams-app/dist/<env>/` (git-ignored). Overlay content changes should include an explicit `version` bump.

## Golden Image

The golden image (`Dockerfile.wrapper`) wraps the upstream OpenClaw image with enterprise configuration. See [`docs/architecture/container-runtime.md`](docs/architecture/container-runtime.md) for the full boot sequence and proxy architecture.

Upgrade: update the `FROM` digest in `Dockerfile.wrapper`, then `make build-image ENV=prod IMAGE_TAG=v2.0.0`.
Rollback: `IMAGE_TAG=v1.0.0 ./platform/cli/ocp deploy user --env prod --user alice`.

## Local Testing

```bash
export COMPASS_API_KEY="sk-local-test"
export GRAPH_MCP_URL="http://host.docker.internal:5000"
export OPENCLAW_BOARDS="fertility,strategic-health"

make docker-up        # Build and start on http://localhost:18789
docker compose logs -f
make docker-down      # Stop and remove volumes
```

Board mode notes:

- Board workspaces and base board-routing rules are refreshed on every boot.
- Per-user feature manifests are the primary source of truth for enabled boards.
- `OPENCLAW_BOARDS` is still supported as a local fallback when no explicit board list is present in features.
- For local Docker runs without a user feature manifest, set `OPENCLAW_BOARDS` explicitly, for example `fertility,strategic-health`.
- The base `.openclaw/workspace` remains the default user-facing workspace; board chairmen and members are additional agents the user can explicitly invoke.
- Formal "convene the board" requests in Control UI now route through the deterministic board-meeting runner, so the chairman returns packets based on named member-agent participation instead of free-form simulation.
- If a user asks for a formal board decision without naming a board, the base assistant should ask: `Which board?`

Per-user capability policy:

- Use `config/users/<slug>.features.json` to control non-secret per-user capabilities.
- Feature manifests can select:
  - enabled boards
  - allowed skills for base workspace, chairman, and members
  - enabled/disabled plugins
- `profiles` are supported and load reusable overlays from `config/features/profiles/*.json`.
- Keep secrets and channel credentials in `config/users/<slug>.env`.
- The deploy/runtime path can inject the merged per-user feature manifest via `OPENCLAW_FEATURES_JSON` without rebuilding the image.

## Security Model

### Secrets Management

- All secrets stored in Azure Key Vault with RBAC authorization enabled
- Each user's managed identity gets `Key Vault Secrets User` scoped to their specific secrets only
- Secrets have 1-year expiration dates (KICS compliance)
- No secrets are baked into the container image or stored in source control

### Identity & Access

- Each user gets a dedicated `azurerm_user_assigned_identity`
- The identity is granted `AcrPull` on the shared ACR
- Per-secret RBAC (not per-vault) ensures users can only read their own secrets

### Network Isolation

- Container Apps Environment uses `internal_load_balancer_enabled = true`
- All container app ingress is set to `external_enabled = false`
- No public IP addresses are allocated to containers
- Storage accounts and Key Vault use `default_action = Deny` with private endpoints

### Container Hardening

- Runs as non-root user (UID 1000)
- `cap_drop: ALL` and `no-new-privileges` in Docker Compose
- Startup and liveness probes configured
- Resource limits enforced (CPU/memory)

## Known Limitations

| Limitation | Details | Workaround |
|------------|---------|------------|
| NFS volume mount requires AzAPI resources | `azurerm` provider only supports `AzureFile`, not `NfsAzureFile` | Use Terraform AzAPI resources |
| NFS storage firewall blocks Terraform | `default_action = Deny` causes 403 | Makefile temporarily opens firewall during operations |
| ACR Tasks agents have unpredictable IPs | Network rules on ACR don't help for build agents | Makefile temporarily allows all traffic during builds |
| Azure org policy may block remote TF state | `publicNetworkAccess: Disabled` on storage accounts | Use `backend "local" {}` (the default) |
| Dual egress IPs from deployer machines | Different Azure services see different source IPs | Makefile auto-detects both IPs |
| Key Vault firewall propagation is slow | IP rule changes take 1-2+ minutes | Makefile includes a 15-second wait |
| OpenClaw ignores `instructions` config key | Unlike OpenCode, adding it causes a crash-loop | Embed instructions in workspace markdown files |
| Shell tool is named `bash`, not `exec` | Workspace files referencing `exec` silently fail | Use `bash` in all tool-call examples |
| Same image tag doesn't trigger new revision | Terraform sees no change in the image reference | Use unique tags or force with `--revision-suffix` |

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `az acr build` fails with 403 | ACR firewall blocking build agent. Makefile handles automatically; manually: `az acr update -n <acr> --default-action Allow`, build, restore Deny. |
| Terraform 403 on NFS/KV | Firewall propagation delay. Wait 1-2 min after IP rule changes. |
| `VolumeMountFailure` | Storage mount type wrong. Verify `NfsAzureFile` (not `AzureFile`) via `az containerapp env storage show`. |
| Key Vault name conflict on rebuild | Soft-deleted vault. `az keyvault list-deleted`, then `recover` or `purge`. |
| Agent responds "Connection error." | Check `COMPASS_BASE_URL`; tail logs for `Patched Compass provider`. |
| `signal-cli spawn error: EACCES` | Harmless. Signal messages flow through the HTTP proxy. |
| Agent ignores MCP tools | Three-layer check: (1) Compass `baseUrl`, (2) `GRAPH_MCP_URL` resolved in workspace files, (3) gateway health. |
| Board mode did not render agents | Check the effective feature manifest for the user first. For local fallback mode, verify `OPENCLAW_BOARDS` is set and `config/boards/<board>.json` exists; then rebuild or restart the container. |
| Rebuilt image but old code runs | Force new revision: `az containerapp update --image <ref> --revision-suffix "$(date +%s)"`. |

## File Structure

```
.
+-- Makefile                     # Orchestration entry point
+-- README.md                    # This file
+-- docs/
|   +-- README.md                # Documentation index
|   +-- onboarding/
|   |   +-- quickstart.md        # First-time setup path
|   +-- architecture/
|   |   +-- container-runtime.md # Boot sequence, proxy, golden image
|   |   +-- teams-relay.md       # Teams relay + manifest system
|   |   +-- signal-stack.md      # Signal messaging architecture
|   +-- runbooks/
|       +-- production-deploy.md # Production deployment guide
|       +-- observability.md     # KQL queries and log analytics
|       +-- platform-reset.md   # Canonical reset command flow
+-- Dockerfile.wrapper           # Golden image (wraps upstream OpenClaw)
+-- docker-compose.yml           # Local testing
+-- entrypoint.sh                # Container entrypoint (config patching, boot logic)
+-- loopback-proxy.mjs           # HTTP/WS proxy (Teams + OpenClaw in single container)
+-- platform-reset.sh            # Internal reset engine used by `ocp reset`
+-- config/
|   +-- schema.json              # Typed env schema for config validation
|   +-- openclaw.json.template   # Enterprise config template (${VAR} placeholders)
|   +-- env/                     # Shared env files (only *.example.env committed)
|   +-- users/                   # Per-user env files (only *.example.env committed)
|   +-- local/                   # Optional local overrides (only *.example.env committed)
+-- scripts/
|   +-- validate-config.py       # Schema validator for env files
|   +-- check-config-determinism.sh
+-- teams-app/                   # Teams app template overlays + packaging scripts
+-- teams-relay/                 # Azure Function relay for Teams webhook
+-- infra/
|   +-- shared/                  # Shared infrastructure Terraform root
|   +-- user-app/                # Per-user Container App Terraform root
+-- signal-proxy/                # Signal routing proxy (Go)
+-- platform/
|   +-- cli/ocp                  # Primary operator CLI
|   +-- scripts/                 # Deploy/signal/teams automation scripts
|       +-- common.py            # Shared helper functions
+-- workspace/                   # Baked into golden image, copied to NFS on first boot
```
