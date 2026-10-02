resource "azurerm_user_assigned_identity" "development" {
  name                = "id-ecommerce-dev-deployment"
  resource_group_name = azurerm_resource_group.bootstrap.name
  location            = azurerm_resource_group.bootstrap.location
  tags                = local.common_tags
  depends_on          = [azurerm_resource_provider_registration.required]
  lifecycle { prevent_destroy = true }
}

resource "azurerm_federated_identity_credential" "development" {
  name                      = "github-development-environment"
  user_assigned_identity_id = azurerm_user_assigned_identity.development.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:MichalBoczula/ECommerceStore.Infrastructure:environment:development"
  lifecycle { prevent_destroy = true }
}

resource "azurerm_role_definition" "development" {
  name              = "ECommerceStore Development Resource Manager"
  scope             = local.subscription_scope
  description       = "Manage dev children; cannot delete the retained RG or manage access/locks. Assigned only on the dev RG."
  assignable_scopes = [azurerm_resource_group.development.id]
  permissions {
    actions = ["*"]
    not_actions = [
      "Microsoft.Authorization/*/Delete",
      "Microsoft.Authorization/*/Write",
      "Microsoft.Authorization/elevateAccess/Action",
      "Microsoft.Resources/subscriptions/resourceGroups/delete",
      "Microsoft.Compute/galleries/share/action",
    ]
    data_actions     = []
    not_data_actions = []
  }
  lifecycle { prevent_destroy = true }
}

resource "azurerm_role_assignment" "development_resources" {
  scope                            = azurerm_resource_group.development.id
  role_definition_id               = azurerm_role_definition.development.role_definition_resource_id
  principal_id                     = azurerm_user_assigned_identity.development.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  lifecycle { prevent_destroy = true }
}

resource "azurerm_role_assignment" "development_state" {
  scope                            = "${data.azurerm_storage_account.state.id}/blobServices/default/containers/development-state"
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.development.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  lifecycle { prevent_destroy = true }
}

resource "azurerm_role_assignment" "development_backend_reader" {
  scope                            = data.azurerm_storage_account.state.id
  role_definition_name             = "Reader"
  principal_id                     = azurerm_user_assigned_identity.development.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  lifecycle { prevent_destroy = true }
}

# Disabled in D/2: the app root currently declares no role assignments.
# D/7 may enable only these two application data roles, only on the dev RG.
resource "azurerm_role_assignment" "application_role_manager" {
  count                            = var.enable_application_role_assignments ? 1 : 0
  scope                            = azurerm_resource_group.development.id
  role_definition_name             = "Role Based Access Control Administrator"
  principal_id                     = azurerm_user_assigned_identity.development.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  condition_version                = "2.0"
  condition                        = <<-EOT
    (
      (!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}))
      OR
      (
        @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 4633458b-17de-408a-b874-0445c86b69e6}
        AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
        AND @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAllOfAllValues:GuidNotEquals {${azurerm_user_assigned_identity.development.principal_id}}
      )
    )
    AND
    (
      (!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}))
      OR
      (
        @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 4633458b-17de-408a-b874-0445c86b69e6}
        AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
        AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] ForAllOfAllValues:GuidNotEquals {${azurerm_user_assigned_identity.development.principal_id}}
      )
    )
  EOT
  lifecycle { prevent_destroy = true }
}
