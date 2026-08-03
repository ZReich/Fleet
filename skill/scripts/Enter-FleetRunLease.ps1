param(
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId,
  [ValidateRange(1, 24)][int]$TtlHours = 24,
  # Optional stable manager PID. When supplied, a dead owner PID makes the lease
  # reclaimable immediately. THIS SCRIPT is a short-lived process (it exits right
  # after writing the lease), so ITS OWN $PID is never a valid owner — never default
  # owner_pid to $PID here. When -OwnerPid is omitted, default to the PARENT process
  # id instead (the caller that invoked this script and stays alive for the run) so
  # owner_pid stops being permanently null; audit fix 2026-08-03 (every lease on disk
  # had owner_pid:null because no caller ever passed -OwnerPid).
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
    if (Test-FleetLeaseReclaimable $lease $now $StaleHeartbeatHours) {
      Remove-Item -LiteralPath $file.FullName -Force
      # Audit fix 2026-08-03: reclaim already worked structurally (the sweep runs
      # before the same-RunId existence check below), but was silent — nothing
      # distinguished "a stale lease got reclaimed" from "no lease existed at all".
      # Log it once per reclaimed file, on stderr only: callers capture this
      # script's stdout as the single lease-path return value (e.g. `$path = &
      # ...Enter-FleetRunLease.ps1 ...`), and an extra stdout line would silently
      # turn that capture into a multi-element array (same class of bug Fix 1 fixed
      # for Grok heartbeats).
      [Console]::Error.WriteLine("reclaimed expired lease " + [string]$lease.run_id)
    }
  }
  $path = Join-Path $root ($RunId + '.json')
  if (Test-Path -LiteralPath $path) { throw "Fleet run lease already exists: $RunId" }
  # Default owner_pid to the parent (caller) process, never this script's own -
  # this script exits immediately after writing the lease, so its own $PID would
  # read as "dead" on the very next stale-owner check.
  $effectiveOwnerPid = if ($OwnerPid -gt 0) { $OwnerPid } else {
    try { [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch { 0 }
  }
  $record = [ordered]@{
    schema_version = '1'
    run_id = $RunId
    owner_pid = $(if ($effectiveOwnerPid -gt 0) { $effectiveOwnerPid } else { $null })
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
