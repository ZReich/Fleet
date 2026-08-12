# Packet-readiness predicates (Sol D2, fleet-reviewburn-20260811). One helper owns the checks
# that must hold BEFORE any voice burns tokens; Get-FleetReviewPacket.ps1 (freeze), the
# pre-dispatch lint CLI, and certification all consume these same predicates.
# PS 5.1-safe, ASCII only.

function Test-FleetPreflightStatusLineCanonical([string]$Line) {
  if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
  return [bool]($Line -cmatch '^review-preflight: READY \| selected: \d+ \| passed: \d+ \| cached: \d+ \| failed: 0$')
}

# Every path component from (and including) $Root down to $Leaf must be reparse-free, so a
# packet-local junction cannot point evidence outside the packet (Terra H3 2026-08-11).
# Any error = unsafe (fail closed).
function Assert-FleetReparseFreeUnder([string]$Root, [string]$Leaf) {
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $cur = [IO.Path]::GetFullPath($Leaf)
  while ($true) {
    $item = Get-Item -LiteralPath $cur -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "reparse point in path: $cur" }
    if ($cur.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = [IO.Path]::GetFullPath((Split-Path -Parent $cur)).TrimEnd('\')
    if ($parent -ceq $cur) { throw "path walk escaped root: $cur" }
    $cur = $parent
  }
}

# RED-evidence contract on test-results.json. behavior|hard REQUIRE a nonzero RED denominator
# with per-control evidence; mechanical may use 0/0 ONLY as an explicit statement that no
# test/gate/validator/oracle changed. Throws with an actionable message on violation.
function Assert-FleetRedEvidence {
  param([Parameter(Mandatory)]$TestResults, [Parameter(Mandatory)][string]$PacketDir,
    [Parameter(Mandatory)][ValidateSet('mechanical', 'behavior', 'hard')][string]$ReviewRisk)
  $names = @($TestResults.PSObject.Properties.Name)
  $hasRed = ('red_denominator' -in $names)
  if (-not $hasRed) {
    # A present test-results.json must state its RED position explicitly even at mechanical
    # (0/0 is a claim, absence is not) — Terra M4 2026-08-11.
    throw "test-results.json missing red_denominator/red_observed/red_controls (required whenever test-results.json is present; mechanical may claim 0/0): record the failing-first (RED) proof for each changed check"
  }
  $den = -1; $obs = -1
  if (-not [int]::TryParse([string]$TestResults.red_denominator, [ref]$den) -or $den -lt 0) { throw 'test-results.json red_denominator must be a non-negative integer' }
  if ('red_observed' -notin $names -or -not [int]::TryParse([string]$TestResults.red_observed, [ref]$obs) -or $obs -lt 0) { throw 'test-results.json red_observed must be a non-negative integer' }
  if ($obs -ne $den) { throw "test-results.json red_observed ($obs) must equal red_denominator ($den)" }
  $controls = @()
  if ('red_controls' -in $names -and $null -ne $TestResults.red_controls) { $controls = @($TestResults.red_controls) }
  if ($controls.Count -ne $den) { throw "test-results.json red_controls count ($($controls.Count)) must equal red_denominator ($den)" }
  if ($ReviewRisk -ne 'mechanical' -and $den -lt 1) { throw "review_risk=$ReviewRisk requires red_denominator >= 1 (a 0/0 RED claim is only valid for mechanical changes)" }
  $packetFull = [IO.Path]::GetFullPath($PacketDir).TrimEnd('\')
  $seenIds = @{}
  foreach ($c in $controls) {
    $cn = @($c.PSObject.Properties.Name)
    foreach ($f in @('id', 'command', 'expected_failure', 'observed_exit_code', 'sample', 'evidence_path', 'evidence_sha256')) {
      if ($f -notin $cn -or [string]::IsNullOrWhiteSpace([string]$c.$f)) { throw "test-results.json red_controls entry missing nonempty '$f'" }
    }
    $cid = [string]$c.id
    if ($seenIds.ContainsKey($cid)) { throw "test-results.json duplicate red_controls id '$cid'" }
    $seenIds[$cid] = $true
    $ec = 0
    if (-not [int]::TryParse([string]$c.observed_exit_code, [ref]$ec)) { throw "red_controls '$cid' observed_exit_code not an integer" }
    if ($ec -eq 0) { throw "red_controls '$cid' observed_exit_code is 0 - a RED control must actually fail" }
    $rel = ([string]$c.evidence_path).Replace('/', '\').Trim('\')
    if ($rel -match '(^|\\)\.\.(\\|$)' -or [IO.Path]::IsPathRooted($rel)) { throw "red_controls '$cid' evidence_path escapes the packet: $($c.evidence_path)" }
    $full = [IO.Path]::GetFullPath((Join-Path $packetFull $rel))
    if (-not ($full + '\').StartsWith($packetFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "red_controls '$cid' evidence_path escapes the packet: $($c.evidence_path)" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "red_controls '$cid' evidence file missing: $rel" }
    try { Assert-FleetReparseFreeUnder -Root $packetFull -Leaf $full } catch { throw "red_controls '$cid' evidence path unsafe: $($_.Exception.Message)" }
    $want = ([string]$c.evidence_sha256).ToLowerInvariant()
    if ($want -notmatch '^[0-9a-f]{64}$') { throw "red_controls '$cid' evidence_sha256 not a sha256 hex" }
    $got = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $want) { throw "red_controls '$cid' evidence hash mismatch: $rel" }
  }
}

function Assert-FleetSingleReviewProfile([string]$PlanPath) {
  if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) { throw "locked-plan.md missing: $PlanPath" }
  $text = [IO.File]::ReadAllText($PlanPath)
  $hits = [regex]::Matches($text, '(?m)^\s*review_profile\s*:\s*(general|security-sensitive)\s*$')
  if ($hits.Count -eq 0) { throw 'locked-plan.md missing review_profile: general|security-sensitive' }
  if ($hits.Count -gt 1) { throw 'locked-plan.md has duplicate review_profile lines' }
}

# Full readiness evaluation: run the frozen-packet gate (which owns artifact presence, hashes,
# gate-evidence shapes, plan scope, preflight READY binding) then the pre-dispatch predicates
# above. Writes diagnostic packet-readiness.json (never trusted; certification re-derives).
function Get-FleetPacketReadiness {
  param([Parameter(Mandatory)][string]$PacketDir,
    [Parameter(Mandatory)][ValidateSet('mechanical', 'behavior', 'hard')][string]$ReviewRisk,
    [string]$RunId = '', [string]$ScriptsRoot = $PSScriptRoot)
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $checks = New-Object System.Collections.ArrayList
  $packetSha = ''
  $ok = $true
  function Add-Check([System.Collections.ArrayList]$List, [string]$Name, [bool]$Passed, [string]$Detail) {
    [void]$List.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
  }
  try {
    $json = & (Join-Path $ScriptsRoot 'Get-FleetReviewPacket.ps1') -PacketDir $PacketDir -ReviewRisk $ReviewRisk
    $manifest = $json | ConvertFrom-Json
    $packetSha = [string]$manifest.packet_sha256
    Add-Check $checks 'frozen_packet_gate' $true "packet_sha256=$packetSha"
  } catch {
    $ok = $false; Add-Check $checks 'frozen_packet_gate' $false $_.Exception.Message
  }
  if ($ok) {
    try {
      Assert-FleetSingleReviewProfile (Join-Path $PacketDir 'locked-plan.md')
      Add-Check $checks 'single_review_profile' $true ''
    } catch { $ok = $false; Add-Check $checks 'single_review_profile' $false $_.Exception.Message }
    try {
      $pf = Get-Content -LiteralPath (Join-Path $PacketDir 'review-preflight.json') -Raw | ConvertFrom-Json
      $line = [string]$pf.status_line
      if (-not (Test-FleetPreflightStatusLineCanonical $line)) { throw "review-preflight.json status_line not canonical: '$line'" }
      Add-Check $checks 'preflight_status_line_canonical' $true ''
    } catch { $ok = $false; Add-Check $checks 'preflight_status_line_canonical' $false $_.Exception.Message }
    try {
      $trPath = Join-Path $PacketDir 'test-results.json'
      if (Test-Path -LiteralPath $trPath -PathType Leaf) {
        $tr = Get-Content -LiteralPath $trPath -Raw | ConvertFrom-Json
        Assert-FleetRedEvidence -TestResults $tr -PacketDir $PacketDir -ReviewRisk $ReviewRisk
      } elseif ($ReviewRisk -ne 'mechanical') { throw "test-results.json required for review_risk=$ReviewRisk" }
      Add-Check $checks 'red_evidence' $true ''
    } catch { $ok = $false; Add-Check $checks 'red_evidence' $false $_.Exception.Message }
  }
  $status = if ($ok) { 'READY' } else { 'BLOCKED' }
  $statusLine = "packet-readiness: $status | checks: $(@($checks | Where-Object { $_.passed }).Count)/$($checks.Count)"
  $doc = [ordered]@{
    schema_version = '1'; run_id = $RunId; packet_sha256 = $packetSha; status = $status
    status_line = $statusLine; checks = @($checks); checked_at_utc = [datetimeoffset]::UtcNow.ToString('o')
  }
  try {
    [IO.File]::WriteAllText((Join-Path $PacketDir 'packet-readiness.json'), (($doc | ConvertTo-Json -Depth 6) + "`n"), $utf8)
  } catch { }
  return [pscustomobject]$doc
}

# Gate-evidence shape validators (moved from Get-FleetReviewPacket.ps1 at the D2 split:
# readiness predicates live together so freeze, pre-dispatch lint, and certification share them).
function Assert-TestResultsJson {
  param($Value, [string]$Label)
  if ($null -eq $Value) { throw "Frozen review packet is incomplete: $Label is not valid JSON" }
  $names = @($Value.PSObject.Properties.Name)
  if ("schema_version" -notin $names -or "status" -notin $names -or "commands" -notin $names) {
    throw "Frozen review packet is incomplete: $Label missing required fields"
  }
  if ([string]$Value.schema_version -ne "1") {
    throw "Frozen review packet is incomplete: $Label schema_version must be 1"
  }
  if ([string]$Value.status -notin @("passed", "failed")) {
    throw "Frozen review packet is incomplete: $Label status must be passed|failed"
  }
  if ($null -eq $Value.commands -or $Value.commands -is [string] -or $Value.commands -isnot [Collections.IEnumerable]) {
    throw "Frozen review packet is incomplete: $Label commands must be an array"
  }
  # A "passed" suite that ran NOTHING is the false-green this gate exists to stop
  # (panel-found 2026-07-26: an empty commands[] sailed through a hard-risk packet).
  if ([string]$Value.status -eq "passed" -and @($Value.commands).Count -eq 0) {
    throw "Frozen review packet is incomplete: $Label claims status=passed with zero commands - no gate ran"
  }
  foreach ($command in @($Value.commands)) {
    $cNames = @($command.PSObject.Properties.Name)
    if ("command" -notin $cNames -or "exit_code" -notin $cNames -or "status" -notin $cNames) {
      throw "Frozen review packet is incomplete: $Label command entry missing required fields"
    }
    if ([string]::IsNullOrWhiteSpace([string]$command.command)) {
      throw "Frozen review packet is incomplete: $Label command entry has blank command"
    }
    $exitCode = 0
    if (-not [int]::TryParse([string]$command.exit_code, [ref]$exitCode)) {
      throw "Frozen review packet is incomplete: $Label command entry has non-integer exit_code"
    }
    if ([string]$command.status -notin @("passed", "failed")) {
      throw "Frozen review packet is incomplete: $Label command entry status must be passed|failed"
    }
    # Top-level "passed" must be consistent with the commands beneath it: a suite cannot
    # pass while one of its gates failed or exited nonzero.
    if ([string]$Value.status -eq "passed" -and ([string]$command.status -ne "passed" -or $exitCode -ne 0)) {
      throw "Frozen review packet is incomplete: $Label claims status=passed but command '$([string]$command.command)' reports status=$([string]$command.status) exit_code=$exitCode"
    }
    # EVIDENCE INTEGRITY (2026-07-26): a passing gate must state WHAT IT ACTUALLY
    # EXERCISED. Recurring failure class on this codebase: green signals produced by a
    # path that never ran the real thing - a suite that collected 0 tests, CI that
    # skipped the frontend suite, an acceptance run that printed 100% coverage from 3 of
    # 8 documents. A pass with no denominator, or a zero denominator, is NOT a pass.
    if ([string]$command.status -eq "passed") {
      $sample = [string]$command.sample
      if ("sample" -notin $cNames -or [string]::IsNullOrWhiteSpace($sample)) {
        throw "Frozen review packet is incomplete: $Label passed command entry needs a nonempty sample (what it exercised, e.g. '274 tests', '8/8 documents')"
      }
      # Denominator required: digit-free prose ("all tests green") is a false green.
      $numbers = [regex]::Matches($sample, '\d+(?:\.\d+)?')
      if ($numbers.Count -eq 0) {
        throw "Frozen review packet is incomplete: $Label passed command entry sample must include a count of what ran (e.g. '274 tests', '8/8 documents'); got '$sample'"
      }
      $allZero = $true
      foreach ($n in $numbers) { if ([double]$n.Value -ne 0) { $allZero = $false; break } }
      if ($allZero) {
        throw "Frozen review packet is incomplete: $Label passed command entry has a zero sample ('$sample') - a gate that exercised nothing is not a pass"
      }
    }
  }
}

# Fallow evidence: exactly three shapes — native audit, legacy fleet, or not_measured.
# Native: fallow audit --format json (kind=audit, verdict, summary with integer counters).
# Legacy: findings[] + summary.new_findings (packets already written that way).
# not_measured: explicit skip + reason; no findings counter. Junk JSON is green-without-exercise.
function Assert-FallowResultsJson {
  param($Value, [string]$Label)
  if ($null -eq $Value) { throw "Frozen review packet is incomplete: $Label is not valid JSON" }
  $names = @($Value.PSObject.Properties.Name)

  # Shape 3: explicit not_measured (PowerShell-only repos, Fallow never ran).
  if ("status" -in $names -and [string]$Value.status -eq "not_measured") {
    $reason = if ("reason" -in $names) { [string]$Value.reason } else { "" }
    if ([string]::IsNullOrWhiteSpace($reason)) {
      throw "Frozen review packet is incomplete: $Label status=not_measured requires a nonempty reason"
    }
    $hasFindings = $false
    if ("new_findings" -in $names -and $null -ne $Value.new_findings) { $hasFindings = $true }
    if (-not $hasFindings -and "summary" -in $names -and $null -ne $Value.summary) {
      $sNames = @($Value.summary.PSObject.Properties.Name)
      if ("new_findings" -in $sNames -and $null -ne $Value.summary.new_findings) { $hasFindings = $true }
    }
    if ($hasFindings) {
      throw "Frozen review packet is incomplete: $Label status=not_measured cannot report new_findings (absent or null only; 0 is a false clean signal)"
    }
    return
  }

  # Shape 1: native Fallow audit (kind=audit + verdict + summary integer counters).
  if ("kind" -in $names -and [string]$Value.kind -eq "audit") {
    if ("verdict" -notin $names -or [string]::IsNullOrWhiteSpace([string]$Value.verdict)) {
      throw "Frozen review packet is incomplete: $Label kind=audit requires a verdict"
    }
    if ("summary" -notin $names -or $null -eq $Value.summary) {
      throw "Frozen review packet is incomplete: $Label kind=audit requires a summary object"
    }
    $counterTotal = 0
    $counterCount = 0
    foreach ($p in @($Value.summary.PSObject.Properties)) {
      $n = 0
      if ($null -ne $p.Value -and [int]::TryParse([string]$p.Value, [ref]$n) -and $n -ge 0) {
        $counterCount++
        $counterTotal += $n
      }
    }
    if ($counterCount -eq 0) {
      throw "Frozen review packet is incomplete: $Label kind=audit summary must include at least one integer issue counter"
    }
    $verdict = [string]$Value.verdict
    if ($verdict -eq "pass" -and $counterTotal -gt 0) {
      throw "Frozen review packet is incomplete: $Label verdict=pass contradicts nonzero issue counters ($counterTotal)"
    }
    if ($verdict -eq "fail" -and $counterTotal -eq 0) {
      throw "Frozen review packet is incomplete: $Label verdict=fail contradicts zero issue counters"
    }
    return
  }

  # Shape 2: legacy fleet measured (status passed|failed + findings[] + summary.new_findings).
  if ("status" -notin $names) {
    throw "Frozen review packet is incomplete: $Label unrecognised shape (need kind=audit, legacy status+findings, or status=not_measured)"
  }
  $status = [string]$Value.status
  if ($status -notin @("passed", "failed")) {
    throw "Frozen review packet is incomplete: $Label status must be passed|failed|not_measured (or use native kind=audit)"
  }
  if ("findings" -notin $names -or $null -eq $Value.findings -or $Value.findings -is [string] -or $Value.findings -isnot [Collections.IEnumerable]) {
    throw "Frozen review packet is incomplete: $Label measured status requires findings array"
  }
  if ("summary" -notin $names -or $null -eq $Value.summary) {
    throw "Frozen review packet is incomplete: $Label measured status requires summary.new_findings (integer under summary, not top-level)"
  }
  $sNames = @($Value.summary.PSObject.Properties.Name)
  if ("new_findings" -notin $sNames -or $null -eq $Value.summary.new_findings) {
    throw "Frozen review packet is incomplete: $Label measured status requires summary.new_findings as a non-negative integer"
  }
  $newFindings = 0
  if (-not [int]::TryParse([string]$Value.summary.new_findings, [ref]$newFindings) -or $newFindings -lt 0) {
    throw "Frozen review packet is incomplete: $Label summary.new_findings must be a non-negative integer"
  }
  if ($status -eq "passed" -and $newFindings -gt 0) {
    throw "Frozen review packet is incomplete: $Label status=passed contradicts summary.new_findings=$newFindings"
  }
  if ($status -eq "failed" -and $newFindings -eq 0) {
    throw "Frozen review packet is incomplete: $Label status=failed contradicts summary.new_findings=0"
  }
}
