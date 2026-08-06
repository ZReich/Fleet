# Thin trusted signing shim: allowlisted wrappers only; derives model identity;
# signs review_lane v2. Design: .fleet/sr-design.md §4. PS 5.1; UTF-8 no BOM.
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId,
  [Parameter(Mandatory)]
  [ValidateSet('Invoke-Grok45', 'Invoke-Opus48', 'Invoke-PiGlm', 'Invoke-KimiK3', 'Invoke-Sol')]
  [string]$Transport,
  [Parameter(Mandatory)][string]$TaskId,
  [Parameter(Mandatory)][string]$LaneId,
  [Parameter(Mandatory)][string]$VoiceId,
  [Parameter(Mandatory)][ValidateSet('general-review', 'security-review')][string]$ReviewRole,
  [Parameter(Mandatory)][string]$CharterPath,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$InputPacketSha256,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$LockedPlanSha256,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedLaneManifestSha256,
  [Parameter(Mandatory)][string]$ReviewProfile,
  [Parameter(Mandatory)][string]$ReviewTier,
  [Parameter(Mandatory)][string]$ReceiptPath,
  [string]$ResultPath = '',
  [string]$Prompt = '',
  [string]$PromptFile = '',
  [string]$FallbackOf = '',
  [ValidateSet('review_lane', 'merge_stage')][string]$ReceiptType = 'review_lane',
  [string]$Stage = '',
  [string]$StageSetSha256 = '',
  [string]$ScriptsRoot = '',
  # Accepted but IGNORED — shim-derived (caller cannot forge)
  [string]$RequestedModel = '',
  [string]$ObservedModel = '',
  [string]$ModelEvidence = '',
  [string]$EmitterId = ''
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetLaneRefusal.Helpers.ps1')

function Fail([string]$Msg) {
  [Console]::Error.WriteLine(('signed-lane: {0}' -f $Msg)); exit 1
}
function Get-UtcStamp { [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
function Get-Sha256Hex([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $sb = New-Object Text.StringBuilder 64
    foreach ($x in $sha.ComputeHash($Bytes)) { [void]$sb.Append($x.ToString('x2')) }
    return $sb.ToString()
  } finally { $sha.Dispose() }
}
function Get-Sha256File([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $fs = [IO.File]::OpenRead($Path)
    try {
      $sb = New-Object Text.StringBuilder 64
      foreach ($x in $sha.ComputeHash($fs)) { [void]$sb.Append($x.ToString('x2')) }
      return $sb.ToString()
    } finally { $fs.Dispose() }
  } finally { $sha.Dispose() }
}
function Write-CreateNew([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $fs = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $b = $utf8.GetBytes($Text); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
}
function Quote-Arg([string]$Token) {
  if ($null -eq $Token -or $Token.Length -eq 0) { return '""' }
  if ($Token -notmatch '[\s"]') { return $Token }
  return ('"' + ($Token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"')
}
function Invoke-AllowlistedWrapper([string]$ScriptPath, [string]$PromptText, [string]$PromptPath) {
  $tokens = New-Object System.Collections.ArrayList
  foreach ($t in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-Mode', 'json')) {
    [void]$tokens.Add($t)
  }
  if (-not [string]::IsNullOrEmpty($PromptPath)) {
    [void]$tokens.Add('-PromptFile'); [void]$tokens.Add($PromptPath)
  } elseif (-not [string]::IsNullOrEmpty($PromptText)) {
    [void]$tokens.Add('-Prompt'); [void]$tokens.Add($PromptText)
  }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = (($tokens | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return @{ Code = [int]$p.ExitCode; Out = [string]$stdout; Err = [string]$stderr }
}
function Get-EnvelopeModelId($Envelope, [string]$Transport) {
  # Req/Obs/Ev/CanObserve — caller overrides never applied.
  $req = ''; $obs = 'unobserved'; $ev = ''; $can = $false
  if ($Transport -ceq 'Invoke-Grok45') {
    $req = 'grok-4.5'; $ev = 'unified-log'; $can = $true
    if ($Envelope -and $Envelope.PSObject.Properties['model'] -and "$($Envelope.model)") { $req = [string]$Envelope.model }
    if ($Envelope -and $Envelope.PSObject.Properties['observed_model'] -and "$($Envelope.observed_model)") {
      $obs = [string]$Envelope.observed_model
    }
  } elseif ($Transport -ceq 'Invoke-Opus48') {
    $req = 'claude-opus-5'; $ev = 'modelUsage'; $can = $true
    if ($Envelope -and $Envelope.PSObject.Properties['model'] -and "$($Envelope.model)") { $req = [string]$Envelope.model }
    if ($Envelope -and $Envelope.PSObject.Properties['observed_models'] -and $null -ne $Envelope.observed_models) {
      $list = @($Envelope.observed_models); $hit = $null
      foreach ($m in $list) {
        $ms = [string]$m
        if ($ms -ceq $req -or $ms -like ($req + '-*')) { $hit = $ms; break }
      }
      if ($null -ne $hit) { $obs = $hit } elseif ($list.Count -gt 0) { $obs = [string]$list[0] }
    }
  } elseif ($Transport -ceq 'Invoke-PiGlm') {
    $req = 'glm-5.2'; $ev = 'cli-pinned-unobserved'; $can = $false; $obs = 'unobserved'
    if ($Envelope -and $Envelope.PSObject.Properties['model'] -and "$($Envelope.model)") { $req = [string]$Envelope.model }
  } elseif ($Transport -ceq 'Invoke-KimiK3') {
    $req = 'kimi-code/k3'; $ev = 'requested-cli-argument+isolated-config'; $can = $false; $obs = 'unobserved'
    if ($Envelope -and $Envelope.PSObject.Properties['model'] -and "$($Envelope.model)") { $req = [string]$Envelope.model }
  } elseif ($Transport -ceq 'Invoke-Sol') {
    $req = 'gpt-5.6-sol'; $ev = 'requested-envelope'; $can = $false; $obs = 'unobserved'
    if ($Envelope -and $Envelope.PSObject.Properties['model_requested'] -and "$($Envelope.model_requested)") {
      $req = [string]$Envelope.model_requested
    } elseif ($Envelope -and $Envelope.PSObject.Properties['model'] -and "$($Envelope.model)") {
      $req = [string]$Envelope.model
    }
  } else { Fail ("transport not allowlisted: {0}" -f $Transport) }
  return @{ Req = $req; Obs = $obs; Ev = $ev; CanObserve = $can }
}
function Test-ModelMatch([string]$Req, [string]$Obs, [bool]$CanObserve) {
  if (-not $CanObserve) { return ($Obs -ceq 'unobserved') }
  if ($Obs -ceq 'unobserved') { return $false }
  if ($Obs -ceq $Req -or $Obs -like ($Req + '-*')) { return $true }
  return $false
}
function ConvertTo-OrderedJson($Obj) {
  $parts = New-Object System.Collections.ArrayList
  foreach ($p in $Obj.PSObject.Properties) {
    $name = ConvertTo-Json -InputObject ([string]$p.Name) -Compress
    $v = $p.Value
    if ($null -eq $v) { [void]$parts.Add(('{0}:null' -f $name)); continue }
    if ($v -is [bool]) {
      if ($v) { [void]$parts.Add(('{0}:true' -f $name)) } else { [void]$parts.Add(('{0}:false' -f $name)) }
      continue
    }
    if ($v -is [byte] -or $v -is [int16] -or $v -is [int32] -or $v -is [int64] -or $v -is [int] -or $v -is [long]) {
      [void]$parts.Add(('{0}:{1}' -f $name, [string][int64]$v)); continue
    }
    [void]$parts.Add(('{0}:{1}' -f $name, (ConvertTo-Json -InputObject ([string]$v) -Compress)))
  }
  return ('{{{0}}}' -f ($parts -join ','))
}

if ($ReceiptType -ceq 'merge_stage') {
  Fail 'merge_stage reserved (hook: New-FleetMergeReadinessReceipt); review_lane only this cut'
}
foreach ($id in @($TaskId, $LaneId, $VoiceId, $ReviewProfile, $ReviewTier, $CharterPath)) {
  if ([string]::IsNullOrWhiteSpace($id)) { Fail 'required identity/path field is blank' }
}
if (-not (Test-Path -LiteralPath $CharterPath -PathType Leaf)) { Fail ("charter missing: {0}" -f $CharterPath) }
$charterSha = Get-Sha256File $CharterPath
$root = $ScriptsRoot
if ([string]::IsNullOrWhiteSpace($root)) { $root = $PSScriptRoot }
$wrapper = Join-Path $root ($Transport + '.ps1')
if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { Fail ("wrapper missing: {0}" -f $wrapper) }
$outResult = $ResultPath
if ([string]::IsNullOrWhiteSpace($outResult)) {
  if ($ReceiptPath.EndsWith('.receipt.json')) {
    $outResult = $ReceiptPath.Substring(0, $ReceiptPath.Length - '.receipt.json'.Length) + '.result.md'
  } else { $outResult = $ReceiptPath + '.result.md' }
}

$startedAt = Get-UtcStamp
$run = Invoke-AllowlistedWrapper -ScriptPath $wrapper -PromptText $Prompt -PromptPath $PromptFile
$completedAt = Get-UtcStamp
$exitCode = [int]$run.Code
$envelope = $null
try { $envelope = $run.Out | ConvertFrom-Json -ErrorAction Stop } catch { $envelope = $null }

$id = Get-EnvelopeModelId $envelope $Transport
$reqModel = [string]$id.Req; $obsModel = [string]$id.Obs; $modelEv = [string]$id.Ev
$emitter = 'Invoke-FleetSignedLane'; $canObs = [bool]$id.CanObserve
$resultBody = ''
if ($null -ne $envelope -and $envelope.PSObject.Properties['response'] -and $null -ne $envelope.response) {
  $resultBody = [string]$envelope.response
} else { $resultBody = [string]$run.Out }
Write-CreateNew $outResult $resultBody
$resultSha = Get-Sha256Hex ($utf8.GetBytes($resultBody))

$statusOk = $false
if ($null -ne $envelope -and $envelope.PSObject.Properties['status'] -and ([string]$envelope.status -ceq 'ok')) {
  $statusOk = $true
}
$modelOk = Test-ModelMatch $reqModel $obsModel $canObs
$sec = ($ReviewRole -ceq 'security-review')
$refusal = Test-FleetLaneRefusal -Result $resultBody -ExitCode $exitCode -IsSecuritySensitive $sec
$outcome = 'failed'; $refusalReason = $null
if (-not $modelOk) { $outcome = 'failed' }
elseif ($refusal.refused) { $outcome = 'refused'; $refusalReason = [string]$refusal.reason }
elseif ($statusOk -and $exitCode -eq 0) { $outcome = 'completed' }
else { $outcome = 'failed' }

# Lease key ONLY after child exits
try { $leaseKey = Get-FleetRunLeaseKey -RunId $RunId }
catch { Fail ("lease key load failed: {0}" -f $_.Exception.Message) }
$fb = $null
if (-not [string]::IsNullOrWhiteSpace($FallbackOf)) { $fb = [string]$FallbackOf }

$o = [ordered]@{
  schema_version = '2'; receipt_type = 'review_lane'; run_id = [string]$RunId
  task_id = [string]$TaskId; lane_id = [string]$LaneId; voice_id = [string]$VoiceId
  review_role = [string]$ReviewRole; requested_model = $reqModel; observed_model = $obsModel
  model_evidence = $modelEv; emitter_id = $emitter
  input_packet_sha256 = [string]$InputPacketSha256
  expected_lane_manifest_sha256 = [string]$ExpectedLaneManifestSha256
  locked_plan_sha256 = [string]$LockedPlanSha256; review_profile = [string]$ReviewProfile
  charter_path = [string]$CharterPath; review_tier = [string]$ReviewTier
  result_path = [string]$outResult; charter_sha256 = $charterSha; result_sha256 = $resultSha
  exit_code = [int64]$exitCode; outcome = $outcome; refusal_reason = $refusalReason
  fallback_of = $fb; started_at = $startedAt; completed_at = $completedAt
  sig_alg = 'HMAC-SHA256'; key_id = [string]$leaseKey.KeyId
}
$receipt = [pscustomobject]$o
$sig = New-FleetReceiptSignature -Receipt $receipt -ReceiptType 'review_lane' -RunSecret $leaseKey.KeyBytes -KeyId $leaseKey.KeyId
$o['signature'] = $sig
Write-CreateNew $ReceiptPath (ConvertTo-OrderedJson ([pscustomobject]$o))
Write-Output $ReceiptPath
if ($outcome -ceq 'completed') { exit 0 }
exit 1
