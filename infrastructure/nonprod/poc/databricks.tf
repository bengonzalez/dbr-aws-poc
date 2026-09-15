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