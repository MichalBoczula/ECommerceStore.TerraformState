mock_provider "azurerm" {
  override_during = plan
  override_resource {
    target = azurerm_resource_group.bootstrap
    values = { id = "/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-ecommerce-bootstrap" }
  }
  override_resource {
    target = azurerm_resource_group.development
    values = { id = "/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-ecommerce-dev" }
  }
  mock_data "azurerm_storage_account" {
    defaults = { id = "/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-ecommerce-terraform-state/providers/Microsoft.Storage/storageAccounts/stecomtfmocktest" }
  }
  mock_resource "azurerm_role_definition" {
    defaults = {
      role_definition_id          = "66666666-6666-6666-6666-666666666666"
      role_definition_resource_id = "/subscriptions/33333333-3333-3333-3333-333333333333/providers/Microsoft.Authorization/roleDefinitions/66666666-6666-6666-6666-666666666666"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "22222222-2222-2222-2222-222222222222"
      object_id = "44444444-4444-4444-4444-444444444444"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-ecommerce-bootstrap/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ecommerce-dev-deployment"
      principal_id = "11111111-1111-1111-1111-111111111111"
      client_id    = "55555555-5555-5555-5555-555555555555"
    }
  }
}

variables {
  subscription_id            = "33333333-3333-3333-3333-333333333333"
  state_storage_account_name = "stecomtfmocktest"
}

run "scoped_access_and_storage" {
  command = plan

  assert {
    condition     = azurerm_role_assignment.development_resources.scope == azurerm_resource_group.development.id
    error_message = "Deployment management access must be scoped to the retained development group."
  }
  assert {
    condition     = azurerm_resource_group.development.id != azurerm_resource_group.bootstrap.id
    error_message = "Application and state storage management scopes must be distinct."
  }
  assert {
    condition     = contains(azurerm_role_definition.development.permissions[0].not_actions, "Microsoft.Resources/subscriptions/resourceGroups/delete")
    error_message = "Deployment role must not delete the retained resource group."
  }
  assert {
    condition     = azurerm_role_assignment.development_state.scope == "${data.azurerm_storage_account.state.id}/blobServices/default/containers/development-state"
    error_message = "Deployment state access must be limited to the dev container."
  }
  assert {
    condition     = azurerm_role_assignment.development_backend_reader.role_definition_name == "Reader"
    error_message = "The deployment identity may only read backend management metadata."
  }
  assert {
    condition     = !strcontains(data.azurerm_storage_account.state.id, "/resourceGroups/rg-ecommerce-dev/") && !strcontains(data.azurerm_storage_account.state.id, "/resourceGroups/rg-ecommerce-bootstrap/")
    error_message = "The external state account must remain outside both Terraform-managed groups."
  }
  assert {
    condition     = azurerm_federated_identity_credential.development.subject == "repo:MichalBoczula/ECommerceStore.Infrastructure:environment:development"
    error_message = "OIDC federation must match the development repo and GitHub environment."
  }
  assert {
    condition     = length(azurerm_role_assignment.application_role_manager) == 0
    error_message = "No application role-assignment privilege is needed in D2."
  }
}

run "optional_role_assignment_boundaries" {
  command = plan
  variables { enable_application_role_assignments = true }
  assert {
    condition     = azurerm_role_assignment.application_role_manager[0].scope == azurerm_resource_group.development.id && azurerm_role_assignment.application_role_manager[0].condition_version == "2.0"
    error_message = "Future role assignment delegation must remain conditional and RG-scoped."
  }
  assert {
    condition     = strcontains(azurerm_role_assignment.application_role_manager[0].condition, "GuidNotEquals {11111111-1111-1111-1111-111111111111}") && !strcontains(azurerm_role_assignment.application_role_manager[0].condition, "8e3af657-a8ff-443c-a75c-2fe8c4bcb635")
    error_message = "Do not delegate Owner grants or self-grants to the deployment identity."
  }
}
