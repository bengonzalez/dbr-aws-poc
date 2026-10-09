output "vpc_id" {
  description = "VPC used by the workspace (existing or newly created)."
  value       = local.vpc_id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC in use (existing or newly created)."
  value       = local.create_vpc ? aws_vpc.this[0].cidr_block : data.aws_vpc.existing[0].cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs created for the workspace."
  value       = aws_subnet.private[*].id
}

output "route_table_ids" {
  description = "Route table IDs in use for the workspace's private subnets (existing or newly created)."
  value       = local.route_table_ids
}

output "security_group_id" {
  description = "Workspace Databricks security group ID (existing or newly created)."
  value = (
    local.create_security_group ?
    aws_security_group.workspace[0].id : data.aws_security_group.existing[0].id
  )
}
