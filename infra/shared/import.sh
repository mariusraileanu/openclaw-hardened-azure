#!/bin/bash
set -e

SUB_ID=$(az account show --query id -o tsv)
ENV=$1
LOCATION=$2
OWNER=$3

RG_NAME="rg-openclaw-${ENV}"
TF_VARS="-var=environment=${ENV} -var=location=${LOCATION} -var=owner_slug=${OWNER}"

import_if_exists() {
  local resource_addr=$1
  local resource_id=$2
  local display_name=$3

  if ! terraform -chdir=infra/shared state list | grep -q "${resource_addr}"; then
    echo "Importing ${display_name}..."
    terraform -chdir=infra/shared import ${TF_VARS} "${resource_addr}" "${resource_id}"
  else
    echo "${display_name} already in state, skipping."
  fi
}

echo "Checking if Resource Group exists..."
if az group show --name $RG_NAME >/dev/null 2>&1; then
  echo "Resource Group exists. Checking terraform state..."

  # Resource Group
  import_if_exists "azurerm_resource_group.shared" \
    "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}" \
    "Resource Group"

  # Virtual Network
  VNET_NAME="vnet-openclaw-${ENV}"
  if az network vnet show --name $VNET_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_virtual_network.shared" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}" \
      "VNet"
  fi

  # CAE Subnet
  SNET_NAME="snet-cae"
  if az network vnet subnet show --name $SNET_NAME --vnet-name $VNET_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_subnet.cae" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${SNET_NAME}" \
      "CAE Subnet"
  fi

  # PE Subnet
  SNET_PE_NAME="snet-pe"
  if az network vnet subnet show --name $SNET_PE_NAME --vnet-name $VNET_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_subnet.pe" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${SNET_PE_NAME}" \
      "PE Subnet"
  fi

  # NSG
  NSG_NAME="nsg-snet-cae-${ENV}"
  if az network nsg show --name $NSG_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_network_security_group.cae" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/networkSecurityGroups/${NSG_NAME}" \
      "NSG"

    import_if_exists "azurerm_subnet_network_security_group_association.cae" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${SNET_NAME}" \
      "NSG-Subnet Association"
  fi

  # Managed Identity
  ID_NAME="id-openclaw-${ENV}"
  if az identity show --name $ID_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_user_assigned_identity.shared" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ID_NAME}" \
      "Managed Identity"
  fi

  # Log Analytics
  LAW_NAME="law-openclaw-${ENV}"
  if az monitor log-analytics workspace show --resource-group $RG_NAME --workspace-name $LAW_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_log_analytics_workspace.shared" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.OperationalInsights/workspaces/${LAW_NAME}" \
      "Log Analytics Workspace"
  fi

  # Container Apps Environment
  CAE_NAME="cae-openclaw-${ENV}"
  CAE_STATE=$(az containerapp env show --name $CAE_NAME --resource-group $RG_NAME --query "properties.provisioningState" -o tsv 2>/dev/null || echo "NotFound")
  if [ "$CAE_STATE" = "Succeeded" ]; then
    import_if_exists "azurerm_container_app_environment.shared" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.App/managedEnvironments/${CAE_NAME}" \
      "Container Apps Environment"
  else
    echo "Container Apps Environment: state=$CAE_STATE, skipping import."
  fi

  # ACR
  ACR_NAME="${ACR_NAME:-acropenclaw${ENV}}"
  if az acr show --name $ACR_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_container_registry.shared" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}" \
      "ACR"
  fi

  # Key Vault
  KV_NAME="kvopenclaw${ENV}"
  if az keyvault show --name $KV_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_key_vault.shared" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.KeyVault/vaults/${KV_NAME}" \
      "Key Vault"
  fi

  # Storage Account (general purpose)
  SA_NAME="${SA_NAME:-stocopenclaw${ENV}}"
  if az storage account show --name $SA_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_storage_account.shared" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}" \
      "Storage Account"
  fi

  # NFS Storage Account
  SA_NFS_NAME="nfsopenclaw${ENV}"
  if az storage account show --name $SA_NFS_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
    import_if_exists "azurerm_storage_account.nfs" \
      "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Storage/storageAccounts/${SA_NFS_NAME}" \
      "NFS Storage Account"
  fi

  # Private DNS Zones
  for dns_zone in "privatelink.vaultcore.azure.net:kv" "privatelink.azurecr.io:acr" "privatelink.file.core.windows.net:file"; do
    ZONE_NAME="${dns_zone%%:*}"
    ZONE_KEY="${dns_zone##*:}"
    if az network private-dns zone show --name $ZONE_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
      import_if_exists "azurerm_private_dns_zone.${ZONE_KEY}" \
        "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/privateDnsZones/${ZONE_NAME}" \
        "Private DNS Zone (${ZONE_NAME})"

      # VNet link
      LINK_NAME="link-${ZONE_KEY}"
      if az network private-dns link vnet show --zone-name $ZONE_NAME --resource-group $RG_NAME --name $LINK_NAME >/dev/null 2>&1; then
        import_if_exists "azurerm_private_dns_zone_virtual_network_link.${ZONE_KEY}" \
          "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/privateDnsZones/${ZONE_NAME}/virtualNetworkLinks/${LINK_NAME}" \
          "DNS VNet Link (${ZONE_KEY})"
      fi
    fi
  done

  # Private Endpoints
  for pe in "pe-kv-${ENV}:kv" "pe-acr-${ENV}:acr" "pe-nfs-${ENV}:nfs"; do
    PE_NAME="${pe%%:*}"
    PE_KEY="${pe##*:}"
    if az network private-endpoint show --name $PE_NAME --resource-group $RG_NAME >/dev/null 2>&1; then
      import_if_exists "azurerm_private_endpoint.${PE_KEY}" \
        "/subscriptions/${SUB_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Network/privateEndpoints/${PE_NAME}" \
        "Private Endpoint (${PE_KEY})"
    fi
  done

fi
