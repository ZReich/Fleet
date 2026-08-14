# Round audit artifact (Sol D4/D5, fleet-reviewburn-20260811). Records which lanes were
# dispatched fresh vs carried forward from a prior round on an IDENTICAL packet hash.
# DIAGNOSTIC ONLY: trust stays in the signed receipts + Assert-FleetReviewIntegrity, which
# binds every receipt's input_packet_sha256 to the current packet manifest — so a carried
# receipt that no longer matches the packet fails certification regardless of this file.
# Carrying rules enforced here (fail closed): only outcome=completed receipts whose parsed
# verdict is GO may carry; findings/refusals/failures/hash-mismatches never carry.
# Prints "review-round: <round_id> | packet: <sha8> | new: N | carried: K | counted: true|false".
[CmdletBinding()]
param(
  # Not [Mandatory]: psvalid invokes `-SelfTest` bare; the CLI path validates below.
  [string]$RunId = '',
  [int]$RoundNumber = 0,
  [string]$PacketSha256 = '',
  # Receipt files dispatched fresh THIS round.
  [string[]]$NewReceipts = @(),
  # Receipt files carried from a prior round (same run, identical packet hash required).
  [string[]]$CarriedReceipts = @(),
  [string]$CarriedFromRound = '',
  [string]$OutDir = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetReviewGrammar.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetReviewVoice.Helpers.ps1')
$utf8 = New-Object System.Text.UTF8Encoding $false

# Signature-verified read (Terra M1 2026-08-11): the round artifact must not launder arbitrary
# JSON into a provenance trail. Every recorded receipt — new or carried — must be a canonical
# v2 review_lane receipt whose HMAC verifies under the run lease key; a missing lease key
# fails closed (rounds are recorded mid-run while the lease is held).
function Read-RoundReceipt([string]$Path, [string]$RunId) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "receipt missing: $Path" }
  $raw = [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding $false)) | ConvertFrom-Json
  $obj = ConvertTo-OrderedReviewReceipt $raw
  if ($null -eq $obj) { throw "receipt noncanonical: $Path" }
  if ([string]$obj.schema_version -cne '2' -or [string]$obj.receipt_type -cne 'review_lane') { throw "receipt not a v2 review_lane receipt: $Path" }
  $keyInfo = Get-FleetRunLeaseKey -RunId $RunId
  $sig = ''; if ($obj.PSObject.Properties['signature']) { $sig = [string]$obj.signature }
  $vr = Test-FleetReceiptSignature -Receipt $obj -ReceiptType 'review_lane' -RunSecret ([byte[]]$keyInfo.KeyBytes) -KeyId ([string]$keyInfo.KeyId) -Signature $sig
  if (-not $vr.ok) { throw "receipt signature invalid: $Path" }
  $sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  return @{ Obj = $obj; Sha = $sha; Path = [IO.Path]::GetFullPath($Path) }
}

function Test-CarryEligible($Receipt, [string]$RunId, [string]$PacketSha256) {
  $o = $Receipt.Obj
  if ([string]$o.run_id -cne $RunId) { return "run_id mismatch ($($o.run_id))" }
  if (([string]$o.input_packet_sha256).ToLowerInvariant() -cne $PacketSha256.ToLowerInvariant()) { return 'packet hash mismatch' }
  if ([string]$o.outcome -cne 'completed') { return "outcome $($o.outcome) cannot carry" }
  $resultPath = [string]$o.result_path
  if ([string]::IsNullOrWhiteSpace($resultPath) -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { return 'result file missing' }
  $body = [IO.File]::ReadAllText($resultPath, (New-Object System.Text.UTF8Encoding $false))
  # Result bytes must still match the signed receipt's result hash (Sol H5 2026-08-11).
  $utf8L = New-Object System.Text.UTF8Encoding $false
  $shaAlg = [Security.Cryptography.SHA256]::Create()
  try { $bodySha = -join ($shaAlg.ComputeHash($utf8L.GetBytes($body)) | ForEach-Object { $_.ToString('x2') }) } finally { $shaAlg.Dispose() }
  if ($bodySha -cne ([string]$o.result_sha256).ToLowerInvariant()) { return 'result bytes no longer match signed result_sha256' }
  $parsed = Parse-FleetReviewVerdict $body
  if (-not $parsed.valid) {
    # Wrapper JSON envelope: parse the response field.
    try {
      $env2 = $body | ConvertFrom-Json -ErrorAction Stop
      if ($env2.PSObject.Properties['response']) { $parsed = Parse-FleetReviewVerdict ([string]$env2.response) }
    } catch { }
  }
  if (-not $parsed.valid) { return 'verdict unparseable' }
  # Sol D4 locked: only GO with NO findings carries — a GO carrying MEDIUM/LOW findings is
  # still open review material and must be re-reviewed or repaired.
  if ($parsed.verdict -cne 'GO' -or -not $parsed.no_findings -or [int]$parsed.findings_count -gt 0) {
    return "only GO/no-findings may carry (verdict=$($parsed.verdict) findings=$($parsed.findings_count))"
  }
  return $null
}

function New-FleetReviewRoundDoc {
  param([string]$RunId, [int]$RoundNumber, [string]$PacketSha256, [string[]]$NewReceipts,
    [string[]]$CarriedReceipts, [string]$CarriedFromRound, [string]$OutDir)
  if ($RunId -notmatch '^[A-Za-z0-9._-]+$') { throw "invalid RunId: $RunId" }
  if ($PacketSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'PacketSha256 must be sha256 hex' }
  if (-not [string]::IsNullOrWhiteSpace($CarriedFromRound)) {
    if ($CarriedFromRound -cnotmatch '^r\d+$') { throw "CarriedFromRound must be r<N>: $CarriedFromRound" }
    if ([int]($CarriedFromRound.Substring(1)) -ge $RoundNumber) { throw "CarriedFromRound $CarriedFromRound must precede round $RoundNumber" }
  }
  $entries = New-Object System.Collections.ArrayList
  $seenLanes = @{}
  $counted = $false
  foreach ($p in @($NewReceipts)) {
    $r = Read-RoundReceipt $p $RunId
    $lane = [string]$r.Obj.lane_id
    if ($seenLanes.ContainsKey($lane)) { throw "duplicate lane receipt: $lane" }
    $seenLanes[$lane] = $true
    if (([string]$r.Obj.input_packet_sha256).ToLowerInvariant() -cne $PacketSha256.ToLowerInvariant()) { throw "new receipt $lane not bound to this packet" }
    if ([string]$r.Obj.outcome -cin @('completed', 'refused')) { $counted = $true }
    [void]$entries.Add([ordered]@{ lane_id = $lane; disposition = 'new'; carried_forward_from = $null; receipt_path = $r.Path; receipt_sha256 = $r.Sha })
  }
  foreach ($p in @($CarriedReceipts)) {
    if ([string]::IsNullOrWhiteSpace($CarriedFromRound)) { throw 'CarriedFromRound required when carrying receipts' }
    $r = Read-RoundReceipt $p $RunId
    $lane = [string]$r.Obj.lane_id
    if ($seenLanes.ContainsKey($lane)) { throw "duplicate lane receipt: $lane" }
    $seenLanes[$lane] = $true
    $why = Test-CarryEligible $r $RunId $PacketSha256
    if ($null -ne $why) { throw "carry refused for lane ${lane}: $why" }
    [void]$entries.Add([ordered]@{ lane_id = $lane; disposition = 'carried'; carried_forward_from = $CarriedFromRound; receipt_path = $r.Path; receipt_sha256 = $r.Sha })
  }
  if ($entries.Count -eq 0) { throw 'round has no receipts' }
  $countReason = if ($counted) { 'voice reviewed this packet (completed or refused receipt)' } else { 'no completed/refused fresh receipt - transport-only attempt, round does not count' }
  $doc = [ordered]@{
    schema_version = '1'; run_id = $RunId; round_id = ('r' + $RoundNumber); packet_sha256 = $PacketSha256.ToLowerInvariant()
    counted = $counted; count_reason = $countReason; review_receipts = @($entries)
  }
  $outPath = Join-Path $OutDir ('review-round-' + $RoundNumber + '.json')
  if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
  $json = ($doc | ConvertTo-Json -Depth 6) + "`n"
  # Never rewrite round history (Sol M1): existing artifact allows only byte-identical replay.
  if (Test-Path -LiteralPath $outPath -PathType Leaf) {
    $existing = [IO.File]::ReadAllText($outPath, (New-Object System.Text.UTF8Encoding $false))
    if ($existing -cne $json) { throw "review-round-$RoundNumber.json already exists with different content" }
  } else {
    [IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding $false))
  }
  return [pscustomobject]$doc
}

if ($SelfTest) {
  $fail = 0
  function Check([string]$n, [bool]$ok) { if ($ok) { Write-Output "PASS $n" } else { Write-Output "FAIL $n"; $script:fail++ } }
  $tmp = Join-Path $env:TEMP ('round-st-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $savedProfile = $env:USERPROFILE
  try {
    # Signed fixtures under a test lease (receipts must verify — Terra M1).
    $env:USERPROFILE = $tmp
    $script:LeaseHome = $tmp; $script:RunSeq = 900; $script:LeaseFields = $null
    . (Join-Path $PSScriptRoot 'FleetSignedTest.Helpers.ps1')
    $lease = New-TestLease
    $runId = $lease.RunId
    $pkt = 'a' * 64
    function W-Receipt([string]$Lane, [string]$Outcome, [string]$Body, [string]$Pkt) {
      $rp = Join-Path $tmp ($Lane + '-result.md')
      [IO.File]::WriteAllText($rp, $Body, (New-Object System.Text.UTF8Encoding $false))
      $sha = [Security.Cryptography.SHA256]::Create()
      try { $bodySha = -join ($sha.ComputeHash((New-Object System.Text.UTF8Encoding $false).GetBytes($Body)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
      $rec = [pscustomobject][ordered]@{
        schema_version = '2'; receipt_type = 'review_lane'; run_id = $script:StRunId; task_id = 't1'
        lane_id = $Lane; voice_id = $Lane; review_role = 'general-review'
        requested_model = 'grok-4.6'; observed_model = 'grok-4.6'; model_evidence = 'observed-provider:grok-unified-log'
        emitter_id = 'Invoke-FleetSignedLane'; input_packet_sha256 = $Pkt
        expected_lane_manifest_sha256 = ('c' * 64); locked_plan_sha256 = ('d' * 64); review_profile = 'general'
        charter_path = (Join-Path $tmp 'charter.txt'); review_tier = 'STANDARD'; result_path = $rp
        charter_sha256 = ('e' * 64); result_sha256 = $bodySha; exit_code = 0; outcome = $Outcome
        refusal_reason = $null; fallback_of = $null
        started_at = '2026-08-11T00:00:00.0000000Z'; completed_at = '2026-08-11T00:01:00.0000000Z'
        sig_alg = 'HMAC-SHA256'; key_id = $script:StKeyId; signature = ''
      }
      $p = Join-Path $tmp ($Lane + '.receipt.json')
      Write-SignedReceiptJson $p $rec $script:StSecret $script:StKeyId
      return $p
    }
    $script:StRunId = $runId; $script:StSecret = $lease.Secret; $script:StKeyId = $lease.KeyId
    $go = "review body`n`nVERDICT: GO`nFINDINGS: none"
    $noGo = "review body`n`nVERDICT: NO-GO`nFINDINGS:`n- HIGH | F1 | a.ps1:1 | bad"
    $r1 = W-Receipt 'v-a' 'completed' $go $pkt
    $r2 = W-Receipt 'v-b' 'completed' $noGo $pkt
    $doc = New-FleetReviewRoundDoc -RunId $runId -RoundNumber 1 -PacketSha256 $pkt -NewReceipts @($r1, $r2) -CarriedReceipts @() -CarriedFromRound '' -OutDir $tmp
    Check 'round 1 counted with two fresh' ($doc.counted -and @($doc.review_receipts).Count -eq 2)
    Check 'artifact written' (Test-Path (Join-Path $tmp 'review-round-1.json'))
    # Round 2: carry the GO voice, redispatch the NO-GO voice.
    $r2b = W-Receipt 'v-b2' 'completed' $go $pkt
    $doc2 = New-FleetReviewRoundDoc -RunId $runId -RoundNumber 2 -PacketSha256 $pkt -NewReceipts @($r2b) -CarriedReceipts @($r1) -CarriedFromRound 'r1' -OutDir $tmp
    $carried = @($doc2.review_receipts | Where-Object { $_.disposition -eq 'carried' })
    Check 'GO receipt carries on identical hash' ($carried.Count -eq 1 -and $carried[0].carried_forward_from -eq 'r1')
    # NO-GO receipt cannot carry.
    $threw = $false; try { $null = New-FleetReviewRoundDoc -RunId $runId -RoundNumber 3 -PacketSha256 $pkt -NewReceipts @() -CarriedReceipts @($r2) -CarriedFromRound 'r1' -OutDir $tmp } catch { $threw = $true }
    Check 'NO-GO carry refused' $threw
    # Changed packet hash: carry refused.
    $threw = $false; try { $null = New-FleetReviewRoundDoc -RunId $runId -RoundNumber 3 -PacketSha256 ('b' * 64) -NewReceipts @() -CarriedReceipts @($r1) -CarriedFromRound 'r1' -OutDir $tmp } catch { $threw = $true }
    Check 'changed packet carry refused' $threw
    # Refused receipt cannot carry.
    $r3 = W-Receipt 'v-c' 'refused' $go $pkt
    $threw = $false; try { $null = New-FleetReviewRoundDoc -RunId $runId -RoundNumber 3 -PacketSha256 $pkt -NewReceipts @() -CarriedReceipts @($r3) -CarriedFromRound 'r1' -OutDir $tmp } catch { $threw = $true }
    Check 'refused carry refused' $threw
    # Wrong run id.
    $threw = $false; try { $null = New-FleetReviewRoundDoc -RunId 'other' -RoundNumber 3 -PacketSha256 $pkt -NewReceipts @() -CarriedReceipts @($r1) -CarriedFromRound 'r1' -OutDir $tmp } catch { $threw = $true }
    Check 'wrong run carry refused' $threw
    # Duplicate lane across new+carried.
    $threw = $false; try { $null = New-FleetReviewRoundDoc -RunId $runId -RoundNumber 3 -PacketSha256 $pkt -NewReceipts @($r1) -CarriedReceipts @($r1) -CarriedFromRound 'r1' -OutDir $tmp } catch { $threw = $true }
    Check 'duplicate lane refused' $threw
    # Transport-only round does not count.
    $r4 = W-Receipt 'v-d' 'failed' $go $pkt
    $doc4 = New-FleetReviewRoundDoc -RunId $runId -RoundNumber 4 -PacketSha256 $pkt -NewReceipts @($r4) -CarriedReceipts @() -CarriedFromRound '' -OutDir $tmp
    Check 'all-failed round not counted' (-not $doc4.counted)
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'Test-NewFleetReviewRound: passed (9 checks)'; exit 0 }
  Write-Output "Test-NewFleetReviewRound: FAILED ($fail)"; exit 1
}

if ([string]::IsNullOrWhiteSpace($RunId) -or $RoundNumber -lt 1 -or [string]::IsNullOrWhiteSpace($PacketSha256) -or [string]::IsNullOrWhiteSpace($OutDir)) {
  throw 'RunId, RoundNumber (>=1), PacketSha256, and OutDir are required'
}
$doc = New-FleetReviewRoundDoc -RunId $RunId -RoundNumber $RoundNumber -PacketSha256 $PacketSha256 `
  -NewReceipts $NewReceipts -CarriedReceipts $CarriedReceipts -CarriedFromRound $CarriedFromRound -OutDir $OutDir
$newN = @($doc.review_receipts | Where-Object { $_.disposition -eq 'new' }).Count
$carN = @($doc.review_receipts | Where-Object { $_.disposition -eq 'carried' }).Count
Write-Output ("review-round: {0} | packet: {1} | new: {2} | carried: {3} | counted: {4}" -f $doc.round_id, $PacketSha256.Substring(0, 8), $newN, $carN, $doc.counted.ToString().ToLowerInvariant())
exit 0
