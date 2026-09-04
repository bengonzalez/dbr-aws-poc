data "aws_caller_identity" "current" {}

/*
For our initial POC, we're using EC2 as the trusted service 
because Databricks classic compute ultimately runs on AWS compute resources.

Important: this is an initial POC trust relationship. 
We will revisit the exact Databricks trust configuration 
when we integrate the actual Databricks workspace. 
I don't want us to prematurely lock the architecture 
to an incorrect Databricks-specific trust relationship.
*/

data "aws_iam_policy_document" "databricks_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "databricks" {
  name = "${var.project_name}-databricks-role"

  assume_role_policy = data.aws_iam_policy_document.databricks_assume_role.json

  tags = {
    Name    = "${var.project_name}-databricks-role"
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "databricks_s3" {
  statement {
    effect = "Allow"

    actions = [
      "s3:ListBucket"
    ]

    resources = [
      var.data_bucket_arn
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      "${var.data_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_policy" "databricks_s3" {
  name        = "${var.project_name}-databricks-s3"
  description = "S3 access for ${var.project_name} Databricks"

  policy = data.aws_iam_policy_document.databricks_s3.json
}

resource "aws_iam_role_policy_attachment" "databricks_s3" {
  role       = aws_iam_role.databricks.name
  policy_arn = aws_iam_policy.databricks_s3.arn
}

data "aws_iam_policy_document" "databricks_kms" {
  statement {
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = [
      var.kms_key_arn
    ]
  }
}

resource "aws_iam_policy" "databricks_kms" {
  name        = "${var.project_name}-databricks-kms"
  description = "KMS access for ${var.project_name} Databricks"

  policy = data.aws_iam_policy_document.databricks_kms.json
}

resource "aws_iam_role_policy_attachment" "databricks_kms" {
  role       = aws_iam_role.databricks.name
  policy_arn = aws_iam_policy.databricks_kms.arn
}

data "aws_iam_policy_document" "databricks_workspace_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type = "AWS"

      identifiers = [
        "arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL"
      ]
    }

    actions = [
      "sts:AssumeRole"
    ]

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"

      values = [
        var.databricks_account_id
      ]
    }
  }
}

resource "aws_iam_role" "databricks_workspace" {
  name = "${var.project_name}-workspace-role"

  assume_role_policy = data.aws_iam_policy_document.databricks_workspace_assume_role.json

  tags = {
    Name    = "${var.project_name}-workspace-role"
    Project = var.project_name
  }
}

data "aws_iam_policy_document" "databricks_workspace_permissions" {
  statement {
    sid    = "NonResourceBasedPermissions"
    effect = "Allow"

    actions = [
      "ec2:AssignPrivateIpAddresses",
      "ec2:CancelSpotInstanceRequests",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeIamInstanceProfileAssociations",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstances",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeNatGateways",
      "ec2:DescribeNetworkAcls",
      "ec2:DescribePrefixLists",
      "ec2:DescribeReservedInstancesOfferings",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotInstanceRequests",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:DescribeVolumes",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeVpcs",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:GetSpotPlacementScores",
      "ec2:RequestSpotInstances",
      "ec2:DescribeFleetHistory",
      "ec2:ModifyFleet",
      "ec2:DeleteFleets",
      "ec2:DescribeFleetInstances",
      "ec2:DescribeFleets",
      "ec2:CreateFleet",
      "ec2:DeleteLaunchTemplate",
      "ec2:GetLaunchTemplateData",
      "ec2:CreateLaunchTemplate",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:ModifyLaunchTemplate",
      "ec2:DeleteLaunchTemplateVersions",
      "ec2:CreateLaunchTemplateVersion"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "InstancePoolsSupport"
    effect = "Allow"

    actions = [
      "ec2:AssociateIamInstanceProfile",
      "ec2:DisassociateIamInstanceProfile",
      "ec2:ReplaceIamInstanceProfileAssociation"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Vendor"
      values   = ["Databricks"]
    }
  }

  statement {
    sid    = "AllowEc2RunInstancePerTag"
    effect = "Allow"

    actions = [
      "ec2:RunInstances"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Vendor"
      values   = ["Databricks"]
    }
  }

  statement {
    sid    = "AllowEc2RunInstanceImagePerTag"
    effect = "Allow"

    actions = [
      "ec2:RunInstances"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:image/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Vendor"
      values   = ["Databricks"]
    }
  }

  statement {
    sid    = "AllowEc2RunInstancePerVPCid"
    effect = "Allow"

    actions = [
      "ec2:RunInstances"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:Vpc"
      values = [
        "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc/${var.vpc_id}"
      ]
    }
  }

  statement {
    sid    = "AllowEc2RunInstanceOtherResources"
    effect = "Allow"

    actions = [
      "ec2:RunInstances"
    ]

    not_resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:image/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
    ]
  }

  statement {
    sid    = "EC2TerminateInstancesTag"
    effect = "Allow"

    actions = [
      "ec2:TerminateInstances"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Vendor"
      values   = ["Databricks"]
    }
  }

  statement {
    sid    = "EC2AttachDetachVolumeTag"
    effect = "Allow"

    actions = [
      "ec2:AttachVolume",
      "ec2:DetachVolume"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Vendor"
      values   = ["Databricks"]
    }
  }

  statement {
    sid    = "EC2CreateVolumeByTag"
    effect = "Allow"

    actions = [
      "ec2:CreateVolume"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Vendor"
      values   = ["Databricks"]
    }
  }

  statement {
    sid    = "EC2DeleteVolumeByTag"
    effect = "Allow"

    actions = [
      "ec2:DeleteVolume"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Vendor"
      values   = ["Databricks"]
    }
  }

  statement {
    effect = "Allow"

    actions = [
      "iam:CreateServiceLinkedRole",
      "iam:PutRolePolicy"
    ]

    resources = [
      "arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
    ]

    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values   = ["spot.amazonaws.com"]
    }
  }

  statement {
    sid    = "VpcNonresourceSpecificActions"
    effect = "Allow"

    actions = [
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/${var.databricks_security_group_id}"
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:Vpc"
      values = [
        "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc/${var.vpc_id}"
      ]
    }
  }
}

resource "aws_iam_role_policy" "databricks_workspace_permissions" {
  name = "${var.project_name}-workspace-permissions"

  role = aws_iam_role.databricks_workspace.id

  policy = data.aws_iam_policy_document.databricks_workspace_permissions.json
}