# Module: datadog-secrets
# Purpose: the two managed external secrets for Datadog.
#   admin   (DatadogAdminKey): service account credentials the rotation uses to call Datadog. Never read by consumers.
#   api key (DatadogApiKey)  : the key every consumer reads. This is the one that rotates.
# Values come in through ephemeral variables and write-only arguments, so they never land in plan or state.

resource "aws_secretsmanager_secret" "admin" {
  name                    = "${var.name_prefix}/datadog-admin-key"
  description             = "Datadog service account credentials used by managed rotation"
  type                    = "DatadogAdminKey"
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string_wo = jsonencode({
    adminApiKey      = var.admin_api_key
    adminApiKeyId    = var.admin_api_key_id
    adminAppKey      = var.admin_app_key
    adminAppKeyId    = var.admin_app_key_id
    serviceAccountId = var.service_account_id
    site             = var.site
  })
  # Bump to push new values. Terraform cannot diff a write-only value.
  secret_string_wo_version = var.values_version
}

resource "aws_secretsmanager_secret" "api_key" {
  name                    = "${var.name_prefix}/datadog-api-key"
  description             = "Datadog API key read by all consumers (Agent ENC[], Lambda extension, ECS)"
  type                    = "DatadogApiKey"
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id = aws_secretsmanager_secret.api_key.id
  secret_string_wo = jsonencode({
    apiKey   = var.consumer_api_key
    apiKeyId = var.consumer_api_key_id
  })
  secret_string_wo_version = var.values_version

  # After the first rotation, Secrets Manager owns the value. Terraform must not push the old key back.
  lifecycle {
    ignore_changes = [secret_string_wo_version]
  }
}
