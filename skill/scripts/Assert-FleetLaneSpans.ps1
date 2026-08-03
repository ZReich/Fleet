# Hard exact-set gate: every expected lane has exactly one valid span row for RunId.
# Summary: lane-spans: <run_id> | expected: N | valid: V | missing: M | duplicate: D | unexpected: U | invalid: I | verdict: ok|FAILED
# Exit 0 only when exact set matches and every expected row is schema-valid.
# Empty normalized expected set always FAILED (never ok). ExpectedLaneManifest is sole expected-lane authority.
param(
  [Parameter(Mandatory)][string]$RunId,
  [Parameter(Mandatory)][string]$LedgerPath,
  [Parameter(Mandatory)][string]$ExpectedLaneManifest,
  [string[]]$ExpectedLaneId = @(),
  [ValidateSet('text', 'json')][string]$Mode = 'text'
)
$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'Test-FleetLaneSpanRecord.ps1'
. $validator

function Normalize-ExpectedLaneIds([string[]]$Raw) {
  $out = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($entry in @($Raw)) {
    foreach ($part in @(([string]$entry) -split ',')) {
      $id = ([string]$part).Trim()
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      if ($seen.ContainsKey($id)) { continue }
      $seen[$id] = $true
      [void]$out.Add($id)
    }
  }
  return @($out)
}

function Format-Summary {
  param(
    [string]$Rid, [int]$N, [int]$V, [int]$M, [int]$D, [int]$U, [int]$I, [string]$Verdict,
    [string]$ManifestSource = ''
  )
  $base = "lane-spans: $Rid | expected: $N | valid: $V | missing: $M | duplicate: $D | unexpected: $U | invalid: $I | verdict: $Verdict"
  if (-not [string]::IsNullOrWhiteSpace($ManifestSource)) {
    return "$base | ExpectedLaneManifest: $ManifestSource"
  }
  return $base
}

$cliExpected = @(Normalize-ExpectedLaneIds $ExpectedLaneId)
$manifestSource = ''; $authorityNotes = New-Object System.Collections.ArrayList
$hasManifest = -not [string]::IsNullOrWhiteSpace($ExpectedLaneManifest)
$hasCli = $cliExpected.Count -gt 0
if ($hasManifest) {
  if (-not (Test-Path -LiteralPath $ExpectedLaneManifest -PathType Leaf)) {
    Write-Output "ExpectedLaneManifest not found: $ExpectedLaneManifest"
    Write-Output (Format-Summary $RunId 0 0 0 0 0 0 'FAILED' $ExpectedLaneManifest); exit 1
  }
  $manifestObj = Get-Content -LiteralPath $ExpectedLaneManifest -Raw -Encoding UTF8 | ConvertFrom-Json
  $manRun = if ($manifestObj.PSObject.Properties['run_id']) { [string]$manifestObj.run_id } else { '' }
  if ($manRun -ne $RunId) {
    Write-Output "ExpectedLaneManifest run_id mismatch: manifest='$manRun' RunId='$RunId'"
    Write-Output (Format-Summary $RunId 0 0 0 0 0 0 'FAILED' $ExpectedLaneManifest); exit 1
  }
  $manLanes = @()
  if ($manifestObj.PSObject.Properties['expected_lanes'] -and $null -ne $manifestObj.expected_lanes) {
    $manLanes = @($manifestObj.expected_lanes | ForEach-Object { [string]$_ })
  }
  $expected = @(Normalize-ExpectedLaneIds $manLanes); $manifestSource = $ExpectedLaneManifest
  if ($hasCli) {
    $cliSet = ($cliExpected | Sort-Object) -join ','; $manSet = ($expected | Sort-Object) -join ','
    if ($cliSet -ne $manSet) { [void]$authorityNotes.Add("ExpectedLaneId ignored; ExpectedLaneManifest is authority (cli=[$cliSet] manifest=[$manSet])") }
    else { [void]$authorityNotes.Add('ExpectedLaneId supplied but ExpectedLaneManifest is authority') }
  }
}
else { $expected = @(); [void]$authorityNotes.Add('ExpectedLaneManifest required; empty expected set fail-closed') }
$expectedCount = $expected.Count
$expectedSet = @{}; foreach ($id in $expected) { $expectedSet[$id] = $true }

$valid = 0; $missing = 0; $duplicate = 0; $unexpected = 0; $invalid = 0
$laneDetails = New-Object System.Collections.ArrayList
$byLane = @{} # lane_id -> list of { valid:bool; reason:string; line:int }

function Add-LaneRow([string]$LaneId, [bool]$IsValid, [string]$Reason, [int]$LineNo) {
  if (-not $byLane.ContainsKey($LaneId)) { $byLane[$LaneId] = New-Object System.Collections.ArrayList }
  [void]$byLane[$LaneId].Add([pscustomobject]@{ Valid = $IsValid; Reason = $Reason; Line = $LineNo })
}
function Emit-GateResult([string]$Verdict, [string]$Message = '') {
  $summary = Format-Summary $RunId $expectedCount $valid $missing $duplicate $unexpected $invalid $Verdict $manifestSource
  if ($Mode -eq 'json') {
    $payload = [ordered]@{
      run_id = $RunId; expected = $expectedCount; valid = $valid; missing = $missing
      duplicate = $duplicate; unexpected = $unexpected; invalid = $invalid
      verdict = $Verdict; summary = $summary; lanes = @($laneDetails)
    }
    if ($Message) { $payload['message'] = $Message }
    if ($manifestSource) { $payload['ExpectedLaneManifest'] = $manifestSource }
    if ($authorityNotes.Count -gt 0) { $payload['authority_notes'] = @($authorityNotes) }
    Write-Output (($payload | ConvertTo-Json -Compress -Depth 6))
  } else {
    foreach ($n in $authorityNotes) { Write-Output $n }
    if ($Message) { Write-Output $Message }
    Write-Output $summary
  }
}

if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
  # Missing ledger: every expected lane is missing; never silent pass.
  $missing = $expectedCount
  foreach ($id in $expected) {
    [void]$laneDetails.Add([ordered]@{ lane_id = $id; state = 'missing'; reason = 'ledger file missing' })
  }
  Emit-GateResult 'FAILED' "ledger file missing: $LedgerPath"
  exit 1
}

$utf8 = New-Object Text.UTF8Encoding $false
$lines = [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $LedgerPath).Path, $utf8)
$lineNo = 0
foreach ($line in $lines) {
  $lineNo++
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $obj = $null
  try {
    $obj = $line | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    # Unparseable: cannot attribute run_id; fail-closed as invalid for this audit.
    $invalid++
    [void]$laneDetails.Add([ordered]@{
        lane_id = $null
        state   = 'invalid'
        reason  = "unparseable line $lineNo"
        line    = $lineNo
      })
    continue
  }
  if ($null -eq $obj) {
    $invalid++
    [void]$laneDetails.Add([ordered]@{
        lane_id = $null
        state   = 'invalid'
        reason  = "null JSON line $lineNo"
        line    = $lineNo
      })
    continue
  }

  $rowRun = $null
  $rowLane = $null
  if ($obj.PSObject.Properties['run_id']) { $rowRun = [string]$obj.run_id }
  if ($obj.PSObject.Properties['lane_id']) { $rowLane = [string]$obj.lane_id }

  if ($rowRun -ne $RunId) { continue }

  if ([string]::IsNullOrWhiteSpace($rowLane)) {
    $invalid++
    Add-LaneRow '' $false "missing lane_id line $lineNo" $lineNo
    [void]$laneDetails.Add([ordered]@{
        lane_id = $null
        state   = 'invalid'
        reason  = "missing lane_id line $lineNo"
        line    = $lineNo
      })
    continue
  }

  $schemaOk = $false
  $schemaReason = $null
  try {
    [void](Test-FleetLaneSpanRecord $obj)
    $schemaOk = $true
  }
  catch {
    $schemaOk = $false
    $schemaReason = $_.Exception.Message
  }

  if (-not $schemaOk) {
    $invalid++
    Add-LaneRow $rowLane $false $schemaReason $lineNo
    [void]$laneDetails.Add([ordered]@{
        lane_id = $rowLane
        state   = 'invalid'
        reason  = $schemaReason
        line    = $lineNo
      })
    continue
  }

  Add-LaneRow $rowLane $true 'ok' $lineNo
}

# Classify expected lanes + unexpected lane ids seen for this run.
foreach ($id in $expected) {
  if (-not $byLane.ContainsKey($id)) {
    $missing++
    [void]$laneDetails.Add([ordered]@{
        lane_id = $id
        state   = 'missing'
        reason  = 'no row for run_id+lane_id'
      })
    continue
  }
  $rows = @($byLane[$id])
  $validRows = @($rows | Where-Object { $_.Valid })
  $invalidRows = @($rows | Where-Object { -not $_.Valid })
  if ($rows.Count -gt 1) {
    $duplicate += ($rows.Count - 1)
    [void]$laneDetails.Add([ordered]@{
        lane_id = $id
        state   = 'duplicate'
        reason  = "count=$($rows.Count)"
        rows    = $rows.Count
      })
    # First valid among multi still does not satisfy exact-set; no valid++.
    continue
  }
  if ($invalidRows.Count -eq 1 -and $validRows.Count -eq 0) {
    # Already counted in invalid; lane present but not valid.
    continue
  }
  if ($validRows.Count -eq 1) {
    $valid++
    [void]$laneDetails.Add([ordered]@{
        lane_id = $id
        state   = 'valid'
        reason  = 'ok'
      })
  }
}

foreach ($laneId in @($byLane.Keys)) {
  if ($expectedSet.ContainsKey($laneId)) { continue }
  if ([string]::IsNullOrWhiteSpace($laneId)) { continue }
  $rows = @($byLane[$laneId])
  $unexpected += $rows.Count
  [void]$laneDetails.Add([ordered]@{
      lane_id = $laneId
      state   = 'unexpected'
      reason  = "not in expected set (rows=$($rows.Count))"
      rows    = $rows.Count
    })
}

# Empty expected set is never ok (fail closed): green gate with zero telemetry forbidden.
$verdict = 'FAILED'
if ($expectedCount -gt 0 -and $missing -eq 0 -and $duplicate -eq 0 -and $unexpected -eq 0 -and $invalid -eq 0 -and $valid -eq $expectedCount) {
  $verdict = 'ok'
}
Emit-GateResult $verdict
if ($verdict -eq 'ok') { exit 0 }
exit 1
