# Step 3.5: detect a consumer that lost its key, from two sides.
#
# 1. AWS side: a revoked key means the Agent's data never reaches Datadog, so Datadog cannot
#    alert on the 403 itself. CloudWatch Logs still has the Agent's "API Key invalid" lines.
# 2. Datadog side: the consumer goes silent. A no-data monitor per ECS task family.

# --- 1. CloudWatch: count "API Key invalid" in the ECS Agent logs, alarm to the alerts topic ---

resource "aws_cloudwatch_log_metric_filter" "dd_api_key_invalid" {
  name           = "poc-02-dd-api-key-invalid"
  log_group_name = aws_cloudwatch_log_group.ecs.name
  pattern        = "\"API Key invalid\""

  metric_transformation {
    name          = "AgentApiKeyInvalid"
    namespace     = "poc-02/datadog"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "dd_api_key_invalid" {
  alarm_name          = "poc-02-dd-api-key-invalid"
  alarm_description   = "A Datadog Agent in ECS is sending with a revoked or wrong API key (HTTP 403). Its data is being dropped."
  namespace           = "poc-02/datadog"
  metric_name         = "AgentApiKeyInvalid"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [module.rotation_alerts.topic_arn]
  ok_actions          = [module.rotation_alerts.topic_arn]
}

# --- 2. Datadog: no data from an ECS task family for 10 minutes ---

resource "datadog_monitor" "ecs_agent_silent" {
  name    = "poc-02: Datadog Agent on ECS stopped reporting ({{task_family.name}})"
  type    = "metric alert"
  query   = "avg(last_5m):avg:ecs.fargate.cpu.percent{*} by {task_family} > 1000"
  message = <<-EOT
    No data from ECS task family {{task_family.name}} for 10 minutes.
    Most likely cause in this lab: the task got its Datadog API key at deploy time and the key was revoked by rotation.
    Check CloudWatch Logs /ecs/poc-02-dd for "API Key invalid", then force a new deployment.
    @${var.alert_email}
  EOT

  monitor_thresholds {
    critical = 1000 # never reached: this monitor only alerts on missing data
  }

  # Only watch for silence while the tasks are supposed to run.
  notify_no_data    = var.ecs_enabled
  no_data_timeframe = 10

  tags = ["poc:poc-02", "managed-by:terraform"]
}
