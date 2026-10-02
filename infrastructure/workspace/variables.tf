variable "workspace" {
  description = "Resolved workspace configuration."

  type = object({
    name        = string
    environment = string
    isolation   = string
  })

  validation {
    condition = (
      contains(["dev", "stage", "live"], var.workspace.environment)
    )

    error_message = "workspace.environment must be dev, stage, or live."
  }

  validation {
    condition = (
      contains(["dedicated"], var.workspace.isolation)
    )

    error_message = "workspace.isolation must be dedicated."
  }
}


variable "cloud" {
  description = "Resolved cloud platform configuration."

  type = object({
    provider = string
    region   = string
  })

  validation {
    condition     = var.cloud.provider == "aws"
    error_message = "Only AWS is currently supported."
  }
}


variable "application" {
  description = "Application associated with the workspace."

  type = object({
    name       = string
    identifier = string
  })
}


variable "ownership" {
  description = "Workspace ownership information."

  type = object({
    technical_owner = string
    business_owner  = string
  })
}


variable "network" {
  description = "Resolved network configuration for the workspace."

  type = object({
    strategy     = string
    architecture = string

    vpc_id             = optional(string)
    private_subnet_ids = optional(list(string))
    security_group_id  = optional(string)
  })

  validation {
    condition = contains(
      ["custom", "isolated"],
      var.network.strategy
    )

    error_message = "network.strategy must be either custom or isolated."
  }

  validation {
    condition = (
      var.network.strategy != "custom" ||
      (
        var.network.vpc_id != null &&
        var.network.private_subnet_ids != null &&
        length(var.network.private_subnet_ids) >= 2 &&
        var.network.security_group_id != null
      )
    )

    error_message = "Custom networking requires vpc_id, at least two private_subnet_ids, and security_group_id."
  }
}


variable "data" {
  description = "Resolved data classification."

  type = object({
    classification = string
  })
}


variable "encryption" {
  description = "Resolved encryption requirements."

  type = object({
    workspace        = string
    application_data = string
  })
}


variable "governance" {
  description = "Resolved Databricks governance configuration."

  type = object({
    unity_catalog     = bool
    workspace_binding = string
  })
}


variable "compute" {
  description = "Resolved compute policy."

  type = object({
    policy = string
  })
}


variable "logging" {
  description = "Resolved logging configuration."

  type = object({
    level       = string
    centralized = bool
    audit       = bool
  })
}


variable "validation" {
  description = "Post-provisioning validation configuration."

  type = object({
    required       = bool
    blocking       = bool
    negative_tests = bool
    evidence       = string
  })
}


variable "tags" {
  description = "Additional resource tags."

  type = map(string)

  default = {}
}