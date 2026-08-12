function Get-FleetPoolWorktreeList {
  param([string]$RepoPath)
  $lines = @(& git -c core.quotePath=false -C $RepoPath worktree list --porcelain 2>$null)
  if ($LASTEXITCODE -ne 0) { throw "git worktree list failed for $RepoPath" }
  $list = New-Object System.Collections.ArrayList; $cur = $null
  foreach ($line in $lines) {
    if ($line -match '^worktree (.+)$') {
      if ($null -ne $cur) { [void]$list.Add($cur) }
      $rawPath = [string]$Matches[1]
      Assert-FleetPoolGitPathNotCQuoted -PathText $rawPath -Context 'worktree'
      $cur = [ordered]@{ path = [IO.Path]::GetFullPath($rawPath).TrimEnd('\') }
    } elseif ([string]::IsNullOrWhiteSpace($line) -and $null -ne $cur) { [void]$list.Add($cur); $cur = $null }
  }
  if ($null -ne $cur) { [void]$list.Add($cur) }; return @($list)
}
function Assert-FleetPoolGitPathNotCQuoted {
  param([string]$PathText, [string]$Context = 'git')
  if ($PathText.StartsWith('"') -or $PathText.EndsWith('"')) {
    throw "Refusing residual C-quoted $Context path: $PathText"
  }
}
function Test-FleetPoolWorktreeRegistered {
  param([string]$RepoPath, [string]$SlotPath)
  $want = [IO.Path]::GetFullPath($SlotPath).TrimEnd('\')
  foreach ($wt in @(Get-FleetPoolWorktreeList -RepoPath $RepoPath)) { if ([string]$wt.path -eq $want) { return $true } }
  return $false
}
function Repair-FleetPoolWorktreeRegistration {
  # `git worktree prune` can discard a secondary-worktree registration while its
  # checkout is still usable. Repair is non-destructive; callers quarantine only
  # after repair and a fresh registration verification both fail.
  param([string]$RepoPath, [string]$SlotPath)
  if (Test-FleetPoolWorktreeRegistered -RepoPath $RepoPath -SlotPath $SlotPath) {
    return [pscustomobject]@{ Registered = $true; Repaired = $false; Evidence = '' }
  }
  if (-not (Test-Path -LiteralPath $SlotPath -PathType Container)) {
    return [pscustomobject]@{ Registered = $false; Repaired = $false; Evidence = "slot path missing: $SlotPath" }
  }
  $repairOutput = @(); $repairCode = -1; $previousEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $repairOutput = @(& git -C $RepoPath worktree repair -- $SlotPath 2>&1)
    $repairCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previousEap }
  if ($repairCode -eq 0 -and (Test-FleetPoolWorktreeRegistered -RepoPath $RepoPath -SlotPath $SlotPath)) {
    return [pscustomobject]@{ Registered = $true; Repaired = $true; Evidence = '' }
  }
  $detail = (($repairOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()
  if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
  if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "git worktree repair exit $repairCode" }
  return [pscustomobject]@{ Registered = $false; Repaired = $false; Evidence = $detail }
}
function Lock-FleetPoolWorktree {
  # Locks intentionally persist across release/sanitation; only teardown may unlock.
  param([string]$RepoPath, [string]$SlotPath)
  if (Test-FleetPoolWorktreeLocked -RepoPath $RepoPath -SlotPath $SlotPath) { return }
  $lockCode = -1; $previousEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $null = @(& git -C $RepoPath worktree lock --reason fleet-pool -- $SlotPath 2>&1)
    $lockCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previousEap }
  if ($lockCode -ne 0) { throw "git worktree lock failed for $SlotPath (exit $lockCode)" }
}
function Test-FleetPoolWorktreeLocked {
  param([string]$RepoPath, [string]$SlotPath)
  $lines = @(& git -c core.quotePath=false -C $RepoPath worktree list --porcelain 2>$null)
  if ($LASTEXITCODE -ne 0) { throw "git worktree list failed while checking lock for $SlotPath" }
  $want = [IO.Path]::GetFullPath($SlotPath).TrimEnd('\')
  $current = $null
  foreach ($line in $lines) {
    if ($line -match '^worktree (.+)$') {
      $current = [IO.Path]::GetFullPath([string]$Matches[1]).TrimEnd('\')
    } elseif ([string]$line -match '^locked(?:\s|$)' -and $null -ne $current -and $current.Equals($want, [StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}
function Get-FleetPoolSlotCommonDir {
  param([string]$SlotPath)
  $raw = @(& git -c core.quotePath=false -C $SlotPath rev-parse --git-common-dir 2>$null)
  if ($LASTEXITCODE -ne 0 -or $raw.Count -lt 1) { return $null }
  $s = [string]$raw[0]; Assert-FleetPoolGitPathNotCQuoted -PathText $s -Context 'common-dir'; if (-not [IO.Path]::IsPathRooted($s)) { $s = Join-Path $SlotPath $s }
  try { return [IO.Path]::GetFullPath($s).TrimEnd('\') } catch { return $null }
}
function Test-FleetPoolSlotDirty {
  param([string]$SlotPath)
  try { $entries = @(Get-FleetPoolGitStatusEntries -SlotPath $SlotPath) } catch { return $true }
  foreach ($entry in $entries) { if ([string]$entry.Status -ne '!!') { return $true } }
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
function ConvertTo-FleetPoolNativeArgument {
  param([AllowEmptyString()][string]$Token)
  if ($null -eq $Token -or $Token.Length -eq 0) { return '""' }
  if ($Token -notmatch '[\s"]') { return $Token }
  return '"' + ($Token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}
function Invoke-FleetPoolGitBytes {
  # PowerShell's native-command text pipeline is line oriented. Git porcelain
  # is a byte protocol, so capture stdout as bytes to preserve NUL delimiters
  # and filenames containing whitespace verbatim.
  param([Parameter(Mandatory)][string]$SlotPath, [Parameter(Mandatory)][string[]]$Arguments)
  $tokens = @('-c', 'core.quotePath=false', '-C', $SlotPath) + @($Arguments)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = (@($tokens | ForEach-Object { ConvertTo-FleetPoolNativeArgument -Token ([string]$_) }) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outBytes = New-Object System.IO.MemoryStream
  try {
    $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($outBytes)
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(60000)) { try { $proc.Kill() } catch { }; throw 'git status timed out' }
    if (-not $outTask.Wait(5000)) { throw 'git stdout drain timed out' }
    if (-not $errTask.Wait(5000)) { throw 'git stderr drain timed out' }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOutBytes = $outBytes.ToArray(); StdErr = [string]$errTask.Result }
  } finally { $outBytes.Dispose(); $proc.Dispose() }
}
function Get-FleetPoolGitStatusEntries {
  param([Parameter(Mandatory)][string]$SlotPath, [switch]$IncludeIgnored)
  $args = @('status', '--porcelain=v1', '-z', '-uall')
  if ($IncludeIgnored) { $args += '--ignored' }
  $result = Invoke-FleetPoolGitBytes -SlotPath $SlotPath -Arguments $args
  if ($result.ExitCode -ne 0) { throw "git status failed for ${SlotPath} (exit $($result.ExitCode)): $($result.StdErr)" }
  $texts = New-Object System.Collections.ArrayList
  $start = 0; $bytes = [byte[]]$result.StdOutBytes
  for ($ix = 0; $ix -lt $bytes.Length; $ix++) {
    if ($bytes[$ix] -ne 0) { continue }
    if ($ix -gt $start) { [void]$texts.Add([Text.Encoding]::UTF8.GetString($bytes, $start, $ix - $start)) }
    $start = $ix + 1
  }
  if ($start -ne $bytes.Length) { throw 'git porcelain -z output had an unterminated record' }
  $entries = New-Object System.Collections.ArrayList
  for ($ix = 0; $ix -lt $texts.Count; $ix++) {
    $record = [string]$texts[$ix]
    if ($record.Length -lt 3 -or $record[2] -ne ' ') { throw "Malformed git porcelain status record: $record" }
    $status = $record.Substring(0, 2); $pathText = $record.Substring(3)
    Assert-FleetPoolGitPathNotCQuoted -PathText $pathText -Context 'status'
    $origPath = $null
    if ($status[0] -in @('R', 'C') -or $status[1] -in @('R', 'C')) {
      $ix++
      if ($ix -ge $texts.Count) { throw "Malformed git porcelain rename/copy record: $record" }
      $origPath = [string]$texts[$ix]
      Assert-FleetPoolGitPathNotCQuoted -PathText $origPath -Context 'status-origin'
    }
    [void]$entries.Add([pscustomobject]@{ Status = $status; Path = $pathText; OriginalPath = $origPath })
  }
  return @($entries)
}
function Invoke-FleetPoolSanitizeSlot {
  param([string]$SlotPath)
  Assert-NoEscapingReparsePoints -Root $SlotPath
  if (Test-FleetPoolDepRootIsReparse -SlotPath $SlotPath) { throw "dependency root is a reparse point (blocks sanitation): $SlotPath" }
  $entries = @(Get-FleetPoolGitStatusEntries -SlotPath $SlotPath -IncludeIgnored)
  $toRemove = New-Object System.Collections.ArrayList
  foreach ($entry in $entries) {
    if ([string]$entry.Status -ne '!!') { continue }
    $rel = [string]$entry.Path
    Assert-FleetPoolGitPathNotCQuoted -PathText $rel -Context 'ignored'
    if ([string]::IsNullOrWhiteSpace($rel)) { continue }
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
  $registration = Repair-FleetPoolWorktreeRegistration -RepoPath $RepoPath -SlotPath $spath
  if (-not $registration.Registered) {
    Set-FleetPoolQuarantine -Slot $Slot -Reason 'worktree_registration_mismatch' -Evidence $registration.Evidence; return 'quarantined'
  }
  try { Lock-FleetPoolWorktree -RepoPath $RepoPath -SlotPath $spath } catch {
    Set-FleetPoolQuarantine -Slot $Slot -Reason 'worktree_lock_failed' -Evidence $_.Exception.Message; return 'quarantined'
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
    try { $ErrorActionPreference = 'Continue'; $null = @(& git -c core.quotePath=false -C $spath checkout --detach HEAD 2>&1); $detCode = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
    if ($detCode -ne 0) { throw "detach failed exit $detCode" }
    $runBranch = [string]$Slot.branch
    if (-not [string]::IsNullOrWhiteSpace($runBranch)) {
      $branchRun = [string]$Slot.run_id
      if ([string]::IsNullOrWhiteSpace($branchRun)) { $branchRun = [string]$Slot.last_run_id }
      $expectedBranch = "fleet/$branchRun"
      if ($runBranch -cne $expectedBranch) { throw "slot branch does not match its run: '$runBranch' vs '$expectedBranch'" }
      # Release detaches the reusable checkout but deliberately retains the
      # run branch for merge, audit, and explicit owner-directed pruning.
      $prevEap = $ErrorActionPreference
      try { $ErrorActionPreference = 'Continue'; $null = @(& git -c core.quotePath=false -C $spath worktree prune 2>&1); $pruneCode = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
      if ($pruneCode -ne 0) { throw "worktree prune failed exit $pruneCode" }
    }
    if (Test-FleetPoolSlotDirty -SlotPath $spath) { throw 'still dirty after sanitation' }
    if (Test-FleetPoolDepRootIsReparse -SlotPath $spath) { throw 'dep root became reparse' }
    Assert-NoEscapingReparsePoints -Root $spath
  } catch { Set-FleetPoolQuarantine -Slot $Slot -Reason 'sanitize_failed' -Evidence $_.Exception.Message; return 'quarantined' }
  Clear-FleetPoolSlotOwnership -Slot $Slot; return 'ready'
}
