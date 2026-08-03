param(
  [ValidateRange(0, 1440)]
  [int]$MinAgeMinutes = 15,
  # Test seam: redirect scan root. Empty = system temp.
  [string]$TempRoot = '',
  # Test seam: when bound (incl. empty array), replaces Get-Process -Name kimi.
  # Entries: @{ Id = <int>; StartTime = <DateTime> }
  [Parameter(Mandatory = $false)]
  [AllowEmptyCollection()]
  [object[]]$LiveKimiInfo
)

$ErrorActionPreference = 'Stop'
$backslash = [string][char]92
if ([string]::IsNullOrWhiteSpace($TempRoot)) {
  $tempRoot = ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd($backslash)
} else {
  $tempRoot = ([IO.Path]::GetFullPath($TempRoot)).TrimEnd($backslash)
}
$cutoff = (Get-Date).AddMinutes(-$MinAgeMinutes)
$removed = 0
$failed = 0
$skippedLive = 0
$skippedUnattributable = 0
$ownerMarkerName = 'owner.json'
$prefix = 'fleet-kimi-k3-'
# Capture at script scope: nested functions do not see caller's PSBoundParameters.
$useLiveKimiOverride = $PSBoundParameters.ContainsKey('LiveKimiInfo')

function Get-LiveKimiInfo {
  if ($useLiveKimiOverride) {
    $out = @()
    foreach ($e in @($LiveKimiInfo)) {
      if ($null -eq $e) { continue }
      $out += [pscustomobject]@{ Id = [int]$e.Id; StartTime = [datetime]$e.StartTime }
    }
    return $out
  }
  $out = @()
  foreach ($k in @(Get-Process -Name 'kimi' -ErrorAction SilentlyContinue)) {
    try {
      $out += [pscustomobject]@{ Id = [int]$k.Id; StartTime = [datetime]$k.StartTime }
    } catch {
      # Unreadable start time: fail-safe sentinel (Id kept, StartTime null).
      $out += [pscustomobject]@{ Id = [int]$k.Id; StartTime = $null }
    }
  }
  return $out
}

function Read-OwnerMarker([string]$RootPath) {
  $markerPath = Join-Path $RootPath $ownerMarkerName
  if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $obj.pid) { return $null }
    $pidVal = [int]$obj.pid
    $startRaw = $obj.start_time
    if ($null -eq $startRaw -or [string]::IsNullOrWhiteSpace([string]$startRaw)) { return $null }
    $start = [datetime]::Parse([string]$startRaw, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    return [pscustomobject]@{ Pid = $pidVal; StartTime = $start }
  } catch {
    return $null
  }
}

function Test-ProcessMatchesOwner([int]$OwnerPid, [datetime]$OwnerStart) {
  try {
    $p = Get-Process -Id $OwnerPid -ErrorAction Stop
  } catch {
    return $false
  }
  try {
    $actual = $p.StartTime
  } catch {
    # Unreadable start time on claimed owner: fail safe (treat live).
    return $true
  }
  # Compare UTC ticks so local/unspecified/round-trip kinds still match.
  return ($actual.ToUniversalTime().Ticks -eq $OwnerStart.ToUniversalTime().Ticks)
}

function Test-IsUnderKimiPrefix([string]$FullPath) {
  $needle = $tempRoot + $backslash + $prefix
  return $FullPath.StartsWith($needle, [StringComparison]::OrdinalIgnoreCase)
}

$liveKimi = @(Get-LiveKimiInfo)
$anyLiveKimi = ($liveKimi.Count -gt 0)
$anyUnreadableLiveStart = $false
foreach ($k in $liveKimi) {
  if ($null -eq $k.StartTime) { $anyUnreadableLiveStart = $true; break }
}

# Unreadable live kimi start times with no per-root markers still fail safe globally
# only when we cannot attribute; per-root owner markers remain authoritative.

Get-ChildItem -LiteralPath $tempRoot -Directory -ErrorAction Stop |
  ForEach-Object {
    $dir = $_
    if ($dir.Name -notlike ($prefix + '*')) { return }
    # Do not traverse reparse points (junctions/symlinks).
    if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }

    $path = [IO.Path]::GetFullPath($dir.FullName)
    if (-not (Test-IsUnderKimiPrefix $path)) {
      throw 'Refusing to clean a path outside the dedicated Fleet Kimi temporary prefix.'
    }

    # Age gate: never remove roots newer than cutoff, markers or not.
    if ($dir.LastWriteTime -gt $cutoff) { return }

    $owner = Read-OwnerMarker -RootPath $path
    if ($null -ne $owner) {
      if (Test-ProcessMatchesOwner -OwnerPid $owner.Pid -OwnerStart $owner.StartTime) {
        $script:skippedLive++
        return
      }
      # Dead pid or recycled pid (mismatched start) -> eligible for delete.
    } else {
      # Legacy unmarked root: only delete when NO kimi process is alive.
      if ($anyLiveKimi) {
        $script:skippedUnattributable++
        return
      }
    }

    try {
      [IO.Directory]::Delete(('\\?\' + $path), $true)
      $script:removed++
    } catch {
      $script:failed++
      $cause = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
      Write-Warning ('Could not remove stale Fleet Kimi runtime: ' + $cause.GetType().Name + ' hresult=' + $cause.HResult + ' message=' + $cause.Message)
    }
  }

$summary = [ordered]@{
  removed = $removed
  failed = $failed
  skipped_live = $skippedLive
  skipped_unattributable = $skippedUnattributable
  min_age_minutes = $MinAgeMinutes
}
if ($removed -eq 0) {
  if ($failed -gt 0) {
    $summary['reason'] = 'delete failures; nothing removed'
  } elseif ($skippedLive -gt 0 -and $skippedUnattributable -gt 0) {
    $summary['reason'] = 'live owned roots and unattributable legacy roots present'
  } elseif ($skippedLive -gt 0) {
    $summary['reason'] = 'live owner process(es) matched marker(s)'
  } elseif ($skippedUnattributable -gt 0) {
    $summary['reason'] = 'unmarked legacy root(s) while kimi process(es) alive'
  } elseif ($anyUnreadableLiveStart) {
    $summary['reason'] = 'live kimi process(es) with unreadable start times'
  } else {
    $summary['reason'] = 'no eligible stale fleet-kimi-k3 roots'
  }
}
$summary | ConvertTo-Json -Compress
if ($failed) { exit 1 }
