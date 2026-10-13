variable "name_prefix" {
  description = "Prefix for resource names, for example poc-02"
  type        = string
}

variable "admin_secret_arn" {
  description = "ARN of the DatadogAdminKey secret (admin credentials used to rotate the API key)"
  type        = string
}

variable "api_key_secret_arn" {
  description = "ARN of the DatadogApiKey secret (the key that gets rotated)"
  type        = string
}
