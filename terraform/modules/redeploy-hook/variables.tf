variable "name_prefix" {
  type = string
}

variable "cluster_name" {
  description = "ECS cluster whose tagged services are redeployed"
  type        = string
}

variable "cluster_arn" {
  type = string
}

variable "secret_name" {
  description = "Secret name to watch (event detail.name), for example poc-02/datadog-api-key"
  type        = string
}

variable "tag_key" {
  type    = string
  default = "DatadogKeyDelivery"
}

variable "tag_value" {
  description = "Services with tag_key = tag_value are redeployed"
  type        = string
  default     = "deploy-time"
}
