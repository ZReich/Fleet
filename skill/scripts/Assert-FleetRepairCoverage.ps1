[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VerdictPath,
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RepairDiffPath,
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)
# PS5.1: $PSScriptRoot is EMPTY in param() default when any [Parameter()] exists — resolve in body.
. (Join-Path $PSScriptRoot 'RepairCoverage.Helpers.ps1')

function Exit-WithResult {
  param($Result, [int]$Code, [string]$Path)
  try {
    Write-CoverageOutput -Result $Result -Path $Path
  }
  catch {
    $writeFail = New-CoverageResult -Status "invalid" -Verdict $Result.verdict_path -Diff $Result.repair_diff_path -ErrorMessage ("output write failed: " + $_.Exception.Message)
    Write-Output (($writeFail | ConvertTo-Json -Depth 8 -Compress))
    exit 2
  }
  exit $Code
}

$resolvedVerdict = $null
$resolvedDiff = $null
try {
  if (-not (Test-Path -LiteralPath $VerdictPath -PathType Leaf)) { throw "verdict file not found: $VerdictPath" }
  if (-not (Test-Path -LiteralPath $RepairDiffPath -PathType Leaf)) { throw "repair diff file not found: $RepairDiffPath" }
  $resolvedVerdict = (Resolve-Path -LiteralPath $VerdictPath).Path
  $resolvedDiff = (Resolve-Path -LiteralPath $RepairDiffPath).Path
  $verdictText = [IO.File]::ReadAllText($resolvedVerdict)
  $diffText = [IO.File]::ReadAllText($resolvedDiff)
  if ([string]::IsNullOrWhiteSpace($verdictText)) { throw "verdict file is empty" }
  if ([string]::IsNullOrWhiteSpace($diffText)) { throw "repair diff file is empty" }

  $trailerMatch = [regex]::Match($verdictText, '(?s)<!--\s*FLEET_REQUIRED_BLOCKERS_V1\s*\r?\n(.*?)\r?\nFLEET_REQUIRED_BLOCKERS_V1\s*-->\s*\z')
  if (-not $trailerMatch.Success) { throw "missing or malformed FLEET_REQUIRED_BLOCKERS_V1 trailer" }
  $trailerJson = $trailerMatch.Groups[1].Value.Trim()
  try {
    $trailer = $trailerJson | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw "trailer JSON is invalid: $($_.Exception.Message)"
  }

  if ([string]$trailer.schema_version -ne "1") { throw "trailer schema_version must be 1" }
  if ($null -eq $trailer.required_blockers) { throw "trailer required_blockers is missing" }
  if (-not (Test-IsJsonArray $trailer.required_blockers)) {
    throw "required_blockers must be an array"
  }
  $blockersIn = @($trailer.required_blockers)
  if ($blockersIn.Count -lt 1) { throw "re-arbitration requires at least one required blocker" }

  $seenIds = @{}
  $parsedBlockers = @()
  foreach ($blocker in $blockersIn) {
    $id = [string]$blocker.id
    if ([string]::IsNullOrWhiteSpace($id)) { throw "blocker id is blank" }
    if ($seenIds.ContainsKey($id)) { throw "duplicate blocker id: $id" }
    $seenIds[$id] = $true
    $summary = [string]$blocker.summary
    if ([string]::IsNullOrWhiteSpace($summary)) { throw "blocker $id has blank summary" }
    if ($null -eq $blocker.evidence -or -not (Test-IsJsonArray $blocker.evidence)) {
      throw "required_blockers must be an array: blocker $id evidence must be an array"
    }
    $evidenceIn = @($blocker.evidence)
    if ($evidenceIn.Count -lt 1) { throw "blocker $id has empty evidence" }
    $evidenceParsed = @()
    foreach ($ev in $evidenceIn) {
      $path = Assert-EvidenceRepoPath ([string]$ev.path)
      $change = [string]$ev.change
      if ($change -notin @("added", "removed", "touched")) { throw "blocker $id evidence change must be added|removed|touched" }
      $pattern = $null
      $compiled = $null
      if ($change -in @("added", "removed")) {
        if ($null -eq $ev.pattern -or [string]::IsNullOrWhiteSpace([string]$ev.pattern)) {
          throw "blocker $id evidence pattern is required for change=$change"
        }
        $pattern = [string]$ev.pattern
        try {
          $compiled = New-BoundedRegex -Pattern $pattern
        }
        catch {
          throw "blocker $id evidence pattern is not a valid .NET regex: $pattern"
        }
      }
      else {
        if ($null -ne $ev.PSObject.Properties["pattern"]) {
          throw "pattern must be omitted for change=touched"
        }
      }
      $evidenceParsed += [ordered]@{
        path = $path
        change = $change
        pattern = $pattern
        compiled = $compiled
      }
    }
    $parsedBlockers += [ordered]@{
      id = $id
      summary = $summary
      evidence = $evidenceParsed
    }
  }

  $fileMap = Get-DiffFileMap -DiffText $diffText
  $blockerResults = @()
  $coveredCount = 0
  $uncoveredCount = 0
  foreach ($blocker in $parsedBlockers) {
    $evidenceResults = @()
    $allMatched = $true
    foreach ($ev in @($blocker.evidence)) {
      $matched = $false
      $reason = $null
      $fileEntry = $null
      if ($fileMap.ContainsKey($ev.path)) { $fileEntry = $fileMap[$ev.path] }
      if ($null -eq $fileEntry) {
        $matched = $false
        $reason = "path not present in repair diff"
      }
      elseif ($ev.change -eq "touched") {
        $matched = [bool]$fileEntry.touched
        if (-not $matched) { $reason = "path has no diff hunk" }
      }
      elseif ($ev.change -eq "added") {
        $regex = $ev.compiled
        if ($null -eq $regex) { $regex = New-BoundedRegex -Pattern $ev.pattern }
        $matched = $false
        try {
          foreach ($line in @($fileEntry.added)) {
            if ($regex.IsMatch($line)) { $matched = $true; break }
          }
        }
        catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
          throw "blocker $($blocker.id) evidence pattern match timed out (RegexMatchTimeoutException)"
        }
        if (-not $matched) { $reason = "pattern did not match any added line" }
      }
      elseif ($ev.change -eq "removed") {
        if ($fileEntry.is_new) {
          # File absent at base: removed-clause is structurally unprovable -> N/A (not FAIL).
          $matched = $true
          $reason = "not_applicable: file absent at base (new file in diff)"
        }
        else {
          $regex = $ev.compiled
          if ($null -eq $regex) { $regex = New-BoundedRegex -Pattern $ev.pattern }
          $matched = $false
          try {
            foreach ($line in @($fileEntry.removed)) {
              if ($regex.IsMatch($line)) { $matched = $true; break }
            }
          }
          catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
            throw "blocker $($blocker.id) evidence pattern match timed out (RegexMatchTimeoutException)"
          }
          if (-not $matched) { $reason = "pattern did not match any removed line" }
        }
      }
      if (-not $matched) { $allMatched = $false }
      $evidenceResults += [ordered]@{
        path = $ev.path
        change = $ev.change
        pattern = $ev.pattern
        matched = [bool]$matched
        reason = $reason
      }
    }
    $blockerStatus = if ($allMatched) { "covered" } else { "uncovered" }
    if ($allMatched) { $coveredCount++ } else { $uncoveredCount++ }
    $blockerResults += [ordered]@{
      id = $blocker.id
      status = $blockerStatus
      evidence = $evidenceResults
    }
  }

  $status = if ($uncoveredCount -eq 0) { "covered" } else { "uncovered" }
  $result = New-CoverageResult -Status $status -Verdict $resolvedVerdict -Diff $resolvedDiff -RequiredCount $parsedBlockers.Count -CoveredCount $coveredCount -UncoveredCount $uncoveredCount -Blockers $blockerResults -ErrorMessage $null
  $code = if ($status -eq "covered") { 0 } else { 1 }
  Exit-WithResult -Result $result -Code $code -Path $OutputPath
}
catch {
  $verdictLabel = if ($resolvedVerdict) { $resolvedVerdict } else { $VerdictPath }
  $diffLabel = if ($resolvedDiff) { $resolvedDiff } else { $RepairDiffPath }
  $result = New-CoverageResult -Status "invalid" -Verdict $verdictLabel -Diff $diffLabel -ErrorMessage $_.Exception.Message
  try {
    Write-CoverageOutput -Result $result -Path $OutputPath
  }
  catch {
    Write-Output ((New-CoverageResult -Status "invalid" -Verdict $verdictLabel -Diff $diffLabel -ErrorMessage ("output write failed: " + $_.Exception.Message) | ConvertTo-Json -Depth 8 -Compress))
  }
  exit 2
}
