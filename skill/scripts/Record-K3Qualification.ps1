param(
  [Parameter(Mandatory)][string]$RunId,
  [Parameter(Mandatory)][string]$Date,
  [Parameter(Mandatory)][string]$ReviewTier,
  [Parameter(Mandatory)][ValidateSet('true','false','1','0','True','False')][string]$Dispatched,
  [string]$WhyNot,
  [string]$VerdictSummary = '',
  [int]$UniqueFindingsCount = 0,
  [int]$VerifiedUniqueAdoptedCatches = 0,
  [int]$FabricationFlags = 0,
  [int]$FalsePositiveCount = 0,
  $WallSeconds = $null,
  [string]$TransportNoContestReason,
  $KConsidered = $null,
  [string]$LedgerPath
)
$ErrorActionPreference = 'Stop'
# PS 5.1 leaves $PSScriptRoot EMPTY in param defaults, so this threw on every call that
# omitted -LedgerPath - meaning the K3 promotion track could not record its own evidence.
if (-not $LedgerPath) { $LedgerPath = Join-Path $PSScriptRoot '..\BENCH-k3-qualification.jsonl' }
$utf8 = [Text.UTF8Encoding]::new($false)
function Fail([string]$m) { throw $m }
if ($ReviewTier -ne 'FULL') { Fail 'ReviewTier must be FULL' }
foreach ($n in @('UniqueFindingsCount','VerifiedUniqueAdoptedCatches','FabricationFlags','FalsePositiveCount')) { if ((Get-Variable $n).Value -lt 0) { Fail "$n must be non-negative" } }
$isDispatched = $Dispatched -in @('true','1','True')
if (-not $isDispatched) { if ([string]::IsNullOrWhiteSpace($WhyNot)) { Fail 'WhyNot required when Dispatched is false' } }
else { if (-not [string]::IsNullOrWhiteSpace($WhyNot)) { Fail 'WhyNot must be empty when Dispatched is true' }; if ($null -eq $WallSeconds -or "$WallSeconds" -eq '') { Fail 'WallSeconds required when Dispatched is true' } }
if ($null -ne $WallSeconds -and "$WallSeconds" -ne '' -and [int]$WallSeconds -lt 0) { Fail 'WallSeconds must be non-negative' }
$row = [ordered]@{ run_id=$RunId; date=$Date; review_tier=$ReviewTier; dispatched=$isDispatched; why_not=$(if ([string]::IsNullOrWhiteSpace($WhyNot)) { $null } else { $WhyNot }); verdict_summary=$VerdictSummary; unique_findings_count=[int]$UniqueFindingsCount; verified_unique_adopted_catches=[int]$VerifiedUniqueAdoptedCatches; fabrication_flags=[int]$FabricationFlags; false_positive_count=[int]$FalsePositiveCount; wall_seconds=$(if ($null -eq $WallSeconds -or "$WallSeconds" -eq '') { $null } else { [int]$WallSeconds }); transport_no_contest_reason=$(if ([string]::IsNullOrWhiteSpace($TransportNoContestReason)) { $null } else { $TransportNoContestReason }); k3_considered=$KConsidered }
$fullPath = [IO.Path]::GetFullPath($LedgerPath)
$dir = Split-Path -Parent $fullPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$payload = ([pscustomobject]$row | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine
$tmp = [IO.Path]::GetTempFileName()
$hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath.ToLowerInvariant()))
$ledgerHash = -join ($hashBytes[0..7] | ForEach-Object { $_.ToString('x2') })
$mutex = [Threading.Mutex]::new($false, "Global\CodexFleetK3Qualification-$ledgerHash")
try {
  if (-not $mutex.WaitOne(30000)) { Fail 'Timed out waiting for K3 qualification ledger lock' }
  [IO.File]::WriteAllText($tmp, $payload, $utf8)
  $rowsTotal = 0; $dispatchedFull = 0
  if (Test-Path -LiteralPath $fullPath) {
    foreach ($line in [IO.File]::ReadAllLines($fullPath, $utf8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $ex = $line | ConvertFrom-Json
      if ([string]$ex.run_id -eq $RunId) { Fail "Duplicate RunId: $RunId" }
      $rowsTotal++
      if ($ex.dispatched -eq $true -and [string]$ex.review_tier -eq 'FULL') { $dispatchedFull++ }
    }
  }
  [IO.File]::AppendAllText($fullPath, [IO.File]::ReadAllText($tmp, $utf8), $utf8)
} finally {
  try { $mutex.ReleaseMutex() } catch { }
  $mutex.Dispose()
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
$rowsTotal++; if ($isDispatched) { $dispatchedFull++ }
[pscustomobject]@{ rows_total=$rowsTotal; dispatched_full_rows=$dispatchedFull; promotion_assessment_due=($dispatchedFull -eq 10) } | ConvertTo-Json -Compress