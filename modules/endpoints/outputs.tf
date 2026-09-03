output "s3_endpoint_id" {
  description = "ID of the S3 VPC endpoint"
  value       = aws_vpc_endpoint.s3.id
}

output "s3_endpoint_arn" {
  description = "ARN of the S3 VPC endpoint"
  value       = aws_vpc_endpoint.s3.arn
}