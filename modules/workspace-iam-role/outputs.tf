
output "role_name" {
  description = "Name of the Databricks workspace cross-account IAM role."
  value       = aws_iam_role.cross_account.name
}

output "role_arn" {
  description = "ARN of the Databricks workspace cross-account IAM role."
  value       = aws_iam_role.cross_account.arn
}