# Module: consumer-access
# Purpose: IAM permissions for consumers to read ONLY the Datadog API key secret.
# This step: EC2 role + instance profile (for hosts launched from the AMIs).
# Lambda role (2.6) and ECS roles (2.7) follow the same rule.

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

# --- Lambda ---

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-dd-lambda"
  description        = "Lambda with Datadog extension: own logs + read the Datadog API key secret"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy" "lambda_read_api_key" {
  name   = "read-datadog-api-key"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.read_api_key.json
}

data "aws_iam_policy_document" "lambda_logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-*:*"]
  }
}

resource "aws_iam_role_policy" "lambda_logs" {
  name   = "own-logs"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_logs.json
}

# --- ECS (Fargate) ---
# Two roles with different jobs:
#   execution role: used by ECS itself to pull the image, write logs and inject "secrets"
#                   at task start (ECS A needs GetSecretValue here).
#   task role:      used by code inside the container (ECS B: the Agent's secrets backend).

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    # Confused deputy guard: only tasks in this account can use these roles.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.name_prefix}-dd-ecs-exec"
  description        = "ECS execution role: own logs + inject the Datadog API key at task start"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "ecs_logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.name_prefix}-*:*"]
  }
}

resource "aws_iam_role_policy" "ecs_execution_logs" {
  name   = "own-logs"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_logs.json
}

# Used only by ECS A (task definition "secrets"). ECS B shares this execution role but
# does not reference the secret there. Trade-off: one role instead of two, noted in docs.
resource "aws_iam_role_policy" "ecs_execution_read_api_key" {
  name   = "read-datadog-api-key"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.read_api_key.json
}

resource "aws_iam_role" "ecs_task_b" {
  name               = "${var.name_prefix}-dd-ecs-task-b"
  description        = "ECS B task role: the Datadog Agent reads the API key secret at runtime"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy" "ecs_task_b_read_api_key" {
  name   = "read-datadog-api-key"
  role   = aws_iam_role.ecs_task_b.id
  policy = data.aws_iam_policy_document.read_api_key.json
}
