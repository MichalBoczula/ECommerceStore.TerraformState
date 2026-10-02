variable "subscription_id" {
  type        = string
  description = "The single Azure subscription used for this portfolio."
  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription UUID."
  }
}

variable "location" {
  type        = string
  default     = "northeurope"
  description = "Bootstrap and development resource-group region. Confirm before first apply."
}

variable "state_storage_account_name" {
  type        = string
  description = "Existing independently created Azure state account. Terraform reads it only."
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.state_storage_account_name))
    error_message = "Use 3-24 lowercase letters and digits."
  }
}

variable "enable_application_role_assignments" {
  type        = bool
  default     = false
  description = "Enable only when D/7 introduces application Blob/Key Vault role assignments."
}

variable "state_resource_group_name" {
  type        = string
  default     = "rg-ecommerce-terraform-state"
  description = "Existing independently created state resource group."
  validation {
    condition     = !contains(["rg-ecommerce-dev", "rg-ecommerce-bootstrap"], lower(var.state_resource_group_name))
    error_message = "State storage must have its own resource group."
  }
}
