output "app_name" {
  description = "Name of the per-user Container App"
  value       = azurerm_container_app.user.name
}

output "app_fqdn" {
  description = "Internal FQDN of the per-user Container App"
  value       = azurerm_container_app.user.ingress[0].fqdn
}

output "app_latest_revision" {
  description = "Latest revision name of the per-user Container App"
  value       = azurerm_container_app.user.latest_revision_name
}

output "user_identity_id" {
  description = "Resource ID of the per-user managed identity (used for KV secret access)"
  value       = azurerm_user_assigned_identity.user.id
}

output "user_identity_principal_id" {
  description = "Principal (object) ID of the per-user managed identity"
  value       = azurerm_user_assigned_identity.user.principal_id
}
