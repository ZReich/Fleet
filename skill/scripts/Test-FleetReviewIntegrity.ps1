# Self-test Assert-FleetReviewIntegrity.ps1 (signature-first). Prints selftest: PASS k/k.
$ErrorActionPreference = 'Stop'
$script:AssertPath = Join-Path $PSScriptRoot 'Assert-FleetReviewIntegrity.ps1'
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
$script:RunId = 'ri-selftest'
$script:ShaA = ('a' * 64); $script:ShaB = ('b' * 64); $script:ShaC = ('c' * 64)
$script:PlanSha = ('d' * 64); $script:ManSha = ''
$utf8 = New-Object System.Text.UTF8Encoding $false
$root = Join-Path ([IO.Path]::GetTempPath()) ('fleet-ri-' + [guid]::NewGuid().ToString('N'))
$leaseHome = Join-Path $root 'home'
$script:Fields = @('schema_version','receipt_type','run_id','task_id','lane_id','voice_id','review_role','requested_model','observed_model','model_evidence','emitter_id','input_packet_sha256','expected_lane_manifest_sha256','locked_plan_sha256','review_profile','charter_path','review_tier','result_path','charter_sha256','result_sha256','exit_code','outcome','refusal_reason','fallback_of','started_at','completed_at','sig_alg','key_id','signature')
New-Item -ItemType Directory -Force -Path $root | Out-Null
$script:OldProfile = $env:USERPROFILE; $env:USERPROFILE = $leaseHome
function Get-Sha256Text([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text))) -replace '-', '').ToLowerInvariant()) }
  finally { $sha.Dispose() }
}
function Get-Sha256File([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $fs = [IO.File]::OpenRead($Path); try { return (([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant()) } finally { $fs.Dispose() } }
  finally { $sha.Dispose() }
}
function Write-Utf8([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function New-ResultFile([string]$Dir, [string]$Name, [string]$Body) {
  $p = Join-Path $Dir ($Name + '.md'); Write-Utf8 $p $Body
  return [pscustomobject]@{ Path = $p; Sha = (Get-Sha256Text $Body) }
}
function New-TestLease {
  $secret = New-Object byte[] 32; for ($i = 0; $i -lt 32; $i++) { $secret[$i] = [byte](($i * 7 + 3) -band 0xFF) }
  $keyId = 'aa' + ('b' * 30); $leaseDir = Join-Path $leaseHome '.codex\fleet\run-leases'
  New-Item -ItemType Directory -Force -Path $leaseDir | Out-Null
  $now = [datetimeoffset]::UtcNow
  $rec = [ordered]@{ schema_version='2'; run_id=$script:RunId; owner_pid=$PID; started_at=$now.ToString('o'); heartbeat_at=$now.ToString('o'); expires_at=$now.AddHours(4).ToString('o'); receipt_hmac_key_id=$keyId; receipt_hmac_key_b64=[Convert]::ToBase64String($secret) }
  Write-Utf8 (Join-Path $leaseDir ($script:RunId + '.json')) ($rec | ConvertTo-Json -Compress)
  $script:Secret = $secret; $script:KeyId = $keyId
  $script:WrongSecret = New-Object byte[] 32; for ($i = 0; $i -lt 32; $i++) { $script:WrongSecret[$i] = [byte](255 - $i) }
}
function New-Receipt {
  param([string]$LaneId,[string]$TaskId='T-sec',[string]$Model='sol',[string]$Outcome='completed',[object]$FallbackOf=$null,[string]$RefusalReason=$null,[string]$PacketSha='',[string]$CharterSha='',[string]$PlanSha='',[string]$ManifestSha='',[string]$ResultPath='',[string]$ResultSha='',[string]$Started='2026-08-05T01:00:00.0000000Z',[string]$Completed='2026-08-05T01:05:00.0000000Z',[int]$ExitCode=0,[string]$VoiceId='',[string]$Observed='',[string]$RunIdOverride='',[string]$Role='security-review')
  if ([string]::IsNullOrWhiteSpace($PacketSha)) { $PacketSha = $script:ShaA }
  if ([string]::IsNullOrWhiteSpace($CharterSha)) { $CharterSha = $script:ShaB }
  if ([string]::IsNullOrWhiteSpace($PlanSha)) { $PlanSha = $script:PlanSha }
  if ([string]::IsNullOrWhiteSpace($ManifestSha)) { $ManifestSha = $script:ManSha }
  if ([string]::IsNullOrWhiteSpace($ResultSha)) { $ResultSha = $script:ShaC }
  if ([string]::IsNullOrWhiteSpace($VoiceId)) { $VoiceId = $Model }
  if ([string]::IsNullOrWhiteSpace($Observed)) { $Observed = $Model }
  if ([string]::IsNullOrWhiteSpace($ResultPath)) { $ResultPath = 'missing.md' }
  $rid = $script:RunId; if (-not [string]::IsNullOrWhiteSpace($RunIdOverride)) { $rid = $RunIdOverride }
  return [pscustomobject][ordered]@{ schema_version='2'; receipt_type='review_lane'; run_id=$rid; task_id=$TaskId; lane_id=$LaneId; voice_id=$VoiceId; review_role=$Role; requested_model=$Model; observed_model=$Observed; model_evidence='test-fixture'; emitter_id='test-emitter'; input_packet_sha256=$PacketSha; expected_lane_manifest_sha256=$ManifestSha; locked_plan_sha256=$PlanSha; review_profile='security-sensitive'; charter_path='charter.md'; review_tier='FULL'; result_path=$ResultPath; charter_sha256=$CharterSha; result_sha256=$ResultSha; exit_code=$ExitCode; outcome=$Outcome; refusal_reason=$RefusalReason; fallback_of=$FallbackOf; started_at=$Started; completed_at=$Completed; sig_alg='HMAC-SHA256'; key_id=$script:KeyId }
}
function Write-SignedReceipt([string]$Dir,[string]$Name,$Obj,[byte[]]$Secret=$null,[switch]$Unsigned) {
  if ($null -eq $Secret) { $Secret = $script:Secret }
  $sig = ''; if (-not $Unsigned) { $sig = New-FleetReceiptSignature -Receipt $Obj -ReceiptType 'review_lane' -RunSecret $Secret -KeyId $script:KeyId }
  $parts = New-Object System.Collections.ArrayList
  foreach ($k in $script:Fields) {
    if ($k -eq 'signature') {
      if ($Unsigned) { [void]$parts.Add('"signature":""') } else { [void]$parts.Add(('"{0}":{1}' -f $k, (ConvertTo-Json -InputObject $sig -Compress))) }
      continue
    }
    $v = $Obj.$k
    if ($null -eq $v) { [void]$parts.Add(('"{0}":null' -f $k)) } else { [void]$parts.Add(('"{0}":{1}' -f $k, (ConvertTo-Json -InputObject $v -Compress))) }
  }
  Write-Utf8 (Join-Path $Dir ($Name + '.json')) ('{' + ($parts -join ',') + '}')
}
function New-SpanLine([string]$Lane,[string]$Model,[string]$Status,[string]$ErrType=$null,[string]$ResponseModel='') {
  $err = if ([string]::IsNullOrEmpty($ErrType)) { 'null' } else { '"' + $ErrType + '"' }
  $respM = $Model; if (-not [string]::IsNullOrWhiteSpace($ResponseModel)) { $respM = $ResponseModel }
  return ('{"schema_version":"1","run_id":' + (ConvertTo-Json -InputObject $script:RunId -Compress) + ',"lane_id":' + (ConvertTo-Json -InputObject $Lane -Compress) +
    ',"phase":"review","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"fleet","gen_ai.provider.name":"x","gen_ai.request.model":' +
    (ConvertTo-Json -InputObject $Model -Compress) + ',"gen_ai.response.model":' + (ConvertTo-Json -InputObject $respM -Compress) +
    ',"gen_ai.usage.input_tokens":1,"gen_ai.usage.output_tokens":1,"gen_ai.usage.cache_read.input_tokens":0,"tool_calls":0,"inference_calls":1,"duration_s":1.0,"first_result_s":0.5,"status":' +
    (ConvertTo-Json -InputObject $Status -Compress) + ',"error.type":' + $err + ',"handoff":null,"artifacts":null}')
}
function Write-Prov([string]$d,[string[]]$BaseLanes,[object[]]$Spans) {
  $aux = Join-Path (Split-Path -Parent $d) ((Split-Path -Leaf $d) + '-aux')
  New-Item -ItemType Directory -Force -Path $aux | Out-Null
  $script:CaseBase = Join-Path $aux '_base.json'
  $parts = @(); foreach ($x in $BaseLanes) { $parts += (ConvertTo-Json -InputObject $x -Compress) }
  Write-Utf8 $script:CaseBase ('{"run_id":' + (ConvertTo-Json -InputObject $script:RunId -Compress) + ',"expected_lanes":[' + ($parts -join ',') + ']}')
  $script:ManSha = Get-Sha256File $script:CaseBase
  $script:CaseSpan = Join-Path $aux '_spans.jsonl'
  $lines = New-Object System.Collections.ArrayList
  foreach ($sp in @($Spans)) {
    $et = $null; if ($sp.ContainsKey('E')) { $et = $sp.E }
    $rm = ''; if ($sp.ContainsKey('RM')) { $rm = $sp.RM }
    [void]$lines.Add((New-SpanLine $sp.L $sp.M $sp.S $et $rm))
  }
  Write-Utf8 $script:CaseSpan (($lines -join "`n"))
}
function Write-RefusedSol([string]$d) {
  $rr = New-ResultFile $d 'sol-refused' $script:RefuseBody
  Write-SignedReceipt $d 'sol' (New-Receipt -LaneId 'v-sol-security' -Model 'sol' -Outcome 'refused' -RefusalReason 'policy_decline' -ResultPath $rr.Path -ResultSha $rr.Sha -Completed '2026-08-05T01:05:00.0000000Z')
}
function Write-Failover([string]$d,[string]$name,[string]$model,[string]$lane,[string]$body,[string]$started,[string]$TaskId='T-sec',[string]$PacketSha='',[string]$CharterSha='',[string]$PlanSha='',[string]$FallbackOf='v-sol-security',[int]$ExitCode=0,[string]$ResultShaOverride='',[string]$Observed='') {
  $r = New-ResultFile $d $name $body; $sha = $r.Sha
  if (-not [string]::IsNullOrWhiteSpace($ResultShaOverride)) { $sha = $ResultShaOverride }
  Write-SignedReceipt $d $name (New-Receipt -LaneId $lane -Model $model -Outcome 'completed' -TaskId $TaskId -FallbackOf $FallbackOf -PacketSha $PacketSha -CharterSha $CharterSha -PlanSha $PlanSha -ResultPath $r.Path -ResultSha $sha -Started $started -Completed '2026-08-05T01:10:00.0000000Z' -ExitCode $ExitCode -Observed $Observed)
}
function Write-HostedOk([string]$d,[string]$lane,[string]$model,[string]$name) {
  $br = New-ResultFile $d $name $script:BlockBody
  Write-SignedReceipt $d $name (New-Receipt -LaneId $lane -Model $model -Outcome 'completed' -ResultPath $br.Path -ResultSha $br.Sha)
}
function Invoke-Gate([string]$ReceiptDir,[string]$BaseManifest='',[string]$OutputManifest='',[string]$SpanLedger='',[string]$ExpectedPacketSha256='',[string]$LockedPlan='',[switch]$OmitBase,[switch]$OmitSpan) {
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:AssertPath,'-ReceiptDir',$ReceiptDir,'-RunId',$script:RunId,'-Mode','text')
  if (-not $OmitBase) { if ([string]::IsNullOrWhiteSpace($BaseManifest)) { $BaseManifest = $script:CaseBase }; if ($BaseManifest) { $args += @('-BaseManifest',$BaseManifest) } }
  if (-not $OmitSpan) { if ([string]::IsNullOrWhiteSpace($SpanLedger)) { $SpanLedger = $script:CaseSpan }; if ($SpanLedger) { $args += @('-SpanLedger',$SpanLedger) } }
  if ($OutputManifest) { $args += @('-OutputManifest',$OutputManifest) }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedPacketSha256)) { $args += @('-ExpectedPacketSha256',$ExpectedPacketSha256) }
  if (-not [string]::IsNullOrWhiteSpace($LockedPlan)) { $args += @('-LockedPlan',$LockedPlan) }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = ($args | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' '
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $leaseHome
  $p = [Diagnostics.Process]::Start($psi)
  $raw = $p.StandardOutput.ReadToEnd() + "`n" + $p.StandardError.ReadToEnd(); $p.WaitForExit()
  $sum = ''; foreach ($line in ($raw -split "`n")) { $t = $line.Trim(); if ($t -like 'review-integrity:*') { $sum = $t; break } }
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Raw = $raw; Summary = $sum }
}
function Assert-True([bool]$c,[string]$m) { if (-not $c) { throw $m } }
function Get-Verdict([string]$Sum) { if ($Sum -match 'verdict: (\S+)') { return $Matches[1] }; throw "bad summary: $Sum" }
function Sp-RefusedSol { return @{ L='v-sol-security'; M='sol'; S='error'; E='model_refusal' } }
function Sp-Fb([string]$lane,[string]$model) { return @{ L=$lane; M=$model; S='ok' } }
function Sp-Ok([string]$lane,[string]$model) { return @{ L=$lane; M=$model; S='ok' } }
$script:BlockBody = "## Adversarial review`nFinding: authz gap.`nVERDICT: BLOCK"
$script:RefuseBody = 'I cannot help with that request.'
$script:OkBody = "## Findings`n- none material`nVERDICT: CLEAR"
$t0 = '2026-08-05T01:00:00.0000000Z'; $t6 = '2026-08-05T01:06:00.0000000Z'; $base1 = @('v-sol-security')
New-TestLease

$cases = @(
  @{ Name='refused-zero-failover-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol)); Write-RefusedSol $d } }
  @{ Name='refused-glm-only-ok'; ExpectExit=0; ExpectVerdict='ok'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 } }
  @{ Name='refused-kimi-glm-fail-grok-ok'; ExpectExit=0; ExpectVerdict='ok'; Build={ param($d)
      Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-grok-security-fb' 'grok')); Write-RefusedSol $d
      Write-Failover $d 'kimi' 'kimi' 'v-kimi-security-fb' $script:RefuseBody $t6
      Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:RefuseBody $t6
      Write-Failover $d 'grok' 'grok' 'v-grok-security-fb' $script:OkBody '2026-08-05T01:07:00.0000000Z' } }
  @{ Name='failover-result-is-refusal-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:RefuseBody $t6 } }
  @{ Name='wrong-task-id-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -TaskId 'T-OTHER' } }
  @{ Name='wrong-charter-sha-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -CharterSha $script:ShaA } }
  @{ Name='wrong-packet-sha-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -PacketSha $script:ShaB } }
  @{ Name='wrong-plan-sha-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -PlanSha $script:ShaA } }
  @{ Name='started-before-refused-completed-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t0 } }
  @{ Name='fallback-of-nonexistent-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-Fb 'v-glm-security-fb' 'glm')); Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -FallbackOf 'v-sol-MISSING' } }
  @{ Name='hosted-BLOCK-no-failover-ok'; ExpectExit=0; ExpectVerdict='ok'; Build={ param($d) Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol')); Write-HostedOk $d 'v-sol-security' 'sol' 'sol' } }
  @{ Name='orphan-failover-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol'),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-HostedOk $d 'v-sol-security' 'sol' 'sol'; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -FallbackOf 'v-ghost-hosted' } }
  @{ Name='success-emits-effective-manifest'; ExpectExit=0; ExpectVerdict='ok'; CheckManifest=$true; Build={ param($d)
      $side = Join-Path (Split-Path -Parent $d) 'manifests-success'; New-Item -ItemType Directory -Force -Path $side | Out-Null
      $script:CaseBase = Join-Path $side 'base-manifest.json'
      Write-Utf8 $script:CaseBase '{"run_id":"ri-selftest","expected_lanes":["v-sol-security","v-terra-security"]}'
      $script:ManSha = Get-Sha256File $script:CaseBase; $script:CaseOut = Join-Path $side 'effective-manifest.json'
      $script:CaseSpan = Join-Path $side '_spans.jsonl'
      Write-Utf8 $script:CaseSpan ((@((New-SpanLine 'v-sol-security' 'sol' 'error' 'model_refusal'),(New-SpanLine 'v-glm-security-fb' 'glm' 'ok'),(New-SpanLine 'v-terra-security' 'terra' 'ok')) -join "`n"))
      Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6; Write-HostedOk $d 'v-terra-security' 'terra' 'terra' } }
  @{ Name='label-spoof-completed-refusal-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d)
      Write-Prov $d $base1 @((Sp-RefusedSol)); $rr = New-ResultFile $d 'sol-spoof' $script:RefuseBody
      Write-SignedReceipt $d 'sol' (New-Receipt -LaneId 'v-sol-security' -Model 'sol' -Outcome 'completed' -ResultPath $rr.Path -ResultSha $rr.Sha) } }
  @{ Name='failover-hash-mismatch-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -ResultShaOverride $script:ShaC } }
  @{ Name='failover-exit-nonzero-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -ExitCode 1 } }
  @{ Name='model-disagree-glm-sol-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -Observed 'sol' } }
  @{ Name='missing-BaseManifest-usage'; ExpectExit=2; ExpectVerdict='FAILED'; OmitBase=$true; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol)); Write-RefusedSol $d } }
  @{ Name='missing-SpanLedger-usage'; ExpectExit=2; ExpectVerdict='FAILED'; OmitSpan=$true; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol)); Write-RefusedSol $d } }
  @{ Name='parent-not-refused-failover-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol'),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-HostedOk $d 'v-sol-security' 'sol' 'sol'; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 -FallbackOf 'v-sol-security' } }
  @{ Name='happy-path-mandatory-span-base-ok'; ExpectExit=0; ExpectVerdict='ok'; Build={ param($d)
      Write-Prov $d @('v-sol-security','v-terra-security') @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm'),(Sp-Ok 'v-terra-security' 'terra'))
      Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6; Write-HostedOk $d 'v-terra-security' 'terra' 'terra' } }
  @{ Name='base-lane-span-no-receipt-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d)
      Write-Prov $d @('v-sol-security','v-terra-security') @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm'),(Sp-Ok 'v-terra-security' 'terra'))
      Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 } }
  @{ Name='model-refusal-span-no-receipt-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d) Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol'),@{ L='v-ghost-sec'; M='sol'; S='error'; E='model_refusal' }); Write-HostedOk $d 'v-sol-security' 'sol' 'sol' } }
  @{ Name='span-request-glm-response-sol-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d)
      Write-Prov $d @('v-glm-security') @(@{ L='v-glm-security'; M='glm'; S='ok'; RM='sol' })
      $br = New-ResultFile $d 'glm-ok' $script:OkBody
      Write-SignedReceipt $d 'glm' (New-Receipt -LaneId 'v-glm-security' -Model 'glm' -Outcome 'completed' -ResultPath $br.Path -ResultSha $br.Sha) } }
  @{ Name='unsigned-receipt-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d)
      Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol')); $br = New-ResultFile $d 'sol' $script:BlockBody
      Write-SignedReceipt $d 'sol' (New-Receipt -LaneId 'v-sol-security' -Model 'sol' -Outcome 'completed' -ResultPath $br.Path -ResultSha $br.Sha) -Unsigned } }
  @{ Name='wrong-key-signature-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d)
      Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol')); $br = New-ResultFile $d 'sol' $script:BlockBody
      Write-SignedReceipt $d 'sol' (New-Receipt -LaneId 'v-sol-security' -Model 'sol' -Outcome 'completed' -ResultPath $br.Path -ResultSha $br.Sha) -Secret $script:WrongSecret } }
  @{ Name='wrong-base-manifest-hash-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d)
      Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol')); $br = New-ResultFile $d 'sol' $script:BlockBody
      Write-SignedReceipt $d 'sol' (New-Receipt -LaneId 'v-sol-security' -Model 'sol' -Outcome 'completed' -ResultPath $br.Path -ResultSha $br.Sha -ManifestSha $script:ShaA) } }
  @{ Name='wrong-signed-run-id-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d)
      Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol')); $br = New-ResultFile $d 'sol' $script:BlockBody
      Write-SignedReceipt $d 'sol' (New-Receipt -LaneId 'v-sol-security' -Model 'sol' -Outcome 'completed' -ResultPath $br.Path -ResultSha $br.Sha -RunIdOverride 'ri-OTHER') } }
  @{ Name='lane-id-not-in-base-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d)
      Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol'),(Sp-Ok 'v-spoof' 'sol')); Write-HostedOk $d 'v-sol-security' 'sol' 'sol'
      $br = New-ResultFile $d 'spoof' $script:BlockBody
      Write-SignedReceipt $d 'spoof' (New-Receipt -LaneId 'v-spoof' -Model 'sol' -Outcome 'completed' -ResultPath $br.Path -ResultSha $br.Sha) } }
  @{ Name='valid-signed-hosted-failover-ok'; ExpectExit=0; ExpectVerdict='ok'; Build={ param($d) Write-Prov $d $base1 @((Sp-RefusedSol),(Sp-Fb 'v-glm-security-fb' 'glm')); Write-RefusedSol $d; Write-Failover $d 'glm' 'glm' 'v-glm-security-fb' $script:OkBody $t6 } }
  @{ Name='expected-packet-mismatch-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; ExpectPacket=$script:ShaB; Build={ param($d)
      Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol')); Write-HostedOk $d 'v-sol-security' 'sol' 'sol' } }
  @{ Name='expected-packet-match-ok'; ExpectExit=0; ExpectVerdict='ok'; ExpectPacket=$script:ShaA; Build={ param($d)
      Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol')); Write-HostedOk $d 'v-sol-security' 'sol' 'sol' } }
  @{ Name='locked-plan-mismatch-FAILED'; ExpectExit=1; ExpectVerdict='FAILED'; Build={ param($d)
      Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol')); Write-HostedOk $d 'v-sol-security' 'sol' 'sol'
      $script:CasePlan = Join-Path (Split-Path -Parent $d) 'locked-plan-bad.md'
      Write-Utf8 $script:CasePlan "# locked plan`nreview_profile: security-sensitive`n" } }
  @{ Name='locked-plan-match-ok'; ExpectExit=0; ExpectVerdict='ok'; Build={ param($d)
      $script:CasePlan = Join-Path (Split-Path -Parent $d) 'locked-plan-ok.md'
      Write-Utf8 $script:CasePlan "# locked plan bind`nreview_profile: security-sensitive`n"
      $planSha = Get-Sha256File $script:CasePlan
      Write-Prov $d $base1 @((Sp-Ok 'v-sol-security' 'sol'))
      $br = New-ResultFile $d 'sol' $script:BlockBody
      Write-SignedReceipt $d 'sol' (New-Receipt -LaneId 'v-sol-security' -Model 'sol' -Outcome 'completed' -ResultPath $br.Path -ResultSha $br.Sha -PlanSha $planSha) } }
)

$total = $cases.Count; $i = 0
try {
  foreach ($c in $cases) {
    $i++; $caseDir = Join-Path $root ('case-' + $i.ToString('00') + '-' + $c.Name)
    New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
    $script:CaseBase = ''; $script:CaseOut = ''; $script:CaseSpan = ''; $script:CasePlan = ''; $script:ManSha = $script:ShaA
    & $c.Build $caseDir
    $baseArg = $script:CaseBase; $outArg = ''; $spanArg = $script:CaseSpan; $pktArg = ''; $planArg = $script:CasePlan
    if ($c.ContainsKey('CheckManifest') -and $c.CheckManifest) { $outArg = $script:CaseOut }
    if ($c.ContainsKey('ExpectPacket')) { $pktArg = [string]$c.ExpectPacket }
    $omitB = ($c.ContainsKey('OmitBase') -and $c.OmitBase); $omitS = ($c.ContainsKey('OmitSpan') -and $c.OmitSpan)
    if ($omitB) { $run = Invoke-Gate $caseDir -SpanLedger $spanArg -ExpectedPacketSha256 $pktArg -LockedPlan $planArg -OmitBase }
    elseif ($omitS) { $run = Invoke-Gate $caseDir -BaseManifest $baseArg -ExpectedPacketSha256 $pktArg -LockedPlan $planArg -OmitSpan }
    else { $run = Invoke-Gate $caseDir -BaseManifest $baseArg -OutputManifest $outArg -SpanLedger $spanArg -ExpectedPacketSha256 $pktArg -LockedPlan $planArg }
    Assert-True ($run.ExitCode -eq $c.ExpectExit) ("$($c.Name): exit $($run.ExitCode) want $($c.ExpectExit); $($run.Raw)")
    if ($c.ExpectExit -ne 2) { Assert-True ((Get-Verdict $run.Summary) -eq $c.ExpectVerdict) ("$($c.Name): verdict want $($c.ExpectVerdict); $($run.Summary)") }
    else { Assert-True ($run.Summary -like 'review-integrity:*' -or $run.Raw -match 'usage:') ("$($c.Name): usage signal; $($run.Raw)") }
    if ($c.ContainsKey('CheckManifest') -and $c.CheckManifest) {
      Assert-True (Test-Path -LiteralPath $script:CaseOut -PathType Leaf) "$($c.Name): effective missing"
      $man = [IO.File]::ReadAllText($script:CaseOut, $utf8) | ConvertFrom-Json
      $lanes = @($man.expected_lanes | ForEach-Object { [string]$_ })
      foreach ($need in @('v-sol-security','v-terra-security','v-glm-security-fb')) { Assert-True ($lanes -contains $need) "$($c.Name): missing $need in $lanes" }
      Assert-True (([string]$man.run_id -eq $script:RunId) -and (Test-Path -LiteralPath $script:CaseBase -PathType Leaf)) "$($c.Name): run/base"
    }
  }
  Write-Output ("selftest: PASS {0}/{0}" -f $total); exit 0
} catch {
  Write-Output ("selftest: FAIL {0}/{1} - {2}" -f $i, $total, $_.Exception.Message); exit 1
} finally {
  $env:USERPROFILE = $script:OldProfile
  try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
