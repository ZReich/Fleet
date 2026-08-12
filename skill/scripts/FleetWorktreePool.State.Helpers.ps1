# Fleet worktree pool helpers. Safety reparse fns VERBATIM from New-FleetWorktree.ps1.
$script:FleetPoolUtf8 = New-Object System.Text.UTF8Encoding $false
$script:FleetPoolSchema = '1'
$script:FleetPoolPathMargin = 80
$script:FleetPoolMaxPath = 260
$script:FleetPoolDepRoots = @('node_modules')
# --- VERBATIM from New-FleetWorktree.ps1 (begin) ---
function Assert-NoEscapingReparsePoints {
  param([string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return }
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $stack = New-Object System.Collections.Stack; $stack.Push($rootFull)
  while ($stack.Count -gt 0) {
    $dir = [string]$stack.Pop()
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) {
        $target = $null; try { $target = (Get-Item -LiteralPath $child.FullName -Force).Target } catch { }
        $anyTarget = $false
        foreach ($t in @($target)) {
          if ([string]::IsNullOrWhiteSpace([string]$t)) { continue }
          $anyTarget = $true
          $resolved = if ([IO.Path]::IsPathRooted([string]$t)) { [string]$t } else { Join-Path (Split-Path -Parent $child.FullName) ([string]$t) }
          $tFull = try { [IO.Path]::GetFullPath($resolved).TrimEnd('\') } catch { [string]$resolved }
          if (-not (Test-UnderRoot -Path $tFull -Root $rootFull)) {
            throw "Refusing worktree: reparse point '$($child.FullName)' escapes to '$tFull' outside the worktree. A recursive delete could follow it into another checkout. Remove the junction (rmdir the link) or use an npm-installed dependency tree (npm ci)."
          }
        }
        if (-not $anyTarget) {
          throw "Refusing worktree: unresolvable reparse point at '$($child.FullName)'. Remove it before using (fail closed)."
        }
        continue
      }
      $stack.Push([string]$child.FullName)
    }
  }
}
function Test-UnderDocuments([string]$Path) {
  foreach ($part in ([IO.Path]::GetFullPath($Path) -split '[\\/]+')) {
    if ($part -eq 'Documents') { return $true }
  }
  return $false
}
function Test-UnderRoot([string]$Path, [string]$Root) {
  $p = [IO.Path]::GetFullPath($Path).TrimEnd('\'); $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  return $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or ($p + '\').StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}
# Walk ancestors; follow reparse targets. Returns physical path + first escape offender.
function Resolve-PhysicalWorktreePath {
  param([string]$LogicalPath, [string]$CanonicalRoot)
  $bs = [string][char]92
  $full = [IO.Path]::GetFullPath($LogicalPath).TrimEnd($bs)
  $root = [IO.Path]::GetPathRoot($full)
  $rel = if ($full.Length -gt $root.Length) { $full.Substring($root.Length).TrimStart($bs) } else { '' }
  $segments = @(); if ($rel) { $segments = @($rel -split '[\\/]+' | Where-Object { $_ }) }
  $current = $root; $offPath = $null; $offTarget = $null; $visited = @{}; $i = 0
  while ($i -lt $segments.Count) {
    $next = Join-Path $current $segments[$i]
    if (-not (Test-Path -LiteralPath $next)) {
      $current = [IO.Path]::GetFullPath((Join-Path $current ($segments[$i..($segments.Count - 1)] -join $bs))).TrimEnd($bs)
      break
    }
    $item = Get-Item -LiteralPath $next -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) {
      $targetRaw = $null; try { $targetRaw = $item.Target } catch { }
      $t = $null
      foreach ($cand in @($targetRaw)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$cand)) { $t = [string]$cand; break }
      }
      if ([string]::IsNullOrWhiteSpace($t)) { throw "Refusing worktree: unresolvable reparse point at '$next'." }
      if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $next) $t }
      $tFull = [IO.Path]::GetFullPath($t).TrimEnd($bs)
      $key = $next.ToLowerInvariant()
      if ($visited.ContainsKey($key)) { throw "Refusing worktree: cyclic reparse point at '$next'." }
      $visited[$key] = $true
      if (-not (Test-UnderRoot -Path $tFull -Root $CanonicalRoot) -and $null -eq $offPath) {
        $offPath = $next; $offTarget = $tFull
      }
      $current = $tFull; $i++; continue
    }
    $current = [IO.Path]::GetFullPath($next).TrimEnd($bs); $i++
  }
  return @{ Path = [IO.Path]::GetFullPath($current).TrimEnd($bs); OffenderPath = $offPath; OffenderTarget = $offTarget }
}
# --- VERBATIM from New-FleetWorktree.ps1 (end) ---
function Get-FleetPoolSha256Hex([string]$Text) {
  return ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant()
}
function Get-FleetPoolCanonicalRoot {
  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw 'USERPROFILE is not set.' }
  return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex\worktrees'))
}
function Resolve-FleetPoolRepoIdentity {
  param([Parameter(Mandatory)][string]$Repo)
  if ([string]::IsNullOrWhiteSpace($Repo)) { throw 'Repo is required.' }
  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  if (-not (Test-Path -LiteralPath $repoFull)) { throw "Repo path does not exist: $repoFull" }
  $gitOk = @(& git -c core.quotePath=false -C $repoFull rev-parse --is-inside-work-tree 2>$null)
  if ($LASTEXITCODE -ne 0 -or ($gitOk -join '') -ne 'true') { throw "Repo is not a git work tree: $repoFull" }
  $commonRaw = @(& git -c core.quotePath=false -C $repoFull rev-parse --git-common-dir 2>$null)
  if ($LASTEXITCODE -ne 0 -or $commonRaw.Count -lt 1) { throw "Could not resolve git-common-dir for: $repoFull" }
  $commonRawStr = [string]$commonRaw[0]
  if (-not [IO.Path]::IsPathRooted($commonRawStr)) { $commonRawStr = Join-Path $repoFull $commonRawStr }
  $commonDir = [IO.Path]::GetFullPath($commonRawStr).TrimEnd('\')
  $repoName = [IO.Path]::GetFileName($repoFull)
  if ([string]::IsNullOrWhiteSpace($repoName)) { throw "Could not derive repo name from: $repoFull" }
  $san = ($repoName.ToLowerInvariant() -creplace '[^a-z0-9]', '')
  if ($san.Length -gt 12) { $san = $san.Substring(0, 12) }
  if ([string]::IsNullOrWhiteSpace($san)) { $san = 'repo' }
  return [pscustomobject]@{ RepoPath = $repoFull; RepoName = $repoName; CommonDir = $commonDir; RepoKey = "$san-$((Get-FleetPoolSha256Hex $commonDir).Substring(0, 8))" }
}
function Get-FleetPoolRepoRoot([string]$RepoKey) { return [IO.Path]::GetFullPath((Join-Path (Get-FleetPoolCanonicalRoot) $RepoKey)) }
function Get-FleetPoolStatePath([string]$RepoKey) { return Join-Path (Get-FleetPoolRepoRoot $RepoKey) '.fleet-pool\pool.json' }
function Get-FleetPoolSlotPath([string]$RepoKey, [string]$SlotId) { return [IO.Path]::GetFullPath((Join-Path (Get-FleetPoolRepoRoot $RepoKey) $SlotId)) }
function Assert-FleetPoolPathBudget([string]$SlotRoot) {
  $len = ([IO.Path]::GetFullPath($SlotRoot)).Length
  if (($len + $script:FleetPoolPathMargin) -gt $script:FleetPoolMaxPath) {
    throw "Slot root path length $len leaves insufficient margin under $($script:FleetPoolMaxPath) (need margin $($script:FleetPoolPathMargin)): $SlotRoot"
  }
}
function Get-FleetPoolMutexName([string]$RepoKey) { return "Global\FleetWorktreePool-$RepoKey" }
function Invoke-FleetPoolWithMutex {
  param([Parameter(Mandatory)][string]$RepoKey, [Parameter(Mandatory)][scriptblock]$Body, [int]$TimeoutMs = 60000)
  $mx = New-Object System.Threading.Mutex($false, (Get-FleetPoolMutexName $RepoKey)); $got = $false
  try {
    $got = $mx.WaitOne($TimeoutMs)
    if (-not $got) { throw "Timed out acquiring pool mutex: $(Get-FleetPoolMutexName $RepoKey)" }
    return & $Body
  } finally { if ($got) { try { $mx.ReleaseMutex() } catch { } }; $mx.Dispose() }
}
function New-FleetPoolToken { return [guid]::NewGuid().ToString('n') }
function New-FleetPoolSlotRecord {
  param([string]$SlotId, [string]$Path, [string]$State = 'provisioning')
  return [ordered]@{
    id = $SlotId; path = $Path; state = $State; token = (New-FleetPoolToken)
    provision_owner_pid = $null
    lease_id = $null; run_id = $null; owner_pid = $null; owner_start_utc = $null
    branch = $null; base_commit = $null; processes = @(); fingerprint = $null; disk_bytes = 0
    quarantine_reason = $null; quarantine_at = $null; quarantine_evidence = $null
    last_lease_id = $null; last_run_id = $null; ever_registered = $false
  }
}
function Assert-FleetPoolSlotPathIdentity {
  # pool.json is durable state, not authority for where a slot lives. A path
  # merely contained by the pool root could point at a sibling slot.
  param([Parameter(Mandatory)]$Slot, [Parameter(Mandatory)][string]$RepoKey)
  $slotId = [string]$Slot.id
  $persisted = [string]$Slot.path
  if ([string]::IsNullOrWhiteSpace($slotId) -or [string]::IsNullOrWhiteSpace($persisted)) {
    throw 'Pool slot is missing id or path.'
  }
  $expected = Get-FleetPoolSlotPath -RepoKey $RepoKey -SlotId $slotId
  $repoRoot = Get-FleetPoolRepoRoot $RepoKey
  if (-not (Test-UnderRoot -Path $expected -Root $repoRoot)) {
    throw "Pool slot id escapes its repo root: $slotId"
  }
  try { $actual = [IO.Path]::GetFullPath($persisted).TrimEnd('\') } catch { throw "Pool slot path is invalid for $slotId" }
  if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Pool slot path identity mismatch for $slotId"
  }
  return $expected
}
function Read-FleetPoolState([string]$StatePath) {
  if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
  try {
    $state = [IO.File]::ReadAllText($StatePath) | ConvertFrom-Json -ErrorAction Stop
    $repoKey = [string]$state.repo_key
    if ([string]::IsNullOrWhiteSpace($repoKey)) { throw 'Pool state is missing repo_key.' }
    $poolDir = Split-Path -Parent ([IO.Path]::GetFullPath($StatePath))
    if ((Split-Path -Leaf $poolDir) -cne '.fleet-pool') { throw 'Pool state path is not under .fleet-pool.' }
    $pathRepoKey = Split-Path -Leaf (Split-Path -Parent $poolDir)
    if ([string]::IsNullOrWhiteSpace($pathRepoKey) -or $repoKey -cne $pathRepoKey) { throw 'Pool state repo_key does not match state-file location.' }
    foreach ($slot in @($state.slots)) { [void](Assert-FleetPoolSlotPathIdentity -Slot $slot -RepoKey $pathRepoKey) }
    return $state
  }
  catch { throw "Unparseable pool state: $StatePath" }
}
function Get-FleetPoolLegacyRepoPath {
  param($State)
  $commonDir = ''
  try { $commonDir = [string]$State.git_common_dir } catch { }
  if ([string]::IsNullOrWhiteSpace($commonDir)) { throw 'Pool state is missing repo_path and git_common_dir.' }
  $fullCommon = [IO.Path]::GetFullPath($commonDir).TrimEnd('\')
  $repoPath = Split-Path -Parent $fullCommon
  if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath $repoPath)) {
    throw "Cannot derive repo_path from git_common_dir: $fullCommon"
  }
  return [IO.Path]::GetFullPath($repoPath).TrimEnd('\')
}
function Read-FleetPoolStateWithRepoPath {
  param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][string]$RepoKey)
  return (Invoke-FleetPoolWithMutex -RepoKey $RepoKey -Body {
    $state = Read-FleetPoolState -StatePath $StatePath
    if ($null -eq $state) { return $null }
    $repoPath = ''
    try { $repoPath = [string]$state.repo_path } catch { }
    if ([string]::IsNullOrWhiteSpace($repoPath)) {
      $repoPath = Get-FleetPoolLegacyRepoPath -State $state
      try { $state | Add-Member -MemberType NoteProperty -Name 'repo_path' -Value $repoPath -Force } catch { $state.repo_path = $repoPath }
      Write-FleetPoolState -StatePath $StatePath -State $state
    }
    return $state
  })
}
function Write-FleetPoolState {
  param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)]$State)
  $dir = Split-Path -Parent $StatePath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = Join-Path $dir ('.pool-' + [guid]::NewGuid().ToString('n') + '.json')
  try {
    [IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json -Depth 10), $script:FleetPoolUtf8)
    if (Test-Path -LiteralPath $StatePath) {
      [IO.File]::Replace($tmp, $StatePath, ($tmp + '.bak'))
      if (Test-Path -LiteralPath ($tmp + '.bak')) { Remove-Item -LiteralPath ($tmp + '.bak') -Force -ErrorAction SilentlyContinue }
    } else { [IO.File]::Move($tmp, $StatePath) }
  } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}
function Get-FleetPoolSlotFromState { param($State, [string]$SlotId); foreach ($slot in @($State.slots)) { if ([string]$slot.id -eq $SlotId) { return $slot } }; return $null }
function Set-FleetPoolQuarantine {
  param($Slot, [string]$Reason, [string]$Evidence = '')
  $runKeep = $null; try { if ($Slot.run_id) { $runKeep = [string]$Slot.run_id } } catch { }
  if (-not [string]::IsNullOrWhiteSpace($runKeep)) {
    $note = "fleet/$runKeep remains for manual prune"
    $Evidence = if ([string]::IsNullOrWhiteSpace($Evidence)) { $note } else { "$Evidence; $note" }
  }
  $Slot.state = 'quarantined'; $Slot.quarantine_reason = $Reason
  $Slot.quarantine_at = [datetimeoffset]::UtcNow.ToString('o'); $Slot.quarantine_evidence = $Evidence
  if ($Slot.lease_id) { $Slot.last_lease_id = $Slot.lease_id }; if ($Slot.run_id) { $Slot.last_run_id = $Slot.run_id }
  $Slot.lease_id = $null; $Slot.run_id = $null; $Slot.owner_pid = $null; $Slot.owner_start_utc = $null
  try { $Slot.provision_owner_pid = $null } catch { $Slot | Add-Member -MemberType NoteProperty -Name 'provision_owner_pid' -Value $null -Force }
  $Slot.token = (New-FleetPoolToken); $Slot.processes = @(); $Slot.ever_registered = $false
}
function Write-FleetPoolEvent {
  param([hashtable]$Event)
  if ($null -eq $Event) { return }
  $telemetryFields = @{}; $eventName = ''
  foreach ($key in @($Event.Keys)) {
    $k = [string]$key
    if ($k -eq 'lease_id') { continue } elseif ($k -eq 'event') { $eventName = [string]$Event[$key] } else { $telemetryFields[$k] = $Event[$key] }
  }
  if ([string]::IsNullOrWhiteSpace($eventName)) { return }
  $map = @{ pool_initialize_slot='provision_complete'; pool_acquire='acquire_complete'; pool_release='release_complete'; pool_reap='reap' }
  if ($map.ContainsKey($eventName)) { $eventName = [string]$map[$eventName] }
  # Lifecycle callers only know a subset of the telemetry schema. Fill the
  # inexpensive, always-known values here so rows remain useful without
  # changing the telemetry schema or ever recording the lease token.
  if (-not $telemetryFields.ContainsKey('outcome') -or [string]::IsNullOrWhiteSpace([string]$telemetryFields['outcome'])) {
    if ($telemetryFields.ContainsKey('quarantine_reason') -and -not [string]::IsNullOrWhiteSpace([string]$telemetryFields['quarantine_reason'])) {
      $telemetryFields['outcome'] = 'quarantined'
    } elseif ($telemetryFields.ContainsKey('state') -and -not [string]::IsNullOrWhiteSpace([string]$telemetryFields['state'])) {
      $telemetryFields['outcome'] = [string]$telemetryFields['state']
    } else { $telemetryFields['outcome'] = 'ok' }
  }
  if (-not $telemetryFields.ContainsKey('reason') -or [string]::IsNullOrWhiteSpace([string]$telemetryFields['reason'])) {
    if ($telemetryFields.ContainsKey('quarantine_reason') -and -not [string]::IsNullOrWhiteSpace([string]$telemetryFields['quarantine_reason'])) {
      $telemetryFields['reason'] = [string]$telemetryFields['quarantine_reason']
    } else { $telemetryFields['reason'] = $eventName }
  }
  if (-not $telemetryFields.ContainsKey('ownership') -or [string]::IsNullOrWhiteSpace([string]$telemetryFields['ownership'])) { $telemetryFields['ownership'] = 'pool' }
  if (-not $telemetryFields.ContainsKey('duration_ms') -or $null -eq $telemetryFields['duration_ms']) { $telemetryFields['duration_ms'] = 0 }
  if (-not $telemetryFields.ContainsKey('schema_version') -or [string]::IsNullOrWhiteSpace([string]$telemetryFields['schema_version'])) { $telemetryFields['schema_version'] = '1' }
  $telemetryFields['event'] = $eventName; $tel = Join-Path $PSScriptRoot 'Write-FleetWorktreeTelemetry.ps1'
  if (-not (Test-Path -LiteralPath $tel -PathType Leaf)) {
    $message = "Telemetry writer is missing: $tel"
    [Console]::Error.WriteLine("WARNING: $message")
    throw $message
  }
  try {
    # The writer also supports a CLI entrypoint with `exit`; suppress it while
    # importing its function so lifecycle scripts can still emit result JSON.
    $hadSuppress = Test-Path -LiteralPath Variable:global:FleetWttSuppressCli
    $previousSuppress = $global:FleetWttSuppressCli
    $global:FleetWttSuppressCli = $true
    try {
      . $tel
      Write-FleetWorktreeTelemetry -Event $eventName -Fields $telemetryFields
    } finally {
      if ($hadSuppress) { $global:FleetWttSuppressCli = $previousSuppress }
      else { Remove-Variable -Name FleetWttSuppressCli -Scope Global -ErrorAction SilentlyContinue }
    }
    return
  } catch {
    $message = "Telemetry write failed for ${eventName}: $($_.Exception.Message)"
    [Console]::Error.WriteLine("WARNING: $message")
    throw $message
  }
}
