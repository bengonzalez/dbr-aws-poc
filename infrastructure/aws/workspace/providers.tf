provider "aws" {
  region = var.cloud.region
}

provider "databricks" {
  alias = "mws"

  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
  profile    = var.databricks_profile

  # A named CLI profile locally; null in CI, where the provider reads
  # DATABRICKS_AUTH_TYPE=env-oidc / DATABRICKS_CLIENT_ID /
  # DATABRICKS_OIDC_TOKEN from the job environment instead (workload
  # identity federation, CLAUDE.md §8 milestone 48).
  auth_type = var.databricks_profile != null ? "databricks-cli" : null
}
