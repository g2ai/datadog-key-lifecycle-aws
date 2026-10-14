output "topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "rule_name" {
  value = aws_cloudwatch_event_rule.rotation.name
}
