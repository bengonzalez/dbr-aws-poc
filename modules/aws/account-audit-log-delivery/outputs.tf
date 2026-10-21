output "log_bucket_name" {
  description = "S3 bucket every workspace's audit logs on this Databricks account are delivered to."
  value       = aws_s3_bucket.log_delivery.bucket
}
