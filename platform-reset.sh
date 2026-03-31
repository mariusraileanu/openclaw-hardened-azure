#!/bin/bash
# ===========================================================================
# OpenClaw Azure Platform — Nuke & Rebuild Script
#
# Operates on ALL users discovered from config/users/*.env.
# No --user flag — this is a platform-wide tool.
#
# Usage:
#   ./platform-reset.sh                       # Interactive full reset (dev)
#   ./platform-reset.sh -e prod               # Target prod environment
#   ./platform-reset.sh -f                    # Non-interactive (no prompts)
#   ./platform-reset.sh --nuke-only           # Destroy only (all users + shared)
#   ./platform-reset.sh --rebuild-only        # Rebuild only, assumes clean state
#   ./platform-reset.sh -e prod -f            # Non-interactive prod reset
#
# Prod safety guardrails (required for prod runs):
#   ALLOW_PROD_DESTRUCTIVE=true
#   BREAK_GLASS_TICKET=INC-12345 (or CHG-12345)
# Optional for protected CI branches/runners:
#   ALLOW_PROTECTED_DESTRUCTIVE=true
#
# NFS Lessons Learned:
#   - azurerm_container_app_environment_storage only supports SMB (AzureFile).
#     NFS mounts are managed via AzAPI (managedEnvironments/storages +
#     containerApps template updates for NfsAzureFile).
#   - azurerm_container_app storage_type only accepts AzureFile|EmptyDir|Secret.
#     NfsAzureFile requires AzAPI patch resources.
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
# CLI argument parsing (POSIX short + GNU long forms)
# ---------------------------------------------------------------------------
ENV_ARG="dev"
FORCE=false
NUKE_ONLY=false
REBUILD_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -e|--env)
      ENV_ARG="$2"
      shift 2
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    --nuke-only)
      NUKE_ONLY=true
      shift
      ;;
    --rebuild-only)
      REBUILD_ONLY=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [-e|--env ENV] [-f|--force] [--nuke-only] [--rebuild-only]"
      echo ""
      echo "Options:"
      echo "  -e, --env ENV       Target environment (default: dev)"
      echo "  -f, --force         Skip confirmation prompts"
      echo "  --nuke-only         Destroy only (all users + shared infra)"
      echo "  --rebuild-only      Rebuild only (assumes clean state)"
      echo "  -h, --help          Show this help"
      echo ""
      echo "This script operates on ALL users discovered from config/users/*.env files."
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Run '$0 --help' for usage."
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Load layered config directly from config/
# ---------------------------------------------------------------------------
AZURE_ENVIRONMENT="${ENV_ARG}"
SHARED_ENV_FILE="config/env/${AZURE_ENVIRONMENT}.env"
LOCAL_SHARED_ENV_FILE="config/local/${AZURE_ENVIRONMENT}.env"

if [[ ! -f "${SHARED_ENV_FILE}" ]]; then
  echo "FATAL: Missing ${SHARED_ENV_FILE}. Run 'make config-bootstrap ENV=${AZURE_ENVIRONMENT}' first." >&2
  exit 1
fi

set -a
source "${SHARED_ENV_FILE}"
if [[ -f "${LOCAL_SHARED_ENV_FILE}" ]]; then
  source "${LOCAL_SHARED_ENV_FILE}"
fi
set +a

# Resolve and validate naming contract from single source of truth
if [[ -f "scripts/naming-contract.sh" ]]; then
  export ENV_NAME="${AZURE_ENVIRONMENT}"
  eval "$(scripts/naming-contract.sh export)"
  scripts/naming-contract.sh validate >/dev/null
  echo "Naming contract: RG=${AZURE_RESOURCE_GROUP} CAE=${AZURE_CONTAINERAPPS_ENV} ACR=${AZURE_ACR_NAME} KV=${AZURE_KEY_VAULT_NAME} NFS=${NFS_SA_NAME}"
else
  echo "FATAL: Missing scripts/naming-contract.sh" >&2
  exit 1
fi

AZURE_ENVIRONMENT="${AZURE_ENVIRONMENT:-dev}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus}"
AZURE_OWNER_SLUG="${AZURE_OWNER_SLUG:-platform}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
SIGNAL_PROXY_AUTH_TOKEN="${SIGNAL_PROXY_AUTH_TOKEN:-}"
ALLOW_PROD_DESTRUCTIVE="${ALLOW_PROD_DESTRUCTIVE:-false}"
ALLOW_PROTECTED_DESTRUCTIVE="${ALLOW_PROTECTED_DESTRUCTIVE:-false}"
BREAK_GLASS_TICKET="${BREAK_GLASS_TICKET:-}"

# Derived names — overridable via env file for non-standard naming (e.g. prod)
RG_NAME="${AZURE_RESOURCE_GROUP}"
CAE_NAME="${AZURE_CONTAINERAPPS_ENV}"
ACR_NAME="${AZURE_ACR_NAME}"
KV_NAME="${AZURE_KEY_VAULT_NAME}"
NFS_SA_NAME="${NFS_SA_NAME}"
CAE_NFS_STORAGE_NAME="${CAE_NFS_STORAGE_NAME}"

# Remote state backend (provisioned by infra/bootstrap-state.sh)
TF_STATE_RG="${TF_STATE_RG}"
TF_STATE_SA="${TF_STATE_SA}"
TF_STATE_KEY="${TF_STATE_KEY}"
TF_BACKEND_ARGS="-backend-config=resource_group_name=${TF_STATE_RG} -backend-config=storage_account_name=${TF_STATE_SA} -backend-config=key=${TF_STATE_KEY}"

# ---------------------------------------------------------------------------
# Discover all users from config/users/*.env files
# ---------------------------------------------------------------------------
discover_users() {
  local users=()
  for f in config/users/*.env; do
    # Skip templates and editor backups
    [[ "$f" == "config/users/user.example.env" ]] && continue
    [[ "$f" == *.swp ]] || [[ "$f" == *~ ]] && continue
    [[ ! -f "$f" ]] && continue
    # Extract slug from filename: config/users/alice.env -> alice
    local slug
    slug="$(basename "$f" .env)"
    users+=("$slug")
  done
  echo "${users[@]}"
}

# Source a user's env file (+ optional local override), overlaying shared env
load_user_env() {
  local slug="$1"
  local user_file="config/users/${slug}.env"
  local local_user_file="config/local/${AZURE_ENVIRONMENT}.${slug}.env"
  if [[ -f "$user_file" ]]; then
    set -a
    source "$user_file"
    if [[ -f "$local_user_file" ]]; then
      source "$local_user_file"
    fi
    set +a
  fi
}

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

is_true() {
  [[ "${1:-}" == "true" ]]
}

is_protected_context() {
  local ref="${GITHUB_REF_NAME:-${GITHUB_REF:-${CI_COMMIT_REF_NAME:-}}}"
  if [[ -n "${PROTECTED_RUNNER:-}" ]] && is_true "${PROTECTED_RUNNER}"; then
    return 0
  fi
  if is_true "${CI:-false}" || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    if [[ "$ref" =~ ^(main|master|prod|production|release/.+)$ ]]; then
      return 0
    fi
  fi
  return 1
}

require_prod_guardrails() {
  if [[ "${AZURE_ENVIRONMENT}" != "prod" ]]; then
    return 0
  fi

  is_true "${ALLOW_PROD_DESTRUCTIVE}" || fail "Prod reset is blocked. Set ALLOW_PROD_DESTRUCTIVE=true to continue."

  if [[ ! "${BREAK_GLASS_TICKET}" =~ ^(INC|CHG)-[0-9]+$ ]]; then
    fail "Prod reset requires BREAK_GLASS_TICKET in format INC-12345 or CHG-12345."
  fi

  if is_protected_context && ! is_true "${ALLOW_PROTECTED_DESTRUCTIVE}"; then
    fail "Prod reset in protected branch/runner context is blocked. Set ALLOW_PROTECTED_DESTRUCTIVE=true to override."
  fi
}

confirm_prod_destructive() {
  if [[ "${AZURE_ENVIRONMENT}" != "prod" ]]; then
    return 0
  fi

  [[ -t 0 ]] || fail "Prod destructive operations require an interactive terminal."

  warn "PRODUCTION DESTRUCTIVE MODE"
  warn "Break-glass ticket: ${BREAK_GLASS_TICKET}"
  warn "Target resource group: ${RG_NAME}"
  echo ""

  local typed_env typed_rg typed_phrase
  echo -n "Type environment name to continue (prod): "
  read -r typed_env
  [[ "$typed_env" == "prod" ]] || fail "Environment confirmation failed."

  echo -n "Type target resource group to continue (${RG_NAME}): "
  read -r typed_rg
  [[ "$typed_rg" == "${RG_NAME}" ]] || fail "Resource group confirmation failed."

  echo -n "Type confirmation phrase (DESTROY-PROD-OPENCLAW): "
  read -r typed_phrase
  [[ "$typed_phrase" == "DESTROY-PROD-OPENCLAW" ]] || fail "Confirmation phrase mismatch."
}

log_destructive_context() {
  local mode="$1"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[$ts] mode=${mode} env=${AZURE_ENVIRONMENT} rg=${RG_NAME} subscription=${SUB_ID} operator=$(whoami) ticket=${BREAK_GLASS_TICKET}" | tee -a "/tmp/openclaw-destructive-${AZURE_ENVIRONMENT}.log"
}

confirm() {
  if [[ "$FORCE" == "true" ]] && [[ "${AZURE_ENVIRONMENT}" != "prod" ]]; then return 0; fi
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

require_prod_guardrails

# Discover users
USERS=($(discover_users))
if [[ ${#USERS[@]} -eq 0 ]]; then
  warn "No config/users/*.env files found — no per-user operations will be performed"
else
  echo "Users discovered: ${USERS[*]}"
fi

# ===========================================================================
# NUKE PHASE
# ===========================================================================
nuke() {
  step "Step 0a: Ensure remote state backend exists"
  bash infra/bootstrap-state.sh
  ok "Remote state backend ready"

  step "Step 0b: Backup non-Terraform resources (all users)"
  for slug in "${USERS[@]}"; do
    if az containerapp show -n "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${slug}" -g "$RG_NAME" >/dev/null 2>&1; then
      az containerapp show -n "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${slug}" -g "$RG_NAME" -o json > "/tmp/graph-mcp-backup-${slug}.json"
      ok "Backed up ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${slug} to /tmp/graph-mcp-backup-${slug}.json"
    else
      warn "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${slug} not found, nothing to back up"
    fi
  done

  confirm "This will DESTROY all Azure resources in ${RG_NAME} for ALL users (${USERS[*]:-none}). Continue?"

  step "Step 1: Destroy Terraform-managed user container apps (all users)"
  terraform -chdir=infra/user-app init -input=false >/dev/null 2>&1 || true
  for slug in "${USERS[@]}"; do
    echo -e "\n${CYAN}--- Destroying user: ${slug} ---${NC}"
    # Select the user's TF workspace
    if terraform -chdir=infra/user-app workspace select "${slug}" 2>/dev/null; then
      export TF_VAR_compass_api_key="placeholder"
      terraform -chdir=infra/user-app destroy -auto-approve \
        -var="user_slug=${slug}" \
        -var="environment=${AZURE_ENVIRONMENT}" \
        -var="location=${AZURE_LOCATION}" \
        -var="image_ref=placeholder" \
        -var="graph_mcp_url=placeholder" \
        -var="resource_group_name=${RG_NAME}" \
        -var="key_vault_name=${KV_NAME}" \
        -var="acr_name=${ACR_NAME}" \
        -var="cae_name=${CAE_NAME}" \
        -var="cae_nfs_storage_name=${CAE_NFS_STORAGE_NAME}" \
        || warn "User app destroy for '${slug}' had issues (may already be gone)"
      ok "User app '${slug}' destroyed"
    else
      warn "No TF workspace '${slug}' found, skipping TF destroy"
    fi
  done

  step "Step 2: Delete non-Terraform container apps (all users)"
  for slug in "${USERS[@]}"; do
    if az containerapp show -n "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${slug}" -g "$RG_NAME" >/dev/null 2>&1; then
      az containerapp delete -n "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${slug}" -g "$RG_NAME" --yes
      ok "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${slug} deleted"
    else
      warn "ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${slug} not found, skipping"
    fi
  done

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
# REBUILD PHASE
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
    warn "SIGNAL_BOT_NUMBER not set in ${SHARED_ENV_FILE} — skipping Signal stack"
  fi

  step "Step 8: Deploy user container apps (all users)"
  if [[ ${#USERS[@]} -eq 0 ]]; then
    warn "No config/users/*.env files found — skipping user app deployment"
  else
    IMAGE_REF="${ACR_NAME}.azurecr.io/openclaw-golden:${IMAGE_TAG}"
    terraform -chdir=infra/user-app init -input=false

    # Auto-capture Signal proxy URL and auth token from shared TF output
    SIGNAL_CLI_URL_TF=$(terraform -chdir=infra/shared output -json signal_cli_url 2>/dev/null | tr -d '"' || echo "")
    SIGNAL_PROXY_AUTH_TOKEN_TF=$(terraform -chdir=infra/shared output -json signal_proxy_auth_token 2>/dev/null | tr -d '"' || echo "")
    SIGNAL_BOT_NUMBER="${SIGNAL_BOT_NUMBER:-}"

    for slug in "${USERS[@]}"; do
      echo -e "\n${CYAN}--- Deploying user: ${slug} ---${NC}"

      # Source the user's env file for per-user overrides
      # (SIGNAL_USER_PHONE, COMPASS_API_KEY)
      load_user_env "$slug"

      # Read per-user values (may have been overridden by load_user_env)
      local_signal_user_phone="${SIGNAL_USER_PHONE:-}"
      local_compass_api_key="${COMPASS_API_KEY:-placeholder}"
      # Select or create the user's TF workspace
      terraform -chdir=infra/user-app workspace select -or-create "${slug}"

      # Build Signal vars if all components are available
      SIGNAL_VARS=""
      if [[ -n "$SIGNAL_CLI_URL_TF" ]] && [[ -n "$SIGNAL_BOT_NUMBER" ]] && [[ -n "$local_signal_user_phone" ]]; then
        SIGNAL_VARS="-var=signal_cli_url=${SIGNAL_CLI_URL_TF} -var=signal_bot_number=${SIGNAL_BOT_NUMBER} -var=signal_user_phone=${local_signal_user_phone}"
        export TF_VAR_signal_proxy_auth_token="${SIGNAL_PROXY_AUTH_TOKEN_TF}"
        echo "Signal enabled: bot=${SIGNAL_BOT_NUMBER} user=${local_signal_user_phone}"
      else
        warn "Signal: skipped for '${slug}' (missing vars or proxy not deployed)"
      fi

      export TF_VAR_compass_api_key="${local_compass_api_key}"
      terraform -chdir=infra/user-app apply -auto-approve \
        -var="user_slug=${slug}" \
        -var="environment=${AZURE_ENVIRONMENT}" \
        -var="location=${AZURE_LOCATION}" \
        -var="image_ref=${IMAGE_REF}" \
        -var="graph_mcp_url=${GRAPH_MCP_URL:-placeholder}" \
        -var="resource_group_name=${RG_NAME}" \
        -var="key_vault_name=${KV_NAME}" \
        -var="acr_name=${ACR_NAME}" \
        -var="cae_name=${CAE_NAME}" \
        -var="cae_nfs_storage_name=${CAE_NFS_STORAGE_NAME}" \
        ${SIGNAL_VARS} \
        || warn "User app deploy for '${slug}' had issues"
      ok "User app ca-openclaw-${AZURE_ENVIRONMENT}-${slug} deployed"

      # Re-source shared env layers to reset overrides before next user
      if [[ -f "${SHARED_ENV_FILE}" ]]; then
        set -a
        source "${SHARED_ENV_FILE}"
        if [[ -f "${LOCAL_SHARED_ENV_FILE}" ]]; then
          source "${LOCAL_SHARED_ENV_FILE}"
        fi
        set +a
      fi
    done
  fi

  step "Step 9: Manual action required"
  for slug in "${USERS[@]}"; do
    echo "Recreate ca-graph-mcp-gw-${AZURE_ENVIRONMENT}-${slug} manually (image must be rebuilt separately)."
    if [[ -f "/tmp/graph-mcp-backup-${slug}.json" ]]; then
      echo "  Backup: /tmp/graph-mcp-backup-${slug}.json"
    fi
  done
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
  echo "Users deployed: ${USERS[*]:-none}"
  echo ""
  echo "Remaining manual step: recreate ca-graph-mcp-gw-<env>-<slug> for each user."
  echo "See REBUILD.md Step 9 for details."
}

# ===========================================================================
# Main
# ===========================================================================
if [[ "$REBUILD_ONLY" == "true" ]]; then
  if [[ "${AZURE_ENVIRONMENT}" == "prod" ]]; then
    log_destructive_context "rebuild-only"
  fi
  rebuild
elif [[ "$NUKE_ONLY" == "true" ]]; then
  if [[ "${AZURE_ENVIRONMENT}" == "prod" ]]; then
    log_destructive_context "nuke-only"
    confirm_prod_destructive
  fi
  nuke
else
  if [[ "${AZURE_ENVIRONMENT}" == "prod" ]]; then
    log_destructive_context "full-rebuild"
    confirm_prod_destructive
  fi
  nuke
  echo ""
  confirm "Nuke complete. Proceed with rebuild?"
  rebuild
fi
