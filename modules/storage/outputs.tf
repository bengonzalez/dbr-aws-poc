output "data_bucket_id" {
  description = "Name of the S3 data bucket"
  value       = aws_s3_bucket.data.id
}

output "data_bucket_arn" {
  description = "ARN of the S3 data bucket"
  value       = aws_s3_bucket.data.arn
}

output "root_bucket_id" {
  description = "Name of the Databricks workspace root S3 bucket"
  value       = aws_s3_bucket.root.id
}

output "root_bucket_arn" {
  description = "ARN of the Databricks workspace root S3 bucket"
  value       = aws_s3_bucket.root.arn
}