[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PacketDir,
  [ValidateSet("mechanical", "behavior", "hard")]
  [string]$ReviewRisk = "mechanical",
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'FleetReviewPacketReady.Helpers.ps1')

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

function Get-FrozenTouchedFiles {
  param([string]$RepoPath, [string]$TouchedPath)
  $backslash = [string][char]92
  $seen = @{}
  $entries = New-Object System.Collections.ArrayList
  foreach ($line in @([IO.File]::ReadAllText($TouchedPath) -split '\r?\n')) {
    $parts = @($line.Trim() -split "`t")
    if ($parts.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$parts[0])) { continue }
    $paths = if ($parts.Count -ge 2 -and $parts[0] -match '^[A-Z]\d*$') {
      if ($parts.Count -ge 3) { @($parts[1], $parts[2]) } else { @($parts[1]) }
    } else { @($parts[0]) }
    foreach ($raw in $paths) {
      $relative = ([string]$raw).Replace($backslash, '/').Trim().Trim('/')
      if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($relative)) {
        throw "Frozen review packet has unsafe touched-file path: $raw"
      }
      $key = $relative.ToLowerInvariant(); if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
      $full = [IO.Path]::GetFullPath((Join-Path $RepoPath ($relative.Replace('/', $backslash))))
      if (-not (($full + $backslash).StartsWith($RepoPath.TrimEnd($backslash) + $backslash, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Frozen review packet touched-file escapes repository: $raw"
      }
      $exists = Test-Path -LiteralPath $full -PathType Leaf
      $hash = if ($exists) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
      [void]$entries.Add([ordered]@{ path = $relative; exists = [bool]$exists; sha256 = $hash })
    }
  }
  if ($entries.Count -eq 0) { throw 'Frozen review packet touched-files.txt contains no file paths to anchor' }
  return @($entries)
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
Assert-FleetSingleReviewProfile (Join-Path $resolvedPacketDir 'locked-plan.md')

$previousEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $repoPath = @(& git -C $resolvedPacketDir rev-parse --show-toplevel 2>$null) }
finally { $ErrorActionPreference = $previousEap }
if ($LASTEXITCODE -ne 0 -or $repoPath.Count -lt 1) {
  throw "Frozen review packet directory is not inside a Git repository: $resolvedPacketDir"
}
$repoPath = [IO.Path]::GetFullPath([string]$repoPath[0]).TrimEnd('\\')
$frozenTouchedFiles = Get-FrozenTouchedFiles -RepoPath $repoPath -TouchedPath (Join-Path $resolvedPacketDir 'touched-files.txt')

# T2: selected-voice preflight binding. Packet freeze requires READY evidence that
# matches selected-voices.json run_id. Both files are hashed into the manifest.
$preflightNames = @("selected-voices.json", "review-preflight.json")
$selectedVoicesObj = $null
$reviewPreflightObj = $null
foreach ($name in $preflightNames) {
  $path = Join-Path $resolvedPacketDir $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Frozen review packet is incomplete: missing required artifact '$name' in $resolvedPacketDir"
  }
  $item = Get-Item -LiteralPath $path
  if ($item.Length -eq 0) {
    throw "Frozen review packet is incomplete: required artifact '$name' is empty"
  }
  $artifactText = [IO.File]::ReadAllText($item.FullName)
  if ([string]::IsNullOrWhiteSpace($artifactText)) {
    throw "Frozen review packet is incomplete: required artifact '$name' is empty"
  }
  try { $parsed = $artifactText | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "Frozen review packet is incomplete: $name is not valid JSON" }
  if ($name -eq "selected-voices.json") {
    if ([string]$parsed.schema_version -ne "1") {
      throw "Frozen review packet is incomplete: selected-voices.json schema_version must be 1"
    }
    if ([string]::IsNullOrWhiteSpace([string]$parsed.run_id)) {
      throw "Frozen review packet is incomplete: selected-voices.json run_id is required"
    }
    $sel = @($parsed.selected)
    if ($sel.Count -eq 0) {
      throw "Frozen review packet is incomplete: selected-voices.json selected[] is empty"
    }
    foreach ($row in $sel) {
      if ([string]::IsNullOrWhiteSpace([string]$row.lane_id) -or [string]::IsNullOrWhiteSpace([string]$row.voice)) {
        throw "Frozen review packet is incomplete: selected-voices.json selected[] row missing lane_id/voice"
      }
    }
    $selectedVoicesObj = $parsed
  }
  else {
    if ([string]$parsed.schema_version -ne "1") {
      throw "Frozen review packet is incomplete: review-preflight.json schema_version must be 1"
    }
    if ([string]::IsNullOrWhiteSpace([string]$parsed.run_id)) {
      throw "Frozen review packet is incomplete: review-preflight.json run_id is required"
    }
    $st = [string]$parsed.status
    $line = if ($parsed.PSObject.Properties['status_line']) { [string]$parsed.status_line } else { "" }
    # Canonical status line EXACTLY (Sol D2): a loose prefix match let a hand-typed variant
    # through in fleet-rescomp r3 and cost a full packet rebuild round.
    if ($st -ne "READY" -or -not (Test-FleetPreflightStatusLineCanonical $line)) {
      throw "Frozen review packet is incomplete: review-preflight.json is not READY with the canonical status_line 'review-preflight: READY | selected: N | passed: P | cached: C | failed: 0' (status='$st', status_line='$line')"
    }
    $failedN = 0
    if ($parsed.PSObject.Properties['failed']) { [void][int]::TryParse([string]$parsed.failed, [ref]$failedN) }
    if ($failedN -gt 0) {
      throw "Frozen review packet is incomplete: review-preflight.json claims READY but failed=$failedN"
    }
    # Semantic counters, not just the text line (Terra H2 2026-08-11): a hand-written READY
    # artifact with hollow numbers must not freeze.
    $selN = -1; $pasN = -1; $cacN = -1
    if (-not $parsed.PSObject.Properties['selected'] -or -not [int]::TryParse([string]$parsed.selected, [ref]$selN) -or $selN -lt 1) {
      throw "Frozen review packet is incomplete: review-preflight.json selected must be an integer >= 1"
    }
    if (-not $parsed.PSObject.Properties['passed'] -or -not [int]::TryParse([string]$parsed.passed, [ref]$pasN) -or $pasN -lt 0) {
      throw "Frozen review packet is incomplete: review-preflight.json passed must be a non-negative integer"
    }
    if (-not $parsed.PSObject.Properties['cached'] -or -not [int]::TryParse([string]$parsed.cached, [ref]$cacN) -or $cacN -lt 0) {
      throw "Frozen review packet is incomplete: review-preflight.json cached must be a non-negative integer"
    }
    if (($pasN + $cacN) -lt $selN) {
      throw "Frozen review packet is incomplete: review-preflight.json READY but passed+cached ($pasN+$cacN) < selected ($selN)"
    }
    if ($line -cne ("review-preflight: READY | selected: $selN | passed: $pasN | cached: $cacN | failed: 0")) {
      throw "Frozen review packet is incomplete: review-preflight.json status_line disagrees with its own counters"
    }
    $reviewPreflightObj = $parsed
  }
  $artifacts += Get-ArtifactHashEntry -Name $name -FullPath $item.FullName -ArtifactText $artifactText
}
if (-not [string]::Equals([string]$selectedVoicesObj.run_id, [string]$reviewPreflightObj.run_id, [StringComparison]::Ordinal)) {
  throw ("Frozen review packet is incomplete: run_id mismatch selected-voices='" + [string]$selectedVoicesObj.run_id + "' preflight='" + [string]$reviewPreflightObj.run_id + "'")
}

# Optional context + machine gate artifacts in stable order (D4):
# six required, preflight pair, caller-context.md, test-results.json, fallow-results.json.
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
      Assert-FleetRedEvidence -TestResults $parsed -PacketDir $resolvedPacketDir -ReviewRisk $ReviewRisk
      # RED evidence files are normal hashed packet artifacts (Sol D2/H3 2026-08-11): mutating
      # or deleting one after freeze breaks the manifest like any other artifact.
      if ($parsed.PSObject.Properties['red_controls'] -and $null -ne $parsed.red_controls) {
        foreach ($ctl in @($parsed.red_controls)) {
          $redRel = ([string]$ctl.evidence_path).Replace('\', '/').Trim('/')
          $redFull = Join-Path $resolvedPacketDir ($redRel.Replace('/', '\'))
          $redText = [IO.File]::ReadAllText((Get-Item -LiteralPath $redFull).FullName)
          $artifacts += Get-ArtifactHashEntry -Name ('red:' + $redRel) -FullPath ([IO.Path]::GetFullPath($redFull)) -ArtifactText $redText
        }
      }
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
$packetMaterial = "review_risk|$ReviewRisk`n" + (($artifacts | ForEach-Object { "$($_.name)|$($_.bytes)|$($_.sha256)" }) -join "`n") + "`nfrozen_touched_files`n" + (($frozenTouchedFiles | ForEach-Object { "$($_.path)|$($_.exists)|$($_.sha256)" }) -join "`n")
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
  frozen_touched_files = @($frozenTouchedFiles)
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
