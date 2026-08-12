# Dot-sourceable signed-receipt TEST fixtures. NO top-level side effects.
# Callers must . FleetReceiptSignature.Helpers.ps1 first. PS 5.1.
$script:FstUtf8 = New-Object System.Text.UTF8Encoding $false
$script:FstRlFields = @('schema_version','receipt_type','run_id','task_id','lane_id','voice_id','review_role','requested_model','observed_model','model_evidence','emitter_id','input_packet_sha256','expected_lane_manifest_sha256','locked_plan_sha256','review_profile','charter_path','review_tier','result_path','charter_sha256','result_sha256','exit_code','outcome','refusal_reason','fallback_of','started_at','completed_at','sig_alg','key_id','signature')
$script:FstMsFields = @('schema_version','receipt_type','run_id','task_id','lane_id','stage','required','status','requested_model','observed_model','model_evidence','effort','input_packet_sha256','emitter_id','locked_plan_sha256','stage_set_sha256','review_tier','review_profile','charter_path','result_path','result_sha256','charter_sha256','exit_code','outcome','fallback_of','failure_category','findings','evidence_refs','output_artifacts','started_at','completed_at','model','sig_alg','signature')
function Get-FileSha([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $fs = [IO.File]::OpenRead($Path); try { return -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) } finally { $fs.Dispose() } } finally { $sha.Dispose() }
}
function Get-StageSetSha([string[]]$Required, [string[]]$Conditional = @()) {
  $mand = @('change-map', 'synthesis', 'adversarial-challenge', 'triage'); $out = New-Object System.Collections.ArrayList; $seen = @{}
  foreach ($entry in @($mand + @($Required) + @($Conditional))) {
    foreach ($part in @(([string]$entry) -split ',')) {
      $id = ([string]$part).Trim(); if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
      $seen[$id] = $true; [void]$out.Add($id)
    }
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash($script:FstUtf8.GetBytes((@($out) -join "`n"))) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}
function Write-Utf8File([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $script:FstUtf8) }
function Install-TestLease {
  if (-not (Test-Path -LiteralPath $script:LeaseDir)) { New-Item -ItemType Directory -Path $script:LeaseDir -Force | Out-Null }
  $now = [datetimeoffset]::Now
  $rec = [ordered]@{ schema_version = '2'; run_id = $script:TestRunId; owner_pid = $PID; started_at = $now.ToString('o'); heartbeat_at = $now.ToString('o'); expires_at = $now.AddHours(4).ToString('o'); receipt_hmac_key_id = $script:TestKeyId; receipt_hmac_key_b64 = [Convert]::ToBase64String($script:TestSecret) }
  Write-Utf8File $script:LeasePath ($rec | ConvertTo-Json -Compress -Depth 4)
}
function Remove-TestLease { if (Test-Path -LiteralPath $script:LeasePath) { Remove-Item -LiteralPath $script:LeasePath -Force -ErrorAction SilentlyContinue } }
function New-TestLease {
  if ($null -eq $script:RunSeq) { $script:RunSeq = 0 }; $script:RunSeq++
  $runId = 'adv-' + $script:RunSeq.ToString('0000'); $secret = New-Object byte[] 32
  for ($i = 0; $i -lt 32; $i++) { $secret[$i] = [byte](($i * 9 + $script:RunSeq) -band 0xFF) }
  $keyId = ('{0:x2}' -f ($script:RunSeq -band 0xFF)) + ('b' * 30)
  $lhome = $script:LeaseHome; if ([string]::IsNullOrWhiteSpace($lhome)) { $lhome = $leaseHome }
  $leaseDir = Join-Path $lhome '.codex\fleet\run-leases'; New-Item -ItemType Directory -Force -Path $leaseDir | Out-Null
  $now = [datetimeoffset]::UtcNow
  $rec = [ordered]@{ schema_version = '2'; run_id = $runId; owner_pid = $PID; started_at = $now.ToString('o'); heartbeat_at = $now.ToString('o'); expires_at = $now.AddHours(4).ToString('o'); receipt_hmac_key_id = $keyId; receipt_hmac_key_b64 = [Convert]::ToBase64String($secret) }
  Write-Utf8File (Join-Path $leaseDir ($runId + '.json')) ($rec | ConvertTo-Json -Compress)
  return [pscustomobject]@{ RunId = $runId; Secret = $secret; KeyId = $keyId }
}
function ConvertTo-FixtureJson($Obj) {
  $parts = New-Object System.Collections.ArrayList
  foreach ($k in @($Obj.Keys)) {
    $v = $Obj[$k]
    if ($k -in @('findings', 'evidence_refs', 'output_artifacts')) {
      $elems = New-Object System.Collections.ArrayList
      foreach ($item in @($v)) { if ($null -eq $item -and @($v).Count -eq 0) { break }; [void]$elems.Add(($item | ConvertTo-Json -Depth 4 -Compress)) }
      [void]$parts.Add(('"{0}":[{1}]' -f $k, ($elems -join ','))); continue
    }
    if ($null -eq $v) { [void]$parts.Add(('"{0}":null' -f $k)); continue }
    [void]$parts.Add(('"{0}":{1}' -f $k, ($v | ConvertTo-Json -Compress -Depth 2)))
  }
  return '{' + ($parts -join ',') + '}'
}
function Write-SignedReceiptJson([string]$Path, $Receipt, [byte[]]$Secret, [string]$KeyId) {
  $sig = New-FleetReceiptSignature -Receipt $Receipt -ReceiptType 'review_lane' -RunSecret $Secret -KeyId $KeyId
  $fields = $script:LeaseFields; if ($null -eq $fields -or @($fields).Count -eq 0) { $fields = $script:FstRlFields }
  $parts = New-Object System.Collections.ArrayList
  foreach ($k in $fields) {
    if ($k -eq 'signature') { [void]$parts.Add(('"{0}":{1}' -f $k, (ConvertTo-Json -InputObject $sig -Compress))); continue }
    $v = $Receipt.$k
    if ($null -eq $v) { [void]$parts.Add(('"{0}":null' -f $k)); continue }
    [void]$parts.Add(('"{0}":{1}' -f $k, (ConvertTo-Json -InputObject $v -Compress)))
  }
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  Write-Utf8File $Path ('{' + ($parts -join ',') + '}')
}
function New-ReceiptObject {
  param(
    [string]$Stage, [string]$PacketSha, [string]$Status = 'passed',
    [object[]]$Findings = @(), [object[]]$EvidenceRefs = @('trigger:ok'), [object[]]$OutputArtifacts = @(),
    [string]$ObservedModel = 'test-model', [string]$Model = 'test-model',
    [object]$FallbackOf = $null, [object]$FailureCategory = $null, [bool]$Required = $true,
    [string]$RunId = '', [string]$StartedAt = '', [string]$CompletedAt = '',
    [string]$StageSetSha = '', [byte[]]$Secret = $null, [string]$KeyId = '', [switch]$Unsigned, [switch]$SkipSign,
    [string]$ResultPath = '', [string]$ResultSha = ''
  )
  if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = $script:TestRunId }
  if ([string]::IsNullOrWhiteSpace($StartedAt)) { $StartedAt = $script:Ts0 }
  if ([string]::IsNullOrWhiteSpace($CompletedAt)) { $CompletedAt = $script:Ts1 }
  if ([string]::IsNullOrWhiteSpace($StageSetSha)) { $StageSetSha = $script:StageSetSha }
  if ($null -eq $Secret) { $Secret = $script:TestSecret }
  if ([string]::IsNullOrWhiteSpace($KeyId)) { $KeyId = $script:TestKeyId }
  if ([string]::IsNullOrWhiteSpace($ResultPath)) { if (-not [string]::IsNullOrWhiteSpace($script:ResultFixturePath)) { $ResultPath = $script:ResultFixturePath } else { $ResultPath = 'C:\tmp\result.md' } }
  if ([string]::IsNullOrWhiteSpace($ResultSha)) { $ResultSha = $script:ShaRes }
  $findCanon = New-Object System.Collections.ArrayList
  foreach ($f in @($Findings)) {
    if ($null -eq $f) { continue }
    [void]$findCanon.Add([pscustomobject][ordered]@{ severity = ([string]$f.severity).Trim().ToUpperInvariant(); id = [string]$f.id; resolved = [bool]$f.resolved })
  }
  $o = [ordered]@{
    schema_version = '2'; receipt_type = 'merge_stage'; run_id = $RunId; task_id = 'task-1'; lane_id = 'lane-1'
    stage = $Stage; required = $Required; status = $Status; requested_model = $Model; observed_model = $ObservedModel
    model_evidence = 'test-evidence'; effort = 'high'; input_packet_sha256 = $PacketSha; emitter_id = 'test-emitter'
    locked_plan_sha256 = $script:ShaPlan; stage_set_sha256 = $StageSetSha; review_tier = 'STANDARD'; review_profile = 'standard'
    charter_path = 'C:\tmp\charter.md'; result_path = $ResultPath; result_sha256 = $ResultSha; charter_sha256 = $script:ShaChar
    exit_code = 0; outcome = 'completed'; fallback_of = $FallbackOf; failure_category = $FailureCategory
    findings = [object[]]@($findCanon); evidence_refs = [string[]]@($EvidenceRefs); output_artifacts = [string[]]@($OutputArtifacts)
    started_at = $StartedAt; completed_at = $CompletedAt; model = $Model; sig_alg = 'HMAC-SHA256'
  }
  if (-not $Unsigned -and -not $SkipSign) {
    $o['signature'] = (New-FleetReceiptSignature -Receipt ([pscustomobject]$o) -ReceiptType 'merge_stage' -RunSecret $Secret -KeyId $KeyId)
  }
  return $o
}
function Write-ReceiptFile([string]$Dir, [string]$Name, $Obj) { Write-Utf8File (Join-Path $Dir ($Name + '.receipt.json')) (ConvertTo-FixtureJson $Obj) }
function Write-RawReceipt([string]$Dir, [string]$Name, [string]$Json) { Write-Utf8File (Join-Path $Dir ($Name + '.receipt.json')) $Json }
function Write-MandatoryPassed([string]$Dir, [string]$Sha, [string[]]$Except = @(), [string]$StageSetSha = '') {
  foreach ($s in $script:Req) { if ($s -in $Except) { continue }; Write-ReceiptFile $Dir $s (New-ReceiptObject $s $Sha -StageSetSha $StageSetSha) }
}
function New-BaseJson([string]$Stage, [string]$Sha, [string]$Status = 'passed', [string]$Model = 'test-model') {
  return (ConvertTo-FixtureJson (New-ReceiptObject $Stage $Sha -Status $Status -Model $Model -ObservedModel $Model))
}
function New-ReviewReceiptObj {
  param(
    [string]$RunId, [string]$KeyId, [string]$LaneId, [string]$VoiceId, [string]$Model,
    [string]$Role = 'general-review', [string]$Profile = 'general', [string]$Tier = 'STANDARD',
    [string]$ResultPath, [string]$ResultSha, [string]$Outcome = 'completed', $Refusal = $null
  )
  $planSha = $script:FixedSha; if (-not [string]::IsNullOrWhiteSpace($script:BoundPlanSha)) { $planSha = $script:BoundPlanSha }
  return [pscustomobject][ordered]@{
    schema_version = '2'; receipt_type = 'review_lane'; run_id = $RunId; task_id = 'T-adv'
    lane_id = $LaneId; voice_id = $VoiceId; review_role = $Role; requested_model = $Model; observed_model = $Model
    model_evidence = 'unified-log'; emitter_id = 'test-emitter'; input_packet_sha256 = $script:FixedSha
    expected_lane_manifest_sha256 = $script:FixedSha; locked_plan_sha256 = $planSha
    review_profile = $Profile; charter_path = 'charter.md'; review_tier = $Tier; result_path = $ResultPath
    charter_sha256 = $script:FixedSha; result_sha256 = $ResultSha; exit_code = 0; outcome = $Outcome
    refusal_reason = $Refusal; fallback_of = $null; started_at = '2026-08-06T12:00:00.0000000Z'
    completed_at = '2026-08-06T12:01:00.0000000Z'; sig_alg = 'HMAC-SHA256'; key_id = $KeyId
  }
}
function New-Repo([string]$Name) {
  $repo = Join-Path $root $Name; New-Item -ItemType Directory -Force -Path $repo | Out-Null
  & git -C $repo init -q | Out-Null
  & git -C $repo -c user.email=fleet-test@example.invalid -c user.name=fleet-test commit --allow-empty -q -m seed | Out-Null
  return $repo
}
function Add-Commit([string]$Repo, [string]$RelPath, [string]$Content, [string]$Message) {
  $full = Join-Path $Repo $RelPath; $parent = Split-Path -Parent $full
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  Write-Utf8File $full $Content; & git -C $Repo add -- $RelPath | Out-Null
  & git -C $Repo -c user.email=fleet-test@example.invalid -c user.name=fleet-test commit -q -m $Message | Out-Null
}
function Quote-GitArg([string]$Value) {
  if ($null -eq $Value) { return '""' }; if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + ($Value.Replace('"', '\"')) + '"'
}
function Write-GitDiffFile([string]$Repo, [string]$BaseRef, [string]$OutFile) {
  $argLine = '-C ' + (Quote-GitArg $Repo) + ' --no-pager diff ' + (Quote-GitArg $BaseRef) + ' HEAD'
  $proc = New-Object System.Diagnostics.Process; $psi = $proc.StartInfo
  $psi.FileName = 'git'; $psi.Arguments = $argLine; $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  [void]$proc.Start(); $ms = New-Object System.IO.MemoryStream
  try {
    $proc.StandardOutput.BaseStream.CopyTo($ms); $err = $proc.StandardError.ReadToEnd(); $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "git diff failed: $err" }; [IO.File]::WriteAllBytes($OutFile, $ms.ToArray())
  } finally { $ms.Dispose(); $proc.Dispose() }
}
# Canonical verdict grammar (FleetReviewGrammar.Helpers.ps1): CRITICAL/HIGH => NO-GO terminal.
function Get-MdVoice([string]$Sev = 'HIGH') {
  $verdict = if ($Sev -ceq 'CRITICAL' -or $Sev -ceq 'HIGH') { 'NO-GO' } else { 'GO' }
  return "## Adversarial review`n$pad`n`nVERDICT: $verdict`nFINDINGS:`n- $Sev | F001 | scripts/x.ps1:10 | problem found, fix required`n"
}
function Get-NoFindingsVoice { return "## Adversarial review`nfull pass complete.`n$pad`n`nVERDICT: GO`nFINDINGS: none`n" }
function Get-JsonVoice { return (@{ status = 'ok'; response = "Review complete after full pass. $pad`n`nVERDICT: GO`nFINDINGS: none" } | ConvertTo-Json -Compress) }
function Get-RefusalJsonVoice { return (@{ status = 'ok'; response = "I cannot perform this security review. $pad" } | ConvertTo-Json -Compress) }
function Get-NgvJsonVoice { return (@{ status = 'needs_gate_validation'; response = "Review complete. HIGH: edge case checked. $pad" } | ConvertTo-Json -Compress) }
function Write-Manifest([string]$ReviewDir, [string]$FinalPath, [string]$Body = $null) {
  if ($Body) { Write-Utf8File (Join-Path $ReviewDir 'packet-manifest.json') $Body; return }
  $bytes = [IO.File]::ReadAllBytes($FinalPath); $sha = [Security.Cryptography.SHA256]::Create()
  try { $hex = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
  $obj = [ordered]@{ schema_version = '1'; review_risk = 'mechanical'; packet_sha256 = $script:FixedSha; artifacts = @(@{ name = 'final.diff'; bytes = [int64]$bytes.Length; sha256 = $hex }) }
  Write-Utf8File (Join-Path $ReviewDir 'packet-manifest.json') ($obj | ConvertTo-Json -Compress -Depth 5)
}
function Write-ReviewPacket {
  param([string]$Repo, [string]$BaseRef, [string]$ReviewDir, [string[]]$VoiceBodies, [int]$EmptyVoiceCount = 0, [string]$FrozenDiffPath = $null, [string]$ManifestBody = $null, [string[]]$VoiceNames = $null)
  if (-not (Test-Path -LiteralPath $ReviewDir)) { New-Item -ItemType Directory -Force -Path $ReviewDir | Out-Null }
  $finalPath = Join-Path $ReviewDir 'final.diff'
  if ($FrozenDiffPath -and (Test-Path -LiteralPath $FrozenDiffPath)) { Copy-Item -LiteralPath $FrozenDiffPath -Destination $finalPath -Force }
  else { Write-GitDiffFile $Repo $BaseRef $finalPath }
  Write-Manifest $ReviewDir $finalPath $ManifestBody; $i = 0; $paths = New-Object System.Collections.ArrayList
  foreach ($body in @($VoiceBodies)) {
    $i++; if ($VoiceNames -and $VoiceNames.Count -ge $i) { $name = $VoiceNames[$i - 1] } else { $name = "v-$i.md" }
    $dest = Join-Path $ReviewDir $name; $parent = Split-Path -Parent $dest
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Write-Utf8File $dest $body; [void]$paths.Add($dest)
  }
  for ($e = 0; $e -lt $EmptyVoiceCount; $e++) {
    $i++; $dest = Join-Path $ReviewDir ("v-$i.md"); [IO.File]::WriteAllBytes($dest, [byte[]]@()); [void]$paths.Add($dest)
  }
  return @($paths)
}
function Write-LockedPlan {
  param([string]$Path, [string]$Profile = 'general', [switch]$Duplicate, [switch]$OmitProfile)
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $lines = @('# frozen locked-plan')
  if (-not $OmitProfile) { $lines += "review_profile: $Profile"; if ($Duplicate) { $lines += "review_profile: $Profile" } } else { $lines += 'goals: ship' }
  Write-Utf8File $Path (($lines -join "`n") + "`n")
}
function Get-ModelForName([string]$Name) {
  $n = $Name.ToLowerInvariant()
  if ($n -match 'sol') { return 'sol' }; if ($n -match 'terra') { return 'terra' }
  if ($n -match 'opus') { return 'claude-opus-5' }; if ($n -match 'kimi') { return 'kimi-k3' }
  if ($n -match 'glm') { return 'glm-5.2' }; if ($n -match 'grok') { return 'grok-4.5' }
  if ($n -match 'fable') { return 'fable' }
  return ('model-' + [IO.Path]::GetFileNameWithoutExtension($Name))
}
function Get-RoleForName([string]$Name, [string]$Profile) {
  if ($Profile -ne 'security-sensitive') { return 'general-review' }
  if ($Name -like 'v-glm-security*' -or $Name -like 'v-kimi-security*' -or $Name -like 'v-grok-security*') { return 'security-review' }
  return 'general-review'
}
function Set-BoundPlanShaFrom([string]$PlanPath = '', [string]$ReceiptDir = '') {
  if (-not [string]::IsNullOrWhiteSpace($PlanPath) -and (Test-Path -LiteralPath $PlanPath -PathType Leaf)) { $script:BoundPlanSha = Get-FileSha $PlanPath; return }
  if (-not [string]::IsNullOrWhiteSpace($ReceiptDir)) { $cand = Join-Path (Split-Path -Parent $ReceiptDir) 'locked-plan.md'; if (Test-Path -LiteralPath $cand -PathType Leaf) { $script:BoundPlanSha = Get-FileSha $cand; return } }
  $script:BoundPlanSha = $script:FixedSha
}
function Write-ReceiptsForVoices {
  param(
    [string]$ReceiptDir, $Lease, [string[]]$VoicePaths, [string]$Profile = 'general',
    [string]$Tier = 'STANDARD', [hashtable]$ModelOverride = $null, [hashtable]$RoleOverride = $null,
    [byte[]]$SecretOverride = $null, [string]$KeyIdOverride = $null
  )
  if (-not (Test-Path -LiteralPath $ReceiptDir)) { New-Item -ItemType Directory -Force -Path $ReceiptDir | Out-Null }
  Set-BoundPlanShaFrom -ReceiptDir $ReceiptDir
  $secret = $Lease.Secret; if ($null -ne $SecretOverride) { $secret = $SecretOverride }
  $keyId = $Lease.KeyId; if (-not [string]::IsNullOrWhiteSpace($KeyIdOverride)) { $keyId = $KeyIdOverride }
  $i = 0
  foreach ($vp in @($VoicePaths)) {
    $i++; $name = [IO.Path]::GetFileName($vp); $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    $model = Get-ModelForName $name; if ($ModelOverride -and $ModelOverride.ContainsKey($name)) { $model = [string]$ModelOverride[$name] }
    $role = Get-RoleForName $name $Profile; if ($RoleOverride -and $RoleOverride.ContainsKey($name)) { $role = [string]$RoleOverride[$name] }
    if (Test-Path -LiteralPath $vp -PathType Leaf) { $sha = Get-FileSha $vp } else { $sha = $script:FixedSha }
    $r = New-ReviewReceiptObj -RunId $Lease.RunId -KeyId $keyId -LaneId $stem -VoiceId $stem -Model $model -Role $role -Profile $Profile -Tier $Tier -ResultPath ([IO.Path]::GetFullPath($vp)) -ResultSha $sha
    Write-SignedReceiptJson (Join-Path $ReceiptDir ("receipt-$i.json")) $r $secret $keyId
  }
}
function Get-FullFiveBodies { return @((Get-MdVoice 'HIGH'), (Get-MdVoice 'MEDIUM'), (Get-MdVoice 'LOW'), (Get-MdVoice 'HIGH'), (Get-MdVoice 'MEDIUM')) }
function Get-FullFiveNames([string]$Glm = 'v-glm.md', [string]$Grok = 'v-grok.md') { return @('v-sol.md', 'v-terra.md', 'v-opus.md', $Glm, $Grok) }
function New-Ship([string]$Name, [string]$File = 'f.txt', [string]$Body = "x`n", [string]$Profile = 'general') {
  $repo = New-Repo $Name; $base = (& git -C $repo rev-parse HEAD).Trim(); Add-Commit $repo $File $Body 'ship'
  $lp = Join-Path $repo 'locked-plan.md'; Write-LockedPlan -Path $lp -Profile $Profile; $lease = New-TestLease
  return [pscustomobject]@{ Repo = $repo; Base = $base; ReviewDir = (Join-Path $repo '.fleet-review'); ReceiptDir = (Join-Path $repo '.fleet-receipts'); LockedPlan = $lp; Lease = $lease; Profile = $Profile }
}
function Finish-Ship {
  param($S, [string[]]$Bodies, [string[]]$Names = $null, [string]$Tier = 'STANDARD', [hashtable]$ModelOverride = $null, [hashtable]$RoleOverride = $null)
  Set-BoundPlanShaFrom -PlanPath $S.LockedPlan -ReceiptDir $S.ReceiptDir
  $paths = Write-ReviewPacket -Repo $S.Repo -BaseRef $S.Base -ReviewDir $S.ReviewDir -VoiceBodies $Bodies -VoiceNames $Names
  Write-ReceiptsForVoices -ReceiptDir $S.ReceiptDir -Lease $S.Lease -VoicePaths $paths -Profile $S.Profile -Tier $Tier -ModelOverride $ModelOverride -RoleOverride $RoleOverride
  return $paths
}
function Invoke-Gate {
  param(
    [string]$Repo, [string]$BaseRef, [string]$ReviewDir = $null, [string]$Tier = 'STANDARD',
    [string]$Mode = 'text', [string[]]$PathFilter = @(), [string]$ReviewProfile = $null,
    [string]$LockedPlan = $null, [switch]$OmitProfile, [switch]$OmitLockedPlan,
    [string]$ReceiptDir = $null, [string]$RunId = $null, [string]$PacketManifest = $null, [switch]$OmitTier
  )
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Repo', $Repo, '-BaseRef', $BaseRef, '-Mode', $Mode)
  if (-not $OmitTier) { $args += @('-Tier', $Tier) }
  if (-not $OmitProfile -and -not [string]::IsNullOrWhiteSpace($ReviewProfile)) { $args += @('-ReviewProfile', $ReviewProfile) }
  if ($ReviewDir) { $args += @('-ReviewDir', $ReviewDir) }
  if (-not $OmitLockedPlan) {
    if ([string]::IsNullOrWhiteSpace($LockedPlan)) { $cand = Join-Path $Repo 'locked-plan.md'; if (Test-Path -LiteralPath $cand -PathType Leaf) { $LockedPlan = $cand } }
    if (-not [string]::IsNullOrWhiteSpace($LockedPlan)) { $args += @('-LockedPlan', $LockedPlan) }
  }
  if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = 'missing-run' }
  if ([string]::IsNullOrWhiteSpace($ReceiptDir)) { $ReceiptDir = Join-Path $Repo '.fleet-receipts' }
  if ([string]::IsNullOrWhiteSpace($PacketManifest)) { if ($ReviewDir) { $PacketManifest = Join-Path $ReviewDir 'packet-manifest.json' } else { $PacketManifest = Join-Path $Repo '.fleet-review\packet-manifest.json' } }
  $args += @('-RunId', $RunId, '-ReceiptDir', $ReceiptDir, '-PacketManifest', $PacketManifest)
  if ($PathFilter -and @($PathFilter).Count -gt 0) { $args += '-PathFilter'; $args += $PathFilter }
  $old = $ErrorActionPreference; $oldHome = $env:USERPROFILE
  try { $ErrorActionPreference = 'Continue'; $env:USERPROFILE = $leaseHome; $raw = & powershell.exe @args 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old; $env:USERPROFILE = $oldHome }
  return [pscustomobject]@{ ExitCode = $code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}
function Ig([string]$Repo,[string]$Base,[string]$Rd,[string]$Tier,[string]$RunId,[string]$Rc) {
  return Invoke-Gate -Repo $Repo -BaseRef $Base -ReviewDir $Rd -Tier $Tier -RunId $RunId -ReceiptDir $Rc -PacketManifest (Join-Path $Rd 'packet-manifest.json')
}
