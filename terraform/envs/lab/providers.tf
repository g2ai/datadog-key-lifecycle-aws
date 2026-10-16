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

# Datadog provider for monitors (step 3.5). The app key has only monitors_read + monitors_write.
# Values are ephemeral variables: never written to plan or state.
provider "datadog" {
  api_url = "https://api.datadoghq.eu/"
  api_key = var.dd_admin_api_key
  app_key = var.dd_monitors_app_key
}
