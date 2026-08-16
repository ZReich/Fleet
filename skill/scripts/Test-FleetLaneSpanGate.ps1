# Offline fixture tests for Assert-FleetLaneSpans.ps1 (temp ledgers only).
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Assert-FleetLaneSpans.ps1'
$manifestProducer = Join-Path $PSScriptRoot 'New-FleetExpectedLaneManifest.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('fleet-lane-span-gate-' + [guid]::NewGuid().ToString('N'))
$passed = 0; $failed = 0
$utf8 = New-Object Text.UTF8Encoding $false
$RunId = 'fleet-build-20260729'
$Expect = @('sol-plan', 'grok-T1', 'grok-T2', 'terra-gates', 'sol-review')

function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw "ASSERTION FAILED: $m" } }
function Case([string]$n, [scriptblock]$b) {
  try { & $b; $script:passed++; Write-Host "PASS $n" }
  catch { $script:failed++; Write-Host "FAIL $n - $($_.Exception.Message)" }
}
function New-ValidSpan {
  param([string]$LaneId, [string]$Status = 'ok', [string]$Rid = $RunId, [string]$Phase = 'impl')
  [pscustomobject][ordered]@{
    schema_version = '1'; run_id = $Rid; lane_id = $LaneId; phase = $Phase
    'gen_ai.operation.name' = 'invoke_agent'; 'gen_ai.agent.name' = 'grok-4.6'
    'gen_ai.provider.name' = 'xai'; 'gen_ai.request.model' = 'grok-4.6'
    'gen_ai.response.model' = $null; 'gen_ai.usage.input_tokens' = $null
    'gen_ai.usage.output_tokens' = $null; 'gen_ai.usage.cache_read.input_tokens' = $null
    tool_calls = 1; inference_calls = 1; duration_s = 10.0; first_result_s = 1.0
    status = $Status; 'error.type' = $null; handoff = $null; artifacts = @()
  }
}
function Write-Ledger([string]$Path, [object[]]$Rows, [string[]]$RawExtra = @()) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $sb = New-Object System.Text.StringBuilder
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    if ($r -is [string]) { [void]$sb.AppendLine($r) }
    else { [void]$sb.AppendLine(($r | ConvertTo-Json -Depth 10 -Compress)) }
  }
  foreach ($x in @($RawExtra)) { [void]$sb.AppendLine($x) }
  [IO.File]::WriteAllText($Path, $sb.ToString(), $utf8)
}
function New-ExactSetLedger([string]$Path) {
  $rows = @(); foreach ($id in $Expect) { $rows += (New-ValidSpan -LaneId $id) }
  Write-Ledger $Path $rows
}
function New-Manifest([string]$Path, [string]$Rid, [string[]]$Lanes) {
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manifestProducer -RunId $Rid -ExpectedLaneId ($Lanes -join ',') -OutputPath $Path
  if ($LASTEXITCODE -ne 0) { throw "manifest producer failed exit $LASTEXITCODE path=$Path" }
}
function Invoke-Gate {
  param([string]$LedgerPath, [string[]]$ExpectedLaneId = $Expect, [string]$Mode = 'text', [string]$Rid = $RunId,
    [string]$ExpectedLaneManifest = '', [switch]$OmitExpectedLaneId, [switch]$OmitManifest)
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-RunId', $Rid, '-LedgerPath', $LedgerPath, '-Mode', $Mode)
  if (-not $OmitExpectedLaneId) { $args += @('-ExpectedLaneId', ($ExpectedLaneId -join ',')) }
  if (-not $OmitManifest) {
    if ([string]::IsNullOrWhiteSpace($ExpectedLaneManifest)) {
      $ExpectedLaneManifest = Join-Path $root ('m-' + [guid]::NewGuid().ToString('N') + '.json')
      New-Manifest $ExpectedLaneManifest $Rid $ExpectedLaneId
    }
    $args += @('-ExpectedLaneManifest', $ExpectedLaneManifest)
  }
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @args 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = $code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}
function Write-Manifest([string]$Path, [string]$Rid, [string[]]$Lanes) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, (([ordered]@{ run_id = $Rid; expected_lanes = @($Lanes) }) | ConvertTo-Json -Compress -Depth 4), $utf8)
}
function Get-SummaryLine([string]$Raw) {
  foreach ($line in ($Raw -split "`n")) { $t = $line.Trim(); if ($t -like 'lane-spans:*') { return $t } }
  return $null
}
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  Case 'positive: exact set present+valid -> exit 0, counts correct' {
    $ledger = Join-Path $root 'exact-ok.jsonl'; New-ExactSetLedger $ledger
    $run = Invoke-Gate -LedgerPath $ledger
    Assert-True ($run.ExitCode -eq 0) "exit 0: $($run.Raw)"
    $sum = Get-SummaryLine $run.Raw
    Assert-True ($sum -match "^lane-spans: $RunId \| expected: 5 \| valid: 5 \| missing: 0 \| duplicate: 0 \| unexpected: 0 \| invalid: 0 \| verdict: ok \| ExpectedLaneManifest: .+") "summary: $sum"
  }
  Case 'missing lane -> exit 1, missing=1, lane named' {
    $ledger = Join-Path $root 'missing-one.jsonl'
    $rows = @(); foreach ($id in $Expect) { if ($id -ne 'grok-T2') { $rows += (New-ValidSpan -LaneId $id) } }
    Write-Ledger $ledger $rows
    $run = Invoke-Gate -LedgerPath $ledger -Mode json
    Assert-True ($run.ExitCode -eq 1) "exit 1: $($run.Raw)"
    $o = $run.Raw | ConvertFrom-Json
    Assert-True ($o.missing -eq 1 -and $o.valid -eq 4 -and $o.verdict -eq 'FAILED') "counts: $($run.Raw)"
    $names = @($o.lanes | Where-Object { $_.state -eq 'missing' } | ForEach-Object { $_.lane_id })
    Assert-True ($names -contains 'grok-T2') "grok-T2 named: $($run.Raw)"
    Assert-True ((Get-SummaryLine (Invoke-Gate -LedgerPath $ledger).Raw) -match 'missing: 1') "text"
  }
  Case 'duplicate row -> exit 1, duplicate=1' {
    $ledger = Join-Path $root 'dup.jsonl'
    $rows = @(); foreach ($id in $Expect) { $rows += (New-ValidSpan -LaneId $id) }; $rows += (New-ValidSpan -LaneId 'sol-plan')
    Write-Ledger $ledger $rows
    $run = Invoke-Gate -LedgerPath $ledger -Mode json
    Assert-True ($run.ExitCode -eq 1 -and ($run.Raw | ConvertFrom-Json).duplicate -eq 1) "dup: $($run.Raw)"
    Assert-True ((Get-SummaryLine (Invoke-Gate -LedgerPath $ledger).Raw) -match 'duplicate: 1') 'text dup'
  }
  Case 'unexpected lane -> exit 1, unexpected=1' {
    $ledger = Join-Path $root 'unexpected.jsonl'
    $rows = @(); foreach ($id in $Expect) { $rows += (New-ValidSpan -LaneId $id) }; $rows += (New-ValidSpan -LaneId 'rogue-lane')
    Write-Ledger $ledger $rows
    $run = Invoke-Gate -LedgerPath $ledger -Mode json
    Assert-True ($run.ExitCode -eq 1) "exit 1: $($run.Raw)"
    $o = $run.Raw | ConvertFrom-Json
    Assert-True ($o.unexpected -eq 1) "unexpected=1: $($run.Raw)"
    Assert-True ((@($o.lanes | Where-Object { $_.state -eq 'unexpected' } | ForEach-Object { $_.lane_id })) -contains 'rogue-lane') "rogue"
  }
  Case 'schema-invalid row (bad status) -> exit 1, invalid=1' {
    $ledger = Join-Path $root 'bad-status.jsonl'; $rows = @()
    foreach ($id in $Expect) {
      if ($id -eq 'terra-gates') { $b = New-ValidSpan -LaneId $id; $b.status = 'done'; $rows += $b }
      else { $rows += (New-ValidSpan -LaneId $id) }
    }
    Write-Ledger $ledger $rows
    $run = Invoke-Gate -LedgerPath $ledger -Mode json
    Assert-True ($run.ExitCode -eq 1 -and ($run.Raw | ConvertFrom-Json).invalid -eq 1) "invalid: $($run.Raw)"
  }
  Case 'schema-invalid row (bad sha256) -> exit 1, invalid=1' {
    $ledger = Join-Path $root 'bad-sha.jsonl'; $rows = @()
    foreach ($id in $Expect) {
      if ($id -eq 'grok-T1') {
        $b = New-ValidSpan -LaneId $id
        $b.artifacts = @([pscustomobject]@{ path = 'x.txt'; bytes = 1; sha256 = ('A' * 64) }); $rows += $b
      } else { $rows += (New-ValidSpan -LaneId $id) }
    }
    Write-Ledger $ledger $rows
    $run = Invoke-Gate -LedgerPath $ledger -Mode json
    Assert-True ($run.ExitCode -eq 1 -and ($run.Raw | ConvertFrom-Json).invalid -eq 1) "invalid=1: $($run.Raw)"
  }
  Case 'schema-invalid row (missing field) -> exit 1, invalid=1' {
    $ledger = Join-Path $root 'missing-field.jsonl'; $rows = @()
    foreach ($id in $Expect) {
      if ($id -eq 'sol-review') { $b = New-ValidSpan -LaneId $id; $b.PSObject.Properties.Remove('phase'); $rows += $b }
      else { $rows += (New-ValidSpan -LaneId $id) }
    }
    Write-Ledger $ledger $rows
    $run = Invoke-Gate -LedgerPath $ledger -Mode json
    Assert-True ($run.ExitCode -eq 1 -and ($run.Raw | ConvertFrom-Json).invalid -eq 1) "invalid=1: $($run.Raw)"
  }
  Case 'unparseable line -> exit 1' {
    $ledger = Join-Path $root 'unparseable.jsonl'
    $rows = @(); foreach ($id in $Expect) { $rows += (New-ValidSpan -LaneId $id) }
    Write-Ledger $ledger $rows -RawExtra @('{not-json')
    $run = Invoke-Gate -LedgerPath $ledger -Mode json
    Assert-True ($run.ExitCode -eq 1 -and ($run.Raw | ConvertFrom-Json).invalid -ge 1) "invalid: $($run.Raw)"
  }
  Case 'JSON/text mode parity: same verdict both modes' {
    $ledger = Join-Path $root 'parity.jsonl'
    $rows = @(); foreach ($id in $Expect) { if ($id -ne 'sol-plan') { $rows += (New-ValidSpan -LaneId $id) } }
    Write-Ledger $ledger $rows
    $textRun = Invoke-Gate -LedgerPath $ledger -Mode text; $jsonRun = Invoke-Gate -LedgerPath $ledger -Mode json
    Assert-True ($textRun.ExitCode -eq $jsonRun.ExitCode -and $textRun.ExitCode -eq 1) "exits"
    $o = $jsonRun.Raw | ConvertFrom-Json; $sum = Get-SummaryLine $textRun.Raw
    Assert-True ($o.verdict -eq 'FAILED' -and $o.expected -eq 5 -and $o.missing -eq 1 -and $o.valid -eq 4) "json: $($jsonRun.Raw)"
    Assert-True ($sum -match 'verdict: FAILED' -and $sum -match 'expected: 5' -and $sum -match 'missing: 1') "text: $sum"
  }
  Case 'RESTORE proof: fail then restore valid ledger -> exit 0' {
    $ledger = Join-Path $root 'restore.jsonl'
    $rows = @(); foreach ($id in $Expect) { if ($id -ne 'terra-gates') { $rows += (New-ValidSpan -LaneId $id) } }
    Write-Ledger $ledger $rows
    $failRun = Invoke-Gate -LedgerPath $ledger
    Assert-True ($failRun.ExitCode -eq 1 -and (Get-SummaryLine $failRun.Raw) -match 'verdict: FAILED') "fail: $($failRun.Raw)"
    New-ExactSetLedger $ledger
    $okRun = Invoke-Gate -LedgerPath $ledger
    Assert-True ($okRun.ExitCode -eq 0 -and (Get-SummaryLine $okRun.Raw) -match 'verdict: ok') "restore: $($okRun.Raw)"
  }
  Case 'missing ledger file -> exit 1, never pass' {
    $missingPath = Join-Path $root 'does-not-exist-ledger.jsonl'
    $run = Invoke-Gate -LedgerPath $missingPath -Mode json
    Assert-True ($run.ExitCode -eq 1) "exit 1: $($run.Raw)"
    $o = $run.Raw | ConvertFrom-Json
    Assert-True ($o.verdict -eq 'FAILED' -and $o.missing -eq 5 -and $o.valid -eq 0) "all missing: $($run.Raw)"
    $textRun = Invoke-Gate -LedgerPath $missingPath
    Assert-True ($textRun.ExitCode -eq 1 -and (Get-SummaryLine $textRun.Raw) -match 'missing: 5') "text: $($textRun.Raw)"
  }
  Case 'status error|timeout|no_contest still valid for this gate' {
    $ledger = Join-Path $root 'non-ok-status.jsonl'
    Write-Ledger $ledger @(
      (New-ValidSpan -LaneId 'sol-plan' -Status 'error'), (New-ValidSpan -LaneId 'grok-T1' -Status 'timeout'),
      (New-ValidSpan -LaneId 'grok-T2' -Status 'no_contest'), (New-ValidSpan -LaneId 'terra-gates' -Status 'ok'),
      (New-ValidSpan -LaneId 'sol-review' -Status 'ok'))
    $run = Invoke-Gate -LedgerPath $ledger
    Assert-True ($run.ExitCode -eq 0 -and (Get-SummaryLine $run.Raw) -match 'verdict: ok') "statuses: $($run.Raw)"
  }
  Case 'other run_id rows ignored' {
    $ledger = Join-Path $root 'other-run.jsonl'
    $rows = @(); foreach ($id in $Expect) { $rows += (New-ValidSpan -LaneId $id) }
    $rows += (New-ValidSpan -LaneId 'extra' -Rid 'other-run'); Write-Ledger $ledger $rows
    Assert-True ((Invoke-Gate -LedgerPath $ledger).ExitCode -eq 0) 'other run ignored'
  }
  Case 'empty expected set fail-closed (no CLI, no manifest)' {
    $ledger = Join-Path $root 'empty-set.jsonl'; New-ExactSetLedger $ledger
    $run = Invoke-Gate -LedgerPath $ledger -Mode text -OmitExpectedLaneId -OmitManifest
    Assert-True ($run.ExitCode -ne 0 -and $run.Raw -notmatch 'verdict: ok') "no manifest: $($run.Raw)"
  }
  Case 'empty expected set fail-closed (empty manifest lanes)' {
    $ledger = Join-Path $root 'empty-manifest-set.jsonl'; New-ExactSetLedger $ledger
    $man = Join-Path $root 'empty-lanes.manifest.json'; Write-Manifest $man $RunId @()
    $run = Invoke-Gate -LedgerPath $ledger -Mode json -OmitExpectedLaneId -ExpectedLaneManifest $man
    Assert-True ($run.ExitCode -eq 1) "exit 1: $($run.Raw)"
    $o = $run.Raw | ConvertFrom-Json
    Assert-True ($o.expected -eq 0 -and $o.verdict -eq 'FAILED' -and $run.Raw -match 'ExpectedLaneManifest') "empty: $($run.Raw)"
  }
  Case 'omitted lane: missing from ledger fails; extra ledger lane unexpected' {
    $ledger = Join-Path $root 'omitted-lane.jsonl'
    Write-Ledger $ledger @((New-ValidSpan -LaneId 'sol-plan'), (New-ValidSpan -LaneId 'grok-T1'), (New-ValidSpan -LaneId 'rogue-lane'))
    $man = Join-Path $root 'omitted.manifest.json'; New-Manifest $man $RunId @('sol-plan', 'grok-T1', 'grok-T2')
    $run = Invoke-Gate -LedgerPath $ledger -Mode json -OmitExpectedLaneId -ExpectedLaneManifest $man
    Assert-True ($run.ExitCode -eq 1) "exit 1: $($run.Raw)"
    $o = $run.Raw | ConvertFrom-Json
    Assert-True ($o.verdict -eq 'FAILED' -and $o.missing -eq 1 -and $o.unexpected -eq 1) "counts: $($run.Raw)"
    Assert-True ((@($o.lanes | Where-Object { $_.state -eq 'missing' } | ForEach-Object { $_.lane_id })) -contains 'grok-T2') 'missing grok-T2'
    Assert-True ((@($o.lanes | Where-Object { $_.state -eq 'unexpected' } | ForEach-Object { $_.lane_id })) -contains 'rogue-lane') 'rogue'
  }
  Case 'manifest authority wins over CLI ExpectedLaneId' {
    $ledger = Join-Path $root 'manifest-auth.jsonl'
    Write-Ledger $ledger @((New-ValidSpan -LaneId 'sol-plan'), (New-ValidSpan -LaneId 'grok-T1'))
    $man = Join-Path $root 'auth.manifest.json'; New-Manifest $man $RunId @('sol-plan', 'grok-T1')
    $run = Invoke-Gate -LedgerPath $ledger -Mode json -ExpectedLaneId $Expect -ExpectedLaneManifest $man
    Assert-True ($run.ExitCode -eq 0) "manifest wins: $($run.Raw)"
    $o = $run.Raw | ConvertFrom-Json
    Assert-True ($o.expected -eq 2 -and $o.verdict -eq 'ok' -and $run.Raw -match 'ExpectedLaneManifest') "auth: $($run.Raw)"
  }
  Case 'CLI-only expected lanes fail closed without manifest' {
    $ledger = Join-Path $root 'cli-only.jsonl'; New-ExactSetLedger $ledger
    $run = Invoke-Gate -LedgerPath $ledger -Mode text -ExpectedLaneId $Expect -OmitManifest
    Assert-True ($run.ExitCode -ne 0 -and $run.Raw -notmatch 'verdict: ok') "CLI-only: $($run.Raw)"
  }
  Case 'pre-dispatch manifest refuses overwrite' {
    $man = Join-Path $root 'once.manifest.json'; New-Manifest $man $RunId @('sol-plan')
    $before = [IO.File]::ReadAllBytes($man)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manifestProducer -RunId $RunId -ExpectedLaneId 'sol-plan,grok-T1' -OutputPath $man 2>&1
    $code = $LASTEXITCODE; $ErrorActionPreference = $old
    Assert-True ($code -ne 0) "overwrite must fail: $raw"
    $after = [IO.File]::ReadAllBytes($man)
    Assert-True ($before.Length -eq $after.Length) 'length changed'
    for ($i = 0; $i -lt $before.Length; $i++) { Assert-True ($before[$i] -eq $after[$i]) "byte $i" }
  }
  Case 'phase-scoped manifest gates only its phase; off-phase rows ignored (fleet-wiki-20260815)' {
    $ledger = Join-Path $root 'phase-scope.jsonl'
    $reviewLanes = @('v-sol', 'v-glm', 'v-opus')
    $rows = @(); foreach ($id in $reviewLanes) { $rows += (New-ValidSpan -LaneId $id -Phase 'review') }
    # Off-phase rows under the SAME run_id (the shared ledger holds every phase). A review-scoped
    # manifest must ignore these, not flag them 'unexpected'.
    $rows += (New-ValidSpan -LaneId 'grok-writer-t2' -Phase 'implement')
    $rows += (New-ValidSpan -LaneId 'grok-planner' -Phase 'plan')
    Write-Ledger $ledger $rows
    # Scoped manifest: expected review lanes + phases=[review].
    $man = Join-Path $root 'phase-scope.manifest.json'
    [IO.File]::WriteAllText($man, (([ordered]@{ run_id = $RunId; expected_lanes = @($reviewLanes); phases = @('review') }) | ConvertTo-Json -Compress -Depth 4), $utf8)
    $run = Invoke-Gate -LedgerPath $ledger -Mode json -OmitExpectedLaneId -ExpectedLaneManifest $man
    Assert-True ($run.ExitCode -eq 0) "phase-scoped ok: $($run.Raw)"
    $o = $run.Raw | ConvertFrom-Json
    Assert-True ($o.expected -eq 3 -and $o.valid -eq 3 -and $o.unexpected -eq 0 -and $o.verdict -eq 'ok') "scoped counts: $($run.Raw)"
    # Back-compat control: SAME ledger, manifest WITHOUT phases -> off-phase rows are unexpected -> FAILED.
    $man2 = Join-Path $root 'no-phase.manifest.json'
    [IO.File]::WriteAllText($man2, (([ordered]@{ run_id = $RunId; expected_lanes = @($reviewLanes) }) | ConvertTo-Json -Compress -Depth 4), $utf8)
    $run2 = Invoke-Gate -LedgerPath $ledger -Mode json -OmitExpectedLaneId -ExpectedLaneManifest $man2
    $o2 = $run2.Raw | ConvertFrom-Json
    Assert-True ($run2.ExitCode -eq 1 -and $o2.unexpected -eq 2 -and $o2.verdict -eq 'FAILED') "run-wide control: $($run2.Raw)"
  }
  $total = $passed + $failed
  if ($total -eq 0) { Write-Host 'FAIL: suite collected 0 cases'; exit 1 }
  Write-Host "RESULT: $passed passed, $failed failed, $total total"
  if ($failed -gt 0) { exit 1 }
  exit 0
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
