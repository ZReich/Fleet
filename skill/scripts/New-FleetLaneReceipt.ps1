# Trusted signing step: turn a completed Grok lane result into a SIGNED lane_gate receipt.
# Runs orchestrator-side (has the ACL-locked lease key; the Grok lane in its sandbox does NOT), so
# it binds grok's self-reported gate outcome to the run + the diff (input_packet_sha256) + the
# result file (result_sha256), identity-bound and tamper-evident. This does NOT make grok's claim
# TRUE (see Test-FleetGateReceiptTrust) -- Assert-FleetLaneReceipt still re-runs the cheap gate to
# catch a lie. It makes the divergence-ledger trust history non-repudiable + audit-grade.
# Emits the receipt path on stdout. PS5.1-safe, ASCII only.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$RunId,
  [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$GrokResult,
  [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$BaseRef,
  [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$OutputPath,
  [string]$RepoPath = (Get-Location).Path,
  [string]$TaskId = 'grok-task',
  [string]$LaneId = 'grok-lane',
  [string]$EmitterId = 'fleet-orchestrator',
  [string]$LockedPlanSha256 = ('0' * 64),
  [string]$CheapGate = 'psvalid',
  [Parameter(ParameterSetName = 'SelfTest')][switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false

function Get-Sha256Text([string]$s) {
  $h = [Security.Cryptography.SHA256]::Create()
  try { return -join ($h.ComputeHash($utf8.GetBytes([string]$s)) | ForEach-Object { $_.ToString('x2') }) } finally { $h.Dispose() }
}
function Get-Sha256File([string]$p) {
  $h = [Security.Cryptography.SHA256]::Create()
  try { $fs = [IO.File]::OpenRead($p); try { return -join ($h.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) } finally { $fs.Dispose() } } finally { $h.Dispose() }
}
function Get-NowTs { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + 'Z' }

# Build + sign a lane_gate receipt (key supplied so this is unit-testable without a live lease).
function New-LaneGateReceipt([hashtable]$f, [byte[]]$secret, [string]$keyId, [string]$scriptsRoot) {
  . (Join-Path $scriptsRoot 'FleetReceiptSignature.Helpers.ps1')
  $r = [ordered]@{
    schema_version = '2'; receipt_type = 'lane_gate'; run_id = $f.runId; task_id = $f.taskId; lane_id = $f.laneId
    requested_model = $f.model; observed_model = $f.observedModel; model_evidence = $f.modelEvidence; emitter_id = $f.emitterId
    input_packet_sha256 = $f.inputSha; result_sha256 = $f.resultSha; locked_plan_sha256 = $f.lockedPlan
    cheap_gate = $f.cheapGate; cheap_gate_claim = $f.cheapClaim; exit_code = [int]$f.exitCode; outcome = $f.outcome
    started_at = $f.startedAt; completed_at = $f.completedAt; sig_alg = 'HMAC-SHA256'; key_id = $keyId
  }
  $sig = New-FleetReceiptSignature -Receipt ([pscustomobject]$r) -ReceiptType 'lane_gate' -RunSecret $secret -KeyId $keyId
  $r['signature'] = $sig
  return $r
}
# Scalar-only canonical writer (lane_gate has no arrays): null->null, int->number, else->JSON string.
function Write-LaneGateReceipt([string]$path, $receipt) {
  $parts = New-Object System.Collections.ArrayList
  foreach ($k in $receipt.Keys) {
    $v = $receipt[$k]
    $name = ConvertTo-Json -InputObject ([string]$k) -Compress
    if ($null -eq $v) { [void]$parts.Add(('{0}:null' -f $name)); continue }
    if ($v -is [int] -or $v -is [int32] -or $v -is [int64] -or $v -is [long]) { [void]$parts.Add(('{0}:{1}' -f $name, [string][int64]$v)); continue }
    [void]$parts.Add(('{0}:{1}' -f $name, (ConvertTo-Json -InputObject ([string]$v) -Compress)))
  }
  $parent = Split-Path -Parent $path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($path, ('{' + ($parts -join ',') + '}'), $utf8)
}

if ($SelfTest) {
  $fail = 0
  function Check([string]$n, [bool]$ok) { if ($ok) { Write-Output "PASS $n" } else { Write-Output "FAIL $n"; $script:fail++ } }
  . (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
  $secret = [byte[]](1..32); $kid = ('a' * 32)
  $f = @{ runId = 'r'; taskId = 't'; laneId = 'g'; model = 'grok-4.5'; observedModel = 'grok-4.5'; modelEvidence = 'unified-log'; emitterId = 'e'; inputSha = ('b' * 64); resultSha = ('c' * 64); lockedPlan = ('d' * 64); cheapGate = 'psvalid'; cheapClaim = '0/0'; exitCode = 0; outcome = 'completed'; startedAt = '2026-08-08T00:00:00.0000000Z'; completedAt = '2026-08-08T00:00:10.0000000Z' }
  $rec = New-LaneGateReceipt $f $secret $kid $PSScriptRoot
  $dir = Join-Path $env:TEMP ('lanereceipt-selftest-' + [guid]::NewGuid().ToString('n')); New-Item -ItemType Directory -Force -Path $dir | Out-Null
  try {
    $rp = Join-Path $dir 'r.json'
    Write-LaneGateReceipt $rp $rec
    Check 'receipt written' (Test-Path -LiteralPath $rp)
    $back = [IO.File]::ReadAllText($rp, $utf8) | ConvertFrom-Json
    $v = Test-FleetReceiptSignature -Receipt $back -ReceiptType 'lane_gate' -RunSecret $secret -KeyId $kid -Signature ([string]$back.signature)
    Check 'written receipt verifies after JSON round-trip' ($v.ok)
    $vt = Test-FleetReceiptSignature -Receipt $back -ReceiptType 'lane_gate' -RunSecret $secret -KeyId $kid -Signature (($back.signature).Substring(0, 62) + '00')
    Check 'a tampered signature fails' (-not $vt.ok)
    $vw = Test-FleetReceiptSignature -Receipt $back -ReceiptType 'lane_gate' -RunSecret ([byte[]](50..81)) -KeyId $kid -Signature ([string]$back.signature)
    Check 'wrong key fails' (-not $vw.ok)
  }
  finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'Test-NewFleetLaneReceipt: passed (4 checks)'; exit 0 }
  Write-Output "Test-NewFleetLaneReceipt: FAILED ($fail)"; exit 1
}

# --- main ---
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
if (-not (Test-Path -LiteralPath $GrokResult -PathType Leaf)) { throw "GrokResult not found: $GrokResult" }
$key = Get-FleetRunLeaseKey -RunId $RunId   # @{ KeyId; KeyBytes } from the ACL-locked lease
$grok = [IO.File]::ReadAllText($GrokResult, $utf8) | ConvertFrom-Json
$grokText = [IO.File]::ReadAllText($GrokResult, $utf8)

$observed = if ($grok.PSObject.Properties['observed_model'] -and $grok.observed_model) { [string]$grok.observed_model } elseif ($grok.PSObject.Properties['model']) { [string]$grok.model } else { 'grok-4.5' }
$evidence = if ($grok.PSObject.Properties['model_evidence'] -and $grok.model_evidence) { [string]$grok.model_evidence } else { 'unified-log' }
$ts = [string]$grok.task_status
$claimedGreen = ($ts -eq 'done') -or (([string]$grok.status) -eq 'ok' -and ($ts -eq '' -or $ts -eq 'done'))
$exit = if ($claimedGreen) { 0 } else { 1 }
$outcome = if ($claimedGreen) { 'completed' } elseif (-not [string]::IsNullOrWhiteSpace($ts)) { $ts } else { 'failed' }
# grok's claimed cheap-gate line, if present in its self-check text.
$cheapClaim = ''
$m = [regex]::Match($grokText, 'psvalid:[^"\\\r\n]*')
if ($m.Success) { $cheapClaim = $m.Value.Trim() }

$diff = & git -C $RepoPath diff $BaseRef 2>$null
$inputSha = Get-Sha256Text ((@($diff) -join "`n"))
$resultSha = Get-Sha256File $GrokResult
$now = Get-NowTs

$fields = @{
  runId = $RunId; taskId = $TaskId; laneId = $LaneId; model = $observed; observedModel = $observed
  modelEvidence = $evidence; emitterId = $EmitterId; inputSha = $inputSha; resultSha = $resultSha
  lockedPlan = $LockedPlanSha256; cheapGate = $CheapGate; cheapClaim = $cheapClaim; exitCode = $exit
  outcome = $outcome; startedAt = $now; completedAt = $now
}
$receipt = New-LaneGateReceipt $fields $key.KeyBytes $key.KeyId $PSScriptRoot
Write-LaneGateReceipt $OutputPath $receipt
Write-Output $OutputPath
exit 0
