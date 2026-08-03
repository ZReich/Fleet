# Reaps orphaned agent child processes (MCP servers and their runtimes).
#
# Every CLI session spawns MCP servers as children and is supposed to take them down on
# exit. It does not always happen: a measured snapshot on 2026-07-31 found 16 live
# jcodemunch-mcp processes, the oldest from the previous afternoon, plus 34 node and 12
# node_repl - 80 processes holding ~6 GB.
#
# SAFETY, because this kills things:
#  - DRY RUN unless -Force. The default prints what it would reap and exits 0.
#  - Orphan-only. A process whose parent is alive is never a candidate.
#  - PID reuse is checked, not assumed: Windows recycles PIDs, so a "live parent" is only
#    believed when the parent STARTED BEFORE the child. A recycled PID whose process began
#    after its supposed child is not that child's parent, and the child is an orphan.
#  - Never reaps this process, its ancestors, or anything younger than -MinAgeMinutes, so
#    a session starting up mid-sweep cannot lose its own server.
#
# Pattern follows Clear-StaleKimiK3Runtime.ps1, which matches an owner marker on pid +
# start time for the same reason.

[CmdletBinding()]
param(
  # Process names to consider. MCP servers only by default: node/python are far more
  # likely to be something the user is actually running.
  [string[]]$Name = @("jcodemunch-mcp"),
  [switch]$Force,
  [ValidateRange(0, 1440)][int]$MinAgeMinutes = 10,
  # SUPERSEDED SIBLINGS (measured 2026-07-31): the real leak was not orphaning. A single
  # codex.exe up since the previous afternoon had spawned TWELVE jcodemunch-mcp children
  # over six hours, never reaping the earlier ones, while claude.exe kept a clean 1:1. An
  # exit-time hook would not have touched it - the parent never exited.
  #
  # Off by default: an MCP client that genuinely holds several concurrent connections to
  # one server would lose live ones. Turn it on only where a single connection per
  # (parent, server) is known to be the contract.
  [switch]$IncludeSuperseded,
  # Machine-readable output goes HERE, not to stdout. Redirecting a native command's stderr
  # in PS 5.1 wraps lines in ErrorRecords rather than dropping them, so `2>$null | ConvertFrom-Json`
  # is not a reliable way to separate the summary from the payload. Same contract as
  # Get-FleetReviewBudget and Get-FleetCodebaseCensus.
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
if ($Name) { $Name = @($Name | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }

# Ancestors of this process are off limits no matter what else is true.
$protected = New-Object 'System.Collections.Generic.HashSet[int]'
$cursor = $PID
for ($i = 0; $i -lt 32 -and $cursor -gt 0; $i++) {
  [void]$protected.Add($cursor)
  $row = Get-CimInstance Win32_Process -Filter "ProcessId = $cursor" -ErrorAction SilentlyContinue
  if (-not $row) { break }
  $cursor = [int]$row.ParentProcessId
}

$all = @{}
foreach ($row in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
  $all[[int]$row.ProcessId] = $row
}

$now = Get-Date
$candidates = @()
$live = @()
foreach ($row in $all.Values) {
  $procName = [IO.Path]::GetFileNameWithoutExtension([string]$row.Name)
  if ($Name -notcontains $procName) { continue }

  $pidValue = [int]$row.ProcessId
  if ($protected.Contains($pidValue)) { continue }

  $started = $row.CreationDate
  if (-not $started) { continue }
  $ageMinutes = ($now - $started).TotalMinutes
  if ($ageMinutes -lt $MinAgeMinutes) { continue }

  $parentPid = [int]$row.ParentProcessId
  $parent = $null
  if ($all.ContainsKey($parentPid)) { $parent = $all[$parentPid] }

  $orphanReason = ""
  if ($null -eq $parent) {
    $orphanReason = "parent pid $parentPid no longer exists"
  }
  elseif ($parent.CreationDate -and $parent.CreationDate -gt $started) {
    # The "parent" started after its child: the PID was recycled and the real parent is gone.
    $orphanReason = "parent pid $parentPid was recycled (started after this child)"
  }
  if (-not $orphanReason) {
    if (-not $IncludeSuperseded) { continue }
    $live += [pscustomobject]@{
      Pid = $pidValue; Name = $procName; ParentPid = $parentPid
      StartedAt = $started; AgeMinutes = [math]::Round($ageMinutes)
      WorkingSetMB = [math]::Round(([int64]$row.WorkingSetSize) / 1MB, 1)
    }
    continue
  }

  $candidates += [pscustomobject]@{
    Pid = $pidValue
    Name = $procName
    StartedAt = $started
    AgeMinutes = [math]::Round($ageMinutes)
    WorkingSetMB = [math]::Round(([int64]$row.WorkingSetSize) / 1MB, 1)
    Reason = $orphanReason
  }
}

if ($IncludeSuperseded) {
  # Keep the newest child per (parent, server name); everything older is superseded.
  foreach ($group in @($live | Group-Object { "$($_.ParentPid)|$($_.Name)" })) {
    $ordered = @($group.Group | Sort-Object StartedAt -Descending)
    if ($ordered.Count -lt 2) { continue }
    $newest = $ordered[0]
    foreach ($stale in $ordered[1..($ordered.Count - 1)]) {
      $candidates += [pscustomobject]@{
        Pid = $stale.Pid
        Name = $stale.Name
        StartedAt = $stale.StartedAt
        AgeMinutes = $stale.AgeMinutes
        WorkingSetMB = $stale.WorkingSetMB
        Reason = "superseded by pid $($newest.Pid) under the same parent $($stale.ParentPid)"
      }
    }
  }
}

$candidates = @($candidates | Sort-Object StartedAt)
$reaped = @()
$failed = @()

if ($Force) {
  foreach ($candidate in $candidates) {
    try {
      Stop-Process -Id $candidate.Pid -Force -ErrorAction Stop
      $reaped += $candidate
    }
    catch { $failed += [pscustomobject]@{ Pid = $candidate.Pid; Error = $_.Exception.Message } }
  }
}

$freedMB = [math]::Round((@($candidates | Measure-Object WorkingSetMB -Sum).Sum), 1)
$result = [ordered]@{
  schema_version = "1"
  mode = $(if ($Force) { "reap" } else { "dry-run" })
  names = $Name
  min_age_minutes = $MinAgeMinutes
  candidates = @($candidates)
  reaped_count = $reaped.Count
  failed = @($failed)
  reclaimable_mb = $freedMB
}
$json = $result | ConvertTo-Json -Depth 5
if ($OutputPath) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
  [IO.File]::WriteAllText($OutputPath, $json, (New-Object Text.UTF8Encoding($false)))
}
else {
  # Only when there is no file to read: otherwise stdout carries the human summary alone,
  # so a caller never has to separate payload from prose. Writing the summary to stderr was
  # tried and reverted - PS 5.1 turns a native command's stderr into terminating
  # ErrorRecords under ErrorActionPreference=Stop, breaking every caller that redirects.
  Write-Output $json
}

$verb = if ($Force) { "reaped: $($reaped.Count)" } else { "would reap: $($candidates.Count) (dry run, pass -Force)" }
if ($OutputPath) {
  Write-Host "agent-runtime: candidates: $($candidates.Count) | $verb | failed: $($failed.Count) | reclaimable: $freedMB MB"
}
if ($failed.Count) { exit 1 } else { exit 0 }
