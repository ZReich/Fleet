# Enqueue fixed canary defects into the existing post-hoc shadow queue.
# Enqueue only: never runs a model, never grades, never sole ship gate.
# See fleet-canaries.json + fleet-policy.json auto_shadow.canary_set.
param(
  [ValidatePattern('^[A-Za-z0-9._-]+$')][string]$CanaryId,
  [string]$Seed,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId,
  [ValidatePattern('^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$')][string]$BaseSha,
  [string]$Challenger = 'terra',
  [ValidateSet('standardized_model','optimized_system')][string]$Estimand = 'optimized_system',
  [string]$CoverageScope = 'grok-eligible, no design decision, canary',
  [string]$QueueRoot = (Join-Path (Get-Location).Path '.fleet\shadow-queue'),
  [string]$PolicyPath = (Join-Path $PSScriptRoot '..\fleet-policy.json'),
  [string]$ManifestPath,
  [string]$RepoRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($CanaryId) -and [string]::IsNullOrWhiteSpace($Seed)) {
  throw "Enqueue-FleetCanary: provide -CanaryId or -Seed (deterministic selection)."
}

if (-not (Test-Path -LiteralPath $PolicyPath)) {
  throw "Enqueue-FleetCanary: policy missing: $PolicyPath"
}
try { $pol = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json } catch {
  throw "Enqueue-FleetCanary: policy unreadable: $PolicyPath"
}
$cfg = $pol.auto_shadow.canary_set
if ($null -eq $cfg) {
  throw "Enqueue-FleetCanary: auto_shadow.canary_set absent in policy (fail closed)."
}
if (-not [bool]$cfg.enabled) {
  throw "Enqueue-FleetCanary: auto_shadow.canary_set.enabled=false (refusing enqueue)."
}
$repeatCount = [int]$cfg.repeat_count
if ($repeatCount -lt 1) { throw "Enqueue-FleetCanary: invalid repeat_count=$repeatCount" }
$soleShip = [bool]$cfg.sole_ship_gate
if ($soleShip) { throw "Enqueue-FleetCanary: sole_ship_gate must be false (canary never sole ship gate)." }

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $manName = [string]$cfg.manifest
  if ([string]::IsNullOrWhiteSpace($manName)) { $manName = 'fleet-canaries.json' }
  $ManifestPath = Join-Path $RepoRoot $manName
}
if (-not (Test-Path -LiteralPath $ManifestPath)) {
  throw "Enqueue-FleetCanary: manifest missing: $ManifestPath"
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$tasks = @($manifest.tasks)
if ($tasks.Count -lt 1) { throw "Enqueue-FleetCanary: manifest has no tasks." }

function Select-CanaryBySeed([string]$S, $TaskList) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($S))
  } finally { $sha.Dispose() }
  $idx = [int]([BitConverter]::ToUInt32($hash, 0) % [uint32]$TaskList.Count)
  return $TaskList[$idx]
}

$selected = $null
if (-not [string]::IsNullOrWhiteSpace($CanaryId)) {
  $selected = @($tasks | Where-Object { [string]$_.id -eq $CanaryId }) | Select-Object -First 1
  if ($null -eq $selected) { throw "Enqueue-FleetCanary: unknown CanaryId='$CanaryId'." }
} else {
  $selected = Select-CanaryBySeed $Seed $tasks
}
$canaryId = [string]$selected.id
$stratum = [string]$selected.task_stratum
if ([string]::IsNullOrWhiteSpace($stratum)) { $stratum = 'standard' }

if ([string]::IsNullOrWhiteSpace($BaseSha)) {
  $BaseSha = (& git -C $RepoRoot rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($BaseSha)) {
    throw "Enqueue-FleetCanary: -BaseSha required (could not resolve HEAD)."
  }
  $BaseSha = $BaseSha.Trim()
}

$baseP = 0.15
if ($null -ne $pol.auto_shadow.default_p_shadow) { $baseP = [double]$pol.auto_shadow.default_p_shadow }
$dailyCap = 0
if ($null -ne $pol.auto_shadow.stratified_boost.daily_boost_cap) {
  $dailyCap = [int]$pol.auto_shadow.stratified_boost.daily_boost_cap
}

# Forced-canary provenance: same field set as Enqueue-FleetShadow -Force path.
$prov = [ordered]@{
  qualification_stratum = ''
  qualification_n_current = 0
  qualification_n_target = 0
  base_p_shadow = $baseP
  effective_p_shadow = 1.0
  boost_applied = $false
  sampling_rate_source = 'forced_canary'
  daily_boost_cap = $dailyCap
  daily_boost_used = 0
  boost_suppressed_reason = ''
}

$sampleSeed = if (-not [string]::IsNullOrWhiteSpace($Seed)) { $Seed } else { "canary:$canaryId" }
$dir = Join-Path $QueueRoot $RunId
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$queued = @()
for ($r = 1; $r -le $repeatCount; $r++) {
  $taskId = "$canaryId-r$r"
  $path = Join-Path $dir ("$taskId.json")
  if (Test-Path -LiteralPath $path) {
    $queued += [ordered]@{
      task_id = $taskId; queue_path = $path; already_queued = $true
      canary_id = $canaryId; canary_repeat = $r
    }
    continue
  }
  $entry = [ordered]@{
    schema_version = '1'
    status = 'pending'
    run_id = $RunId
    task_id = $taskId
    task_stratum = $stratum
    base_sha = $BaseSha
    packet_manifest = ''
    challenger = $Challenger
    sample_seed = $sampleSeed
    selection_probability = 1.0
    draw_value = 0.0
    estimand = $Estimand
    coverage_scope = $CoverageScope
    shadow_mode = 'post_hoc_async'
    adopted_into_run = $false
    critical_path_delay_seconds = 0
    enqueued_at = [datetimeoffset]::UtcNow.ToString('o')
    canary = $true
    canary_id = $canaryId
    canary_repeat = $r
    canary_repeat_count = $repeatCount
    sole_ship_gate = $false
  }
  foreach ($k in $prov.Keys) { $entry[$k] = $prov[$k] }
  $temp = Join-Path $dir ('.enqueue-canary-' + [guid]::NewGuid().ToString('n') + '.json')
  try {
    [IO.File]::WriteAllText($temp, ($entry | ConvertTo-Json -Depth 6), $utf8)
    [IO.File]::Move($temp, $path)
  } finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
  }
  $queued += [ordered]@{
    task_id = $taskId; queue_path = $path; already_queued = $false
    canary_id = $canaryId; canary_repeat = $r
  }
}

$out = [ordered]@{
  enqueued = $true
  canary_id = $canaryId
  canary_repeat_count = $repeatCount
  sole_ship_gate = $false
  sampling_rate_source = 'forced_canary'
  run_id = $RunId
  entries = $queued
}
foreach ($k in $prov.Keys) { $out[$k] = $prov[$k] }
Write-Output ($out | ConvertTo-Json -Depth 6 -Compress)
