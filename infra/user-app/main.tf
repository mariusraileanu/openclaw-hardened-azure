data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Read shared module outputs from remote state (no naming convention coupling)
# ---------------------------------------------------------------------------
data "terraform_remote_state" "shared" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.tf_state_resource_group
    storage_account_name = var.tf_state_storage_account
    container_name       = "tfstate"
    key                  = "shared.tfstate"
  }
}

locals {
  shared = data.terraform_remote_state.shared.outputs

  app_name       = "ca-openclaw-${var.user_slug}"
  signal_enabled = var.signal_cli_url != "" && var.signal_bot_number != "" && var.signal_user_phone != ""

  tags = {
    environment = var.environment
    user        = var.user_slug
    project     = "openclaw"
    managed_by  = "terraform"
  }

  # Full container env array for the NFS volume PATCH (must mirror the env
  # blocks in azurerm_container_app.user so the REST PATCH doesn't clobber them).
  container_env = concat(
    [
      { name = "COMPASS_API_KEY", secretRef = "compass-api-key" },
      { name = "GRAPH_MCP_URL", secretRef = "graph-mcp-url" },
      { name = "OPENCLAW_GATEWAY_AUTH_TOKEN", secretRef = "gateway-token" },
      { name = "USER_SLUG", value = var.user_slug },
    ],
    local.signal_enabled ? [
      { name = "SIGNAL_CLI_URL", value = var.signal_cli_url },
      { name = "SIGNAL_PROXY_AUTH_TOKEN", value = var.signal_proxy_auth_token },
      { name = "SIGNAL_BOT_NUMBER", value = var.signal_bot_number },
      { name = "SIGNAL_USER_PHONE", value = var.signal_user_phone },
    ] : []
  )

  # Full PATCH body for the NFS volume + volumeMount + complete container spec.
  # Built via jsonencode so env vars, probes, and volumeMounts are never lost.
  # Includes an init container that runs as root to create the per-user
  # subdirectory on the NFS share and chown it to UID 1000 (app user).
  nfs_patch_body = jsonencode({
    properties = {
      template = {
        volumes = [
          {
            name        = "data"
            storageName = "openclaw-nfs"
            storageType = "NfsAzureFile"
          }
        ]
        initContainers = [
          {
            name    = "init-nfs-dir"
            image   = "alpine:3"
            command = ["/bin/sh", "-c", "mkdir -p /mnt/${var.user_slug} && chown 1000:1000 /mnt/${var.user_slug} && echo 'NFS dir ready for ${var.user_slug}'"]
            resources = {
              cpu    = 0.25
              memory = "0.5Gi"
            }
            volumeMounts = [
              {
                volumeName = "data"
                mountPath  = "/mnt"
              }
            ]
          }
        ]
        containers = [
          {
            name  = "openclaw"
            image = var.image_ref
            resources = {
              cpu    = var.cpu
              memory = var.memory
            }
            env = local.container_env
            volumeMounts = [
              {
                volumeName = "data"
                mountPath  = "/app/data"
              }
            ]
            probes = [
              {
                type = "Startup"
                tcpSocket = {
                  port = 18789
                }
                periodSeconds    = 6
                timeoutSeconds   = 3
                failureThreshold = 10
              },
              {
                type = "Liveness"
                tcpSocket = {
                  port = 18789
                }
                initialDelaySeconds = 1
                periodSeconds       = 30
                timeoutSeconds      = 5
                failureThreshold    = 3
              }
            ]
          }
        ]
      }
    }
  })
}

# ---------------------------------------------------------------------------
# Per-User Managed Identity (KV secret access only; ACR pull uses shared identity)
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "user" {
  name                = "id-openclaw-${var.user_slug}-${var.environment}"
  location            = var.location
  resource_group_name = local.shared.resource_group_name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# Store per-user secrets in Key Vault
# ---------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "compass_api_key" {
  name         = "${var.user_slug}-compass-api-key"
  value        = var.compass_api_key
  key_vault_id = local.shared.key_vault_id
  tags         = local.tags
}

resource "azurerm_key_vault_secret" "graph_mcp_url" {
  name         = "${var.user_slug}-graph-mcp-url"
  value        = var.graph_mcp_url
  key_vault_id = local.shared.key_vault_id
  tags         = local.tags
}

resource "azurerm_key_vault_secret" "gateway_token" {
  name         = "${var.user_slug}-gateway-token"
  value        = var.openclaw_gateway_auth_token
  key_vault_id = local.shared.key_vault_id
  tags         = local.tags
}

# ---------------------------------------------------------------------------
# Per-secret RBAC: user identity can only read its own secrets
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "kv_secret_compass" {
  scope                = azurerm_key_vault_secret.compass_api_key.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.user.principal_id
}

resource "azurerm_role_assignment" "kv_secret_graph_mcp" {
  scope                = azurerm_key_vault_secret.graph_mcp_url.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.user.principal_id
}

resource "azurerm_role_assignment" "kv_secret_gateway" {
  scope                = azurerm_key_vault_secret.gateway_token.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.user.principal_id
}

# ---------------------------------------------------------------------------
# Wait for Azure AD RBAC propagation before the container app tries to pull
# secrets with the per-user identity. Role assignments are eventually-consistent
# and can take up to 5-10 minutes; 120s covers the common case.
# ---------------------------------------------------------------------------
resource "time_sleep" "rbac_propagation" {
  depends_on = [
    azurerm_role_assignment.kv_secret_compass,
    azurerm_role_assignment.kv_secret_graph_mcp,
    azurerm_role_assignment.kv_secret_gateway,
  ]

  create_duration = "120s"
}

# ---------------------------------------------------------------------------
# Per-User Container App (isolated, internal-only)
# ---------------------------------------------------------------------------
resource "azurerm_container_app" "user" {
  name                         = local.app_name
  container_app_environment_id = local.shared.cae_id
  resource_group_name          = local.shared.resource_group_name
  revision_mode                = "Single"
  tags                         = local.tags

  depends_on = [time_sleep.rbac_propagation]

  lifecycle {
    ignore_changes = [
      template[0].volume,                     # Managed via null_resource.nfs_volume_patch (NfsAzureFile not supported by azurerm)
      template[0].container[0].volume_mounts, # Added by null_resource after creation
      template[0].init_container,             # Init container added by null_resource patch
      workload_profile_name,                  # Azure auto-sets to "Consumption"; not in our config
    ]
  }

  identity {
    type = "UserAssigned"
    identity_ids = [
      local.shared.managed_identity_id,       # ACR pull (shared)
      azurerm_user_assigned_identity.user.id, # KV secrets (per-user)
    ]
  }

  registry {
    server   = local.shared.acr_login_server
    identity = local.shared.managed_identity_id
  }

  secret {
    name                = "compass-api-key"
    key_vault_secret_id = azurerm_key_vault_secret.compass_api_key.versionless_id
    identity            = azurerm_user_assigned_identity.user.id
  }

  secret {
    name                = "graph-mcp-url"
    key_vault_secret_id = azurerm_key_vault_secret.graph_mcp_url.versionless_id
    identity            = azurerm_user_assigned_identity.user.id
  }

  secret {
    name                = "gateway-token"
    key_vault_secret_id = azurerm_key_vault_secret.gateway_token.versionless_id
    identity            = azurerm_user_assigned_identity.user.id
  }

  ingress {
    external_enabled = false
    target_port      = 18789
    transport        = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    # NOTE: volume is NOT defined here. The azurerm provider only supports
    # "AzureFile" but the CAE storage mount is NfsAzureFile, which causes a
    # 400 error. The null_resource.nfs_volume_patch below adds the NFS volume
    # + container volumeMount via REST API after creation.

    container {
      name   = "openclaw"
      image  = var.image_ref
      cpu    = var.cpu
      memory = var.memory

      # NOTE: volume_mounts not defined here — added by null_resource patch

      env {
        name        = "COMPASS_API_KEY"
        secret_name = "compass-api-key"
      }

      env {
        name        = "GRAPH_MCP_URL"
        secret_name = "graph-mcp-url"
      }

      env {
        name        = "OPENCLAW_GATEWAY_AUTH_TOKEN"
        secret_name = "gateway-token"
      }

      env {
        name  = "USER_SLUG"
        value = var.user_slug
      }

      # Signal channel config (only set when all three Signal variables are provided)
      dynamic "env" {
        for_each = local.signal_enabled ? [1] : []
        content {
          name  = "SIGNAL_CLI_URL"
          value = var.signal_cli_url
        }
      }

      dynamic "env" {
        for_each = local.signal_enabled ? [1] : []
        content {
          name  = "SIGNAL_PROXY_AUTH_TOKEN"
          value = var.signal_proxy_auth_token
        }
      }

      dynamic "env" {
        for_each = local.signal_enabled ? [1] : []
        content {
          name  = "SIGNAL_BOT_NUMBER"
          value = var.signal_bot_number
        }
      }

      dynamic "env" {
        for_each = local.signal_enabled ? [1] : []
        content {
          name  = "SIGNAL_USER_PHONE"
          value = var.signal_user_phone
        }
      }

      # Startup probe: generous failure threshold for gateway initialization
      # 10 * 6s = 60s max startup time (max failure_count_threshold is 10)
      startup_probe {
        transport = "TCP"
        port      = 18789

        interval_seconds        = 6
        timeout                 = 3
        failure_count_threshold = 10
      }

      # Liveness probe: restart if gateway becomes unresponsive
      liveness_probe {
        transport = "TCP"
        port      = 18789

        initial_delay           = 1
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Patch: add NfsAzureFile volume + container volumeMount via REST API
# ---------------------------------------------------------------------------
# The azurerm provider cannot create a container app with NfsAzureFile volumes
# (only supports "AzureFile", but the CAE storage is registered as NfsAzureFile).
# So we create the container app bare (no volume/mounts), then this
# null_resource patches in the NFS volume and updates the FULL container spec
# (env vars, probes, volumeMounts) via a single atomic REST PATCH.
# The body is built by jsonencode (local.nfs_patch_body) to guarantee the
# patch never clobbers env vars or probes.
resource "null_resource" "nfs_volume_patch" {
  triggers = {
    app_id         = azurerm_container_app.user.id
    user_slug      = var.user_slug
    signal_enabled = local.signal_enabled
    # Force re-run when the patch body changes (e.g. new env vars, image, etc.)
    patch_hash = sha256(local.nfs_patch_body)
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for any in-progress provisioning to complete
      for i in $(seq 1 30); do
        state=$(az containerapp show --ids ${azurerm_container_app.user.id} --query "properties.provisioningState" -o tsv 2>/dev/null)
        if [ "$state" = "Succeeded" ] || [ "$state" = "Failed" ]; then break; fi
        sleep 10
      done

      # Write the patch body to a temp file (avoids shell quoting issues)
      cat > /tmp/nfs-patch-${var.user_slug}.json <<'PATCH_EOF'
${local.nfs_patch_body}
PATCH_EOF

      az rest --method PATCH \
        --uri "${azurerm_container_app.user.id}?api-version=2024-03-01" \
        --body @/tmp/nfs-patch-${var.user_slug}.json \
        --output none

      rm -f /tmp/nfs-patch-${var.user_slug}.json
    EOT
  }

  depends_on = [azurerm_container_app.user]
}
