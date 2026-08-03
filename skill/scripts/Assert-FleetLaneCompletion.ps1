# End-of-run gate: every dispatched fleet lane must leave a real result.
# Manager quotes the summary line in run reports:
#   lanes: N expected, A audited, X ok, Y rescued, Z incomplete, P partial, W empty, V unparseable, M missing
#   (N is `?` when -ExpectLane not supplied — never invent expectation from dir contents)
# Exit 0 only when no EMPTY/UNPARSEABLE/INCOMPLETE/PARTIAL/MISSING remain after deliverable rescue.
param(
  [Parameter(Mandatory)][string]$LaneDir,
  [string]$Pattern = '*-result.json',
  [string[]]$DeliverableDir = @(),
  [string[]]$ExpectLane = @(),
  [ValidateSet('text','json')][string]$Mode = 'text'
)
$ErrorActionPreference = 'Stop'

function Test-HasNonEmptyDeliverable([string]$Dir) {
  if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Recurse -ErrorAction SilentlyContinue)) {
    if ($f.Length -gt 0) { return $true }
  }
  return $false
}

function Find-RescueDir([string[]]$Dirs) {
  foreach ($d in @($Dirs)) {
    if (Test-HasNonEmptyDeliverable $d) { return $d }
  }
  return $null
}

function Get-LaneFiles([string]$Root, [string]$Filter) {
  $files = New-Object System.Collections.ArrayList
  foreach ($f in @(Get-ChildItem -LiteralPath $Root -Filter $Filter -File -ErrorAction SilentlyContinue)) {
    [void]$files.Add($f)
  }
  foreach ($sub in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $sub.FullName -Filter $Filter -File -ErrorAction SilentlyContinue)) {
      [void]$files.Add($f)
    }
  }
  return @($files | Sort-Object FullName)
}

function Resolve-ExpectLaneName([string]$Entry) {
  $e = ([string]$Entry).Trim()
  if ([string]::IsNullOrWhiteSpace($e)) { return $null }
  # File name (has extension) kept as-is; bare lane id maps to <id>-result.json.
  if ($e -like '*.*') { return $e }
  return "$e-result.json"
}

function Classify-LaneFile {
  param([IO.FileInfo]$File, [string]$RescueDir)
  $bytes = [int64]$File.Length
  $text = ''
  if ($bytes -gt 0) {
    $text = [IO.File]::ReadAllText($File.FullName)
  }
  if ($bytes -eq 0 -or [string]::IsNullOrWhiteSpace($text)) {
    if ($RescueDir) {
      return [ordered]@{
        path = $File.FullName
        classification = 'RESCUED'
        bytes = $bytes
        status = $null
        rescued_by = $RescueDir
      }
    }
    return [ordered]@{
      path = $File.FullName
      classification = 'EMPTY'
      bytes = $bytes
      status = $null
      rescued_by = $null
    }
  }

  # Review/analysis lanes are FREE-FORM MARKDOWN by contract (harness law), so a
  # non-empty non-.json result is a delivered lane, not a broken one. Only a .json
  # result that fails to parse is UNPARSEABLE - otherwise this gate would false-fail
  # every markdown review lane, which is the exact false-signal class it exists to stop.
  if ($File.Extension -notmatch '^\.json$') {
    return [ordered]@{
      path = $File.FullName
      classification = 'OK'
      bytes = $bytes
      status = 'non-json deliverable'
      rescued_by = $null
    }
  }

  $obj = $null
  try {
    $obj = $text | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    return [ordered]@{
      path = $File.FullName
      classification = 'UNPARSEABLE'
      bytes = $bytes
      status = $null
      rescued_by = $null
    }
  }

  $hasStatus = $false
  $statusVal = $null
  $timedOut = $false
  $exitCodePresent = $false
  $exitCodeVal = 0
  if ($null -ne $obj -and $obj.PSObject -and $obj.PSObject.Properties) {
    $prop = $obj.PSObject.Properties['status']
    if ($null -ne $prop) {
      $hasStatus = $true
      $statusVal = [string]$prop.Value
    }
    $toProp = $obj.PSObject.Properties['timed_out']
    if ($null -ne $toProp) {
      $tv = $toProp.Value
      if ($tv -is [bool]) { $timedOut = [bool]$tv }
      elseif ("$tv" -eq 'true' -or "$tv" -eq '1') { $timedOut = $true }
    }
    $exProp = $obj.PSObject.Properties['exit_code']
    if ($null -ne $exProp -and $null -ne $exProp.Value -and "$($exProp.Value)" -ne '') {
      $exitCodePresent = $true
      try { $exitCodeVal = [int]$exProp.Value } catch { $exitCodeVal = -1 }
    }
  }

  # timeout_partial: process killed at deadline; real partial deliverable, own bucket, still fails.
  if ($hasStatus -and $statusVal -eq 'timeout_partial') {
    return [ordered]@{
      path = $File.FullName
      classification = 'PARTIAL'
      bytes = $bytes
      status = $statusVal
      rescued_by = $null
    }
  }

  # Allowlist only: unknown statuses must never default to OK (denylist was inverted wrong).
  # needs_gate_validation is NOT complete — worker self-audit untrusted (panel-found 2026-07-26).
  $okStatuses = @('ok', 'passed', 'done', 'completed')
  if (-not $hasStatus -or $statusVal -notin $okStatuses) {
    return [ordered]@{
      path = $File.FullName
      classification = 'INCOMPLETE'
      bytes = $bytes
      status = $statusVal
      rescued_by = $null
    }
  }

  # Independent of status string: timed_out or nonzero exit_code still incomplete.
  if ($timedOut -or ($exitCodePresent -and $exitCodeVal -ne 0)) {
    return [ordered]@{
      path = $File.FullName
      classification = 'INCOMPLETE'
      bytes = $bytes
      status = $statusVal
      rescued_by = $null
    }
  }

  return [ordered]@{
    path = $File.FullName
    classification = 'OK'
    bytes = $bytes
    status = $statusVal
    rescued_by = $null
  }
}

# Normalize -ExpectLane once (file names or lane ids). Empty/absent => expectation unset.
# Comma-split each entry so -File callers can pass -ExpectLane a,b,c (PS array bind via -File
# only accepts one token unless commas are used; repeated -ExpectLane is ParameterAlreadyBound).
$expectedNames = New-Object System.Collections.ArrayList
$expectedSeen = @{}
foreach ($entry in @($ExpectLane)) {
  foreach ($part in @(([string]$entry) -split ',')) {
    $name = Resolve-ExpectLaneName $part
    if ($null -eq $name) { continue }
    if ($expectedSeen.ContainsKey($name)) { continue }
    $expectedSeen[$name] = $true
    [void]$expectedNames.Add($name)
  }
}
$expectSet = $expectedNames.Count -gt 0
$expectedCount = $expectedNames.Count

if (-not (Test-Path -LiteralPath $LaneDir -PathType Container)) {
  $msg = "LaneDir does not exist: $LaneDir"
  if ($Mode -eq 'json') {
    $errPayload = [ordered]@{
      error = $msg
      audited = 0; ok = 0; rescued = 0; incomplete = 0; partial = 0; empty = 0; unparseable = 0
      lanes = @()
    }
    if ($expectSet) {
      $errPayload['expected'] = $expectedCount
      $errPayload['missing'] = $expectedCount
      $errPayload['missing_lanes'] = @($expectedNames)
    }
    Write-Output (($errPayload | ConvertTo-Json -Compress -Depth 5))
  }
  else {
    Write-Output $msg
  }
  exit 1
}

$resolvedLane = (Resolve-Path -LiteralPath $LaneDir).Path
$resolvedDeliverables = @()
foreach ($d in @($DeliverableDir)) {
  if ([string]::IsNullOrWhiteSpace($d)) { continue }
  if (Test-Path -LiteralPath $d -PathType Container) {
    $resolvedDeliverables += (Resolve-Path -LiteralPath $d).Path
  }
  else {
    $resolvedDeliverables += $d
  }
}
$laneFiles = Get-LaneFiles -Root $resolvedLane -Filter $Pattern
$lanes = New-Object System.Collections.ArrayList
$ok = 0; $rescued = 0; $incomplete = 0; $partial = 0; $empty = 0; $unparseable = 0

# RESCUE MUST BIND TO A LANE (panel-found 2026-07-26). Previously ONE deliverable
# directory holding any nonempty byte rescued EVERY empty lane result, so a single
# unrelated README could launder an arbitrary number of dead lanes into "complete".
# A deliverable dir may be given as "<lane-file-name>=<dir>" to bind it explicitly; a
# bare dir is accepted only when there is exactly ONE empty lane to attribute it to.
$boundRescue = @{}
$unboundDirs = @()
foreach ($entry in @($resolvedDeliverables)) {
  $split = [string]$entry -split '=', 2
  if ($split.Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($split[0])) {
    $boundRescue[$split[0].Trim()] = $split[1].Trim()
  }
  else { $unboundDirs += [string]$entry }
}

$emptyLaneNames = @()
foreach ($f in $laneFiles) {
  $len = 0
  try { $len = (Get-Item -LiteralPath $f.FullName).Length } catch { $len = 0 }
  if ($len -eq 0) { $emptyLaneNames += $f.Name }
}
$ambiguousRescue = ($unboundDirs.Count -gt 0 -and $emptyLaneNames.Count -gt 1)
$fallbackRescueDir = if ($ambiguousRescue) { $null } else { Find-RescueDir $unboundDirs }

$foundNames = @{}
foreach ($file in $laneFiles) {
  $foundNames[$file.Name] = $true
  $laneRescueDir = if ($boundRescue.ContainsKey($file.Name)) { Find-RescueDir @($boundRescue[$file.Name]) } else { $fallbackRescueDir }
  $row = Classify-LaneFile -File $file -RescueDir $laneRescueDir
  [void]$lanes.Add($row)
  switch ($row.classification) {
    'OK' { $ok++ }
    'RESCUED' { $rescued++ }
    'INCOMPLETE' { $incomplete++ }
    'PARTIAL' { $partial++ }
    'EMPTY' { $empty++ }
    'UNPARSEABLE' { $unparseable++ }
  }
}

$audited = $lanes.Count
$missingLanes = New-Object System.Collections.ArrayList
if ($expectSet) {
  foreach ($want in @($expectedNames)) {
    if ($foundNames.ContainsKey($want)) { continue }
    [void]$missingLanes.Add($want)
    [void]$lanes.Add([ordered]@{
      path = (Join-Path $resolvedLane $want)
      classification = 'MISSING'
      bytes = 0
      status = $null
      rescued_by = $null
    })
  }
}
$missing = $missingLanes.Count

$expectedLabel = if ($expectSet) { "$expectedCount" } else { '?' }
$summary = "lanes: $expectedLabel expected, $audited audited, $ok ok, $rescued rescued, $incomplete incomplete, $partial partial, $empty empty, $unparseable unparseable"
if ($expectSet) {
  $summary = "$summary, $missing missing"
}
$fail = ($audited -eq 0) -or ($incomplete -gt 0) -or ($partial -gt 0) -or ($empty -gt 0) -or ($unparseable -gt 0) -or ($missing -gt 0)
$exitCode = if ($fail) { 1 } else { 0 }

if ($Mode -eq 'json') {
  $payload = [ordered]@{
    audited = $audited
    ok = $ok
    rescued = $rescued
    incomplete = $incomplete
    partial = $partial
    empty = $empty
    unparseable = $unparseable
    summary = $summary
    lanes = @($lanes)
  }
  if ($expectSet) {
    $payload['expected'] = $expectedCount
    $payload['missing'] = $missing
    $payload['missing_lanes'] = @($missingLanes)
  }
  Write-Output (($payload | ConvertTo-Json -Compress -Depth 6))
}
else {
  foreach ($row in $lanes) {
    $line = "{0} {1} bytes={2}" -f $row.classification, $row.path, $row.bytes
    if ($null -ne $row.status -and $row.status -ne '') {
      $line = "$line status=$($row.status)"
    }
    if ($row.rescued_by) {
      $line = "$line rescued_by=$($row.rescued_by)"
    }
    Write-Output $line
  }
  Write-Output $summary
}

exit $exitCode
