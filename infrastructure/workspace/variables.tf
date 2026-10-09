variable "databricks_account_id" {
  description = "Databricks account ID used to configure the workspace network."
  type        = string
  sensitive   = true
}

variable "databricks_profile" {
  description = "Databricks CLI authentication profile used for account-level Terraform operations."
  type        = string
}

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

variable "platform" {
  description = "Existing platform infrastructure resolved for the workspace, when network ownership is 'existing'."

  type = object({
    vpc_id          = optional(string)
    route_table_ids = optional(list(string))
  })

  default = {}
}

variable "vpc_ownership_override" {
  description = "Override the VPC ownership implied by network.strategy ('existing' or 'terraform'). Null defers to the strategy default: custom -> existing, isolated -> terraform."
  type        = string
  default     = null

  validation {
    condition     = var.vpc_ownership_override == null || contains(["existing", "terraform"], var.vpc_ownership_override)
    error_message = "vpc_ownership_override must be 'existing', 'terraform', or null."
  }
}

variable "routing_ownership_override" {
  description = "Override the routing ownership implied by network.strategy. Null defers to the strategy default: custom -> existing, isolated -> terraform."
  type        = string
  default     = null

  validation {
    condition     = var.routing_ownership_override == null || contains(["existing", "terraform"], var.routing_ownership_override)
    error_message = "routing_ownership_override must be 'existing', 'terraform', or null."
  }
}

variable "security_group_ownership_override" {
  description = "Override the security group ownership (default: terraform-created in every strategy)."
  type        = string
  default     = null

  validation {
    condition     = var.security_group_ownership_override == null || contains(["existing", "terraform"], var.security_group_ownership_override)
    error_message = "security_group_ownership_override must be 'existing', 'terraform', or null."
  }
}

variable "endpoints_ownership_override" {
  description = "Override the VPC endpoints ownership implied by network.strategy. Null defers to the strategy default: custom -> existing, isolated -> terraform."
  type        = string
  default     = null

  validation {
    condition     = var.endpoints_ownership_override == null || contains(["existing", "terraform"], var.endpoints_ownership_override)
    error_message = "endpoints_ownership_override must be 'existing', 'terraform', or null."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for a new VPC. Required only when VPC ownership resolves to 'terraform'."
  type        = string
  default     = null
}

variable "existing_security_group_id" {
  description = "ID of an existing security group to use, when security group ownership resolves to 'existing'."
  type        = string
  default     = null
}

variable "existing_workspace_storage_key_arn" {
  description = "ARN of an existing KMS key to use for workspace storage instead of creating a dedicated one."
  type        = string
  default     = null
}

variable "existing_workspace_storage_key_alias" {
  description = "Alias name of the existing workspace storage key, if any."
  type        = string
  default     = null
}

variable "existing_managed_services_key_arn" {
  description = "ARN of an existing KMS key to use for managed services instead of creating a dedicated one."
  type        = string
  default     = null
}

variable "existing_managed_services_key_alias" {
  description = "Alias name of the existing managed services key, if any."
  type        = string
  default     = null
}


variable "ownership" {
  description = "Workspace ownership information."

  type = object({
    technical_owner = string
    business_owner  = string
  })
}


variable "network" {
  description = "Resolved network requirements for the workspace."

  type = object({
    strategy     = string
    architecture = string

    requirements = object({
      vpc = object({
        ownership = string
      })

      subnets = object({
        ownership = string

        private = optional(list(object({
          cidr              = string
          availability_zone = string
        })))
      })

      routing = object({
        ownership = string
      })

      security_groups = object({
        ownership = string
      })

      endpoints = object({
        ownership = string
      })
    })
  })

  validation {
    condition = contains(
      ["custom", "isolated"],
      var.network.strategy
    )

    error_message = "network.strategy must be custom or isolated."
  }

  validation {
    condition = contains(
      ["client_managed", "hybrid", "platform_managed"],
      var.network.architecture
    )

    error_message = "network.architecture must be client_managed, hybrid, or platform_managed."
  }

  validation {
    condition = contains(
      ["existing", "terraform"],
      var.network.requirements.vpc.ownership
    )

    error_message = "VPC ownership must be existing or terraform."
  }

  validation {
    condition = contains(
      ["existing", "terraform"],
      var.network.requirements.subnets.ownership
    )

    error_message = "Subnet ownership must be existing or terraform."
  }

  validation {
    condition = contains(
      ["existing", "terraform"],
      var.network.requirements.routing.ownership
    )

    error_message = "Routing ownership must be existing or terraform."
  }

  validation {
    condition = contains(
      ["existing", "terraform"],
      var.network.requirements.security_groups.ownership
    )

    error_message = "Security group ownership must be existing or terraform."
  }

  validation {
    condition = contains(
      ["existing", "terraform"],
      var.network.requirements.endpoints.ownership
    )

    error_message = "Endpoint ownership must be existing or terraform."
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