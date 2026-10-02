output "development_github_variables" {
  description = "Set these non-secret variables on the Infrastructure repo's development GitHub environment."
  value = {
    AZURE_CLIENT_ID         = azurerm_user_assigned_identity.development.client_id
    AZURE_TENANT_ID         = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID   = var.subscription_id
    TFSTATE_RESOURCE_GROUP  = data.azurerm_resource_group.state.name
    TFSTATE_STORAGE_ACCOUNT = data.azurerm_storage_account.state.name
    TFSTATE_CONTAINER       = "development-state"
  }
}

output "bootstrap_backend" {
  value = {
    resource_group_name  = data.azurerm_resource_group.state.name
    storage_account_name = data.azurerm_storage_account.state.name
    container_name       = "bootstrap-state"
    key                  = "ecommerce/bootstrap.tfstate"
  }
}

output "development_principal_id" {
  value = azurerm_user_assigned_identity.development.principal_id
}

output "development_resource_group_id" {
  value = azurerm_resource_group.development.id
}
