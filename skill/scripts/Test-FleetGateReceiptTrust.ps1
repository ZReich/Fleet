# RED-TEAM: can a signed gate receipt be RELIED ON to skip the barrier re-run?
# Answers the owner's question empirically, using the real signing primitives.
# Four facts, each PASS/FAIL:
#   1. A valid receipt is tamper-evident (flip a field -> signature fails).
#   2. A keyless lane cannot forge a receipt (wrong key -> verify fails).
#   3. THE GAP: a cryptographically VALID receipt can assert a gate PASSED while the
#      actual gate on that exact code FAILS. Signature verify != gate truth.
#   4. A cheap barrier spot-check (re-run the deterministic gate) CATCHES the false claim.
# Conclusion the script prints: rely on the receipt for identity/tamper-evidence/binding;
# keep a cheap re-run (or sample) for gate TRUTH.
[CmdletBinding()]
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
$fail = 0
function Check([string]$n, [bool]$ok) { if ($ok) { Write-Output "PASS $n" } else { Write-Output "FAIL $n"; $script:fail++ } }
function Note([string]$m) { if (-not $Quiet) { Write-Output "  $m" } }

# --- a real run key (what the ACL-locked lease holds; a lane cannot read it) ---
$secret = [byte[]](1..32)
$keyId = ('a' * 32)
$wrongSecret = [byte[]](100..131)

# --- a merge_stage receipt CLAIMING the gate passed (exit 0 / completed) ---
function New-GateReceipt([int]$ExitCode, [string]$Outcome, [string]$ResultSha) {
  [ordered]@{
    schema_version = '2'; receipt_type = 'merge_stage'; run_id = 'demo-run'; task_id = 'task-1'; lane_id = 'grok-lane-1'
    stage = 'build-typecheck'; required = $true; status = 'passed'; requested_model = 'grok-4.5'; observed_model = 'grok-4.5'
    model_evidence = 'unified-log'; effort = 'high'; input_packet_sha256 = ('b' * 64); emitter_id = 'grok-emitter'
    locked_plan_sha256 = ('c' * 64); stage_set_sha256 = ('d' * 64); review_tier = 'STANDARD'; review_profile = 'standard'
    charter_path = 'C:\tmp\charter.md'; result_path = 'C:\tmp\gate-result.txt'; result_sha256 = $ResultSha; charter_sha256 = ('e' * 64)
    exit_code = $ExitCode; outcome = $Outcome; fallback_of = $null; failure_category = $null
    findings = [object[]]@(); evidence_refs = [string[]]@('gate:psvalid'); output_artifacts = [string[]]@()
    started_at = '2026-08-08T00:00:00.0000000Z'; completed_at = '2026-08-08T00:00:10.0000000Z'
    model = 'grok-4.5'; sig_alg = 'HMAC-SHA256'
  }
}
function Get-TextSha([string]$s) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

# The grok lane's SELF-REPORTED gate result file says "green".
$claimedResult = "psvalid: 0 parse errors, 0 test failures over 1 changed .ps1"
$resultSha = Get-TextSha $claimedResult
$receipt = New-GateReceipt 0 'completed' $resultSha
$sig = New-FleetReceiptSignature -Receipt ([pscustomobject]$receipt) -ReceiptType 'merge_stage' -RunSecret $secret -KeyId $keyId

# FACT 1 - tamper-evidence: verify OK, then flip exit_code and re-verify -> must fail.
$v1 = Test-FleetReceiptSignature -Receipt ([pscustomobject]$receipt) -ReceiptType 'merge_stage' -RunSecret $secret -KeyId $keyId -Signature $sig
$tampered = New-GateReceipt 1 'completed' $resultSha   # attacker flips exit_code, keeps old signature
$v1t = Test-FleetReceiptSignature -Receipt ([pscustomobject]$tampered) -ReceiptType 'merge_stage' -RunSecret $secret -KeyId $keyId -Signature $sig
Check '1. valid receipt verifies; tampering a field breaks the signature' ($v1.ok -and -not $v1t.ok)
Note "verify(valid)=$($v1.ok)  verify(tampered exit_code)=$($v1t.ok) [$($v1t.reason)]"

# FACT 2 - keyless forge: a lane WITHOUT the run key cannot make a receipt that verifies.
$v2 = Test-FleetReceiptSignature -Receipt ([pscustomobject]$receipt) -ReceiptType 'merge_stage' -RunSecret $wrongSecret -KeyId $keyId -Signature $sig
$forgedSig = New-FleetReceiptSignature -Receipt ([pscustomobject]$receipt) -ReceiptType 'merge_stage' -RunSecret $wrongSecret -KeyId $keyId
$v2b = Test-FleetReceiptSignature -Receipt ([pscustomobject]$receipt) -ReceiptType 'merge_stage' -RunSecret $secret -KeyId $keyId -Signature $forgedSig
Check '2. a keyless lane cannot forge a verifying receipt' ((-not $v2.ok) -and (-not $v2b.ok))
Note "verify(wrong key)=$($v2.ok)  verify(sig made with wrong key)=$($v2b.ok)"

# FACT 3 - THE GAP: the receipt is cryptographically VALID and asserts the gate PASSED,
# but the ACTUAL gate on that exact code FAILS. Build a real broken .ps1 and run the real gate.
$dir = Join-Path $env:TEMP ('gatetrust-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
try {
  $broken = Join-Path $dir 'Broken.ps1'
  [IO.File]::WriteAllText($broken, "Write-Output `"bad " + [char]0x2014 + " dash`"; if (`$x) { ")  # em-dash: unterminated string
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($broken, [ref]$null, [ref]$parseErrors)
  $realGatePassed = ($null -eq $parseErrors -or @($parseErrors).Count -eq 0)
  $receiptSaysPassed = ($receipt.exit_code -eq 0 -and $receipt.outcome -eq 'completed')
  $sigValid = $v1.ok
  Check '3. a VALID signed receipt can assert PASS while the real gate FAILS' ($sigValid -and $receiptSaysPassed -and (-not $realGatePassed))
  Note "signature valid=$sigValid  receipt claims=PASS  actual gate=$(if($realGatePassed){'PASS'}else{'FAIL ('+@($parseErrors).Count+' parse errors)'})"

  # FACT 4 - spot-check: re-running the deterministic gate diverges from the receipt's claim -> lie caught.
  $spotCheckPassed = $realGatePassed
  $divergence = ($receiptSaysPassed -ne $spotCheckPassed)
  Check '4. a cheap barrier re-run of the gate CATCHES the false claim' $divergence
  Note "receipt=PASS vs spot-check=$(if($spotCheckPassed){'PASS'}else{'FAIL'}) -> divergence=$divergence (the lie is caught)"
}
finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output ''
if ($fail -eq 0) {
  Write-Output 'VERDICT: signature = sound (identity + tamper-evidence + binding, un-forgeable without the run key).'
  Write-Output 'VERDICT: signature != gate truth. A valid receipt can carry a false green.'
  Write-Output 'VERDICT: rely on the receipt to skip re-VERIFYING identity/integrity; keep a CHEAP gate re-run'
  Write-Output '         (deterministic gates in full, expensive gates by sample) to catch a lying/buggy lane.'
  Write-Output 'Test-FleetGateReceiptTrust: passed (4 checks)'
  exit 0
}
Write-Output "Test-FleetGateReceiptTrust: FAILED ($fail)"
exit 1
