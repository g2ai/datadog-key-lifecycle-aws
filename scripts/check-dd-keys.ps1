# Checks which Datadog API keys are still valid, without printing any key.
# - K1 from ~\poc-secrets (TF_VAR_dd_consumer_api_key, loaded by load-secrets.ps1)
# - AWSCURRENT and AWSPREVIOUS versions of the API key secret
# Output: label, last 4 characters, valid true/false.
param(
  [string]$SecretId = "poc-02/datadog-api-key",
  [string]$Region   = "eu-west-1",
  [string]$Profile  = "poc02",
  [string]$Site     = "datadoghq.eu"
)

function Test-DdKey([string]$Key) {
  try {
    (Invoke-RestMethod -Uri "https://api.$Site/api/v1/validate" -Headers @{ "DD-API-KEY" = $Key }).valid
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    "False (HTTP $code)"
  }
}

function Show([string]$Label, [string]$Key) {
  if ([string]::IsNullOrEmpty($Key)) { "{0,-22} (none)" -f $Label; return }
  "{0,-22} ...{1}  valid: {2}" -f $Label, $Key.Substring($Key.Length - 4), (Test-DdKey $Key)
}

Show "K1 (poc-02-consumer)" $env:TF_VAR_dd_consumer_api_key

foreach ($stage in "AWSCURRENT", "AWSPREVIOUS") {
  $raw = aws secretsmanager get-secret-value --secret-id $SecretId --version-stage $stage --region $Region --profile $Profile --query SecretString --output text 2>$null
  $key = if ($raw) { ($raw | ConvertFrom-Json).apiKey } else { $null }
  Show "secret $stage" $key
  Remove-Variable raw, key -ErrorAction SilentlyContinue
}
