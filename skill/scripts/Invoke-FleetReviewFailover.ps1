# Signed failover helper: verify parent receipts, dispatch fallback lanes, mint
# signed-v2 children with fallback_of, append spans, run review-integrity once.
# Design: docs/superpowers/plans/2026-08-10-fleet-fix-trustchain.md F3. PS 5.1; UTF-8 no BOM.
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId,
  [Parameter(Mandatory)][string]$FailoverPlan,
  [Parameter(Mandatory)][string]$ReceiptDir,
  [Parameter(Mandatory)][string]$BaseManifest,
  [Parameter(Mandatory)][string]$SpanLedger,
  [Parameter(Mandatory)][string]$OutputManifest,
  # Test-only dispatch overrides; production resolves source-sibling wrappers.
  [hashtable]$DispatchTable = $null,
  # JSON object map path (tests; process-safe). Overrides empty DispatchTable.
  [string]$DispatchTablePath = '',
  [string]$ScriptsRoot = '',
  [string]$SignedLanePath = ''
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetLaneRefusal.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetReviewVoice.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetFailoverClassify.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Test-FleetLaneSpanRecord.ps1')

$script:AllowTransport = @('Invoke-Grok45', 'Invoke-Opus48', 'Invoke-PiGlm', 'Invoke-KimiK3', 'Invoke-Sol')
$script:OpenVoiceKeys = @('kimi', 'glm', 'grok')
$script:HostedKeys = @('sol', 'terra', 'luna', 'opus', 'fable')

function Fail([string]$Msg) {
  [Console]::Error.WriteLine(('review-failover: {0}' -f $Msg)); exit 1
}

function Test-TestHarnessOverride {
  return (($null -ne $DispatchTable) -or -not [string]::IsNullOrWhiteSpace($DispatchTablePath) -or -not [string]::IsNullOrWhiteSpace($ScriptsRoot) -or -not [string]::IsNullOrWhiteSpace($SignedLanePath))
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
function Write-Utf8([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Quote-Arg([string]$Token) {
  if ($null -eq $Token -or $Token.Length -eq 0) { return '""' }
  if ($Token -notmatch '[\s"]') { return $Token }
  return ('"' + ($Token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"')
}
function Get-VoiceKey([string]$VoiceOrModel) {
  return (Get-VoiceModelKey $VoiceOrModel)
}
function Read-PlanRows([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail ("FailoverPlan missing: {0}" -f $Path) }
  try { $raw = [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json -ErrorAction Stop }
  catch { Fail ("FailoverPlan unparseable: {0}" -f $_.Exception.Message) }
  $rows = @()
  if ($raw -is [System.Array]) { $rows = @($raw) }
  elseif ($raw.PSObject.Properties['rows']) { $rows = @($raw.rows) }
  elseif ($raw.PSObject.Properties['plan']) { $rows = @($raw.plan) }
  else { $rows = @($raw) }
  if ($rows.Count -eq 0) { Fail 'FailoverPlan empty' }
  $out = New-Object System.Collections.ArrayList
  foreach ($r in $rows) {
    if ($null -eq $r) { continue }
    $fb = ''; $lid = ''; $vid = ''; $tx = ''
    if ($r.PSObject.Properties['fallback_of']) { $fb = [string]$r.fallback_of }
    if ($r.PSObject.Properties['lane_id']) { $lid = [string]$r.lane_id }
    if ($r.PSObject.Properties['voice_id']) { $vid = [string]$r.voice_id }
    if ($r.PSObject.Properties['transport']) { $tx = [string]$r.transport }
    foreach ($req in @(@{n='fallback_of';v=$fb},@{n='lane_id';v=$lid},@{n='voice_id';v=$vid},@{n='transport';v=$tx})) {
      if ([string]::IsNullOrWhiteSpace($req.v)) { Fail ("plan row missing {0}" -f $req.n) }
    }
    foreach ($pn in @($r.PSObject.Properties.Name)) {
      if ($pn -notin @('fallback_of', 'lane_id', 'voice_id', 'transport')) {
        Fail ("plan row unknown field: {0}" -f $pn)
      }
    }
    if (-not (Test-FleetIdGrammar $fb)) { Fail ("fallback_of grammar: {0}" -f $fb) }
    if (-not (Test-FleetIdGrammar $lid)) { Fail ("lane_id grammar: {0}" -f $lid) }
    if (-not (Test-FleetIdGrammar $vid)) { Fail ("voice_id grammar: {0}" -f $vid) }
    if ($tx -notin $script:AllowTransport) { Fail ("non-allowlisted transport: {0}" -f $tx) }
    $bind = Test-FleetVoiceTransportBinding -VoiceId $vid -Transport $tx
    if (-not $bind.Ok) { Fail $bind.Reason }
    [void]$out.Add([pscustomobject]@{ fallback_of = $fb; lane_id = $lid; voice_id = $vid; transport = $tx })
  }
  if ($out.Count -eq 0) { Fail 'FailoverPlan empty after parse' }
  return @($out)
}
function Find-ParentReceipt([string]$Dir, [string]$LaneId) {
  foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    if ($file.Name.StartsWith('_')) { continue }
    try { $obj = [IO.File]::ReadAllText($file.FullName, $utf8) | ConvertFrom-Json -ErrorAction Stop }
    catch { continue }
    if ($null -eq $obj) { continue }
    if ([string]$obj.lane_id -ceq $LaneId) { return @{ Path = $file.FullName; Obj = $obj } }
  }
  return $null
}
function New-SpanLine([string]$Rid, [string]$LaneId, [string]$Model, [string]$Status, $ErrType, [string]$RespModel) {
  $rm = $RespModel
  if ([string]::IsNullOrWhiteSpace($rm)) { $rm = $Model }
  $err = 'null'
  if ($null -ne $ErrType -and -not [string]::IsNullOrWhiteSpace([string]$ErrType)) {
    $err = (ConvertTo-Json -InputObject ([string]$ErrType) -Compress)
  }
  # Exact compact line (mirrors Test-FleetReviewIntegrity New-SpanLine; artifacts:null).
  return ('{"schema_version":"1","run_id":' + (ConvertTo-Json -InputObject $Rid -Compress) +
    ',"lane_id":' + (ConvertTo-Json -InputObject $LaneId -Compress) +
    ',"phase":"review","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"fleet","gen_ai.provider.name":"fleet"' +
    ',"gen_ai.request.model":' + (ConvertTo-Json -InputObject $Model -Compress) +
    ',"gen_ai.response.model":' + (ConvertTo-Json -InputObject $rm -Compress) +
    ',"gen_ai.usage.input_tokens":1,"gen_ai.usage.output_tokens":1,"gen_ai.usage.cache_read.input_tokens":0' +
    ',"tool_calls":0,"inference_calls":1,"duration_s":1.0,"first_result_s":0.5' +
    ',"status":' + (ConvertTo-Json -InputObject $Status -Compress) +
    ',"error.type":' + $err + ',"handoff":null,"artifacts":null}')
}
function Append-SpanRow([string]$Ledger, [string]$Line) {
  try {
    $parent = Split-Path -Parent $Ledger
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $row = $Line | ConvertFrom-Json -ErrorAction Stop
    [void](Test-FleetLaneSpanRecord $row)
    if (Test-Path -LiteralPath $Ledger -PathType Leaf) {
      foreach ($existingLine in [IO.File]::ReadAllLines($Ledger, $utf8)) {
        if ([string]::IsNullOrWhiteSpace($existingLine)) { continue }
        try { $existing = $existingLine | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ([string]$existing.run_id -eq [string]$row.run_id -and [string]$existing.lane_id -eq [string]$row.lane_id) {
          Fail ("Duplicate lane span record: $($row.run_id)/$($row.lane_id)")
        }
      }
    }
    $payload = $Line.Trim() + [Environment]::NewLine
    if (Test-Path -LiteralPath $Ledger -PathType Leaf) {
      $existingBytes = [IO.File]::ReadAllBytes($Ledger)
      if ($existingBytes.Length -gt 0) {
        $last = $existingBytes[$existingBytes.Length - 1]
        # Ensure prior content ends with newline before append (JSONL).
        if ($last -ne 10 -and $last -ne 13) {
          $payload = [Environment]::NewLine + $payload
        }
      }
    }
    [IO.File]::AppendAllText($Ledger, $payload, $utf8)
  } catch {
    Fail ("span append failed: {0}" -f $_.Exception.Message)
  }
}
function Invoke-ChildLane {
  param(
    $Row, $Parent, [string]$CharterPath, [string]$ReceiptPath, [string]$ResultPath,
    [string]$Shim, [string]$Root, [hashtable]$Table
  )
  $tx = [string]$Row.transport
  $scriptsForChild = $Root
  if ($null -ne $Table -and $Table.ContainsKey($tx)) {
    $wrapperPath = [string]$Table[$tx]
    $scriptsForChild = Split-Path -Parent $wrapperPath
    # Shim resolves Join-Path ScriptsRoot (Transport + '.ps1'); ensure basename match.
  }
  $role = 'general-review'
  if ([string]$Parent.review_role -ceq 'security-review') { $role = 'security-review' }
  $tokens = New-Object System.Collections.ArrayList
  foreach ($t in @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Shim,
      '-RunId', $RunId, '-Transport', $tx,
      '-TaskId', [string]$Parent.task_id, '-LaneId', [string]$Row.lane_id,
      '-VoiceId', [string]$Row.voice_id, '-ReviewRole', $role,
      '-CharterPath', $CharterPath,
      '-InputPacketSha256', [string]$Parent.input_packet_sha256,
      '-LockedPlanSha256', [string]$Parent.locked_plan_sha256,
      '-ExpectedLaneManifestSha256', [string]$Parent.expected_lane_manifest_sha256,
      '-ReviewProfile', [string]$Parent.review_profile,
      '-ReviewTier', [string]$Parent.review_tier,
      '-ReceiptPath', $ReceiptPath, '-ResultPath', $ResultPath,
      '-FallbackOf', [string]$Row.fallback_of,
      '-PromptFile', $CharterPath,
      '-ScriptsRoot', $scriptsForChild
    )) { [void]$tokens.Add($t) }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = (($tokens | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd()
  $null = $p.Handle; $p.WaitForExit()
  return @{ Code = [int]$p.ExitCode; Out = [string]$stdout; Err = [string]$stderr }
}

# --- validate paths ---
if ((Test-TestHarnessOverride) -and $env:FLEET_TEST_HARNESS -cne '1') { Fail 'test override refused: FLEET_TEST_HARNESS=1 is required' }
if (-not (Test-Path -LiteralPath $ReceiptDir -PathType Container)) { Fail ("ReceiptDir missing: {0}" -f $ReceiptDir) }
if (-not (Test-Path -LiteralPath $BaseManifest -PathType Leaf)) { Fail ("BaseManifest missing: {0}" -f $BaseManifest) }
if ([string]::IsNullOrWhiteSpace($ScriptsRoot)) { $ScriptsRoot = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($SignedLanePath)) { $SignedLanePath = Join-Path $PSScriptRoot 'Invoke-FleetSignedLane.ps1' }
if (-not (Test-Path -LiteralPath $SignedLanePath -PathType Leaf)) { Fail ("signed-lane shim missing: {0}" -f $SignedLanePath) }
if (($null -eq $DispatchTable -or $DispatchTable.Count -eq 0) -and -not [string]::IsNullOrWhiteSpace($DispatchTablePath)) {
  if (-not (Test-Path -LiteralPath $DispatchTablePath -PathType Leaf)) { Fail ("DispatchTablePath missing: {0}" -f $DispatchTablePath) }
  try {
    $dj = [IO.File]::ReadAllText($DispatchTablePath, $utf8) | ConvertFrom-Json -ErrorAction Stop
    $DispatchTable = @{}
    foreach ($p in @($dj.PSObject.Properties)) { $DispatchTable[[string]$p.Name] = [string]$p.Value }
  } catch { Fail ("DispatchTablePath unparseable: {0}" -f $_.Exception.Message) }
}

# Lease key first (missing key => fail closed)
try { $leaseKey = Get-FleetRunLeaseKey -RunId $RunId }
catch { Fail ("lease key load failed: {0}" -f $_.Exception.Message) }
$runSecret = [byte[]]$leaseKey.KeyBytes; $leaseKeyId = [string]$leaseKey.KeyId

$planRows = Read-PlanRows $FailoverPlan

# All-or-nothing validation before any dispatch
$byParent = @{}
$newLanes = @{}
$existingLanes = @{}
foreach ($file in @(Get-ChildItem -LiteralPath $ReceiptDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
  if ($file.Name.StartsWith('_')) { continue }
  try { $o = [IO.File]::ReadAllText($file.FullName, $utf8) | ConvertFrom-Json -ErrorAction Stop } catch { continue }
  if ($null -ne $o -and $o.PSObject.Properties['lane_id']) { $existingLanes[[string]$o.lane_id] = $true }
}
$validated = New-Object System.Collections.ArrayList
foreach ($row in $planRows) {
  $fb = [string]$row.fallback_of
  $nl = [string]$row.lane_id
  if ($newLanes.ContainsKey($nl) -or $existingLanes.ContainsKey($nl)) {
    Fail ("duplicate lane_id: {0}" -f $nl)
  }
  $newLanes[$nl] = $true
  $hit = Find-ParentReceipt $ReceiptDir $fb
  if ($null -eq $hit) { Fail ("parent receipt missing for fallback_of={0}" -f $fb) }
  $raw = $hit.Obj
  $ordered = ConvertTo-OrderedReviewReceipt $raw
  if ($null -eq $ordered) { Fail ("parent noncanonical: {0}" -f $fb) }
  $sig = ''; if ($ordered.PSObject.Properties['signature']) { $sig = [string]$ordered.signature }
  $vr = Test-FleetReceiptSignature -Receipt $ordered -ReceiptType 'review_lane' -RunSecret $runSecret -KeyId $leaseKeyId -Signature $sig
  if (-not $vr.ok) { Fail ("forged/unverifiable parent {0}: {1}" -f $fb, $vr.reason) }
  if ([string]$ordered.run_id -cne $RunId) { Fail ("parent run_id mismatch: {0}" -f $fb) }
  if ([string]$ordered.key_id -cne $leaseKeyId) { Fail ("parent key_id mismatch: {0}" -f $fb) }
  $body = ''
  $rp = [string]$ordered.result_path
  if (-not [string]::IsNullOrWhiteSpace($rp) -and (Test-Path -LiteralPath $rp -PathType Leaf)) {
    $body = [IO.File]::ReadAllText($rp, $utf8)
  }
  $kind = Get-ParentKind $ordered $body
  if ($kind -ceq 'negative') { Fail ("completed-negative-verdict parent: {0}" -f $fb) }
  if ($kind -ceq 'ineligible') { Fail ("parent not eligible for failover: {0}" -f $fb) }
  $chPath = [string]$ordered.charter_path
  if (-not (Test-Path -LiteralPath $chPath -PathType Leaf)) { Fail ("parent charter missing: {0}" -f $chPath) }
  $liveSha = Get-Sha256File $chPath
  if ($liveSha -cne ([string]$ordered.charter_sha256).ToLowerInvariant()) {
    Fail ("byte-different charter for parent {0}: live={1} signed={2}" -f $fb, $liveSha, $ordered.charter_sha256)
  }
  if (-not $byParent.ContainsKey($fb)) {
    $byParent[$fb] = [pscustomobject]@{ Parent = $ordered; Kind = $kind; Rows = (New-Object System.Collections.ArrayList) }
  } elseif ([string]$byParent[$fb].Kind -cne $kind) {
    Fail ("parent kind conflict for {0}" -f $fb)
  }
  [void]$byParent[$fb].Rows.Add($row)
  [void]$validated.Add([pscustomobject]@{ Row = $row; Parent = $ordered; Kind = $kind; CharterPath = $chPath })
}
# Refusal => both kimi+glm rows required for that parent
foreach ($pk in @($byParent.Keys)) {
  $grp = $byParent[$pk]
  if ([string]$grp.Kind -cne 'refusal') {
    if (@($grp.Rows).Count -ne 1) { Fail ("transport parent {0} requires exactly one fallback row" -f $pk) }
    continue
  }
  $keys = @{}
  foreach ($rr in @($grp.Rows)) {
    $vk = Get-VoiceKey ([string]$rr.voice_id)
    if ($vk) { $keys[$vk] = $true }
  }
  if (-not ($keys.ContainsKey('kimi') -and $keys.ContainsKey('glm'))) {
    Fail ("refusal parent {0} requires both kimi+glm plan rows" -f $pk)
  }
}

# Dispatch all validated children (paths contained under ReceiptDir)
$receiptDirFull = [IO.Path]::GetFullPath($ReceiptDir).TrimEnd('\', '/')
$childResults = New-Object System.Collections.ArrayList
foreach ($item in $validated) {
  $row = $item.Row; $parent = $item.Parent; $kind = [string]$item.Kind
  $lid = [string]$row.lane_id
  try {
    $receiptPath = Get-FleetContainedReceiptPath -ReceiptDir $receiptDirFull -LeafName ($lid + '.receipt.json')
    $resultPath = Get-FleetContainedReceiptPath -ReceiptDir $receiptDirFull -LeafName ($lid + '.result.md')
  } catch { Fail $_.Exception.Message }
  if (Test-Path -LiteralPath $receiptPath) { Fail ("child receipt already exists: {0}" -f $receiptPath) }
  $cap = Invoke-ChildLane -Row $row -Parent $parent -CharterPath ([string]$item.CharterPath) `
    -ReceiptPath $receiptPath -ResultPath $resultPath -Shim $SignedLanePath -Root $ScriptsRoot -Table $DispatchTable
  $childOk = $false
  $childModel = 'unknown'
  $childObs = 'unknown'
  if ((Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    try {
      $crec = [IO.File]::ReadAllText($receiptPath, $utf8) | ConvertFrom-Json -ErrorAction Stop
      $cord = ConvertTo-OrderedReviewReceipt $crec
      if ($null -ne $cord) {
        if ($cord.PSObject.Properties['requested_model'] -and -not [string]::IsNullOrWhiteSpace([string]$cord.requested_model)) {
          $childModel = [string]$cord.requested_model
        }
        if ($cord.PSObject.Properties['observed_model'] -and -not [string]::IsNullOrWhiteSpace([string]$cord.observed_model)) {
          $childObs = [string]$cord.observed_model
        } else { $childObs = $childModel }
        $csig = [string]$cord.signature
        $cv = Test-FleetReceiptSignature -Receipt $cord -ReceiptType 'review_lane' -RunSecret $runSecret -KeyId $leaseKeyId -Signature $csig
        if ($cv.ok -and [string]$cord.fallback_of -ceq [string]$row.fallback_of) {
          if ([string]$cord.outcome -ceq 'completed') { $childOk = $true }
        }
      }
    } catch { }
  }
  if ($childModel -eq 'unknown') {
    $vk = Get-VoiceKey ([string]$row.voice_id)
    if ($vk) { $childModel = $vk; $childObs = $vk }
  }
  # Integrity span model-key match: unobserved obs cannot be span response token.
  $spanObs = $childObs
  if ($childObs -ceq 'unobserved') { $spanObs = $childModel }
  $spanStatus = 'ok'; $errType = $null
  if (-not $childOk) { $spanStatus = 'error'; $errType = 'failover_dispatch_error' }
  $spanLine = New-SpanLine $RunId $lid $childModel $spanStatus $errType $spanObs
  Append-SpanRow $SpanLedger $spanLine
  [void]$childResults.Add([pscustomobject]@{ LaneId = $lid; Ok = $childOk; Code = [int]$cap.Code; Kind = $kind })
}

# Integrity once (base + proven failovers)
$assert = Join-Path $PSScriptRoot 'Assert-FleetReviewIntegrity.ps1'
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = ((@(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $assert,
      '-ReceiptDir', $ReceiptDir, '-RunId', $RunId,
      '-SpanLedger', $SpanLedger, '-BaseManifest', $BaseManifest,
      '-OutputManifest', $OutputManifest, '-Mode', 'text'
    ) | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$p = [Diagnostics.Process]::Start($psi)
$iOut = $p.StandardOutput.ReadToEnd(); $iErr = $p.StandardError.ReadToEnd()
$null = $p.Handle; $p.WaitForExit()
$combined = ($iOut + "`n" + $iErr).Trim()
$summary = ''
foreach ($line in ($combined -split "`r?`n")) {
  $t = $line.Trim()
  if ($t -like 'review-integrity:*') { $summary = $t; break }
}
# Re-emit full integrity stdout/stderr so callers see FAIL reason + summary line.
if (-not [string]::IsNullOrWhiteSpace($combined)) { Write-Output $combined }
elseif ($summary) { Write-Output $summary }
if ($p.ExitCode -ne 0) { exit $p.ExitCode }
exit 0
