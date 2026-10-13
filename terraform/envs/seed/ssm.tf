# 1. COPY: key as a plain String parameter
resource "aws_ssm_parameter" "string_copy" {
  name  = "/${local.prefix}/app1/dd_api_key"
  type  = "String"
  value = local.fake["ssm_string"]
}

# 2. COPY: key as a SecureString (encrypted with the AWS managed key aws/ssm)
resource "aws_ssm_parameter" "secure_copy" {
  name  = "/${local.prefix}/app2/dd_api_key"
  type  = "SecureString"
  value = local.fake["ssm_secure"]
}

# 3. REFERENCE: parameter holds a pointer, not the key
resource "aws_ssm_parameter" "string_ref" {
  name  = "/${local.prefix}/agent/dd_api_key_ref"
  type  = "String"
  value = "ENC[${local.ref_secret_arn}]"
}

# 12. COPY in the second region
resource "aws_ssm_parameter" "second_region_copy" {
  provider = aws.second
  name     = "/${local.prefix}/app3/dd_api_key"
  type     = "String"
  value    = local.fake["ssm_second_region"]
}

# D. Decoy: 32 hex value that is NOT a key (a checksum). Census must not report it.
resource "aws_ssm_parameter" "decoy" {
  name  = "/${local.prefix}/build/artifact_md5"
  type  = "String"
  value = random_id.decoy.hex
}

# 13. Step 2.2: a parameter that is "migrated" from a copy to a reference.
# Step 1: apply with app4_migrated = false (parameter holds the key).
# Step 2: change to true and apply again (parameter now holds ENC[...]).
# SSM keeps the old value in parameter history (up to 100 versions).
locals {
  app4_migrated = true
}

resource "aws_ssm_parameter" "migrated" {
  name  = "/${local.prefix}/app4/dd_api_key"
  type  = "SecureString"
  value = local.app4_migrated ? "ENC[${local.ref_secret_arn}]" : local.fake["ssm_migrated"]
}
