# Module: rotation-alerts
# Purpose: email when a Secrets Manager rotation fails (and, optionally, when it succeeds).
# Rotation events are CloudTrail *service* events: detail-type "AWS Service Event via CloudTrail".

locals {
  event_names = concat(
    ["RotationFailed", "RotationAbandoned"],
    var.notify_on_success ? ["RotationSucceeded"] : []
  )
}

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-rotation-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
  # AWS sends a confirmation mail. The subscription stays "PendingConfirmation" until the link is clicked.
}

resource "aws_cloudwatch_event_rule" "rotation" {
  name        = "${var.name_prefix}-secret-rotation-events"
  description = "Secrets Manager rotation outcome for any secret in this account and region"
  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["AWS Service Event via CloudTrail"]
    detail        = { eventName = local.event_names }
  })
}

resource "aws_cloudwatch_event_target" "sns" {
  rule = aws_cloudwatch_event_rule.rotation.name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      event  = "$.detail.eventName"
      region = "$.region"
      time   = "$.time"
    }
    input_template = "\"Secrets Manager <event> in <region> at <time> (UTC). Details (secret name, error if any): CloudTrail event history.\""
  }
}

# Only EventBridge, and only this rule, may publish to the topic.
data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "AllowRotationRuleOnly"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.rotation.arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.topic.json
}
