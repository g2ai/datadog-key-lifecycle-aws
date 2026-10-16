variable "region" {
  description = "AWS region for the POC"
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI profile. poc02-ro for plan, poc02 for apply"
  type        = string
  default     = "poc02-ro"
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC"
  type        = string
  default     = "10.20.0.0/16"
}

# --- Datadog values. Set by scripts/load-secrets.ps1 as TF_VAR_* for this shell only. ---
# Ephemeral: Terraform never writes them to plan or state.

variable "dd_admin_api_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "dd_admin_api_key_id" {
  type      = string
  ephemeral = true
}

variable "dd_admin_app_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "dd_admin_app_key_id" {
  type      = string
  ephemeral = true
}

variable "dd_service_account_id" {
  type      = string
  ephemeral = true
}

variable "dd_consumer_api_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "dd_consumer_api_key_id" {
  type      = string
  ephemeral = true
}

variable "alert_email" {
  description = "Email for rotation alerts. Set in terraform.tfvars (git-ignored)."
  type        = string
}

variable "hosts_enabled" {
  description = "Create the two Datadog test hosts and enable the Lambda tick. Default false: turn on per session with -var hosts_enabled=true"
  type        = bool
  default     = false
}

variable "ecs_enabled" {
  description = "Run one Fargate task per ECS variant (A deploy-time, B runtime). Default false: turn on per session with -var ecs_enabled=true"
  type        = bool
  default     = false
}

variable "dd_agent_image" {
  description = "Datadog Agent container image, pinned to the same version as the AMIs"
  type        = string
  default     = "public.ecr.aws/datadog/agent:7.83.1"
}

variable "ecs_secret_refresh_seconds" {
  description = "ECS B: how often the Agent re-reads the API key secret (seconds). Lab: short so rotation tests move fast"
  type        = number
  default     = 600
}

variable "dd_extension_version" {
  description = "Datadog Lambda extension layer version. Must be >= 99 to read the 'apiKey' field of a managed DatadogApiKey secret."
  type        = number
  default     = 101
}

variable "dd_secret_reload_seconds" {
  description = "How often the extension re-reads the API key (seconds, extension v88+). Lab: short so rotation tests move fast."
  type        = number
  default     = 600
}
