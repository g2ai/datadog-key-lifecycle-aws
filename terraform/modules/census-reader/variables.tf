variable "name_prefix" {
  description = "Prefix for resource names, for example poc-02"
  type        = string
}

variable "trusted_principal_arns" {
  description = "ARN patterns (ArnLike) of principals in this account allowed to assume the census role"
  type        = list(string)

  validation {
    condition     = length(var.trusted_principal_arns) > 0
    error_message = "Give at least one trusted principal ARN pattern."
  }
}
