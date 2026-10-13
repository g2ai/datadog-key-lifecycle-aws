# Lab environment: wires the three modules. Same modules are reused per account at scale.
data "aws_caller_identity" "current" {}

locals {
  # Placeholder ARNs until the secrets exist (spike 0.5). Replace with resource references then.
  admin_secret_arn   = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:poc-02/datadog-admin-key-AAAAAA"
  api_key_secret_arn = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:poc-02/datadog-api-key-BBBBBB"
}

module "census_reader" {
  source      = "../../modules/census-reader"
  name_prefix = "poc-02"

  # IAM Identity Center roles in this account (both poc02 and poc02-ro permission sets).
  trusted_principal_arns = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_*",
  ]
}

module "consumer_access" {
  source      = "../../modules/consumer-access"
  name_prefix = "poc-02"
}

module "rotation" {
  source             = "../../modules/rotation"
  name_prefix        = "poc-02"
  admin_secret_arn   = local.admin_secret_arn
  api_key_secret_arn = local.api_key_secret_arn
}

output "census_reader_role_arn" {
  value = module.census_reader.role_arn
}
