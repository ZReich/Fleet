# Self-test for FleetReceiptSignature.Helpers.ps1. Prints selftest: PASS k/k; exit 0/1.
# Orchestrator may pass -SelfTest; always runs the suite.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')

$script:passed = 0
$script:failed = 0
$script:total = 0

function Case([string]$Name, [scriptblock]$Body) {
  $script:total++
  try {
    & $Body
    $script:passed++
    Write-Host ("PASS {0}" -f $Name)
  } catch {
    $script:failed++
    Write-Host ("FAIL {0} - {1}" -f $Name, $_.Exception.Message)
  }
}
function Assert-True([bool]$Cond, [string]$Msg) {
  if (-not $Cond) { throw $Msg }
}
function Get-FixedSha([string]$seed) {
  # Deterministic lowercase 64-hex from seed (not security; test fixture only).
  $b = [Text.Encoding]::UTF8.GetBytes($seed)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $h = $sha.ComputeHash($b)
    $sb = New-Object Text.StringBuilder 64
    foreach ($x in $h) { [void]$sb.Append($x.ToString('x2')) }
    return $sb.ToString()
  } finally { $sha.Dispose() }
}
function New-ReviewReceipt([string]$KeyId, $Refusal = $null) {
  $sha1 = Get-FixedSha 'pkt'; $sha2 = Get-FixedSha 'man'; $sha3 = Get-FixedSha 'plan'
  $sha4 = Get-FixedSha 'char'; $sha5 = Get-FixedSha 'res'
  return [pscustomobject][ordered]@{
    schema_version = '2'
    receipt_type = 'review_lane'
    run_id = 'run-1'
    task_id = 'task-1'
    lane_id = 'T1'
    voice_id = 'v-grok'
    review_role = 'general-review'
    requested_model = 'grok-4.6'
    observed_model = 'grok-4.6'
    model_evidence = 'wrapper-log'
    emitter_id = 'Invoke-Grok45'
    input_packet_sha256 = $sha1
    expected_lane_manifest_sha256 = $sha2
    locked_plan_sha256 = $sha3
    review_profile = 'standard'
    charter_path = 'C:\tmp\charter.md'
    review_tier = 'STANDARD'
    result_path = 'C:\tmp\result.md'
    charter_sha256 = $sha4
    result_sha256 = $sha5
    exit_code = 0
    outcome = 'completed'
    refusal_reason = $Refusal
    fallback_of = $null
    started_at = '2026-08-06T12:00:00.0000000Z'
    completed_at = '2026-08-06T12:01:00.0000000Z'
    sig_alg = 'HMAC-SHA256'
    key_id = $KeyId
  }
}
function New-MergeReceipt {
  $sha1 = Get-FixedSha 'pkt2'; $sha2 = Get-FixedSha 'plan2'; $sha3 = Get-FixedSha 'stages'
  $sha4 = Get-FixedSha 'res2'; $sha5 = Get-FixedSha 'char2'
  $finding = [pscustomobject][ordered]@{ severity = 'HIGH'; id = 'F1'; resolved = $true }
  return [pscustomobject][ordered]@{
    schema_version = '2'
    receipt_type = 'merge_stage'
    run_id = 'run-2'
    task_id = 'task-2'
    lane_id = 'MS1'
    stage = 'triage'
    required = $true
    status = 'passed'
    requested_model = 'claude-opus-5'
    observed_model = 'claude-opus-5'
    model_evidence = 'cli-envelope'
    effort = 'high'
    input_packet_sha256 = $sha1
    emitter_id = 'Invoke-FleetSignedLane'
    locked_plan_sha256 = $sha2
    stage_set_sha256 = $sha3
    review_tier = 'FULL'
    review_profile = 'security-sensitive'
    charter_path = 'C:\tmp\mcharter.md'
    result_path = 'C:\tmp\mresult.md'
    result_sha256 = $sha4
    charter_sha256 = $sha5
    exit_code = 0
    outcome = 'completed'
    fallback_of = $null
    failure_category = $null
    findings = [object[]]@($finding)
    evidence_refs = [string[]]@('ref-a')
    output_artifacts = [string[]]@()
    started_at = '2026-08-06T13:00:00.0000000Z'
    completed_at = '2026-08-06T13:05:00.0000000Z'
    model = 'claude-opus-5'
    sig_alg = 'HMAC-SHA256'
  }
}
function Copy-OrderedReceipt($src) {
  $o = [ordered]@{}
  foreach ($p in $src.PSObject.Properties) { $o[$p.Name] = $p.Value }
  return [pscustomobject]$o
}

# Fixed 32-byte secret + 32-hex key_id for receipt vectors.
$secret = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $secret[$i] = [byte]$i }
$keyId = '0123456789abcdef0123456789abcdef'
$wrongSecret = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $wrongSecret[$i] = [byte](255 - $i) }

Case 'known HMAC-SHA256 vector (RFC4231 TC2)' {
  # key="Jefe" data="what do ya want for nothing?"
  $k = [Text.Encoding]::UTF8.GetBytes('Jefe')
  $m = [Text.Encoding]::UTF8.GetBytes('what do ya want for nothing?')
  $h = New-Object System.Security.Cryptography.HMACSHA256
  try {
    $h.Key = $k
    $hash = $h.ComputeHash($m)
    $sb = New-Object Text.StringBuilder 64
    foreach ($x in $hash) { [void]$sb.Append($x.ToString('x2')) }
    $got = $sb.ToString()
  } finally { $h.Dispose() }
  $exp = '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843'
  Assert-True ($got -ceq $exp) ("mac mismatch got=$got")
}

Case 'review_lane sign+verify ok' {
  $r = New-ReviewReceipt $keyId
  $sig = New-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId
  Assert-True ($sig -cmatch '^[0-9a-f]{64}$') 'sig format'
  $v = Test-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature $sig
  Assert-True ($v.ok -eq $true) ("not ok: $($v.reason)")
  Assert-True ($v.reason -ceq 'ok') "reason=$($v.reason)"
}

Case 'merge_stage sign+verify ok' {
  $r = New-MergeReceipt
  $sig = New-FleetReceiptSignature -Receipt $r -ReceiptType 'merge_stage' -RunSecret $secret -KeyId $keyId
  Assert-True ($sig -cmatch '^[0-9a-f]{64}$') 'sig format'
  $v = Test-FleetReceiptSignature -Receipt $r -ReceiptType 'merge_stage' -RunSecret $secret -KeyId $keyId -Signature $sig
  Assert-True ($v.ok -eq $true) ("not ok: $($v.reason)")
  Assert-True ($v.reason -ceq 'ok') "reason=$($v.reason)"
}

Case 'wrong key => bad_signature' {
  $r = New-ReviewReceipt $keyId
  $sig = New-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId
  $v = Test-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $wrongSecret -KeyId $keyId -Signature $sig
  Assert-True ($v.ok -eq $false) 'should fail'
  Assert-True ($v.reason -ceq 'bad_signature') "reason=$($v.reason)"
}

Case 'missing signature => missing_signature' {
  $r = New-ReviewReceipt $keyId
  $v = Test-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature ''
  Assert-True ($v.ok -eq $false) 'should fail'
  Assert-True ($v.reason -ceq 'missing_signature') "reason=$($v.reason)"
}

Case 'mutated field post-sign => bad_signature' {
  $r = New-ReviewReceipt $keyId
  $sig = New-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId
  $r2 = Copy-OrderedReceipt $r
  $r2.outcome = 'refused'
  $v = Test-FleetReceiptSignature -Receipt $r2 -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature $sig
  Assert-True ($v.ok -eq $false) 'should fail'
  Assert-True ($v.reason -ceq 'bad_signature') "reason=$($v.reason)"
}

Case 'missing field => noncanonical_shape' {
  $r = New-ReviewReceipt $keyId
  $sig = New-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId
  $o = [ordered]@{}
  foreach ($p in $r.PSObject.Properties) {
    if ($p.Name -ceq 'fallback_of') { continue }
    $o[$p.Name] = $p.Value
  }
  $r2 = [pscustomobject]$o
  $v = Test-FleetReceiptSignature -Receipt $r2 -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature $sig
  Assert-True ($v.ok -eq $false) 'should fail'
  Assert-True ($v.reason -ceq 'noncanonical_shape') "reason=$($v.reason)"
}

Case 'extra field => noncanonical_shape' {
  $r = New-ReviewReceipt $keyId
  $sig = New-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId
  $o = [ordered]@{}
  foreach ($p in $r.PSObject.Properties) { $o[$p.Name] = $p.Value }
  $o['extra_field'] = 'nope'
  $r2 = [pscustomobject]$o
  $v = Test-FleetReceiptSignature -Receipt $r2 -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature $sig
  Assert-True ($v.ok -eq $false) 'should fail'
  Assert-True ($v.reason -ceq 'noncanonical_shape') "reason=$($v.reason)"
}

Case 'reordered field => noncanonical_shape' {
  $r = New-ReviewReceipt $keyId
  $sig = New-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId
  $o = [ordered]@{}
  $names = @($r.PSObject.Properties | ForEach-Object { $_.Name })
  # swap first two signed fields
  $tmp = $names[0]; $names[0] = $names[1]; $names[1] = $tmp
  foreach ($n in $names) { $o[$n] = $r.$n }
  $r2 = [pscustomobject]$o
  $v = Test-FleetReceiptSignature -Receipt $r2 -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature $sig
  Assert-True ($v.ok -eq $false) 'should fail'
  Assert-True ($v.reason -ceq 'noncanonical_shape') "reason=$($v.reason)"
}

Case 'null-vs-empty-string confusion => bad_signature' {
  $r = New-ReviewReceipt $keyId $null
  $sig = New-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId
  $r2 = Copy-OrderedReceipt $r
  $r2.refusal_reason = ''
  $v = Test-FleetReceiptSignature -Receipt $r2 -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature $sig
  Assert-True ($v.ok -eq $false) 'should fail'
  Assert-True ($v.reason -ceq 'bad_signature') "reason=$($v.reason)"
}

Case 'UPPERCASE sha => noncanonical_shape' {
  $r = New-ReviewReceipt $keyId
  $sig = New-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId
  $r2 = Copy-OrderedReceipt $r
  $r2.input_packet_sha256 = $r2.input_packet_sha256.ToUpperInvariant()
  $v = Test-FleetReceiptSignature -Receipt $r2 -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature $sig
  Assert-True ($v.ok -eq $false) 'should fail'
  Assert-True ($v.reason -ceq 'noncanonical_shape') "reason=$($v.reason)"
}

Case 'malformed non-64-hex signature => bad_signature' {
  $r = New-ReviewReceipt $keyId
  $null = New-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId
  $v = Test-FleetReceiptSignature -Receipt $r -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature 'deadbeef'
  Assert-True ($v.ok -eq $false) 'should fail'
  Assert-True ($v.reason -ceq 'bad_signature') "reason=$($v.reason)"
}

Write-Output ("selftest: PASS {0}/{1}" -f $script:passed, $script:total)
if ($script:failed -gt 0) { exit 1 }
exit 0
