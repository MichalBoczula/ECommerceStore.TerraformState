locals {
  subscription_scope = "/subscriptions/${var.subscription_id}"
  common_tags = {
    project   = "ECommerceStore"
    lifecycle = "persistent-bootstrap"
    managedBy = "Terraform"
  }
}

# These resources already exist and are deliberately NOT Terraform-managed.
data "azurerm_resource_group" "state" {
  name = var.state_resource_group_name
}

data "azurerm_storage_account" "state" {
  name                = var.state_storage_account_name
  resource_group_name = data.azurerm_resource_group.state.name
}

resource "azurerm_resource_provider_registration" "required" {
  name = "Microsoft.ManagedIdentity"
  lifecycle { prevent_destroy = true }
}

resource "azurerm_resource_group" "bootstrap" {
  name     = "rg-ecommerce-bootstrap"
  location = var.location
  tags     = local.common_tags
  lifecycle { prevent_destroy = true }
}

# A durable empty shell preserves RG-scoped access after app teardown.
# No Azure lock here: inherited locks would also block child deletion.
resource "azurerm_resource_group" "development" {
  name     = "rg-ecommerce-dev"
  location = var.location
  tags     = merge(local.common_tags, { environment = "development" })
  lifecycle { prevent_destroy = true }
}
