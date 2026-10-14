# Lab environment: wires the three modules. Same modules are reused per account at scale.
data "aws_caller_identity" "current" {}

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

module "datadog_secrets" {
  source      = "../../modules/datadog-secrets"
  name_prefix = "poc-02"

  admin_api_key       = var.dd_admin_api_key
  admin_api_key_id    = var.dd_admin_api_key_id
  admin_app_key       = var.dd_admin_app_key
  admin_app_key_id    = var.dd_admin_app_key_id
  service_account_id  = var.dd_service_account_id
  consumer_api_key    = var.dd_consumer_api_key
  consumer_api_key_id = var.dd_consumer_api_key_id
}

module "rotation" {
  source             = "../../modules/rotation"
  name_prefix        = "poc-02"
  admin_secret_arn   = module.datadog_secrets.admin_secret_arn
  api_key_secret_arn = module.datadog_secrets.api_key_secret_arn
}

output "census_reader_role_arn" {
  value = module.census_reader.role_arn
}

output "ec2_instance_profile_name" {
  value = module.consumer_access.ec2_instance_profile_name
}
