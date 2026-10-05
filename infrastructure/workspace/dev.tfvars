workspace = {
  name        = "document-ai-dev"
  environment = "dev"
  isolation   = "dedicated"
}

cloud = {
  provider = "aws"
  region   = "us-east-1"
}

application = {
  name       = "Document AI"
  identifier = "document-ai"
}

ownership = {
  technical_owner = "document-ai-platform"
  business_owner  = "technology"
}

network = {
  strategy     = "custom"
  architecture = "hybrid"

  requirements = {
    vpc = {
      ownership = "existing"
    }

    subnets = {
      ownership = "terraform"

      private = [
        {
          cidr              = "10.20.10.0/24"
          availability_zone = "us-east-1a"
        },
        {
          cidr              = "10.20.11.0/24"
          availability_zone = "us-east-1b"
        }
      ]
    }

    routing = {
      ownership = "existing"
    }

    security_groups = {
      ownership = "terraform"
    }

    endpoints = {
      ownership = "existing"
    }
  }
}

data = {
  classification = "sensitive"
}

encryption = {
  workspace        = "platform_managed"
  application_data = "platform_managed"
}

governance = {
  unity_catalog     = true
  workspace_binding = "optional"
}

compute = {
  policy = "development"
}

logging = {
  level       = "standard"
  centralized = true
  audit       = false
}

validation = {
  required       = true
  blocking       = false
  negative_tests = true
  evidence       = "standard"
}

tags = {
  cost_center = "12345"
}