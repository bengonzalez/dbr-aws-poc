databricks_account_id = "331f8702-2e00-42e9-82e2-2935e7e1d4f9"
databricks_profile    = "bxg3611 Premium"

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
          cidr              = "172.31.100.0/24"
          availability_zone = "us-east-1a"
        },
        {
          cidr              = "172.31.101.0/24"
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

platform = {
  vpc_id = "vpc-60c2a81d"

  route_table_ids = [
    "rtb-042726c440509ac14",
    "rtb-0e29c295cc93c131c"
  ]
}