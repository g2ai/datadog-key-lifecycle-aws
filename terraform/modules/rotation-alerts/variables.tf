variable "name_prefix" {
  type = string
}

variable "alert_email" {
  description = "Where alerts go. Kept out of the repo: set in terraform.tfvars (git-ignored) or TF_VAR_alert_email."
  type        = string
}

variable "notify_on_success" {
  description = "Also email on RotationSucceeded. Useful in the lab to prove the pipeline; turn off in production."
  type        = bool
  default     = true
}
