variable "name_prefix" {
  type = string
}

variable "site" {
  type    = string
  default = "datadoghq.eu"
}

variable "recovery_window_in_days" {
  description = "0 deletes at once (lets the lab recreate the same name). 7-30 keeps a recovery window."
  type        = number
  default     = 7
}

variable "values_version" {
  description = "Increase to write new values to the secrets"
  type        = number
  default     = 1
}

# --- Ephemeral inputs: never stored in plan or state ---

variable "admin_api_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "admin_api_key_id" {
  type      = string
  ephemeral = true
}

variable "admin_app_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "admin_app_key_id" {
  type      = string
  ephemeral = true
}

variable "service_account_id" {
  type      = string
  ephemeral = true
}

variable "consumer_api_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "consumer_api_key_id" {
  type      = string
  ephemeral = true
}
