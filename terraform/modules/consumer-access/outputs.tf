output "ec2_instance_profile_name" {
  description = "Attach to hosts launched from the Datadog AMIs"
  value       = aws_iam_instance_profile.ec2.name
}

output "api_key_secret_arn_pattern" {
  value = local.api_key_secret_arn_pattern
}
