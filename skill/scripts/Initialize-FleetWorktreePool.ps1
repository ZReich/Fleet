# Provision fixed warm worktree slots for a repo. Never recursive-deletes a slot.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repo,
  [ValidateRange(2, 4)][int]$Size = 3,
  [string]$BaseRef = 'HEAD',
  [string]$InstallCommand,
  [string]$NodeBinDir,
  [ValidateSet('json', 'text')][string]$Mode = 'json'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetWorktreePool.State.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Liveness.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Sanitize.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Initialize-FleetWorktreePool.Helpers.ps1')
$initializeTimer = [Diagnostics.Stopwatch]::StartNew()

function Write-Fail([string]$Message) { [Console]::Error.WriteLine($Message) }

function Quote-FleetPoolEnsureArg([string]$Token) {
  if ($null -eq $Token -or $Token.Length -eq 0) { return '""' }
  if ($Token -notmatch '[\s"]') { return $Token }
  return '"' + ($Token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-FleetPoolEnsureOnce {
  param([string[]]$Tokens)
  $argLine = (@($Tokens | ForEach-Object { Quote-FleetPoolEnsureArg ([string]$_) }) -join ' ')
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
  return [pscustomobject]@{
    Code   = $ensureCode
    Status = [string]$ensureResult.status
    Reason = [string]$ensureResult.install_reason
    Fp     = [string]$ensureResult.dependency_fingerprint
  }
}

function Invoke-FleetPoolEnsureDepsLocal {
  param(
    [string]$WorktreeRoot,
    [string]$PreviousFingerprint = '',
    [string]$InstallCommand = '',
    [string]$NodeBinDir = ''
  )
  $ensureScript = Join-Path $PSScriptRoot 'Ensure-FleetDependencies.ps1'
  if (-not (Test-Path -LiteralPath $ensureScript -PathType Leaf)) {
    throw "Ensure-FleetDependencies.ps1 missing: $ensureScript"
  }
  $storeRoot = Join-Path $env:USERPROFILE '.codex\cache\fleet\npm'
  if (-not (Test-Path -LiteralPath $storeRoot)) {
    New-Item -ItemType Directory -Force -Path $storeRoot | Out-Null
  }
  # ProcessStartInfo + quoted args (call-operator splits space-heavy values).
  # Provision: install when possible. On failure, -NoInstall fingerprint so Enter can warm.
  # Optional InstallCommand/NodeBinDir must match Enter so fingerprints align (FIX4b).
  $base = New-Object System.Collections.ArrayList
  foreach ($t in @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ensureScript,
      '-Worktree', $WorktreeRoot, '-StoreRoot', $storeRoot, '-Mode', 'json'
    )) { [void]$base.Add($t) }
  if (-not [string]::IsNullOrWhiteSpace($PreviousFingerprint)) {
    [void]$base.Add('-PreviousFingerprint'); [void]$base.Add([string]$PreviousFingerprint)
  }
  if (-not [string]::IsNullOrWhiteSpace($InstallCommand)) {
    [void]$base.Add('-InstallCommand'); [void]$base.Add($InstallCommand)
  }
  if (-not [string]::IsNullOrWhiteSpace($NodeBinDir)) {
    [void]$base.Add('-NodeBinDir'); [void]$base.Add($NodeBinDir)
  }

  $first = Invoke-FleetPoolEnsureOnce -Tokens @($base)
  if (@('reuse-hit', 'installed', 'skipped') -contains $first.Status) { return $first.Fp }
  $second = Invoke-FleetPoolEnsureOnce -Tokens (@($base) + @('-NoInstall'))
  if (@('reuse-hit', 'installed', 'skipped') -contains $second.Status) { return $second.Fp }
  $reason = $first.Reason
  if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "status=$($first.Status)" }
  throw "install failure: $reason"
}

try {
  $ident = Resolve-FleetPoolRepoIdentity -Repo $Repo
  $canonicalRoot = Get-FleetPoolCanonicalRoot
  $poolRoot = Get-FleetPoolRepoRoot $ident.RepoKey
  $statePath = Get-FleetPoolStatePath $ident.RepoKey

  Assert-FleetPoolCanonicalGates -LogicalPath $poolRoot -CanonicalRoot $canonicalRoot | Out-Null
  if (-not (Test-Path -LiteralPath $poolRoot)) {
    New-Item -ItemType Directory -Force -Path $poolRoot | Out-Null
  }

  # Reap first (may quarantine stale slots; never deletes).
  $reapScript = Join-Path $PSScriptRoot 'Invoke-FleetWorktreePoolReap.ps1'
  if (Test-Path -LiteralPath $reapScript) {
    try {
      & $reapScript -Repo $ident.RepoPath -Mode json 2>$null | Out-Null
    } catch { }
  }

  $state = Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
    $existing = Read-FleetPoolState -StatePath $statePath
    if ($null -ne $existing -and [string]$existing.repo_key -eq $ident.RepoKey) {
      # Backfill repo_path (required for Resolve-FleetPoolSlotContext worker registration).
      $needWrite = $false
      $haveRp = $false
      try { if (-not [string]::IsNullOrWhiteSpace([string]$existing.repo_path)) { $haveRp = $true } } catch { }
      if (-not $haveRp) {
        try { $existing | Add-Member -MemberType NoteProperty -Name 'repo_path' -Value $ident.RepoPath -Force } catch { $existing.repo_path = $ident.RepoPath }
        $needWrite = $true
      } elseif ([string]$existing.repo_path -ne $ident.RepoPath) {
        $existing.repo_path = $ident.RepoPath
        $needWrite = $true
      }
      if ($needWrite) { Write-FleetPoolState -StatePath $statePath -State $existing }
      return $existing
    }
    $slots = New-Object System.Collections.ArrayList
    for ($si = 1; $si -le $Size; $si++) {
      $sid = Format-FleetPoolSlotId $si
      $spath = Get-FleetPoolSlotPath $ident.RepoKey $sid
      Assert-FleetPoolPathBudget -SlotRoot $spath
      [void]$slots.Add((New-FleetPoolSlotRecord -SlotId $sid -Path $spath -State 'provisioning'))
    }
    $fresh = [ordered]@{
      schema_version = $script:FleetPoolSchema
      repo_key = $ident.RepoKey
      repo_name = $ident.RepoName
      repo_path = $ident.RepoPath
      git_common_dir = $ident.CommonDir
      size = $Size
      base_ref_default = $BaseRef
      slots = @($slots)
    }
    Write-FleetPoolState -StatePath $statePath -State $fresh
    return (Read-FleetPoolState -StatePath $statePath)
  }

  $results = New-Object System.Collections.ArrayList
  foreach ($slot in @($state.slots)) {
    $sid = [string]$slot.id
    $spath = Assert-FleetPoolSlotPathIdentity -Slot $slot -RepoKey $ident.RepoKey
    $curState = [string]$slot.state
    $recoverBrokenRegistration = $false
    # Older pool versions quarantined registrations that `git worktree repair`
    # can safely reconstruct. Make those slots eligible for this initialization.
    $registrationQuarantine = ([string]$slot.quarantine_reason -eq 'worktree_registration_mismatch') -or (
      [string]$slot.quarantine_reason -eq 'provision_failed' -and [string]$slot.quarantine_evidence -match 'worktree registration missing'
    )
    if ($curState -eq 'quarantined' -and $registrationQuarantine) {
      Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
        $st = Read-FleetPoolState -StatePath $statePath
        $s = Get-FleetPoolSlotFromState -State $st -SlotId $sid
        if ($null -eq $s) { throw "Missing slot $sid while recovering registration" }
        if ([string]$s.state -eq 'quarantined' -and [string]$s.quarantine_reason -eq 'worktree_registration_mismatch') {
          $s.state = 'provisioning'; $s.token = (New-FleetPoolToken)
          Write-FleetPoolState -StatePath $statePath -State $st
        }
      }
      $curState = 'provisioning'
      $recoverBrokenRegistration = $true
    }
    if ($curState -eq 'ready' -or $curState -eq 'acquired' -or $curState -eq 'preparing') {
      # Backfill prune protection for pools created before slot locking existed.
      # A missing registration gets one non-destructive repair attempt first.
      $registration = Repair-FleetPoolWorktreeRegistration -RepoPath $ident.RepoPath -SlotPath $spath
      $lockError = $null
      if ($registration.Registered) {
        try { Lock-FleetPoolWorktree -RepoPath $ident.RepoPath -SlotPath $spath } catch { $lockError = $_.Exception.Message }
      }
      if (-not $registration.Registered -or $lockError) {
        $reason = if ($registration.Registered) { 'worktree_lock_failed' } else { 'worktree_registration_mismatch' }
        $evidence = if ($registration.Registered) { $lockError } else { $registration.Evidence }
        Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
          $st = Read-FleetPoolState -StatePath $statePath
          $s = Get-FleetPoolSlotFromState -State $st -SlotId $sid
          if ($null -eq $s) { throw "Missing slot $sid while quarantining registration" }
          Set-FleetPoolQuarantine -Slot $s -Reason $reason -Evidence $evidence
          Write-FleetPoolState -StatePath $statePath -State $st
        }
        [void]$results.Add([ordered]@{ id = $sid; state = 'quarantined'; path = $spath; reason = $reason })
        continue
      }
      [void]$results.Add([ordered]@{ id = $sid; state = $curState; path = $spath })
      continue
    }
    if ($curState -eq 'quarantined') {
      # Quarantine never means removable: if its checkout is still registered,
      # retain the prune-protection lock while preserving the quarantine reason.
      $registration = Repair-FleetPoolWorktreeRegistration -RepoPath $ident.RepoPath -SlotPath $spath
      if ($registration.Registered) {
        try { Lock-FleetPoolWorktree -RepoPath $ident.RepoPath -SlotPath $spath } catch { }
      }
      [void]$results.Add([ordered]@{ id = $sid; state = 'quarantined'; path = $spath; reason = [string]$slot.quarantine_reason })
      continue
    }

    # Commit provisioning token under mutex, then release for long git op.
    $provToken = Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
      $st = Read-FleetPoolState -StatePath $statePath
      $s = Get-FleetPoolSlotFromState -State $st -SlotId $sid
      if ($null -eq $s) { throw "Missing slot $sid in pool state" }
      if ([string]$s.state -eq 'ready' -or [string]$s.state -eq 'acquired') { return }
      # provisioning is an exclusive CAS state once a worker claimed it.  Fresh
      # records have no owner and are claimed here; concurrent initializers return.
      $provisionOwner = ''; try { $provisionOwner = [string]$s.provision_owner_pid } catch { }
      if ([string]$s.state -eq 'provisioning' -and -not [string]::IsNullOrWhiteSpace($provisionOwner)) { return }
      $s.state = 'provisioning'
      $s.token = (New-FleetPoolToken)
      try { $s.provision_owner_pid = [int]$PID } catch { $s | Add-Member -MemberType NoteProperty -Name 'provision_owner_pid' -Value ([int]$PID) -Force }
      Write-FleetPoolState -StatePath $statePath -State $st
      return [string]$s.token
    }
    if ([string]::IsNullOrWhiteSpace($provToken)) { continue }

    # Test-only deterministic race seam; it changes state, never slot contents.
    if ([string]$env:FLEET_POOL_TEST_STEAL_PROVISION_TOKEN -eq $sid) {
      Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
        $st = Read-FleetPoolState -StatePath $statePath
        $s = Get-FleetPoolSlotFromState -State $st -SlotId $sid
        if ($null -ne $s -and [string]$s.token -eq $provToken) { $s.token = (New-FleetPoolToken); Write-FleetPoolState -StatePath $statePath -State $st }
      }
    }
    # Final operation before slot I/O: stolen token means zero slot I/O.
    Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
      $st = Read-FleetPoolState -StatePath $statePath
      $s = Get-FleetPoolSlotFromState -State $st -SlotId $sid
      if ($null -eq $s -or [string]$s.token -ne $provToken -or [string]$s.state -ne 'provisioning') {
        throw "provisioning token mismatch for $sid before slot I/O"
      }
    }

    $provError = $null
    $depFp = $null
    $preservedBrokenCheckout = $null
    try {
      Assert-FleetPoolPathBudget -SlotRoot $spath
      Assert-FleetPoolCanonicalGates -LogicalPath $spath -CanonicalRoot $canonicalRoot | Out-Null

      # If repair cannot recover a pruned administration directory, retain the
      # old checkout beside the slot (never delete it) and provision a fresh one.
      # This is only allowed for a previously quarantined registration failure.
      if (Test-Path -LiteralPath $spath) {
        $existingRegistration = Repair-FleetPoolWorktreeRegistration -RepoPath $ident.RepoPath -SlotPath $spath
        if (-not $existingRegistration.Registered) {
          if (-not $recoverBrokenRegistration) {
            throw "worktree registration missing for ${spath}: $($existingRegistration.Evidence)"
          }
          Assert-NoEscapingReparsePoints -Root $spath
          $preservedBrokenCheckout = "$spath.registration-mismatch-$([datetimeoffset]::UtcNow.ToString('yyyyMMddHHmmss'))"
          $suffix = 0
          while (Test-Path -LiteralPath $preservedBrokenCheckout) {
            $suffix++; $preservedBrokenCheckout = "$spath.registration-mismatch-$([datetimeoffset]::UtcNow.ToString('yyyyMMddHHmmss'))-$suffix"
          }
          Assert-FleetPoolCanonicalGates -LogicalPath $preservedBrokenCheckout -CanonicalRoot $canonicalRoot | Out-Null
          Move-Item -LiteralPath $spath -Destination $preservedBrokenCheckout -ErrorAction Stop
        }
      }

      if (-not (Test-Path -LiteralPath $spath)) {
        $parent = Split-Path -Parent $spath
        if (-not (Test-Path -LiteralPath $parent)) {
          New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        $prevEap = $ErrorActionPreference
        try {
          $ErrorActionPreference = 'Continue'
          $null = @(& git -C $ident.RepoPath worktree add --detach -- $spath $BaseRef 2>&1)
          $wtCode = $LASTEXITCODE
        } finally {
          $ErrorActionPreference = $prevEap
        }
        if ($wtCode -ne 0) { throw "git worktree add failed for $spath (exit $wtCode)" }
      }

      $registration = Repair-FleetPoolWorktreeRegistration -RepoPath $ident.RepoPath -SlotPath $spath
      if (-not $registration.Registered) {
        throw "worktree registration missing for ${spath}: $($registration.Evidence)"
      }
      Lock-FleetPoolWorktree -RepoPath $ident.RepoPath -SlotPath $spath
      $slotCommon = Get-FleetPoolSlotCommonDir -SlotPath $spath
      if ([string]::IsNullOrWhiteSpace($slotCommon) -or -not $slotCommon.Equals($ident.CommonDir, [StringComparison]::OrdinalIgnoreCase)) {
        throw "git-common-dir mismatch for $spath (got '$slotCommon', want '$($ident.CommonDir)')"
      }
      Assert-NoEscapingReparsePoints -Root $spath

      $pkgJson = Join-Path $spath 'package.json'
      if (Test-Path -LiteralPath $pkgJson -PathType Leaf) {
        # First provision: no prior fingerprint (reuse-hit not expected here).
        $depFp = Invoke-FleetPoolEnsureDepsLocal -WorktreeRoot $spath -PreviousFingerprint '' `
          -InstallCommand $InstallCommand -NodeBinDir $NodeBinDir
      }
    } catch {
      $provError = $_.Exception.Message
    }

    # Token-checked finalization under mutex.
    Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
      $st = Read-FleetPoolState -StatePath $statePath
      $s = Get-FleetPoolSlotFromState -State $st -SlotId $sid
      if ($null -eq $s) { throw "Missing slot $sid at finalize" }
      if ([string]$s.token -ne $provToken) {
        throw "provisioning token mismatch for $sid (concurrent claim)"
      }
      if ($provError) {
        Set-FleetPoolQuarantine -Slot $s -Reason 'provision_failed' -Evidence $provError
      } else {
        try {
          Assert-NoEscapingReparsePoints -Root $spath
          if (-not [string]::IsNullOrWhiteSpace($depFp)) { $s.fingerprint = $depFp }
          $s.disk_bytes = Get-FleetPoolDiskBytesLocal -Root $spath
          $s.state = 'ready'
          $s.provision_owner_pid = $null
          $s.quarantine_reason = $null
          $s.quarantine_at = $null
          $s.quarantine_evidence = $null
          $s.token = (New-FleetPoolToken)
        } catch {
          Set-FleetPoolQuarantine -Slot $s -Reason 'structural_mismatch' -Evidence $_.Exception.Message
        }
      }
      Write-FleetPoolState -StatePath $statePath -State $st
      [void]$results.Add([ordered]@{
        id = $sid
        state = [string]$s.state
        path = $spath
        reason = [string]$s.quarantine_reason
      })
    }

    Write-FleetPoolEvent -Event @{
      event = 'pool_initialize_slot'
      repo_id = $ident.RepoPath
      repo_key = $ident.RepoKey
      slot_id = $sid
      state = if ($provError) { 'quarantined' } else { 'ready' }
      outcome = if ($provError) { 'quarantined' } else { 'ready' }
      reason = if ($provError) { [string]$provError } elseif ($preservedBrokenCheckout) { "reprovisioned; preserved $preservedBrokenCheckout" } else { 'provisioned' }
      ownership = 'pool'
      duration_ms = [int]$initializeTimer.ElapsedMilliseconds
      quarantine_reason = if ($provError) { [string]$provError } else { '' }
    }
  }

  $readyCount = @($results | Where-Object { [string]$_.state -eq 'ready' }).Count
  $payload = [ordered]@{
    ok = ($readyCount -gt 0)
    repo_key = $ident.RepoKey
    pool_root = $poolRoot
    size = $Size
    ready = $readyCount
    slots = @($results)
  }
  if ($Mode -eq 'json') { Emit-FleetPoolJson $payload }
  else { Emit-FleetPoolText ("pool: $($ident.RepoKey) | size: $Size | ready: $readyCount | root: $poolRoot") }
  if ($readyCount -le 0) { exit 1 }
  exit 0
} catch {
  Write-Fail $_.Exception.Message
  if ($Mode -eq 'json') {
    Emit-FleetPoolJson ([ordered]@{ ok = $false; error = $_.Exception.Message })
  }
  exit 1
}
