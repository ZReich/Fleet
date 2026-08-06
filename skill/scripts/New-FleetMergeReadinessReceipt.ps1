# Emit schema v2 signed merge-stage receipt (sidecar *.receipt.json). CreateNew; refuse overwrite.
# Field order locked: references/merge-readiness.md + .fleet/sr-design.md. PS 5.1; UTF-8 no BOM.
param(
  [Parameter(Mandatory)][string]$RunId,
  [Parameter(Mandatory)][string]$TaskId,
  [Parameter(Mandatory)][string]$LaneId,
  [Parameter(Mandatory)][string]$Stage,
  [Parameter(Mandatory)][ValidateSet('true', 'false')][string]$Required,
  [Parameter(Mandatory)][ValidateSet('passed', 'not_applicable', 'blocked', 'failed', 'no_contest')][string]$Status,
  [Parameter(Mandatory)][string]$Model,
  [Parameter(Mandatory)][string]$ObservedModel,
  [Parameter(Mandatory)][string]$ModelEvidence,
  [Parameter(Mandatory)][string]$Effort,
  [Parameter(Mandatory)][string]$InputPacketSha256,
  [Parameter(Mandatory)][string]$EmitterId,
  [Parameter(Mandatory)][string]$LockedPlanSha256,
  [Parameter(Mandatory)][string]$StageSetSha256,
  [Parameter(Mandatory)][string]$ReviewTier,
  [Parameter(Mandatory)][string]$ReviewProfile,
  [Parameter(Mandatory)][string]$CharterPath,
  [Parameter(Mandatory)][string]$ResultPath,
  [Parameter(Mandatory)][string]$ResultSha256,
  [Parameter(Mandatory)][string]$CharterSha256,
  [Parameter(Mandatory)][int]$ExitCode,
  [Parameter(Mandatory)][string]$Outcome,
  [string]$FallbackOf = '',
  [string]$FailureCategory = '',
  [string]$FindingsPath = '',
  [string[]]$EvidenceRef = @(),
  [string[]]$OutputArtifact = @(),
  [Parameter(Mandatory)][string]$StartedAt,
  [Parameter(Mandatory)][string]$CompletedAt,
  [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$script:ShaRe = '^[0-9a-fA-F]{64}$'
$script:SevEnum = @('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')

function Fail([string]$Msg) {
  [Console]::Error.WriteLine(('merge-receipt: {0}' -f $Msg))
  exit 1
}
function Escape-JsonString([string]$s) {
  if ($null -eq $s) { return '""' }
  return (ConvertTo-Json -InputObject ([string]$s) -Compress)
}
function ConvertTo-FindingsJson($Items) {
  $parts = New-Object System.Collections.ArrayList
  foreach ($f in @($Items)) {
    if ($null -eq $f) { continue }
    $sev = Escape-JsonString ([string]$f.severity)
    $id = Escape-JsonString ([string]$f.id)
    $res = 'false'; if ($f.resolved -eq $true) { $res = 'true' }
    [void]$parts.Add(('{{"severity":{0},"id":{1},"resolved":{2}}}' -f $sev, $id, $res))
  }
  return ('[{0}]' -f ($parts -join ','))
}
function ConvertTo-StringArrayJson([string[]]$Items) {
  $parts = New-Object System.Collections.ArrayList
  if ($null -ne $Items) {
    foreach ($item in @($Items)) {
      if ($null -eq $item) { continue }
      [void]$parts.Add((Escape-JsonString ([string]$item)))
    }
  }
  return ('[{0}]' -f ($parts -join ','))
}
function Format-CanonTs([DateTimeOffset]$dto) {
  return ($dto.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffff', [Globalization.CultureInfo]::InvariantCulture) + 'Z')
}
function Assert-NonEmpty([string]$N, [string]$V) {
  if ([string]::IsNullOrWhiteSpace($V)) { Fail ("{0} must be nonempty" -f $N) }
}
function Assert-Sha([string]$N, [string]$V) {
  if ([string]::IsNullOrWhiteSpace($V) -or ($V -notmatch $script:ShaRe)) { Fail ("{0} must be 64-char hex" -f $N) }
}

# --- validate ---
Assert-Sha 'input_packet_sha256' $InputPacketSha256
Assert-Sha 'locked_plan_sha256' $LockedPlanSha256
Assert-Sha 'stage_set_sha256' $StageSetSha256
Assert-Sha 'result_sha256' $ResultSha256
Assert-Sha 'charter_sha256' $CharterSha256
foreach ($sf in @(
  @{ N = 'RunId'; V = $RunId }, @{ N = 'TaskId'; V = $TaskId }, @{ N = 'LaneId'; V = $LaneId },
  @{ N = 'Stage'; V = $Stage }, @{ N = 'Model'; V = $Model }, @{ N = 'ObservedModel'; V = $ObservedModel },
  @{ N = 'ModelEvidence'; V = $ModelEvidence }, @{ N = 'Effort'; V = $Effort }, @{ N = 'EmitterId'; V = $EmitterId },
  @{ N = 'ReviewTier'; V = $ReviewTier }, @{ N = 'ReviewProfile'; V = $ReviewProfile },
  @{ N = 'CharterPath'; V = $CharterPath }, @{ N = 'ResultPath'; V = $ResultPath }, @{ N = 'Outcome'; V = $Outcome }
)) { Assert-NonEmpty $sf.N $sf.V }

$findings = @()
if (-not [string]::IsNullOrWhiteSpace($FindingsPath)) {
  if (-not (Test-Path -LiteralPath $FindingsPath -PathType Leaf)) { Fail ("FindingsPath missing: {0}" -f $FindingsPath) }
  try {
    $rawFind = Get-Content -LiteralPath $FindingsPath -Raw -Encoding UTF8
    $parsed = $rawFind | ConvertFrom-Json -ErrorAction Stop
  } catch { Fail ("FindingsPath not valid JSON: {0}" -f $_.Exception.Message) }
  if ($null -eq $parsed) { $findings = @() }
  elseif ($parsed -is [System.Array]) { $findings = @($parsed) }
  else {
    if ($parsed -is [string] -or $parsed -is [bool] -or $parsed -is [int] -or $parsed -is [long]) { Fail 'findings must be a JSON array' }
    $findings = @($parsed)
  }
}
$canonFindings = New-Object System.Collections.ArrayList
foreach ($f in @($findings)) {
  if ($null -eq $f -or $f -is [string] -or $f -is [bool] -or $f -is [int] -or $f -is [long]) {
    Fail 'finding must be object with severity,id,resolved'
  }
  $fn = @($f.PSObject.Properties.Name)
  foreach ($need in @('severity', 'id', 'resolved')) {
    if ($need -notin $fn) { Fail ("finding missing {0}" -f $need) }
  }
  if (-not ($f.resolved -is [bool])) { Fail 'finding.resolved must be bool' }
  if ([string]::IsNullOrWhiteSpace([string]$f.severity) -or [string]::IsNullOrWhiteSpace([string]$f.id)) {
    Fail 'finding severity/id must be nonempty'
  }
  $sevCanon = ([string]$f.severity).Trim().ToUpperInvariant()
  if ($sevCanon -notin $script:SevEnum) { Fail ("finding severity invalid: {0}" -f $f.severity) }
  [void]$canonFindings.Add([pscustomobject][ordered]@{ severity = $sevCanon; id = [string]$f.id; resolved = [bool]$f.resolved })
}
$findings = @($canonFindings)

$startDto = $null; $endDto = $null
try { $startDto = [DateTimeOffset]::Parse($StartedAt) } catch { Fail ("StartedAt not parseable: {0}" -f $StartedAt) }
try { $endDto = [DateTimeOffset]::Parse($CompletedAt) } catch { Fail ("CompletedAt not parseable: {0}" -f $CompletedAt) }
if ($startDto -gt $endDto) { Fail 'started_at must be <= completed_at' }
$startedCanon = Format-CanonTs $startDto
$completedCanon = Format-CanonTs $endDto

$baseName = [IO.Path]::GetFileName($OutputPath)
if ([string]::IsNullOrWhiteSpace($baseName) -or -not $baseName.EndsWith('.receipt.json')) {
  Fail 'OutputPath basename must end with .receipt.json'
}

$reqBool = ($Required -eq 'true')
$pkt = $InputPacketSha256.ToLowerInvariant()
$plan = $LockedPlanSha256.ToLowerInvariant()
$ss = $StageSetSha256.ToLowerInvariant()
$rsha = $ResultSha256.ToLowerInvariant()
$csha = $CharterSha256.ToLowerInvariant()

$evRefs = New-Object System.Collections.ArrayList
foreach ($e in @($EvidenceRef)) { if ($null -ne $e) { [void]$evRefs.Add([string]$e) } }
$outArts = New-Object System.Collections.ArrayList
foreach ($a in @($OutputArtifact)) { if ($null -ne $a) { [void]$outArts.Add([string]$a) } }
$evArr = [string[]]@($evRefs)
$oaArr = [string[]]@($outArts)
$findArr = [object[]]@($findings)

$fbVal = $null
if (-not [string]::IsNullOrWhiteSpace($FallbackOf)) { $fbVal = [string]$FallbackOf }
$fcVal = $null
if (-not [string]::IsNullOrWhiteSpace($FailureCategory)) { $fcVal = [string]$FailureCategory }

# requested_model == model (exact)
$requested = [string]$Model

$receipt = [pscustomobject][ordered]@{
  schema_version = '2'
  receipt_type = 'merge_stage'
  run_id = [string]$RunId
  task_id = [string]$TaskId
  lane_id = [string]$LaneId
  stage = [string]$Stage
  required = $reqBool
  status = [string]$Status
  requested_model = $requested
  observed_model = [string]$ObservedModel
  model_evidence = [string]$ModelEvidence
  effort = [string]$Effort
  input_packet_sha256 = $pkt
  emitter_id = [string]$EmitterId
  locked_plan_sha256 = $plan
  stage_set_sha256 = $ss
  review_tier = [string]$ReviewTier
  review_profile = [string]$ReviewProfile
  charter_path = [string]$CharterPath
  result_path = [string]$ResultPath
  result_sha256 = $rsha
  charter_sha256 = $csha
  exit_code = [int64]$ExitCode
  outcome = [string]$Outcome
  fallback_of = $fbVal
  failure_category = $fcVal
  findings = $findArr
  evidence_refs = $evArr
  output_artifacts = $oaArr
  started_at = $startedCanon
  completed_at = $completedCanon
  model = $requested
  sig_alg = 'HMAC-SHA256'
}

try {
  $leaseKey = Get-FleetRunLeaseKey -RunId $RunId
} catch {
  Fail ("lease key load failed: {0}" -f $_.Exception.Message)
}
try {
  $signature = New-FleetReceiptSignature -Receipt $receipt -ReceiptType 'merge_stage' `
    -RunSecret $leaseKey.KeyBytes -KeyId $leaseKey.KeyId
} catch {
  Fail ("sign failed: {0}" -f $_.Exception.Message)
}

$reqJson = 'false'; if ($reqBool) { $reqJson = 'true' }
$fbJson = 'null'; if ($null -ne $fbVal) { $fbJson = Escape-JsonString $fbVal }
$fcJson = 'null'; if ($null -ne $fcVal) { $fcJson = Escape-JsonString $fcVal }

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('{')
[void]$sb.Append('"schema_version":"2",')
[void]$sb.Append('"receipt_type":"merge_stage",')
[void]$sb.Append('"run_id":'); [void]$sb.Append((Escape-JsonString $RunId)); [void]$sb.Append(',')
[void]$sb.Append('"task_id":'); [void]$sb.Append((Escape-JsonString $TaskId)); [void]$sb.Append(',')
[void]$sb.Append('"lane_id":'); [void]$sb.Append((Escape-JsonString $LaneId)); [void]$sb.Append(',')
[void]$sb.Append('"stage":'); [void]$sb.Append((Escape-JsonString $Stage)); [void]$sb.Append(',')
[void]$sb.Append('"required":'); [void]$sb.Append($reqJson); [void]$sb.Append(',')
[void]$sb.Append('"status":'); [void]$sb.Append((Escape-JsonString $Status)); [void]$sb.Append(',')
[void]$sb.Append('"requested_model":'); [void]$sb.Append((Escape-JsonString $requested)); [void]$sb.Append(',')
[void]$sb.Append('"observed_model":'); [void]$sb.Append((Escape-JsonString $ObservedModel)); [void]$sb.Append(',')
[void]$sb.Append('"model_evidence":'); [void]$sb.Append((Escape-JsonString $ModelEvidence)); [void]$sb.Append(',')
[void]$sb.Append('"effort":'); [void]$sb.Append((Escape-JsonString $Effort)); [void]$sb.Append(',')
[void]$sb.Append('"input_packet_sha256":'); [void]$sb.Append((Escape-JsonString $pkt)); [void]$sb.Append(',')
[void]$sb.Append('"emitter_id":'); [void]$sb.Append((Escape-JsonString $EmitterId)); [void]$sb.Append(',')
[void]$sb.Append('"locked_plan_sha256":'); [void]$sb.Append((Escape-JsonString $plan)); [void]$sb.Append(',')
[void]$sb.Append('"stage_set_sha256":'); [void]$sb.Append((Escape-JsonString $ss)); [void]$sb.Append(',')
[void]$sb.Append('"review_tier":'); [void]$sb.Append((Escape-JsonString $ReviewTier)); [void]$sb.Append(',')
[void]$sb.Append('"review_profile":'); [void]$sb.Append((Escape-JsonString $ReviewProfile)); [void]$sb.Append(',')
[void]$sb.Append('"charter_path":'); [void]$sb.Append((Escape-JsonString $CharterPath)); [void]$sb.Append(',')
[void]$sb.Append('"result_path":'); [void]$sb.Append((Escape-JsonString $ResultPath)); [void]$sb.Append(',')
[void]$sb.Append('"result_sha256":'); [void]$sb.Append((Escape-JsonString $rsha)); [void]$sb.Append(',')
[void]$sb.Append('"charter_sha256":'); [void]$sb.Append((Escape-JsonString $csha)); [void]$sb.Append(',')
[void]$sb.Append('"exit_code":'); [void]$sb.Append([string][int64]$ExitCode); [void]$sb.Append(',')
[void]$sb.Append('"outcome":'); [void]$sb.Append((Escape-JsonString $Outcome)); [void]$sb.Append(',')
[void]$sb.Append('"fallback_of":'); [void]$sb.Append($fbJson); [void]$sb.Append(',')
[void]$sb.Append('"failure_category":'); [void]$sb.Append($fcJson); [void]$sb.Append(',')
[void]$sb.Append('"findings":'); [void]$sb.Append((ConvertTo-FindingsJson $findings)); [void]$sb.Append(',')
[void]$sb.Append('"evidence_refs":'); [void]$sb.Append((ConvertTo-StringArrayJson $evArr)); [void]$sb.Append(',')
[void]$sb.Append('"output_artifacts":'); [void]$sb.Append((ConvertTo-StringArrayJson $oaArr)); [void]$sb.Append(',')
[void]$sb.Append('"started_at":'); [void]$sb.Append((Escape-JsonString $startedCanon)); [void]$sb.Append(',')
[void]$sb.Append('"completed_at":'); [void]$sb.Append((Escape-JsonString $completedCanon)); [void]$sb.Append(',')
[void]$sb.Append('"model":'); [void]$sb.Append((Escape-JsonString $requested)); [void]$sb.Append(',')
[void]$sb.Append('"sig_alg":"HMAC-SHA256",')
[void]$sb.Append('"signature":'); [void]$sb.Append((Escape-JsonString $signature))
[void]$sb.Append('}')
$payload = $sb.ToString()

$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
try {
  $fs = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $bytes = $utf8.GetBytes($payload)
    $fs.Write($bytes, 0, $bytes.Length)
  } finally { $fs.Dispose() }
} catch {
  Fail ("refuse overwrite or write failed: {0} ({1})" -f $OutputPath, $_.Exception.Message)
}
Write-Output $OutputPath
exit 0
