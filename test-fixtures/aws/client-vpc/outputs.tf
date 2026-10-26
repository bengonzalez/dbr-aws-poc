output "handoff_file" {
  description = "The filled handoff this fixture wrote."
  value       = abspath(local_file.handoff.filename)
}

output "vpc_id" {
  value = aws_vpc.this.id
}
