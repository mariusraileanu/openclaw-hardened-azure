# Production Deployment Guide

Deploying OpenClaw to a production environment where shared infrastructure (resource groups, VNets, storage, etc.) is pre-provisioned by a platform team or separate tooling.

The user-app Terraform module looks up shared resources by name via `data` sources rather than depending on Terraform remote state.

## Prerequisites (Shared Resources)

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

## Step 1: Create Production Config

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

# Shared secrets (defaults for all users -- can be overridden per-user)
COMPASS_BASE_URL=https://api.core42.ai/v1
COMPASS_API_KEY=your-api-key-here
```

Then create per-user overlay files:

```bash
cp config/users/user.example.env config/users/alice.env
# Edit config/users/alice.env -- set SIGNAL_USER_PHONE, optional API key overrides

./platform/cli/ocp config validate --env prod --user alice
```

## Step 2: Build and Push the Golden Image

The golden image is built remotely via ACR Tasks (no local Docker required):

```bash
make build-image ENV=prod
```

Verify deterministic runtime config assembly:

```bash
make config-determinism-check
```

If your ACR has network rules, the Makefile temporarily opens the firewall for the build.

## Step 3: Deploy the Graph MCP Gateway

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

# Auth status -- shows whether a Microsoft token is cached
curl -s "http://${GW_FQDN}/auth/status"
```

**First-time Microsoft auth:** The gateway uses the device-code flow. On first start, check the gateway logs for a URL and code. Open the URL in a browser, enter the code, and sign in with your Microsoft account. The token is cached on the NFS volume and survives restarts.

**Post-auth identity guard check (recommended):**

```bash
# Verify gateway auth identity for one or more users
./platform/cli/ocp graph auth-check --env prod --user alice --user bob
```

Expected outcomes:

- `PASS` -> authenticated and resolved Entra object ID matches Key Vault secret `<slug>-entra-object-id`.
- `WARN_LOGIN_REQUIRED` -> gateway is healthy but user has not completed device-code auth yet.
- `FAIL_MISMATCH` -> cached token belongs to a different user; clear token cache in the graph-gateway deployment and re-auth.

The user-app deployment auto-discovers the gateway FQDN at deploy time and injects it as `GRAPH_MCP_URL`.

## Step 4: Deploy the User Container App

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
4. Stores secrets in Key Vault (Compass API key, MCP URL)
5. Creates the Container App with startup/liveness probes
6. Applies NFS volume + mount updates via Terraform AzAPI resources
7. Closes firewalls

## Step 5: Verify

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

## Terraform State

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

## Upgrading the Base Image

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

## Rolling Back

```bash
IMAGE_TAG=v1.0.0 ./platform/cli/ocp deploy user --env prod --user alice
```
