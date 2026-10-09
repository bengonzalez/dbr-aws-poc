output "s3_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "sts_endpoint_id" {
  description = "ID of the STS interface VPC endpoint."
  value       = aws_vpc_endpoint.sts.id
}

output "kms_endpoint_id" {
  description = "ID of the KMS interface VPC endpoint, when created."
  value       = var.enable_kms_endpoint ? aws_vpc_endpoint.kms[0].id : null
}

output "interface_endpoints_security_group_id" {
  description = "Security group used by the workspace's interface VPC endpoints."
  value       = aws_security_group.interface_endpoints.id
}
