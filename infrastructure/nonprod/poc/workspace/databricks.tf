resource "databricks_storage_credential" "data_access" {
  name = "${var.project_name}-data-access"

  aws_iam_role {
    role_arn = var.databricks_data_access_role_arn
  }

  comment = "Unity Catalog storage credential for ${var.project_name} S3 data"
}

resource "databricks_external_location" "data" {
  name = "${var.project_name}-data"

  url = "s3://${var.data_bucket_name}/"

  credential_name = databricks_storage_credential.data_access.name

  comment = "Unity Catalog external location for ${var.project_name} S3 data"

  skip_validation = false
}

resource "databricks_catalog" "poc" {
  name = "${var.project_name}_catalog"

  comment = "Unity Catalog catalog for the ${var.project_name} POC"

  storage_root = "s3://${var.data_bucket_name}/managed/"

  depends_on = [
    databricks_external_location.data
  ]
}

resource "databricks_schema" "poc" {
  catalog_name = databricks_catalog.poc.name
  name         = "poc_schema"

  comment = "Schema for Databricks POC validation"
}

resource "databricks_sql_table" "validation" {
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