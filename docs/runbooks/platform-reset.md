# Platform Reset Runbook

Complete teardown and rebuild of the OpenClaw Azure platform.
Use this when a destructive infrastructure change is required
(e.g., adding VNet integration to an existing non-VNet CAE).

## Prerequisites

- Azure CLI authenticated (`az login`)
- Terraform 1.5+ installed
- Layered config populated under `config/` (`./platform/cli/ocp config bootstrap --env <env> --user <slug>`)
- Per-user overlays in `config/users/<slug>.env` (see `config/users/user.example.env`)
- Your public IPs for deployer allowlisting (see Step 5)

## Why a full rebuild?

Azure Container Apps Environments **cannot** be updated from
non-VNet to VNet-integrated in-place. The CAE must be destroyed
and recreated, which cascades to all Container Apps inside it.

## Architecture after rebuild

```
VNet 10.0.0.0/16
├── snet-cae  10.0.0.0/21  (CAE, delegated, internal LB)
└── snet-pe   10.0.8.0/24  (private endpoints: ACR, KV, NFS Storage)

PaaS Firewalls: default_action = Deny on ACR, KV, Storage
Private Endpoints: ACR, Key Vault, NFS Storage
NFS: Premium FileStorage, 100 GB share mounted into CAE via NfsAzureFile
```

## Key lessons learned

> Read these before starting — they will save you hours.

### NFS Storage

- **azurerm provider does NOT fully support NFS.** The
  `azurerm_container_app_environment_storage` resource only creates SMB
  (AzureFile) mounts. NFS mounts are applied with Terraform AzAPI resources.
- **azurerm_container_app `storage_type` only accepts
  `AzureFile|EmptyDir|Secret`.** NfsAzureFile is patched via AzAPI
  after creation. The container app
  uses `lifecycle { ignore_changes = [template[0].volume] }` to prevent
  Terraform from reverting it.
- **NFS FileStorage with `default_action = Deny` blocks Terraform
  data-plane.** Terraform cannot create/manage file shares (403 errors).
  **Workaround:** Temporarily set `--default-action Allow` via
  `az storage account update`, perform the operation, then restore Deny.
- **SMB mount on NFS share = CrashLoopBackOff.** If Azure tries
  `mount.cifs` on an NFS share, the container fails with
  `VolumeMountFailure: mount error(13): Permission denied`.

### ACR Builds

- **ACR Tasks build agents have unpredictable IPs.** They are NOT your
  deployer IP. **Workaround:** Temporarily set ACR default action to
  `Allow` during builds (`az acr update -n <name> --default-action Allow`),
  then restore to `Deny` after.

### Deployer IPs

- **Your machine may egress through TWO different public IPs.** Different
  Azure services see different source IPs depending on routing. Always
  detect both:
  ```bash
  curl -s ifconfig.me        # → IP1
  curl -s https://api.ipify.org  # → IP2 (may differ)
  ```
- Use the `deployer_ips` variable (comma-separated):
  ```bash
  -var="deployer_ips=<YOUR_IP1>,<YOUR_IP2>"
  ```

### Key Vault

- **KV purge may be blocked by subscription policy** (DeletedVaultPurge
  denied). Use `az keyvault recover` to recover the soft-deleted vault
  into the new resource group, then import it into Terraform state.
- **KV firewall propagation is slow** (1-2+ minutes). Terraform
  operations may 403 right after updating IP rules.

### CAE

- **CAE VNet integration is destructive** -- cannot be added in-place.
- **`infrastructure_resource_group_name` forces CAE replacement** -- Azure
  auto-populates this field; Terraform detects drift. Fixed with
  `lifecycle { ignore_changes }`.
- **CAE deletion is VERY slow** (10-15+ minutes).
- **CAE cannot delete with apps inside** -- delete ALL container apps first.

---

## Step-by-step (manual)

### 0. Capture non-Terraform resources

Before destroying anything, document resources not managed by Terraform.
The `ca-graph-mcp-gw-<slug>` container app is NOT in Terraform state.

```bash
# Export its config for later recreation
az containerapp show -n ca-graph-mcp-gw-<slug> -g rg-openclaw-<env> -o json > /tmp/graph-mcp-backup.json
```

Key details for manual recreation:
- Image: `<acr-name>.azurecr.io/graph-mcp-gateway:latest`
- Identity: SystemAssigned
- Resources: 0.25 CPU / 0.5Gi
- Port: 3000 (internal ingress)
- Env vars: `HOST=0.0.0.0`, `NODE_ENV=production`, `PORT=3000`
- Secret env vars: `GRAPH_MCP_CLIENT_ID`, `GRAPH_MCP_TENANT_ID`
- Secrets: `storage-key`, `tenant-id`, `client-id`

### 1. Destroy user container apps (Terraform-managed)

For each user with a `config/users/<slug>.env` file:

```bash
./platform/cli/ocp user remove --env dev --user alice
./platform/cli/ocp user remove --env dev --user bob
```

This removes `ca-openclaw-<env>-<slug>` and its KV secrets.

### 2. Delete non-Terraform container apps manually

```bash
az containerapp delete -n ca-graph-mcp-gw-<slug> -g rg-openclaw-<env> --yes
```

### 3. Destroy shared infrastructure

```bash
./platform/cli/ocp deploy shared --env dev --destroy
```

This destroys: CAE, VNet, subnets, NSG, private endpoints, DNS zones,
ACR, Key Vault, Storage accounts, NFS share, Log Analytics, Identity.

**Note:** Key Vault has purge protection (90 days). If subscription
policy blocks purge, the rebuild step will recover it instead.

```bash
# Only if policy allows purge:
az keyvault purge --name kv<name> --location ${AZURE_LOCATION}
```

### 4. Clean Terraform state

```bash
rm -rf infra/shared/terraform.tfstate*
rm -rf infra/user-app/terraform.tfstate*
rm -rf infra/shared/.terraform
rm -rf infra/user-app/.terraform
```

### 5. Detect all deployer IPs

Your machine may egress through different IPs depending on routing.
Always check both sources:

```bash
echo "IP1: $(curl -s ifconfig.me)"
echo "IP2: $(curl -s https://api.ipify.org)"
# If they differ, use both comma-separated:
export DEPLOYER_IPS="$(curl -s ifconfig.me),$(curl -s https://api.ipify.org)"
echo "Deployer IPs: $DEPLOYER_IPS"
```

### 5b. Recover soft-deleted Key Vault (if needed)

If a soft-deleted vault exists with the same name:

```bash
# Check for soft-deleted vault
az keyvault list-deleted --query "[?name=='kv<name>']" -o table

# Recover it (preferred over purge)
az keyvault recover --name kv<name> --location ${AZURE_LOCATION}
```

Then import it into Terraform state during step 6 (import.sh handles this).

### 6. Rebuild shared infrastructure

```bash
terraform -chdir=infra/shared init

terraform -chdir=infra/shared apply \
  -var="environment=dev" \
  -var="location=${AZURE_LOCATION}" \
  -var="region_code=${AZURE_REGION_CODE}" \
  -var="owner_slug=platform" \
  -var="deployer_ips=$DEPLOYER_IPS"
```

If apply fails on the NFS file share with 403, the storage account
firewall hasn't propagated yet. Workaround:

```bash
# Temporarily open NFS storage firewall
az storage account update --name nfs<name> --default-action Allow
sleep 15

# Retry apply
terraform -chdir=infra/shared apply \
  -var="environment=dev" \
  -var="location=${AZURE_LOCATION}" \
  -var="region_code=${AZURE_REGION_CODE}" \
  -var="owner_slug=platform" \
  -var="deployer_ips=$DEPLOYER_IPS"

# Restore firewall
az storage account update --name nfs<name> --default-action Deny
```

This creates the full VNet-integrated platform:
- Resource Group, VNet, 2 subnets, NSG
- CAE (VNet-integrated, internal LB)
- ACR (Premium, private endpoint, deployer IPs allowed)
- Key Vault (RBAC, private endpoint, deployer IPs allowed)
- Storage accounts (general + NFS Premium FileStorage)
- NFS share mounted into CAE (NfsAzureFile type, via Terraform AzAPI)
- Private DNS zones + VNet links
- Managed Identity with AcrPull + KV Secrets User

### 7. Build and push the golden image

```bash
# ACR Tasks build agents have unpredictable IPs -- temporarily allow all
az acr update -n <acr-name> --default-action Allow

make build-image

# Restore firewall
az acr update -n <acr-name> --default-action Deny
```

### 8. Deploy user container app

For each user with a `config/users/<slug>.env` file:

```bash
./platform/cli/ocp deploy user --env dev --user alice
./platform/cli/ocp deploy user --env dev --user bob
```

The container app is created with `storage_type = "AzureFile"` (provider
limitation), then Terraform AzAPI resources patch it to
`NfsAzureFile`. Verify the volume mount is working:

```bash
az containerapp show -n ca-openclaw-<slug> -g rg-openclaw-<env> \
  --query "properties.template.volumes" -o table
```

### 9. Recreate non-Terraform container apps

Recreate `ca-graph-mcp-gw-<slug>` manually:

```bash
az containerapp create \
  --name ca-graph-mcp-gw-<slug> \
  --resource-group rg-openclaw-<env> \
  --environment cae-openclaw-<env> \
  --image <acr-name>.azurecr.io/graph-mcp-gateway:latest \
  --cpu 0.25 --memory 0.5Gi \
  --min-replicas 1 --max-replicas 1 \
  --ingress internal --target-port 3000 \
  --env-vars "HOST=0.0.0.0" "NODE_ENV=production" "PORT=3000" \
    "GRAPH_MCP_CLIENT_ID=secretref:client-id" \
    "GRAPH_MCP_TENANT_ID=secretref:tenant-id" \
  --secrets "storage-key=<VALUE>" "tenant-id=<VALUE>" "client-id=<VALUE>" \
  --system-assigned
```

Replace `<VALUE>` placeholders with actual secret values from
`/tmp/graph-mcp-backup.json` or your secrets manager.

### 10. (Optional) Lock down deployer IP access

Once everything is deployed, remove the deployer IP allowlist
by re-applying shared infra without `deployer_ips`:

```bash
terraform -chdir=infra/shared apply \
  -var="environment=dev" \
  -var="location=${AZURE_LOCATION}" \
  -var="region_code=${AZURE_REGION_CODE}" \
  -var="owner_slug=platform"
```

This sets `deployer_ips=""`, which closes public access on ACR, KV,
and Storage. All traffic must then go through private endpoints.

---

## Automated rebuild

For a scripted version of the above, use `ocp reset`. It discovers all users from `config/users/*.env` files automatically -- no `--user` flag needed.

```bash
./platform/cli/ocp reset --env dev
./platform/cli/ocp reset --env dev --force
./platform/cli/ocp reset --env prod
./platform/cli/ocp reset --env prod --force
./platform/cli/ocp reset --env dev --nuke-only
./platform/cli/ocp reset --env dev --rebuild-only
```

Or use Makefile aliases (these are `make`-only shortcuts with no direct `ocp` equivalent):

```bash
make nuke-all ENV=dev
make rebuild-all ENV=dev
make full-rebuild ENV=dev
```

`platform-reset.sh` remains as the internal reset engine, but operator entry should be `ocp reset`.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `az acr build` fails with 403 | ACR Tasks agents have unpredictable IPs. Temporarily `az acr update -n <acr> --default-action Allow`, build, then restore Deny. |
| Key Vault name conflict | Check for soft-deleted vault: `az keyvault list-deleted`. Recover with `az keyvault recover` (preferred) or purge with `az keyvault purge` (may be policy-blocked). |
| CAE subnet conflict | Ensure old CAE is fully deleted before re-creating (can take 10-15 min). |
| NFS share mount fails (VolumeMountFailure) | Verify storage mount type is `NfsAzureFile` not `AzureFile`. Check: `az containerapp env storage show -n <cae> -g <rg> --storage-name openclaw-nfs-<env>`. |
| Terraform 403 on NFS file share | NFS storage firewall hasn't propagated. Temporarily `az storage account update --name <nfs-sa> --default-action Allow`, apply, restore Deny. |
| KV firewall propagation delay | Wait 1-2 min after updating KV IP rules before Terraform operations. |
| `workload_profile_name` perpetual drift | Already handled by `lifecycle { ignore_changes }` in container app config. |
| Azure `CreatedDate` tag drift | Azure auto-adds this tag. Remove manually or ignore; will recur on resource recreation. |
| `infrastructure_resource_group_name` forces CAE replacement | Already handled by `lifecycle { ignore_changes }` in CAE config. |
| Deployer gets 403 on multiple services | You may have two outbound IPs. Check both `curl -s ifconfig.me` and `curl -s https://api.ipify.org`, pass both comma-separated to `deployer_ips`. |
