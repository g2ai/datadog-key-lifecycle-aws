output "ec2_instance_profile_name" {
  description = "Attach to hosts launched from the Datadog AMIs"
  value       = aws_iam_instance_profile.ec2.name
}

output "api_key_secret_arn_pattern" {
  value = local.api_key_secret_arn_pattern
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
}

output "ecs_execution_role_arn" {
  value = aws_iam_role.ecs_execution.arn
}

output "ecs_task_role_arn" {
  description = "ECS B task role (runtime secret read)"
  value       = aws_iam_role.ecs_task_b.arn
}
