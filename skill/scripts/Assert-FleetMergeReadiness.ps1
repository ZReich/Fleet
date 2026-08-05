# Deterministic merge-readiness reducer. FAIL CLOSED on any receipt anomaly.
# Exit: 0 READY, 3 NOT_READY, 4 BLOCKED, 2 usage. -SelfTest -> Test-FleetMergeReadiness.ps1.
param(
  [string]$ReceiptDir = '', [string[]]$RequiredStages = @(), [string[]]$ConditionalStages = @(),
  [int]$RoundCap = 3, [string]$OutputPath = '', [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$script:StatusEnum = @('passed', 'not_applicable', 'blocked', 'failed', 'no_contest')
$script:MandatoryStages = @('change-map', 'synthesis', 'adversarial-challenge', 'triage')
$script:FallbackCats = @('transport error', 'provider outage', 'no-equivalent-authority')
$script:ShaRe = '^[0-9a-fA-F]{64}$'
$script:RvCanonRe = '^(repair|verify)-([1-9][0-9]*)$'
$script:RvPrefixRe = '^(repair|verify)-'
$script:Fields = @('schema_version','run_id','stage','required','status','observed_model','effort',
  'input_packet_sha256','fallback_of','failure_category','findings','evidence_refs','output_artifacts',
  'started_at','completed_at','model')
$script:ArrFields = @('findings', 'evidence_refs', 'output_artifacts')

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
function Test-IsBool($v) { return ($v -is [bool]) }
function Get-ArrayField($v) { if ($null -ne $v -and $v -is [System.Array]) { return ,$v }; return $null }
function Test-SchemaVersionOk($v) {
  if ($null -eq $v -or $v -is [bool]) { return $false }
  if ($v -is [string]) { return ($v -ceq '1') }
  if ($v -is [byte] -or $v -is [int] -or $v -is [long] -or $v -is [decimal] -or $v -is [double] -or $v -is [float] -or $v -is [single]) {
    try { return (([int]$v -eq $v) -and ([double]$v -eq 1)) } catch { return $false }
  }
  return $false
}
# Depth-aware: depth-1 keys only; mark depth-1 array values. Never count nested keys.
function Get-TopLevelJsonMeta([string]$s) {
  $counts = @{}; $arrayFields = @{}
  if ([string]::IsNullOrWhiteSpace($s)) { return @{ Dup = $true; Counts = $counts; ArrayFields = $arrayFields } }
  $i = 0; $n = $s.Length; $objDepth = 0; $arrDepth = 0; $expectKey = $false
  $inStr = $false; $escape = $false; $pendingKey = $null
  while ($i -lt $n) {
    $c = $s[$i]
    if ($inStr) {
      if ($escape) { $escape = $false } elseif ($c -eq [char]92) { $escape = $true } elseif ($c -eq '"') { $inStr = $false }
      $i++; continue
    }
    if ($c -eq '"') {
      if ($objDepth -eq 1 -and $arrDepth -eq 0 -and $expectKey) {
        $i++; $start = $i
        while ($i -lt $n) {
          if ($s[$i] -eq [char]92 -and ($i + 1) -lt $n) { $i += 2; continue }
          if ($s[$i] -eq '"') { break }; $i++
        }
        $key = $s.Substring($start, [Math]::Max(0, $i - $start))
        if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
        $pendingKey = $key; $expectKey = $false
        if ($i -lt $n -and $s[$i] -eq '"') { $i++ }; continue
      }
      $inStr = $true; $i++; continue
    }
    if ($c -eq '{') { $objDepth++; $expectKey = $true; $pendingKey = $null; $i++; continue }
    if ($c -eq '}') { $objDepth--; $expectKey = $false; $pendingKey = $null; $i++; continue }
    if ($c -eq '[') {
      if ($null -ne $pendingKey -and $objDepth -eq 1 -and $arrDepth -eq 0) { $arrayFields[$pendingKey] = $true }
      $arrDepth++; $pendingKey = $null; $expectKey = $false; $i++; continue
    }
    if ($c -eq ']') { $arrDepth--; $i++; continue }
    if ($c -eq ',') { if ($objDepth -eq 1 -and $arrDepth -eq 0) { $expectKey = $true }; $pendingKey = $null; $i++; continue }
    if ($c -eq ':') { $expectKey = $false; $i++; continue }
    if ($c -notmatch '\s') { $pendingKey = $null }; $i++
  }
  $dup = $false
  foreach ($k in @($counts.Keys)) { if ($counts[$k] -gt 1 -or $k.IndexOf([char]92) -ge 0) { $dup = $true; break } }
  return @{ Dup = $dup; Counts = $counts; ArrayFields = $arrayFields }
}
function Restore-TopLevelArrays($Obj, $ArrayFields) {
  foreach ($field in $script:ArrFields) {
    if (-not $ArrayFields.ContainsKey($field)) { continue }
    $v = $Obj.$field
    if ($null -eq $v) { $Obj.$field = @() } elseif (-not ($v -is [System.Array])) { $Obj.$field = @($v) }
  }
}
function Test-ReceiptSchema($Obj) {
  if ($null -eq $Obj) { return 'null' }
  $names = @($Obj.PSObject.Properties.Name)
  foreach ($f in $script:Fields) { if ($f -notin $names) { return "missing $f" } }
  if (-not (Test-SchemaVersionOk $Obj.schema_version)) { return 'bad schema_version' }
  foreach ($sf in @('run_id', 'stage', 'model', 'observed_model')) {
    if (-not ($Obj.$sf -is [string])) { return "$sf not string" }; if ([string]::IsNullOrWhiteSpace($Obj.$sf)) { return "empty $sf" }
  }
  $sha = [string]$Obj.input_packet_sha256
  if ([string]::IsNullOrWhiteSpace($sha) -or $sha -notmatch $script:ShaRe) {
    if ([string]::IsNullOrWhiteSpace($sha)) { return 'empty sha' }; return 'bad sha'
  }
  if (-not (Test-IsBool $Obj.required)) { return 'required not bool' }
  if ([string]$Obj.status -notin $script:StatusEnum) { return 'bad status' }
  if ($null -eq (Get-ArrayField $Obj.findings)) { return 'findings not array' }
  if ($null -eq (Get-ArrayField $Obj.evidence_refs)) { return 'evidence_refs not array' }
  if ($null -eq (Get-ArrayField $Obj.output_artifacts)) { return 'output_artifacts not array' }
  foreach ($f in @($Obj.findings)) {
    if ($null -eq $f -or $f -is [string] -or $f -is [bool] -or $f -is [int] -or $f -is [long]) { return 'finding bad' }
    $fn = @($f.PSObject.Properties.Name)
    foreach ($need in @('severity', 'id', 'resolved')) { if ($need -notin $fn) { return "finding missing $need" } }
    if (-not (Test-IsBool $f.resolved)) { return 'finding resolved not bool' }
  }
  return $null
}
function Get-UnresolvedCount($Findings) {
  $n = 0
  foreach ($f in @($Findings)) {
    if ($null -eq $f) { continue }
    $sev = ''; if ($f.PSObject.Properties['severity']) { $sev = ([string]$f.severity).ToUpperInvariant() }
    $resolved = ($f.PSObject.Properties['resolved'] -and ($f.resolved -is [bool]) -and [bool]$f.resolved)
    if (-not $resolved -and ($sev -eq 'HIGH' -or $sev -eq 'CRITICAL')) { $n++ }
  }
  return $n
}
function Test-EvidenceNonEmpty($Refs) {
  foreach ($ref in @($Refs)) { if ($null -ne $ref -and -not [string]::IsNullOrWhiteSpace([string]$ref)) { return $true } }
  return $false
}
function Get-ReceiptIdentity($r) { return (([string]$r.stage) + ':' + ([string]$r.model)) }
function Test-LegitFallbackCat([string]$Cat) { return ($Cat -in $script:FallbackCats) }
function Test-StageNameOk([string]$sn) {
  if ([string]::IsNullOrWhiteSpace($sn)) { return $false }
  if ($sn -match $script:RvPrefixRe) { return [bool]($sn -match $script:RvCanonRe) }
  return $true
}
function Resolve-StageReceipt($List) {
  $arr = @($List); if ($arr.Count -eq 0) { return $null }
  $byId = @{}; $roots = New-Object System.Collections.ArrayList; $nonRoots = New-Object System.Collections.ArrayList
  foreach ($r in $arr) {
    $id = Get-ReceiptIdentity $r; if ($byId.ContainsKey($id)) { return $null }
    $byId[$id] = $r; $fb = $r.fallback_of
    if ($null -eq $fb -or [string]::IsNullOrWhiteSpace([string]$fb)) { [void]$roots.Add($r) } else { [void]$nonRoots.Add($r) }
  }
  if ($roots.Count -ne 1) { return $null }
  $root = $roots[0]; $children = @{}
  foreach ($r in @($nonRoots)) {
    $fbKey = [string]$r.fallback_of; if (-not $byId.ContainsKey($fbKey)) { return $null }
    $pred = $byId[$fbKey]
    if ([string]$pred.stage -ne [string]$r.stage) { return $null }
    if (-not (Test-LegitFallbackCat ([string]$pred.failure_category))) { return $null }
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
function New-ReduceResult([string]$Verdict, [int]$N, [int]$V, [int]$M, [int]$S, [int]$U, [bool]$UsageError = $false) {
  return [pscustomobject]@{ Verdict = $Verdict; N = $N; V = $V; M = $M; S = $S; U = $U; UsageError = $UsageError }
}

function Invoke-MergeReadinessReduce {
  param([string]$Dir, [string[]]$Required, [string[]]$Conditional, [int]$Cap)
  $fired = @(Normalize-StageList $Required); $condOnly = @(Normalize-StageList $Conditional)
  $eval = New-Object System.Collections.ArrayList; $evalSet = @{}
  foreach ($id in @($script:MandatoryStages + $fired + $condOnly)) {
    if ($evalSet.ContainsKey($id)) { continue }; $evalSet[$id] = $true; [void]$eval.Add($id)
  }
  $N = $eval.Count; $V = 0; $M = 0; $S = 0; $U = 0; $blocked = $false
  $firedSet = @{}; foreach ($fx in $fired) { $firedSet[$fx] = $true }
  $condSet = @{}; foreach ($cx in $condOnly) { $condSet[$cx] = $true }
  $mandSet = @{}; foreach ($mx in $script:MandatoryStages) { $mandSet[$mx] = $true }
  if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir -PathType Container)) {
    return (New-ReduceResult 'NOT_READY' $N 0 $N 0 0)
  }
  $groups = @{}; $tainted = @{}; $runIds = @{}; $dirInvalid = $false
  foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter '*.receipt.json' -File -ErrorAction SilentlyContinue)) {
    try {
      $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
      $meta = Get-TopLevelJsonMeta $raw; $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { $dirInvalid = $true; continue }
    if ($null -eq $obj) { $dirInvalid = $true; continue }
    $stageCount = 0; if ($meta.Counts.ContainsKey('stage')) { $stageCount = [int]$meta.Counts['stage'] }
    if ($meta.Dup -and $stageCount -ne 1) { $dirInvalid = $true; continue }
    Restore-TopLevelArrays $obj $meta.ArrayFields
    $sn = ''; if ($obj.PSObject.Properties['stage']) { $sn = [string]$obj.stage }
    if ([string]::IsNullOrWhiteSpace($sn) -or -not (Test-StageNameOk $sn)) { $dirInvalid = $true; continue }
    if ($obj.PSObject.Properties['run_id'] -and ($obj.run_id -is [string]) -and -not [string]::IsNullOrWhiteSpace($obj.run_id)) { $runIds[$obj.run_id] = $true }
    if ($meta.Dup -or $null -ne (Test-ReceiptSchema $obj)) { $tainted[$sn] = $true; continue }
    if (-not $groups.ContainsKey($sn)) { $groups[$sn] = New-Object System.Collections.ArrayList }
    [void]$groups[$sn].Add($obj)
  }
  if ($dirInvalid -or $runIds.Count -gt 1) { return (New-ReduceResult 'NOT_READY' $N 0 $N 0 0 $true) }
  foreach ($sn in @($groups.Keys)) { if ($tainted.ContainsKey($sn)) { $groups.Remove($sn) } }
  $byStage = @{}
  foreach ($sn in @($groups.Keys)) {
    $picked = Resolve-StageReceipt $groups[$sn]
    if ($null -ne $picked) { $byStage[$sn] = $picked } else { $tainted[$sn] = $true }
  }
  $shaCounts = @{}; $canonical = ''; $best = -1
  foreach ($k in @($byStage.Keys)) {
    $sha = [string]$byStage[$k].input_packet_sha256
    if ([string]::IsNullOrWhiteSpace($sha)) { continue }
    if (-not $shaCounts.ContainsKey($sha)) { $shaCounts[$sha] = 0 }
    $shaCounts[$sha]++
  }
  foreach ($sk in @($shaCounts.Keys)) { if ($shaCounts[$sk] -gt $best) { $best = $shaCounts[$sk]; $canonical = $sk } }
  $staleSet = @{}
  foreach ($k in @($byStage.Keys)) {
    $r = $byStage[$k]
    if ([string]$r.status -eq 'blocked') { $blocked = $true; $U++ }
    $uHere = Get-UnresolvedCount $r.findings
    if ($uHere -gt 0) { $U += $uHere; $blocked = $true }
    if (-not [string]::IsNullOrWhiteSpace($canonical) -and [string]$r.input_packet_sha256 -ne $canonical) {
      if (-not $staleSet.ContainsKey($k)) { $staleSet[$k] = $true; $S++ }
    }
  }
  foreach ($stage in @($eval)) {
    $mustPass = $mandSet.ContainsKey($stage) -or $firedSet.ContainsKey($stage)
    $allowNa = (-not $mustPass) -and $condSet.ContainsKey($stage)
    if ($tainted.ContainsKey($stage) -or -not $byStage.ContainsKey($stage)) { $M++; continue }
    $r = $byStage[$stage]; if ($null -ne (Test-ReceiptSchema $r)) { $M++; continue }
    $st = [string]$r.status
    if ($staleSet.ContainsKey($stage)) { continue }
    if ($mustPass) { if ($st -ne 'passed') { $M++ } else { $V++ }; continue }
    if ($allowNa) {
      if ($st -eq 'not_applicable') { if (Test-EvidenceNonEmpty $r.evidence_refs) { $V++ } else { $M++ } }
      elseif ($st -eq 'passed') { $V++ } else { $M++ }
      continue
    }
    if ($st -eq 'passed') { $V++ } else { $M++ }
  }
  foreach ($sn in @($tainted.Keys)) {
    if (-not $evalSet.ContainsKey($sn) -and $sn -notmatch $script:RvCanonRe) { $M++ }
  }
  foreach ($sn in @($byStage.Keys)) { if (($sn -notmatch $script:RvCanonRe) -and ($byStage[$sn].required -eq $true) -and (-not $evalSet.ContainsKey($sn))) { $M++ } }
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
    if ([string]::IsNullOrWhiteSpace($canonical) -or [string]$rr.input_packet_sha256 -ne $canonical -or [string]$vr.input_packet_sha256 -ne $canonical) { $M++; continue }
    if ([string]$rr.observed_model -eq [string]$vr.observed_model) { $M++; continue }
  }
  $verdict = 'READY'
  if ($blocked) { $verdict = 'BLOCKED' }
  elseif ($M -gt 0 -or $S -gt 0 -or $V -lt $N) { $verdict = 'NOT_READY' }
  return (New-ReduceResult $verdict $N $V $M $S $U)
}

function Format-MergeLine($R) {
  return "merge-readiness: $($R.Verdict) | required: $($R.N) | valid: $($R.V) | missing: $($R.M) | stale: $($R.S) | unresolved: $($R.U)"
}
function Get-ExitForVerdict([string]$V) {
  if ($V -eq 'READY') { return 0 }; if ($V -eq 'BLOCKED') { return 4 }; return 3
}
if ($SelfTest) {
  $here = $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
  $testScript = Join-Path $here 'Test-FleetMergeReadiness.ps1'
  if (-not (Test-Path -LiteralPath $testScript)) { [Console]::Error.WriteLine(('selftest: missing {0}' -f $testScript)); exit 1 }
  & $testScript; exit $LASTEXITCODE
}
if ($RoundCap -lt 1 -or $RoundCap -gt 3) { [Console]::Error.WriteLine('usage: -RoundCap must be 1..3 (hard cap 3 not caller-defeatable)'); exit 2 }
if ([string]::IsNullOrWhiteSpace($ReceiptDir)) {
  [Console]::Error.WriteLine('usage: -ReceiptDir <dir> [-RequiredStages <fired>] [-ConditionalStages <non-fired>] | -SelfTest'); exit 2
}
$result = Invoke-MergeReadinessReduce -Dir $ReceiptDir -Required $RequiredStages -Conditional $ConditionalStages -Cap $RoundCap
if ($result.UsageError) { [Console]::Error.WriteLine('usage: receipt dir invalid (parse/stage anomaly or mixed run_id)'); exit 2 }
$line = Format-MergeLine $result
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  try {
    $summary = [ordered]@{ schema_version = '1'; verdict = $result.Verdict; required = $result.N
      valid = $result.V; missing = $result.M; stale = $result.S; unresolved = $result.U; summary = $line }
    [IO.File]::WriteAllText($OutputPath, ($summary | ConvertTo-Json -Compress -Depth 4), (New-Object System.Text.UTF8Encoding $false))
  } catch { [Console]::Error.WriteLine(('usage: -OutputPath write failed: {0}' -f $_.Exception.Message)); exit 2 }
}
Write-Output $line
exit (Get-ExitForVerdict $result.Verdict)
