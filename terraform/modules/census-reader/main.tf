# Module: census-reader
# Purpose: Read-only IAM role the census CLI assumes in each account (step 2.1).
# Reads metadata and config values where keys hide. Never reads secret values.
# Same module is deployed in every account; only trusted_principal_arns changes.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# Trust: principals in this account whose ARN matches one of the patterns.
# Lab: the IAM Identity Center roles. At scale: one role in a central tooling account.
data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "AllowListedPrincipals"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = var.trusted_principal_arns
    }
  }
}

data "aws_iam_policy_document" "census" {
  statement {
    sid       = "Regions"
    effect    = "Allow"
    actions   = ["ec2:DescribeRegions"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadKeyLocations"
    effect = "Allow"
    actions = [
      "ssm:DescribeParameters",
      "ssm:GetParameters",
      "ssm:GetParameterHistory",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "lambda:ListFunctions",
      "ecs:ListTaskDefinitions",
      "ecs:DescribeTaskDefinition",
      "cloudformation:DescribeStacks",
      "cloudformation:ListStacks", # DescribeStacks without a stack name is authorized as ListStacks
      "secretsmanager:ListSecrets",
    ]
    resources = ["*"]
  }

  # Needed to read SecureString parameters. Only when the call comes through SSM.
  statement {
    sid       = "DecryptViaSsmOnly"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["ssm.*.amazonaws.com"]
    }
  }

  # Belt and braces: even if someone attaches a broader policy later,
  # this role can never read a secret value.
  statement {
    sid    = "NeverReadSecretValues"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:BatchGetSecretValue",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "census_reader" {
  name                 = "${var.name_prefix}-census-reader"
  description          = "Census CLI: finds Datadog key copies and references. Read only, no secret values."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "census" {
  name   = "census-read"
  role   = aws_iam_role.census_reader.id
  policy = data.aws_iam_policy_document.census.json
}
