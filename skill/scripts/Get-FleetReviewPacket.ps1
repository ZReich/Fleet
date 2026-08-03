[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PacketDir,
  [ValidateSet("mechanical", "behavior", "hard")]
  [string]$ReviewRisk = "mechanical",
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)

$requiredNames = @(
  "base.sha",
  "final.diff",
  "touched-files.txt",
  "locked-plan.md",
  "acceptance-evidence.md",
  "gate-evidence.md"
)

$resolvedPacketDir = (Resolve-Path -LiteralPath $PacketDir).Path
if (-not (Test-Path -LiteralPath $resolvedPacketDir -PathType Container)) {
  throw "Review packet directory is not a directory: $PacketDir"
}

function Get-ArtifactHashEntry {
  param([string]$Name, [string]$FullPath, [string]$ArtifactText)
  $artifactBytes = $utf8.GetBytes($ArtifactText)
  if ($artifactBytes.Length -eq 0) {
    throw "Frozen review packet is incomplete: artifact '$Name' has no transport bytes"
  }
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    $artifactHash = -join ($hasher.ComputeHash($artifactBytes) | ForEach-Object { $_.ToString("x2") })
  }
  finally {
    $hasher.Dispose()
  }
  return [ordered]@{
    name = $Name
    path = $FullPath
    bytes = [int64]$artifactBytes.Length
    sha256 = $artifactHash
  }
}

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

# PACKET SCOPE (panel-found 2026-07-26): plan claims must appear in touched-files.
function Assert-PlanScopeCovered {
  param([string]$PlanPath, [string]$TouchedPath)
  if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) { return }
  if (-not (Test-Path -LiteralPath $TouchedPath -PathType Leaf)) { return }
  $backslash = [string][char]92  # escape-proof: literal backslash without quoting games
  $planText = [IO.File]::ReadAllText($PlanPath)
  # git name-status: STATUS\tpath | R###\told\tnew | bare path. Bare=basename; /=\.
  $touchedNorm = @([IO.File]::ReadAllText($TouchedPath) -split '\r?\n' | ForEach-Object {
    $p = $_.Trim() -split "`t"
    if ($p.Count -ge 2 -and $p[0] -match '^[A-Z]\d*$') { $p = if ($p.Count -ge 3) { $p[1..2] } else { @($p[1]) } }
    $p | ForEach-Object { $_.Replace($backslash, '/').Trim().Trim('/') } | Where-Object { $_ }
  })
  $touchedBase = @($touchedNorm | ForEach-Object { $_.Split('/')[-1] })
  $claimPat = '`([A-Za-z0-9_./' + $backslash + $backslash + '-]+\.(?:ps1|psm1|md|json|jsonl|js|ts|tsx|py))`'
  $claimed = [regex]::Matches($planText, $claimPat) | ForEach-Object { $_.Groups[1].Value.Replace($backslash, '/').Trim('/') } | Sort-Object -Unique
  $missing = @()
  foreach ($c in $claimed) {
    $pool = if ($c -match '/') { $touchedNorm } else { $touchedBase }
    if (@($pool | Where-Object { $_.Equals($c, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { $missing += $c }
  }
  if ($missing.Count -gt 0) {
    throw ("Frozen review packet is incomplete: locked-plan.md names files absent from touched-files.txt: " + ($missing -join ', ') + ". Widen the diff range or drop them from the plan - reviewers must not be told to attack files the packet does not carry.")
  }
}

$artifacts = @()
foreach ($name in $requiredNames) {
  $path = Join-Path $resolvedPacketDir $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Frozen review packet is incomplete: missing required artifact '$name' in $resolvedPacketDir"
  }

  $item = Get-Item -LiteralPath $path
  if ($item.Length -eq 0) {
    throw "Frozen review packet is incomplete: required artifact '$name' is empty"
  }

  # Match Get-FleetReviewBudget, Invoke-Opus48, and Invoke-PiGlm exactly: all
  # review artifacts are serialized as UTF-8 text without BOM before transport.
  $artifactText = [IO.File]::ReadAllText($item.FullName)
  $artifacts += Get-ArtifactHashEntry -Name $name -FullPath $item.FullName -ArtifactText $artifactText
}

Assert-PlanScopeCovered -PlanPath (Join-Path $resolvedPacketDir 'locked-plan.md') -TouchedPath (Join-Path $resolvedPacketDir 'touched-files.txt')

# Optional context + machine gate artifacts in stable order (D4):
# six required, caller-context.md, test-results.json, fallow-results.json.
# mechanical: optional if present must be nonempty valid JSON (for JSON files) and hashed.
# behavior|hard: test-results.json and fallow-results.json required.
$optionalNames = @("caller-context.md", "test-results.json", "fallow-results.json")
$riskRequired = @()
if ($ReviewRisk -in @("behavior", "hard")) {
  $riskRequired = @("test-results.json", "fallow-results.json")
}
foreach ($name in $optionalNames) {
  $path = Join-Path $resolvedPacketDir $name
  $exists = Test-Path -LiteralPath $path -PathType Leaf
  if (-not $exists) {
    if ($name -in $riskRequired) {
      throw "Frozen review packet is incomplete: review_risk=$ReviewRisk requires artifact '$name' in $resolvedPacketDir"
    }
    continue
  }
  $item = Get-Item -LiteralPath $path
  $artifactText = if ($item.Length -eq 0) { "" } else { [IO.File]::ReadAllText($item.FullName) }
  # Machine gate artifacts: when present, must be nonempty valid JSON at every risk level (D4).
  if ($name -in @("test-results.json", "fallow-results.json")) {
    if ($item.Length -eq 0 -or [string]::IsNullOrWhiteSpace($artifactText)) {
      throw "Frozen review packet is incomplete: present machine gate artifact '$name' is empty; a present artifact must be nonempty artifact with valid JSON"
    }
    if ($name -eq "test-results.json") {
      try {
        $parsed = $artifactText | ConvertFrom-Json -ErrorAction Stop
      }
      catch {
        throw "Frozen review packet is incomplete: test-results.json is not valid JSON"
      }
      Assert-TestResultsJson -Value $parsed -Label "test-results.json"
    }
    else {
      try {
        $fallowParsed = $artifactText | ConvertFrom-Json -ErrorAction Stop
      }
      catch {
        throw "Frozen review packet is incomplete: fallow-results.json is not valid JSON"
      }
      Assert-FallowResultsJson -Value $fallowParsed -Label "fallow-results.json"
    }
  }
  else {
    # caller-context.md keeps existing optional empty handling.
    if ($item.Length -eq 0 -or [string]::IsNullOrWhiteSpace($artifactText)) {
      continue
    }
  }
  $artifacts += Get-ArtifactHashEntry -Name $name -FullPath $item.FullName -ArtifactText $artifactText
}

$baseSha = [IO.File]::ReadAllText((Join-Path $resolvedPacketDir "base.sha")).Trim()
if ($baseSha -notmatch '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$') {
  throw "Frozen review packet has invalid base.sha; expected a 40- or 64-character Git object ID"
}

# review_risk participates in packet_sha256 (D4).
$packetMaterial = "review_risk|$ReviewRisk`n" + (($artifacts | ForEach-Object { "$($_.name)|$($_.bytes)|$($_.sha256)" }) -join "`n")
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
$packetHash = -join ($sha256.ComputeHash($utf8.GetBytes($packetMaterial)) | ForEach-Object { $_.ToString("x2") })
}
finally {
  $sha256.Dispose()
}

$result = [ordered]@{
  schema_version = "1"
  review_risk = $ReviewRisk
  packet_dir = $resolvedPacketDir
  artifact_paths = @($artifacts | ForEach-Object { $_.path })
  artifacts = @($artifacts)
  packet_sha256 = $packetHash
}
$json = $result | ConvertTo-Json -Depth 5 -Compress

if ($OutputPath) {
  $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
  $expectedOutputPath = [IO.Path]::GetFullPath((Join-Path $resolvedPacketDir "packet-manifest.json"))
  if (-not [string]::Equals($resolvedOutputPath, $expectedOutputPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Review packet manifest must be written only to $expectedOutputPath"
  }
  $temporaryPath = "$resolvedOutputPath.$PID.tmp"
  try {
    [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $utf8)
    Move-Item -LiteralPath $temporaryPath -Destination $resolvedOutputPath -Force
  }
  finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      Remove-Item -LiteralPath $temporaryPath -Force
    }
  }
}

Write-Output $json
