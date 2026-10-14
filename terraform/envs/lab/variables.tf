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
