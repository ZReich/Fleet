# Parse [GROK · TEST-AUDIT] lane markdown into machine rows. Advisory — always exit 0.
# Manager quotes: test-audit: N audited, K reject, W warn, P pass, I invalid
param(
  [Parameter(Mandatory)][string]$LaneOutputPath,
  [ValidateSet('text', 'json')][string]$Mode = 'json'
)
$ErrorActionPreference = 'Stop'

# Force UTF-8 stdout. The lane's free-text can hold printable non-ASCII (e.g. a "->" arrow
# U+2192); with a non-UTF-8 console output encoding, PowerShell corrupts it to a raw control
# byte (0x1A) on any `> file` redirect, producing invalid JSON that every downstream parser
# rejects. The in-process string is clean; only the transport was lossy (2026-08-07, live).
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object Text.UTF8Encoding($false)

# Emit ASCII-ONLY JSON. The lane's free-text can hold printable non-ASCII (a "->" arrow
# U+2192); PS 5.1 ConvertTo-Json leaves it as a raw multibyte char, which a PARENT process
# re-decoding the child's stdout (or a non-UTF-8 `> file` redirect) corrupts to a control
# byte, breaking every downstream parser. Escaping every char >0x7F to \uXXXX makes the
# JSON survive ANY transport regardless of console codepage (2026-08-07, live-repro'd).
function ConvertTo-AsciiJson([string]$Json) {
  if ([string]::IsNullOrEmpty($Json)) { return $Json }
  $sb = New-Object Text.StringBuilder ($Json.Length)
  foreach ($ch in $Json.ToCharArray()) {
    $code = [int][char]$ch
    if ($code -gt 127) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
    else { [void]$sb.Append($ch) }
  }
  return $sb.ToString()
}

$allowedResult = @('PASS', 'WARN', 'REJECT')
$allowedAction = @('keep', 'strengthen', 'delete', 'merge')
$allowedCheck = @(
  'would-fail-if-mutated',
  'independent-oracle',
  'tests-subject-not-mock',
  'real-assertion',
  'deletes-duplicate',
  'boundary',
  'none'
)
$allowedStryker = @('killed', 'survived', 'unknown', 'n/a')

if ([string]::IsNullOrWhiteSpace($LaneOutputPath)) {
  throw 'LaneOutputPath is required.'
}
if (-not (Test-Path -LiteralPath $LaneOutputPath -PathType Leaf)) {
  throw "LaneOutputPath not found: $LaneOutputPath"
}
$raw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $LaneOutputPath).Path)

$rows = New-Object System.Collections.ArrayList
$invalid = New-Object System.Collections.ArrayList

# Strip C0/C1 control chars (except TAB) from model free-text before it rides into JSON.
# A Grok verdict field contained a stray 0x1A (SUB), and PS 5.1 ConvertTo-Json emitted it
# RAW, producing invalid JSON that every downstream json.load rejected. Sanitize on capture.
function Remove-ControlChars([string]$Value) {
  if ($null -eq $Value) { return $null }
  return ([regex]::Replace($Value, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', ' ')).Trim()
}

function Get-FieldValue([string]$Body, [string]$Key) {
  $pattern = '(?im)^\s*' + [regex]::Escape($Key) + '\s*:\s*(.*?)\s*$'
  $m = [regex]::Match($Body, $pattern)
  if (-not $m.Success) { return $null }
  return (Remove-ControlChars $m.Groups[1].Value)
}

function Test-Allowed([string]$Value, [string[]]$Set) {
  if ($null -eq $Value) { return $false }
  foreach ($item in $Set) {
    if ($Value -ceq $item) { return $true }
  }
  # case-insensitive fallback for result only handled by caller normalize
  foreach ($item in $Set) {
    if ($Value.Equals($item, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Normalize-Token([string]$Value, [string[]]$Set) {
  if ($null -eq $Value) { return $null }
  $trim = $Value.Trim()
  foreach ($item in $Set) {
    if ($trim.Equals($item, [StringComparison]::OrdinalIgnoreCase)) { return $item }
  }
  return $trim
}

$blockPattern = '(?s)===TEST-AUDIT===\s*(.*?)\s*===END==='
# Never assign $matches — case-insensitive clash with automatic $Matches (ps51-footguns).
$blockHits = [regex]::Matches($raw, $blockPattern)
foreach ($mx in $blockHits) {
  $body = $mx.Groups[1].Value
  $rawBlock = $mx.Value
  $testVal = Get-FieldValue $body 'test'
  $resultRaw = Get-FieldValue $body 'result'
  $worstRaw = Get-FieldValue $body 'worst_check'
  $bugRaw = Get-FieldValue $body 'bug_it_would_catch'
  $actionRaw = Get-FieldValue $body 'action'
  $evidenceRaw = Get-FieldValue $body 'evidence'
  $strykerRaw = Get-FieldValue $body 'stryker'

  $reasons = New-Object System.Collections.ArrayList
  if ($null -eq $resultRaw) { [void]$reasons.Add('missing result:') }

  $resultVal = if ($null -ne $resultRaw) { Normalize-Token $resultRaw $allowedResult } else { $null }
  $worstVal = if ($null -ne $worstRaw) { Normalize-Token $worstRaw $allowedCheck } else { $null }
  $actionVal = if ($null -ne $actionRaw) { Normalize-Token $actionRaw $allowedAction } else { $null }
  $bugVal = if ($null -ne $bugRaw) { $bugRaw.Trim() } else { $null }
  $evidenceVal = if ($null -ne $evidenceRaw) { $evidenceRaw.Trim() } else { $null }
  $strykerVal = if ($null -ne $strykerRaw -and $strykerRaw.Trim() -ne '') {
    Normalize-Token $strykerRaw $allowedStryker
  } else {
    'n/a'
  }

  if ($null -eq $testVal -or $testVal -eq '') { [void]$reasons.Add('missing or empty test:') }
  if ($null -ne $resultRaw -and -not (Test-Allowed $resultVal $allowedResult)) {
    [void]$reasons.Add("result not in allowed set: $resultRaw")
  }
  if ($null -eq $worstVal -or -not (Test-Allowed $worstVal $allowedCheck)) {
    [void]$reasons.Add("worst_check missing or not in allowed set: $worstRaw")
  }
  if ($null -eq $actionVal -or -not (Test-Allowed $actionVal $allowedAction)) {
    [void]$reasons.Add("action missing or not in allowed set: $actionRaw")
  }
  if ($null -eq $bugVal -or $bugVal -eq '') {
    [void]$reasons.Add('missing or empty bug_it_would_catch:')
  }
  if ($null -eq $evidenceVal -or $evidenceVal -eq '') {
    [void]$reasons.Add('missing or empty evidence:')
  }
  if (-not (Test-Allowed $strykerVal $allowedStryker)) {
    [void]$reasons.Add("stryker not in allowed set: $strykerRaw")
  }

  # Vacuous REJECT/WARN: must carry real worst_check and (real bug OR delete/merge action).
  if ($resultVal -eq 'REJECT' -or $resultVal -eq 'WARN') {
    $hasRealCheck = ($null -ne $worstVal -and $worstVal -ne 'none')
    $hasRealBug = ($null -ne $bugVal -and $bugVal -ne '' -and $bugVal -ne 'none')
    $isPrune = ($actionVal -eq 'delete' -or $actionVal -eq 'merge')
    if (-not $hasRealCheck) {
      [void]$reasons.Add('REJECT/WARN requires non-none worst_check')
    }
    if (-not $hasRealBug -and -not $isPrune) {
      [void]$reasons.Add('REJECT/WARN requires non-none bug_it_would_catch or action=delete/merge')
    }
  }

  if ($reasons.Count -gt 0) {
    [void]$invalid.Add([ordered]@{
        reason = ($reasons -join '; ')
        raw    = $rawBlock
      })
    continue
  }

  [void]$rows.Add([ordered]@{
      test               = $testVal
      result             = $resultVal
      worst_check        = $worstVal
      bug_it_would_catch = $bugVal
      action             = $actionVal
      evidence           = $evidenceVal
      stryker            = $strykerVal
    })
}

$passCount = 0
$warnCount = 0
$rejectCount = 0
foreach ($row in $rows) {
  switch ($row.result) {
    'PASS' { $passCount++ }
    'WARN' { $warnCount++ }
    'REJECT' { $rejectCount++ }
  }
}
$audited = $rows.Count
$invalidCount = $invalid.Count
$summary = "test-audit: $audited audited, $rejectCount reject, $warnCount warn, $passCount pass, $invalidCount invalid"

if ($Mode -eq 'json') {
  $payload = [ordered]@{
    audited = $audited
    reject  = $rejectCount
    warn    = $warnCount
    pass    = $passCount
    invalid_count = $invalidCount
    summary = $summary
    rows    = @($rows)
    invalid = @($invalid)
  }
  Write-Output (ConvertTo-AsciiJson ($payload | ConvertTo-Json -Compress -Depth 8))
}
else {
  foreach ($row in $rows) {
    Write-Output ("{0} {1} action={2} worst={3} stryker={4} evidence={5}" -f $row.result, $row.test, $row.action, $row.worst_check, $row.stryker, $row.evidence)
  }
  foreach ($inv in $invalid) {
    Write-Output ("INVALID {0}" -f $inv.reason)
  }
  Write-Output $summary
}

# ADVISORY: never gate the build on verdicts.
exit 0
