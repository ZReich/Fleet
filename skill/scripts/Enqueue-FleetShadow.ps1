# Post-hoc auto-shadow enqueue. Runs at task completion; NEVER blocks and NEVER runs a
# model. Evaluates a reproducible seeded draw and, if sampled, appends one durable queue
# entry for Start-FleetAutoShadow.ps1 to replay off the critical path. See
# references/auto-shadow.md.
param(
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$TaskId,
  [Parameter(Mandatory)][ValidateSet('mechanical','standard','hard','review')][string]$TaskStratum,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$')][string]$BaseSha,
  [Parameter(Mandatory)][string]$Seed,
  [Parameter(Mandatory)][string]$Challenger,
  [string]$PacketManifest,
  [string]$QueueRoot = (Join-Path (Get-Location).Path '.fleet\shadow-queue'),
  [ValidateRange(0.0, 1.0)][double]$PShadow = 0.15,
  [ValidateSet('standardized_model','optimized_system')][string]$Estimand = 'optimized_system',
  [string]$CoverageScope = 'grok-eligible, no design decision',
  [string]$PolicyPath = '',
  [string]$LedgerRoot = '',
  [ValidateSet('generic','k3_full_review','opus5_pair')][string]$JobKind = 'generic',
  # Frozen task snapshot for self-contained replay. Empty/null = legacy entry
  # (consumer terminal deferred_no_spec). Packet mutation after enqueue cannot
  # affect replay when these are present.
  [string]$TaskSpecJson = '',
  [string]$PrimaryLane = '',
  [string]$PrimaryWallSeconds = '',
  [string]$PacketSha256 = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
# PS5.1: $PSScriptRoot is empty in param() defaults when any [Parameter()] attribute
# is present; resolve script-relative defaults here instead.
if ([string]::IsNullOrEmpty($PolicyPath)) { $PolicyPath = Join-Path $PSScriptRoot '..\fleet-policy.json' }
if ([string]::IsNullOrEmpty($LedgerRoot)) { $LedgerRoot = Join-Path $PSScriptRoot '..' }
$explicitP = $PSBoundParameters.ContainsKey('PShadow')
$utf8 = New-Object Text.UTF8Encoding($false)

function Get-LedgerCount([string]$LedgerPath, [string]$Source) {
  if (-not (Test-Path -LiteralPath $LedgerPath)) { return @{ ok = $true; n = 0 } }
  $n = 0
  try {
    foreach ($line in [IO.File]::ReadAllLines($LedgerPath, $utf8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $row = $line | ConvertFrom-Json } catch { return @{ ok = $false; n = 0; reason = "malformed_ledger:$([IO.Path]::GetFileName($LedgerPath))" } }
      if ($Source -eq 'dispatched_full_rows') {
        if ($row.dispatched -eq $true -and [string]$row.review_tier -eq 'FULL') { $n++ }
      } elseif ($Source -eq 'valid_rows') { $n++ }
      else { return @{ ok = $false; n = 0; reason = "unknown_n_current_source:$Source" } }
    }
  } catch { return @{ ok = $false; n = 0; reason = "malformed_ledger:$([IO.Path]::GetFileName($LedgerPath))" } }
  return @{ ok = $true; n = $n }
}

function Get-DailyBoostUsed([string]$Root) {
  $used = 0
  if (-not (Test-Path -LiteralPath $Root)) { return 0 }
  $today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
  foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    try {
      $e = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
      if ($e.boost_applied -ne $true) { continue }
      if ([string]::IsNullOrWhiteSpace([string]$e.enqueued_at)) { continue }
      $dto = [datetimeoffset]::Parse([string]$e.enqueued_at)
      if ($dto.UtcDateTime.ToString('yyyy-MM-dd') -eq $today) { $used++ }
    } catch { }
  }
  return $used
}

function Get-QueueMutexName([string]$Root) {
  $full = [IO.Path]::GetFullPath($Root)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full.ToUpperInvariant()))).Replace('-', '').Substring(0, 24)
  } finally { $sha.Dispose() }
  return "Global\CodexFleetShadowQueue-$hash"
}

# Reproducible draw in [0,1): stable hash of seed|task, no Math.random (resumable).
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Seed|$TaskId")) } finally { $sha.Dispose() }
$draw = [double]([BitConverter]::ToUInt32($hash, 0)) / [uint32]::MaxValue

$baseP = 0.15
$boostCfg = $null
if (Test-Path -LiteralPath $PolicyPath) {
  try {
    $pol = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json
    if ($null -ne $pol.auto_shadow.default_p_shadow) { $baseP = [double]$pol.auto_shadow.default_p_shadow }
    $boostCfg = $pol.auto_shadow.stratified_boost
  } catch { }
}
if (-not $explicitP) { $PShadow = $baseP }

$dailyCap = 0
$dailyUsed = 0
$qStratum = ''
$qN = 0
$qTarget = 0
$boostApplied = $false
$rateSource = 'base_rate'
$suppress = ''
$effectiveP = $baseP
$under = $null
$anyUnder = $false
$malReason = ''
$malForKind = ''

# Serialize daily-cap count, boost decision, idempotency check, and queue publish.
$mutex = [Threading.Mutex]::new($false, (Get-QueueMutexName $QueueRoot))
$gotLock = $false
try {
  if (-not $mutex.WaitOne(30000)) { throw 'Timed out waiting for shadow queue lock' }
  $gotLock = $true

  if ($null -ne $boostCfg) {
    $dailyCap = [int]$boostCfg.daily_boost_cap
    $dailyUsed = Get-DailyBoostUsed $QueueRoot
    foreach ($s in @($boostCfg.strata)) {
      $sKind = [string]$s.job_kind
      $kindMatch = ($sKind -eq $JobKind)
      $lp = Join-Path $LedgerRoot ([string]$s.ledger)
      $c = Get-LedgerCount $lp ([string]$s.n_current_source)
      if (-not $c.ok) {
        if ([string]::IsNullOrEmpty($malReason)) { $malReason = [string]$c.reason }
        if ($kindMatch -and [string]::IsNullOrEmpty($malForKind)) { $malForKind = [string]$c.reason }
        if ($kindMatch -and [string]::IsNullOrEmpty($qStratum)) {
          $qStratum = [string]$s.name; $qN = 0; $qTarget = [int]$s.n_target
        }
        continue
      }
      $isUnder = ([int]$c.n -lt [int]$s.n_target)
      if ($isUnder) { $anyUnder = $true }
      if ($kindMatch) {
        if ($null -eq $under -and $isUnder) {
          $under = $s; $qStratum = [string]$s.name; $qN = [int]$c.n; $qTarget = [int]$s.n_target
        } elseif ([string]::IsNullOrEmpty($qStratum)) {
          $qStratum = [string]$s.name; $qN = [int]$c.n; $qTarget = [int]$s.n_target
        }
      } elseif ([string]::IsNullOrEmpty($qStratum) -and $isUnder) {
        $qStratum = [string]$s.name; $qN = [int]$c.n; $qTarget = [int]$s.n_target
      }
    }
  }

  if ($Force) {
    $effectiveP = 1.0
    $rateSource = 'forced_canary'
    $suppress = ''
  } elseif ($explicitP) {
    $effectiveP = $PShadow
    $rateSource = 'base_rate'
    $suppress = 'explicit_override'
  } elseif ($null -eq $boostCfg -or -not [bool]$boostCfg.enabled) {
    $effectiveP = $baseP
    $rateSource = 'base_rate'
    if ($null -ne $boostCfg -and -not [bool]$boostCfg.enabled) { $suppress = 'stratified_boost_disabled' }
  } elseif ($null -ne $under -and $dailyUsed -lt $dailyCap) {
    $effectiveP = 1.0
    $boostApplied = $true
    $rateSource = 'stratified_boost'
    $suppress = $malReason
  } else {
    $effectiveP = $baseP
    $rateSource = 'base_rate'
    if ($null -ne $under -and $dailyUsed -ge $dailyCap) { $suppress = 'daily_boost_cap' }
    elseif ($null -eq $under -and -not [string]::IsNullOrEmpty($malForKind)) { $suppress = $malForKind }
    elseif ($null -eq $under -and $anyUnder) { $suppress = 'job_kind_ineligible' }
    elseif ($null -eq $under -and -not [string]::IsNullOrEmpty($malReason)) { $suppress = $malReason }
  }

  $sampled = $Force -or ($draw -le $effectiveP)
  $prov = [ordered]@{
    qualification_stratum = $qStratum
    qualification_n_current = $qN
    qualification_n_target = $qTarget
    qualification_job_kind = $JobKind
    base_p_shadow = $baseP
    effective_p_shadow = $effectiveP
    boost_applied = $boostApplied
    sampling_rate_source = $rateSource
    daily_boost_cap = $dailyCap
    daily_boost_used = $dailyUsed
    boost_suppressed_reason = $suppress
  }

  if (-not $sampled) {
    $out = [ordered]@{ sampled = $false; draw_value = [math]::Round($draw, 6); shadow_skipped_reason = 'not_drawn'; task_id = $TaskId }
    foreach ($k in $prov.Keys) { $out[$k] = $prov[$k] }
    Write-Output ($out | ConvertTo-Json -Compress)
    return
  }

  $dir = Join-Path $QueueRoot $RunId
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $path = Join-Path $dir ("$TaskId.json")
  # Append-only / idempotent: a task is enqueued at most once per run.
  if (Test-Path -LiteralPath $path) {
    $out = [ordered]@{ sampled = $true; draw_value = [math]::Round($draw, 6); queue_path = $path; already_queued = $true; task_id = $TaskId }
    foreach ($k in $prov.Keys) { $out[$k] = $prov[$k] }
    Write-Output ($out | ConvertTo-Json -Compress)
    return
  }
  # Snapshot task_spec / primary / packet hash so later packet moves cannot alter replay.
  $taskSpec = $null
  if (-not [string]::IsNullOrWhiteSpace($TaskSpecJson)) {
    try { $taskSpec = $TaskSpecJson | ConvertFrom-Json } catch { throw "TaskSpecJson is not valid JSON: $($_.Exception.Message)" }
    foreach ($req in @('id','prompt','allowed_paths','gate_commands')) {
      if (-not $taskSpec.PSObject.Properties[$req] -or $null -eq $taskSpec.$req) { throw "TaskSpecJson missing required field: $req" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$taskSpec.id) -or [string]::IsNullOrWhiteSpace([string]$taskSpec.prompt)) {
      throw 'TaskSpecJson id and prompt must be non-empty'
    }
    if (@($taskSpec.allowed_paths).Count -lt 1) { throw 'TaskSpecJson allowed_paths must be non-empty' }
    # Fail closed at publish: TaskSpecJson requires primary_lane + primary_wall_seconds > 0.
    if ([string]::IsNullOrWhiteSpace($PrimaryLane)) { throw 'PrimaryLane is required when TaskSpecJson is supplied' }
    if ([string]::IsNullOrWhiteSpace($PrimaryWallSeconds)) { throw 'PrimaryWallSeconds is required when TaskSpecJson is supplied' }
  }
  $primaryLaneSnap = if ([string]::IsNullOrWhiteSpace($PrimaryLane)) { $null } else { [string]$PrimaryLane }
  $primaryWallSnap = $null
  if (-not [string]::IsNullOrWhiteSpace($PrimaryWallSeconds)) {
    $pw = 0
    if (-not [int]::TryParse([string]$PrimaryWallSeconds, [ref]$pw) -or $pw -le 0) {
      throw "PrimaryWallSeconds must be a positive integer (> 0), got: $PrimaryWallSeconds"
    }
    $primaryWallSnap = $pw
  }
  if ($null -ne $taskSpec -and ($null -eq $primaryLaneSnap -or $null -eq $primaryWallSnap -or $primaryWallSnap -le 0)) {
    throw 'primary_lane and primary_wall_seconds (> 0) required when TaskSpecJson is supplied'
  }
  $packetHashSnap = $null
  if (-not [string]::IsNullOrWhiteSpace($PacketSha256)) {
    if ($PacketSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "PacketSha256 must be 64 hex chars" }
    $packetHashSnap = $PacketSha256.ToLowerInvariant()
  } elseif (-not [string]::IsNullOrWhiteSpace($PacketManifest) -and (Test-Path -LiteralPath $PacketManifest -PathType Leaf)) {
    $packetHashSnap = (Get-FileHash -LiteralPath $PacketManifest -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $entry = [ordered]@{
    schema_version = '1'
    status = 'pending'
    run_id = $RunId
    task_id = $TaskId
    task_stratum = $TaskStratum
    base_sha = $BaseSha
    packet_manifest = $PacketManifest
    challenger = $Challenger
    sample_seed = $Seed
    selection_probability = $effectiveP
    draw_value = [math]::Round($draw, 6)
    estimand = $Estimand
    coverage_scope = $CoverageScope
    shadow_mode = 'post_hoc_async'
    adopted_into_run = $false
    critical_path_delay_seconds = 0
    qualification_job_kind = $JobKind
    task_spec = $taskSpec
    primary_lane = $primaryLaneSnap
    primary_wall_seconds = $primaryWallSnap
    packet_sha256 = $packetHashSnap
    canary = $false
    canary_id = $null
    canary_repeat = $null
    canary_repeat_count = $null
    sole_ship_gate = $null
    enqueued_at = [datetimeoffset]::UtcNow.ToString('o')
  }
  foreach ($k in $prov.Keys) { $entry[$k] = $prov[$k] }
  $temp = Join-Path $dir ('.enqueue-' + [guid]::NewGuid().ToString('n') + '.json')
  try {
    [IO.File]::WriteAllText($temp, ($entry | ConvertTo-Json -Depth 6), $utf8)
    [IO.File]::Move($temp, $path)
  }
  finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
  $out = [ordered]@{ sampled = $true; draw_value = [math]::Round($draw, 6); queue_path = $path; task_id = $TaskId }
  foreach ($k in $prov.Keys) { $out[$k] = $prov[$k] }
  Write-Output ($out | ConvertTo-Json -Compress)
}
finally {
  if ($gotLock) { try { $mutex.ReleaseMutex() } catch { } }
  $mutex.Dispose()
}
