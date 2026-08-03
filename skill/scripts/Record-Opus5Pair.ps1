# Append one Opus-5 pair (or solo) row to BENCH-opus5-pairs.jsonl.
# Solo rows: wall/precision/verified-FP. Paired fields only when a 4.8 pair ran.
param(
  [Parameter(Mandatory)][string]$PairId,
  [Parameter(Mandatory)][string]$Date,
  [Parameter(Mandatory)][ValidateSet('true','false','1','0','True','False')][string]$Dispatched,
  [string]$WhyNot,
  [string]$VerdictSummary = '',
  [int]$FindingsCount = 0,
  [int]$VerifiedUniqueAdoptedCatches = 0,
  [int]$FalsePositiveCount = 0,
  $WallSeconds = $null,
  $Precision = $null,
  $Opus48WallSeconds = $null,
  $Opus48FindingsCount = $null,
  [string]$TransportNoContestReason,
  [string]$LedgerPath
)

# PS 5.1 does not populate $PSScriptRoot in param defaults - resolve in the body.
if (-not $LedgerPath) { $LedgerPath = Join-Path $PSScriptRoot '..\BENCH-opus5-pairs.jsonl' }
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
function Fail([string]$m) { throw $m }
foreach ($n in @('FindingsCount','VerifiedUniqueAdoptedCatches','FalsePositiveCount')) {
  if ((Get-Variable $n).Value -lt 0) { Fail "$n must be non-negative" }
}
$isDispatched = $Dispatched -in @('true','1','True')
if (-not $isDispatched) {
  if ([string]::IsNullOrWhiteSpace($WhyNot)) { Fail 'WhyNot required when Dispatched is false' }
} else {
  if (-not [string]::IsNullOrWhiteSpace($WhyNot)) { Fail 'WhyNot must be empty when Dispatched is true' }
  if ($null -eq $WallSeconds -or "$WallSeconds" -eq '') { Fail 'WallSeconds required when Dispatched is true' }
}
if ($null -ne $WallSeconds -and "$WallSeconds" -ne '' -and [int]$WallSeconds -lt 0) { Fail 'WallSeconds must be non-negative' }
$row = [ordered]@{
  schema_version = '1'
  pair_id = $PairId
  date = $Date
  dispatched = $isDispatched
  why_not = $(if ([string]::IsNullOrWhiteSpace($WhyNot)) { $null } else { $WhyNot })
  verdict_summary = $VerdictSummary
  findings_count = [int]$FindingsCount
  verified_unique_adopted_catches = [int]$VerifiedUniqueAdoptedCatches
  false_positive_count = [int]$FalsePositiveCount
  wall_seconds = $(if ($null -eq $WallSeconds -or "$WallSeconds" -eq '') { $null } else { [int]$WallSeconds })
  precision = $Precision
  transport_no_contest_reason = $(if ([string]::IsNullOrWhiteSpace($TransportNoContestReason)) { $null } else { $TransportNoContestReason })
}
if ($null -ne $Opus48WallSeconds -and "$Opus48WallSeconds" -ne '') {
  $row.opus48_wall_seconds = [int]$Opus48WallSeconds
  $row.opus48_findings_count = $(if ($null -eq $Opus48FindingsCount -or "$Opus48FindingsCount" -eq '') { $null } else { [int]$Opus48FindingsCount })
}
$fullPath = [IO.Path]::GetFullPath($LedgerPath)
$dir = Split-Path -Parent $fullPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$payload = ([pscustomobject]$row | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine
$tmp = [IO.Path]::GetTempFileName()
$hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath.ToLowerInvariant()))
$ledgerHash = -join ($hashBytes[0..7] | ForEach-Object { $_.ToString('x2') })
$mutex = [Threading.Mutex]::new($false, "Global\CodexFleetOpus5Pair-$ledgerHash")
try {
  if (-not $mutex.WaitOne(30000)) { Fail 'Timed out waiting for Opus-5 pairs ledger lock' }
  [IO.File]::WriteAllText($tmp, $payload, $utf8)
  $rowsTotal = 0
  if (Test-Path -LiteralPath $fullPath) {
    foreach ($line in [IO.File]::ReadAllLines($fullPath, $utf8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $ex = $line | ConvertFrom-Json
      if ([string]$ex.pair_id -eq $PairId) { Fail "Duplicate PairId: $PairId" }
      $rowsTotal++
    }
  }
  [IO.File]::AppendAllText($fullPath, [IO.File]::ReadAllText($tmp, $utf8), $utf8)
} finally {
  try { $mutex.ReleaseMutex() } catch { }
  $mutex.Dispose()
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
$rowsTotal++
[pscustomobject]@{ rows_total = $rowsTotal; valid_rows = $rowsTotal } | ConvertTo-Json -Compress
