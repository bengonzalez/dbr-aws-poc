provider "aws" {
  region = var.cloud.region
}

provider "databricks" {
  alias = "mws"
}