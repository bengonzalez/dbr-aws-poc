output "vpc_id" {
  description = "VPC used by the workspace."
  value       = data.aws_vpc.workspace.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs created for the workspace."
  value       = aws_subnet.private[*].id
}

output "security_group_id" {
  description = "Workspace Databricks security group ID."
  value       = aws_security_group.workspace.id
}