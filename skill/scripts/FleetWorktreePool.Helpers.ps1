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
  $gitOk = @(& git -C $repoFull rev-parse --is-inside-work-tree 2>$null)
  if ($LASTEXITCODE -ne 0 -or ($gitOk -join '') -ne 'true') { throw "Repo is not a git work tree: $repoFull" }
  $commonRaw = @(& git -C $repoFull rev-parse --git-common-dir 2>$null)
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
    lease_id = $null; run_id = $null; owner_pid = $null; owner_start_utc = $null
    branch = $null; base_commit = $null; processes = @(); fingerprint = $null; disk_bytes = 0
    quarantine_reason = $null; quarantine_at = $null; quarantine_evidence = $null
    last_lease_id = $null; last_run_id = $null; ever_registered = $false
  }
}
function Read-FleetPoolState([string]$StatePath) {
  if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
  try { return ([IO.File]::ReadAllText($StatePath) | ConvertFrom-Json -ErrorAction Stop) }
  catch { throw "Unparseable pool state: $StatePath" }
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
  $fields = @{}; $eventName = ''
  foreach ($key in @($Event.Keys)) {
    $k = [string]$key
    if ($k -eq 'lease_id') { continue } elseif ($k -eq 'event') { $eventName = [string]$Event[$key] } else { $fields[$k] = $Event[$key] }
  }
  if ([string]::IsNullOrWhiteSpace($eventName)) { return }
  $map = @{ pool_initialize_slot='provision_complete'; pool_acquire='acquire_complete'; pool_release='release_complete'; pool_reap='reap' }
  if ($map.ContainsKey($eventName)) { $eventName = [string]$map[$eventName] }
  $fields['event'] = $eventName; $tel = Join-Path $PSScriptRoot 'Write-FleetWorktreeTelemetry.ps1'
  if (Test-Path -LiteralPath $tel -PathType Leaf) { try { . $tel; Write-FleetWorktreeTelemetry -Event $eventName -Fields $fields } catch { } }
}
function Get-FleetPoolProcessStartUtc([int]$ProcessId) {
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if ($null -eq $proc) { return $null }; return ([datetimeoffset]$proc.StartTime.ToUniversalTime()).ToString('o')
}
function Test-FleetPoolProcessIdentityLive {
  param([int]$ProcessId, [string]$StartUtc)
  if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($StartUtc)) { return $false }
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if ($null -eq $proc) { return $false }
  try {
    $want = [datetimeoffset]::Parse($StartUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
    return ([math]::Abs(($want - ([datetimeoffset]$proc.StartTime.ToUniversalTime())).TotalSeconds) -lt 2.0)
  } catch { return $false }
}
function Test-FleetPoolRegisteredWorkersLive {
  param($Slot)
  foreach ($row in @($Slot.processes)) {
    $rowPid = 0; try { $rowPid = [int]$row.pid } catch { continue }
    if (Test-FleetPoolProcessIdentityLive -ProcessId $rowPid -StartUtc ([string]$row.start_utc)) { return $true }
  }
  return $false
}
function Test-FleetPoolHasRegistration {
  param($Slot)
  try { if ($Slot.ever_registered -eq $true) { return $true } } catch { }
  foreach ($row in @($Slot.processes)) {
    if ($null -eq $row) { continue }; $rowPid = 0; try { $rowPid = [int]$row.pid } catch { continue }
    if ($rowPid -gt 0) { return $true }
  }
  return $false
}
function Test-FleetPoolOwnerLive {
  param($Slot)
  $ownPid = 0; try { if ($null -ne $Slot.owner_pid) { $ownPid = [int]$Slot.owner_pid } } catch { }
  return ($ownPid -gt 0 -and (Test-FleetPoolProcessIdentityLive -ProcessId $ownPid -StartUtc ([string]$Slot.owner_start_utc)))
}
function Test-FleetPoolLeaseLive { param($Slot); return ((Test-FleetPoolOwnerLive -Slot $Slot) -or (Test-FleetPoolRegisteredWorkersLive -Slot $Slot)) }
function Test-FleetPoolSlotPathInLiveCommandLine {
  param([string]$SlotPath)
  $needle = [IO.Path]::GetFullPath($SlotPath).TrimEnd('\')
  foreach ($row in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    $cl = [string]$row.CommandLine
    if (-not [string]::IsNullOrEmpty($cl) -and $cl.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  }
  return $false
}
function Resolve-FleetPoolSlotContext {
  param([Parameter(Mandatory)][string]$WorkingDirectory)
  if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or -not (Test-Path -LiteralPath $WorkingDirectory)) { return $null }
  $wd = [IO.Path]::GetFullPath($WorkingDirectory).TrimEnd('\'); $canon = Get-FleetPoolCanonicalRoot
  if (-not (Test-UnderRoot -Path $wd -Root $canon)) { return $null }
  # Search pool.json under worktrees root; slot path ancestor of (or equals) wd.
  foreach ($repoDir in @(Get-ChildItem -LiteralPath $canon -Directory -ErrorAction SilentlyContinue)) {
    $statePath = Join-Path $repoDir.FullName '.fleet-pool\pool.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
    $st = $null; try { $st = Read-FleetPoolState -StatePath $statePath } catch { continue }
    if ($null -eq $st) { continue }
    $repoPath = $null; try { if ($st.repo_path) { $repoPath = [string]$st.repo_path } } catch { }
    if ([string]::IsNullOrWhiteSpace($repoPath)) { continue }
    foreach ($slot in @($st.slots)) {
      $spath = [string]$slot.path; if ([string]::IsNullOrWhiteSpace($spath)) { continue }
      try { $sfull = [IO.Path]::GetFullPath($spath).TrimEnd('\'); if (-not (Test-UnderRoot -Path $wd -Root $sfull)) { continue } } catch { continue }
      $lease = [string]$slot.lease_id; if ([string]::IsNullOrWhiteSpace($lease)) { return $null }
      return [pscustomobject]@{ RepoPath = [IO.Path]::GetFullPath($repoPath).TrimEnd('\'); RepoKey = [string]$st.repo_key; SlotId = [string]$slot.id; SlotPath = $sfull; LeaseId = $lease; RunId = [string]$slot.run_id; State = [string]$slot.state }
    }
  }
  return $null
}
function Get-FleetPoolWorktreeList {
  param([string]$RepoPath)
  $lines = @(& git -C $RepoPath worktree list --porcelain 2>$null)
  if ($LASTEXITCODE -ne 0) { throw "git worktree list failed for $RepoPath" }
  $list = New-Object System.Collections.ArrayList; $cur = $null
  foreach ($line in $lines) {
    if ($line -match '^worktree (.+)$') {
      if ($null -ne $cur) { [void]$list.Add($cur) }
      $cur = [ordered]@{ path = [IO.Path]::GetFullPath($Matches[1]).TrimEnd('\') }
    } elseif ([string]::IsNullOrWhiteSpace($line) -and $null -ne $cur) { [void]$list.Add($cur); $cur = $null }
  }
  if ($null -ne $cur) { [void]$list.Add($cur) }; return @($list)
}
function Test-FleetPoolWorktreeRegistered {
  param([string]$RepoPath, [string]$SlotPath)
  $want = [IO.Path]::GetFullPath($SlotPath).TrimEnd('\')
  foreach ($wt in @(Get-FleetPoolWorktreeList -RepoPath $RepoPath)) { if ([string]$wt.path -eq $want) { return $true } }
  return $false
}
function Get-FleetPoolSlotCommonDir {
  param([string]$SlotPath)
  $raw = @(& git -C $SlotPath rev-parse --git-common-dir 2>$null)
  if ($LASTEXITCODE -ne 0 -or $raw.Count -lt 1) { return $null }
  $s = [string]$raw[0]; if (-not [IO.Path]::IsPathRooted($s)) { $s = Join-Path $SlotPath $s }
  try { return [IO.Path]::GetFullPath($s).TrimEnd('\') } catch { return $null }
}
function Test-FleetPoolSlotDirty {
  param([string]$SlotPath)
  $lines = @(& git -C $SlotPath status --porcelain -uall 2>$null)
  if ($LASTEXITCODE -ne 0) { return $true }
  foreach ($line in $lines) { if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith('!!')) { return $true } }
  return $false
}
function Test-FleetPoolDepRootIsReparse {
  param([string]$SlotPath)
  foreach ($depName in $script:FleetPoolDepRoots) {
    $dep = Join-Path $SlotPath $depName; if (-not (Test-Path -LiteralPath $dep)) { continue }
    if (((Get-Item -LiteralPath $dep -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) { return $true }
  }
  return $false
}
function Test-FleetPoolUnderDepRoot {
  param([string]$SlotPath, [string]$FullPath)
  $slotFull = [IO.Path]::GetFullPath($SlotPath).TrimEnd('\'); $p = [IO.Path]::GetFullPath($FullPath).TrimEnd('\')
  foreach ($depName in $script:FleetPoolDepRoots) { if (Test-UnderRoot -Path $p -Root (Join-Path $slotFull $depName)) { return $true } }
  return $false
}
function Assert-FleetPoolDeleteTargetSafe {
  param([string]$TargetPath, [string]$SlotRoot)
  $slotFull = [IO.Path]::GetFullPath($SlotRoot).TrimEnd('\'); $tgt = [IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
  if (-not (Test-UnderRoot -Path $tgt -Root $slotFull)) { throw "delete target escapes slot root: $tgt not under $slotFull" }
  $resolved = Resolve-PhysicalWorktreePath -LogicalPath $tgt -CanonicalRoot $slotFull
  if ($resolved.OffenderPath) { throw "delete target has escaping reparse '$($resolved.OffenderPath)' -> '$($resolved.OffenderTarget)'" }
  if (-not (Test-UnderRoot -Path $resolved.Path -Root $slotFull)) { throw "delete target physical path escapes slot: $($resolved.Path)" }
}
function Remove-FleetPoolTreeNoRecurse {
  param([string]$TargetPath, [string]$SlotRoot)
  if (-not (Test-Path -LiteralPath $TargetPath)) { return }
  Assert-FleetPoolDeleteTargetSafe -TargetPath $TargetPath -SlotRoot $SlotRoot
  $item = Get-Item -LiteralPath $TargetPath -Force
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) { throw "reparse point blocks sanitation: $TargetPath" }
  if (-not $item.PSIsContainer) { Remove-Item -LiteralPath $TargetPath -Force; return }
  $stack = New-Object System.Collections.Stack; $dirs = New-Object System.Collections.Generic.List[string]
  $stack.Push([IO.Path]::GetFullPath($TargetPath))
  while ($stack.Count -gt 0) {
    $dir = [string]$stack.Pop(); Assert-FleetPoolDeleteTargetSafe -TargetPath $dir -SlotRoot $SlotRoot
    $dirItem = Get-Item -LiteralPath $dir -Force
    if (($dirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) { throw "reparse point blocks sanitation: $dir" }
    [void]$dirs.Add($dir)
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) { throw "reparse point blocks sanitation: $($child.FullName)" }
      if ($child.PSIsContainer) { $stack.Push($child.FullName) }
      else { Assert-FleetPoolDeleteTargetSafe -TargetPath $child.FullName -SlotRoot $SlotRoot; Remove-Item -LiteralPath $child.FullName -Force }
    }
  }
  for ($di = $dirs.Count - 1; $di -ge 0; $di--) { Assert-FleetPoolDeleteTargetSafe -TargetPath $dirs[$di] -SlotRoot $SlotRoot; Remove-Item -LiteralPath $dirs[$di] -Force -ErrorAction SilentlyContinue }
}
function Invoke-FleetPoolSanitizeSlot {
  param([string]$SlotPath)
  Assert-NoEscapingReparsePoints -Root $SlotPath
  if (Test-FleetPoolDepRootIsReparse -SlotPath $SlotPath) { throw "dependency root is a reparse point (blocks sanitation): $SlotPath" }
  $lines = @(& git -C $SlotPath status --porcelain --ignored -uall 2>$null)
  if ($LASTEXITCODE -ne 0) { throw "git status failed during sanitation: $SlotPath" }
  $toRemove = New-Object System.Collections.ArrayList
  foreach ($line in $lines) {
    if (-not $line.StartsWith('!! ')) { continue }
    $rel = $line.Substring(3).Trim().Trim('"'); if ([string]::IsNullOrWhiteSpace($rel)) { continue }
    $full = [IO.Path]::GetFullPath((Join-Path $SlotPath ($rel -replace '/', '\')))
    if (Test-FleetPoolUnderDepRoot -SlotPath $SlotPath -FullPath $full) { continue }
    Assert-FleetPoolDeleteTargetSafe -TargetPath $full -SlotRoot $SlotPath; [void]$toRemove.Add($full)
  }
  $ordered = @($toRemove | Sort-Object { $_.Length } -Descending); $seen = @{}
  foreach ($path in $ordered) {
    $lk = $path.ToLowerInvariant(); if ($seen.ContainsKey($lk)) { continue }; $seen[$lk] = $true
    if (Test-Path -LiteralPath $path) { Remove-FleetPoolTreeNoRecurse -TargetPath $path -SlotRoot $SlotPath }
  }
}
function Clear-FleetPoolSlotOwnership {
  param($Slot)
  if ($Slot.lease_id) { $Slot.last_lease_id = $Slot.lease_id }
  if ($Slot.run_id) { $Slot.last_run_id = $Slot.run_id }
  $Slot.lease_id = $null; $Slot.run_id = $null; $Slot.owner_pid = $null; $Slot.owner_start_utc = $null
  $Slot.branch = $null; $Slot.base_commit = $null; $Slot.processes = @(); $Slot.ever_registered = $false
  $Slot.token = (New-FleetPoolToken); $Slot.state = 'ready'
}
function Assert-FleetPoolCanonicalGates {
  param([string]$LogicalPath, [string]$CanonicalRoot)
  if (Test-UnderDocuments -Path $LogicalPath) { throw "Refusing worktree path under a Documents directory: $LogicalPath" }
  $resolved = Resolve-PhysicalWorktreePath -LogicalPath $LogicalPath -CanonicalRoot $CanonicalRoot
  if (-not (Test-UnderRoot -Path $resolved.Path -Root $CanonicalRoot)) {
    if ($resolved.OffenderPath) { throw "Refusing worktree: ancestor reparse point '$($resolved.OffenderPath)' resolves to '$($resolved.OffenderTarget)' outside the canonical worktree root '$CanonicalRoot'." }
    throw "Refusing worktree: resolved path '$($resolved.Path)' escapes canonical worktree root '$CanonicalRoot'."
  }
  if (Test-UnderDocuments -Path $resolved.Path) { throw "Refusing worktree path under a Documents directory: $($resolved.Path)" }
  return $resolved
}
function Format-FleetPoolSlotId([int]$Index) { return ('slot-{0:d2}' -f $Index) }
function Emit-FleetPoolJson($Obj) { Write-Output (($Obj | ConvertTo-Json -Depth 8 -Compress)) }
function Emit-FleetPoolText([string]$Line) { Write-Output $Line }
function Invoke-FleetPoolSanitizeAndRelease {
  param($Slot, [string]$RepoPath, [string]$ExpectedCommonDir)
  $spath = [string]$Slot.path
  if (-not (Test-FleetPoolWorktreeRegistered -RepoPath $RepoPath -SlotPath $spath)) {
    Set-FleetPoolQuarantine -Slot $Slot -Reason 'worktree_registration_mismatch' -Evidence $spath; return 'quarantined'
  }
  $slotCommon = Get-FleetPoolSlotCommonDir -SlotPath $spath
  if ([string]::IsNullOrWhiteSpace($slotCommon) -or -not $slotCommon.Equals($ExpectedCommonDir, [StringComparison]::OrdinalIgnoreCase)) {
    Set-FleetPoolQuarantine -Slot $Slot -Reason 'repo_common_dir_mismatch' -Evidence "got=$slotCommon want=$ExpectedCommonDir"; return 'quarantined'
  }
  try { Assert-NoEscapingReparsePoints -Root $spath } catch {
    Set-FleetPoolQuarantine -Slot $Slot -Reason 'escaping_reparse' -Evidence $_.Exception.Message; return 'quarantined'
  }
  if (Test-FleetPoolDepRootIsReparse -SlotPath $spath) { Set-FleetPoolQuarantine -Slot $Slot -Reason 'dep_root_reparse' -Evidence $spath; return 'quarantined' }
  if (Test-FleetPoolSlotDirty -SlotPath $spath) { Set-FleetPoolQuarantine -Slot $Slot -Reason 'dirty_tracked_or_index' -Evidence 'status porcelain non-empty'; return 'quarantined' }
  try {
    Invoke-FleetPoolSanitizeSlot -SlotPath $spath
    $prevEap = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $null = @(& git -C $spath checkout --detach HEAD 2>&1); $detCode = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
    if ($detCode -ne 0) { throw "detach failed exit $detCode" }
    if (Test-FleetPoolSlotDirty -SlotPath $spath) { throw 'still dirty after sanitation' }
    if (Test-FleetPoolDepRootIsReparse -SlotPath $spath) { throw 'dep root became reparse' }
    Assert-NoEscapingReparsePoints -Root $spath
  } catch { Set-FleetPoolQuarantine -Slot $Slot -Reason 'sanitize_failed' -Evidence $_.Exception.Message; return 'quarantined' }
  Clear-FleetPoolSlotOwnership -Slot $Slot; return 'ready'
}
