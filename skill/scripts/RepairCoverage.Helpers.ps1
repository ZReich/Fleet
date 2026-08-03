# Dot-sourced helpers for Assert-FleetRepairCoverage.ps1.
# Caller sets $utf8 (UTF8Encoding no BOM) before Write-CoverageOutput runs.

function New-CoverageResult {
  param(
    [string]$Status,
    [string]$Verdict,
    [string]$Diff,
    [int]$RequiredCount = 0,
    [int]$CoveredCount = 0,
    [int]$UncoveredCount = 0,
    [object[]]$Blockers = @(),
    $ErrorMessage = $null
  )
  return [ordered]@{
    schema_version = "1"
    status = $Status
    verdict_path = $Verdict
    repair_diff_path = $Diff
    required_blocker_count = $RequiredCount
    covered_count = $CoveredCount
    uncovered_count = $UncoveredCount
    blockers = @($Blockers)
    error = $ErrorMessage
  }
}

function Write-CoverageOutput {
  param($Result, [string]$Path)
  $json = ($Result | ConvertTo-Json -Depth 8 -Compress)
  if ($Path) {
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dir = Split-Path -Parent $resolved
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $temporary = "$resolved.$PID.tmp"
    try {
      [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, $utf8)
      Move-Item -LiteralPath $temporary -Destination $resolved -Force
    }
    catch {
      if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
      }
      throw
    }
    finally {
      if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
      }
    }
  }
  Write-Output $json
}

function Normalize-RepoPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  $normalized = ($Path -replace '\\', '/').Trim()
  $normalized = $normalized -replace '^\./', ''
  if ($normalized.StartsWith('/')) { return $null }
  if ($normalized -match '(^|/)\.\.(/|$)') { return $null }
  if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
  return $normalized
}

# D3 evidence paths must already be slash-separated repo-relative (no silent rewrite).
function Assert-EvidenceRepoPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "path must be normalized: blank path"
  }
  if ($Path -match '[\\:]' -or $Path.StartsWith('/') -or $Path -match '(^|/)\.\.(/|$)' -or $Path -match '^\./') {
    throw "path must be normalized (slash-separated repo-relative, no backslash or rooted path): $Path"
  }
  $trimmed = $Path.Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed)) {
    throw "path must be normalized: blank path"
  }
  return $trimmed
}

function Test-IsJsonArray($Value) {
  if ($null -eq $Value) { return $false }
  if ($Value -is [Array]) { return $true }
  if ($Value -is [System.Collections.ArrayList]) { return $true }
  return $false
}

function New-BoundedRegex([string]$pattern) {
  return [regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(2))
}

function New-DiffFileEntry([string]$Path) {
  return [ordered]@{
    path = $Path
    touched = $true
    is_new = $false
    added = New-Object Collections.Generic.List[string]
    removed = New-Object Collections.Generic.List[string]
  }
}

function Get-DiffFileMap([string]$DiffText) {
  $map = @{}
  $current = $null
  foreach ($line in ($DiffText -split "`r?`n")) {
    if ($line -match '^diff --git a/(.+) b/(.+)$') {
      $path = Normalize-RepoPath $Matches[2]
      if (-not $path) { $path = Normalize-RepoPath $Matches[1] }
      $current = $path
      if ($current -and -not $map.ContainsKey($current)) {
        $map[$current] = New-DiffFileEntry $current
      }
      continue
    }
    if ($line -match '^new file mode ') {
      if ($null -ne $current -and $map.ContainsKey($current)) {
        $map[$current].is_new = $true
      }
      continue
    }
    if ($line -eq '--- /dev/null' -or $line.StartsWith('--- /dev/null')) {
      if ($null -ne $current -and $map.ContainsKey($current)) {
        $map[$current].is_new = $true
      }
      continue
    }
    if ($line -match '^\+\+\+ b/(.+)$') {
      $path = Normalize-RepoPath $Matches[1]
      if ($path) {
        $current = $path
        if (-not $map.ContainsKey($current)) {
          $map[$current] = New-DiffFileEntry $current
        }
      }
      continue
    }
    if ($line -match '^--- a/(.+)$') {
      $path = Normalize-RepoPath $Matches[1]
      if ($path -and -not $map.ContainsKey($path)) {
        $map[$path] = New-DiffFileEntry $path
      }
      continue
    }
    # Exclude +++ / --- header lines from content matching (D3).
    if ($line.StartsWith('+++') -or $line.StartsWith('---')) { continue }
    if ($null -eq $current -or -not $map.ContainsKey($current)) { continue }
    if ($line.StartsWith('+') -and -not $line.StartsWith('+++')) {
      [void]$map[$current].added.Add($line.Substring(1))
      $map[$current].touched = $true
    }
    elseif ($line.StartsWith('-') -and -not $line.StartsWith('---')) {
      [void]$map[$current].removed.Add($line.Substring(1))
      $map[$current].touched = $true
    }
    elseif ($line.StartsWith('@@')) {
      $map[$current].touched = $true
    }
  }
  return $map
}
