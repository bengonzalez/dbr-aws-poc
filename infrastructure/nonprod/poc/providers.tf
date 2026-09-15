provider "aws" {
  region = var.aws_region
}

provider "databricks" {
  alias      = "mws"
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
}

provider "databricks" {
  alias   = "workspace"
  host    = "https://dbc-b8953b54-e421.cloud.databricks.com"
  profile = var.databricks_profile
}