output "databricks_role_name" {
  description = "Name of the Databricks IAM role"
  value       = aws_iam_role.databricks.name
}

output "databricks_role_arn" {
  description = "ARN of the Databricks IAM role"
  value       = aws_iam_role.databricks.arn
}
output "databricks_workspace_role_arn" {
  description = "ARN of the Databricks workspace cross-account IAM role"
  value       = aws_iam_role.databricks_workspace.arn
}

output "databricks_data_access_role_arn" {
  description = "ARN of the Databricks Unity Catalog S3 data access IAM role"

  value = aws_iam_role.databricks_data_access.arn
}