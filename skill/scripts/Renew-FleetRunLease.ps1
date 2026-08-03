param(
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId,
  [ValidateRange(1, 24)][int]$TtlHours = 24
)

$ErrorActionPreference = 'Stop'
$path = "$env:USERPROFILE\.codex\fleet\run-leases\$RunId.json"
$mutex = New-Object Threading.Mutex($false, 'FleetClaudePromotion')
$hasMutex = $false
$temp = $null
$backup = $null
try {
  $hasMutex = $mutex.WaitOne(0)
  if (-not $hasMutex) { throw 'CLI promotion is active; lease renewal refused.' }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Fleet run lease not found: $RunId" }
  try { $lease = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "Fleet run lease is invalid: $path" }
  if ([string]$lease.run_id -ne $RunId) { throw 'Fleet run lease identity mismatch.' }
  $now = [datetimeoffset]::Now
  $ownerPid = $null; try { if ([int]$lease.owner_pid -gt 0) { $ownerPid = [int]$lease.owner_pid } } catch { }
  $record = [ordered]@{
    schema_version = '1'
    run_id = $RunId
    owner_pid = $ownerPid
    started_at = [string]$lease.started_at
    heartbeat_at = $now.ToString('o')
    expires_at = $now.AddHours($TtlHours).ToString('o')
  }
  $parent = Split-Path -Parent $path
  $temp = Join-Path $parent ('.renew-' + [guid]::NewGuid().ToString('n') + '.json')
  $backup = Join-Path $parent ('.renew-backup-' + [guid]::NewGuid().ToString('n') + '.json')
  [IO.File]::WriteAllText($temp, ($record | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
  [IO.File]::Replace($temp, $path, $backup, $true)
  $temp = $null
  Write-Output $path
}
finally {
  foreach ($file in @($temp, $backup)) { if ($file -and (Test-Path -LiteralPath $file)) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } }
  if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
  $mutex.Dispose()
}
