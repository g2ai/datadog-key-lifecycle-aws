# Module: rotation
# Purpose: Secrets Manager rotation role scoped to the admin and API key secret ARNs.

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "rotation" {
  name = "${var.name_prefix}-datadog-rotation"

  # Trust policy: WHO can use this role.
  # Only Secrets Manager, only from this account, only for the API key secret.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "secretsmanager.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike      = { "aws:SourceArn" = var.api_key_secret_arn }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "rotation" {
  name = "${var.name_prefix}-datadog-rotation"
  role = aws_iam_role.rotation.id

  # Permission policy: WHAT this role can do.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read and write the API key secret: this is the secret being rotated.
        Sid    = "RotateApiKeySecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage"
        ]
        Resource = var.api_key_secret_arn
      },
      {
        # Read only the admin secret: its credentials call the Datadog API, but it is never changed here.
        Sid    = "ReadAdminKeySecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue"
        ]
        Resource = var.admin_secret_arn
      }
    ]
  })
}

# Managed external rotation: Secrets Manager calls the Datadog API itself, no Lambda.
resource "aws_secretsmanager_secret_rotation" "api_key" {
  secret_id                         = var.api_key_secret_arn
  external_secret_rotation_role_arn = aws_iam_role.rotation.arn

  external_secret_rotation_metadata {
    key   = "adminSecretArn"
    value = var.admin_secret_arn
  }

  rotation_rules {
    schedule_expression = var.schedule_expression
  }

  # Apply must not create a Datadog key on its own. Rotations are triggered on purpose.
  rotate_immediately = false

  # The role policy must exist before Secrets Manager tries to use the role.
  depends_on = [aws_iam_role_policy.rotation]
}
