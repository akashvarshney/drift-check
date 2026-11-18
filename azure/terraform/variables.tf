variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "uksouth"
}

variable "resource_group_name" {
  description = "Resource group that holds the drift-reporting storage account"
  type        = string
  default     = "rg-tf-drift-detection"
}

variable "create_resource_group" {
  description = "Create the resource group (set false to use an existing one)"
  type        = bool
  default     = true
}

variable "storage_account_name" {
  description = "Globally unique storage account name (3-24 chars, lowercase letters and digits)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account names must be 3-24 lowercase alphanumeric characters."
  }
}

variable "container_name" {
  description = "Blob container that receives drift reports"
  type        = string
  default     = "drift-reports"
}

variable "replication_type" {
  description = "Storage replication SKU suffix (LRS, ZRS, GRS, RAGRS)"
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.replication_type)
    error_message = "Use a valid replication type: LRS, ZRS, GRS, RAGRS, GZRS or RAGZRS."
  }
}

variable "retention_days" {
  description = "Days after which a drift report blob is deleted"
  type        = number
  default     = 90
}

variable "app_display_name" {
  description = "Entra ID application used by GitHub Actions OIDC"
  type        = string
  default     = "gh-tf-drift-detection"
}

variable "github_repositories" {
  description = "Repositories allowed to upload drift reports. `subject` overrides the default branch subject (needed for GitHub's immutable subject format)."
  type = list(object({
    name    = string
    branch  = optional(string, "main")
    subject = optional(string)
  }))
  default = [
    { name = "acme-corp/infra-network" },
    { name = "acme-corp/infra-platform" },
  ]
}

variable "tags" {
  description = "Tags applied to taggable resources"
  type        = map(string)
  default = {
    workload = "terraform-drift-detection"
    phase    = "1"
  }
}
