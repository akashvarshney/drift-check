output "azure_client_id" {
  description = "Set as the AZURE_CLIENT_ID GitHub secret"
  value       = azuread_application.drift.client_id
}

output "azure_tenant_id" {
  description = "Set as the AZURE_TENANT_ID GitHub secret"
  value       = data.azurerm_client_config.current.tenant_id
}

output "azure_subscription_id" {
  description = "Set as the AZURE_SUBSCRIPTION_ID GitHub secret"
  value       = data.azurerm_client_config.current.subscription_id
}

output "storage_account_name" {
  description = "Set as the AZURE_STORAGE_ACCOUNT GitHub secret"
  value       = azurerm_storage_account.this.name
}

output "container_name" {
  description = "Blob container that receives drift reports"
  value       = azurerm_storage_container.drift.name
}

output "container_scope" {
  description = "RBAC scope granted to the GitHub Actions identity"
  value       = local.container_scope
}

output "federated_credential_subjects" {
  description = "Subject claim trusted for each repository"
  value       = { for name, credential in azuread_application_federated_identity_credential.repo : name => credential.subject }
}
