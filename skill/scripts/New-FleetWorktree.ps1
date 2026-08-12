# Canonical, junction-safe fleet worktree creator.
# Location: $env:USERPROFILE\.codex\worktrees\<repo-slug>\<RunId> (cold) or pool slot.
# Fail-closed: Documents, source-sibling, existing branch, missing CopyFile, escaping reparse, hollow install.
# PoolMode Auto/Require may return ownership=pool-slot. CALLER releases via Exit-FleetWorktreePoolSlot.ps1
# (New-FleetWorktree does not auto-release a pool slot).
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$RunId,
  [string]$BaseRef = 'HEAD',
  [string[]]$CopyFile = @(),
  [switch]$Install,
  [switch]$NoInstall,
  [string]$InstallCommand,
  [string]$NodeBinDir,
  [int]$InstallTimeoutSeconds = 1800,
  [ValidateSet('text', 'json')][string]$Mode = 'text',
  [ValidateSet('Auto', 'Require', 'Off')][string]$PoolMode = 'Auto',
  [string]$BuildCacheSpec
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetWorktreePool.State.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Liveness.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Sanitize.Helpers.ps1')

$script:exitCode = 1
$script:installStatus = 'skipped'
$script:copiedCount = 0
$script:depsCount = 0
$script:worktreePath = $null
$script:branchName = "fleet/$RunId"
$script:ownership = 'run-owned'
$script:slotId = ''
$script:leaseId = ''
$script:reuseHit = $false
$script:depFingerprint = ''
$script:poolFallbackReason = ''

function Write-Fail([string]$Message) { [Console]::Error.WriteLine($Message) }

function Test-SiblingOfSource([string]$WorktreePath, [string]$RepoPath) {
  $wtParent = [IO.Path]::GetFullPath((Split-Path -Parent $WorktreePath)).TrimEnd('\')
  $repoParent = [IO.Path]::GetFullPath((Split-Path -Parent $RepoPath)).TrimEnd('\')
  return $wtParent.Equals($repoParent, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DepsCount([string]$Root) {
  $nm = Join-Path $Root 'node_modules'
  if (-not (Test-Path -LiteralPath $nm)) { return 0 }
  return @(Get-ChildItem -LiteralPath $nm -Force -ErrorAction SilentlyContinue).Count
}

function Stop-Tree {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try { $processId = $Process.Id } catch { return }
  try { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null } catch { }
  try { $null = $Process.WaitForExit(5000) } catch { }
}

function Emit-Summary {
  param([string]$Path, [string]$Branch, [int]$Copied, [string]$Install, [int]$Deps)
  $own = $script:ownership; $slot = $script:slotId; $lease = $script:leaseId; $fp = $script:depFingerprint
  $rh = if ($script:reuseHit) { 'true' } else { 'false' }
  if ($Mode -eq 'json') {
    Write-Output (([ordered]@{
      worktree = $Path; branch = $Branch; copied = $Copied; install = $Install; deps = $Deps
      ownership = $own; slot = $slot; lease_id = $lease; reuse_hit = [bool]$script:reuseHit
      dependency_fingerprint = $fp; pool_fallback_reason = $script:poolFallbackReason
    } | ConvertTo-Json -Compress))
  } else {
    Write-Output ("worktree: $Path | branch: $Branch | copied: $Copied | install: $Install | deps: $Deps entries | ownership: $own | slot: $slot | lease_id: $lease | reuse_hit: $rh | dependency_fingerprint: $fp | pool_fallback_reason: $($script:poolFallbackReason)")
  }
}

function Invoke-Install {
  param([string]$WorktreeRoot, [string]$Command, [string]$BinDir, [int]$TimeoutSeconds)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'; $psi.Arguments = "/d /c $Command"; $psi.WorkingDirectory = $WorktreeRoot
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  if (-not [string]::IsNullOrWhiteSpace($BinDir)) {
    $psi.EnvironmentVariables['PATH'] = $BinDir.TrimEnd('\') + ';' + $psi.EnvironmentVariables['PATH']
  }
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync(); $stderrTask = $proc.StandardError.ReadToEndAsync()
  if (-not $proc.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
    Stop-Tree -Process $proc; $null = $stdoutTask.Wait(2000); $null = $stderrTask.Wait(2000); $proc.Dispose()
    throw "Install timed out after ${TimeoutSeconds}s: $Command"
  }
  $code = $proc.ExitCode
  $err = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { '' }
  $out = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { '' }
  $proc.Dispose()
  if ($code -ne 0) {
    if ($err) { Write-Fail $err.TrimEnd() }; if ($out) { Write-Fail $out.TrimEnd() }
    throw "Install exited ${code}: $Command"
  }
}

function Get-FleetCopyEntries([string[]]$RawCopy) {
  $copyEntries = New-Object System.Collections.ArrayList
  foreach ($item in @($RawCopy)) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    foreach ($piece in ([string]$item -split ',')) {
      $p = $piece.Trim(); if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$copyEntries.Add($p) }
    }
  }
  return ,@($copyEntries)
}

function Quote-FleetArgs([string[]]$Tokens) {
  (@($Tokens) | ForEach-Object {
    $token = [string]$_
    if ($token.Length -eq 0) { '""' }
    elseif ($token -notmatch '[\s"]') { $token }
    else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }) -join ' '
}

function Get-FleetPoolDispatchState([string]$RepoPath) {
  $ident = Resolve-FleetPoolRepoIdentity -Repo $RepoPath
  $statePath = Get-FleetPoolStatePath $ident.RepoKey
  $st = Read-FleetPoolStateWithRepoPath -StatePath $statePath -RepoKey $ident.RepoKey
  if ($null -eq $st) { return [pscustomobject]@{ Kind = 'absent'; Reason = 'pool_not_initialized' } }
  if ([string]$st.repo_key -ne $ident.RepoKey) { throw "Pool state repo-key mismatch: $statePath" }
  if ([string]$st.git_common_dir -ne $ident.CommonDir) { throw "Pool common-dir mismatch (state='$($st.git_common_dir)' repo='$($ident.CommonDir)')" }
  $stateRepoPath = [IO.Path]::GetFullPath([string]$st.repo_path).TrimEnd('\')
  if (-not $stateRepoPath.Equals($ident.RepoPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Pool repo-path mismatch (state='$stateRepoPath' repo='$($ident.RepoPath)')"
  }
  $slots = @($st.slots)
  if ($slots.Count -lt 1) { throw "Pool state has no slots: $statePath" }
  $ready = 0
  foreach ($slot in $slots) {
    $slotState = [string]$slot.state
    if (@('ready', 'acquired', 'preparing', 'provisioning', 'quarantined') -notcontains $slotState) {
      throw "Pool state has invalid slot state '$slotState': $statePath"
    }
    if ($slotState -eq 'ready') { $ready++ }
  }
  if ($ready -gt 0) { return [pscustomobject]@{ Kind = 'available'; Reason = '' } }
  return [pscustomobject]@{ Kind = 'exhausted'; Reason = 'all_slots_busy_or_quarantined' }
}

function Invoke-FleetPoolEnterChild {
  param([string]$RepoPath, [string]$RunIdVal, [string]$BaseRefVal, [string[]]$CopyFiles, [string]$InstallCmd, [string]$BinDir)
  $enterScript = Join-Path $PSScriptRoot 'Enter-FleetWorktreePoolSlot.ps1'
  $argTokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $enterScript,
    '-Repo', $RepoPath, '-RunId', $RunIdVal, '-BaseRef', $BaseRefVal, '-Mode', 'json')
  foreach ($cf in @($CopyFiles)) { if (-not [string]::IsNullOrWhiteSpace($cf)) { $argTokens += @('-CopyFile', $cf) } }
  if (-not [string]::IsNullOrWhiteSpace($InstallCmd)) { $argTokens += @('-InstallCommand', $InstallCmd) }
  if (-not [string]::IsNullOrWhiteSpace($BinDir)) { $argTokens += @('-NodeBinDir', $BinDir) }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'; $psi.Arguments = (Quote-FleetArgs -Tokens $argTokens)
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
  $null = $proc.WaitForExit(3600000)
  $code = if ($proc.HasExited) { $proc.ExitCode } else { try { $proc.Kill() } catch { }; -1 }
  $stdout = if ($outTask.Wait(5000)) { [string]$outTask.Result } else { '' }
  $stderr = if ($errTask.Wait(5000)) { [string]$errTask.Result } else { '' }
  $proc.Dispose()
  $json = $null
  foreach ($line in @($stdout -split "`r?`n")) {
    $t = $line.Trim()
    if ($t.StartsWith('{')) { try { $json = $t | ConvertFrom-Json -ErrorAction Stop } catch { } }
  }
  return [pscustomobject]@{ ExitCode = $code; Stdout = $stdout.TrimEnd(); Stderr = $stderr.TrimEnd(); Json = $json }
}

function Try-AcquireFleetPoolSlot {
  param([string]$RepoPath, [string]$RunIdVal, [string]$BaseRefVal, [string[]]$CopyFiles, [string]$InstallCmd, [string]$BinDir, [bool]$RequireMode, [int]$WaitSeconds = 30)
  $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(0, $WaitSeconds))
  $lastErr = 'No ready pool slot available'
  while ($true) {
    $r = Invoke-FleetPoolEnterChild -RepoPath $RepoPath -RunIdVal $RunIdVal -BaseRefVal $BaseRefVal -CopyFiles $CopyFiles -InstallCmd $InstallCmd -BinDir $BinDir
    if ($r.ExitCode -eq 0 -and $null -ne $r.Json -and $r.Json.ok -ne $false -and -not [string]::IsNullOrWhiteSpace([string]$r.Json.path)) { return $r }
    $errMsg = ''
    if ($null -ne $r.Json -and $r.Json.error) { $errMsg = [string]$r.Json.error }
    if ([string]::IsNullOrWhiteSpace($errMsg)) { $errMsg = $r.Stderr }
    if ([string]::IsNullOrWhiteSpace($errMsg)) { $errMsg = $r.Stdout }
    $lastErr = $errMsg
    # Bounded wait only for transient exhaustion; missing/broken pool fails immediately.
    $exhaust = ($errMsg -match 'No ready pool slot')
    if (-not $exhaust) {
      # Prepare/branch failures must not silent-cold-fallback (fleet/<RunId> already exists).
      if ($RequireMode) { throw "Pool acquire failed (Require, no cold fallback): $lastErr" }
      throw "Pool acquire failed (no cold fallback after failed enter): $lastErr"
    }
    if (-not $RequireMode) { return $null }
    if ([datetime]::UtcNow -ge $deadline) { throw "Pool acquire failed after wait (Require, no cold fallback): $lastErr" }
    Start-Sleep -Seconds 1
  }
}

function Copy-FleetWorktreeFiles {
  param([string]$RepoPath, [string]$DestRoot, [string[]]$RawCopy)
  $copyEntries = Get-FleetCopyEntries -RawCopy $RawCopy
  $repoRootFull = [IO.Path]::GetFullPath($RepoPath).TrimEnd('\'); $count = 0
  foreach ($rel in @($copyEntries)) {
    $norm = $rel -replace '/', '\'
    if ($norm -match '(^|\\)\.\.(\\|$)') { throw "CopyFile may not contain '..': $rel" }
    if ([IO.Path]::IsPathRooted($norm)) {
      $abs = [IO.Path]::GetFullPath($norm)
      if (($abs + '\').StartsWith($repoRootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $norm = $abs.Substring($repoRootFull.Length).TrimStart('\')
      } else { throw "CopyFile absolute path is outside the repo (refused): $rel" }
    }
    $src = Join-Path $RepoPath $norm
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "CopyFile source missing (hard failure): $rel (looked for $src)" }
    $dst = Join-Path $DestRoot $norm; $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force; $count++
  }
  return $count
}

function Invoke-FleetWorktreeInstallPhase {
  param([string]$WorktreeRoot, [bool]$HadEnterInstall)
  $null = $Install
  $hasPackageJson = Test-Path -LiteralPath (Join-Path $WorktreeRoot 'package.json') -PathType Leaf
  if ($NoInstall) {
    $script:installStatus = 'skipped(-NoInstall)'; $script:depsCount = Get-DepsCount -Root $WorktreeRoot; $script:reuseHit = $false; return
  }
  if (-not $hasPackageJson) {
    $script:installStatus = 'skipped(no package.json)'; $script:depsCount = Get-DepsCount -Root $WorktreeRoot; $script:reuseHit = $false; return
  }
  if ($HadEnterInstall) {
    $script:depsCount = Get-DepsCount -Root $WorktreeRoot
    if ($script:depsCount -le 0) { $script:installStatus = 'failed'; throw "Install exited 0 but node_modules is empty/absent under $WorktreeRoot (install did not materialise deps)" }
    $script:installStatus = 'ok'; $script:reuseHit = $false; return
  }
  $existingDeps = Get-DepsCount -Root $WorktreeRoot
  if ($script:ownership -eq 'pool-slot' -and $existingDeps -gt 0 -and [string]::IsNullOrWhiteSpace($InstallCommand)) {
    $script:depsCount = $existingDeps; $script:installStatus = 'ok'; $script:reuseHit = $true; return
  }
  if (-not [string]::IsNullOrWhiteSpace($InstallCommand)) { $cmd = $InstallCommand }
  elseif (Test-Path -LiteralPath (Join-Path $WorktreeRoot 'package-lock.json') -PathType Leaf) { $cmd = 'npm ci' }
  else { $cmd = 'npm install' }
  try {
    Invoke-Install -WorktreeRoot $WorktreeRoot -Command $cmd -BinDir $NodeBinDir -TimeoutSeconds $InstallTimeoutSeconds
    $script:depsCount = Get-DepsCount -Root $WorktreeRoot
    if ($script:depsCount -le 0) { $script:installStatus = 'failed'; throw "Install exited 0 but node_modules is empty/absent under $WorktreeRoot (install did not materialise deps)" }
    $script:installStatus = 'ok'; $script:reuseHit = $false
  } catch {
    $script:installStatus = 'failed'; $script:depsCount = Get-DepsCount -Root $WorktreeRoot; $script:reuseHit = $false; throw
  }
}

function New-FleetColdWorktree {
  param([string]$RepoFull, [string]$CanonicalRoot, [string]$RepoSlug)
  $script:ownership = 'run-owned'; $script:slotId = ''; $script:leaseId = ''; $script:reuseHit = $false; $script:depFingerprint = ''
  $script:worktreePath = [IO.Path]::GetFullPath((Join-Path $CanonicalRoot "$RepoSlug\$RunId"))
  $script:branchName = "fleet/$RunId"
  if (Test-UnderDocuments -Path $script:worktreePath) { throw "Refusing worktree path under a Documents directory: $($script:worktreePath)" }
  if (Test-SiblingOfSource -WorktreePath $script:worktreePath -RepoPath $RepoFull) {
    throw "Refusing worktree path that would be a sibling of the source checkout: $($script:worktreePath)"
  }
  $resolved = Resolve-PhysicalWorktreePath -LogicalPath $script:worktreePath -CanonicalRoot $CanonicalRoot
  if (-not (Test-UnderRoot -Path $resolved.Path -Root $CanonicalRoot)) {
    if ($resolved.OffenderPath) {
      throw "Refusing worktree: ancestor reparse point '$($resolved.OffenderPath)' resolves to '$($resolved.OffenderTarget)' outside the canonical worktree root '$CanonicalRoot'."
    }
    throw "Refusing worktree: resolved path '$($resolved.Path)' escapes canonical worktree root '$CanonicalRoot'."
  }
  if (Test-UnderDocuments -Path $resolved.Path) { throw "Refusing worktree path under a Documents directory: $($resolved.Path)" }
  if (Test-SiblingOfSource -WorktreePath $resolved.Path -RepoPath $RepoFull) {
    throw "Refusing worktree path that would be a sibling of the source checkout: $($resolved.Path)"
  }
  if (Test-Path -LiteralPath $script:worktreePath) { throw "Worktree path already exists: $($script:worktreePath)" }
  & git -C $RepoFull show-ref --verify --quiet "refs/heads/$($script:branchName)" 2>$null
  if ($LASTEXITCODE -eq 0) { throw "Branch already exists: $($script:branchName) (refusing to reuse; pick a new RunId)" }
  $parent = Split-Path -Parent $script:worktreePath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $prevEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $wtOut = @(& git -C $RepoFull worktree add -b $script:branchName -- $script:worktreePath $BaseRef 2>&1)
    $wtCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prevEap }
  foreach ($wtLine in $wtOut) { Write-Output $wtLine }
  if ($wtCode -ne 0) { throw "git worktree add failed for $($script:worktreePath) branch $($script:branchName) (exit $wtCode)" }
  $coldIdentity = Resolve-FleetPoolRepoIdentity -Repo $RepoFull
  $sidecarPath = $script:worktreePath + '.fleet-run.json'
  $sidecar = [ordered]@{
    schema_version = '1'; run_id = $RunId; repo_path = $coldIdentity.RepoPath
    git_common_dir = $coldIdentity.CommonDir; created_utc = [datetimeoffset]::UtcNow.ToString('o')
    ownership = 'run-owned'
  }
  [IO.File]::WriteAllText($sidecarPath, ($sidecar | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
  $script:copiedCount = Copy-FleetWorktreeFiles -RepoPath $RepoFull -DestRoot $script:worktreePath -RawCopy $CopyFile
  try { Invoke-FleetWorktreeInstallPhase -WorktreeRoot $script:worktreePath -HadEnterInstall:$false }
  catch {
    Write-Fail $_.Exception.Message
    Emit-Summary -Path $script:worktreePath -Branch $script:branchName -Copied $script:copiedCount -Install $script:installStatus -Deps $script:depsCount
    exit 1
  }
  Assert-NoEscapingReparsePoints -Root $script:worktreePath
}

try {
  if ([string]::IsNullOrWhiteSpace($Repo)) { throw 'Repo is required.' }
  if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'RunId is required.' }
  if ($RunId -match '[\\/]' -or $RunId -match '\.\.') { throw "RunId must be a single path segment, got: $RunId" }
  if (-not [string]::IsNullOrEmpty($BuildCacheSpec) -and $BuildCacheSpec.IndexOf([char]0) -ge 0) {
    throw 'BuildCacheSpec contains invalid null character.'
  }
  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  if (-not (Test-Path -LiteralPath $repoFull)) { throw "Repo path does not exist: $repoFull" }
  $gitOk = & git -C $repoFull rev-parse --is-inside-work-tree 2>$null
  if ($LASTEXITCODE -ne 0 -or $gitOk -ne 'true') { throw "Repo is not a git work tree: $repoFull" }
  $repoSlug = ([IO.Path]::GetFileName($repoFull)).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($repoSlug)) { throw "Could not derive repo-slug from: $repoFull" }
  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw 'USERPROFILE is not set.' }
  $canonicalRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex\worktrees'))
  $script:branchName = "fleet/$RunId"
  $usedPool = $false
  $poolAcquired = $false
  if ($PoolMode -ne 'Off') {
    $poolDispatch = Get-FleetPoolDispatchState -RepoPath $repoFull
    if ($PoolMode -eq 'Require' -or $poolDispatch.Kind -ne 'absent') {
      try {
        $passInstall = if (-not [string]::IsNullOrWhiteSpace($InstallCommand) -and -not $NoInstall) { $InstallCommand } else { $null }
        $enterResult = Try-AcquireFleetPoolSlot -RepoPath $repoFull -RunIdVal $RunId -BaseRefVal $BaseRef `
          -CopyFiles $CopyFile -InstallCmd $passInstall -BinDir $NodeBinDir -RequireMode:($PoolMode -eq 'Require') -WaitSeconds 30
        if ($null -ne $enterResult) {
          $j = $enterResult.Json
          $script:worktreePath = [IO.Path]::GetFullPath([string]$j.path).TrimEnd('\')
          $script:branchName = if ($j.branch) { [string]$j.branch } else { "fleet/$RunId" }
          $script:slotId = if ($j.slot_id) { [string]$j.slot_id } else { '' }
          $script:leaseId = if ($j.lease_id) { [string]$j.lease_id } else { '' }
          $script:ownership = 'pool-slot'
          $poolAcquired = $true
          $script:copiedCount = @(Get-FleetCopyEntries -RawCopy $CopyFile).Count
          try {
            $ident = Resolve-FleetPoolRepoIdentity -Repo $repoFull
            $slotRec = Get-FleetPoolSlotFromState -State (Read-FleetPoolState -StatePath (Get-FleetPoolStatePath $ident.RepoKey)) -SlotId $script:slotId
            if ($null -ne $slotRec -and $null -ne $slotRec.fingerprint) { $script:depFingerprint = [string]$slotRec.fingerprint }
          } catch { $script:depFingerprint = '' }
          $hadEnterInstall = -not [string]::IsNullOrWhiteSpace($passInstall)
          try { Invoke-FleetWorktreeInstallPhase -WorktreeRoot $script:worktreePath -HadEnterInstall:$hadEnterInstall }
          catch {
            Write-Fail $_.Exception.Message
            Emit-Summary -Path $script:worktreePath -Branch $script:branchName -Copied $script:copiedCount -Install $script:installStatus -Deps $script:depsCount
            throw
          }
          Assert-NoEscapingReparsePoints -Root $script:worktreePath
          $usedPool = $true
        }
      } catch {
        # Slot acquired (branch/lease live): release before any Auto cold fallback to avoid
        # "Branch already exists" on fleet/<RunId>. Surface original error after release.
        if ($poolAcquired -and -not [string]::IsNullOrWhiteSpace($script:leaseId)) {
          try {
            $exitScript = Join-Path $PSScriptRoot 'Exit-FleetWorktreePoolSlot.ps1'
            $exitArgTokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $exitScript,
              '-Repo', $repoFull, '-RunId', $RunId, '-LeaseId', $script:leaseId, '-Mode', 'json')
            $epsi = New-Object System.Diagnostics.ProcessStartInfo
            $epsi.FileName = 'powershell.exe'
            $epsi.Arguments = (Quote-FleetArgs -Tokens $exitArgTokens)
            $epsi.UseShellExecute = $false
            $epsi.CreateNoWindow = $true
            $epsi.RedirectStandardOutput = $true
            $epsi.RedirectStandardError = $true
            $eproc = [System.Diagnostics.Process]::Start($epsi)
            $null = $eproc.WaitForExit(120000)
            $eproc.Dispose()
          } catch { }
          throw
        }
        if ($PoolMode -eq 'Require') { throw }
        throw
      }
    }
    if (-not $usedPool) { $script:poolFallbackReason = [string]$poolDispatch.Reason }
  } else {
    $script:poolFallbackReason = 'pool_mode_off'
  }
  if (-not $usedPool) {
    if ($PoolMode -eq 'Require') { throw 'Pool acquire failed (Require, no cold fallback): no healthy initialized pool' }
    New-FleetColdWorktree -RepoFull $repoFull -CanonicalRoot $canonicalRoot -RepoSlug $repoSlug
  }
  Emit-Summary -Path $script:worktreePath -Branch $script:branchName -Copied $script:copiedCount -Install $script:installStatus -Deps $script:depsCount
  $script:exitCode = 0
  exit 0
} catch {
  Write-Fail $_.Exception.Message
  if ($script:worktreePath -and (Test-Path -LiteralPath $script:worktreePath) -and $script:installStatus -eq 'failed') {
    Emit-Summary -Path $script:worktreePath -Branch $script:branchName -Copied $script:copiedCount -Install $script:installStatus -Deps $script:depsCount
  }
  exit 1
}
