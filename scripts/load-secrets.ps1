# Loads Datadog values from ~\poc-secrets\poc-02.env into TF_VAR_* for THIS PowerShell window only.
# Never prints a value. Run with:  . .\scripts\load-secrets.ps1   (note the leading dot)
param([string]$Path = "$HOME\poc-secrets\poc-02.env")

if (-not (Test-Path $Path)) { Write-Error "Not found: $Path"; return }

$uuid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$checks = @{
  DD_ADMIN_API_KEY       = '^[a-f0-9]{32}$'
  DD_ADMIN_API_KEY_ID    = $uuid
  DD_ADMIN_APP_KEY       = '^ddapp_'
  DD_ADMIN_APP_KEY_ID    = $uuid
  DD_SERVICE_ACCOUNT_ID  = $uuid
  DD_CONSUMER_API_KEY    = '^[a-f0-9]{32}$'
  DD_CONSUMER_API_KEY_ID = $uuid
}

$values = @{}
foreach ($line in Get-Content $Path) {
  if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $values[$Matches[1]] = $Matches[2] }
}

foreach ($name in ($checks.Keys | Sort-Object)) {
  $v = $values[$name]
  if ([string]::IsNullOrEmpty($v)) { $state = 'MISSING' }
  elseif ($v -cmatch $checks[$name]) { $state = 'ok' }
  else { $state = 'WRONG SHAPE' }
  if ($v) { Set-Item -Path ("Env:TF_VAR_" + $name.ToLower()) -Value $v }
  "{0,-24} {1}" -f $name, $state
}
