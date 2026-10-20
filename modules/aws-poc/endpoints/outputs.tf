output "s3_endpoint_id" {
  description = "ID of the S3 VPC endpoint"
  value       = aws_vpc_endpoint.s3.id
}

output "s3_endpoint_arn" {
  description = "ARN of the S3 VPC endpoint"
  value       = aws_vpc_endpoint.s3.arn
}

output "kms_endpoint_id" {
  description = "ID of the KMS VPC endpoint"
  value       = aws_vpc_endpoint.kms.id
}

output "endpoint_security_group_id" {
  description = "Security group ID used by interface VPC endpoints"
  value       = aws_security_group.interface_endpoints.id
}