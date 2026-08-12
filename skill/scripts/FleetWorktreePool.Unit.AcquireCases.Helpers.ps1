# Early pool acquisition cases kept separate from the long unit-suite runner.
function Invoke-FleetPoolUnitAcquireCases {
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)]$Ident)
  Case 'concurrent acquire cannot return same slot (token guard) [1/13]' {
    $init = Invoke-PoolScript -ScriptName 'Initialize-FleetWorktreePool.ps1' -ArgList @('-Repo', $Repo, '-Size', '2', '-Mode', 'json')
    Assert-True ($init.ExitCode -eq 0) "init failed: $($init.Stderr) $($init.Stdout)"
    $a1 = Invoke-PoolScript -ScriptName 'Enter-FleetWorktreePoolSlot.ps1' -ArgList @('-Repo', $Repo, '-RunId', 'run-a1', '-Mode', 'json')
    Assert-True ($a1.ExitCode -eq 0) "enter1 failed: $($a1.Stderr) $($a1.Stdout)"
    $j1 = Get-JsonOut $a1.Stdout
    $a2 = Invoke-PoolScript -ScriptName 'Enter-FleetWorktreePoolSlot.ps1' -ArgList @('-Repo', $Repo, '-RunId', 'run-a2', '-Mode', 'json')
    Assert-True ($a2.ExitCode -eq 0) "enter2 failed: $($a2.Stderr) $($a2.Stdout)"
    $j2 = Get-JsonOut $a2.Stdout
    Assert-True ([string]$j1.slot_id -ne [string]$j2.slot_id) "same slot returned: $($j1.slot_id)"
    $statePath = Get-FleetPoolStatePath $Ident.RepoKey
    $st = Read-FleetPoolState $statePath; $slot = Get-FleetPoolSlotFromState -State $st -SlotId ([string]$j1.slot_id)
    $realToken = [string]$slot.token; $slot.token = 'deadbeefdeadbeefdeadbeefdeadbeef'; Write-FleetPoolState -StatePath $statePath -State $st
    $st2 = Read-FleetPoolState $statePath; $slot2 = Get-FleetPoolSlotFromState -State $st2 -SlotId ([string]$j1.slot_id)
    Assert-True ([string]$slot2.token -ne $realToken) 'token rewrite for guard check'
    $slot2.token = $realToken; Write-FleetPoolState -StatePath $statePath -State $st2
  }
  Case 'wrong lease/RunId cannot release [2/13]' {
    $st = Read-FleetPoolState (Get-FleetPoolStatePath $Ident.RepoKey); $acquired = $null
    foreach ($s in @($st.slots)) { if ([string]$s.state -eq 'acquired') { $acquired = $s; break } }
    Assert-True ($null -ne $acquired) 'need acquired slot from prior case'
    $bad = Invoke-PoolScript -ScriptName 'Exit-FleetWorktreePoolSlot.ps1' -ArgList @('-Repo', $Repo, '-RunId', 'wrong-run', '-LeaseId', ([string]$acquired.lease_id), '-Mode', 'json')
    Assert-True ($bad.ExitCode -ne 0) "wrong run should fail, got $($bad.ExitCode)"
    $bad2 = Invoke-PoolScript -ScriptName 'Exit-FleetWorktreePoolSlot.ps1' -ArgList @('-Repo', $Repo, '-RunId', ([string]$acquired.run_id), '-LeaseId', 'not-a-real-lease-id', '-Mode', 'json')
    Assert-True ($bad2.ExitCode -ne 0) "wrong lease should fail, got $($bad2.ExitCode)"
  }
  Case 'live PID+start-time blocks release [3/13]' {
    $st = Read-FleetPoolState (Get-FleetPoolStatePath $Ident.RepoKey); $acquired = $null
    foreach ($s in @($st.slots)) { if ([string]$s.state -eq 'acquired') { $acquired = $s; break } }
    Assert-True ($null -ne $acquired) 'need acquired slot'; $liveStart = Get-FleetPoolProcessStartUtc -ProcessId $PID
    $reg = Invoke-PoolScript -ScriptName 'Set-FleetWorktreePoolProcess.ps1' -ArgList @('-Action', 'Register', '-Repo', $Repo, '-LeaseId', ([string]$acquired.lease_id), '-ProcessId', ([string]$PID), '-ProcessStartUtc', $liveStart, '-Mode', 'json')
    Assert-True ($reg.ExitCode -eq 0) "register failed: $($reg.Stderr)"
    $blocked = Invoke-PoolScript -ScriptName 'Exit-FleetWorktreePoolSlot.ps1' -ArgList @('-Repo', $Repo, '-RunId', ([string]$acquired.run_id), '-LeaseId', ([string]$acquired.lease_id), '-Mode', 'json')
    Assert-True ($blocked.ExitCode -ne 0) "live worker should block release: $($blocked.Stdout)"
    Assert-True ($blocked.Stderr -match 'Live registered worker' -or $blocked.Stdout -match 'Live registered worker' -or $blocked.Stdout -match 'blocks release') "msg: $($blocked.Stderr) $($blocked.Stdout)"
    $unreg = Invoke-PoolScript -ScriptName 'Set-FleetWorktreePoolProcess.ps1' -ArgList @('-Action', 'Unregister', '-Repo', $Repo, '-LeaseId', ([string]$acquired.lease_id), '-ProcessId', ([string]$PID), '-ProcessStartUtc', $liveStart, '-Mode', 'json')
    Assert-True ($unreg.ExitCode -eq 0) "unregister failed: $($unreg.Stderr)"
  }
  Case 'dirty slot quarantines [4/13]' {
    $st = Read-FleetPoolState (Get-FleetPoolStatePath $Ident.RepoKey); $acquired = $null
    foreach ($s in @($st.slots)) { if ([string]$s.state -eq 'acquired') { $acquired = $s; break } }
    Assert-True ($null -ne $acquired) 'need acquired slot'; $spath = [string]$acquired.path
    [IO.File]::WriteAllText((Join-Path $spath 'DIRTY.txt'), 'uncommitted')
    $ex = Invoke-PoolScript -ScriptName 'Exit-FleetWorktreePoolSlot.ps1' -ArgList @('-Repo', $Repo, '-RunId', ([string]$acquired.run_id), '-LeaseId', ([string]$acquired.lease_id), '-Mode', 'json')
    Assert-True ($ex.ExitCode -ne 0) "dirty exit should fail: $($ex.Stdout)"
    $st2 = Read-FleetPoolState (Get-FleetPoolStatePath $Ident.RepoKey); $s2 = Get-FleetPoolSlotFromState -State $st2 -SlotId ([string]$acquired.id)
    Assert-True ([string]$s2.state -eq 'quarantined') "expected quarantined, got $($s2.state)"; Assert-True ([string]$s2.quarantine_reason -match 'dirty|live_cmdline') "reason: $($s2.quarantine_reason)"
  }
  Case 'repo-common-dir mismatch quarantines [5/13]' {
    $repo2 = New-TestRepo 'pool-mismatch'; $init2 = Invoke-PoolScript -ScriptName 'Initialize-FleetWorktreePool.ps1' -ArgList @('-Repo', $repo2, '-Size', '2', '-Mode', 'json')
    Assert-True ($init2.ExitCode -eq 0) "init2: $($init2.Stderr)"; $ident2 = Resolve-FleetPoolRepoIdentity -Repo $repo2; $statePath2 = Get-FleetPoolStatePath $ident2.RepoKey; $st = Read-FleetPoolState $statePath2; $slot = $null
    foreach ($s in @($st.slots)) { if ([string]$s.state -eq 'ready') { $slot = $s; break } }
    Assert-True ($null -ne $slot) 'need ready slot'; $slot.state = 'acquired'; $slot.lease_id = (New-FleetPoolToken); $slot.run_id = 'mismatch-run'; $slot.owner_pid = $null; $slot.owner_start_utc = $null; $slot.processes = @()
    $outcome = Invoke-FleetPoolSanitizeAndRelease -Slot $slot -RepoPath $repo2 -ExpectedCommonDir 'C:\not\a\real\common-dir'
    Assert-True ($outcome -eq 'quarantined') "expected quarantined got $outcome"; Assert-True ([string]$slot.quarantine_reason -eq 'repo_common_dir_mismatch') "reason=$($slot.quarantine_reason)"
  }
}
