# Stacks with one free placeholder resource. Only the parameters matter.

locals {
  cfn_template = {
    copy = jsonencode({
      Parameters = { DdApiKey = { Type = "String" } }
      Resources  = { Placeholder = { Type = "AWS::CloudFormation::WaitConditionHandle" } }
    })
    hidden = jsonencode({
      Parameters = { DdApiKey = { Type = "String", NoEcho = true } }
      Resources  = { Placeholder = { Type = "AWS::CloudFormation::WaitConditionHandle" } }
    })
  }
}

# 10. COPY: parameter value visible in DescribeStacks
resource "aws_cloudformation_stack" "copy" {
  name          = "${local.prefix}-copy"
  template_body = local.cfn_template.copy
  parameters    = { DdApiKey = local.fake["cfn_copy"] }
}

# 11. HIDDEN: NoEcho, DescribeStacks shows ****
resource "aws_cloudformation_stack" "hidden" {
  name          = "${local.prefix}-hidden"
  template_body = local.cfn_template.hidden
  parameters    = { DdApiKey = local.fake["cfn_hidden"] }

  # AWS returns **** for NoEcho, so Terraform sees a change on every plan. Ignore it.
  lifecycle {
    ignore_changes = [parameters]
  }
}
