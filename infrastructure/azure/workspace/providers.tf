provider "azurerm" {
  features {}
}

# Only used to look up the AzureDatabricks first-party app's per-tenant
# object id for customer-managed keys (modules/azure/workspace-kms). Same
# `az` CLI session as azurerm - no separate auth.
provider "azuread" {}

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

# Account-level provider, needed only for databricks_workspace_network_option
# below (CLAUDE.md §10 backlog item #1a / §8 milestone 40) - its own docs
# say it "can only be used with an account-level provider," unlike every
# other Databricks resource in this root, which uses the workspace-scoped
# provider above. account_id defaults to null when no workspace in this
# root ever sets network_policy_id - a provider block with a null,
# never-dereferenced argument is harmless.
provider "databricks" {
  alias = "mws"

  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  auth_type  = "azure-cli"
}
