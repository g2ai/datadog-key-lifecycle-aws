output "admin_secret_arn" {
  value = aws_secretsmanager_secret.admin.arn
}

output "api_key_secret_arn" {
  value = aws_secretsmanager_secret.api_key.arn
}
