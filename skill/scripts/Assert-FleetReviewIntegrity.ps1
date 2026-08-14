# REVIEW-INTEGRITY: VERIFY-SIGNATURE-FIRST + provenance. Exit 0 ok / 1 FAILED / 2 usage.
# Nothing in a receipt is trusted until HMAC verifies against the run lease key.
param(
  [Parameter(Mandatory)][string]$ReceiptDir,
  [Parameter(Mandatory)][string]$RunId,
  [string]$SpanLedger = '',
  [string]$BaseManifest = '',
  [string]$OutputManifest = '',
  [string]$ExpectedPacketSha256 = '',
  [string]$LockedPlan = '',
  [ValidateSet('text', 'json')][string]$Mode = 'text'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetReviewVoice.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Test-FleetLaneSpanRecord.ps1')

$script:HostedKeys = @('sol', 'terra', 'luna', 'opus', 'fable')
$script:OpenKeys = @('kimi', 'glm', 'grok')
$utf8 = New-Object Text.UTF8Encoding $false
function Get-Sha256File([string]$Path) { return (Get-FileSha256Hex $Path).ToLowerInvariant() }
function Test-IsInt($v) {
  if ($null -eq $v -or $v -is [bool] -or $v -is [string]) { return $false }
  if ($v -is [byte] -or $v -is [sbyte] -or $v -is [int16] -or $v -is [uint16] -or $v -is [int32] -or $v -is [uint32] -or $v -is [int64] -or $v -is [uint64] -or $v -is [int] -or $v -is [long]) { return $true }
  if ($v -is [double] -or $v -is [float] -or $v -is [single] -or $v -is [decimal]) {
    $d = [double]$v; if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $false }; return ($d -eq [math]::Floor($d))
  }
  return $false
}
function Parse-Ts([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  try { return [DateTimeOffset]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}
function Get-ReceiptModelKey($r) {
  $src = [string]$r.voice_id
  if ($r.PSObject.Properties['requested_model'] -and -not [string]::IsNullOrWhiteSpace([string]$r.requested_model)) { $src = [string]$r.requested_model }
  return (Get-VoiceModelKey $src)
}
function Format-Summary([string]$Rid,[int]$H,[int]$R,[int]$C,[string]$Verdict) { return "review-integrity: $Rid | hosted: $H | refused: $R | open-weight-failovers: $C/$R | verdict: $Verdict" }
function Write-EffectiveManifest([string]$Path,[string]$Rid,[string[]]$Lanes) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append(('{"run_id":' + (ConvertTo-Json -InputObject ([string]$Rid) -Compress) + ',"expected_lanes":['))
  $first = $true
  foreach ($id in @($Lanes)) {
    if (-not $first) { [void]$sb.Append(',') }; $first = $false
    [void]$sb.Append((ConvertTo-Json -InputObject ([string]$id) -Compress))
  }
  [void]$sb.Append(']}')
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $fs = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $b = $utf8.GetBytes($sb.ToString()); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
}
function Emit-Result([string]$Verdict,[int]$H,[int]$R,[int]$C,[string]$Message='',[string[]]$Proven=@()) {
  $summary = Format-Summary $RunId $H $R $C $Verdict
  if ($Mode -eq 'json') {
    $payload = [ordered]@{ run_id=$RunId; hosted=$H; refused=$R; covered=$C; open_weight_failovers="$C/$R"; verdict=$Verdict; summary=$summary; proven_failover_lane_ids=@($Proven) }
    if ($Message) { $payload['message'] = $Message }
    Write-Output (($payload | ConvertTo-Json -Compress -Depth 5))
  } else {
    if ($Message) { Write-Output $Message }
    Write-Output $summary
  }
}
function Test-ModelAgreement($r, $spanProp) {
  $req = ''; $obs = ''; $evidence = ''
  if ($r.PSObject.Properties['requested_model']) { $req = [string]$r.requested_model }
  if ($r.PSObject.Properties['observed_model']) { $obs = [string]$r.observed_model }
  if ($r.PSObject.Properties['model_evidence']) { $evidence = [string]$r.model_evidence }
  if ([string]::IsNullOrWhiteSpace($req) -or [string]::IsNullOrWhiteSpace($obs)) { return 'model blank' }
  $rk = Get-VoiceModelKey $req
  # EXACT allowlist (Terra M3 2026-08-11): unknown evidence values fail closed. Old names kept
  # for already-signed archived receipts; new receipts use the Sol-locked canonical values.
  $unobservableSet = @(
    'requested-pinned:codex-cli-config', 'requested-pinned:pi-provider-model', 'requested-pinned:kimi-cli-config',
    'cli-pinned-unobserved', 'requested-envelope', 'requested-cli-argument+isolated-config')
  $observableSet = @(
    'observed-provider:grok-unified-log', 'observed-envelope:claude-modelUsage',
    'unified-log', 'modelUsage')
  $unobservable = ($evidence -cin $unobservableSet)
  if (-not $unobservable -and ($evidence -cnotin $observableSet)) { return "model evidence not allowlisted: $evidence" }
  if ($unobservable) {
    if ($obs -cne 'unobserved') { return "model disagree req=$req obs=$obs" }
  } else {
    $ok = Get-VoiceModelKey $obs
    if ($rk -ne $ok) { return "model disagree req=$req obs=$obs" }
  }
  if ($null -ne $spanProp) {
    $sm = ''; if ($spanProp.PSObject.Properties['gen_ai.request.model']) { $sm = [string]$spanProp.'gen_ai.request.model' }
    if ([string]::IsNullOrWhiteSpace($sm)) { return 'span request model null' }
    if ((Get-VoiceModelKey $sm) -ne $rk) { return 'span request model disagree' }
    $srm = ''; if ($spanProp.PSObject.Properties['gen_ai.response.model']) { $srm = [string]$spanProp.'gen_ai.response.model' }
    if ([string]::IsNullOrWhiteSpace($srm)) {
      if (-not $unobservable) { return 'span response model null' }
    } elseif ((Get-VoiceModelKey $srm) -ne $rk) { return 'span response model disagree' }
  }
  return $null
}
function Read-ResultVerified($r) {
  $rp = [string]$r.result_path
  if (-not (Test-Path -LiteralPath $rp -PathType Leaf)) { return @{ Ok = $false; Err = "result missing: $rp" } }
  if ((Get-Sha256File $rp) -cne ([string]$r.result_sha256).ToLowerInvariant()) { return @{ Ok = $false; Err = ("result hash mismatch: " + [string]$r.lane_id) } }
  return @{ Ok = $true; Content = ([IO.File]::ReadAllText($rp, $utf8)); Err = '' }
}
function Test-EligibleFailover($refused, $fo) {
  if ([string]$fo.outcome -ne 'completed') { return $false }
  if (-not (Test-IsInt $fo.exit_code) -or [int]$fo.exit_code -ne 0) { return $false }
  if ((Get-ReceiptModelKey $fo) -notin $script:OpenKeys) { return $false }
  if ([string]$fo.fallback_of -ne [string]$refused.lane_id) { return $false }
  if ([string]$fo.task_id -ne [string]$refused.task_id) { return $false }
  if ([string]$fo.charter_sha256.ToLowerInvariant() -cne [string]$refused.charter_sha256.ToLowerInvariant()) { return $false }
  if ([string]$fo.input_packet_sha256.ToLowerInvariant() -cne [string]$refused.input_packet_sha256.ToLowerInvariant()) { return $false }
  if ([string]$fo.locked_plan_sha256.ToLowerInvariant() -cne [string]$refused.locked_plan_sha256.ToLowerInvariant()) { return $false }
  $tFo = Parse-Ts ([string]$fo.started_at); $tRef = Parse-Ts ([string]$refused.completed_at)
  if ($null -eq $tFo -or $null -eq $tRef -or $tFo -lt $tRef) { return $false }
  $vr = Read-ResultVerified $fo
  if (-not $vr.Ok) { return $false }
  # Softening bar on the failover completion only when the REFUSED PARENT was a security
  # review (derive from the parent receipt role, never a literal $true — a general failover
  # child must not be held to the security bar, which would deadlock the gate).
  $foSec = ([string]$refused.review_role -ceq 'security-review')
  if (-not (Test-FailoverEligible -ResultText $vr.Content -ExitCode ([int]$fo.exit_code) -DetectSoftening $foSec)) { return $false }
  return $true
}
function Test-ExactSpan($spanByLane, [string]$LaneId, $r, [bool]$ExpectRefused) {
  $n = 0; if ($spanByLane.ContainsKey($LaneId)) { $n = $spanByLane[$LaneId].Count }
  if ($n -eq 0) { return "span missing: $LaneId" }
  if ($n -ne 1) { return "span duplicate: $LaneId" }
  $span = $spanByLane[$LaneId][0]
  $st = [string]$span.status
  if ($ExpectRefused) {
    if ($st -ne 'error') { return "span status not error: $LaneId" }
  } else {
    if ($st -ne 'ok') { return "span status not ok: $LaneId" }
  }
  $merr = Test-ModelAgreement $r $span
  if ($null -ne $merr) { return "span model ${LaneId}: $merr" }
  return $null
}

if ([string]::IsNullOrWhiteSpace($RunId)) { Emit-Result 'FAILED' 0 0 0 'usage: -RunId required'; exit 2 }
if ([string]::IsNullOrWhiteSpace($SpanLedger)) { Emit-Result 'FAILED' 0 0 0 'usage: -SpanLedger required'; exit 2 }
if ([string]::IsNullOrWhiteSpace($BaseManifest)) { Emit-Result 'FAILED' 0 0 0 'usage: -BaseManifest required'; exit 2 }
if (-not [string]::IsNullOrWhiteSpace($OutputManifest)) {
  try {
    $bFull = if (Test-Path -LiteralPath $BaseManifest) { (Resolve-Path -LiteralPath $BaseManifest).Path } else { [IO.Path]::GetFullPath($BaseManifest) }
    $oFull = [IO.Path]::GetFullPath($OutputManifest)
    if ($bFull -eq $oFull) { Emit-Result 'FAILED' 0 0 0 'usage: -OutputManifest must not equal -BaseManifest'; exit 2 }
  } catch { }
}
if (-not (Test-Path -LiteralPath $ReceiptDir -PathType Container)) { Emit-Result 'FAILED' 0 0 0 "ReceiptDir missing: $ReceiptDir"; exit 1 }

# 1) Lease key from external -RunId ONLY (fail closed)
try { $leaseKey = Get-FleetRunLeaseKey -RunId $RunId }
catch { Emit-Result 'FAILED' 0 0 0 ("lease key load failed: " + $_.Exception.Message); exit 2 }
$runSecret = [byte[]]$leaseKey.KeyBytes; $leaseKeyId = [string]$leaseKey.KeyId

# Strict base manifest (immutable authority for expected_lane_manifest_sha256)
if (-not (Test-Path -LiteralPath $BaseManifest -PathType Leaf)) { Emit-Result 'FAILED' 0 0 0 "BaseManifest missing: $BaseManifest"; exit 1 }
$basePath = (Resolve-Path -LiteralPath $BaseManifest).Path
$baseSha = Get-Sha256File $basePath
try { $man = [IO.File]::ReadAllText($basePath, $utf8) | ConvertFrom-Json -ErrorAction Stop }
catch { Emit-Result 'FAILED' 0 0 0 'BaseManifest unparseable'; exit 1 }
$manRun = ''; if ($man.PSObject.Properties['run_id']) { $manRun = [string]$man.run_id }
if ($manRun -ne $RunId) { Emit-Result 'FAILED' 0 0 0 'BaseManifest run_id mismatch'; exit 1 }
if (-not $man.PSObject.Properties['expected_lanes'] -or $null -eq $man.expected_lanes) {
  Emit-Result 'FAILED' 0 0 0 'BaseManifest expected_lanes missing'; exit 1
}
$expectPkt = ''; if (-not [string]::IsNullOrWhiteSpace($ExpectedPacketSha256)) {
  $expectPkt = $ExpectedPacketSha256.ToLowerInvariant()
  if ($expectPkt -notmatch '^[0-9a-f]{64}$') { Emit-Result 'FAILED' 0 0 0 'usage: -ExpectedPacketSha256 must be 64-char hex'; exit 2 }
}
$manPkt = ''; if ($man.PSObject.Properties['packet_sha256'] -and -not [string]::IsNullOrWhiteSpace([string]$man.packet_sha256)) { $manPkt = ([string]$man.packet_sha256).ToLowerInvariant() }
if ($expectPkt -and $manPkt -and $expectPkt -cne $manPkt) { Emit-Result 'FAILED' 0 0 0 'ExpectedPacketSha256 != BaseManifest.packet_sha256'; exit 1 }
$planFileSha = ''
if (-not [string]::IsNullOrWhiteSpace($LockedPlan)) {
  if (-not (Test-Path -LiteralPath $LockedPlan -PathType Leaf)) { Emit-Result 'FAILED' 0 0 0 "LockedPlan missing: $LockedPlan"; exit 1 }
  $planFileSha = (Get-Sha256File $LockedPlan)
}
$boundPkt = $expectPkt; if (-not $boundPkt) { $boundPkt = $manPkt }
$baseLanes = New-Object System.Collections.ArrayList; $baseSeen = @{}; $rawLanes = @($man.expected_lanes)
if ($rawLanes.Count -eq 0) { Emit-Result 'FAILED' 0 0 0 'BaseManifest expected_lanes empty'; exit 1 }
foreach ($id in $rawLanes) {
  $s = [string]$id
  if ([string]::IsNullOrWhiteSpace($s)) { Emit-Result 'FAILED' 0 0 0 'BaseManifest expected_lanes blank'; exit 1 }
  if ($baseSeen.ContainsKey($s)) { Emit-Result 'FAILED' 0 0 0 "BaseManifest duplicate lane: $s"; exit 1 }
  $baseSeen[$s] = $true; [void]$baseLanes.Add($s)
}

# Span ledger (mandatory)
if (-not (Test-Path -LiteralPath $SpanLedger -PathType Leaf)) { Emit-Result 'FAILED' 0 0 0 "SpanLedger missing: $SpanLedger"; exit 1 }
$spanByLane = @{}
$lineNo = 0
foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $SpanLedger).Path, $utf8)) {
  $lineNo++
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { Emit-Result 'FAILED' 0 0 0 "unparseable span line $lineNo"; exit 1 }
  if ($null -eq $row) { continue }
  $rr = ''; $rl = ''
  if ($row.PSObject.Properties['run_id']) { $rr = [string]$row.run_id }
  if ($row.PSObject.Properties['lane_id']) { $rl = [string]$row.lane_id }
  if ($rr -ne $RunId -or [string]::IsNullOrWhiteSpace($rl)) { continue }
  try { [void](Test-FleetLaneSpanRecord $row) } catch { Emit-Result 'FAILED' 0 0 0 "malformed span lane=$rl line=$lineNo"; exit 1 }
  if (-not $spanByLane.ContainsKey($rl)) { $spanByLane[$rl] = New-Object System.Collections.ArrayList }
  [void]$spanByLane[$rl].Add($row)
}

# 2-4) Parse shape + VERIFY SIGNATURE before any semantic trust. One bad receipt => whole set FAILED.
$receipts = New-Object System.Collections.ArrayList; $byLane = @{}; $laneCounts = @{}
foreach ($file in @(Get-ChildItem -LiteralPath $ReceiptDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.result.json' } | Sort-Object FullName)) {
  if ($file.Name.StartsWith('_')) { continue }
  try { $raw = [IO.File]::ReadAllText($file.FullName, $utf8) | ConvertFrom-Json -ErrorAction Stop }
  catch { Emit-Result 'FAILED' 0 0 0 "unparseable receipt: $($file.Name)"; exit 1 }
  $obj = ConvertTo-OrderedReviewReceipt $raw
  if ($null -eq $obj) { Emit-Result 'FAILED' 0 0 0 "noncanonical receipt: $($file.Name)"; exit 1 }
  $sig = $null; if ($obj.PSObject.Properties['signature']) { $sig = [string]$obj.signature }
  $vr = Test-FleetReceiptSignature -Receipt $obj -ReceiptType 'review_lane' -RunSecret $runSecret -KeyId $leaseKeyId -Signature $sig
  if (-not $vr.ok) { Emit-Result 'FAILED' 0 0 0 "signature $($vr.reason): $($file.Name)"; exit 1 }
  # 5+) Trust fields only after HMAC ok
  if ([string]$obj.run_id -cne $RunId) { Emit-Result 'FAILED' 0 0 0 "run_id mismatch in $($file.Name)"; exit 1 }
  if ([string]$obj.key_id -cne $leaseKeyId) { Emit-Result 'FAILED' 0 0 0 "key_id mismatch in $($file.Name)"; exit 1 }
  if ([string]$obj.expected_lane_manifest_sha256 -cne $baseSha) { Emit-Result 'FAILED' 0 0 0 "expected_lane_manifest_sha256 mismatch: $($file.Name)"; exit 1 }
  # M1 packet bind + L3 plan bind (after HMAC).
  $pkt = ([string]$obj.input_packet_sha256).ToLowerInvariant()
  if ($expectPkt -and $pkt -cne $expectPkt) { Emit-Result 'FAILED' 0 0 0 "input_packet_sha256 != ExpectedPacketSha256: $($file.Name)"; exit 1 }
  if ($manPkt -and $pkt -cne $manPkt) { Emit-Result 'FAILED' 0 0 0 "input_packet_sha256 != BaseManifest.packet_sha256: $($file.Name)"; exit 1 }
  if (-not $boundPkt) { $boundPkt = $pkt } elseif ($pkt -cne $boundPkt) { Emit-Result 'FAILED' 0 0 0 "input_packet_sha256 disagree across receipts: $($file.Name)"; exit 1 }
  if ($planFileSha -and (([string]$obj.locked_plan_sha256).ToLowerInvariant() -cne $planFileSha)) { Emit-Result 'FAILED' 0 0 0 "locked_plan_sha256 mismatch: $($file.Name)"; exit 1 }
  if ([string]$obj.outcome -notin @('completed','refused')) { Emit-Result 'FAILED' 0 0 0 "bad outcome in $($file.Name)"; exit 1 }
  $merr = Test-ModelAgreement $obj $null
  if ($null -ne $merr) { Emit-Result 'FAILED' 0 0 0 "model agreement $($file.Name): $merr"; exit 1 }
  $lid = [string]$obj.lane_id
  $hasFb = ($null -ne $obj.fallback_of -and -not [string]::IsNullOrWhiteSpace([string]$obj.fallback_of))
  if (-not $hasFb -and -not $baseSeen.ContainsKey($lid)) {
    Emit-Result 'FAILED' 0 0 0 "lane_id not in base manifest: $lid"; exit 1
  }
  if ($laneCounts.ContainsKey($lid)) { Emit-Result 'FAILED' 0 0 0 "duplicate lane_id: $lid"; exit 1 }
  $laneCounts[$lid] = 1; [void]$receipts.Add($obj); $byLane[$lid] = $obj
}

$hosted = New-Object System.Collections.ArrayList
$refusedHosted = New-Object System.Collections.ArrayList
$failovers = New-Object System.Collections.ArrayList
$effectivelyRefused = @{}
foreach ($r in @($receipts)) {
  $mk = Get-ReceiptModelKey $r
  $hasFb = ($null -ne $r.fallback_of -and -not [string]::IsNullOrWhiteSpace([string]$r.fallback_of))
  if ($mk -in $script:HostedKeys -and -not $hasFb) {
    [void]$hosted.Add($r)
    $lid = [string]$r.lane_id
    $isRefused = $false
    if ([string]$r.outcome -eq 'refused') {
      $isRefused = $true
    } elseif ([string]$r.outcome -eq 'completed') {
      if (-not (Test-IsInt $r.exit_code) -or [int]$r.exit_code -ne 0) {
        Emit-Result 'FAILED' $hosted.Count 0 0 "completed hosted exit!=0: $lid"; exit 1
      }
      $vr = Read-ResultVerified $r
      if (-not $vr.Ok) { Emit-Result 'FAILED' $hosted.Count 0 0 $vr.Err; exit 1 }
      # Softening scoped to security-review receipts only (never general hosted lanes):
      # a general review in the canonical VERDICT/FINDINGS grammar must not be soft-flagged.
      $secReview = ([string]$r.review_role -ceq 'security-review')
      $chk = Test-FleetLaneRefusal -Result $vr.Content -ExitCode ([int]$r.exit_code) -IsSecuritySensitive $true -DetectSoftening $secReview
      if ($chk.refused) { $isRefused = $true }
    }
    if ($isRefused) { [void]$refusedHosted.Add($r); $effectivelyRefused[$lid] = $true }
  }
  if ($hasFb) { [void]$failovers.Add($r) }
}

$H = $hosted.Count; $R = $refusedHosted.Count
foreach ($lid in @($baseLanes)) {
  if (-not $byLane.ContainsKey($lid)) { Emit-Result 'FAILED' $H $R 0 "base lane missing receipt: $lid"; exit 1 }
  $br = $byLane[$lid]
  $expectRef = ($effectivelyRefused.ContainsKey($lid) -or [string]$br.outcome -eq 'refused')
  $serr = Test-ExactSpan $spanByLane $lid $br $expectRef
  if ($null -ne $serr) { Emit-Result 'FAILED' $H $R 0 $serr; exit 1 }
}
foreach ($fo in @($failovers)) {
  $parentId = [string]$fo.fallback_of
  if (-not $byLane.ContainsKey($parentId)) { Emit-Result 'FAILED' $H $R 0 "orphan failover: fallback_of=$parentId missing"; exit 1 }
  $parent = $byLane[$parentId]
  if ((Get-ReceiptModelKey $parent) -notin $script:HostedKeys) {
    Emit-Result 'FAILED' $H $R 0 "orphan failover: fallback_of=$parentId not hosted"; exit 1
  }
  if (-not $effectivelyRefused.ContainsKey($parentId)) {
    Emit-Result 'FAILED' $H $R 0 "orphan failover: parent $parentId not refused"; exit 1
  }
}
$C = 0; $proven = New-Object System.Collections.ArrayList; $provenSet = @{}; $refCovered = @{}
foreach ($ref in @($refusedHosted)) {
  $okOne = $false; $rid = [string]$ref.lane_id
  foreach ($fo in @($failovers)) {
    if (-not (Test-EligibleFailover $ref $fo)) { continue }
    $fid = [string]$fo.lane_id
    if ($null -ne (Test-ExactSpan $spanByLane $fid $fo $false)) { continue }
    $okOne = $true
    if (-not $provenSet.ContainsKey($fid)) { $provenSet[$fid] = $true; [void]$proven.Add($fid) }
  }
  if ($okOne) { $C++; $refCovered[$rid] = $true }
}
foreach ($sk in @($spanByLane.Keys)) {
  foreach ($sp in @($spanByLane[$sk])) {
    $et = ''; if ($sp.PSObject.Properties['error.type'] -and $null -ne $sp.'error.type') { $et = [string]$sp.'error.type' }
    if ($et -ne 'model_refusal') { continue }
    if (-not $byLane.ContainsKey($sk)) { Emit-Result 'FAILED' $H $R $C "model_refusal span no receipt: $sk"; exit 1 }
    if (-not $effectivelyRefused.ContainsKey($sk) -and [string]$byLane[$sk].outcome -ne 'refused') {
      Emit-Result 'FAILED' $H $R $C "model_refusal span receipt not refused: $sk"; exit 1
    }
    if (-not $refCovered.ContainsKey($sk)) { Emit-Result 'FAILED' $H $R $C "model_refusal span no proven failover: $sk"; exit 1 }
  }
}
$verdict = 'ok'; if ($R -gt 0 -and $C -lt $R) { $verdict = 'FAILED' }
if ($verdict -eq 'ok' -and -not [string]::IsNullOrWhiteSpace($OutputManifest)) {
  $eff = New-Object System.Collections.ArrayList; $effSeen = @{}
  foreach ($id in @(@($baseLanes) + @($proven))) {
    if ($effSeen.ContainsKey($id)) { continue }; $effSeen[$id] = $true; [void]$eff.Add($id)
  }
  try { Write-EffectiveManifest $OutputManifest $RunId @($eff) }
  catch { Emit-Result 'FAILED' $H $R $C "OutputManifest write failed: $($_.Exception.Message)"; exit 1 }
}
Emit-Result $verdict $H $R $C '' @($proven)
if ($verdict -eq 'ok') { exit 0 } else { exit 1 }
