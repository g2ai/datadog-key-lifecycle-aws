provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      project    = "poc-02"
      owner      = "jd"
      managed-by = "terraform"
    }
  }
}
