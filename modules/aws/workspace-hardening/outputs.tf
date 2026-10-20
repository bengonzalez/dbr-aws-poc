output "compliance_security_profile_enabled" {
  description = "Whether Compliance Security Profile (and, with it, Enhanced Security Monitoring/Automatic Cluster Update) is enabled on this workspace."
  value       = length(var.compliance_standards) > 0
}
