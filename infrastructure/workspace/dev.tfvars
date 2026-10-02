workspace = {
  name        = "document-ai-dev"
  environment = "dev"
  isolation   = "dedicated"
}

cloud = {
  provider = "aws"
  region   = "us-east-1"
  account  = "123456789012"
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
  architecture = "client_managed"

  vpc_id = "vpc-xxxxxxxx"

  private_subnet_ids = [
    "subnet-xxxxxxxx",
    "subnet-yyyyyyyy"
  ]

  security_group_id = "sg-xxxxxxxx"
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