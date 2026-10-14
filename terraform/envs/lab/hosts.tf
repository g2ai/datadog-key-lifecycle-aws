# Step 2.5: one host from each AMI. Same instance type, subnet and security group.
# Only the AMI-ref host gets the instance profile: the AMI-baked host carries its key in the image.
# Turn off between test sessions:  terraform apply -var hosts_enabled=false

data "aws_ami" "dd_ref" {
  owners      = ["self"]
  most_recent = true
  filter {
    name   = "tag:Variant"
    values = ["ami-ref"]
  }
}

data "aws_ami" "dd_baked" {
  owners      = ["self"]
  most_recent = true
  filter {
    name   = "tag:Variant"
    values = ["ami-baked"]
  }
}

# No inbound rules at all. The Agent only makes outbound HTTPS calls.
resource "aws_security_group" "hosts" {
  name        = "poc-02-dd-hosts"
  description = "Datadog test hosts: egress only"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "Outbound HTTPS to Datadog and AWS APIs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "poc-02-dd-hosts" }
}

locals {
  hosts = var.hosts_enabled ? {
    ref   = { ami = data.aws_ami.dd_ref.id, profile = module.consumer_access.ec2_instance_profile_name }
    baked = { ami = data.aws_ami.dd_baked.id, profile = null }
  } : {}
}

resource "aws_instance" "dd" {
  for_each = local.hosts

  ami                    = each.value.ami
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.hosts.id]
  iam_instance_profile   = each.value.profile

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = {
    Name    = "poc-02-host-${each.key}"
    Variant = "ami-${each.key}"
  }
}

output "hosts" {
  value = { for k, i in aws_instance.dd : k => { id = i.id, ami = i.ami } }
}
