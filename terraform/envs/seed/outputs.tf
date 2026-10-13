# Last 4 characters only, to compare with the census table. Never print full fake keys.
output "expected_copy_last4" {
  value = {
    ssm_string        = substr(local.fake["ssm_string"], 28, 4)
    ssm_secure        = substr(local.fake["ssm_secure"], 28, 4)
    lt_copy           = substr(local.fake["lt_copy"], 28, 4)
    lambda_copy       = substr(local.fake["lambda_copy"], 28, 4)
    ecs_copy          = substr(local.fake["ecs_copy"], 28, 4)
    cfn_copy          = substr(local.fake["cfn_copy"], 28, 4)
    ssm_second_region = substr(local.fake["ssm_second_region"], 28, 4)
    ssm_migrated      = substr(local.fake["ssm_migrated"], 28, 4)
  }
}
