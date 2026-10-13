# Key-free Agent config. The image holds a reference, never the key.
site: datadoghq.eu

# DatadogApiKey managed secret value is JSON {"apiKey": "...", "apiKeyId": "..."}.
api_key: ENC[${secret_name};apiKey]

secret_backend_type: aws.secrets
secret_backend_config:
  aws_session:
    aws_region: ${region}

# Pull the current key every hour without a restart (Agent 7.67+).
secret_refresh_interval: 3600
# If Datadog rejects the key (403), refresh at most every 10 minutes (Agent 7.74+).
secret_refresh_on_api_key_failure_interval: 10
