param(
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId,
  [ValidateRange(1, 24)][int]$TtlHours = 24,
  # Optional stable manager PID. When supplied, a dead owner PID makes the lease
  # reclaimable immediately. These scripts run as short-lived processes, so their own
  # $PID is NOT a valid owner — never default owner_pid to it.
  [int]$OwnerPid = 0,
  # A live run renews hourly; a heartbeat older than 2x that is genuinely abandoned.
  [ValidateRange(1, 24)][int]$StaleHeartbeatHours = 2
)

$ErrorActionPreference = 'Stop'
$root = "$env:USERPROFILE\.codex\fleet\run-leases"
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')

$mutex = New-Object Threading.Mutex($false, 'FleetClaudePromotion')
$hasMutex = $false
try {
  $hasMutex = $mutex.WaitOne(0)
  if (-not $hasMutex) { throw 'CLI promotion is active; Fleet run cannot start until it completes.' }
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $now = [datetimeoffset]::Now
  foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    try { $lease = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid Fleet run lease blocks dispatch: $($file.FullName)" }
    if (Test-FleetLeaseReclaimable $lease $now $StaleHeartbeatHours) { Remove-Item -LiteralPath $file.FullName -Force }
  }
  $path = Join-Path $root ($RunId + '.json')
  if (Test-Path -LiteralPath $path) { throw "Fleet run lease already exists: $RunId" }
  $record = [ordered]@{
    schema_version = '1'
    run_id = $RunId
    owner_pid = $(if ($OwnerPid -gt 0) { $OwnerPid } else { $null })
    started_at = $now.ToString('o')
    heartbeat_at = $now.ToString('o')
    expires_at = $now.AddHours($TtlHours).ToString('o')
  }
  $temp = Join-Path $root ('.lease-' + [guid]::NewGuid().ToString('n') + '.json')
  try {
    [IO.File]::WriteAllText($temp, ($record | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::Move($temp, $path)
  }
  finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
  Write-Output $path
}
finally {
  if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
  $mutex.Dispose()
}
