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

    vpc = object({
      ownership = string
      id        = optional(string)
    })

    subnets = object({
      ownership = string

      private = optional(list(object({
        cidr              = optional(string)
        availability_zone = optional(string)
        id                = optional(string)
      })))
    })

    routing = object({
      ownership = string
    })

    security_groups = object({
      ownership = string
      id        = optional(string)
    })

    endpoints = object({
      ownership = string
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
      var.network.vpc.ownership
    )

    error_message = "VPC ownership must be existing or terraform."
  }

  validation {
    condition = contains(
      ["existing", "terraform"],
      var.network.subnets.ownership
    )

    error_message = "Subnet ownership must be existing or terraform."
  }

  validation {
    condition = contains(
      ["existing", "terraform"],
      var.network.routing.ownership
    )

    error_message = "Routing ownership must be existing or terraform."
  }

  validation {
    condition = contains(
      ["existing", "terraform"],
      var.network.security_groups.ownership
    )

    error_message = "Security group ownership must be existing or terraform."
  }

  validation {
    condition = contains(
      ["existing", "terraform"],
      var.network.endpoints.ownership
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