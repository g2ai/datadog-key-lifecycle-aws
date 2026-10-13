variable "region" {
  description = "Main region for seeded locations"
  type        = string
  default     = "eu-west-1"
}

variable "second_region" {
  description = "Second region, proves the census scans all regions"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile. poc02-ro for plan, poc02 for apply"
  type        = string
  default     = "poc02-ro"
}
