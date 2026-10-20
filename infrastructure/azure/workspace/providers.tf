provider "azurerm" {
  features {}
}

# Workspace-URL-scoped provider for Unity Catalog, referencing
# module.deployment's own azurerm_databricks_workspace output. This has to
# live here, in the root - Terraform does not allow a non-root module to
# define a provider block referencing a resource it creates (see
# modules/azure-workspace-deployment/main.tf's header comment). auth_type
# = "azure-cli" reuses the already-authenticated `az` session - no
# interactive browser OAuth step and no databricks_profile/
# local.auto.tfvars equivalent needed, unlike the AWS root - validated
# directly against a real Azure subscription (throwaway spike).
provider "databricks" {
  alias     = "workspace"
  host      = "https://${module.deployment.workspace_url}"
  auth_type = "azure-cli"
}
