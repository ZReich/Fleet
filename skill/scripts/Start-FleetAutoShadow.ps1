# Post-hoc auto-shadow consumer. Runs OFF the critical path (own run-lease, detached
# worktree) and replays queued shadows against the frozen base. Guards base_drift and
# writes v8 rows to BENCH-shadow.jsonl. `critical_path_delay_seconds` is always 0 for
# these rows. See references/auto-shadow.md.
param(
  [Parameter(Mandatory)][string]$QueueRoot,
  [Parameter(Mandatory)][string]$RepoRoot,
  [ValidateRange(1, 1000)][int]$MaxItems = 50,
  [string]$LedgerPath = '',
  [string]$LedgerRoot = '',
  # Process mechanics without invoking models (queue/drift/ledger only). The live
  # path calls Invoke-ShadowReplay.ps1 (lane-spec wrappers; tests inject fakes).
  [switch]$NoModel,
  # Offline/test injection: JSON completion record(s) accepted in place of live replay.
  # Shape: {task_id, kind, success, wall_seconds} or array / {completions:[...]}.
  [string]$InjectedCompletionPath = '',
  # Optional lane-spec JSON for Invoke-ShadowReplay (tests inject fake wrappers).
  [string]$LaneSpecPath = ''
)

$ErrorActionPreference = 'Stop'
# PS5.1: $PSScriptRoot is empty in param() defaults when any [Parameter()] attribute
# is present; resolve script-relative defaults here instead.
if ([string]::IsNullOrEmpty($LedgerPath)) { $LedgerPath = Join-Path $PSScriptRoot '..\BENCH-shadow.jsonl' }
if ([string]::IsNullOrEmpty($LedgerRoot)) { $LedgerRoot = Join-Path $PSScriptRoot '..' }
$utf8 = New-Object Text.UTF8Encoding($false)
$processed = @()
$recK3 = Join-Path $PSScriptRoot 'Record-K3Qualification.ps1'
$recOpus = Join-Path $PSScriptRoot 'Record-Opus5Pair.ps1'

function Add-LedgerRow($row) {
  $dir = Split-Path -Parent $LedgerPath
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $line = ($row | ConvertTo-Json -Depth 8 -Compress)
  # Append-only, serialized by a short retry loop on the shared file.
  for ($i = 0; $i -lt 20; $i++) {
    try { $fs = [IO.File]::Open($LedgerPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read); try { $bytes = $utf8.GetBytes($line + "`n"); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }; return } catch { Start-Sleep -Milliseconds 50 }
  }
  throw "Could not append to shadow ledger: $LedgerPath"
}

function Write-QualificationTrack($entry, $completion) {
  # Qualification ledgers increment ONLY for real successful matching work.
  # NoModel, deferred, excluded, base_drift, deferred_no_spec, non-success must never reach here.
  if ($null -eq $completion) { return }
  $success = $false
  if ($completion.PSObject.Properties['success'] -and $true -eq $completion.success) { $success = $true }
  if (-not $success) { return }
  $kind = [string]$entry.qualification_job_kind
  if ([string]::IsNullOrWhiteSpace($kind) -or $kind -eq 'generic') { return }
  $cKind = ''
  if ($completion.PSObject.Properties['kind']) { $cKind = [string]$completion.kind }
  elseif ($completion.PSObject.Properties['qualification_job_kind']) { $cKind = [string]$completion.qualification_job_kind }
  if ($cKind -ne $kind) { return }
  if (-not $completion.PSObject.Properties['wall_seconds']) { return }
  if ($null -eq $completion.wall_seconds -or "$($completion.wall_seconds)" -eq '') { return }
  $wall = [int]$completion.wall_seconds
  $date = [datetime]::UtcNow.ToString('yyyy-MM-dd')
  $rid = ([string]$entry.run_id) + '-' + ([string]$entry.task_id)
  if ($kind -eq 'k3_full_review') {
    $lp = Join-Path $LedgerRoot 'BENCH-k3-qualification.jsonl'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recK3 -RunId $rid -Date $date -ReviewTier FULL -Dispatched true -WallSeconds $wall -VerdictSummary 'auto-shadow' -LedgerPath $lp
    if ($LASTEXITCODE -ne 0) { throw "Record-K3Qualification.ps1 failed for $rid (exit $LASTEXITCODE)" }
  } elseif ($kind -eq 'opus5_pair') {
    $lp = Join-Path $LedgerRoot 'BENCH-opus5-pairs.jsonl'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recOpus -PairId $rid -Date $date -Dispatched true -WallSeconds $wall -LedgerPath $lp
    if ($LASTEXITCODE -ne 0) { throw "Record-Opus5Pair.ps1 failed for $rid (exit $LASTEXITCODE)" }
  }
}

function Get-QueueMutexName([string]$Root) {
  $full = [IO.Path]::GetFullPath($Root); $sha = [Security.Cryptography.SHA256]::Create()
  try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full.ToUpperInvariant()))).Replace('-', '').Substring(0, 24) }
  finally { $sha.Dispose() }
  return "Global\CodexFleetShadowQueue-$hash"
}

function Resolve-InjectedCompletion($entry) {
  if ([string]::IsNullOrWhiteSpace($InjectedCompletionPath)) { return $null }
  # Test seam only: InjectedCompletionPath requires $env:FLEET_SHADOW_TEST_INJECT=1; else refused + warned (B6).
  if ($env:FLEET_SHADOW_TEST_INJECT -ne '1') { $script:injectedCompletionRefused = $true; return $null }
  if (-not (Test-Path -LiteralPath $InjectedCompletionPath -PathType Leaf)) { return $null }
  try { $inj = Get-Content -LiteralPath $InjectedCompletionPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  $candidates = @()
  if ($inj -is [System.Array]) { $candidates = @($inj) }
  elseif ($inj.PSObject.Properties['completions'] -and $null -ne $inj.completions) { $candidates = @($inj.completions) }
  else { $candidates = @($inj) }
  $tid = [string]$entry.task_id
  foreach ($c in $candidates) {
    if ($null -eq $c) { continue }
    $cTid = if ($c.PSObject.Properties['task_id']) { [string]$c.task_id } else { '' }
    if ([string]::IsNullOrWhiteSpace($cTid) -or $cTid -eq $tid) { return $c }
  }
  return $null
}

function Set-EntryStatus([string]$Path, $EntryObj, [string]$Status) {
  $EntryObj.status = $Status; [IO.File]::WriteAllText($Path, ($EntryObj | ConvertTo-Json -Depth 8), $utf8)
}

function Claim-QueueEntry([string]$Path) {
  # Atomically mark pending -> in_flight under Global mutex; reject duplicate claim.
  $mutex = New-Object System.Threading.Mutex($false, (Get-QueueMutexName $QueueRoot)); $got = $false
  try {
    if (-not $mutex.WaitOne(30000)) { throw 'Timed out waiting for shadow queue claim lock' }
    $got = $true
    try { $e = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
    if ([string]$e.status -ne 'pending') { return $null } # duplicate: already claimed/processed
    Set-EntryStatus $Path $e 'in_flight'; return $e
  } finally {
    if ($got) { try { $mutex.ReleaseMutex() } catch { } }; $mutex.Dispose()
  }
}

$injectedCompletionRefused = $false
if (-not (Test-Path -LiteralPath $QueueRoot)) {
  Write-Output (@{ processed = @(); note = 'no queue'; injected_completion_refused = $false } | ConvertTo-Json -Compress); return
}

$entries = @(Get-ChildItem -LiteralPath $QueueRoot -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First $MaxItems)
foreach ($file in $entries) {
  $entry = Claim-QueueEntry $file.FullName
  if ($null -eq $entry) { continue }

  # base_drift guard: never grade against a base that moved out of the repo.
  $baseOk = $false
  try { & git -C $RepoRoot cat-file -e ("{0}^{{commit}}" -f [string]$entry.base_sha) 2>$null; $baseOk = ($LASTEXITCODE -eq 0) } catch { $baseOk = $false }

  $row = [ordered]@{
    schema_version = '8'
    ledger = 'shadow'
    run_id = [string]$entry.run_id
    task_id = [string]$entry.task_id
    task_stratum = [string]$entry.task_stratum
    challenger = [string]$entry.challenger
    estimand = [string]$entry.estimand
    coverage_scope = [string]$entry.coverage_scope
    shadow_mode = 'post_hoc_async'
    sample_seed = [string]$entry.sample_seed
    selection_probability = $entry.selection_probability
    qualification_stratum = $entry.qualification_stratum
    qualification_n_current = $entry.qualification_n_current
    qualification_n_target = $entry.qualification_n_target
    qualification_job_kind = $entry.qualification_job_kind
    base_p_shadow = $entry.base_p_shadow
    effective_p_shadow = $entry.effective_p_shadow
    boost_applied = $entry.boost_applied
    sampling_rate_source = $entry.sampling_rate_source
    daily_boost_cap = $entry.daily_boost_cap
    daily_boost_used = $entry.daily_boost_used
    boost_suppressed_reason = $entry.boost_suppressed_reason
    canary = $(if ($null -eq $entry.canary) { $false } else { [bool]$entry.canary })
    canary_id = $entry.canary_id
    canary_repeat = $entry.canary_repeat
    canary_repeat_count = $entry.canary_repeat_count
    sole_ship_gate = $entry.sole_ship_gate
    adopted_into_run = $false
    critical_path_delay_seconds = 0
    base_drift = (-not $baseOk)
    graded_at = [datetimeoffset]::Now.ToString('o')
  }

  if (-not $baseOk) {
    $row.status = 'excluded'; $row.exclusion_reason = 'base_drift'
    Add-LedgerRow $row; Set-EntryStatus $file.FullName $entry 'excluded'
    $processed += @{ task_id = $row.task_id; outcome = 'excluded_base_drift' }; continue
  }

  if ($NoModel) {
    $row.status = 'deferred_no_model'
    Add-LedgerRow $row; Set-EntryStatus $file.FullName $entry 'processed_dry'
    $processed += @{ task_id = $row.task_id; outcome = 'deferred_no_model' }; continue
  }

  $hasSpec = $false
  if ($entry.PSObject.Properties['task_spec'] -and $null -ne $entry.task_spec) {
    $ts = $entry.task_spec
    if ($ts.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$ts.id) -and
        $ts.PSObject.Properties['prompt'] -and -not [string]::IsNullOrWhiteSpace([string]$ts.prompt) -and
        $ts.PSObject.Properties['allowed_paths'] -and @($ts.allowed_paths).Count -gt 0) { $hasSpec = $true }
  }
  $laneOk = $entry.PSObject.Properties['primary_lane'] -and -not [string]::IsNullOrWhiteSpace([string]$entry.primary_lane)
  $primaryWall = 0
  if ($entry.PSObject.Properties['primary_wall_seconds'] -and $null -ne $entry.primary_wall_seconds -and "$($entry.primary_wall_seconds)" -ne '') {
    try { $primaryWall = [int]$entry.primary_wall_seconds } catch { $primaryWall = 0 }
  }
  $wallOk = $true; if ($primaryWall -le 0) { $wallOk = $false }
  # Spec present but primary_lane/wall missing or wall incomplete => terminal deferred_no_spec (never live/inject).
  if ($hasSpec -and (-not $laneOk -or -not $wallOk)) {
    $row.status = 'deferred_no_spec'; Add-LedgerRow $row; Set-EntryStatus $file.FullName $entry 'processed_deferred'
    $processed += @{ task_id = $row.task_id; outcome = 'deferred_no_spec' }; continue
  }

  $completion = Resolve-InjectedCompletion $entry
  if ($null -ne $completion -and $completion.PSObject.Properties['success'] -and $true -eq $completion.success) {
    $row.status = 'graded'
    if ($completion.PSObject.Properties['wall_seconds']) { $row.wall_seconds = $completion.wall_seconds }
    Add-LedgerRow $row; Write-QualificationTrack $entry $completion; Set-EntryStatus $file.FullName $entry 'processed'
    $processed += @{ task_id = $row.task_id; outcome = 'graded' }; continue
  }
  # Non-success injected completion: never grade, never qualify; restore pending.
  if ($null -ne $completion) {
    $row.status = 'no_contest'
    if ($completion.PSObject.Properties['wall_seconds']) { $row.wall_seconds = $completion.wall_seconds }
    Add-LedgerRow $row; Set-EntryStatus $file.FullName $entry 'pending'
    $processed += @{ task_id = $row.task_id; outcome = 'injected_nonsuccess' }; continue
  }

  # Legacy / incomplete for live: no full snapshot => deferred_no_spec, no model launch.
  if (-not ($hasSpec -and $laneOk -and $wallOk)) {
    $row.status = 'deferred_no_spec'; Add-LedgerRow $row; Set-EntryStatus $file.FullName $entry 'processed_deferred'
    $processed += @{ task_id = $row.task_id; outcome = 'deferred_no_spec' }; continue
  }

  # Live deterministic replay via Invoke-ShadowReplay (lane-spec wrappers, sealed reveal).
  $replay = Join-Path $PSScriptRoot 'Invoke-ShadowReplay.ps1'
  $outDir = Join-Path ([IO.Path]::GetTempPath()) ('fleet-auto-shadow-' + [guid]::NewGuid().ToString('n'))
  $replayArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$replay,'-EntryPath',$file.FullName,'-RepoRoot',$RepoRoot,'-OutputDirectory',$outDir)
  if (-not [string]::IsNullOrWhiteSpace($LaneSpecPath)) { $replayArgs += @('-LaneSpecPath', $LaneSpecPath) }
  # EAP=Stop + native stderr = NativeCommandError (LESSONS 2026-07-26); force Continue.
  $oldEap = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @replayArgs 2>&1 | Out-String }
  finally { $ErrorActionPreference = $oldEap }
  $completion = $null
  try { $completion = ($raw.Trim() | ConvertFrom-Json) } catch { $completion = $null }
  if ($null -eq $completion) {
    $row.status = 'error'; $row.error = 'replay_unparseable'
    Add-LedgerRow $row
    Set-EntryStatus $file.FullName $entry 'pending'
    $processed += @{ task_id = $row.task_id; outcome = 'error' }
    continue
  }
  if ($true -eq $completion.success) {
    $row.status = 'graded'
    if ($completion.PSObject.Properties['wall_seconds']) { $row.wall_seconds = $completion.wall_seconds }
    if ($completion.PSObject.Properties['result']) { $row.result = $completion.result }
    if ($completion.PSObject.Properties['scores']) { $row.scores = $completion.scores }
    if ($completion.PSObject.Properties['reveal_path']) { $row.reveal_path = $completion.reveal_path }
    $row.rubric = 'deterministic_partial'; $row.max_score = 90
    if ($completion.PSObject.Properties['v8_row'] -and $null -ne $completion.v8_row) {
      foreach ($p in $completion.v8_row.PSObject.Properties) {
        if (-not ($row.Keys -contains $p.Name)) { $row[$p.Name] = $p.Value }
      }
    }
    Add-LedgerRow $row
    Write-QualificationTrack $entry $completion
    Set-EntryStatus $file.FullName $entry 'processed'
    $processed += @{ task_id = $row.task_id; outcome = 'graded' }
    continue
  }
  # Timeout: no_contest row, restore pending for a future sweep.
  if ($true -eq $completion.timeout) {
    $row.status = 'no_contest'; $row.exclusion_reason = 'arm_timeout'
    if ($completion.PSObject.Properties['wall_seconds']) { $row.wall_seconds = $completion.wall_seconds }
    Add-LedgerRow $row
    Set-EntryStatus $file.FullName $entry 'pending'
    $processed += @{ task_id = $row.task_id; outcome = 'no_contest_timeout' }
    continue
  }
  # Terminal non-success (both-ineligible no_contest, excluded, etc.): record, no qualify.
  $row.status = [string]$completion.status
  if ([string]::IsNullOrWhiteSpace($row.status)) { $row.status = 'error' }
  if ($completion.PSObject.Properties['result']) { $row.result = $completion.result }
  if ($completion.PSObject.Properties['scores']) { $row.scores = $completion.scores }
  if ($completion.PSObject.Properties['reveal_path']) { $row.reveal_path = $completion.reveal_path }
  if ($completion.PSObject.Properties['exclusion_reason']) { $row.exclusion_reason = $completion.exclusion_reason }
  if ($completion.PSObject.Properties['wall_seconds']) { $row.wall_seconds = $completion.wall_seconds }
  Add-LedgerRow $row
  $terminal = $true
  if ($completion.PSObject.Properties['terminal'] -and $false -eq $completion.terminal) { $terminal = $false }
  if ($terminal) { Set-EntryStatus $file.FullName $entry 'processed' }
  else { Set-EntryStatus $file.FullName $entry 'pending' }
  $processed += @{ task_id = $row.task_id; outcome = [string]$row.status }
}

Write-Output (@{ processed = $processed; count = $processed.Count; injected_completion_refused = [bool]$injectedCompletionRefused } | ConvertTo-Json -Depth 5 -Compress)
