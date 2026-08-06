# Merge-readiness reducer. VERIFY-SIGNATURE-FIRST. FAIL CLOSED. Exit 0/3/4/2. PS 5.1; <300 lines.
param(
  [string]$RunId = '', [string]$ExpectedPacketSha256 = '',
  [string]$ReceiptDir = '', [string[]]$RequiredStages = @(), [string[]]$ConditionalStages = @(),
  [int]$RoundCap = 3, [string]$OutputPath = '', [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$script:StatusEnum = @('passed', 'not_applicable', 'blocked', 'failed', 'no_contest')
$script:FailStates = @('failed', 'blocked', 'no_contest')
$script:SevEnum = @('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')
$script:MandatoryStages = @('change-map', 'synthesis', 'adversarial-challenge', 'triage')
$script:FallbackCats = @('transport error', 'provider outage', 'no-equivalent-authority', 'policy refusal', 'capability decline')
$script:ShaRe = '^[0-9a-fA-F]{64}$'; $script:RvCanonRe = '^(repair|verify)-([1-9][0-9]*)$'; $script:RvPrefixRe = '^(repair|verify)-'
$script:MsFields = @('schema_version','receipt_type','run_id','task_id','lane_id','stage','required','status','requested_model','observed_model','model_evidence','effort','input_packet_sha256','emitter_id','locked_plan_sha256','stage_set_sha256','review_tier','review_profile','charter_path','result_path','result_sha256','charter_sha256','exit_code','outcome','fallback_of','failure_category','findings','evidence_refs','output_artifacts','started_at','completed_at','model','sig_alg','signature')
$script:ArrFields = @('findings', 'evidence_refs', 'output_artifacts')
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')

function Normalize-StageList([string[]]$Raw) {
  $out = New-Object System.Collections.ArrayList; $seen = @{}
  foreach ($entry in @($Raw)) {
    foreach ($part in @(([string]$entry) -split ',')) {
      $id = ([string]$part).Trim()
      if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
      $seen[$id] = $true; [void]$out.Add($id)
    }
  }
  return @($out)
}
function Get-MergeStageSetSha256([string[]]$Required, [string[]]$Conditional) {
  $ids = @(Normalize-StageList (@($script:MandatoryStages) + @($Required) + @($Conditional)))
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash($utf8.GetBytes(($ids -join "`n"))) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}
function Get-TopLevelJsonMeta([string]$s) {
  $counts = @{}; $arrayFields = @{}
  if ([string]::IsNullOrWhiteSpace($s)) { return @{ Dup = $true; Counts = $counts; ArrayFields = $arrayFields } }
  $i = 0; $n = $s.Length; $objDepth = 0; $arrDepth = 0; $expectKey = $false; $inStr = $false; $escape = $false; $pendingKey = $null
  while ($i -lt $n) {
    $c = $s[$i]
    if ($inStr) { if ($escape) { $escape = $false } elseif ($c -eq [char]92) { $escape = $true } elseif ($c -eq '"') { $inStr = $false }; $i++; continue }
    if ($c -eq '"') {
      if ($objDepth -eq 1 -and $arrDepth -eq 0 -and $expectKey) {
        $i++; $start = $i
        while ($i -lt $n) { if ($s[$i] -eq [char]92 -and ($i + 1) -lt $n) { $i += 2; continue }; if ($s[$i] -eq '"') { break }; $i++ }
        $key = $s.Substring($start, [Math]::Max(0, $i - $start))
        if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
        $pendingKey = $key; $expectKey = $false; if ($i -lt $n -and $s[$i] -eq '"') { $i++ }; continue
      }
      $inStr = $true; $i++; continue
    }
    if ($c -eq '{') { $objDepth++; $expectKey = $true; $pendingKey = $null; $i++; continue }
    if ($c -eq '}') { $objDepth--; $expectKey = $false; $pendingKey = $null; $i++; continue }
    if ($c -eq '[') { if ($null -ne $pendingKey -and $objDepth -eq 1 -and $arrDepth -eq 0) { $arrayFields[$pendingKey] = $true }; $arrDepth++; $pendingKey = $null; $expectKey = $false; $i++; continue }
    if ($c -eq ']') { $arrDepth--; $i++; continue }
    if ($c -eq ',') { if ($objDepth -eq 1 -and $arrDepth -eq 0) { $expectKey = $true }; $pendingKey = $null; $i++; continue }
    if ($c -eq ':') { $expectKey = $false; $i++; continue }
    if ($c -notmatch '\s') { $pendingKey = $null }; $i++
  }
  $dup = $false; foreach ($k in @($counts.Keys)) { if ($counts[$k] -gt 1 -or $k.IndexOf([char]92) -ge 0) { $dup = $true; break } }
  return @{ Dup = $dup; Counts = $counts; ArrayFields = $arrayFields }
}
function Restore-TopLevelArrays($Obj, $ArrayFields) {
  foreach ($field in $script:ArrFields) {
    if (-not $ArrayFields.ContainsKey($field)) { continue }
    $v = $Obj.$field
    if ($null -eq $v) { $Obj.$field = @() } elseif (-not ($v -is [System.Array])) { $Obj.$field = @($v) }
  }
}
function Get-OrderedMergeReceipt($Obj) {
  $findList = New-Object System.Collections.ArrayList
  foreach ($f in @($Obj.findings)) {
    if ($null -eq $f) { continue }
    [void]$findList.Add([pscustomobject][ordered]@{ severity = [string]$f.severity; id = [string]$f.id; resolved = [bool]$f.resolved })
  }
  $ev = New-Object System.Collections.ArrayList; foreach ($x in @($Obj.evidence_refs)) { if ($null -ne $x) { [void]$ev.Add([string]$x) } }
  $oa = New-Object System.Collections.ArrayList; foreach ($x in @($Obj.output_artifacts)) { if ($null -ne $x) { [void]$oa.Add([string]$x) } }
  $o = [ordered]@{}
  foreach ($name in $script:MsFields) {
    if ($name -eq 'signature') { continue }
    if ($name -eq 'findings') { $o[$name] = [object[]]@($findList); continue }
    if ($name -eq 'evidence_refs') { $o[$name] = [string[]]@($ev); continue }
    if ($name -eq 'output_artifacts') { $o[$name] = [string[]]@($oa); continue }
    if ($Obj.PSObject.Properties[$name]) { $o[$name] = $Obj.$name } else { $o[$name] = $null }
  }
  return [pscustomobject]$o
}
function Test-ReceiptSchema($Obj) {
  if ($null -eq $Obj) { return 'null' }
  if (-not ($Obj.schema_version -is [string]) -or ([string]$Obj.schema_version -cne '2')) { return 'bad schema_version' }
  if (-not ($Obj.receipt_type -is [string]) -or ([string]$Obj.receipt_type -cne 'merge_stage')) { return 'bad receipt_type' }
  foreach ($sf in @('run_id', 'stage', 'model', 'observed_model')) {
    if (-not ($Obj.$sf -is [string]) -or [string]::IsNullOrWhiteSpace($Obj.$sf)) { return "bad $sf" }
  }
  $sha = [string]$Obj.input_packet_sha256
  if ([string]::IsNullOrWhiteSpace($sha) -or $sha -notmatch $script:ShaRe) { return 'bad sha' }
  if (-not ($Obj.required -is [bool])) { return 'required not bool' }
  if ([string]$Obj.status -notin $script:StatusEnum) { return 'bad status' }
  foreach ($af in $script:ArrFields) { if ($null -eq $Obj.$af -or -not ($Obj.$af -is [System.Array])) { return "$af not array" } }
  foreach ($f in @($Obj.findings)) {
    if ($null -eq $f -or $f -is [ValueType] -or $f -is [string]) { return 'finding bad' }
    foreach ($need in @('severity', 'id', 'resolved')) { if ($need -notin @($f.PSObject.Properties.Name)) { return "finding missing $need" } }
    if (-not ($f.resolved -is [bool])) { return 'finding resolved not bool' }
    if (([string]$f.severity).Trim().ToUpperInvariant() -notin $script:SevEnum) { return 'finding bad severity' }
  }
  return $null
}
function Get-UnresolvedCount($Findings) {
  $n = 0
  foreach ($f in @($Findings)) {
    if ($null -eq $f) { continue }
    $sev = ''; if ($f.PSObject.Properties['severity']) { $sev = ([string]$f.severity).Trim().ToUpperInvariant() }
    $resolved = ($f.PSObject.Properties['resolved'] -and ($f.resolved -is [bool]) -and [bool]$f.resolved)
    if (-not $resolved -and ($sev -eq 'HIGH' -or $sev -eq 'CRITICAL')) { $n++ }
  }
  return $n
}
function Test-EvidenceNonEmpty($Refs) {
  foreach ($ref in @($Refs)) { if ($null -ne $ref -and -not [string]::IsNullOrWhiteSpace([string]$ref)) { return $true } }; return $false
}
function Get-ReceiptIdentity($r) { return (([string]$r.stage) + ':' + ([string]$r.model)) }
function Test-ResultVerified($r) {
  $rp = [string]$r.result_path
  if ([string]::IsNullOrWhiteSpace($rp) -or -not (Test-Path -LiteralPath $rp -PathType Leaf)) { return $false }
  $sha = [Security.Cryptography.SHA256]::Create(); try { $fs = [IO.File]::OpenRead($rp); try { $got = -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) } finally { $fs.Dispose() } } finally { $sha.Dispose() }
  return ($got -ceq ([string]$r.result_sha256).ToLowerInvariant())
}
function Test-StageNameOk([string]$sn) {
  if ([string]::IsNullOrWhiteSpace($sn)) { return $false }
  if ($sn -match $script:RvPrefixRe) { return [bool]($sn -match $script:RvCanonRe) }; return $true
}
function Resolve-StageReceipt($List) {
  $arr = @($List); if ($arr.Count -eq 0) { return $null }
  $byId = @{}; $roots = New-Object System.Collections.ArrayList; $nonRoots = New-Object System.Collections.ArrayList
  foreach ($r in $arr) {
    $id = Get-ReceiptIdentity $r; if ($byId.ContainsKey($id)) { return $null }
    $byId[$id] = $r
    if ($null -eq $r.fallback_of -or [string]::IsNullOrWhiteSpace([string]$r.fallback_of)) { [void]$roots.Add($r) } else { [void]$nonRoots.Add($r) }
  }
  if ($roots.Count -ne 1) { return $null }
  $root = $roots[0]; $children = @{}
  foreach ($r in @($nonRoots)) {
    $fbKey = [string]$r.fallback_of; if (-not $byId.ContainsKey($fbKey)) { return $null }
    $pred = $byId[$fbKey]
    if ([string]$pred.stage -ne [string]$r.stage) { return $null }
    if ([string]$pred.status -notin $script:FailStates) { return $null }
    if ([string]$pred.failure_category -notin $script:FallbackCats) { return $null }
    try { if ([DateTimeOffset]::Parse([string]$r.started_at) -lt [DateTimeOffset]::Parse([string]$pred.completed_at)) { return $null } } catch { return $null }
    if (-not $children.ContainsKey($fbKey)) { $children[$fbKey] = New-Object System.Collections.ArrayList }
    [void]$children[$fbKey].Add($r)
  }
  foreach ($k in @($children.Keys)) { if (@($children[$k]).Count -gt 1) { return $null } }
  $seen = @{}; $cur = $root; $guard = 0
  while ($true) {
    $cid = Get-ReceiptIdentity $cur; if ($seen.ContainsKey($cid) -or $cur.required -ne $root.required) { return $null }
    $seen[$cid] = $true; if (-not $children.ContainsKey($cid)) { break }
    $kids = @($children[$cid]); if ($kids.Count -ne 1) { return $null }
    $cur = $kids[0]; $guard++; if ($guard -gt $arr.Count) { return $null }
  }
  if ($seen.Count -ne $arr.Count) { return $null }
  return $cur
}
function New-ReduceResult([string]$Verdict, [int]$N, [int]$V, [int]$M, [int]$S, [int]$U, [bool]$UsageError = $false, [string]$SigReason = '') {
  return [pscustomobject]@{ Verdict = $Verdict; N = $N; V = $V; M = $M; S = $S; U = $U; UsageError = $UsageError; SigReason = $SigReason }
}
function Invoke-MergeReadinessReduce {
  param([string]$Dir, [string[]]$Required, [string[]]$Conditional, [int]$Cap, [string]$RunId, [string]$ExpectedPacket, [byte[]]$Secret, [string]$KeyId)
  $fired = @(Normalize-StageList $Required); $condOnly = @(Normalize-StageList $Conditional)
  $eval = New-Object System.Collections.ArrayList; $evalSet = @{}
  foreach ($id in @($script:MandatoryStages + $fired + $condOnly)) {
    if ($evalSet.ContainsKey($id)) { continue }; $evalSet[$id] = $true; [void]$eval.Add($id)
  }
  $N = $eval.Count; $V = 0; $M = 0; $S = 0; $U = 0; $blocked = $false
  $firedSet = @{}; foreach ($fx in $fired) { $firedSet[$fx] = $true }
  $condSet = @{}; foreach ($cx in $condOnly) { $condSet[$cx] = $true }
  $mandSet = @{}; foreach ($mx in $script:MandatoryStages) { $mandSet[$mx] = $true }
  $expectStageSet = Get-MergeStageSetSha256 $Required $Conditional
  $expectPkt = $ExpectedPacket.ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir -PathType Container)) {
    return (New-ReduceResult 'NOT_READY' $N 0 $N 0 0)
  }
  $groups = @{}; $tainted = @{}; $runIds = @{}; $dirInvalid = $false; $sigReason = ''
  foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter '*.receipt.json' -File -ErrorAction SilentlyContinue)) {
    try {
      $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
      $meta = Get-TopLevelJsonMeta $raw; $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { $dirInvalid = $true; continue }
    if ($null -eq $obj) { $dirInvalid = $true; continue }
    $stageCount = 0; if ($meta.Counts.ContainsKey('stage')) { $stageCount = [int]$meta.Counts['stage'] }
    if ($meta.Dup -and $stageCount -ne 1) { $dirInvalid = $true; continue }
    Restore-TopLevelArrays $obj $meta.ArrayFields
    # Signature FIRST — never trust stage/status/model/findings/fallback_of before HMAC ok.
    $sigProp = $null; if ($obj.PSObject.Properties['signature']) { $sigProp = [string]$obj.signature }
    try { $ordered = Get-OrderedMergeReceipt $obj } catch { $sigReason = 'noncanonical_shape'; continue }
    $vr = Test-FleetReceiptSignature -Receipt $ordered -ReceiptType 'merge_stage' -RunSecret $Secret -KeyId $KeyId -Signature $sigProp
    if (-not $vr.ok) { if ([string]::IsNullOrWhiteSpace($sigReason)) { $sigReason = [string]$vr.reason }; continue }
    if ([string]$ordered.run_id -cne $RunId) { if ([string]::IsNullOrWhiteSpace($sigReason)) { $sigReason = 'run_id_mismatch' }; continue }
    $sn = [string]$ordered.stage
    if ([string]::IsNullOrWhiteSpace($sn) -or -not (Test-StageNameOk $sn)) { $dirInvalid = $true; continue }
    $runIds[$ordered.run_id] = $true
    if ($meta.Dup -or $null -ne (Test-ReceiptSchema $ordered)) { $tainted[$sn] = $true; continue }
    if (-not $groups.ContainsKey($sn)) { $groups[$sn] = New-Object System.Collections.ArrayList }
    [void]$groups[$sn].Add($ordered)
  }
  if (-not [string]::IsNullOrWhiteSpace($sigReason)) { return (New-ReduceResult 'NOT_READY' $N 0 $N 0 0 $false $sigReason) }
  if ($dirInvalid -or $runIds.Count -gt 1) { return (New-ReduceResult 'NOT_READY' $N 0 $N 0 0 $true) }
  foreach ($sn in @($groups.Keys)) { if ($tainted.ContainsKey($sn)) { $groups.Remove($sn) } }
  $byStage = @{}
  foreach ($sn in @($groups.Keys)) {
    $picked = Resolve-StageReceipt $groups[$sn]
    if ($null -ne $picked) { $byStage[$sn] = $picked } else { $tainted[$sn] = $true }
  }
  # Trusted -ExpectedPacketSha256 — no packet-majority election.
  $staleSet = @{}
  foreach ($k in @($byStage.Keys)) {
    $r = $byStage[$k]
    if ([string]$r.status -eq 'blocked') { $blocked = $true; $U++ }
    $uHere = Get-UnresolvedCount $r.findings; if ($uHere -gt 0) { $U += $uHere; $blocked = $true }
    $pkt = ([string]$r.input_packet_sha256).ToLowerInvariant()
    $ss = ([string]$r.stage_set_sha256).ToLowerInvariant()
    if ($pkt -ne $expectPkt -or $ss -ne $expectStageSet) { if (-not $staleSet.ContainsKey($k)) { $staleSet[$k] = $true; $S++ } }
  }
  foreach ($stage in @($eval)) {
    $mustPass = $mandSet.ContainsKey($stage) -or $firedSet.ContainsKey($stage)
    $allowNa = (-not $mustPass) -and $condSet.ContainsKey($stage)
    if ($tainted.ContainsKey($stage) -or -not $byStage.ContainsKey($stage)) { $M++; continue }
    $r = $byStage[$stage]; if ($null -ne (Test-ReceiptSchema $r)) { $M++; continue }
    $st = [string]$r.status
    if ($staleSet.ContainsKey($stage)) { continue }
    if ($mustPass) {
      if ($r.required -ne $true -or $st -ne 'passed') { $M++; continue }
      if (-not (Test-ResultVerified $r)) { $M++; continue }
      if ((Test-EvidenceNonEmpty $r.evidence_refs) -or (Test-EvidenceNonEmpty $r.output_artifacts)) { $V++ } else { $M++ }
      continue
    }
    if ($allowNa) {
      if ($st -eq 'not_applicable') { if (Test-EvidenceNonEmpty $r.evidence_refs) { $V++ } else { $M++ } }
      elseif ($st -eq 'passed') { $V++ } else { $M++ }; continue
    }
    if ($st -eq 'passed') { $V++ } else { $M++ }
  }
  foreach ($sn in @($tainted.Keys)) { if (-not $evalSet.ContainsKey($sn) -and $sn -notmatch $script:RvCanonRe) { $M++ } }
  foreach ($sn in @($byStage.Keys)) {
    if (($sn -notmatch $script:RvCanonRe) -and ($byStage[$sn].required -eq $true) -and (-not $evalSet.ContainsKey($sn))) { $M++ }
  }
  $repairMap = @{}; $verifyMap = @{}
  foreach ($k in @(@($byStage.Keys) + @($tainted.Keys))) {
    if ($k -notmatch $script:RvCanonRe) { continue }
    $idx = [int]$Matches[2]; $kind = $Matches[1]
    if ($byStage.ContainsKey($k)) {
      if ($kind -eq 'repair') { $repairMap[$idx] = $byStage[$k] } else { $verifyMap[$idx] = $byStage[$k] }
    } else {
      if ($kind -eq 'repair' -and -not $repairMap.ContainsKey($idx)) { $repairMap[$idx] = $null }
      elseif ($kind -eq 'verify' -and -not $verifyMap.ContainsKey($idx)) { $verifyMap[$idx] = $null }
    }
  }
  $maxRound = 0
  foreach ($rn in @($repairMap.Keys + $verifyMap.Keys)) { if ([int]$rn -gt $maxRound) { $maxRound = [int]$rn } }
  if ($maxRound -gt $Cap) { $M++ }
  for ($rn = 1; $rn -le $maxRound; $rn++) {
    if (-not $repairMap.ContainsKey($rn) -or -not $verifyMap.ContainsKey($rn)) { $M++; continue }
    $rr = $repairMap[$rn]; $vr = $verifyMap[$rn]
    if ($null -eq $rr -or $null -eq $vr) { $M++; continue }
    if ([string]$rr.status -ne 'passed' -or [string]$vr.status -ne 'passed') { $M++; continue }
    if (([string]$rr.input_packet_sha256).ToLowerInvariant() -ne $expectPkt -or ([string]$vr.input_packet_sha256).ToLowerInvariant() -ne $expectPkt) { $M++; continue }
    if ([string]$rr.observed_model -eq [string]$vr.observed_model) { $M++; continue }
  }
  $verdict = 'READY'; if ($blocked) { $verdict = 'BLOCKED' } elseif ($M -gt 0 -or $S -gt 0 -or $V -lt $N) { $verdict = 'NOT_READY' }
  return (New-ReduceResult $verdict $N $V $M $S $U)
}
function Format-MergeLine($R) { return "merge-readiness: $($R.Verdict) | required: $($R.N) | valid: $($R.V) | missing: $($R.M) | stale: $($R.S) | unresolved: $($R.U)" }
function Get-ExitForVerdict([string]$V) { if ($V -eq 'READY') { return 0 }; if ($V -eq 'BLOCKED') { return 4 }; return 3 }
if ($SelfTest) {
  $here = $PSScriptRoot; if ([string]::IsNullOrWhiteSpace($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
  $testScript = Join-Path $here 'Test-FleetMergeReadiness.ps1'
  if (-not (Test-Path -LiteralPath $testScript)) { [Console]::Error.WriteLine(('selftest: missing {0}' -f $testScript)); exit 1 }
  & $testScript; exit $LASTEXITCODE
}
if ($RoundCap -lt 1 -or $RoundCap -gt 3) { [Console]::Error.WriteLine('usage: -RoundCap must be 1..3'); exit 2 }
if ([string]::IsNullOrWhiteSpace($ReceiptDir)) { [Console]::Error.WriteLine('usage: -ReceiptDir -RunId -ExpectedPacketSha256 | -SelfTest'); exit 2 }
if ([string]::IsNullOrWhiteSpace($RunId)) { [Console]::Error.WriteLine('usage: -RunId is mandatory'); exit 2 }
if ([string]::IsNullOrWhiteSpace($ExpectedPacketSha256) -or ($ExpectedPacketSha256 -notmatch $script:ShaRe)) { [Console]::Error.WriteLine('usage: -ExpectedPacketSha256 must be 64-char hex'); exit 2 }
try { $leaseKey = Get-FleetRunLeaseKey -RunId $RunId } catch { [Console]::Error.WriteLine(('usage: lease key load failed: {0}' -f $_.Exception.Message)); exit 2 }
$result = Invoke-MergeReadinessReduce -Dir $ReceiptDir -Required $RequiredStages -Conditional $ConditionalStages -Cap $RoundCap -RunId $RunId -ExpectedPacket $ExpectedPacketSha256 -Secret $leaseKey.KeyBytes -KeyId $leaseKey.KeyId
if ($result.UsageError) { [Console]::Error.WriteLine('usage: receipt dir invalid (parse/stage anomaly or mixed run_id)'); exit 2 }
if (-not [string]::IsNullOrWhiteSpace($result.SigReason)) { [Console]::Error.WriteLine(('merge-readiness: signature: {0}' -f $result.SigReason)) }
$line = Format-MergeLine $result
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  try {
    $summary = [ordered]@{ schema_version = '1'; verdict = $result.Verdict; required = $result.N; valid = $result.V; missing = $result.M; stale = $result.S; unresolved = $result.U; summary = $line; signature_reason = $result.SigReason }
    [IO.File]::WriteAllText($OutputPath, ($summary | ConvertTo-Json -Compress -Depth 4), (New-Object System.Text.UTF8Encoding $false))
  } catch { [Console]::Error.WriteLine(('usage: -OutputPath write failed: {0}' -f $_.Exception.Message)); exit 2 }
}
Write-Output $line; exit (Get-ExitForVerdict $result.Verdict)
