# Module: consumer-access
# Purpose: IAM permissions for consumers to read ONLY the Datadog API key secret.
# This step: EC2 role + instance profile (for hosts launched from the AMIs).
# Lambda and ECS roles are added in 2.6 / 2.7.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Secrets Manager adds a random 6-character suffix to every secret ARN.
  # Matching the name plus "-??????" lets this policy exist before the secret does,
  # and keeps working if the secret is ever deleted and recreated with the same name.
  api_key_secret_arn_pattern = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.api_key_secret_name}-??????"
}

data "aws_iam_policy_document" "read_api_key" {
  statement {
    sid       = "ReadDatadogApiKeyOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.api_key_secret_arn_pattern]
  }
}

# --- EC2 ---

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.name_prefix}-dd-agent-ec2"
  description        = "Datadog Agent on EC2: read the Datadog API key secret, nothing else"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy" "ec2_read_api_key" {
  name   = "read-datadog-api-key"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.read_api_key.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name_prefix}-dd-agent-ec2"
  role = aws_iam_role.ec2.name
}
