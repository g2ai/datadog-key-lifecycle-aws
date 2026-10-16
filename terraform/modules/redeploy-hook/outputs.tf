output "function_name" {
  value = aws_lambda_function.fn.function_name
}

output "rule_name" {
  value = aws_cloudwatch_event_rule.key_changed.name
}
