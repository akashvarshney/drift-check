# -----------------------------------------------------------------------------
# Phase 1 Azure resources for the Terraform drift-detection pipeline.
#
# Identical outcome to azure/setup.sh, expressed as code:
#   storage account (private, no shared keys) -> container -> lifecycle
#   -> Entra app + one federated credential per (repo, branch) -> RBAC
# -----------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 1 : 0

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

locals {
  storage_account_name = lower(var.storage_account_name)

  # Scoping RBAC to the container is the least-privilege option: the pipeline
  # can write drift reports and nothing else in the account.
  container_scope = "${azurerm_storage_account.this.id}/blobServices/default/containers/${azurerm_storage_container.drift.name}"
}

resource "azurerm_storage_account" "this" {
  name                = local.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = var.replication_type
  account_kind             = "StorageV2"

  min_tls_version = "TLS1_2"

  # Drift reports can contain sensitive attribute values from terraform plan:
  # never publicly readable, never accessible with a shared key.
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  https_traffic_only_enabled      = true
  public_network_access_enabled   = true

  blob_properties {
    versioning_enabled = true
  }

  tags = var.tags

  depends_on = [azurerm_resource_group.this]
}

resource "azurerm_storage_container" "drift" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Retain reports long enough for Phase 2 to consume them, then expire.
resource "azurerm_storage_management_policy" "drift" {
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "expire-drift-reports"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${var.container_name}/"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.retention_days
      }
    }
  }
}

resource "azuread_application" "drift" {
  display_name     = var.app_display_name
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "drift" {
  client_id = azuread_application.drift.client_id
}

# The OIDC `sub` claim identifies the caller repository, so a shared reusable
# workflow still needs one credential per target repository.
#
# Default subject is the mutable branch format:
#   repo:owner/repo:ref:refs/heads/main
# For repositories on GitHub's immutable subject format, set `subject`
# explicitly per entry (see setup.sh, which detects this automatically):
#   repo:owner@<owner_id>/repo@<repo_id>:ref:refs/heads/main
resource "azuread_application_federated_identity_credential" "repo" {
  for_each = { for repo in var.github_repositories : repo.name => repo }

  application_id = azuread_application.drift.id
  display_name   = substr("gh-${replace(each.value.name, "/", "-")}-${each.value.branch}", 0, 120)
  description    = "GitHub Actions OIDC for ${each.value.name} on ${each.value.branch}"

  audiences = ["api://AzureADTokenExchange"]
  issuer    = "https://token.actions.githubusercontent.com"
  subject   = coalesce(each.value.subject, format("repo:%s:ref:refs/heads/%s", each.value.name, each.value.branch))
}

resource "azurerm_role_assignment" "blob_contributor" {
  scope                = local.container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.drift.object_id
  principal_type       = "ServicePrincipal"
}
