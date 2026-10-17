# Module: redeploy-hook (step 3.3)
# When the Datadog API key secret gets a new AWSCURRENT version, force a new deployment of
# ECS services that receive the key at deploy time (task definition "secrets").
#
# Trigger: the native Secrets Manager event "Secret Label Updated" (labelUpdated=AWSCURRENT).
# Native events go to the default bus and do NOT need a CloudTrail trail, unlike the
# CloudTrail-derived "RotationSucceeded" event used by the rotation-alerts module.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  fn_name = "${var.name_prefix}-redeploy-hook"
  acct    = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region
}

data "archive_file" "fn" {
  type        = "zip"
  source_file = "${path.module}/src/redeploy_hook.py"
  output_path = "${path.module}/build/redeploy_hook.zip"
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${local.fn_name}"
  retention_in_days = 3
}

# --- IAM: list/describe services in one cluster, update only its services ---

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fn" {
  name               = local.fn_name
  description        = "Redeploy hook: force new deployment of tagged ECS services in one cluster"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

data "aws_iam_policy_document" "fn" {
  statement {
    sid       = "ListServicesInThisClusterOnly"
    actions   = ["ecs:ListServices"]
    resources = ["*"] # ListServices has no resource ARN; scoped by the condition below
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.cluster_arn]
    }
  }

  statement {
    sid       = "DescribeAndRedeployServicesInThisCluster"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["arn:aws:ecs:${local.region}:${local.acct}:service/${var.cluster_name}/*"]
  }

  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.fn.arn}:*"]
  }
}

resource "aws_iam_role_policy" "fn" {
  name   = "redeploy-tagged-services"
  role   = aws_iam_role.fn.id
  policy = data.aws_iam_policy_document.fn.json
}

resource "aws_lambda_function" "fn" {
  function_name    = local.fn_name
  role             = aws_iam_role.fn.arn
  runtime          = "python3.13"
  handler          = "redeploy_hook.handler"
  filename         = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      CLUSTER   = var.cluster_name
      TAG_KEY   = var.tag_key
      TAG_VALUE = var.tag_value
    }
  }

  depends_on = [aws_cloudwatch_log_group.fn, aws_iam_role_policy.fn]
}

# --- EventBridge: native event, filtered to one secret and the AWSCURRENT label ---

resource "aws_cloudwatch_event_rule" "key_changed" {
  name        = "${var.name_prefix}-redeploy-on-key-change"
  description = "AWSCURRENT moved on ${var.secret_name}: redeploy deploy-time consumers"
  # Explicit, so Terraform notices if someone disables the rule by hand (seen in the lab).
  state = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["Secret Label Updated"]
    detail = {
      name         = [var.secret_name]
      labelUpdated = ["AWSCURRENT"]
    }
  })
}

resource "aws_cloudwatch_event_target" "fn" {
  rule = aws_cloudwatch_event_rule.key_changed.name
  arn  = aws_lambda_function.fn.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridgeKeyChanged"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.key_changed.arn
}
