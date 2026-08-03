# Fixture tests for Assert-FleetLaneCompletion.ps1 (end-of-run lane completion gate).
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Assert-FleetLaneCompletion.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('fleet-lane-completion-test-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$failed = 0
$utf8 = New-Object Text.UTF8Encoding $false

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Case([string]$Name, [scriptblock]$Body) {
  try {
    & $Body
    $script:passed++
    Write-Host "PASS $Name"
  }
  catch {
    $script:failed++
    Write-Host "FAIL $Name - $($_.Exception.Message)"
  }
}

function Invoke-Gate {
  param(
    [string]$LaneDir,
    [string[]]$DeliverableDir = @(),
    [string[]]$ExpectLane = @(),
    [string]$Mode = 'text',
    [string]$Pattern = '*-result.json'
  )
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
    '-LaneDir', $LaneDir, '-Pattern', $Pattern, '-Mode', $Mode
  )
  if ($DeliverableDir.Count -gt 0) {
    $args += '-DeliverableDir'
    $args += $DeliverableDir
  }
  # -File cannot take repeated -ExpectLane (ParameterAlreadyBound). Pass comma-joined token;
  # Assert-FleetLaneCompletion splits commas when normalizing.
  if ($ExpectLane.Count -gt 0) {
    $args += '-ExpectLane'
    $args += ($ExpectLane -join ',')
  }
  $old = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $raw = & powershell.exe @args 2>&1
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $old
  }
  $text = ($raw | ForEach-Object { "$_" }) -join "`n"
  return [pscustomobject]@{ ExitCode = $code; Raw = $text }
}

function New-FixtureDir([string]$Name) {
  $dir = Join-Path $root $Name
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  return $dir
}

function Write-Result([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Content, $utf8)
}

try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null

  Case 'all-ok fixture -> exit 0, summary counts correct' {
    $lane = New-FixtureDir 'all-ok'
    Write-Result (Join-Path $lane 'a-result.json') '{"status":"ok","lane":"a"}'
    Write-Result (Join-Path $lane 'nested\b-result.json') '{"status":"done"}'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 2 audited, 2 ok, 0 rescued, 0 incomplete, 0 partial, 0 empty, 0 unparseable') "summary wrong: $($run.Raw)"
  }

  Case '0-byte result with NO deliverable dir -> exit 1, counted empty' {
    $lane = New-FixtureDir 'empty-no-rescue'
    Write-Result (Join-Path $lane 'dead-result.json') ''
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 0 ok, 0 rescued, 0 incomplete, 0 partial, 1 empty, 0 unparseable') "summary wrong: $($run.Raw)"
    Assert-True ($run.Raw -match 'EMPTY') "expected EMPTY classification: $($run.Raw)"
  }

  Case '0-byte result WITH deliverable dir holding non-empty file -> exit 0, rescued' {
    $lane = New-FixtureDir 'empty-rescued'
    $deliv = New-FixtureDir 'empty-rescued-deliverables'
    Write-Result (Join-Path $lane 'kimi-result.json') ''
    Write-Result (Join-Path $deliv 'artifact.md') '# real deliverable'
    $run = Invoke-Gate -LaneDir $lane -DeliverableDir @($deliv)
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 0 ok, 1 rescued, 0 incomplete, 0 partial, 0 empty, 0 unparseable') "summary wrong: $($run.Raw)"
    Assert-True ($run.Raw -match 'RESCUED') "expected RESCUED: $($run.Raw)"
    Assert-True ($run.Raw -match [regex]::Escape($deliv)) "must name rescuing directory: $($run.Raw)"
  }

  Case 'unparseable result -> exit 1' {
    $lane = New-FixtureDir 'unparseable'
    Write-Result (Join-Path $lane 'bad-result.json') 'not-json{'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 0 ok, 0 rescued, 0 incomplete, 0 partial, 0 empty, 1 unparseable') "summary wrong: $($run.Raw)"
    Assert-True ($run.Raw -match 'UNPARSEABLE') "expected UNPARSEABLE: $($run.Raw)"
  }

  Case 'result whose JSON status is timeout -> exit 1 (incomplete)' {
    $lane = New-FixtureDir 'timeout'
    Write-Result (Join-Path $lane 't-result.json') '{"status":"timeout","reason":"deadline"}'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 0 ok, 0 rescued, 1 incomplete, 0 partial, 0 empty, 0 unparseable') "summary wrong: $($run.Raw)"
    Assert-True ($run.Raw -match 'INCOMPLETE') "expected INCOMPLETE: $($run.Raw)"
  }

  Case 'empty lane directory (no matches) -> exit 1 with 0 audited' {
    $lane = New-FixtureDir 'no-matches'
    Write-Result (Join-Path $lane 'notes.txt') 'ignore me'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 0 audited') "expected 0 audited: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 0 audited, 0 ok, 0 rescued, 0 incomplete, 0 partial, 0 empty, 0 unparseable') "full zero summary: $($run.Raw)"
  }

  Case 'missing lane directory -> non-zero exit and explicit message' {
    $missing = Join-Path $root 'does-not-exist-lane-dir'
    $run = Invoke-Gate -LaneDir $missing
    Assert-True ($run.ExitCode -ne 0) "expected non-zero: $($run.Raw)"
    Assert-True ($run.Raw -match 'LaneDir does not exist') "expected explicit message: $($run.Raw)"
  }

  Case 'json mode: output parses, counts match text mode, same exit code' {
    $lane = New-FixtureDir 'json-mode'
    $deliv = New-FixtureDir 'json-mode-deliverables'
    Write-Result (Join-Path $lane 'ok-result.json') '{"status":"ok"}'
    Write-Result (Join-Path $lane 'empty-result.json') ''
    Write-Result (Join-Path $lane 'bad-result.json') '{broken'
    Write-Result (Join-Path $lane 'to-result.json') '{"status":"timeout"}'
    Write-Result (Join-Path $deliv 'out.md') 'payload'
    $textRun = Invoke-Gate -LaneDir $lane -DeliverableDir @($deliv) -Mode text
    $jsonRun = Invoke-Gate -LaneDir $lane -DeliverableDir @($deliv) -Mode json
    Assert-True ($textRun.ExitCode -eq $jsonRun.ExitCode) "exit codes differ text=$($textRun.ExitCode) json=$($jsonRun.ExitCode)"
    Assert-True ($textRun.ExitCode -eq 1) "mixed fixture should fail: $($textRun.Raw)"
    $obj = $null
    try { $obj = $jsonRun.Raw | ConvertFrom-Json -ErrorAction Stop } catch { throw "json mode did not parse: $($jsonRun.Raw)" }
    Assert-True ($obj.audited -eq 4) "audited count: $($jsonRun.Raw)"
    Assert-True ($obj.ok -eq 1 -and $obj.rescued -eq 1 -and $obj.incomplete -eq 1 -and $obj.partial -eq 0 -and $obj.empty -eq 0 -and $obj.unparseable -eq 1) "counts mismatch: $($jsonRun.Raw)"
    Assert-True ($obj.lanes.Count -eq 4) "lane array size: $($jsonRun.Raw)"
    Assert-True ($textRun.Raw -match 'lanes: \? expected, 4 audited, 1 ok, 1 rescued, 1 incomplete, 0 partial, 0 empty, 1 unparseable') "text summary: $($textRun.Raw)"
  }

  Case "markdown review lane counts as delivered, not unparseable" {
    # Review/analysis lanes are free-form markdown by contract. Auditing them with a
    # broad pattern must NOT false-fail: that would be the same false-signal class the
    # gate exists to catch. Real regression: 8 .md review results read as UNPARSEABLE.
    $lane = New-FixtureDir 'md-lane'
    Write-Result (Join-Path $lane 'rev-opus-result.md') "# Review

No blockers."
    Write-Result (Join-Path $lane 'impl-result.json') '{"status":"ok"}'
    $run = Invoke-Gate -LaneDir $lane -Pattern '*result*' -Mode json
    Assert-True ($run.ExitCode -eq 0) "markdown lane false-failed: $($run.Raw)"
    $o = $run.Raw | ConvertFrom-Json
    Assert-True ($o.audited -eq 2 -and $o.ok -eq 2 -and $o.unparseable -eq 0) "counts: $($run.Raw)"

    # NEGATIVE CONTROL: a .json result that is truly malformed is still UNPARSEABLE.
    $lane2 = New-FixtureDir 'md-lane-broken'
    Write-Result (Join-Path $lane2 'broken-result.json') 'not json at all'
    $run2 = Invoke-Gate -LaneDir $lane2 -Pattern '*result*' -Mode json
    Assert-True ($run2.ExitCode -eq 1) "malformed json must still fail: $($run2.Raw)"
    Assert-True ((($run2.Raw | ConvertFrom-Json).unparseable) -eq 1) "unparseable count: $($run2.Raw)"

    # NEGATIVE CONTROL: an EMPTY markdown result is still a dead lane.
    $lane3 = New-FixtureDir 'md-lane-empty'
    Write-Result (Join-Path $lane3 'dead-result.md') ''
    $run3 = Invoke-Gate -LaneDir $lane3 -Pattern '*result*' -Mode json
    Assert-True ($run3.ExitCode -eq 1) "empty markdown must fail: $($run3.Raw)"
    Assert-True ((($run3.Raw | ConvertFrom-Json).empty) -eq 1) "empty count: $($run3.Raw)"
  }

  Case 'NEGATIVE ExpectLane: only A present of A,B -> exit 1, B MISSING by name' {
    $lane = New-FixtureDir 'expect-missing-b'
    Write-Result (Join-Path $lane 'A-result.json') '{"status":"ok"}'
    $run = Invoke-Gate -LaneDir $lane -ExpectLane @('A-result.json', 'B-result.json') -Mode json
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    $o = $null
    try { $o = $run.Raw | ConvertFrom-Json -ErrorAction Stop } catch { throw "json parse: $($run.Raw)" }
    Assert-True ($o.expected -eq 2) "expected=2: $($run.Raw)"
    Assert-True ($o.missing -eq 1) "missing=1: $($run.Raw)"
    Assert-True ($o.audited -eq 1 -and $o.ok -eq 1) "audited/ok: $($run.Raw)"
    $rawMl = $o.missing_lanes
    if ($null -eq $rawMl) { $names = @() }
    elseif ($rawMl -is [string]) { $names = @($rawMl) }
    else { $names = @($rawMl | ForEach-Object { "$_" }) }
    Assert-True ($names -contains 'B-result.json') "B-result.json in missing_lanes: $($run.Raw)"
    Assert-True ($run.Raw -match 'MISSING') "MISSING classification: $($run.Raw)"
    Assert-True ($run.Raw -match 'B-result\.json') "B named: $($run.Raw)"
    $textRun = Invoke-Gate -LaneDir $lane -ExpectLane @('A-result.json', 'B-result.json')
    Assert-True ($textRun.ExitCode -eq 1) "text exit 1: $($textRun.Raw)"
    Assert-True ($textRun.Raw -match 'lanes: 2 expected, 1 audited, 1 ok, 0 rescued, 0 incomplete, 0 partial, 0 empty, 0 unparseable, 1 missing') "summary: $($textRun.Raw)"
    Assert-True ($textRun.Raw -match 'MISSING') "text MISSING: $($textRun.Raw)"
    Assert-True ($textRun.Raw -match 'B-result\.json') "text names B: $($textRun.Raw)"
  }

  Case 'POSITIVE ExpectLane: both present and ok -> exit 0, 2 expected' {
    $lane = New-FixtureDir 'expect-both-ok'
    Write-Result (Join-Path $lane 'A-result.json') '{"status":"ok"}'
    Write-Result (Join-Path $lane 'B-result.json') '{"status":"done"}'
    $run = Invoke-Gate -LaneDir $lane -ExpectLane @('A-result.json', 'B-result.json')
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: 2 expected, 2 audited, 2 ok, 0 rescued, 0 incomplete, 0 partial, 0 empty, 0 unparseable, 0 missing') "summary: $($run.Raw)"
    $jsonRun = Invoke-Gate -LaneDir $lane -ExpectLane @('A-result.json', 'B-result.json') -Mode json
    Assert-True ($jsonRun.ExitCode -eq 0) "json exit 0: $($jsonRun.Raw)"
    $o = $jsonRun.Raw | ConvertFrom-Json
    Assert-True ($o.expected -eq 2 -and $o.missing -eq 0) "json expected/missing: $($jsonRun.Raw)"
    Assert-True (@($o.missing_lanes).Count -eq 0) "missing_lanes empty: $($jsonRun.Raw)"
  }

  Case 'POSITIVE ExpectLane: empty lane rescued by bound deliverable -> exit 0' {
    $lane = New-FixtureDir 'expect-empty-rescued'
    $deliv = New-FixtureDir 'expect-empty-rescued-deliv'
    Write-Result (Join-Path $lane 'A-result.json') ''
    Write-Result (Join-Path $deliv 'artifact.md') '# bound deliverable'
    $bound = "A-result.json=$deliv"
    $run = Invoke-Gate -LaneDir $lane -ExpectLane @('A-result.json') -DeliverableDir @($bound)
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True ($run.Raw -match 'RESCUED') "RESCUED: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: 1 expected, 1 audited, 0 ok, 1 rescued, 0 incomplete, 0 partial, 0 empty, 0 unparseable, 0 missing') "summary: $($run.Raw)"
  }

  Case 'NEGATIVE ExpectLane: empty lane NOT rescued -> exit 1' {
    $lane = New-FixtureDir 'expect-empty-dead'
    Write-Result (Join-Path $lane 'A-result.json') ''
    $run = Invoke-Gate -LaneDir $lane -ExpectLane @('A-result.json')
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Raw -match 'EMPTY') "EMPTY: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: 1 expected, 1 audited, 0 ok, 0 rescued, 0 incomplete, 0 partial, 1 empty, 0 unparseable, 0 missing') "summary: $($run.Raw)"
  }

  Case 'POSITIVE no ExpectLane: prior behaviour, expectation unset in summary' {
    $lane = New-FixtureDir 'no-expect-unset'
    Write-Result (Join-Path $lane 'solo-result.json') '{"status":"ok"}'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 1 ok, 0 rescued, 0 incomplete, 0 partial, 0 empty, 0 unparseable') "unset summary: $($run.Raw)"
    Assert-True ($run.Raw -notmatch ',\s*\d+ missing') "must not append missing when unset: $($run.Raw)"
    $jsonRun = Invoke-Gate -LaneDir $lane -Mode json
    $o = $jsonRun.Raw | ConvertFrom-Json
    Assert-True ($null -eq $o.expected) "json expected absent/null when unset: $($jsonRun.Raw)"
    Assert-True ($null -eq $o.missing -and $null -eq $o.missing_lanes) "json missing fields absent when unset: $($jsonRun.Raw)"
  }

  Case 'NEGATIVE timeout_partial incident -> exit 1, partial bucket not ok' {
    $lane = New-FixtureDir 'timeout-partial-incident'
    Write-Result (Join-Path $lane 'killed-result.json') '{"status":"timeout_partial","timed_out":true,"exit_code":-1}'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Raw -match 'PARTIAL') "expected PARTIAL classification: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 0 ok, 0 rescued, 0 incomplete, 1 partial, 0 empty, 0 unparseable') "summary wrong: $($run.Raw)"
    $jsonRun = Invoke-Gate -LaneDir $lane -Mode json
    Assert-True ($jsonRun.ExitCode -eq 1) "json exit 1: $($jsonRun.Raw)"
    $o = $jsonRun.Raw | ConvertFrom-Json
    Assert-True ($o.partial -eq 1 -and $o.ok -eq 0 -and $o.incomplete -eq 0) "partial bucket: $($jsonRun.Raw)"
  }

  Case 'NEGATIVE invented status weird_new_state -> exit 1 (allowlist)' {
    $lane = New-FixtureDir 'weird-status'
    Write-Result (Join-Path $lane 'w-result.json') '{"status":"weird_new_state"}'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Raw -match 'INCOMPLETE') "expected INCOMPLETE: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 0 ok, 0 rescued, 1 incomplete, 0 partial, 0 empty, 0 unparseable') "summary wrong: $($run.Raw)"
  }

  Case 'NEGATIVE status ok but timed_out true -> exit 1' {
    $lane = New-FixtureDir 'ok-timed-out'
    Write-Result (Join-Path $lane 't-result.json') '{"status":"ok","timed_out":true}'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Raw -match 'INCOMPLETE') "expected INCOMPLETE: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 0 ok, 0 rescued, 1 incomplete, 0 partial, 0 empty, 0 unparseable') "summary wrong: $($run.Raw)"
  }

  Case 'NEGATIVE status ok but nonzero exit_code -> exit 1' {
    $lane = New-FixtureDir 'ok-exit-3'
    Write-Result (Join-Path $lane 'e-result.json') '{"status":"ok","exit_code":3}'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Raw -match 'INCOMPLETE') "expected INCOMPLETE: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 0 ok, 0 rescued, 1 incomplete, 0 partial, 0 empty, 0 unparseable') "summary wrong: $($run.Raw)"
  }

  Case 'POSITIVE status ok alone -> exit 0' {
    $lane = New-FixtureDir 'ok-alone'
    Write-Result (Join-Path $lane 'ok-result.json') '{"status":"ok"}'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 1 ok, 0 rescued, 0 incomplete, 0 partial, 0 empty, 0 unparseable') "summary wrong: $($run.Raw)"
  }

  Case 'POSITIVE status ok with exit_code 0 -> exit 0' {
    $lane = New-FixtureDir 'ok-exit-0'
    Write-Result (Join-Path $lane 'ok-result.json') '{"status":"ok","exit_code":0}'
    $run = Invoke-Gate -LaneDir $lane
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True ($run.Raw -match 'lanes: \? expected, 1 audited, 1 ok, 0 rescued, 0 incomplete, 0 partial, 0 empty, 0 unparseable') "summary wrong: $($run.Raw)"
  }

  Write-Host "$passed passed, $failed failed"
  if ($failed) { exit 1 } else { exit 0 }
}
finally {
  if (Test-Path -LiteralPath $root) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  }
}
