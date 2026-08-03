# Focused regression suite for Clear-StaleKimiK3Runtime owner-marker fail-safe.
# Case/Assert-True style matches Test-FleetContract.ps1.
$ErrorActionPreference = 'Stop'
$passed = 0; $failed = 0; $skipped = 0
function Case([string]$n, [scriptblock]$b) {
  try { & $b; $script:passed++; Write-Host "PASS $n" }
  catch { $script:failed++; Write-Host "FAIL $n - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }

$scriptPath = Join-Path $PSScriptRoot 'Clear-StaleKimiK3Runtime.ps1'
$backslash = [string][char]92

function New-TestRoot {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('fleet-stale-test-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  return $root
}

function Set-RuntimeAge([string]$Dir, [datetime]$LastWrite) {
  $item = Get-Item -LiteralPath $Dir
  $item.LastWriteTime = $LastWrite
  $item.CreationTime = $LastWrite
  # Child writes can refresh parent mtime; re-apply after markers.
  foreach ($child in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
    try { $child.LastWriteTime = $LastWrite } catch { }
  }
  $item = Get-Item -LiteralPath $Dir
  $item.LastWriteTime = $LastWrite
}

function New-RuntimeDir([string]$Parent, [string]$Suffix, [datetime]$LastWrite) {
  $dir = Join-Path $Parent ('fleet-kimi-k3-' + $Suffix)
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $dir 'probe.txt') -Value 'x' -Encoding ASCII
  Set-RuntimeAge -Dir $dir -LastWrite $LastWrite
  return $dir
}

function Write-OwnerMarker([string]$Root, [int]$OwnerPid, [datetime]$StartTime, [datetime]$Age = [datetime]::MinValue) {
  $payload = [ordered]@{
    pid = $OwnerPid
    start_time = $StartTime.ToString('o')
  } | ConvertTo-Json -Compress
  Set-Content -LiteralPath (Join-Path $Root 'owner.json') -Value $payload -Encoding UTF8
  if ($Age -ne [datetime]::MinValue) { Set-RuntimeAge -Dir $Root -LastWrite $Age }
}

function Invoke-Clear([string]$TempRoot, [int]$MinAgeMinutes, [object[]]$LiveKimiInfo) {
  $splats = @{
    TempRoot = $TempRoot
    MinAgeMinutes = $MinAgeMinutes
  }
  if ($null -ne $LiveKimiInfo) {
    $splats['LiveKimiInfo'] = $LiveKimiInfo
  }
  $json = & $scriptPath @splats
  if ($json -is [array]) { $json = $json[-1] }
  return ($json | ConvertFrom-Json)
}

function Find-DeadPid {
  # Pick a high pid unlikely to exist; verify with Get-Process.
  foreach ($candidate in 2147483000, 2147483001, 2147483002, 999999, 888888) {
    $exists = $null -ne (Get-Process -Id $candidate -ErrorAction SilentlyContinue)
    if (-not $exists) { return $candidate }
  }
  throw 'could not find a free dead pid for tests'
}

$self = Get-Process -Id $PID
$selfStart = $self.StartTime
$old = (Get-Date).AddMinutes(-60)
$fresh = Get-Date
$deadPid = Find-DeadPid
$fakeLive = @(@{ Id = 424242; StartTime = (Get-Date).AddHours(-1) })

# --- NEGATIVE: live owner older than MinAge -> skipped_live, not removed ---
Case 'live owner marker older than MinAge is skipped_live not removed' {
  $root = New-TestRoot
  try {
    $dir = New-RuntimeDir -Parent $root -Suffix 'live' -LastWrite $old
    Write-OwnerMarker -Root $dir -OwnerPid $PID -StartTime $selfStart -Age $old
    $r = Invoke-Clear -TempRoot $root -MinAgeMinutes 15 -LiveKimiInfo @()
    Assert-True (Test-Path -LiteralPath $dir) 'live-owned root was deleted'
    Assert-True ($r.skipped_live -ge 1) "expected skipped_live>=1 got $($r.skipped_live)"
    Assert-True ($r.removed -eq 0) "expected removed=0 got $($r.removed)"
  } finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# --- POSITIVE: dead owner pid -> removed ---
Case 'dead owner pid root is removed' {
  $root = New-TestRoot
  try {
    $dir = New-RuntimeDir -Parent $root -Suffix 'dead' -LastWrite $old
    Write-OwnerMarker -Root $dir -OwnerPid $deadPid -StartTime $old -Age $old
    $r = Invoke-Clear -TempRoot $root -MinAgeMinutes 15 -LiveKimiInfo @()
    Assert-True (-not (Test-Path -LiteralPath $dir)) 'dead-owner root was not deleted'
    Assert-True ($r.removed -eq 1) "expected removed=1 got $($r.removed)"
  } finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# --- POSITIVE: live pid but mismatched creation time (recycled) -> removed ---
Case 'recycled pid mismatched start_time is removed' {
  $root = New-TestRoot
  try {
    $dir = New-RuntimeDir -Parent $root -Suffix 'recycled' -LastWrite $old
    $wrongStart = $selfStart.AddHours(-5)
    Write-OwnerMarker -Root $dir -OwnerPid $PID -StartTime $wrongStart -Age $old
    $r = Invoke-Clear -TempRoot $root -MinAgeMinutes 15 -LiveKimiInfo @()
    Assert-True (-not (Test-Path -LiteralPath $dir)) 'recycled-pid root was not deleted'
    Assert-True ($r.removed -eq 1) "expected removed=1 got $($r.removed)"
    Assert-True ($r.skipped_live -eq 0) "expected skipped_live=0 got $($r.skipped_live)"
  } finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# --- NEGATIVE: unmarked legacy while kimi alive -> skipped_unattributable ---
Case 'unmarked legacy with live kimi is skipped_unattributable' {
  $root = New-TestRoot
  try {
    $dir = New-RuntimeDir -Parent $root -Suffix 'legacy-live' -LastWrite $old
    $r = Invoke-Clear -TempRoot $root -MinAgeMinutes 15 -LiveKimiInfo $fakeLive
    Assert-True (Test-Path -LiteralPath $dir) 'unmarked root deleted while kimi live'
    Assert-True ($r.skipped_unattributable -ge 1) "expected skipped_unattributable>=1 got $($r.skipped_unattributable)"
    Assert-True ($r.removed -eq 0) "expected removed=0 got $($r.removed)"
    Assert-True ($null -ne $r.reason -and $r.reason.Length -gt 0) 'missing reason when nothing removed'
  } finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# --- POSITIVE: unmarked legacy, no kimi, older than cutoff -> removed ---
Case 'unmarked legacy no kimi older than cutoff is removed' {
  $root = New-TestRoot
  try {
    $dir = New-RuntimeDir -Parent $root -Suffix 'legacy-gone' -LastWrite $old
    $r = Invoke-Clear -TempRoot $root -MinAgeMinutes 15 -LiveKimiInfo @()
    Assert-True (-not (Test-Path -LiteralPath $dir)) 'unmarked stale root was not deleted'
    Assert-True ($r.removed -eq 1) "expected removed=1 got $($r.removed)"
  } finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# --- POSITIVE: root newer than age cutoff never removed ---
Case 'root newer than age cutoff never removed' {
  $root = New-TestRoot
  try {
    $dirDead = New-RuntimeDir -Parent $root -Suffix 'fresh-dead' -LastWrite $fresh
    Write-OwnerMarker -Root $dirDead -OwnerPid $deadPid -StartTime $old -Age $fresh
    $dirLive = New-RuntimeDir -Parent $root -Suffix 'fresh-live' -LastWrite $fresh
    Write-OwnerMarker -Root $dirLive -OwnerPid $PID -StartTime $selfStart -Age $fresh
    $dirLeg = New-RuntimeDir -Parent $root -Suffix 'fresh-leg' -LastWrite $fresh
    $r = Invoke-Clear -TempRoot $root -MinAgeMinutes 15 -LiveKimiInfo @()
    Assert-True (Test-Path -LiteralPath $dirDead) 'fresh dead-owner root was deleted'
    Assert-True (Test-Path -LiteralPath $dirLive) 'fresh live-owner root was deleted'
    Assert-True (Test-Path -LiteralPath $dirLeg) 'fresh legacy root was deleted'
    Assert-True ($r.removed -eq 0) "expected removed=0 got $($r.removed)"
  } finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# --- Containment: outside fleet-kimi-k3- prefix not touched ---
Case 'path outside fleet-kimi-k3 prefix is not removed' {
  $root = New-TestRoot
  try {
    $outside = Join-Path $root ('other-runtime-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $outside 'probe.txt') -Value 'x' -Encoding ASCII
    $item = Get-Item -LiteralPath $outside
    $item.LastWriteTime = $old
    $r = Invoke-Clear -TempRoot $root -MinAgeMinutes 15 -LiveKimiInfo @()
    Assert-True (Test-Path -LiteralPath $outside) 'non-prefix path was deleted'
    Assert-True ($r.removed -eq 0) "expected removed=0 got $($r.removed)"
  } finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# --- Containment throw: path must stay under tempRoot + prefix (defense in depth) ---
Case 'prefix guard string is present in script' {
  $text = [IO.File]::ReadAllText($scriptPath)
  Assert-True ($text -match 'Refusing to clean a path outside the dedicated Fleet Kimi temporary prefix') 'missing containment throw message'
  Assert-True ($text -match 'owner\.json') 'missing owner.json marker name'
  Assert-True ($text -match 'skipped_live' -and $text -match 'skipped_unattributable') 'missing skip counters'
}

Write-Host ("RESULT passed={0} failed={1} skipped={2} total={3}" -f $passed, $failed, $skipped, ($passed + $failed + $skipped))
if ($failed -gt 0) { exit 1 }
if (($passed + $failed + $skipped) -eq 0) { Write-Host 'RESULT collected=0'; exit 1 }
exit 0
