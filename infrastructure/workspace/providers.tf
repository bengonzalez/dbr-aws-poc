provider "aws" {
  region = var.cloud.region
}

provider "databricks" {
  alias = "mws"

  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
  profile    = var.databricks_profile
  auth_type  = "databricks-cli"
}