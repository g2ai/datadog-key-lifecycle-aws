# Launch templates are never used to launch an instance. Only user data matters.

# 4. COPY: key written into the Agent config at boot
resource "aws_launch_template" "copy" {
  name = "${local.prefix}-lt-copy"
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    DD_API_KEY=${local.fake["lt_copy"]} DD_SITE=datadoghq.eu bash -c "echo install agent here"
  USERDATA
  )
}

# 5. REFERENCE: Agent config points at Secrets Manager
resource "aws_launch_template" "ref" {
  name = "${local.prefix}-lt-ref"
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    cat > /etc/datadog-agent/datadog.yaml <<'CFG'
    api_key: ENC[${local.ref_secret_arn}]
    secret_backend_type: aws.secrets
    CFG
  USERDATA
  )
}
