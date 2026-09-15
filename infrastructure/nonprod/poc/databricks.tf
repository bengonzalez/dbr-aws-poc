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