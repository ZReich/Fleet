# Deterministic-graded shadow replay for one queue entry. Detached worktrees from the
# entry's frozen base_sha, crypto A/B, lane-spec wrappers only, gates closed-stdin,
# deterministic_partial rubric (max 90, maintainability null). Exit 0 only with
# structurally complete evidence. See references/auto-shadow.md.
param(
  [Parameter(Mandatory)][string]$EntryPath,
  [Parameter(Mandatory)][string]$RepoRoot,
  [string]$OutputDirectory = '',
  [string]$LaneSpecPath = '',
  [ValidateRange(1, 3600)][int]$GateTimeoutSeconds = 900,
  [switch]$KeepWorktrees
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$CanonicalLanes = @('terra','grok','sol','luna','glm','opus','kimi','gemini')
$HardIneligible = @('scope_violation','binary_change','diff_budget_exceeded','gate_failed','commit_created')
$scriptsRoot = $PSScriptRoot; if ([string]::IsNullOrEmpty($scriptsRoot)) { $scriptsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Write-Utf8([string]$Path, [string]$Value) {
  $p = Split-Path -Parent $Path; if ($p) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  [IO.File]::WriteAllText($Path, $Value, $utf8)
}
function Get-TextHash([string]$Value) {
  $s = [Security.Cryptography.SHA256]::Create()
  try { return (([BitConverter]::ToString($s.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))) -replace '-', '').ToLowerInvariant()) }
  finally { $s.Dispose() }
}
function Get-CryptoBit {
  $b = New-Object byte[] 1; $r = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $r.GetBytes($b); return (($b[0] -band 1) -eq 1) } finally { $r.Dispose() }
}
function Invoke-GitNative([string]$Cwd, [string[]]$GitArgs) {
  # EAP=Stop + native stderr = NativeCommandError EVEN with 2>$null (LESSONS 2026-07-26).
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; & git -C $Cwd @GitArgs 2>$null }
  finally { $ErrorActionPreference = $old }
}
function Emit-Completion($Obj) { Write-Output ($Obj | ConvertTo-Json -Depth 12 -Compress) }
function New-Fail([string]$Status, [string]$Reason, [bool]$Timeout = $false, [int]$Wall = 0, [bool]$Terminal = $true) {
  return [ordered]@{
    success=$false; status=$Status; result=$(if($Status -eq 'no_contest'){'no_contest'}else{$null})
    wall_seconds=$Wall; scores=$null; reveal_path=$null; v8_row=$null; kind=$null
    timeout=$Timeout; terminal=$Terminal; exclusion_reason=$Reason; error=$Reason
  }
}
. (Join-Path $scriptsRoot 'ShadowReplay.Helpers.ps1')

if (-not (Test-Path -LiteralPath $EntryPath -PathType Leaf)) { Emit-Completion (New-Fail 'error' "entry missing: $EntryPath"); exit 1 }
$entry = Get-Content -LiteralPath $EntryPath -Raw -Encoding UTF8 | ConvertFrom-Json
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path; $startedAll = Get-Date
$task = $entry.task_spec
if ($null -eq $task -or [string]::IsNullOrWhiteSpace([string]$task.id) -or [string]::IsNullOrWhiteSpace([string]$task.prompt) -or @($task.allowed_paths).Count -lt 1) {
  Emit-Completion (New-Fail 'deferred_no_spec' 'missing_task_spec'); exit 0
}
$primaryLane = [string]$entry.primary_lane; $challenger = [string]$entry.challenger
if ([string]::IsNullOrWhiteSpace($primaryLane) -or [string]::IsNullOrWhiteSpace($challenger)) { Emit-Completion (New-Fail 'error' 'primary_lane and challenger required'); exit 1 }
foreach ($lane in @($primaryLane, $challenger)) {
  if ($CanonicalLanes -notcontains $lane.ToLowerInvariant()) { Emit-Completion (New-Fail 'error' "non-canonical wrapper id: $lane"); exit 1 }
}
$primaryLane = $primaryLane.ToLowerInvariant(); $challenger = $challenger.ToLowerInvariant()
$primaryWall = 0
if ($entry.PSObject.Properties['primary_wall_seconds'] -and $null -ne $entry.primary_wall_seconds -and "$($entry.primary_wall_seconds)" -ne '') { $primaryWall = [int]$entry.primary_wall_seconds }
if ($primaryWall -le 0) { Emit-Completion (New-Fail 'error' 'primary_wall_seconds required and > 0'); exit 1 }
$armBudget = [int][math]::Ceiling(1.5 * $primaryWall)
# base_drift guard FIRST — never grade a missing base.
$baseSha = [string]$entry.base_sha; $baseOk = $false
try { & git -C $RepoRoot cat-file -e ("{0}^{{commit}}" -f $baseSha) 2>$null; $baseOk = ($LASTEXITCODE -eq 0) } catch { $baseOk = $false }
if (-not $baseOk) { $c = New-Fail 'excluded' 'base_drift'; $c.exclusion_reason = 'base_drift'; Emit-Completion $c; exit 0 }
$wrappers = @{}; $laneModels = @{}; $spec = $null
if (-not [string]::IsNullOrWhiteSpace($LaneSpecPath)) {
  if (-not (Test-Path -LiteralPath $LaneSpecPath -PathType Leaf)) { Emit-Completion (New-Fail 'error' "LaneSpecPath missing: $LaneSpecPath"); exit 1 }
  $spec = Get-Content -LiteralPath $LaneSpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($null -eq $spec.wrappers) { Emit-Completion (New-Fail 'error' 'LaneSpec missing wrappers'); exit 1 }
  foreach ($p in $spec.wrappers.PSObject.Properties) { $wrappers[$p.Name.ToLowerInvariant()] = [string]$p.Value }
  if ($null -ne $spec.models) {
    foreach ($p in $spec.models.PSObject.Properties) { $laneModels[$p.Name.ToLowerInvariant()] = [string]$p.Value }
  }
} else {
  foreach ($pair in @{ grok='Invoke-Grok45.ps1'; sol='Invoke-Sol.ps1'; terra='Invoke-Sol.ps1'; luna='Invoke-Sol.ps1'; glm='Invoke-PiGlm.ps1'; opus='Invoke-Opus48.ps1'; kimi='Invoke-KimiK3.ps1'; gemini='Invoke-Gemini35.ps1' }.GetEnumerator()) {
    $wrappers[$pair.Key] = Join-Path $scriptsRoot $pair.Value
  }
}
foreach ($lane in @($primaryLane, $challenger)) {
  if (-not $wrappers.ContainsKey($lane)) { Emit-Completion (New-Fail 'error' "wrapper missing for lane $lane"); exit 1 }
  # B1 trust boundary: scripts/ basename allowlist (Split-Path -Leaf + -notin $allowedWrappers).
  $leaf = Split-Path -Leaf $wrappers[$lane]
  if ($leaf -notin $allowedWrappers) { Emit-Completion (New-Fail 'error' "wrapper basename not allowed: $leaf"); exit 1 }
  $trust = Resolve-TrustedWrapper $wrappers[$lane]
  if (-not $trust.ok) { Emit-Completion (New-Fail 'error' $trust.error); exit 1 }
  $wrappers[$lane] = $trust.path
}

$runId = [string]$entry.run_id; $taskId = [string]$task.id
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ("fleet-shadow-replay-" + [guid]::NewGuid().ToString('n'))
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$privateRoot = Join-Path $OutputDirectory 'private'
$blindRoot = Join-Path $OutputDirectory 'blind'
$worktreeRoot = Join-Path $OutputDirectory 'worktrees'
New-Item -ItemType Directory -Force -Path $privateRoot, $blindRoot, $worktreeRoot | Out-Null
$created = @()
$wallSeconds = 0
try {
  $allowed = @($task.allowed_paths | ForEach-Object { ([string]$_ -replace '\\','/').Trim('/') })
  foreach ($path in $allowed) {
    if (-not $path -or $path -eq '.' -or [IO.Path]::IsPathRooted($path) -or @($path -split '/' | Where-Object { $_ -eq '..' }).Count) {
      Emit-Completion (New-Fail 'error' "unsafe allowed_paths: $path"); exit 1
    }
  }
  $maxLines = if ($task.PSObject.Properties['max_diff_lines'] -and $null -ne $task.max_diff_lines) { [int]$task.max_diff_lines } else { 1000 }
  $gateText = if (@($task.gate_commands).Count) { @($task.gate_commands | ForEach-Object { "- $_" }) -join "`n" } else { '- none' }
  $prompt = "SHADOW_COVERED:$runId/$taskId`nImplement this non-design task. Read any tracked file needed. Do not commit.`nAllowed changed paths:`n$(@($allowed | ForEach-Object { "- $_" }) -join "`n")`nMaximum changed lines: $maxLines`nRequired gates (runner repeats these):`n$gateText`n`nTask:`n$($task.prompt)"
  $promptHash = Get-TextHash $prompt
  $promptPath = Join-Path $privateRoot 'prompt.txt'; Write-Utf8 $promptPath $prompt
  Write-Utf8 (Join-Path $blindRoot 'prompt.txt') $prompt

  $trees = @{}
  foreach ($lane in @($primaryLane, $challenger)) {
    $tree = Join-Path $worktreeRoot "$taskId-$lane"
    Invoke-GitNative $RepoRoot @('worktree','add','--detach',$tree,$baseSha) | Out-Null
    if ($LASTEXITCODE -ne 0) { Emit-Completion (New-Fail 'error' "worktree failed for $lane"); exit 1 }
    $created += $tree; $trees[$lane] = $tree
  }

  $runs = @{}; $anyTimeout = $false
  foreach ($lane in @($primaryLane, $challenger)) {
    $wrapper = $wrappers[$lane]
    $reqModel = Get-LaneModel $lane $laneModels
    $cap = Get-WrapperCap $wrapper
    $stdoutPath = Join-Path $privateRoot "$lane.stdout.txt"
    $stderrPath = Join-Path $privateRoot "$lane.stderr.txt"
    $t0 = Get-Date
    # Sol-family: -Prompt $prompt -Model $reqModel (never -PromptFile). Else PromptFile shape.
    $launchArgs = Build-ArmLaunchArgs $lane $wrapper $prompt $promptPath $trees[$lane] $armBudget $reqModel
    try { if ([IO.File]::ReadAllText($wrapper) -match '\$LaneId') { $launchArgs += @('-LaneId', $lane) } } catch {}
    Write-Utf8 (Join-Path $privateRoot "$lane.launch.json") (([ordered]@{ wrapper = (Split-Path -Leaf $wrapper); requested_model = $reqModel; args = $launchArgs }) | ConvertTo-Json -Depth 5 -Compress)
    $env:FLEET_SHADOW_LANE_ID = $lane
    $run = Invoke-CapturedProcess 'powershell.exe' $launchArgs $trees[$lane] $stdoutPath $stderrPath ([math]::Max(1, $armBudget + 2))
    Remove-Item Env:\FLEET_SHADOW_LANE_ID -ErrorAction SilentlyContinue
    $transport = $null; try { $transport = Get-Content -LiteralPath $stdoutPath -Raw | ConvertFrom-Json } catch {}
    $tStatus = if ($run.timed_out) { 'timeout' } elseif ($run.exit_code -eq 0 -and $null -ne $transport -and [string]$transport.status -eq 'ok') { 'ok' } else { 'error' }
    if ($tStatus -eq 'timeout') { $anyTimeout = $true }
    $runs[$lane] = [pscustomobject]@{
      transport_status = $tStatus; timed_out = $run.timed_out; run = $run
      seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2); transport = $transport
      requested_model = $reqModel; wrapper = (Split-Path -Leaf $wrapper); cap = $cap
    }
  }

  function Get-ArmArtifacts([string]$Lane) {
    $wt = $trees[$Lane]
    Invoke-GitNative $wt @('add','-N','-A') | Out-Null
    $changed = @(Invoke-GitNative $wt @('diff','--name-only',$baseSha) | Where-Object { $_ } | Sort-Object -Unique)
    $diff = (Invoke-GitNative $wt @('diff',$baseSha,'--binary','--no-ext-diff')) -join "`n"
    $diffPath = Join-Path $privateRoot "$Lane.diff"; Write-Utf8 $diffPath $diff
    $outside = @($changed | Where-Object { -not (Test-AllowedPath $_ $allowed) })
    $numstat = @(Invoke-GitNative $wt @('diff',$baseSha,'--numstat')); $diffLines = 0; $binary = $false
    foreach ($line in $numstat) {
      $parts = $line -split "`t"
      if ($parts[0] -eq '-' -or $parts[1] -eq '-') { $binary = $true; continue }
      $diffLines += [int]$parts[0] + [int]$parts[1]
    }
    $gates = @(); $gi = 0
    foreach ($command in @($task.gate_commands)) {
      $g0 = Get-Date; $stem = "$Lane.gate-$gi"
      $gRun = Invoke-CapturedProcess 'powershell.exe' @('-NoProfile','-Command',[string]$command) $wt (Join-Path $privateRoot "$stem.stdout.txt") (Join-Path $privateRoot "$stem.stderr.txt") $GateTimeoutSeconds
      $gOut = ([string](Get-Content -LiteralPath $gRun.stdout -Raw -ErrorAction SilentlyContinue)) + ([string](Get-Content -LiteralPath $gRun.stderr -Raw -ErrorAction SilentlyContinue))
      $gates += [pscustomobject]@{ command = [string]$command; exit_code = $gRun.exit_code; timed_out = $gRun.timed_out; seconds = [math]::Round(((Get-Date) - $g0).TotalSeconds, 2); output = $gOut }
      $gi++
    }
    $headSha = ([string](Invoke-GitNative $wt @('rev-parse','HEAD'))).Trim()
    $status = if ($headSha -ne $baseSha) { 'commit_created' } elseif ($outside.Count) { 'scope_violation' } elseif ($binary) { 'binary_change' } elseif ($diffLines -gt $maxLines) { 'diff_budget_exceeded' } elseif (@($gates | Where-Object { $_.exit_code -ne 0 }).Count) { 'gate_failed' } else { 'eligible' }
    [pscustomobject]@{ status = $status; changed_files = $changed; outside_allowed_paths = $outside; diff_lines = $diffLines; head_sha = $headSha; diff_path = $diffPath; gates = $gates }
  }

  $arts = @{}
  foreach ($lane in @($primaryLane, $challenger)) {
    $r = $runs[$lane]
    if ($r.transport_status -eq 'ok' -and (Test-IsPatchSeat $r.cap $r.transport)) {
      $patchText = Get-TransportPatchText $r.transport
      $applied = Apply-LanePatch $lane $trees[$lane] $patchText $allowed $privateRoot
      if (-not $applied.ok) {
        $arts[$lane] = New-ExcludedArtifacts $lane $applied.reason $privateRoot $baseSha
        continue
      }
    }
    $arts[$lane] = Get-ArmArtifacts $lane
  }

  function Score-Arm($Art) {
    $gates = @($Art.gates)
    $allPass = ($gates.Count -eq 0) -or (@($gates | Where-Object { $_.exit_code -ne 0 }).Count -eq 0)
    $correctness = if ($allPass) { 40 } else { 0 }
    $spec = if (@($Art.outside_allowed_paths).Count -eq 0) { 25 } else { 0 }
    $tests = if ($gates.Count -gt 0 -and @($gates | Where-Object { $_.timed_out }).Count -eq 0) { 15 } else { 0 }
    $scope = if ($Art.diff_lines -le $maxLines) { 10 } else { 0 }
    $total = $correctness + $spec + $tests + $scope
    $inelig = ($HardIneligible -contains $Art.status)
    [ordered]@{ total = $total; correctness = $correctness; spec = $spec; tests = $tests; scope = $scope; maintainability = $null; hard_ineligible = $inelig; status = $Art.status }
  }

  $pScore = Score-Arm $arts[$primaryLane]
  $cScore = Score-Arm $arts[$challenger]
  $anyOutage = $anyTimeout -or ($runs[$primaryLane].transport_status -eq 'error') -or ($runs[$challenger].transport_status -eq 'error')
  $anyExcluded = ($arts[$primaryLane].status -eq 'excluded_capability') -or ($arts[$challenger].status -eq 'excluded_capability')
  # Timeout/outage/excluded_capability => no_contest (patch fail never a loss). Hard-ineligible may lose, never win.
  $result = 'no_contest'
  if (-not ($anyTimeout -or $anyOutage -or $anyExcluded)) {
    if ($pScore.hard_ineligible -and $cScore.hard_ineligible) { $result = 'no_contest' }
    elseif ($pScore.hard_ineligible) { $result = 'challenger' }
    elseif ($cScore.hard_ineligible) { $result = 'primary' }
    else {
      $delta = [math]::Abs([double]$pScore.total - [double]$cScore.total)
      if ($delta -le 5.0) { $result = 'tie' }
      elseif ([double]$pScore.total -gt [double]$cScore.total) { $result = 'primary' }
      else { $result = 'challenger' }
    }
  }

  $primaryIsA = Get-CryptoBit
  $aLane = if ($primaryIsA) { $primaryLane } else { $challenger }
  $bLane = if ($primaryIsA) { $challenger } else { $primaryLane }
  $pubDir = $blindRoot
  Copy-Item $arts[$aLane].diff_path (Join-Path $pubDir 'candidate-a.diff')
  Copy-Item $arts[$bLane].diff_path (Join-Path $pubDir 'candidate-b.diff')
  $gateSlim = { param($g) @($g | ForEach-Object { @{ command = $_.command; exit_code = $_.exit_code; timed_out = $_.timed_out; seconds = $_.seconds } }) }
  $gradePacket = [ordered]@{
    task_id = $taskId; rubric = 'deterministic_partial'; max_score = 90; base_sha = $baseSha
    shared_charter_sha256 = $promptHash
    candidate_a = @{ scoring_status = $arts[$aLane].status; diff_lines = $arts[$aLane].diff_lines; changed_files = $arts[$aLane].changed_files; gates = (& $gateSlim $arts[$aLane].gates) }
    candidate_b = @{ scoring_status = $arts[$bLane].status; diff_lines = $arts[$bLane].diff_lines; changed_files = $arts[$bLane].changed_files; gates = (& $gateSlim $arts[$bLane].gates) }
  }
  Write-Utf8 (Join-Path $pubDir 'packet.json') ($gradePacket | ConvertTo-Json -Depth 10)
  # ...............................................................................................................................................
  # ...............................................................................................................................................
  # ...............................................................................................................................................
  $reveal = [ordered]@{
    schema_version = '1'; run_id = $runId; task_id = $taskId  # sealed reveal: requested_model/wrapper identity lives here only (blind packet de-identified, B4)
    requested_model = @{ primary = $runs[$primaryLane].requested_model; challenger = $runs[$challenger].requested_model }
    wrapper = @{ primary = $runs[$primaryLane].wrapper; challenger = $runs[$challenger].wrapper }
    repo = $RepoRoot; base_sha = $baseSha; rubric = 'deterministic_partial'; max_score = 90
    arm_budget_seconds = $armBudget; primary_lane = $primaryLane; challenger = $challenger
    blind_mapping = @{ candidate_a = $aLane; candidate_b = $bLane }
    scores = @{ primary = $pScore; challenger = $cScore; delta = [math]::Round([double]$pScore.total - [double]$cScore.total, 2) }
    result = $result; primary = @{ run = $runs[$primaryLane]; artifacts = $arts[$primaryLane] }
    challenger_arm = @{ run = $runs[$challenger]; artifacts = $arts[$challenger] }
  }
  $revealPath = Join-Path $privateRoot 'reveal.json'
  Write-Utf8 $revealPath ($reveal | ConvertTo-Json -Depth 12)
  $wallSeconds = [int][math]::Round(((Get-Date) - $startedAll).TotalSeconds)
  $kind = [string]$entry.qualification_job_kind
  if ($anyTimeout -or $anyOutage) {
    $reason = if ($anyTimeout) { 'arm_timeout' } else { 'arm_outage' }
    $c = New-Fail 'no_contest' $reason $anyTimeout $wallSeconds
    $c.scores = $reveal.scores; $c.reveal_path = $revealPath; $c.kind = $kind; $c.terminal = $false
    Emit-Completion $c; exit 0
  }
  $isGrade = ($result -in @('primary','challenger','tie'))
  $v8 = [ordered]@{
    schema_version='8'; ledger='shadow'; run_id=$runId; task_id=[string]$entry.task_id
    task_stratum=[string]$entry.task_stratum; challenger=$challenger; primary_lane=$primaryLane
    estimand=[string]$entry.estimand; coverage_scope=[string]$entry.coverage_scope
    shadow_mode='post_hoc_async'; sample_seed=[string]$entry.sample_seed
    selection_probability=$entry.selection_probability; qualification_stratum=$entry.qualification_stratum
    qualification_n_current=$entry.qualification_n_current; qualification_n_target=$entry.qualification_n_target
    qualification_job_kind=$entry.qualification_job_kind; base_p_shadow=$entry.base_p_shadow
    effective_p_shadow=$entry.effective_p_shadow; boost_applied=$entry.boost_applied
    sampling_rate_source=$entry.sampling_rate_source; daily_boost_cap=$entry.daily_boost_cap
    daily_boost_used=$entry.daily_boost_used; boost_suppressed_reason=$entry.boost_suppressed_reason
    canary=$(if($null -eq $entry.canary){$false}else{[bool]$entry.canary}); canary_id=$entry.canary_id
    canary_repeat=$entry.canary_repeat; canary_repeat_count=$entry.canary_repeat_count
    sole_ship_gate=$entry.sole_ship_gate; adopted_into_run=$false; critical_path_delay_seconds=0
    base_drift=$false; rubric='deterministic_partial'; max_score=90
    status=$(if($isGrade){'graded'}else{'no_contest'}); result=$result; scores=$reveal.scores
    wall_seconds=$wallSeconds; reveal_path=$revealPath; packet_sha256=$entry.packet_sha256
    graded_at=[datetimeoffset]::Now.ToString('o')
  }
  Emit-Completion ([ordered]@{
    success=$isGrade; status=$v8.status; result=$result; wall_seconds=$wallSeconds
    scores=$reveal.scores; reveal_path=$revealPath; v8_row=$v8; kind=$kind
    timeout=$false; terminal=$true; exclusion_reason=$null; error=$null
  })
  exit 0
}
finally {
  if (-not $KeepWorktrees) {
    foreach ($tree in @($created | Where-Object { Test-Path -LiteralPath $_ })) {
      try {
        $full = [IO.Path]::GetFullPath($tree)
        $prefix = [IO.Path]::GetFullPath($worktreeRoot).TrimEnd('\') + '\'
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
          & git -C $RepoRoot worktree remove --force $full 2>$null | Out-Null
        }
      } catch {}
    }
    try { & git -C $RepoRoot worktree prune | Out-Null } catch {}
  }
}
