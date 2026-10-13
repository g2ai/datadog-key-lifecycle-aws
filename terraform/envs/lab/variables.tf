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
