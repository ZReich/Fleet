# Barrier verification for a Grok lane -- the "rely on the receipt, but cheaply verify" mode.
# Adds only SECONDS: it does NOT re-run the expensive full suite/build (that is trusted from the
# lane's own receipt/report). It DOES:
#   1. verify the lane receipt's HMAC signature when one is supplied (tamper-evidence + identity);
#   2. re-run the CHEAP DETERMINISTIC gate in full (default Assert-FleetPowerShellValid -- parse +
#      self-test, seconds) and compare to the lane's claimed outcome;
#   3. flag DIVERGENCE when the lane reported success but the cheap gate fails on re-run, and append
#      a row to a divergence ledger so the lane's claim-vs-reality trust rate is tracked over time.
# Rationale proven by Test-FleetGateReceiptTrust.ps1: a valid signature does NOT prove gate truth,
# so a cheap re-run is kept; but the expensive re-run (the real time cost) is skipped. If the cheap
# gate ever diverges from the lane's claim, that lane/run is untrustworthy -> fail closed.
# Prints: lanegate: signature <ok|absent|INVALID>, cheap-gate <PASS|FAIL>, claim <green|nongreen>, <MATCH|DIVERGENCE>
# Exit 1 on DIVERGENCE or INVALID signature (unless -ReportOnly). PS5.1-safe, ASCII only.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$GrokResult,
  [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$BaseRef,
  [string]$RepoPath = (Get-Location).Path,
  # Cheap deterministic gate to re-run. Empty default -> resolved in the body to this repo's
  # PowerShell-validity gate (never use $PSScriptRoot in a param default: it is EMPTY in PS5.1 when
  # any [Parameter()] attribute is present -- ps51-footguns). Any repo can pass its own (e.g. a
  # changed-file tsc/lint wrapper); it is invoked as `<script> -BaseRef <ref> -RepoPath <repo>`.
  [string]$CheapGate = '',
  # Optional signed receipt (JSON) + RunId to load the lease HMAC key for signature verification.
  [string]$ReceiptPath = '',
  [string]$RunId = '',
  # Append-only JSONL ledger of claim-vs-reality outcomes (the trust metric). Optional.
  [string]$DivergenceLedger = '',
  [switch]$ReportOnly,
  [Parameter(ParameterSetName = 'SelfTest')][switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false

# Did the lane claim success? (task_status done, or status ok with no failure).
function Test-LaneClaimedGreen($result) {
  if ($null -eq $result) { return $false }
  $ts = [string]$result.task_status
  $st = [string]$result.status
  if ($ts -eq 'done') { return $true }
  if ($st -eq 'ok' -and ($ts -eq '' -or $ts -eq 'done')) { return $true }
  return $false
}

# Verify a receipt file's signature against the run lease key. Returns 'ok' | 'INVALID' | 'absent'.
function Get-ReceiptSignatureStatus([string]$receiptPath, [string]$runId, [string]$scriptsRoot) {
  if ([string]::IsNullOrWhiteSpace($receiptPath)) { return 'absent' }
  if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return 'INVALID' }
  try {
    . (Join-Path $scriptsRoot 'RunLease.Helpers.ps1')
    . (Join-Path $scriptsRoot 'FleetReceiptSignature.Helpers.ps1')
    $doc = [IO.File]::ReadAllText($receiptPath, (New-Object System.Text.UTF8Encoding $false)) | ConvertFrom-Json
    $key = Get-FleetRunLeaseKey -RunId $runId   # @{ KeyId; KeyBytes } from the ACL-locked lease
    $rtype = [string]$doc.receipt_type
    $res = Test-FleetReceiptSignature -Receipt $doc -ReceiptType $rtype -RunSecret $key.KeyBytes -KeyId $key.KeyId -Signature ([string]$doc.signature)
    if ($res.ok) { return 'ok' } else { return 'INVALID' }
  }
  catch { return 'INVALID' }
}

# Run the cheap deterministic gate; return $true if it passed (exit 0).
function Invoke-CheapGate([string]$gate, [string]$baseRef, [string]$repo) {
  if (-not (Test-Path -LiteralPath $gate -PathType Leaf)) { throw "CheapGate not found: $gate" }
  $out = [IO.Path]::GetTempFileName()
  try {
    $p = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow -Wait `
      -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $gate + '" -BaseRef ' + $baseRef + ' -RepoPath "' + $repo + '"') `
      -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
    return ($p.ExitCode -eq 0)
  }
  finally { Remove-Item -LiteralPath $out, ($out + '.err') -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) {
  $fail = 0
  function Check([string]$n, [bool]$ok) { if ($ok) { Write-Output "PASS $n" } else { Write-Output "FAIL $n"; $script:fail++ } }
  # claim detection
  Check 'task_status done => claimed green' (Test-LaneClaimedGreen ([pscustomobject]@{ task_status = 'done' }))
  Check 'status ok => claimed green' (Test-LaneClaimedGreen ([pscustomobject]@{ status = 'ok'; task_status = '' }))
  Check 'partial => NOT claimed green' (-not (Test-LaneClaimedGreen ([pscustomobject]@{ task_status = 'partial' })))
  # divergence logic (pure): claimed green + cheap gate fail => divergence
  function Test-Divergence([bool]$claimed, [bool]$cheapPassed) { return ($claimed -and -not $cheapPassed) }
  Check 'green claim + cheap FAIL => DIVERGENCE' (Test-Divergence $true $false)
  Check 'green claim + cheap PASS => match' (-not (Test-Divergence $true $true))
  Check 'nongreen claim + cheap FAIL => no divergence (lane admitted failure)' (-not (Test-Divergence $false $false))
  # signature: absent when no path
  Check 'no receipt path => signature absent' ((Get-ReceiptSignatureStatus '' '' $PSScriptRoot) -eq 'absent')
  Check 'missing receipt file => INVALID' ((Get-ReceiptSignatureStatus (Join-Path $env:TEMP ('nope-' + [guid]::NewGuid().ToString('n') + '.json')) 'x' $PSScriptRoot) -eq 'INVALID')
  if ($fail -eq 0) { Write-Output 'Test-AssertFleetLaneReceipt: passed (8 checks)'; exit 0 }
  Write-Output "Test-AssertFleetLaneReceipt: FAILED ($fail)"; exit 1
}

# --- main ---
if ([string]::IsNullOrWhiteSpace($CheapGate)) { $CheapGate = Join-Path $PSScriptRoot 'Assert-FleetPowerShellValid.ps1' }
if (-not (Test-Path -LiteralPath $GrokResult -PathType Leaf)) { throw "GrokResult not found: $GrokResult" }
$result = [IO.File]::ReadAllText($GrokResult, $utf8) | ConvertFrom-Json
$claimedGreen = Test-LaneClaimedGreen $result

$sigStatus = Get-ReceiptSignatureStatus $ReceiptPath $RunId $PSScriptRoot
$cheapPassed = Invoke-CheapGate $CheapGate $BaseRef $RepoPath
$divergence = ($claimedGreen -and -not $cheapPassed)

$claimWord = if ($claimedGreen) { 'green' } else { 'nongreen' }
$cheapWord = if ($cheapPassed) { 'PASS' } else { 'FAIL' }
$matchWord = if ($divergence) { 'DIVERGENCE' } else { 'MATCH' }
Write-Output ("lanegate: signature {0}, cheap-gate {1}, claim {2}, {3}" -f $sigStatus, $cheapWord, $claimWord, $matchWord)

if (-not [string]::IsNullOrWhiteSpace($DivergenceLedger)) {
  try {
    $row = [ordered]@{ base = $BaseRef; claim = $claimWord; cheap_gate = $cheapWord; signature = $sigStatus; divergence = [bool]$divergence; run_id = $RunId }
    $dir = Split-Path -Parent $DivergenceLedger
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::AppendAllText($DivergenceLedger, (($row | ConvertTo-Json -Compress) + "`n"), $utf8)
  }
  catch { }
}

if ((($divergence) -or ($sigStatus -eq 'INVALID')) -and -not $ReportOnly) { exit 1 }
exit 0
