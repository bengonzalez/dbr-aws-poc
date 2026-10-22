terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }

    time = {
      source = "hashicorp/time"
    }

    databricks = {
      source = "databricks/databricks"

      configuration_aliases = [
        databricks.mws
      ]
    }
  }
}
