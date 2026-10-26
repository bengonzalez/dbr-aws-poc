variable "workspace_name" {
  description = "Workspace the handed-over VPC is for. Also names the fixture's resources and the generated handoff file."
  type        = string
  default     = "tsa-shape-proof"
}

variable "environment" {
  description = "Environment of the workspace (dev | stage | live)."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "The two AZs, in order."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Exactly two availability zones are required."
  }
}

variable "primary_cidr" {
  description = "The VPC's unique, routable /27. Keep it clear of 10.64.0.0/10 (the factory's isolated-VPC pool) and other VPCs in the account."
  type        = string
  default     = "10.250.0.0/27"

  validation {
    condition     = endswith(var.primary_cidr, "/27")
    error_message = "primary_cidr must be a /27."
  }
}

variable "secondary_cidr" {
  description = "Non-routable secondary CIDR (the client standard is 100.64.0.0/19)."
  type        = string
  default     = "100.64.0.0/19"
}

variable "create_transit_gateway" {
  description = "Also build a Transit Gateway, its attachment, the /27 static route and the edge default route. Off by default: it adds hourly cost, and with no hub behind it there's still no internet egress."
  type        = bool
  default     = false
}

variable "databricks_account_id" {
  description = "Databricks account id written into the handoff. Empty leaves it blank (the AWS account's inventory default is used)."
  type        = string
  default     = ""
}

variable "databricks_enterprise_tier" {
  description = "Written into the handoff: true | false | unknown."
  type        = string
  default     = "false"
}

variable "handoff_dir" {
  description = "Where to write the filled handoff, relative to this directory."
  type        = string
  default     = "../../../client-handoffs/aws"
}
