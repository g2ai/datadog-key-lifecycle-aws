locals {
  seed_tags = {
    project    = "poc-02"
    owner      = "jd"
    managed-by = "terraform"
    Purpose    = "census-seed"
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = local.seed_tags
  }
}

provider "aws" {
  alias   = "second"
  region  = var.second_region
  profile = var.aws_profile

  default_tags {
    tags = local.seed_tags
  }
}
