output "function_name" {
  value = aws_lambda_function.fn.function_name
}

output "schedule_name" {
  value = aws_scheduler_schedule.check.name
}
