# Integration: signed self-tests + mutation proofs. Fail-close on unsigned/tampered.
# contract: N sub-tests PASS | mutation-proofs: M/M | verdict: ok|FAILED  (PS 5.1)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
$root = Join-Path $env:TEMP ('fleet-contract-' + [guid]::NewGuid().ToString('N'))
$leaseHome = Join-Path $root 'home'; $oldProfile = $env:USERPROFILE
$subPass = 0; $subTotal = 8; $mutOk = 0; $mutTotal = 4; $failed = $false
$assertRi = Join-Path $PSScriptRoot 'Assert-FleetReviewIntegrity.ps1'
$assertAdv = Join-Path $PSScriptRoot 'Assert-FleetAdversarialReview.ps1'
$assertMr = Join-Path $PSScriptRoot 'Assert-FleetMergeReadiness.ps1'
$shaA = ('a' * 64); $shaB = ('b' * 64); $shaC = ('c' * 64); $shaPlan = ('d' * 64)
$ts0 = '2026-08-05T01:00:00.0000000Z'; $ts1 = '2026-08-05T01:05:00.0000000Z'
$ts6 = '2026-08-05T01:06:00.0000000Z'; $ts10 = '2026-08-05T01:10:00.0000000Z'
$pad = ('evidence detail line for substantive review body. ' * 6)
$voiceBody = "## Adversarial review`n### Findings`n- scripts/x.ps1:10 HIGH - problem found. Fix required.`n$pad`n"
$okBody = "## Findings`n- none material`nVERDICT: CLEAR"; $refuseBody = 'I cannot help with that request.'
$rlF = @('schema_version','receipt_type','run_id','task_id','lane_id','voice_id','review_role','requested_model','observed_model','model_evidence','emitter_id','input_packet_sha256','expected_lane_manifest_sha256','locked_plan_sha256','review_profile','charter_path','review_tier','result_path','charter_sha256','result_sha256','exit_code','outcome','refusal_reason','fallback_of','started_at','completed_at','sig_alg','key_id','signature')
$msF = @('schema_version','receipt_type','run_id','task_id','lane_id','stage','required','status','requested_model','observed_model','model_evidence','effort','input_packet_sha256','emitter_id','locked_plan_sha256','stage_set_sha256','review_tier','review_profile','charter_path','result_path','result_sha256','charter_sha256','exit_code','outcome','fallback_of','failure_category','findings','evidence_refs','output_artifacts','started_at','completed_at','model','sig_alg','signature')
$script:RunId = 'contract-mut'; $script:Secret = $null; $script:KeyId = ''; $script:ManSha = $shaA

function Write-Utf8([string]$Path, [string]$Text) {
  $p = Split-Path -Parent $Path
  if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Get-ShaHex([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}
function Get-Sha256Text([string]$Text) { return (Get-ShaHex $utf8.GetBytes($Text)) }
function Get-Sha256File([string]$Path) { return (Get-ShaHex ([IO.File]::ReadAllBytes($Path))) }
function Invoke-Child([string]$Script, [string[]]$ExtraArgs = @()) {
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + @($ExtraArgs)
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @argList 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = $code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}
function Get-SelfTestKk([string]$Raw) {
  if ($Raw -match 'selftest:\s*PASS\s+(\d+)/(\d+)') { return [pscustomobject]@{ A = [int]$Matches[1]; B = [int]$Matches[2] } }
  return $null
}
function Get-VerdictToken([string]$Raw, [string]$Kind = 'verdict') {
  if ($Kind -eq 'merge' -and $Raw -match 'merge-readiness:\s+(\S+)') { return $Matches[1] }
  if ($Raw -match 'verdict:\s*(\S+)') { return $Matches[1] }
  return ''
}
function Install-Lease {
  $script:Secret = New-Object byte[] 32
  for ($i = 0; $i -lt 32; $i++) { $script:Secret[$i] = [byte](($i * 11 + 5) -band 0xFF) }
  $script:KeyId = 'cc' + ('d' * 30)
  $dir = Join-Path $leaseHome '.codex\fleet\run-leases'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $now = [datetimeoffset]::UtcNow
  $rec = [ordered]@{ schema_version='2'; run_id=$script:RunId; owner_pid=$PID; started_at=$now.ToString('o'); heartbeat_at=$now.ToString('o'); expires_at=$now.AddHours(4).ToString('o'); receipt_hmac_key_id=$script:KeyId; receipt_hmac_key_b64=[Convert]::ToBase64String($script:Secret) }
  Write-Utf8 (Join-Path $dir ($script:RunId + '.json')) ($rec | ConvertTo-Json -Compress)
}
function Write-OrderedJson([string]$Path, $Obj, [string[]]$Fields, [string]$Sig) {
  $parts = New-Object System.Collections.ArrayList
  foreach ($k in $Fields) {
    if ($k -eq 'signature') { [void]$parts.Add(('"{0}":{1}' -f $k, (ConvertTo-Json -InputObject $Sig -Compress))); continue }
    $v = $Obj.$k
    if ($null -eq $v) {
      if ($k -in @('findings','evidence_refs','output_artifacts')) { [void]$parts.Add(('"{0}":[]' -f $k)) } else { [void]$parts.Add(('"{0}":null' -f $k)) }
      continue
    }
    if ($k -in @('findings','evidence_refs','output_artifacts')) {
      $els = New-Object System.Collections.ArrayList
      foreach ($item in @($v)) { [void]$els.Add(($item | ConvertTo-Json -Depth 4 -Compress)) }
      [void]$parts.Add(('"{0}":[{1}]' -f $k, ($els -join ','))); continue
    }
    [void]$parts.Add(('"{0}":{1}' -f $k, (ConvertTo-Json -InputObject $v -Compress)))
  }
  Write-Utf8 $Path ('{' + ($parts -join ',') + '}')
}
function New-RlObj {
  param([string]$Lane,[string]$Model,[string]$Outcome='completed',[string]$Role='security-review',[string]$ResultPath,[string]$ResultSha,[string]$Started=$ts0,[string]$Completed=$ts1,[object]$FallbackOf=$null,[object]$Refusal=$null,[string]$Profile='security-sensitive',[string]$Tier='FULL',[string]$Man='',[string]$PlanSha='')
  if ([string]::IsNullOrWhiteSpace($Man)) { $Man = $script:ManSha }
  if ([string]::IsNullOrWhiteSpace($PlanSha)) { $PlanSha = $script:BoundPlanSha; if ([string]::IsNullOrWhiteSpace($PlanSha)) { $PlanSha = $shaPlan } }
  return [pscustomobject][ordered]@{ schema_version='2'; receipt_type='review_lane'; run_id=$script:RunId; task_id='T-sec'; lane_id=$Lane; voice_id=$Model; review_role=$Role; requested_model=$Model; observed_model=$Model; model_evidence='test-fixture'; emitter_id='test-emitter'; input_packet_sha256=$shaA; expected_lane_manifest_sha256=$Man; locked_plan_sha256=$PlanSha; review_profile=$Profile; charter_path='charter.md'; review_tier=$Tier; result_path=$ResultPath; charter_sha256=$shaB; result_sha256=$ResultSha; exit_code=0; outcome=$Outcome; refusal_reason=$Refusal; fallback_of=$FallbackOf; started_at=$Started; completed_at=$Completed; sig_alg='HMAC-SHA256'; key_id=$script:KeyId }
}
function Write-SignedRl([string]$Path, $Obj, [byte[]]$Secret = $null) {
  if ($null -eq $Secret) { $Secret = $script:Secret }
  Write-OrderedJson $Path $Obj $rlF (New-FleetReceiptSignature -Receipt $Obj -ReceiptType 'review_lane' -RunSecret $Secret -KeyId $script:KeyId)
}
function New-MsObj([string]$Stage, [string]$Packet) {
  $ss = Get-Sha256Text "change-map`nsynthesis`nadversarial-challenge`ntriage"
  $rp = $script:ResultFixturePath; $rsha = $script:ResultFixtureSha
  if ([string]::IsNullOrWhiteSpace($rp)) { $rp = 'C:\tmp\result.md' }; if ([string]::IsNullOrWhiteSpace($rsha)) { $rsha = $shaC }
  return [pscustomobject][ordered]@{ schema_version='2'; receipt_type='merge_stage'; run_id=$script:RunId; task_id='task-1'; lane_id='lane-1'; stage=$Stage; required=$true; status='passed'; requested_model='test-model'; observed_model='test-model'; model_evidence='test-evidence'; effort='high'; input_packet_sha256=$Packet; emitter_id='test-emitter'; locked_plan_sha256=$shaPlan; stage_set_sha256=$ss; review_tier='STANDARD'; review_profile='standard'; charter_path='C:\tmp\charter.md'; result_path=$rp; result_sha256=$rsha; charter_sha256=$shaB; exit_code=0; outcome='completed'; fallback_of=$null; failure_category=$null; findings=@(); evidence_refs=@('trigger:ok'); output_artifacts=@(); started_at=$ts0; completed_at=$ts1; model='test-model'; sig_alg='HMAC-SHA256' }
}
function Write-SignedMs([string]$Path, $Obj) {
  Write-OrderedJson $Path $Obj $msF (New-FleetReceiptSignature -Receipt $Obj -ReceiptType 'merge_stage' -RunSecret $script:Secret -KeyId $script:KeyId)
}
function New-Span([string]$Lane, [string]$Model, [string]$Status, [string]$ErrType = $null) {
  $err = if ([string]::IsNullOrEmpty($ErrType)) { 'null' } else { '"' + $ErrType + '"' }
  return ('{"schema_version":"1","run_id":' + (ConvertTo-Json -InputObject $script:RunId -Compress) + ',"lane_id":' + (ConvertTo-Json -InputObject $Lane -Compress) + ',"phase":"review","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"fleet","gen_ai.provider.name":"x","gen_ai.request.model":' + (ConvertTo-Json -InputObject $Model -Compress) + ',"gen_ai.response.model":' + (ConvertTo-Json -InputObject $Model -Compress) + ',"gen_ai.usage.input_tokens":1,"gen_ai.usage.output_tokens":1,"gen_ai.usage.cache_read.input_tokens":0,"tool_calls":0,"inference_calls":1,"duration_s":1.0,"first_result_s":0.5,"status":' + (ConvertTo-Json -InputObject $Status -Compress) + ',"error.type":' + $err + ',"handoff":null,"artifacts":null}')
}
function Invoke-Integrity([string]$Dir, [string]$Base, [string]$Span) {
  return (Invoke-Child -Script $assertRi -ExtraArgs @('-ReceiptDir',$Dir,'-RunId',$script:RunId,'-Mode','text','-BaseManifest',$Base,'-SpanLedger',$Span))
}
function Invoke-Adv([string]$Repo, [string]$BaseRef, [string]$ReviewDir, [string]$ReceiptDir) {
  return (Invoke-Child -Script $assertAdv -ExtraArgs @('-Repo',$Repo,'-BaseRef',$BaseRef,'-RunId',$script:RunId,'-ReceiptDir',$ReceiptDir,'-PacketManifest',(Join-Path $ReviewDir 'packet-manifest.json'),'-ReviewDir',$ReviewDir,'-Tier','FULL','-ReviewProfile','security-sensitive','-LockedPlan',(Join-Path $Repo 'locked-plan.md'),'-Mode','text'))
}
function Invoke-Merge([string]$Dir, [string]$Packet) {
  return (Invoke-Child -Script $assertMr -ExtraArgs @('-ReceiptDir',$Dir,'-RunId',$script:RunId,'-ExpectedPacketSha256',$Packet,'-RequiredStages','change-map,synthesis,adversarial-challenge,triage'))
}
function New-AdvShip([string]$Name) {
  $repo = Join-Path $root $Name
  New-Item -ItemType Directory -Force -Path $repo | Out-Null
  & git -C $repo init -q | Out-Null
  & git -C $repo -c user.email=fleet-test@example.invalid -c user.name=fleet-test commit --allow-empty -q -m seed | Out-Null
  $base = (& git -C $repo rev-parse HEAD).Trim()
  Write-Utf8 (Join-Path $repo 'ship.txt') "shipped`n"
  & git -C $repo add -- ship.txt | Out-Null
  & git -C $repo -c user.email=fleet-test@example.invalid -c user.name=fleet-test commit -q -m ship | Out-Null
  Write-Utf8 (Join-Path $repo 'locked-plan.md') "# locked plan`nreview_profile: security-sensitive`n"
  $rd = Join-Path $repo '.fleet-review'; $rc = Join-Path $repo '.fleet-receipts'
  New-Item -ItemType Directory -Force -Path $rd, $rc | Out-Null
  $final = Join-Path $rd 'final.diff'
  $argLine = '-C "' + ($repo.Replace('"', '\"')) + '" --no-pager diff "' + ($base.Replace('"', '\"')) + '" HEAD'
  $proc = New-Object System.Diagnostics.Process; $psi = $proc.StartInfo
  $psi.FileName = 'git'; $psi.Arguments = $argLine; $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  [void]$proc.Start(); $ms = New-Object System.IO.MemoryStream
  try { $proc.StandardOutput.BaseStream.CopyTo($ms); $err = $proc.StandardError.ReadToEnd(); $proc.WaitForExit(); if ($proc.ExitCode -ne 0) { throw "git diff failed: $err" }; [IO.File]::WriteAllBytes($final, $ms.ToArray()) }
  finally { $ms.Dispose(); $proc.Dispose() }
  $bytes = [IO.File]::ReadAllBytes($final)
  $man = [ordered]@{ schema_version='1'; review_risk='mechanical'; packet_sha256=$shaA; artifacts=@(@{ name='final.diff'; bytes=[int64]$bytes.Length; sha256=(Get-ShaHex $bytes) }) }
  Write-Utf8 (Join-Path $rd 'packet-manifest.json') ($man | ConvertTo-Json -Compress -Depth 5)
  return [pscustomobject]@{ Repo=$repo; Base=$base; ReviewDir=$rd; ReceiptDir=$rc }
}
function Write-AdvVoices($Ship, [string[]]$Names, [hashtable]$Models, [hashtable]$Roles) {
  # L3: hash LockedPlan before signing so locked_plan_sha256 matches file.
  $lp = Join-Path $Ship.Repo 'locked-plan.md'
  if (Test-Path -LiteralPath $lp -PathType Leaf) { $script:BoundPlanSha = Get-Sha256File $lp } else { $script:BoundPlanSha = $shaPlan }
  $i = 0
  foreach ($n in $Names) {
    $i++; $vp = Join-Path $Ship.ReviewDir $n; Write-Utf8 $vp $voiceBody
    $obj = New-RlObj -Lane ([IO.Path]::GetFileNameWithoutExtension($n)) -Model $Models[$n] -Role $Roles[$n] -ResultPath ([IO.Path]::GetFullPath($vp)) -ResultSha (Get-Sha256Text $voiceBody) -Man $shaA -PlanSha $script:BoundPlanSha
    Write-SignedRl (Join-Path $Ship.ReceiptDir ("r$i.json")) $obj
  }
}
function Write-RiBase([string]$Aux, [string[]]$Spans) {
  $basePath = Join-Path $Aux '_base.json'; $spanPath = Join-Path $Aux '_spans.jsonl'
  Write-Utf8 $basePath ('{"run_id":' + (ConvertTo-Json -InputObject $script:RunId -Compress) + ',"expected_lanes":["v-sol-security"]}')
  $script:ManSha = Get-Sha256File $basePath
  Write-Utf8 $spanPath (($Spans -join "`n"))
  return [pscustomobject]@{ Base=$basePath; Span=$spanPath }
}

$subs = @(
  @{ N='Test-FleetReceiptSignature'; S=(Join-Path $PSScriptRoot 'Test-FleetReceiptSignature.ps1'); E=@() }
  @{ N='Test-FleetRunLease'; S=(Join-Path $PSScriptRoot 'Test-FleetRunLease.ps1'); E=@() }
  @{ N='Test-FleetSignedLane'; S=(Join-Path $PSScriptRoot 'Test-FleetSignedLane.ps1'); E=@() }
  @{ N='Test-FleetLaneRefusal'; S=(Join-Path $PSScriptRoot 'Test-FleetLaneRefusal.ps1'); E=@() }
  @{ N='Test-FleetAdversarialReview'; S=(Join-Path $PSScriptRoot 'Test-FleetAdversarialReview.ps1'); E=@() }
  @{ N='Test-NewFleetMergeReadinessReceipt'; S=(Join-Path $PSScriptRoot 'Test-NewFleetMergeReadinessReceipt.ps1'); E=@() }
  @{ N='Assert-FleetMergeReadiness-SelfTest'; S=$assertMr; E=@('-SelfTest') }
  @{ N='Test-FleetReviewIntegrity'; S=(Join-Path $PSScriptRoot 'Test-FleetReviewIntegrity.ps1'); E=@() }
)

try {
  New-Item -ItemType Directory -Force -Path $root, $leaseHome | Out-Null
  $env:USERPROFILE = $leaseHome
  Install-Lease
  # M2: real merge result fixture (path exists + sha matches signed result_sha256).
  $script:ResultFixturePath = Join-Path $root 'merge-result.md'
  Write-Utf8 $script:ResultFixturePath "fleet-contract-merge-result`n"
  $script:ResultFixtureSha = Get-Sha256File $script:ResultFixturePath
  $script:BoundPlanSha = $shaPlan

  foreach ($s in $subs) {
    if (-not (Test-Path -LiteralPath $s.S -PathType Leaf)) { $failed = $true; Write-Output ("subtest FAIL {0}: missing" -f $s.N); continue }
    $run = Invoke-Child -Script $s.S -ExtraArgs $s.E; $kk = Get-SelfTestKk $run.Raw
    if ($run.ExitCode -eq 0 -and $null -ne $kk -and $kk.A -eq $kk.B -and $kk.A -gt 0) {
      $subPass++; Write-Output ("subtest PASS {0}: selftest: PASS {1}/{2}" -f $s.N, $kk.A, $kk.B)
    } else {
      $failed = $true; $d = 'no selftest: PASS k/k'; if ($null -ne $kk) { $d = ("selftest line {0}/{1}" -f $kk.A, $kk.B) }
      Write-Output ("subtest FAIL {0}: exit={1} {2}" -f $s.N, $run.ExitCode, $d)
    }
  }

  # A: integrity valid signed hosted+failover ok; delete failover => FAILED
  try {
    $riDir = Join-Path $root 'mut-a'; $aux = Join-Path $root 'mut-a-aux'
    New-Item -ItemType Directory -Force -Path $riDir, $aux | Out-Null
    $prov = Write-RiBase $aux @((New-Span 'v-sol-security' 'sol' 'error' 'model_refusal'), (New-Span 'v-glm-security-fb' 'glm' 'ok'))
    $rp = [IO.Path]::GetFullPath((Join-Path $riDir 'sol.md')); Write-Utf8 $rp $refuseBody
    $gp = [IO.Path]::GetFullPath((Join-Path $riDir 'glm.md')); Write-Utf8 $gp $okBody
    Write-SignedRl (Join-Path $riDir 'sol.json') (New-RlObj -Lane 'v-sol-security' -Model 'sol' -Outcome 'refused' -ResultPath $rp -ResultSha (Get-Sha256Text $refuseBody) -Completed $ts1 -Refusal 'policy_decline')
    Write-SignedRl (Join-Path $riDir 'glm.json') (New-RlObj -Lane 'v-glm-security-fb' -Model 'glm' -ResultPath $gp -ResultSha (Get-Sha256Text $okBody) -Started $ts6 -Completed $ts10 -FallbackOf 'v-sol-security')
    $before = Invoke-Integrity $riDir $prov.Base $prov.Span
    if ($before.ExitCode -ne 0 -or (Get-VerdictToken $before.Raw) -ne 'ok') { throw ("baseline not ok: {0}" -f $before.Raw) }
    Remove-Item -LiteralPath (Join-Path $riDir 'glm.json') -Force
    $after = Invoke-Integrity $riDir $prov.Base $prov.Span
    if ($after.ExitCode -ne 1 -or (Get-VerdictToken $after.Raw) -ne 'FAILED') { throw ("after delete want FAILED: {0}" -f $after.Raw) }
    $mutOk++; Write-Output 'mutation-A PASS: integrity ok -> FAILED after failover receipt delete'
  } catch { $failed = $true; Write-Output ("mutation-A FAIL: {0}" -f $_.Exception.Message) }

  # B: unsigned / wrong-key / tampered-field => FAILED
  try {
    $riDir = Join-Path $root 'mut-b'; $aux = Join-Path $root 'mut-b-aux'
    New-Item -ItemType Directory -Force -Path $riDir, $aux | Out-Null
    $prov = Write-RiBase $aux @((New-Span 'v-sol-security' 'sol' 'ok'))
    $bp = [IO.Path]::GetFullPath((Join-Path $riDir 'sol.md')); Write-Utf8 $bp $okBody
    $obj = New-RlObj -Lane 'v-sol-security' -Model 'sol' -ResultPath $bp -ResultSha (Get-Sha256Text $okBody)
    Write-OrderedJson (Join-Path $riDir 'sol.json') $obj $rlF ''
    if ((Get-VerdictToken (Invoke-Integrity $riDir $prov.Base $prov.Span).Raw) -ne 'FAILED') { throw 'unsigned not FAILED' }
    $wrong = New-Object byte[] 32; for ($i = 0; $i -lt 32; $i++) { $wrong[$i] = [byte](255 - $i) }
    Write-SignedRl (Join-Path $riDir 'sol.json') $obj $wrong
    if ((Get-VerdictToken (Invoke-Integrity $riDir $prov.Base $prov.Span).Raw) -ne 'FAILED') { throw 'wrong-key not FAILED' }
    Write-SignedRl (Join-Path $riDir 'sol.json') $obj
    $raw = ([IO.File]::ReadAllText((Join-Path $riDir 'sol.json'), $utf8)) -replace '"outcome":"completed"', '"outcome":"refused"'
    Write-Utf8 (Join-Path $riDir 'sol.json') $raw
    if ((Get-VerdictToken (Invoke-Integrity $riDir $prov.Base $prov.Span).Raw) -ne 'FAILED') { throw 'tampered not FAILED' }
    $mutOk++; Write-Output 'mutation-B PASS: unsigned/wrong-key/tampered => FAILED'
  } catch { $failed = $true; Write-Output ("mutation-B FAIL: {0}" -f $_.Exception.Message) }

  # C: security identity ok(1/2); hosted masquerade FAILED; generic FAILED
  try {
    $names = @('v-sol.md','v-terra.md','v-opus.md','v-glm-security.md','v-grok.md')
    $mOk = @{ 'v-sol.md'='sol'; 'v-terra.md'='terra'; 'v-opus.md'='claude-opus-5'; 'v-glm-security.md'='glm-5.2'; 'v-grok.md'='grok-4.5' }
    $rOk = @{ 'v-sol.md'='general-review'; 'v-terra.md'='general-review'; 'v-opus.md'='general-review'; 'v-glm-security.md'='security-review'; 'v-grok.md'='general-review' }
    $s0 = New-AdvShip 'mut-c-ok'; Write-AdvVoices $s0 $names $mOk $rOk
    $r0 = Invoke-Adv $s0.Repo $s0.Base $s0.ReviewDir $s0.ReceiptDir
    if ($r0.ExitCode -ne 0 -or $r0.Raw -notmatch 'security-voices: 1/2' -or (Get-VerdictToken $r0.Raw) -ne 'ok') { throw ("valid want ok 1/2: {0}" -f $r0.Raw) }
    $s1 = New-AdvShip 'mut-c-host'
    # Hosted model under same v-glm-security lane (keep 5 distinct model keys; security identity fails)
    $mHost = @{ 'v-sol.md'='sol'; 'v-terra.md'='terra'; 'v-opus.md'='claude-opus-5'; 'v-glm-security.md'='fable'; 'v-grok.md'='grok-4.5' }
    Write-AdvVoices $s1 $names $mHost $rOk
    $r1 = Invoke-Adv $s1.Repo $s1.Base $s1.ReviewDir $s1.ReceiptDir
    if ($r1.ExitCode -ne 1 -or $r1.Raw -notmatch 'security-voices: 0/2' -or (Get-VerdictToken $r1.Raw) -ne 'FAILED') { throw ("hosted want FAILED: {0}" -f $r1.Raw) }
    $s2 = New-AdvShip 'mut-c-gen'
    $nGen = @('v-sol.md','v-terra.md','v-opus.md','v-glm.md','v-grok.md')
    $mGen = @{ 'v-sol.md'='sol'; 'v-terra.md'='terra'; 'v-opus.md'='claude-opus-5'; 'v-glm.md'='glm-5.2'; 'v-grok.md'='grok-4.5' }
    $rGen = @{ 'v-sol.md'='general-review'; 'v-terra.md'='general-review'; 'v-opus.md'='general-review'; 'v-glm.md'='general-review'; 'v-grok.md'='general-review' }
    Write-AdvVoices $s2 $nGen $mGen $rGen
    $r2 = Invoke-Adv $s2.Repo $s2.Base $s2.ReviewDir $s2.ReceiptDir
    if ($r2.ExitCode -ne 1 -or $r2.Raw -notmatch 'security-voices: 0/2' -or (Get-VerdictToken $r2.Raw) -ne 'FAILED') { throw ("generic want FAILED: {0}" -f $r2.Raw) }
    $mutOk++; Write-Output 'mutation-C PASS: security identity ok(1/2) -> hosted/generic FAILED'
  } catch { $failed = $true; Write-Output ("mutation-C FAIL: {0}" -f $_.Exception.Message) }

  # D: merge READY; different signed packet sha => NOT_READY
  try {
    $mrDir = Join-Path $root 'mut-d'; New-Item -ItemType Directory -Force -Path $mrDir | Out-Null
    foreach ($st in @('change-map','synthesis','adversarial-challenge','triage')) {
      Write-SignedMs (Join-Path $mrDir ($st + '.receipt.json')) (New-MsObj $st $shaA)
    }
    $r0 = Invoke-Merge $mrDir $shaA
    if ($r0.ExitCode -ne 0 -or (Get-VerdictToken $r0.Raw 'merge') -ne 'READY') { throw ("want READY: {0}" -f $r0.Raw) }
    Write-SignedMs (Join-Path $mrDir 'triage.receipt.json') (New-MsObj 'triage' $shaB)
    $r1 = Invoke-Merge $mrDir $shaA
    if ((Get-VerdictToken $r1.Raw 'merge') -ne 'NOT_READY') { throw ("want NOT_READY: {0}" -f $r1.Raw) }
    $mutOk++; Write-Output 'mutation-D PASS: merge READY -> NOT_READY on packet-sha mismatch'
  } catch { $failed = $true; Write-Output ("mutation-D FAIL: {0}" -f $_.Exception.Message) }
}
catch { $failed = $true; Write-Output ("harness FAIL: {0}" -f $_.Exception.Message) }
finally {
  $env:USERPROFILE = $oldProfile
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
$verdict = 'FAILED'; $exitCode = 1
if ((-not $failed) -and ($subPass -eq $subTotal) -and ($mutOk -eq $mutTotal)) { $verdict = 'ok'; $exitCode = 0 }
Write-Output ("contract: {0} sub-tests PASS | mutation-proofs: {1}/{2} | verdict: {3}" -f $subPass, $mutOk, $mutTotal, $verdict)
exit $exitCode
