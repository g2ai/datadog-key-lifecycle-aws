# Seed: fake Datadog API keys in known places, so the census (step 2.1) can be tested.
# Every value is random and fake. Nothing here can reach Datadog.
# Expected census result: 7 COPY, 4 REFERENCE, 1 HIDDEN, decoy not reported.
# Remove everything with: terraform destroy -var aws_profile=poc02

data "aws_caller_identity" "current" {}

locals {
  prefix = "poc-02-seed"

  # Fake keys: 16 random bytes = 32 hex characters, same shape as a Datadog API key.
  # Generated at apply time, so no key-like string is ever committed.
  fake = { for k, v in random_id.fake : k => v.hex }

  # A secret ARN that does not exist. References only need to look real.
  ref_secret_arn = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:poc-02/datadog-api-key-SEEDREF"
}

resource "random_id" "fake" {
  for_each    = toset(["ssm_string", "ssm_secure", "lt_copy", "lambda_copy", "ecs_copy", "cfn_copy", "cfn_hidden", "ssm_second_region", "ssm_migrated"])
  byte_length = 16
}

resource "random_id" "decoy" {
  byte_length = 16
}
