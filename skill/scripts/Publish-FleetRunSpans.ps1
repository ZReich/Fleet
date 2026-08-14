# Publish a run's per-run lane-span records into the shared BENCH-lanes.jsonl (Sol A1).
# Runs BEFORE Assert-FleetLaneSpans/certification, never inside lease cleanup. Verifies the
# expected-lane manifest, path containment, schema, run/lane identity, and source hashes, then
# writes through the canonical Record-FleetLaneSpan.ps1 (which owns mutex + dedupe). An
# identical already-published row is an idempotent no-op; a conflicting duplicate fails.
# Emits span-publish-manifest.json next to the source dir and prints
# "span-publish: <run_id> | records: N | published: P | noop: K | failed: F".
[CmdletBinding()]
param(
  # Not [Mandatory]: psvalid invokes `-SelfTest` bare; the CLI path validates below.
  [string]$RunId = '',
  # Directory holding the run's span record JSON files (one span per file).
  [string]$SpanDir = '',
  # Optional expected lane ids (from the run's lane manifest); when given, the record set must
  # match EXACTLY (no missing, no unexpected lanes).
  [string[]]$ExpectedLanes = @(),
  [string]$LedgerPath = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$recordScript = Join-Path $PSScriptRoot 'Record-FleetLaneSpan.ps1'

function Get-FileShaHex([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Invoke-FleetSpanPublish([string]$RunId, [string]$SpanDir, [string[]]$ExpectedLanes, [string]$LedgerPath) {
  $utf8L = New-Object System.Text.UTF8Encoding $false
  if ($RunId -notmatch '^[A-Za-z0-9._-]+$') { throw "invalid RunId: $RunId" }
  $dirFull = [IO.Path]::GetFullPath($SpanDir).TrimEnd('\')
  if (-not (Test-Path -LiteralPath $dirFull -PathType Container)) { throw "SpanDir missing: $SpanDir" }
  # Expected lanes are MANDATORY (Sol M5 2026-08-11): publishing without lane authority could
  # contaminate the shared ledger before the lane-span gate runs.
  if (@($ExpectedLanes).Count -eq 0) { throw 'ExpectedLanes is required: pass the run lane manifest lane ids' }
  if ([string]::IsNullOrWhiteSpace($LedgerPath)) { $LedgerPath = Join-Path $PSScriptRoot '..\BENCH-lanes.jsonl' }
  $ledgerFull = [IO.Path]::GetFullPath($LedgerPath)

  $files = @(Get-ChildItem -LiteralPath $dirFull -Filter '*.json' -File | Where-Object { $_.Name -ne 'span-publish-manifest.json' } | Sort-Object Name)
  $records = New-Object System.Collections.ArrayList
  $seenLanes = @{}
  foreach ($f in $files) {
    if (-not ($f.FullName + '').StartsWith($dirFull, [StringComparison]::OrdinalIgnoreCase)) { throw "record escapes SpanDir: $($f.FullName)" }
    $obj = [IO.File]::ReadAllText($f.FullName, $utf8L) | ConvertFrom-Json
    if ([string]$obj.schema_version -cne '1') { throw "record $($f.Name): schema_version must be '1'" }
    if ([string]$obj.run_id -cne $RunId) { throw "record $($f.Name): run_id '$($obj.run_id)' != '$RunId'" }
    $lane = [string]$obj.lane_id
    if ($lane -notmatch '^[A-Za-z0-9._-]+$') { throw "record $($f.Name): invalid lane_id '$lane'" }
    if ($seenLanes.ContainsKey($lane)) { throw "duplicate lane_id across records: $lane" }
    $seenLanes[$lane] = $true
    [void]$records.Add(@{ lane_id = $lane; record_path = $f.FullName; record_sha256 = (Get-FileShaHex $f.FullName) })
  }
  if (@($ExpectedLanes).Count -gt 0) {
    $want = @($ExpectedLanes | Sort-Object -Unique)
    $got = @($seenLanes.Keys | Sort-Object)
    $missing = @($want | Where-Object { $_ -cnotin $got })
    $extra = @($got | Where-Object { $_ -cnotin $want })
    if ($missing.Count -gt 0) { throw ('missing expected lanes: ' + ($missing -join ', ')) }
    if ($extra.Count -gt 0) { throw ('unexpected lanes: ' + ($extra -join ', ')) }
  }
  if ($records.Count -eq 0) { throw "no span records found in $SpanDir" }

  # Idempotence: a row already in the ledger that is BYTE-IDENTICAL in canonical form is a
  # no-op; same (run_id,lane_id) with different content is a conflict (canonical writer throws).
  $existingByLane = @{}
  if (Test-Path -LiteralPath $ledgerFull -PathType Leaf) {
    foreach ($ln in [IO.File]::ReadAllLines($ledgerFull, $utf8L)) {
      if ([string]::IsNullOrWhiteSpace($ln)) { continue }
      try { $e = $ln | ConvertFrom-Json } catch { continue }
      if ([string]$e.run_id -ceq $RunId) { $existingByLane[[string]$e.lane_id] = $ln.Trim() }
    }
  }
  $published = 0; $noop = 0; $failedRecords = @()
  foreach ($r in @($records)) {
    if ($existingByLane.ContainsKey([string]$r.lane_id)) {
      # Compare canonical serialization of the incoming record to the published row.
      $incoming = ([IO.File]::ReadAllText([string]$r.record_path, $utf8L) | ConvertFrom-Json)
      $canonScript = Join-Path $PSScriptRoot 'Test-FleetLaneSpanRecord.ps1'
      . $canonScript
      $canon = ([pscustomobject](ConvertTo-CanonicalLaneSpan $incoming) | ConvertTo-Json -Depth 8 -Compress)
      if ($canon -ceq $existingByLane[[string]$r.lane_id]) { $noop++; continue }
      $failedRecords += ("conflicting duplicate for lane " + $r.lane_id)
      continue
    }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& $recordScript -RecordPath ([string]$r.record_path) -OutputPath $ledgerFull 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -eq 0) { $published++ } else { $failedRecords += ("lane " + $r.lane_id + ": " + ($out -join ' ')) }
  }

  $manifest = [ordered]@{
    schema_version = '1'; run_id = $RunId
    records = @($records | ForEach-Object { [ordered]@{ lane_id = $_.lane_id; record_path = $_.record_path; record_sha256 = $_.record_sha256 } })
  }
  [IO.File]::WriteAllText((Join-Path $dirFull 'span-publish-manifest.json'), (($manifest | ConvertTo-Json -Depth 5) + "`n"), $utf8L)
  $line = "span-publish: $RunId | records: $($records.Count) | published: $published | noop: $noop | failed: $($failedRecords.Count)"
  return @{ Line = $line; Failed = @($failedRecords) }
}

if ($SelfTest) {
  $fail = 0
  function Check([string]$n, [bool]$ok) { if ($ok) { Write-Output "PASS $n" } else { Write-Output "FAIL $n"; $script:fail++ } }
  $tmp = Join-Path $env:TEMP ('spanpub-st-' + [guid]::NewGuid().ToString('n'))
  $sd = Join-Path $tmp 'spans'; $ledger = Join-Path $tmp 'ledger.jsonl'
  New-Item -ItemType Directory -Force -Path $sd | Out-Null
  try {
    function W-Span([string]$Lane) {
      $rec = [ordered]@{
        schema_version = '1'; run_id = 'st-run'; lane_id = $Lane; phase = 'impl'
        'gen_ai.operation.name' = 'invoke_agent'; 'gen_ai.agent.name' = 'grok-4.6'; 'gen_ai.provider.name' = 'xai'
        'gen_ai.request.model' = 'grok-4.6'; 'gen_ai.response.model' = $null
        'gen_ai.usage.input_tokens' = $null; 'gen_ai.usage.output_tokens' = $null; 'gen_ai.usage.cache_read.input_tokens' = $null
        tool_calls = 0; inference_calls = 1; duration_s = 60.0; first_result_s = 1.5
        status = 'ok'; 'error.type' = $null; handoff = $null; artifacts = @()
      }
      [IO.File]::WriteAllText((Join-Path $sd ($Lane + '.json')), ($rec | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
    }
    W-Span 'L1'; W-Span 'L2'
    $r = Invoke-FleetSpanPublish -RunId 'st-run' -SpanDir $sd -ExpectedLanes @('L1', 'L2') -LedgerPath $ledger
    Check 'publishes 2' ($r.Line -match 'published: 2' -and $r.Failed.Count -eq 0)
    Check 'ledger has 2 rows' (@([IO.File]::ReadAllLines($ledger) | Where-Object { $_ }).Count -eq 2)
    Check 'manifest written' (Test-Path (Join-Path $sd 'span-publish-manifest.json'))
    $r2 = Invoke-FleetSpanPublish -RunId 'st-run' -SpanDir $sd -ExpectedLanes @('L1', 'L2') -LedgerPath $ledger
    Check 'identical replay is noop' ($r2.Line -match 'published: 0' -and $r2.Line -match 'noop: 2' -and $r2.Failed.Count -eq 0)
    # Conflicting duplicate: same lane, mutated content.
    $p = Join-Path $sd 'L1.json'
    [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace '"duration_s":\s*60(\.0)?', '"duration_s": 61.0'), (New-Object System.Text.UTF8Encoding $false))
    $r3 = Invoke-FleetSpanPublish -RunId 'st-run' -SpanDir $sd -ExpectedLanes @('L1', 'L2') -LedgerPath $ledger
    Check 'conflicting replay fails' ($r3.Failed.Count -eq 1 -and $r3.Failed[0] -match 'L1')
    # Expected-lane mismatches.
    $threw = $false; try { $null = Invoke-FleetSpanPublish -RunId 'st-run' -SpanDir $sd -ExpectedLanes @('L1', 'L2', 'L3') -LedgerPath $ledger } catch { $threw = $true }
    Check 'missing expected lane throws' $threw
    $threw = $false; try { $null = Invoke-FleetSpanPublish -RunId 'st-run' -SpanDir $sd -ExpectedLanes @('L1') -LedgerPath $ledger } catch { $threw = $true }
    Check 'unexpected lane throws' $threw
    # Wrong run id in a record.
    W-Span 'L4'
    [IO.File]::WriteAllText((Join-Path $sd 'L4.json'), ([IO.File]::ReadAllText((Join-Path $sd 'L4.json')) -replace '"run_id":\s*"st-run"', '"run_id": "other-run"'), (New-Object System.Text.UTF8Encoding $false))
    $threw = $false; try { $null = Invoke-FleetSpanPublish -RunId 'st-run' -SpanDir $sd -ExpectedLanes @('L1', 'L2', 'L4') -LedgerPath $ledger } catch { $threw = $true }
    Check 'wrong run_id throws' $threw
    $threw = $false; try { $null = Invoke-FleetSpanPublish -RunId 'st-run' -SpanDir $sd -LedgerPath $ledger } catch { $threw = $true }
    Check 'omitted ExpectedLanes throws' $threw
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'Test-PublishFleetRunSpans: passed (9 checks)'; exit 0 }
  Write-Output "Test-PublishFleetRunSpans: FAILED ($fail)"; exit 1
}

if ([string]::IsNullOrWhiteSpace($RunId) -or [string]::IsNullOrWhiteSpace($SpanDir)) { throw 'RunId and SpanDir are required' }
$res = Invoke-FleetSpanPublish -RunId $RunId -SpanDir $SpanDir -ExpectedLanes $ExpectedLanes -LedgerPath $LedgerPath
Write-Output $res.Line
foreach ($f in $res.Failed) { [Console]::Error.WriteLine("span-publish: FAILED $f") }
if ($res.Failed.Count -gt 0) { exit 1 }
exit 0
