#!/bin/bash
# ===========================================================================
# Bootstrap Terraform Remote State Backend
#
# Creates a dedicated Azure Storage Account + blob container for Terraform
# state, in a separate resource group that survives workload nuke operations.
#
# This script is idempotent — safe to re-run. It skips resources that
# already exist and only creates what is missing.
#
# Usage:
#   ./infra/bootstrap-state.sh              # uses AZURE_ENVIRONMENT + AZURE_LOCATION from env/.env
#   AZURE_ENVIRONMENT=prod ./infra/bootstrap-state.sh
#
# After running, initialize Terraform with:
#   terraform init \
#     -backend-config="resource_group_name=rg-openclaw-tfstate-<env>" \
#     -backend-config="storage_account_name=tfopenclawstate<env>"
# ===========================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Load per-environment layered config (same pattern as Makefile / platform-reset.sh)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_ENV="${AZURE_ENVIRONMENT:-dev}"
if [[ -f "${REPO_ROOT}/config/env/${_ENV}.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/config/env/${_ENV}.env"
  if [[ -f "${REPO_ROOT}/config/local/${_ENV}.env" ]]; then
    source "${REPO_ROOT}/config/local/${_ENV}.env"
  fi
  set +a
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ENV="${AZURE_ENVIRONMENT:-dev}"
LOCATION="${AZURE_LOCATION:-eastus}"

RG_NAME="rg-openclaw-tfstate-${ENV}"
SA_NAME="tfopenclawstate${ENV}"
CONTAINER_NAME="tfstate"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo -e "\n${CYAN}=== $1 ===${NC}"; }
ok()   { echo -e "${GREEN}OK: $1${NC}"; }
skip() { echo -e "${YELLOW}SKIP: $1${NC}"; }
fail() { echo -e "${RED}FAILED: $1${NC}"; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
step "Pre-flight checks"
command -v az >/dev/null 2>&1 || fail "Azure CLI not found"
az account show >/dev/null 2>&1 || fail "Not logged in to Azure CLI"

SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
echo "Subscription: ${SUB_NAME} (${SUB_ID})"
echo "Environment:  ${ENV}"
echo "Location:     ${LOCATION}"
echo "State RG:     ${RG_NAME}"
echo "State SA:     ${SA_NAME}"

# ---------------------------------------------------------------------------
# 1. Resource Group
# ---------------------------------------------------------------------------
step "Resource Group: ${RG_NAME}"
if az group show --name "${RG_NAME}" >/dev/null 2>&1; then
  skip "Resource group already exists"
else
  az group create \
    --name "${RG_NAME}" \
    --location "${LOCATION}" \
    --tags environment="${ENV}" project=openclaw managed_by=bootstrap purpose=terraform-state \
    --output none
  ok "Resource group created"
fi

# ---------------------------------------------------------------------------
# 2. Storage Account (org policy: no shared keys, no public network access)
# ---------------------------------------------------------------------------
step "Storage Account: ${SA_NAME}"

# Detect deployer's outbound IP for firewall rules
DEPLOYER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "")
if [[ -z "${DEPLOYER_IP}" ]]; then
  fail "Could not detect deployer IP — needed for storage firewall rule"
fi
echo "Deployer IP: ${DEPLOYER_IP}"

if az storage account show --name "${SA_NAME}" --resource-group "${RG_NAME}" >/dev/null 2>&1; then
  skip "Storage account already exists"
else
  az storage account create \
    --name "${SA_NAME}" \
    --resource-group "${RG_NAME}" \
    --location "${LOCATION}" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --https-only true \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --public-network-access Disabled \
    --tags environment="${ENV}" project=openclaw managed_by=bootstrap purpose=terraform-state \
    --output none
  ok "Storage account created"
fi

# Ensure deployer IP is allowed through the firewall
step "Storage firewall: allow deployer IP"
az storage account network-rule add \
  --account-name "${SA_NAME}" \
  --resource-group "${RG_NAME}" \
  --ip-address "${DEPLOYER_IP}" \
  --output none 2>/dev/null || true
# Enable default deny + allow Azure services
az storage account update \
  --name "${SA_NAME}" \
  --resource-group "${RG_NAME}" \
  --default-action Deny \
  --bypass AzureServices \
  --public-network-access Enabled \
  --output none
ok "Firewall: default deny + deployer IP allowed"

# Grant current user Storage Blob Data Contributor on this account (for Azure AD auth)
step "RBAC: Storage Blob Data Contributor for deployer"
DEPLOYER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
SA_RESOURCE_ID=$(az storage account show --name "${SA_NAME}" --resource-group "${RG_NAME}" --query id -o tsv)

if [[ -n "${DEPLOYER_OID}" ]]; then
  EXISTING_ROLE=$(az role assignment list \
    --assignee "${DEPLOYER_OID}" \
    --scope "${SA_RESOURCE_ID}" \
    --role "Storage Blob Data Contributor" \
    --query "[0].id" -o tsv 2>/dev/null || echo "")
  if [[ -n "${EXISTING_ROLE}" ]]; then
    skip "Storage Blob Data Contributor already assigned"
  else
    az role assignment create \
      --assignee-object-id "${DEPLOYER_OID}" \
      --assignee-principal-type User \
      --role "Storage Blob Data Contributor" \
      --scope "${SA_RESOURCE_ID}" \
      --output none
    ok "Storage Blob Data Contributor assigned to deployer"
    echo "Waiting 30s for RBAC propagation..."
    sleep 30
  fi
else
  echo "WARNING: Could not determine deployer Object ID — RBAC assignment skipped"
  echo "You may need to manually assign Storage Blob Data Contributor on ${SA_NAME}"
fi

# Enable blob versioning (acts as state history / backup)
step "Blob versioning"
VERSIONING=$(az storage account blob-service-properties show \
  --account-name "${SA_NAME}" \
  --resource-group "${RG_NAME}" \
  --query "isVersioningEnabled" -o tsv 2>/dev/null || echo "false")

if [[ "${VERSIONING}" == "true" ]]; then
  skip "Blob versioning already enabled"
else
  az storage account blob-service-properties update \
    --account-name "${SA_NAME}" \
    --resource-group "${RG_NAME}" \
    --enable-versioning true \
    --output none
  ok "Blob versioning enabled"
fi

# ---------------------------------------------------------------------------
# 3. Blob Container (using Azure AD auth — no shared keys)
# ---------------------------------------------------------------------------
step "Blob Container: ${CONTAINER_NAME}"

if az storage container show \
    --name "${CONTAINER_NAME}" \
    --account-name "${SA_NAME}" \
    --auth-mode login >/dev/null 2>&1; then
  skip "Blob container already exists"
else
  az storage container create \
    --name "${CONTAINER_NAME}" \
    --account-name "${SA_NAME}" \
    --auth-mode login \
    --output none
  ok "Blob container created"
fi

# ---------------------------------------------------------------------------
# 4. Delete Lock (prevent accidental deletion of state storage)
# ---------------------------------------------------------------------------
step "Delete Lock"
LOCK_EXISTS=$(az lock list \
  --resource-group "${RG_NAME}" \
  --query "[?name=='do-not-delete-tfstate'].name" -o tsv 2>/dev/null || echo "")

if [[ -n "${LOCK_EXISTS}" ]]; then
  skip "Delete lock already exists"
else
  az lock create \
    --name "do-not-delete-tfstate" \
    --resource-group "${RG_NAME}" \
    --lock-type CanNotDelete \
    --notes "Protects Terraform state backend. Remove only if you are certain." \
    --output none
  ok "Delete lock created on resource group"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Terraform state backend ready${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Backend configuration values:"
echo "  resource_group_name  = ${RG_NAME}"
echo "  storage_account_name = ${SA_NAME}"
echo "  container_name       = ${CONTAINER_NAME}"
echo ""
echo "To migrate existing local state to this backend:"
echo "  cd infra/shared"
echo "  terraform init -migrate-state \\"
echo "    -backend-config=\"resource_group_name=${RG_NAME}\" \\"
echo "    -backend-config=\"storage_account_name=${SA_NAME}\""
echo ""
echo "  cd ../user-app"
echo "  terraform init -migrate-state \\"
echo "    -backend-config=\"resource_group_name=${RG_NAME}\" \\"
echo "    -backend-config=\"storage_account_name=${SA_NAME}\""
