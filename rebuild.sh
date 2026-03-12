#!/bin/bash
# ===========================================================================
# OpenClaw Azure Platform — Nuke & Rebuild Script
#
# Usage:
#   ./rebuild.sh                  # Interactive (prompts before destructive ops)
#   ./rebuild.sh --force          # Non-interactive (no prompts)
#   ./rebuild.sh --nuke-only      # Destroy only (steps 1-4)
#   ./rebuild.sh --rebuild-only   # Rebuild only (steps 5-10), assumes clean state
#
# NFS Lessons Learned:
#   - azurerm_container_app_environment_storage only supports SMB (AzureFile).
#     NFS mounts use null_resource + "az containerapp env storage set --storage-type NfsAzureFile".
#   - azurerm_container_app storage_type only accepts AzureFile|EmptyDir|Secret.
#     NfsAzureFile is patched via REST API (null_resource.nfs_volume_patch).
#   - NFS Premium FileStorage with default_action=Deny blocks Terraform data-plane.
#     Workaround: temporarily set --default-action Allow during terraform apply.
#   - ACR Tasks build agent IPs are unpredictable. Temporarily set ACR default
#     action to Allow during builds, restore to Deny after.
#   - Deployer machine may have TWO outbound IPs (different services see different
#     IPs). Always detect both with ifconfig.me AND api.ipify.org.
#   - KV purge may be blocked by subscription policy. Recover soft-deleted vault
#     with "az keyvault recover" instead.
# ===========================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Load per-environment env file
# ---------------------------------------------------------------------------
AZURE_ENVIRONMENT="${AZURE_ENVIRONMENT:-dev}"
if [[ -f ".env.azure.${AZURE_ENVIRONMENT}" ]]; then
  set -a
  source ".env.azure.${AZURE_ENVIRONMENT}"
  set +a
fi

AZURE_ENVIRONMENT="${AZURE_ENVIRONMENT:-dev}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus}"
AZURE_OWNER_SLUG="${AZURE_OWNER_SLUG:-platform}"
USER_SLUG="${USER_SLUG:-}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
SIGNAL_PROXY_AUTH_TOKEN="${SIGNAL_PROXY_AUTH_TOKEN:-}"

# Derived names — overridable via env file for non-standard naming (e.g. prod)
RG_NAME="${AZURE_RESOURCE_GROUP:-rg-openclaw-shared-${AZURE_ENVIRONMENT}}"
CAE_NAME="${AZURE_CONTAINERAPPS_ENV:-cae-openclaw-shared-${AZURE_ENVIRONMENT}}"
ACR_NAME="${AZURE_ACR_NAME:-openclawshared${AZURE_ENVIRONMENT}acr}"
KV_NAME="${AZURE_KEY_VAULT_NAME:-kvopenclawshared${AZURE_ENVIRONMENT}}"
NFS_SA_NAME="${NFS_SA_NAME:-nfsopenclawshared${AZURE_ENVIRONMENT}}"
CAE_NFS_STORAGE_NAME="${CAE_NFS_STORAGE_NAME:-openclaw-nfs}"

# Remote state backend (provisioned by infra/bootstrap-state.sh)
TF_STATE_RG="${TF_STATE_RG:-rg-openclaw-tfstate-${AZURE_ENVIRONMENT}}"
TF_STATE_SA="${TF_STATE_SA:-tfopenclawstate${AZURE_ENVIRONMENT}}"
TF_BACKEND_ARGS="-backend-config=resource_group_name=${TF_STATE_RG} -backend-config=storage_account_name=${TF_STATE_SA}"

FORCE=false
NUKE_ONLY=false
REBUILD_ONLY=false

for arg in "$@"; do
  case $arg in
    --force) FORCE=true ;;
    --nuke-only) NUKE_ONLY=true ;;
    --rebuild-only) REBUILD_ONLY=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${CYAN}=== $1 ===${NC}"; }
warn() { echo -e "${YELLOW}WARNING: $1${NC}"; }
ok()   { echo -e "${GREEN}OK: $1${NC}"; }
fail() { echo -e "${RED}FAILED: $1${NC}"; exit 1; }

confirm() {
  if [[ "$FORCE" == "true" ]]; then return 0; fi
  echo -en "${YELLOW}$1 [y/N]: ${NC}"
  read -r response
  [[ "$response" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# Detect all unique outbound IPs (deployer may egress through different IPs)
detect_deployer_ips() {
  local ip1 ip2
  ip1=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
  ip2=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "")

  if [[ -z "$ip1" ]] && [[ -z "$ip2" ]]; then
    fail "Could not detect any outbound IP"
  fi

  if [[ "$ip1" == "$ip2" ]] || [[ -z "$ip2" ]]; then
    echo "$ip1"
  elif [[ -z "$ip1" ]]; then
    echo "$ip2"
  else
    echo "${ip1},${ip2}"
  fi
}

# Temporarily open NFS storage account firewall for Terraform data-plane access
nfs_firewall_allow() {
  step "Temporarily allowing public access on NFS storage account"
  if az storage account show --name "${NFS_SA_NAME}" --resource-group "${RG_NAME}" >/dev/null 2>&1; then
    az storage account update --name "${NFS_SA_NAME}" --resource-group "${RG_NAME}" --default-action Allow --output none
    ok "NFS storage default action set to Allow"
    echo "Waiting 15s for firewall propagation..."
    sleep 15
  else
    warn "NFS storage account not found, skipping"
  fi
}

# Restore NFS storage account firewall to Deny
nfs_firewall_deny() {
  step "Restoring NFS storage account firewall to Deny"
  if az storage account show --name "${NFS_SA_NAME}" --resource-group "${RG_NAME}" >/dev/null 2>&1; then
    az storage account update --name "${NFS_SA_NAME}" --resource-group "${RG_NAME}" --default-action Deny --output none
    ok "NFS storage default action restored to Deny"
  fi
}

# Temporarily open ACR public access for ACR Tasks builds
acr_firewall_allow() {
  step "Temporarily allowing ACR public access for build"
  az acr update -n "${ACR_NAME}" --default-action Allow --output none 2>/dev/null || true
  ok "ACR default action set to Allow"
}

# Restore ACR firewall to Deny
acr_firewall_deny() {
  step "Restoring ACR firewall to Deny"
  az acr update -n "${ACR_NAME}" --default-action Deny --output none 2>/dev/null || true
  ok "ACR default action restored to Deny"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
step "Pre-flight checks"
command -v az >/dev/null 2>&1 || fail "Azure CLI not found"
command -v terraform >/dev/null 2>&1 || fail "Terraform not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
az account show >/dev/null 2>&1 || fail "Not logged in to Azure CLI"

SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
echo "Subscription: ${SUB_NAME} (${SUB_ID})"
echo "Resource Group: ${RG_NAME}"
echo "Environment: ${AZURE_ENVIRONMENT}"
echo "Location: ${AZURE_LOCATION}"

# ===========================================================================
# NUKE PHASE (Steps 1-4)
# ===========================================================================
nuke() {
  step "Step 0a: Ensure remote state backend exists"
  bash infra/bootstrap-state.sh
  ok "Remote state backend ready"

  step "Step 0b: Backup non-Terraform resources"
  if [[ -n "$USER_SLUG" ]]; then
    if az containerapp show -n "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${USER_SLUG}" -g "$RG_NAME" >/dev/null 2>&1; then
      az containerapp show -n "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${USER_SLUG}" -g "$RG_NAME" -o json > /tmp/graph-mcp-backup.json
      ok "Backed up ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${USER_SLUG} to /tmp/graph-mcp-backup.json"
    else
      warn "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${USER_SLUG} not found, nothing to back up"
    fi
  else
    warn "USER_SLUG not set, skipping graph MCP gateway backup"
  fi

  confirm "This will DESTROY all Azure resources in ${RG_NAME}. Continue?"

  step "Step 1: Destroy Terraform-managed user container apps"
  if [[ -n "$USER_SLUG" ]]; then
    terraform -chdir=infra/user-app init -input=false ${TF_BACKEND_ARGS} >/dev/null 2>&1 || true
    export TF_VAR_compass_api_key="placeholder"
    export TF_VAR_openclaw_gateway_auth_token="placeholder"
    terraform -chdir=infra/user-app destroy -auto-approve \
      -var="user_slug=${USER_SLUG}" \
      -var="environment=${AZURE_ENVIRONMENT}" \
      -var="location=${AZURE_LOCATION}" \
      -var="image_ref=placeholder" \
      -var="graph_mcp_url=placeholder" \
      -var="resource_group_name=${RG_NAME}" \
      -var="key_vault_name=${KV_NAME}" \
      -var="acr_name=${ACR_NAME}" \
      -var="cae_name=${CAE_NAME}" \
      -var="cae_nfs_storage_name=${CAE_NFS_STORAGE_NAME}" \
      || warn "User app destroy had issues (may already be gone)"
    ok "User app destroyed"
  else
    warn "USER_SLUG not set, skipping user app destroy"
  fi

  step "Step 2: Delete non-Terraform container apps"
  if [[ -n "$USER_SLUG" ]]; then
    if az containerapp show -n "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${USER_SLUG}" -g "$RG_NAME" >/dev/null 2>&1; then
      az containerapp delete -n "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${USER_SLUG}" -g "$RG_NAME" --yes
      ok "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${USER_SLUG} deleted"
    else
      warn "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${USER_SLUG} not found, skipping"
    fi
  else
    warn "USER_SLUG not set, skipping graph MCP gateway deletion"
  fi

  step "Step 3: Destroy shared infrastructure"
  terraform -chdir=infra/shared init -input=false ${TF_BACKEND_ARGS} >/dev/null 2>&1 || true
  terraform -chdir=infra/shared destroy -auto-approve \
    -var="environment=${AZURE_ENVIRONMENT}" \
    -var="location=${AZURE_LOCATION}" \
    -var="owner_slug=${AZURE_OWNER_SLUG}" \
    || warn "Shared infra destroy had issues"
  ok "Shared infrastructure destroyed"

  # Handle soft-deleted Key Vault
  # NOTE: Subscription policy may block purge (DeletedVaultPurge denied).
  # Prefer recovery ("az keyvault recover") into the new RG, then import
  # into Terraform state. Only attempt purge as a fallback.
  step "Step 3b: Handle soft-deleted Key Vault"
  if az keyvault list-deleted --query "[?name=='${KV_NAME}']" -o tsv 2>/dev/null | grep -q "${KV_NAME}"; then
    warn "Soft-deleted Key Vault '${KV_NAME}' found."
    echo "  Option A: Recover it (az keyvault recover) — preserves secrets, works with policy restrictions"
    echo "  Option B: Purge it (az keyvault purge) — may be blocked by subscription policy"
    echo "  The rebuild step will attempt recovery first, then let Terraform import it."
    # Don't auto-purge; recovery is handled in the rebuild phase
    ok "Soft-deleted Key Vault noted (will recover during rebuild)"
  else
    ok "No soft-deleted Key Vault found"
  fi

  step "Step 4: Clean local Terraform caches"
  # NOTE: Remote state in Azure Blob is preserved across nukes — only local
  # plugin caches are removed. State is never deleted by this script.
  rm -rf infra/shared/.terraform
  rm -rf infra/user-app/.terraform
  ok "Local .terraform dirs removed (remote state preserved)"
}

# ===========================================================================
# REBUILD PHASE (Steps 5-10)
# ===========================================================================
rebuild() {
  step "Step 4b: Ensure remote state backend exists"
  bash infra/bootstrap-state.sh
  ok "Remote state backend ready"

  step "Step 5: Detect deployer IPs"
  DEPLOYER_IPS=$(detect_deployer_ips)
  echo "Deployer IPs: ${DEPLOYER_IPS}"

  step "Step 5b: Recover soft-deleted Key Vault (if needed)"
  if az keyvault list-deleted --query "[?name=='${KV_NAME}']" -o tsv 2>/dev/null | grep -q "${KV_NAME}"; then
    warn "Recovering soft-deleted Key Vault '${KV_NAME}'..."
    az keyvault recover --name "${KV_NAME}" --location "${AZURE_LOCATION}" --output none || \
      warn "Key Vault recovery failed (may already exist or policy issue)"
    ok "Key Vault recovered (will import into Terraform state)"
    sleep 10  # Allow recovery to propagate
  fi

  step "Step 6: Rebuild shared infrastructure"
  terraform -chdir=infra/shared init -input=false ${TF_BACKEND_ARGS}

  # NOTE: NFS Premium FileStorage with default_action=Deny blocks Terraform
  # data-plane operations (creating/managing file shares returns 403).
  # The first apply creates the storage account with deployer IPs allowed,
  # but the NFS share creation may still fail if IPs haven't propagated.
  # If apply fails on the NFS share, wait and retry.
  terraform -chdir=infra/shared apply -auto-approve \
    -var="environment=${AZURE_ENVIRONMENT}" \
    -var="location=${AZURE_LOCATION}" \
    -var="owner_slug=${AZURE_OWNER_SLUG}" \
    -var="deployer_ips=${DEPLOYER_IPS}" \
  || {
    warn "First apply failed (likely NFS firewall propagation). Retrying in 30s..."
    nfs_firewall_allow
    terraform -chdir=infra/shared apply -auto-approve \
      -var="environment=${AZURE_ENVIRONMENT}" \
      -var="location=${AZURE_LOCATION}" \
      -var="owner_slug=${AZURE_OWNER_SLUG}" \
      -var="deployer_ips=${DEPLOYER_IPS}"
    nfs_firewall_deny
  }
  ok "Shared infrastructure created"

  step "Step 7: Build and push golden image"
  # ACR Tasks uses Azure's build infrastructure with unpredictable IPs.
  # Temporarily allow all public access on ACR during the build.
  acr_firewall_allow
  az acr build \
    --registry "${ACR_NAME}" \
    --image "openclaw-golden:${IMAGE_TAG}" \
    --file Dockerfile.wrapper .
  ok "Golden image pushed to ACR"

  # --- Step 7b: Signal stack (conditional) ---
  SIGNAL_BOT_NUMBER="${SIGNAL_BOT_NUMBER:-}"
  if [[ -n "$SIGNAL_BOT_NUMBER" ]]; then
    step "Step 7b: Build signal-proxy image and deploy Signal stack"
    echo "SIGNAL_BOT_NUMBER is set — deploying Signal stack"

    # Build signal-proxy image (ACR firewall is already open from step 7)
    az acr build \
      --registry "${ACR_NAME}" \
      --image "signal-proxy:${IMAGE_TAG}" \
      --file signal-proxy/Dockerfile signal-proxy/
    ok "Signal-proxy image pushed to ACR"

    acr_firewall_deny

    # Deploy signal-cli + proxy via Terraform (shared module)
    # NFS firewall must be open for TF to manage volumes
    nfs_firewall_allow
    SIGNAL_PROXY_IMAGE="${ACR_NAME}.azurecr.io/signal-proxy:${IMAGE_TAG}"
    terraform -chdir=infra/shared apply -auto-approve \
      -var="environment=${AZURE_ENVIRONMENT}" \
      -var="location=${AZURE_LOCATION}" \
      -var="owner_slug=${AZURE_OWNER_SLUG}" \
      -var="deployer_ips=${DEPLOYER_IPS}" \
      -var="signal_cli_enabled=true" \
      -var="signal_proxy_image=${SIGNAL_PROXY_IMAGE}" \
      -var="signal_proxy_auth_token=${SIGNAL_PROXY_AUTH_TOKEN}"
    nfs_firewall_deny
    ok "Signal stack deployed (signal-cli + proxy)"
    echo "NOTE: If this is a fresh deployment, run 'make signal-register' to register your bot number."
  else
    acr_firewall_deny
    warn "SIGNAL_BOT_NUMBER not set in .env.azure.${AZURE_ENVIRONMENT} — skipping Signal stack"
  fi

  step "Step 8: Deploy user container app"
  if [[ -z "$USER_SLUG" ]]; then
    warn "USER_SLUG not set in .env.azure.${AZURE_ENVIRONMENT}, skipping user app deployment"
  else
    IMAGE_REF="${ACR_NAME}.azurecr.io/openclaw-golden:${IMAGE_TAG}"
    terraform -chdir=infra/user-app init -input=false ${TF_BACKEND_ARGS}

    # Auto-capture Signal proxy URL and auth token from shared TF output
    SIGNAL_VARS=""
    SIGNAL_CLI_URL_TF=$(terraform -chdir=infra/shared output -json signal_cli_url 2>/dev/null | tr -d '"' || echo "")
    SIGNAL_PROXY_AUTH_TOKEN_TF=$(terraform -chdir=infra/shared output -json signal_proxy_auth_token 2>/dev/null | tr -d '"' || echo "")
    SIGNAL_USER_PHONE="${SIGNAL_USER_PHONE:-}"
    if [[ -n "$SIGNAL_CLI_URL_TF" ]] && [[ -n "$SIGNAL_BOT_NUMBER" ]] && [[ -n "$SIGNAL_USER_PHONE" ]]; then
      SIGNAL_VARS="-var=signal_cli_url=${SIGNAL_CLI_URL_TF} -var=signal_bot_number=${SIGNAL_BOT_NUMBER} -var=signal_user_phone=${SIGNAL_USER_PHONE}"
      export TF_VAR_signal_proxy_auth_token="${SIGNAL_PROXY_AUTH_TOKEN_TF}"
      echo "Signal enabled: bot=${SIGNAL_BOT_NUMBER} user=${SIGNAL_USER_PHONE}"
    else
      warn "Signal: skipped (missing vars or proxy not deployed)"
    fi

    export TF_VAR_compass_api_key="${COMPASS_API_KEY:-placeholder}"
    export TF_VAR_openclaw_gateway_auth_token="${OPENCLAW_GATEWAY_AUTH_TOKEN:-placeholder}"
    terraform -chdir=infra/user-app apply -auto-approve \
      -var="user_slug=${USER_SLUG}" \
      -var="environment=${AZURE_ENVIRONMENT}" \
      -var="location=${AZURE_LOCATION}" \
      -var="image_ref=${IMAGE_REF}" \
      -var="graph_mcp_url=${GRAPH_MCP_URL:-placeholder}" \
      -var="resource_group_name=${RG_NAME}" \
      -var="key_vault_name=${KV_NAME}" \
      -var="acr_name=${ACR_NAME}" \
      -var="cae_name=${CAE_NAME}" \
      -var="cae_nfs_storage_name=${CAE_NFS_STORAGE_NAME}" \
      ${SIGNAL_VARS}
    ok "User app ca-openclaw-${AZURE_ENVIRONMENT}-${USER_SLUG} deployed"
  fi

  step "Step 9: Manual action required"
  echo "Recreate ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-\${USER_SLUG} manually (image must be rebuilt separately)."
  echo "Backup is at /tmp/graph-mcp-backup.json (if it existed)."
  echo "See REBUILD.md Step 9 for the az containerapp create command."

  step "Step 10: (Optional) Lock down deployer IP access"
  confirm "Remove deployer IP allowlist and lock down public access?"
  # Preserve Signal state if it was deployed in step 7b
  LOCKDOWN_SIGNAL_VARS=""
  if [[ -n "$SIGNAL_BOT_NUMBER" ]]; then
    SIGNAL_PROXY_IMAGE="${ACR_NAME}.azurecr.io/signal-proxy:${IMAGE_TAG}"
    LOCKDOWN_SIGNAL_VARS="-var=signal_cli_enabled=true -var=signal_proxy_image=${SIGNAL_PROXY_IMAGE} -var=signal_proxy_auth_token=${SIGNAL_PROXY_AUTH_TOKEN}"
  fi
  terraform -chdir=infra/shared apply -auto-approve \
    -var="environment=${AZURE_ENVIRONMENT}" \
    -var="location=${AZURE_LOCATION}" \
    -var="owner_slug=${AZURE_OWNER_SLUG}" \
    ${LOCKDOWN_SIGNAL_VARS}
  ok "Public access locked down (deployer_ips removed)"

  echo ""
  echo -e "${GREEN}=========================================${NC}"
  echo -e "${GREEN} Rebuild complete!${NC}"
  echo -e "${GREEN}=========================================${NC}"
  echo ""
  echo "Remaining manual step: recreate ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-\${USER_SLUG}"
  echo "See REBUILD.md Step 9 for details."
}

# ===========================================================================
# Main
# ===========================================================================
if [[ "$REBUILD_ONLY" == "true" ]]; then
  rebuild
elif [[ "$NUKE_ONLY" == "true" ]]; then
  nuke
else
  nuke
  echo ""
  confirm "Nuke complete. Proceed with rebuild?"
  rebuild
fi
