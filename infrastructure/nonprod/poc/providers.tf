provider "aws" {
  region = var.aws_region
}

provider "databricks" {
  alias = "mws"

  host = "https://accounts.cloud.databricks.com"
}