variable "name_prefix" {
  description = "Prefix for resource names, for example poc-02"
  type        = string
}

variable "api_key_secret_name" {
  description = "Name of the Datadog API key secret. Same name in every account, so one AMI works everywhere."
  type        = string
  default     = "poc-02/datadog-api-key"
}
