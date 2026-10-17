# Module: safe-to-rotate (step 3.4)
# EventBridge Scheduler runs a check every check_schedule (prod: 45 days). The check rotates
# only if the key that the rotation will revoke (AWSPREVIOUS) has not been used recently;
# otherwise it holds and alerts. The managed rotation schedule (90 days) stays as a backstop,
# so a hold cannot last forever.
#
# Needs a Datadog application key with ONLY the api_keys_read scope, stored in its own secret.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  fn_name = "${var.name_prefix}-safe-to-rotate"
}

# --- Read-only Datadog app key (api_keys_read) ---

resource "aws_secretsmanager_secret" "keycheck_app_key" {
  name                    = "${var.name_prefix}/datadog-keycheck-app-key"
  description             = "Datadog application key, scope api_keys_read only, for the safe-to-rotate check"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "keycheck_app_key" {
  secret_id                = aws_secretsmanager_secret.keycheck_app_key.id
  secret_string_wo         = var.keycheck_app_key
  secret_string_wo_version = var.values_version
}

# --- Lambda ---

data "archive_file" "fn" {
  type        = "zip"
  source_file = "${path.module}/src/safe_to_rotate.py"
  output_path = "${path.module}/build/safe_to_rotate.zip"
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${local.fn_name}"
  retention_in_days = 3
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fn" {
  name               = local.fn_name
  description        = "Safe-to-rotate check: read key IDs, ask Datadog, rotate or alert"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "fn" {
  statement {
    sid       = "ReadKeyIdAndCurrentKeyAndAppKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.api_key_secret_arn, aws_secretsmanager_secret.keycheck_app_key.arn]
  }
  statement {
    sid       = "SeeUnfinishedRotations"
    actions   = ["secretsmanager:ListSecretVersionIds"]
    resources = [var.api_key_secret_arn]
  }
  statement {
    sid       = "RotateOnlyTheApiKeySecret"
    actions   = ["secretsmanager:RotateSecret"]
    resources = [var.api_key_secret_arn]
  }
  statement {
    sid       = "AlertOnHold"
    actions   = ["sns:Publish"]
    resources = [var.alert_topic_arn]
  }
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.fn.arn}:*"]
  }
}

resource "aws_iam_role_policy" "fn" {
  name   = "safe-to-rotate"
  role   = aws_iam_role.fn.id
  policy = data.aws_iam_policy_document.fn.json
}

resource "aws_lambda_function" "fn" {
  function_name    = local.fn_name
  role             = aws_iam_role.fn.arn
  runtime          = "python3.13"
  handler          = "safe_to_rotate.handler"
  filename         = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      API_KEY_SECRET_ID = var.api_key_secret_arn
      APP_KEY_SECRET_ID = aws_secretsmanager_secret.keycheck_app_key.arn
      DD_SITE           = var.dd_site
      IDLE_MINUTES      = tostring(var.idle_minutes)
      TOPIC_ARN         = var.alert_topic_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.fn, aws_iam_role_policy.fn]
}

# --- EventBridge Scheduler: the regular check ---

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.fn_name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke-safe-to-rotate"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.fn.arn
    }]
  })
}

resource "aws_scheduler_schedule" "check" {
  name                = "${local.fn_name}-check"
  schedule_expression = var.check_schedule
  state               = var.schedule_state
  # A rate() schedule with no start date fires right after it is created. That would run a
  # real rotation check (and maybe a rotation) on every apply that recreates the schedule.
  start_date = var.schedule_start_date

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.fn.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ dry_run = false })
  }
}
