# Automatic reclaim of abandoned run-owned worktrees. Ambiguity = SKIP (never delete).
# CLI default Mode=Report. Enter-FleetRunLease invokes Apply after mutex release.
# NEVER: rd, Remove-Item -Recurse, robocopy /MIR|/PURGE, generic recursive walker.
[CmdletBinding()]
param(
  [ValidateSet('Report', 'Apply')][string]$Mode = 'Report',
  [ValidateRange(1, 8760)][int]$MinAgeHours = 72,
  # Bare orphan dirs (no git identity at all) quarantine after this age; quarantined dirs
  # untouched for QuarantinePurgeAgeHours more are purged. Two-stage, reversible in stage 1.
  [ValidateRange(1, 8760)][int]$OrphanQuarantineAgeHours = 336,
  [ValidateRange(1, 8760)][int]$QuarantinePurgeAgeHours = 336,
  # Registered non-fleet-branch worktrees (work-guard class) wait longer than run-owned trees
  # before quarantine — they may be deliberate user workspaces (Terra H4 2026-08-11).
  [ValidateRange(1, 8760)][int]$RegisteredGuardAgeHours = 168,
  [string]$WorktreeRoot = '',
  [string]$ReportPath = ''
)
$ErrorActionPreference = 'Stop'
$script:JanitorUtf8 = New-Object System.Text.UTF8Encoding $false
$script:JanitorPurge = Join-Path $PSScriptRoot 'purge_orphan_tree.py'
$script:JanitorReposPruned = @{}
$script:JanitorCwdReady = $false
. (Join-Path $PSScriptRoot 'FleetWorktreeJanitor.Helpers.ps1')
if ($env:FLEET_JANITOR_FORCE_FAIL -eq '1') { throw 'forced janitor failure for tests' }
if ([string]::IsNullOrWhiteSpace($WorktreeRoot)) {
  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw 'USERPROFILE is not set.' }
  $WorktreeRoot = Join-Path $env:USERPROFILE '.codex\worktrees'
}
$WorktreeRoot = [IO.Path]::GetFullPath($WorktreeRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path ([IO.Path]::GetTempPath()) ('fleet-janitor-' + [guid]::NewGuid().ToString('n') + '.json')
}
$ReportPath = [IO.Path]::GetFullPath($ReportPath)

function Write-JanitorErr([string]$Message) { [Console]::Error.WriteLine($Message) }
function Get-JanitorBytesEstimate([string]$Path) {
  $total = [int64]0
  try {
    $stack = New-Object System.Collections.Stack; $stack.Push([IO.Path]::GetFullPath($Path))
    while ($stack.Count -gt 0) {
      foreach ($child in @(Get-ChildItem -LiteralPath ([string]$stack.Pop()) -Force -ErrorAction SilentlyContinue)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if ($child.PSIsContainer) { $stack.Push($child.FullName) } else { try { $total += [int64]$child.Length } catch { } }
      }
    }
  } catch { }
  return $total
}
function Get-JanitorAgeHours([string]$Path, $Sidecar) {
  $newest = [datetime]::MinValue
  try { $newest = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).LastWriteTimeUtc } catch { }
  if ($null -ne $Sidecar -and $Sidecar.created_utc) {
    try { $cu = [datetimeoffset]::Parse([string]$Sidecar.created_utc).UtcDateTime; if ($cu -gt $newest) { $newest = $cu } } catch { }
  }
  if ($newest -eq [datetime]::MinValue) { return 0.0 }
  return [math]::Round(([datetime]::UtcNow - $newest).TotalHours, 3)
}
function Test-JanitorReparseTargetOk($item) {
  foreach ($t in @($item.Target)) { if (-not [string]::IsNullOrWhiteSpace([string]$t)) { return $true } }
  return $false
}
function Test-JanitorHasUnresolvedReparse([string]$Path) {
  try {
    $stack = New-Object System.Collections.Stack; $stack.Push([IO.Path]::GetFullPath($Path))
    while ($stack.Count -gt 0) {
      $dir = [string]$stack.Pop()
      $item = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        if (-not (Test-JanitorReparseTargetOk $item)) { return $true }; continue
      }
      foreach ($child in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          $t2 = $null; try { $t2 = Get-Item -LiteralPath $child.FullName -Force } catch { }
          if ($null -eq $t2 -or -not (Test-JanitorReparseTargetOk $t2)) { return $true }; continue
        }
        if ($child.PSIsContainer) { $stack.Push($child.FullName) }
      }
    }
  } catch { return $true }
  return $false
}
function Get-JanitorGitInfo([string]$Path, $Sidecar) {
  # Corroborated = fleet/<run_id> branch OR registered under explicit sidecar.repo_path/git_common_dir.
  $repoPath = $null; $registered = $false; $branch = ''; $corroborated = $false
  $scRepo = $null; $scGcd = $null; $commonFull = $null
  if ($null -ne $Sidecar) {
    if (-not [string]::IsNullOrWhiteSpace([string]$Sidecar.repo_path)) {
      try { $scRepo = [IO.Path]::GetFullPath([string]$Sidecar.repo_path).TrimEnd('\') } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Sidecar.git_common_dir)) {
      try { $scGcd = [IO.Path]::GetFullPath([string]$Sidecar.git_common_dir).TrimEnd('\') } catch { }
    }
    if ($null -ne $scRepo) { $repoPath = $scRepo }
    elseif ($null -ne $scGcd) { $repoPath = if ((Split-Path -Leaf $scGcd) -eq '.git') { Split-Path -Parent $scGcd } else { $scGcd } }
  }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $head = @(& git -C $Path rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $head.Count -gt 0) { $branch = [string]$head[0] }
    $common = @(& git -C $Path rev-parse --git-common-dir 2>$null)
    if ($LASTEXITCODE -eq 0 -and $common.Count -gt 0) {
      $c = [string]$common[0]; if (-not [IO.Path]::IsPathRooted($c)) { $c = Join-Path $Path $c }
      $commonFull = [IO.Path]::GetFullPath($c).TrimEnd('\')
      if ([string]::IsNullOrWhiteSpace($repoPath)) {
        $repoPath = if ((Split-Path -Leaf $commonFull) -eq '.git') { Split-Path -Parent $commonFull } else { Split-Path -Parent $commonFull }
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($repoPath) -and (Test-Path -LiteralPath $repoPath)) {
      $want = [IO.Path]::GetFullPath($Path).TrimEnd('\')
      $repoFull = [IO.Path]::GetFullPath($repoPath).TrimEnd('\')
      # Primary checkout (path == repo root) is not a linked worktree; use purge, not worktree remove.
      if (-not $want.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
        $lines = @(& git -C $repoPath worktree list --porcelain 2>$null)
        if ($LASTEXITCODE -eq 0) {
          foreach ($line in $lines) {
            if ($line -match '^worktree (.+)$') {
              if ([IO.Path]::GetFullPath($Matches[1]).TrimEnd('\').Equals($want, [StringComparison]::OrdinalIgnoreCase)) { $registered = $true; break }
            }
          }
        }
      }
    }
    if ($null -ne $Sidecar) {
      $rid = [string]$Sidecar.run_id
      $repoMatches = ($null -ne $scRepo -and $null -ne $repoPath -and $repoPath.Equals($scRepo, [StringComparison]::OrdinalIgnoreCase))
      $commonMatches = ($null -ne $scGcd -and $null -ne $commonFull -and $commonFull.Equals($scGcd, [StringComparison]::OrdinalIgnoreCase))
      $branchMatches = (-not [string]::IsNullOrWhiteSpace($rid) -and $branch.Equals(('fleet/' + $rid), [StringComparison]::OrdinalIgnoreCase))
      # A candidate's HEAD cannot authorize deletion.  Require independent
      # worktree registration, trusted repository/common-dir agreement, and run branch.
      if ($registered -and $repoMatches -and $commonMatches -and $branchMatches) { $corroborated = $true }
    }
  } catch { } finally { $ErrorActionPreference = $prev }
  return @{ RepoPath = $repoPath; Registered = $registered; Branch = $branch; Corroborated = $corroborated }
}
function New-JanitorRow {
  param([string]$Path, [string]$Action, [string]$Reason, [string]$RunId = '', [string]$Ownership = '',
    [double]$AgeHours = 0, [int64]$Bytes = 0, [string]$DeleteVia = '', [string]$Command = '')
  return [ordered]@{
    path = $Path; run_id = $RunId; ownership = $Ownership; age_hours = $AgeHours
    bytes_estimate = $Bytes; action = $Action; reason = $Reason; delete_via = $DeleteVia; command = $Command
  }
}
function Get-JanitorDeletePreview([bool]$Registered, [string]$RepoPath, [string]$Path, [bool]$UseForce = $true) {
  if ($Registered -and -not [string]::IsNullOrWhiteSpace($RepoPath)) {
    $forceArg = if ($UseForce) { '--force ' } else { '' }
    return @{ Via = 'git_worktree_remove'; Command = ('git -C "' + $RepoPath + '" worktree remove ' + $forceArg + '-- "' + $Path + '"') }
  }
  return @{ Via = 'purge_orphan_tree'; Command = ('python "' + $script:JanitorPurge + '" "' + $Path + '"') }
}
function Invoke-JanitorDelete {
  # UseForce=$false for trees admitted only via registration (work guards): git's own
  # dirty/locked refusal then acts as a second, independent data-loss guard.
  param([string]$Path, [bool]$Registered, [string]$RepoPath, [bool]$UseForce = $true)
  $cmds = New-Object System.Collections.ArrayList
  if ($Registered -and -not [string]::IsNullOrWhiteSpace($RepoPath)) {
    $gitArgs = @('-C', $RepoPath, 'worktree', 'remove')
    if ($UseForce) { $gitArgs += '--force' }
    $gitArgs += @('--', $Path)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& git @gitArgs 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    $forceArg = if ($UseForce) { '--force ' } else { '' }
    [void]$cmds.Add(('git -C "' + $RepoPath + '" worktree remove ' + $forceArg + '-- "' + $Path + '"'))
    if ($code -ne 0) { throw ("git worktree remove failed (exit $code): " + ($out -join ' ')) }
    $via = 'git_worktree_remove'
  } else {
    if (-not (Test-Path -LiteralPath $script:JanitorPurge -PathType Leaf)) { throw "purge_orphan_tree.py missing: $($script:JanitorPurge)" }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& python $script:JanitorPurge $Path 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    [void]$cmds.Add(('python "' + $script:JanitorPurge + '" "' + $Path + '"'))
    if ($code -ne 0) { throw ("purge_orphan_tree failed (exit $code): " + ($out -join ' ')) }
    $via = 'purge_orphan_tree'
  }
  if (-not [string]::IsNullOrWhiteSpace($RepoPath) -and -not $script:JanitorReposPruned.ContainsKey($RepoPath.ToLowerInvariant())) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = & git -C $RepoPath worktree prune --expire now 2>&1 } catch { }
    finally { $ErrorActionPreference = $prev }
    $script:JanitorReposPruned[$RepoPath.ToLowerInvariant()] = $true
    [void]$cmds.Add('git -C "' + $RepoPath + '" worktree prune --expire now')
  }
  $sc = Get-JanitorSidecarPath $Path
  if (Test-Path -LiteralPath $sc -PathType Leaf) { try { Remove-Item -LiteralPath $sc -Force -ErrorAction Stop } catch { } }
  return @{ Via = $via; Command = ($cmds -join ' && ') }
}

Write-JanitorErr ('fleet-lease-order: janitor-begin mode=' + $Mode)
$janitorMutex = $null; $hasJanitorMutex = $false
if ($Mode -eq 'Apply') {
  try {
    $janitorMutex = New-Object System.Threading.Mutex($false, 'Global\FleetWorktreeJanitorApply')
    $hasJanitorMutex = $janitorMutex.WaitOne(30000)
    if (-not $hasJanitorMutex) { throw 'Timed out waiting for janitor Apply mutex' }
  } catch {
    if ($null -ne $janitorMutex) { $janitorMutex.Dispose() }
    throw
  }
}
try {
$candidates = New-Object System.Collections.ArrayList
$scanned = 0
$nowUtc = [datetimeoffset]::UtcNow.ToString('o')

if (-not (Test-Path -LiteralPath $WorktreeRoot -PathType Container)) {
  $report = [ordered]@{
    schema_version = '1'; mode = $Mode; worktree_root = $WorktreeRoot; min_age_hours = $MinAgeHours
    generated_utc = $nowUtc; candidates = @()
    summary = [ordered]@{ scanned = 0; removable = 0; skipped = 0; removed = 0; quarantined = 0; errors = 0 }
  }
} else {
  $dirs = New-Object System.Collections.ArrayList
  foreach ($top in @(Get-ChildItem -LiteralPath $WorktreeRoot -Directory -Force -ErrorAction SilentlyContinue)) {
    if (($top.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) { continue }
    if ($top.Name -eq '.fleet-quarantine') { continue }
    $nested = @(Get-ChildItem -LiteralPath $top.FullName -Directory -Force -ErrorAction SilentlyContinue)
    $addedNested = $false
    foreach ($child in $nested) {
      if ($child.Name -eq '.fleet-pool') { continue }
      [void]$dirs.Add($child.FullName); $addedNested = $true
    }
    if (-not $addedNested -or (Test-Path -LiteralPath (Join-Path $top.FullName '.git'))) { [void]$dirs.Add($top.FullName) }
  }

  foreach ($dir in @($dirs)) {
    $scanned++
    $full = [IO.Path]::GetFullPath($dir).TrimEnd('\')
    $name = Split-Path -Leaf $full
    try {
      $sidecar = Read-JanitorSidecar $full
      $runId = ''; $ownership = ''; $gitInfo = $null; $needsWorkGuards = $false
      if ($null -ne $sidecar) {
        # Sidecar only NOMINATES; needs canonical-root + independent git admin proof.
        $runId = [string]$sidecar.run_id; $ownership = 'run-owned'
        if (-not (Test-JanitorUnderRoot -Path $full -Root $WorktreeRoot)) {
          [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason 'outside_worktree_root' -RunId $runId -Ownership 'ambiguous')); continue
        }
        $gitInfo = Get-JanitorGitInfo -Path $full -Sidecar $sidecar
        if (-not [bool]$gitInfo.Corroborated) {
          [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason 'ownership_ambiguous' -RunId $runId -Ownership 'ambiguous')); continue
        }
      } else {
        $gitInfo = Get-JanitorGitInfo -Path $full -Sidecar $null
        $legacyName = Test-JanitorLegacyName $name
        $legacyBranch = (-not [string]::IsNullOrEmpty($gitInfo.Branch) -and $gitInfo.Branch -match '^fleet/[A-Za-z0-9._-]+$')
        # Two independent admission proofs for sidecar-less trees:
        #  - fleet/* branch + legacy name (original rule, run-owned semantics), or
        #  - REGISTERED linked worktree (the repository's own worktree metadata names this
        #    path) under the agent-owned root; those additionally require the clean +
        #    no-unmerged-commits work guards below before deletion.
        if (-not (($legacyName -and $legacyBranch) -or [bool]$gitInfo.Registered)) {
          # Bare orphan (no git identity at all): two-stage quarantine instead of skip.
          if ((Test-JanitorUnderRoot -Path $full -Root $WorktreeRoot) -and (Test-JanitorBareOrphan $full)) {
            $bytes = Get-JanitorBytesEstimate $full
            $age = Get-JanitorAgeHours -Path $full -Sidecar $null
            $oSkip = $null
            if (Test-JanitorPoolMarker $full) { $oSkip = 'pool_marker' }
            elseif ($age -lt [double]$OrphanQuarantineAgeHours) { $oSkip = 'too_young' }
            elseif (Test-JanitorLiveProcessHit $full) { $oSkip = 'live_process' }
            if ($null -ne $oSkip) {
              [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason $oSkip -Ownership 'orphan' -AgeHours $age -Bytes $bytes)); continue
            }
            if ($Mode -eq 'Report') {
              [void]$candidates.Add((New-JanitorRow -Path $full -Action 'would_quarantine' -Reason 'aged_bare_orphan' -Ownership 'orphan' -AgeHours $age -Bytes $bytes -DeleteVia 'quarantine_move')); continue
            }
            if ((Test-JanitorPoolMarker $full) -or (Test-JanitorLiveProcessHit $full) -or -not (Test-JanitorBareOrphan $full)) {
              [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason 'orphan_recheck' -Ownership 'orphan' -AgeHours $age -Bytes $bytes)); continue
            }
            try {
              $dest = Move-JanitorToQuarantine -Path $full -WorktreeRoot $WorktreeRoot
              [void]$candidates.Add((New-JanitorRow -Path $full -Action 'quarantined' -Reason 'aged_bare_orphan' -Ownership 'orphan' -AgeHours $age -Bytes $bytes -DeleteVia 'quarantine_move' -Command ('move -> ' + $dest)))
            } catch {
              [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason ('quarantine_failed: ' + $_.Exception.Message) -Ownership 'orphan' -AgeHours $age -Bytes $bytes))
            }
            continue
          }
          [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason 'ownership_ambiguous' -Ownership 'ambiguous')); continue
        }
        if (-not (Test-JanitorUnderRoot -Path $full -Root $WorktreeRoot)) {
          [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason 'outside_worktree_root' -Ownership 'ambiguous')); continue
        }
        $ownership = 'legacy'
        $needsWorkGuards = (-not $legacyBranch)
        if ($gitInfo.Branch -match '^fleet/(.+)$') { $runId = $Matches[1] } else { $runId = $name }
      }
      $bytes = Get-JanitorBytesEstimate $full
      $age = Get-JanitorAgeHours -Path $full -Sidecar $sidecar
      $skipReason = $null
      if (Test-JanitorPoolMarker $full) { $skipReason = 'pool_marker' }
      elseif (Test-JanitorLiveLease $runId) { $skipReason = 'live_lease' }
      elseif ($age -lt [double]$MinAgeHours) { $skipReason = 'too_young' }
      elseif (Test-JanitorLiveProcessHit $full) { $skipReason = 'live_process' }
      elseif (Test-JanitorHasUnresolvedReparse $full) { $skipReason = 'unresolved_reparse' }
      elseif ($needsWorkGuards -and $age -lt [double]$RegisteredGuardAgeHours) { $skipReason = 'too_young_registered' }
      elseif ($needsWorkGuards -and -not (Test-JanitorTreeClean $full)) { $skipReason = 'dirty_tree' }
      elseif ($needsWorkGuards -and -not (Test-JanitorNoUnmergedCommits $full ([string]$gitInfo.Branch))) { $skipReason = 'unmerged_commits' }
      if ($null -ne $skipReason) {
        [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason $skipReason -RunId $runId -Ownership $ownership -AgeHours $age -Bytes $bytes)); continue
      }
      # NO hard-delete at scan level (Sol H7 + Terra H4 2026-08-11): every eligible tree —
      # run-owned, fleet-branch legacy, or registered work-guard class — is quarantined
      # (reversible, QuarantinePurgeAgeHours retention) and its stale registration pruned.
      # purge_orphan_tree runs only on quarantine-expired entries.
      $prevw = @{ Via = 'quarantine_move+worktree_prune'; Command = ('move -> ' + (Get-JanitorQuarantineRoot $WorktreeRoot)) }
      $eligibleReason = if ($needsWorkGuards) { 'aged_registered_worktree' } else { 'aged_run_owned' }
      if ($Mode -eq 'Report') {
        [void]$candidates.Add((New-JanitorRow -Path $full -Action 'would_quarantine' -Reason $eligibleReason -RunId $runId -Ownership $ownership -AgeHours $age -Bytes $bytes -DeleteVia $prevw.Via -Command $prevw.Command))
        continue
      }
      # Re-check ownership/pool/lease/process/reparse immediately before each deletion.
      $recheck = $null
      if ($null -ne $sidecar) {
        $sc2 = Read-JanitorSidecar $full
        if ($null -eq $sc2) { $recheck = 'ownership_recheck' }
        else {
          $gitInfo = Get-JanitorGitInfo -Path $full -Sidecar $sc2
          if (-not [bool]$gitInfo.Corroborated) { $recheck = 'ownership_recheck' } else { $runId = [string]$sc2.run_id }
        }
      }
      if ($null -eq $recheck) {
        if (Test-JanitorPoolMarker $full) { $recheck = 'pool_marker_recheck' }
        elseif (Test-JanitorLiveLease $runId) { $recheck = 'live_lease_recheck' }
        elseif (Test-JanitorLiveProcessHit $full) { $recheck = 'live_process_recheck' }
        elseif (Test-JanitorHasUnresolvedReparse $full) { $recheck = 'reparse_recheck' }
        elseif ($needsWorkGuards -and -not (Test-JanitorTreeClean $full)) { $recheck = 'dirty_tree_recheck' }
        elseif ($needsWorkGuards -and -not (Test-JanitorNoUnmergedCommits $full ([string]$gitInfo.Branch))) { $recheck = 'unmerged_recheck' }
      }
      if ($null -ne $recheck) {
        $own = if ($recheck -eq 'ownership_recheck') { 'ambiguous' } else { $ownership }
        [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason $recheck -RunId $runId -Ownership $own -AgeHours $age -Bytes $bytes)); continue
      }
      try {
        $dest = Move-JanitorToQuarantine -Path $full -WorktreeRoot $WorktreeRoot
        $rp = [string]$gitInfo.RepoPath
        if (-not [string]::IsNullOrWhiteSpace($rp)) {
          $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
          try { $null = & git -C $rp worktree prune --expire now 2>&1 } catch { } finally { $ErrorActionPreference = $prevEap }
        }
        $sc = Get-JanitorSidecarPath $full
        if (Test-Path -LiteralPath $sc -PathType Leaf) { try { Remove-Item -LiteralPath $sc -Force -ErrorAction Stop } catch { } }
        [void]$candidates.Add((New-JanitorRow -Path $full -Action 'quarantined' -Reason $eligibleReason -RunId $runId -Ownership $ownership -AgeHours $age -Bytes $bytes -DeleteVia 'quarantine_move+worktree_prune' -Command ('move -> ' + $dest)))
      } catch {
        [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason ('delete_failed: ' + $_.Exception.Message) -RunId $runId -Ownership $ownership -AgeHours $age -Bytes $bytes -DeleteVia $prevw.Via -Command $prevw.Command))
      }
    } catch {
      [void]$candidates.Add((New-JanitorRow -Path $full -Action 'skip' -Reason ('enumeration_error: ' + $_.Exception.Message) -Ownership 'unknown'))
    }
  }

  Invoke-JanitorQuarantineSweep -WorktreeRoot $WorktreeRoot -Mode $Mode -PurgeAgeHours $QuarantinePurgeAgeHours -Candidates $candidates -Scanned ([ref]$scanned)

  $candArr = @($candidates)
  $removable = @($candArr | Where-Object { $_.action -eq 'would_remove' -or $_.action -eq 'removed' -or $_.action -eq 'would_quarantine' -or $_.action -eq 'quarantined' }).Count
  $skipped = @($candArr | Where-Object { $_.action -eq 'skip' }).Count
  $removed = @($candArr | Where-Object { $_.action -eq 'removed' }).Count
  $quarantined = @($candArr | Where-Object { $_.action -eq 'quarantined' }).Count
  $errors = @($candArr | Where-Object { $_.reason -like 'delete_failed*' -or $_.reason -like 'enumeration_error*' -or $_.reason -like 'quarantine_failed*' }).Count
  $report = [ordered]@{
    schema_version = '1'; mode = $Mode; worktree_root = $WorktreeRoot; min_age_hours = $MinAgeHours
    generated_utc = $nowUtc; candidates = [object[]]$candArr
    summary = [ordered]@{ scanned = $scanned; removable = $removable; skipped = $skipped; removed = $removed; quarantined = $quarantined; errors = $errors }
  }
}

$reportParent = Split-Path -Parent $ReportPath
if ($reportParent -and -not (Test-Path -LiteralPath $reportParent)) { New-Item -ItemType Directory -Force -Path $reportParent | Out-Null }
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 6), $script:JanitorUtf8)
Write-JanitorErr ('fleet-janitor: mode=' + $Mode + ' report=' + $ReportPath + ' scanned=' + $report.summary.scanned + ' removable=' + $report.summary.removable + ' removed=' + $report.summary.removed + ' quarantined=' + $report.summary.quarantined + ' skipped=' + $report.summary.skipped)
} finally {
  if ($hasJanitorMutex) { try { $janitorMutex.ReleaseMutex() } catch { } }
  if ($null -ne $janitorMutex) { $janitorMutex.Dispose() }
}
exit 0
