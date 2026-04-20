# ---------------------------------------------------------------------------
# Look up shared resources by name (no Terraform remote state dependency).
# Works regardless of whether shared infra was provisioned by Terraform,
# az CLI, ARM templates, or any other tool.
# ---------------------------------------------------------------------------
data "azurerm_resource_group" "shared" {
  name = var.resource_group_name
}

data "azurerm_key_vault" "shared" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

data "azurerm_container_app_environment" "shared" {
  name                = var.cae_name
  resource_group_name = var.resource_group_name
}

data "azurerm_container_registry" "shared" {
  name                = var.acr_name
  resource_group_name = var.resource_group_name
}

locals {
  app_name        = "ca-openclaw-${var.environment}-${var.user_slug}"
  tavily_enabled  = var.tavily_api_key != ""
  signal_enabled  = var.signal_cli_url != "" && var.signal_bot_number != "" && var.signal_user_phone != ""
  msteams_enabled = var.msteams_enabled && var.msteams_tenant_id != "" && var.msteams_app_id != ""

  # Extract secret name from KV data-plane URL and build an ARM resource ID
  # that azurerm_role_assignment can use as scope.
  # Input:  https://<vault>.vault.azure.net/secrets/<name>
  # Output: /subscriptions/.../Microsoft.KeyVault/vaults/<vault>/secrets/<name>
  msteams_kv_secret_name      = var.msteams_app_password_secret_id != "" ? element(split("/", var.msteams_app_password_secret_id), length(split("/", var.msteams_app_password_secret_id)) - 1) : ""
  msteams_kv_secret_arm_scope = var.msteams_app_password_secret_id != "" ? "${data.azurerm_key_vault.shared.id}/secrets/${local.msteams_kv_secret_name}" : ""

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
      { name = "COMPASS_BASE_URL", value = var.compass_base_url },
      { name = "COMPASS_API_KEY", secretRef = "compass-api-key" },
      { name = "GRAPH_MCP_URL", secretRef = "graph-mcp-url" },
      { name = "USER_SLUG", value = var.user_slug },
      { name = "OPENCLAW_FEATURES_JSON", value = var.openclaw_features_json },
      # Gateway runs on loopback behind the HTTP proxy; token auth is unnecessary.
      { name = "OPENCLAW_FORCE_NO_AUTH", value = "true" },
    ],
    local.tavily_enabled ? [
      { name = "TAVILY_API_KEY", secretRef = "tavily-api-key" },
    ] : [],
    local.signal_enabled ? [
      { name = "SIGNAL_CLI_URL", value = var.signal_cli_url },
      { name = "SIGNAL_PROXY_AUTH_TOKEN", value = var.signal_proxy_auth_token },
      { name = "SIGNAL_BOT_NUMBER", value = var.signal_bot_number },
      { name = "SIGNAL_USER_PHONE", value = var.signal_user_phone },
    ] : [],
    local.msteams_enabled ? [
      { name = "MSTEAMS_APP_ID", value = var.msteams_app_id },
      { name = "MSTEAMS_APP_PASSWORD", secretRef = "msteams-app-password" },
      { name = "MSTEAMS_TENANT_ID", value = var.msteams_tenant_id },
      { name = "MicrosoftAppType", value = "MultiTenant" },
      { name = "MicrosoftAppId", value = var.msteams_app_id },
      { name = "MicrosoftAppPassword", secretRef = "msteams-app-password" },
      { name = "MicrosoftAppTenantId", value = var.msteams_tenant_id },
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
            storageName = var.cae_nfs_storage_name
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

  # Full PATCH body for the Teams receiver app's NFS volume + volumeMount.
  # Same storage path as the main app so Teams and gateway share user state.
}

# ---------------------------------------------------------------------------
# Per-User Managed Identity (used for both ACR pull and KV secret access)
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "user" {
  name                = "id-openclaw-${var.environment}-${var.user_slug}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.shared.name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# ACR Pull: per-user identity can pull images from the shared registry
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "acr_pull" {
  scope                = data.azurerm_container_registry.shared.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.user.principal_id
}

# ---------------------------------------------------------------------------
# Secret expiration: 1 year from initial deployment (KICS finding).
# Uses time_static so the timestamp is fixed at creation time -- subsequent
# terraform apply runs won't recreate secrets with a rolling expiry date.
# ---------------------------------------------------------------------------
resource "time_static" "secret_expiry_base" {}

# ---------------------------------------------------------------------------
# Store per-user secrets in Key Vault
# ---------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "compass_api_key" {
  name            = "${var.user_slug}-compass-api-key"
  value           = var.compass_api_key
  key_vault_id    = data.azurerm_key_vault.shared.id
  content_type    = "text/plain"
  expiration_date = timeadd(time_static.secret_expiry_base.rfc3339, "8760h")
  tags            = local.tags
}

resource "azurerm_key_vault_secret" "graph_mcp_url" {
  name            = "${var.user_slug}-graph-mcp-url"
  value           = var.graph_mcp_url
  key_vault_id    = data.azurerm_key_vault.shared.id
  content_type    = "text/plain"
  expiration_date = timeadd(time_static.secret_expiry_base.rfc3339, "8760h")
  tags            = local.tags
}

resource "azurerm_key_vault_secret" "tavily_api_key" {
  count           = local.tavily_enabled ? 1 : 0
  name            = "${var.user_slug}-tavily-api-key"
  value           = var.tavily_api_key
  key_vault_id    = data.azurerm_key_vault.shared.id
  content_type    = "text/plain"
  expiration_date = timeadd(time_static.secret_expiry_base.rfc3339, "8760h")
  tags            = local.tags
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

resource "azurerm_role_assignment" "kv_secret_tavily" {
  count                = local.tavily_enabled ? 1 : 0
  scope                = azurerm_key_vault_secret.tavily_api_key[0].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.user.principal_id
}

# ---------------------------------------------------------------------------
# Microsoft Teams: grant per-user identity read access to shared bot secret
# ---------------------------------------------------------------------------
# The shared bot password lives in Key Vault (created by shared infra).
# Each user container needs to read it to validate Bot Framework JWTs and
# send replies. The secret ID is passed from shared Terraform outputs.
resource "azurerm_role_assignment" "kv_secret_msteams" {
  count                = local.msteams_enabled ? 1 : 0
  scope                = local.msteams_kv_secret_arm_scope
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
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secret_compass,
    azurerm_role_assignment.kv_secret_graph_mcp,
    azurerm_role_assignment.kv_secret_tavily,
    azurerm_role_assignment.kv_secret_msteams,
  ]

  create_duration = "120s"
}

# ---------------------------------------------------------------------------
# Per-User Container App (isolated, internal-only)
# ---------------------------------------------------------------------------
resource "azurerm_container_app" "user" {
  name                         = local.app_name
  container_app_environment_id = data.azurerm_container_app_environment.shared.id
  resource_group_name          = data.azurerm_resource_group.shared.name
  revision_mode                = "Single"
  tags                         = local.tags

  depends_on = [time_sleep.rbac_propagation]

  lifecycle {
    ignore_changes = [
      template[0].volume,                     # Managed via AzAPI patch (NfsAzureFile not supported by azurerm)
      template[0].container[0].volume_mounts, # Added by AzAPI after creation
      template[0].init_container,             # Init container added by AzAPI patch
      template[0].container[0].startup_probe, # Azure/API may normalize probe ordering/fields after patch
      template[0].container[0].liveness_probe,
      workload_profile_name, # Azure auto-sets to "Consumption"; not in our config
      tags["CreatedDate"],
    ]
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.user.id]
  }

  registry {
    server   = data.azurerm_container_registry.shared.login_server
    identity = azurerm_user_assigned_identity.user.id
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

  dynamic "secret" {
    for_each = local.tavily_enabled ? [1] : []
    content {
      name                = "tavily-api-key"
      key_vault_secret_id = azurerm_key_vault_secret.tavily_api_key[0].versionless_id
      identity            = azurerm_user_assigned_identity.user.id
    }
  }

  dynamic "secret" {
    for_each = local.msteams_enabled ? [1] : []
    content {
      name                = "msteams-app-password"
      key_vault_secret_id = var.msteams_app_password_secret_id
      identity            = azurerm_user_assigned_identity.user.id
    }
  }

  ingress {
    # External so the relay function app can reach it via the VNet-accessible
    # FQDN.  The HTTP path-based proxy on port 18789 routes POST /api/messages
    # to the Teams webhook (port 3978) and everything else to the gateway
    # (port 18790).  allow_insecure is needed because the relay sends plain HTTP.
    external_enabled           = true
    target_port                = 18789
    transport                  = "http"
    allow_insecure_connections = true

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
    # 400 error. The azapi_update_resource.nfs_volume_patch below adds the NFS
    # volume + container volumeMount after creation.

    container {
      name   = "openclaw"
      image  = var.image_ref
      cpu    = var.cpu
      memory = var.memory

      # NOTE: volume_mounts not defined here -- added by AzAPI patch

      env {
        name  = "COMPASS_BASE_URL"
        value = var.compass_base_url
      }

      env {
        name        = "COMPASS_API_KEY"
        secret_name = "compass-api-key"
      }

      env {
        name        = "GRAPH_MCP_URL"
        secret_name = "graph-mcp-url"
      }

      env {
        name  = "USER_SLUG"
        value = var.user_slug
      }

      env {
        name  = "OPENCLAW_FEATURES_JSON"
        value = var.openclaw_features_json
      }

      env {
        name  = "OPENCLAW_FORCE_NO_AUTH"
        value = "true"
      }

      # Tavily API key (only set when tavily_api_key is provided)
      dynamic "env" {
        for_each = local.tavily_enabled ? [1] : []
        content {
          name        = "TAVILY_API_KEY"
          secret_name = "tavily-api-key"
        }
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

      # Microsoft Teams channel config (only set when msteams_enabled is true)
      dynamic "env" {
        for_each = local.msteams_enabled ? [1] : []
        content {
          name  = "MSTEAMS_APP_ID"
          value = var.msteams_app_id
        }
      }

      dynamic "env" {
        for_each = local.msteams_enabled ? [1] : []
        content {
          name        = "MSTEAMS_APP_PASSWORD"
          secret_name = "msteams-app-password"
        }
      }

      dynamic "env" {
        for_each = local.msteams_enabled ? [1] : []
        content {
          name  = "MSTEAMS_TENANT_ID"
          value = var.msteams_tenant_id
        }
      }

      dynamic "env" {
        for_each = local.msteams_enabled ? [1] : []
        content {
          name  = "MicrosoftAppType"
          value = "MultiTenant"
        }
      }

      dynamic "env" {
        for_each = local.msteams_enabled ? [1] : []
        content {
          name  = "MicrosoftAppId"
          value = var.msteams_app_id
        }
      }

      dynamic "env" {
        for_each = local.msteams_enabled ? [1] : []
        content {
          name        = "MicrosoftAppPassword"
          secret_name = "msteams-app-password"
        }
      }

      dynamic "env" {
        for_each = local.msteams_enabled ? [1] : []
        content {
          name  = "MicrosoftAppTenantId"
          value = var.msteams_tenant_id
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
# So we create the container app bare (no volume/mounts), then AzAPI patches in
# the NFS volume and updates the FULL container spec (env vars, probes,
# volumeMounts) via ARM.
# The body is built by jsonencode (local.nfs_patch_body) to guarantee the
# patch never clobbers env vars or probes.
resource "azapi_update_resource" "nfs_volume_patch" {
  type        = "Microsoft.App/containerApps@2024-03-01"
  resource_id = azurerm_container_app.user.id
  body        = local.nfs_patch_body

  lifecycle {
    ignore_changes = [body]
  }

  depends_on = [azurerm_container_app.user]
}

data "azapi_resource" "user_container_template" {
  type        = "Microsoft.App/containerApps@2024-03-01"
  resource_id = azurerm_container_app.user.id

  response_export_values = ["*"]

  depends_on = [azapi_update_resource.nfs_volume_patch]
}

check "user_nfs_mount_present" {
  assert {
    condition     = can(regex("NfsAzureFile", jsonencode(data.azapi_resource.user_container_template.output))) && can(regex("/app/data", jsonencode(data.azapi_resource.user_container_template.output)))
    error_message = "User container app is missing expected NFS volume or mount after AzAPI patch."
  }
}
