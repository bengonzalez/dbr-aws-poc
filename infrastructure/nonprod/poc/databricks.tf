########################################################
#
# Unity Catalog Storage Credential
#
########################################################

resource "databricks_storage_credential" "data_access" {
  provider = databricks.workspace

  name = "${var.project_name}-data-access"

  aws_iam_role {
    role_arn = module.security.databricks_data_access_role_arn
  }

  comment = "Unity Catalog storage credential for ${var.project_name} S3 data"
}

########################################################
#
# Unity Catalog External Location
#
########################################################

resource "databricks_external_location" "data" {
  provider        = databricks.workspace
  name            = "${var.project_name}-data"
  url             = "s3://${module.storage.data_bucket_id}/"
  credential_name = databricks_storage_credential.data_access.name
  comment         = "Unity Catalog external location for ${var.project_name} S3 data"
  skip_validation = false
}

########################################################
#
# Unity Catalog POC Catalog
#
########################################################

resource "databricks_catalog" "poc" {
  provider = databricks.workspace

  name    = "${var.project_name}_catalog"
  comment = "Unity Catalog catalog for the ${var.project_name} POC"

  storage_root = "s3://${module.storage.data_bucket_id}/managed/"
}

########################################################
#
# Unity Catalog POC Schema
#
########################################################

resource "databricks_schema" "poc" {
  provider = databricks.workspace

  catalog_name = databricks_catalog.poc.name
  name         = "poc_schema"
  comment      = "Schema for Databricks POC validation"
}

########################################################
#
# Unity Catalog Managed Validation Table
#
########################################################

resource "databricks_sql_table" "validation" {
  provider = databricks.workspace

  name               = "validation_table"
  catalog_name       = databricks_catalog.poc.name
  schema_name        = databricks_schema.poc.name
  table_type         = "MANAGED"
  data_source_format = "DELTA"

  column {
    name = "id"
    type = "INT"
  }

  column {
    name = "message"
    type = "STRING"
  }
}