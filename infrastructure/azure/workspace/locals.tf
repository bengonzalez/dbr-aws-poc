locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy   = "terraform"
      Platform    = "databricks"
      Environment = var.workspace.environment
      Workspace   = var.workspace.name
      Application = var.application.identifier
    }
  )

  # Azure storage account names: <=24 chars, lowercase alphanumeric only -
  # derived from the workspace name plus a slice of the live subscription
  # id (from data.azurerm_client_config.current, not a passed-in variable -
  # same "derive from the provider's own identity" posture AWS's UC bucket
  # naming uses via data.aws_caller_identity.current). Known limitation:
  # not guaranteed globally unique across subscriptions/tenants - revisit
  # if that ever actually collides.
  storage_account_name = "st${lower(substr(replace(var.workspace.name, "-", ""), 0, 10))}${substr(data.azurerm_client_config.current.subscription_id, 0, 8)}"
}
