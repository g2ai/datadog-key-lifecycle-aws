output "role_arn" {
  description = "ARN of the rotation role, passed to aws_secretsmanager_secret_rotation"
  value       = aws_iam_role.rotation.arn
}
