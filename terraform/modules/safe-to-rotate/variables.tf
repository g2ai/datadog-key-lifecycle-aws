variable "name_prefix" {
  type = string
}

variable "api_key_secret_arn" {
  type = string
}

variable "alert_topic_arn" {
  description = "SNS topic for HOLD alerts (the rotation-alerts topic)"
  type        = string
}

variable "dd_site" {
  type    = string
  default = "datadoghq.eu"
}

variable "idle_minutes" {
  description = "HOLD if the AWSPREVIOUS key was used within this many minutes. Datadog date_last_used is rounded down to the hour: use >= 120. Prod: 1440 (1 day)"
  type        = number
  default     = 1440
}

variable "check_schedule" {
  description = "How often the check runs. Policy 'no key older than 90 days' with two live keys = 45 days"
  type        = string
  default     = "rate(45 days)"
}

variable "schedule_state" {
  type    = string
  default = "ENABLED"
}

variable "schedule_start_date" {
  description = "RFC 3339 time of the first check (prod: set it, for example the next planned rotation date). null = fires right after creation"
  type        = string
  default     = null
}

variable "values_version" {
  description = "Increase to write a new app key value"
  type        = number
  default     = 1
}

variable "keycheck_app_key" {
  description = "Datadog application key with only the api_keys_read scope"
  type        = string
  ephemeral   = true
  sensitive   = true
}
