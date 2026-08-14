# Thin trusted signing shim: allowlisted wrappers only; derives model identity;
# signs review_lane v2. Design: .fleet/sr-design.md §4. PS 5.1; UTF-8 no BOM.
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId,
  [Parameter(Mandatory)]
  [ValidateSet('Invoke-Grok45', 'Invoke-Opus48', 'Invoke-PiGlm', 'Invoke-KimiK3', 'Invoke-Sol')]
  [string]$Transport,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$TaskId,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$LaneId,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$VoiceId,
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
. (Join-Path $PSScriptRoot 'FleetReviewVoice.Helpers.ps1')

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
function Write-CreateNew([string]$Path, [string]$Text) {
  Write-FleetCreateNewAtomic -Path $Path -Text $Text -Encoding $utf8
}
function Quote-Arg([string]$Token) {
  if ($null -eq $Token -or $Token.Length -eq 0) { return '""' }
  if ($Token -notmatch '[\s"]') { return $Token }
  return ('"' + ($Token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"')
}
function Invoke-AllowlistedWrapper([string]$ScriptPath, [string]$PromptText, [string]$PromptPath, [string]$TransportName, [string]$ReceiptKind) {
  $tokens = New-Object System.Collections.ArrayList
  foreach ($t in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-Mode', 'json')) {
    [void]$tokens.Add($t)
  }
  # Grok's review contract is markdown, not the implementation JSON schema.  Keep
  # -Mode json for the transport envelope, but explicitly select its review mode.
  if ($ReceiptKind -ceq 'review_lane' -and $TransportName -ceq 'Invoke-Grok45') {
    foreach ($t in @('-Review', '-Effort', 'high', '-TimeoutSeconds', '900')) { [void]$tokens.Add($t) }
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
  # Evidence values are the Sol-locked allowlist (2026-08-11): observed-* only when the
  # transport actually reports the serving model; requested-pinned:* NEVER supports an
  # observed-model claim. Codex JSONL carries no model field on pinned 0.146.1 (probed live
  # 2026-08-11) so Sol/Terra stay requested-pinned until a captured fixture proves one.
  if ($Transport -ceq 'Invoke-Grok45') {
    $req = 'grok-4.6'; $ev = 'observed-provider:grok-unified-log'; $can = $true
    if ($Envelope -and $Envelope.PSObject.Properties['model'] -and "$($Envelope.model)") { $req = [string]$Envelope.model }
    if ($Envelope -and $Envelope.PSObject.Properties['observed_model'] -and "$($Envelope.observed_model)") {
      $obs = [string]$Envelope.observed_model
    }
  } elseif ($Transport -ceq 'Invoke-Opus48') {
    $req = 'claude-opus-5'; $ev = 'observed-envelope:claude-modelUsage'; $can = $true
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
    $req = 'glm-5.3'; $ev = 'requested-pinned:pi-provider-model'; $can = $false; $obs = 'unobserved'
    if ($Envelope -and $Envelope.PSObject.Properties['model'] -and "$($Envelope.model)") { $req = [string]$Envelope.model }
  } elseif ($Transport -ceq 'Invoke-KimiK3') {
    $req = 'kimi-code/k3'; $ev = 'requested-pinned:kimi-cli-config'; $can = $false; $obs = 'unobserved'
    if ($Envelope -and $Envelope.PSObject.Properties['model'] -and "$($Envelope.model)") { $req = [string]$Envelope.model }
  } elseif ($Transport -ceq 'Invoke-Sol') {
    $req = 'gpt-5.6-sol'; $ev = 'requested-pinned:codex-cli-config'; $can = $false; $obs = 'unobserved'
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
foreach ($id in @($TaskId, $LaneId, $VoiceId, $ReviewProfile, $ReviewTier, $CharterPath, $ReceiptPath)) {
  if ([string]::IsNullOrWhiteSpace($id)) { Fail 'required identity/path field is blank' }
}
$fb = $null
if (-not [string]::IsNullOrWhiteSpace($FallbackOf)) {
  if (-not (Test-FleetIdGrammar $FallbackOf)) { Fail ("fallback_of grammar: {0}" -f $FallbackOf) }
  $fb = [string]$FallbackOf
}
$bind = Test-FleetVoiceTransportBinding -VoiceId $VoiceId -Transport $Transport
if (-not $bind.Ok) { Fail $bind.Reason }
if (-not (Test-Path -LiteralPath $CharterPath -PathType Leaf)) { Fail ("charter missing: {0}" -f $CharterPath) }
$root = $ScriptsRoot
if ([string]::IsNullOrWhiteSpace($root)) { $root = $PSScriptRoot }
$wrapper = Join-Path $root ($Transport + '.ps1')
if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { Fail ("wrapper missing: {0}" -f $wrapper) }

# Path containment: receipt/result parents must be EXACTLY the receipt directory.
$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
$receiptDir = [IO.Path]::GetFullPath((Split-Path -Parent $receiptFull)).TrimEnd('\', '/')
try { $receiptFull = Assert-FleetPathInReceiptDir -ReceiptDir $receiptDir -TargetPath $receiptFull }
catch { Fail ("receipt path: {0}" -f $_.Exception.Message) }
$receiptLeaf = Split-Path -Leaf $receiptFull
$outResult = $ResultPath
if ([string]::IsNullOrWhiteSpace($outResult)) {
  if ($receiptLeaf.EndsWith('.receipt.json')) {
    $outResult = Join-Path $receiptDir ($receiptLeaf.Substring(0, $receiptLeaf.Length - '.receipt.json'.Length) + '.result.md')
  } else { $outResult = Join-Path $receiptDir ($receiptLeaf + '.result.md') }
}
try { $outResult = Assert-FleetPathInReceiptDir -ReceiptDir $receiptDir -TargetPath $outResult }
catch { Fail ("result path: {0}" -f $_.Exception.Message) }
# Create a dedicated, signed-lane-owned runtime directory for this run's transport
# snapshot. It is deliberately distinct from the caller-selected receipt directory.
$runtimeLeaf = '.fleet-charter-runtime-' + $RunId
try {
  $runtimeRoot = Get-FleetContainedReceiptPath -ReceiptDir $receiptDir -LeafName $runtimeLeaf
  # Check the candidate runtime root itself before New-Item can accept an existing
  # junction, then check it again as the snapshot ancestor immediately after creation.
  $null = Assert-FleetSnapshotAncestorChain -SnapshotPath $runtimeRoot -RuntimeRoot $receiptDir
  if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $runtimeRoot -ErrorAction Stop | Out-Null
  }
} catch { Fail ("snapshot runtime root: {0}" -f $_.Exception.Message) }

# Run-scoped snapshot leaf tied to receipt stem (avoids cross-lane collisions).
$snapStem = $receiptLeaf
if ($snapStem.EndsWith('.receipt.json')) {
  $snapStem = $snapStem.Substring(0, $snapStem.Length - '.receipt.json'.Length)
} elseif ($snapStem.EndsWith('.json')) {
  $snapStem = $snapStem.Substring(0, $snapStem.Length - '.json'.Length)
}
$snapLeaf = $snapStem + '.charter.snapshot'
try {
  $snapPath = Get-FleetContainedReceiptPath -ReceiptDir $runtimeRoot -LeafName $snapLeaf
  # Before creating the file, reject every existing ancestor reparse point from the
  # intended snapshot leaf through the run-scoped runtime root.
  $null = Assert-FleetSnapshotAncestorChain -SnapshotPath $snapPath -RuntimeRoot $runtimeRoot
}
catch { Fail ("snapshot path: {0}" -f $_.Exception.Message) }

$snapHold = $null
$wroteSnapshot = $false
$wroteResult = $false
$wroteReceipt = $false
try {
  $snapshot = New-FleetCharterSnapshot -SourcePath $CharterPath -SnapshotPath $snapPath -RuntimeRoot $runtimeRoot
  $wroteSnapshot = $true
  $charterSha = [string]$snapshot.CharterSha256
  $snapHold = $snapshot.Hold
  $startedAt = Get-UtcStamp
  # The wrapper re-opens PromptFile by path. Re-check every path component after the
  # held-stream hash and immediately before that external open; also require its final
  # held-stream identity to be the exact canonical path passed to the transport.
  try {
    $transportSnapshotPath = Assert-FleetSnapshotAncestorChain -SnapshotPath $snapPath -RuntimeRoot $runtimeRoot -RequireSnapshot
    $heldSnapshotPath = [IO.Path]::GetFullPath([string]$snapHold.Name)
    if ($heldSnapshotPath -cne $transportSnapshotPath) {
      throw ("held snapshot identity differs from transport path: held={0} transport={1}" -f $heldSnapshotPath, $transportSnapshotPath)
    }
  } catch { Fail ("snapshot dispatch verification: {0}" -f $_.Exception.Message) }
  # Model consumes snapshot bytes only (PromptFile overrides Prompt).
  $run = Invoke-AllowlistedWrapper -ScriptPath $wrapper -PromptText '' -PromptPath $transportSnapshotPath -TransportName $Transport -ReceiptKind $ReceiptType
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
  $wroteResult = $true
  $resultSha = Get-Sha256Hex ($utf8.GetBytes($resultBody))

  $statusOk = $false
  if ($null -ne $envelope -and $envelope.PSObject.Properties['status'] -and ([string]$envelope.status -ceq 'ok')) {
    $statusOk = $true
  }
  $deliverableOk = $statusOk
  if ($ReceiptType -ceq 'review_lane' -and $Transport -ceq 'Invoke-Grok45') {
    $deliverableOk = $statusOk -and -not [string]::IsNullOrWhiteSpace($resultBody)
  }
  $modelOk = Test-ModelMatch $reqModel $obsModel $canObs
  $sec = ($ReviewRole -ceq 'security-review')
  # Softening detection scoped to security-review role (never general): keeps the receipt
  # outcome consistent with what the integrity gate concludes, so a softened security
  # review is marked refused AT SOURCE and the failover engine dispatches for it.
  $refusal = Test-FleetLaneRefusal -Result $resultBody -ExitCode $exitCode -IsSecuritySensitive $sec -DetectSoftening $sec
  $outcome = 'failed'; $refusalReason = $null
  if (-not $modelOk) { $outcome = 'failed' }
  elseif ($refusal.refused) { $outcome = 'refused'; $refusalReason = [string]$refusal.reason }
  elseif ($deliverableOk -and $exitCode -eq 0) { $outcome = 'completed' }
  else { $outcome = 'failed' }

  # Lease key ONLY after child exits
  try { $leaseKey = Get-FleetRunLeaseKey -RunId $RunId }
  catch { Fail ("lease key load failed: {0}" -f $_.Exception.Message) }

  $o = [ordered]@{
    schema_version = '2'; receipt_type = 'review_lane'; run_id = [string]$RunId
    task_id = [string]$TaskId; lane_id = [string]$LaneId; voice_id = [string]$VoiceId
    review_role = [string]$ReviewRole; requested_model = $reqModel; observed_model = $obsModel
    model_evidence = $modelEv; emitter_id = $emitter
    input_packet_sha256 = [string]$InputPacketSha256
    expected_lane_manifest_sha256 = [string]$ExpectedLaneManifestSha256
    locked_plan_sha256 = [string]$LockedPlanSha256; review_profile = [string]$ReviewProfile
    charter_path = [string]$snapPath; review_tier = [string]$ReviewTier
    result_path = [string]$outResult; charter_sha256 = $charterSha; result_sha256 = $resultSha
    exit_code = [int64]$exitCode; outcome = $outcome; refusal_reason = $refusalReason
    fallback_of = $fb; started_at = $startedAt; completed_at = $completedAt
    sig_alg = 'HMAC-SHA256'; key_id = [string]$leaseKey.KeyId
  }
  $receipt = [pscustomobject]$o
  $sig = New-FleetReceiptSignature -Receipt $receipt -ReceiptType 'review_lane' -RunSecret $leaseKey.KeyBytes -KeyId $leaseKey.KeyId
  $o['signature'] = $sig
  Write-CreateNew $ReceiptPath (ConvertTo-OrderedJson ([pscustomobject]$o))
  $wroteReceipt = $true
  Write-Output $ReceiptPath
  if ($outcome -ceq 'completed') { exit 0 }
  exit 1
} catch {
  if ($_.Exception.Message -match '^signed-lane:') { throw }
  Fail $_.Exception.Message
} finally {
  if ($null -ne $snapHold) { $snapHold.Dispose() }
  if (-not $wroteReceipt) {
    if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) { Remove-Item -LiteralPath $ReceiptPath -Force -ErrorAction SilentlyContinue }
    if ($wroteResult -and (Test-Path -LiteralPath $outResult -PathType Leaf)) { Remove-Item -LiteralPath $outResult -Force -ErrorAction SilentlyContinue }
    if ($wroteSnapshot -and (Test-Path -LiteralPath $snapPath -PathType Leaf)) { Remove-Item -LiteralPath $snapPath -Force -ErrorAction SilentlyContinue }
  }
}
