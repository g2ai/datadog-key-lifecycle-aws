# AMI pair for the rotation test (step 2.3).
#   ref   : Agent + datadog.yaml with api_key: ENC[...]. No key in the image. Never rebuilt for rotation.
#   baked : Agent + datadog.yaml with the key value written in. The anti-pattern, built only to show it breaking.
# Build one at a time:
#   packer build -only="ref.*" .
#   packer build -only="baked.*" .   (needs PKR_VAR_dd_api_key, after the trial starts)

packer {
  required_version = ">= 1.16.0"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.8"
    }
  }
}

variable "aws_profile" {
  type    = string
  default = "poc02"
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "agent_version" {
  description = "Exact Agent RPM version, pinned"
  type        = string
  default     = "7.83.1-1"
}

variable "secret_name" {
  description = "Secrets Manager secret name. A name (not an ARN) lets the same AMI work in every account."
  type        = string
  default     = "poc-02/datadog-api-key"
}

variable "dd_api_key" {
  description = "Only for the baked build. Pass through PKR_VAR_dd_api_key, never in a file."
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  stamp = formatdate("YYYYMMDD-hhmm", timestamp())
  tags = {
    project    = "poc-02"
    owner      = "jd"
    managed-by = "packer"
  }
}

source "amazon-ebs" "al2023" {
  profile       = var.aws_profile
  region        = var.region
  instance_type = "t3.micro"

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-*-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  # Lab VPC public subnet. Packer opens SSH only to this laptop's public IP.
  subnet_filter {
    filters = { "tag:Name" = "poc-02-public-0" }
  }
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  ssh_username = "ec2-user"

  run_tags        = local.tags
  run_volume_tags = local.tags
}

build {
  name = "ref"

  source "source.amazon-ebs.al2023" {
    ami_name      = "poc-02-dd-agent-ref-${local.stamp}"
    tags          = merge(local.tags, { Variant = "ami-ref", AgentVersion = var.agent_version, SourceAMI = "{{ .SourceAMI }}" })
    snapshot_tags = merge(local.tags, { Variant = "ami-ref" })
  }

  provisioner "shell" {
    script           = "scripts/install-agent.sh"
    environment_vars = ["AGENT_VERSION=${var.agent_version}"]
    execute_command  = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
  }

  provisioner "file" {
    content     = templatefile("files/datadog-ref.yaml.tpl", { secret_name = var.secret_name, region = var.region })
    destination = "/tmp/datadog.yaml"
  }

  provisioner "shell" {
    script          = "scripts/finalize.sh"
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output = "manifest-ref.json"
  }
}

build {
  name = "baked"

  source "source.amazon-ebs.al2023" {
    ami_name      = "poc-02-dd-agent-baked-${local.stamp}"
    tags          = merge(local.tags, { Variant = "ami-baked", AgentVersion = var.agent_version, SourceAMI = "{{ .SourceAMI }}" })
    snapshot_tags = merge(local.tags, { Variant = "ami-baked" })
  }

  provisioner "shell" {
    script           = "scripts/install-agent.sh"
    environment_vars = ["AGENT_VERSION=${var.agent_version}"]
    execute_command  = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
  }

  provisioner "shell" {
    inline = ["test -n \"$DD_API_KEY\" || { echo 'PKR_VAR_dd_api_key is empty'; exit 1; }",
    "printf 'site: datadoghq.eu\\napi_key: %s\\n' \"$DD_API_KEY\" > /tmp/datadog.yaml"]
    environment_vars = ["DD_API_KEY=${var.dd_api_key}"]
  }

  provisioner "shell" {
    script          = "scripts/finalize.sh"
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output = "manifest-baked.json"
  }
}
