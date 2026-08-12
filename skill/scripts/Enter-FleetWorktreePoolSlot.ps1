# Acquire lowest-numbered ready pool slot for a run lease.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$RunId,
  [string]$BaseRef = 'HEAD',
  [string[]]$CopyFile = @(),
  [string]$InstallCommand,
  [string]$NodeBinDir,
  [switch]$NoInstall,
  [ValidateSet('json', 'text')][string]$Mode = 'json'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetWorktreePool.State.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Liveness.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Sanitize.Helpers.ps1')
$acquireTimer = [Diagnostics.Stopwatch]::StartNew()

function Write-Fail([string]$Message) { [Console]::Error.WriteLine($Message) }

function Copy-FleetPoolFilesLocal {
  param([string]$RepoPath, [string]$SlotPath, [string[]]$CopyFile)
  $copyEntries = New-Object System.Collections.ArrayList
  foreach ($item in @($CopyFile)) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    foreach ($piece in ([string]$item -split ',')) {
      $p = $piece.Trim(); if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$copyEntries.Add($p) }
    }
  }
  $repoRootFull = [IO.Path]::GetFullPath($RepoPath).TrimEnd('\'); $copied = 0
  foreach ($rel in $copyEntries) {
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
    $dst = Join-Path $SlotPath $norm
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force; $copied++
  }
  return $copied
}

function Quote-FleetPoolEnsureArg([string]$Token) {
  if ($null -eq $Token -or $Token.Length -eq 0) { return '""' }
  if ($Token -notmatch '[\s"]') { return $Token }
  return '"' + ($Token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-FleetPoolEnsureDepsLocal {
  param(
    [string]$WorktreeRoot,
    [string]$PreviousFingerprint = '',
    [string]$InstallCommand = '',
    [string]$NodeBinDir = '',
    [bool]$SkipInstall = $false
  )
  $ensureScript = Join-Path $PSScriptRoot 'Ensure-FleetDependencies.ps1'
  if (-not (Test-Path -LiteralPath $ensureScript -PathType Leaf)) {
    throw "Ensure-FleetDependencies.ps1 missing: $ensureScript"
  }
  $storeRoot = Join-Path $env:USERPROFILE '.codex\cache\fleet\npm'
  if (-not (Test-Path -LiteralPath $storeRoot)) {
    New-Item -ItemType Directory -Force -Path $storeRoot | Out-Null
  }
  # ProcessStartInfo + quoted args: call-operator drops/splits empty and space-heavy values.
  $tokens = New-Object System.Collections.ArrayList
  foreach ($t in @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ensureScript,
      '-Worktree', $WorktreeRoot, '-StoreRoot', $storeRoot, '-Mode', 'json'
    )) { [void]$tokens.Add($t) }
  if (-not [string]::IsNullOrWhiteSpace($PreviousFingerprint)) {
    [void]$tokens.Add('-PreviousFingerprint'); [void]$tokens.Add([string]$PreviousFingerprint)
  }
  if (-not [string]::IsNullOrWhiteSpace($InstallCommand)) {
    [void]$tokens.Add('-InstallCommand'); [void]$tokens.Add($InstallCommand)
  }
  if (-not [string]::IsNullOrWhiteSpace($NodeBinDir)) {
    [void]$tokens.Add('-NodeBinDir'); [void]$tokens.Add($NodeBinDir)
  }
  if ($SkipInstall) { [void]$tokens.Add('-NoInstall') }
  $argLine = (@($tokens | ForEach-Object { Quote-FleetPoolEnsureArg ([string]$_) }) -join ' ')
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = $argLine
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outT = $proc.StandardOutput.ReadToEndAsync()
  $errT = $proc.StandardError.ReadToEndAsync()
  $null = $proc.WaitForExit(3600000)
  $ensureCode = if ($proc.HasExited) { $proc.ExitCode } else {
    try { $proc.Kill() } catch { }
    try { $null = $proc.WaitForExit(5000) } catch { }
    -1
  }
  $stdout = if ($outT.Wait(5000)) { [string]$outT.Result } else { '' }
  $stderr = if ($errT.Wait(5000)) { [string]$errT.Result } else { '' }
  $proc.Dispose()
  $jsonLine = $null
  foreach ($line in @($stdout -split "`r?`n")) {
    if ($line -match '^\s*\{') { $jsonLine = $line }
  }
  if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    $blob = ($stderr + ' ' + $stdout).Trim()
    if ($blob.Length -gt 400) { $blob = $blob.Substring(0, 400) }
    throw "Ensure-FleetDependencies produced no JSON (exit $ensureCode): $blob"
  }
  $ensureResult = $jsonLine | ConvertFrom-Json
  $status = [string]$ensureResult.status
  if (@('reuse-hit', 'installed', 'skipped') -notcontains $status) {
    $reason = [string]$ensureResult.install_reason
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "status=$status exit=$ensureCode" }
    throw "install failure: $reason"
  }
  return [string]$ensureResult.dependency_fingerprint
}

try {
  if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'RunId is required.' }
  if ($RunId -match '[\\/]' -or $RunId -match '\.\.') { throw "RunId must be a single path segment, got: $RunId" }

  $ident = Resolve-FleetPoolRepoIdentity -Repo $Repo
  $canonicalRoot = Get-FleetPoolCanonicalRoot
  $statePath = Get-FleetPoolStatePath $ident.RepoKey
  $branchName = "fleet/$RunId"

  $reapScript = Join-Path $PSScriptRoot 'Invoke-FleetWorktreePoolReap.ps1'
  if (Test-Path -LiteralPath $reapScript) {
    try { & $reapScript -Repo $ident.RepoPath -Mode json 2>$null | Out-Null } catch { }
  }

  # Refuse existing branch early (repo-level).
  $null = @(& git -C $ident.RepoPath show-ref --verify --quiet "refs/heads/$branchName" 2>$null)
  if ($LASTEXITCODE -eq 0) { throw "Branch already exists: $branchName (refusing to reuse; pick a new RunId)" }

  $baseCommit = @(& git -C $ident.RepoPath rev-parse --verify "$BaseRef^{commit}" 2>$null)
  if ($LASTEXITCODE -ne 0 -or $baseCommit.Count -lt 1) { throw "BaseRef not resolvable: $BaseRef" }
  $baseCommit = [string]$baseCommit[0]

  $claim = Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
    $st = Read-FleetPoolState -StatePath $statePath
    if ($null -eq $st) { throw "Pool not initialized for $($ident.RepoKey); run Initialize-FleetWorktreePool first" }
    if ([string]$st.git_common_dir -ne $ident.CommonDir) {
      throw "Pool common-dir mismatch (state='$($st.git_common_dir)' repo='$($ident.CommonDir)')"
    }
    $chosen = $null
    foreach ($slot in @($st.slots | Sort-Object { [string]$_.id })) {
      if ([string]$slot.state -ne 'ready') { continue }
      $spath = Assert-FleetPoolSlotPathIdentity -Slot $slot -RepoKey $ident.RepoKey
      if (-not (Test-Path -LiteralPath $spath)) { Set-FleetPoolQuarantine -Slot $slot -Reason 'missing_path' -Evidence $spath; continue }
      $registration = Repair-FleetPoolWorktreeRegistration -RepoPath $ident.RepoPath -SlotPath $spath
      if (-not $registration.Registered) {
        Set-FleetPoolQuarantine -Slot $slot -Reason 'worktree_registration_mismatch' -Evidence $registration.Evidence; continue
      }
      try {
        Lock-FleetPoolWorktree -RepoPath $ident.RepoPath -SlotPath $spath
      } catch {
        Set-FleetPoolQuarantine -Slot $slot -Reason 'worktree_lock_failed' -Evidence $_.Exception.Message; continue
      }
      $slotCommon = Get-FleetPoolSlotCommonDir -SlotPath $spath
      if ([string]::IsNullOrWhiteSpace($slotCommon) -or -not $slotCommon.Equals($ident.CommonDir, [StringComparison]::OrdinalIgnoreCase)) {
        Set-FleetPoolQuarantine -Slot $slot -Reason 'repo_common_dir_mismatch' -Evidence "got=$slotCommon"; continue
      }
      # Cheap gates only inside mutex; expensive reparse walk runs after claim (FIX5b).
      try {
        Assert-FleetPoolCanonicalGates -LogicalPath $spath -CanonicalRoot $canonicalRoot | Out-Null
      } catch {
        Set-FleetPoolQuarantine -Slot $slot -Reason 'escaping_reparse' -Evidence $_.Exception.Message; continue
      }
      if (Test-FleetPoolSlotDirty -SlotPath $spath) {
        Set-FleetPoolQuarantine -Slot $slot -Reason 'dirty_tracked_or_index' -Evidence 'dirty at acquire'; continue
      }
      if (Test-FleetPoolLeaseLive -Slot $slot) {
        Set-FleetPoolQuarantine -Slot $slot -Reason 'live_worker_ambiguity' -Evidence 'ready but live workers'; continue
      }
      $chosen = $slot; break
    }
    if ($null -eq $chosen) {
      Write-FleetPoolState -StatePath $statePath -State $st
      throw 'No ready pool slot available'
    }
    # Owner = parent (caller) process, never this short-lived Enter script PID (same class as run-lease).
    $ownerPidVal = 0
    try {
      $ownerPidVal = [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
    } catch { $ownerPidVal = 0 }
    $ownerStartVal = $null
    if ($ownerPidVal -gt 0) { $ownerStartVal = Get-FleetPoolProcessStartUtc -ProcessId $ownerPidVal }
    $leaseId = New-FleetPoolToken
    $chosen.state = 'preparing'
    $chosen.token = (New-FleetPoolToken)
    $chosen.lease_id = $leaseId
    $chosen.run_id = $RunId
    $chosen.owner_pid = $(if ($ownerPidVal -gt 0) { $ownerPidVal } else { $null })
    $chosen.owner_start_utc = $ownerStartVal
    $chosen.branch = $branchName
    $chosen.base_commit = $baseCommit
    $chosen.processes = @()
    Write-FleetPoolState -StatePath $statePath -State $st
    $prevFpClaim = ''
    if ($null -ne $chosen.fingerprint -and -not [string]::IsNullOrWhiteSpace([string]$chosen.fingerprint)) {
      $prevFpClaim = [string]$chosen.fingerprint
    }
    return [ordered]@{
      slot_id = [string]$chosen.id
      path = $spath
      lease_id = $leaseId
      token = [string]$chosen.token
      fingerprint = $prevFpClaim
    }
  }

  $prepError = $null
  $depFp = $null
  try {
    $spath = [string]$claim.path
    $prevEap = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $null = @(& git -C $spath checkout --detach $baseCommit 2>&1)
      $coCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap }
    if ($coCode -ne 0) { throw "checkout base failed exit $coCode" }
    try {
      $ErrorActionPreference = 'Continue'
      $null = @(& git -C $spath checkout -b $branchName 2>&1)
      $brCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap }
    if ($brCode -ne 0) { throw "create branch $branchName failed exit $brCode" }
    $null = Copy-FleetPoolFilesLocal -RepoPath $ident.RepoPath -SlotPath $spath -CopyFile $CopyFile
    $pkgJson = Join-Path $spath 'package.json'
    if (Test-Path -LiteralPath $pkgJson -PathType Leaf) {
      $prevFp = ''
      try { if ($null -ne $claim.fingerprint) { $prevFp = [string]$claim.fingerprint } } catch { }
      $depFp = Invoke-FleetPoolEnsureDepsLocal -WorktreeRoot $spath -PreviousFingerprint $prevFp `
        -InstallCommand $InstallCommand -NodeBinDir $NodeBinDir -SkipInstall:([bool]$NoInstall)
    }
    # Reparse walk outside mutex (prepare phase) — blocks sanitize path if escapes found.
    Assert-NoEscapingReparsePoints -Root $spath
  } catch {
    $prepError = $_.Exception.Message
  }

  $final = Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
    $st = Read-FleetPoolState -StatePath $statePath
    $s = Get-FleetPoolSlotFromState -State $st -SlotId ([string]$claim.slot_id)
    if ($null -eq $s) { throw "Slot disappeared: $($claim.slot_id)" }
    if ([string]$s.token -ne [string]$claim.token -or [string]$s.lease_id -ne [string]$claim.lease_id) {
      throw "state/lease token inconsistency for $($claim.slot_id)"
    }
    if ($prepError) {
      Set-FleetPoolQuarantine -Slot $s -Reason 'prepare_failed' -Evidence $prepError
      Write-FleetPoolState -StatePath $statePath -State $st
      throw "prepare failed (quarantined): $prepError"
    }
    if (-not [string]::IsNullOrWhiteSpace($depFp)) { $s.fingerprint = $depFp }
    $s.state = 'acquired'
    $s.token = (New-FleetPoolToken)
    Write-FleetPoolState -StatePath $statePath -State $st
    return [ordered]@{
      ok = $true
      slot_id = [string]$s.id
      path = (Get-FleetPoolSlotPath -RepoKey $ident.RepoKey -SlotId ([string]$s.id))
      branch = $branchName
      lease_id = [string]$s.lease_id
      run_id = $RunId
      base_commit = $baseCommit
    }
  }

  Write-FleetPoolEvent -Event @{
    event = 'pool_acquire'
    repo_id = $ident.RepoPath
    repo_key = $ident.RepoKey
    slot_id = [string]$final.slot_id
    run_id = $RunId
    branch = $branchName
    base_sha = [string]$final.base_commit
    outcome = 'acquired'
    reason = 'acquired'
    ownership = 'pool'
    duration_ms = [int]$acquireTimer.ElapsedMilliseconds
  }

  if ($Mode -eq 'json') { Emit-FleetPoolJson $final }
  else {
    Emit-FleetPoolText ("slot: $($final.slot_id) | path: $($final.path) | branch: $branchName | lease: $($final.lease_id)")
  }
  exit 0
} catch {
  Write-Fail $_.Exception.Message
  if ($Mode -eq 'json') { Emit-FleetPoolJson ([ordered]@{ ok = $false; error = $_.Exception.Message }) }
  exit 1
}
