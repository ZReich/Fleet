# Pool sanitation, registration, and token-race cases kept out of the suite runner.
function Invoke-FleetPoolUnitHardeningCases {
  Case 'tracked spaced filename sanitizes to ready and preserves run branch' {
    $repo19 = New-TestRepo 'pool-spaced-filename'
    $imageDir = Join-Path $repo19 'packages\backend\src\images'
    New-Item -ItemType Directory -Force -Path $imageDir | Out-Null
    $imagePath = Join-Path $imageDir 'AI _image.svg'
    [IO.File]::WriteAllText($imagePath, '<svg/>')
    $null = @(& git -C $repo19 add -- 'packages/backend/src/images/AI _image.svg' 2>&1)
    $null = @(& git -C $repo19 commit -m 'tracked spaced image' 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) 'commit spaced tracked image'
    Assert-True ((Invoke-PoolScript -ScriptName 'Initialize-FleetWorktreePool.ps1' -ArgList @('-Repo', $repo19, '-Size', '2', '-Mode', 'json')).ExitCode -eq 0) 'init spaced filename repo'
    $enter19 = Invoke-PoolScript -ScriptName 'Enter-FleetWorktreePoolSlot.ps1' -ArgList @('-Repo', $repo19, '-RunId', 'spaced-name', '-Mode', 'json')
    Assert-True ($enter19.ExitCode -eq 0) "enter spaced filename repo: $($enter19.Stderr)"
    $json19 = Get-JsonOut $enter19.Stdout
    Assert-True (Test-Path -LiteralPath (Join-Path ([string]$json19.path) 'packages\backend\src\images\AI _image.svg')) 'tracked spaced filename missing from slot'
    $ignoredImage = Join-Path ([string]$json19.path) 'dist\AI _image.svg'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ignoredImage) | Out-Null
    [IO.File]::WriteAllText($ignoredImage, 'ignored artifact')
    $exit19 = Invoke-PoolScript -ScriptName 'Exit-FleetWorktreePoolSlot.ps1' -ArgList @('-Repo', $repo19, '-RunId', 'spaced-name', '-LeaseId', ([string]$json19.lease_id), '-Mode', 'json')
    Assert-True ($exit19.ExitCode -eq 0) "spaced filename release failed: $($exit19.Stderr) $($exit19.Stdout)"
    $slot19 = Get-FleetPoolSlotFromState -State (Read-FleetPoolState (Get-FleetPoolStatePath (Resolve-FleetPoolRepoIdentity -Repo $repo19).RepoKey)) -SlotId ([string]$json19.slot_id)
    Assert-True ([string]$slot19.state -eq 'ready') "spaced filename slot state=$($slot19.state)"
    Assert-True (-not (Test-Path -LiteralPath $ignoredImage)) 'ignored spaced artifact survived sanitation'
    $null = @(& git -C $repo19 show-ref --verify --quiet 'refs/heads/fleet/spaced-name' 2>$null)
    Assert-True ($LASTEXITCODE -eq 0) 'released run branch was not preserved'
  }

  Case 'locked pool slot survives worktree prune expire now' {
    $repo20 = New-TestRepo 'pool-prune-lock'
    Assert-True ((Invoke-PoolScript -ScriptName 'Initialize-FleetWorktreePool.ps1' -ArgList @('-Repo', $repo20, '-Size', '2', '-Mode', 'json')).ExitCode -eq 0) 'init prune lock'
    $ident20 = Resolve-FleetPoolRepoIdentity -Repo $repo20
    $slot20 = @((Read-FleetPoolState (Get-FleetPoolStatePath $ident20.RepoKey)).slots | Select-Object -First 1)[0]
    $slotPath20 = [string]$slot20.path
    Assert-True (Test-FleetPoolWorktreeLocked -RepoPath $repo20 -SlotPath $slotPath20) 'pool slot is not locked'
    $null = @(& git -C $repo20 worktree prune --expire now 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) 'prune expire now failed'
    Assert-True (Test-FleetPoolWorktreeRegistered -RepoPath $repo20 -SlotPath $slotPath20) 'locked slot registration was pruned'
  }

  Case 'sibling-contained persisted slot path is rejected' {
    $repo21 = New-TestRepo 'pool-prune-repair'
    Assert-True ((Invoke-PoolScript -ScriptName 'Initialize-FleetWorktreePool.ps1' -ArgList @('-Repo', $repo21, '-Size', '2', '-Mode', 'json')).ExitCode -eq 0) 'init prune repair'
    $ident21 = Resolve-FleetPoolRepoIdentity -Repo $repo21; $statePath21 = Get-FleetPoolStatePath $ident21.RepoKey
    $slot21 = @((Read-FleetPoolState $statePath21).slots | Select-Object -First 1)[0]
    $stale21 = Read-FleetPoolState $statePath21
    $otherPath21 = Get-FleetPoolSlotPath $ident21.RepoKey 'slot-02'
    (Get-FleetPoolSlotFromState -State $stale21 -SlotId ([string]$slot21.id)).path = $otherPath21
    Write-FleetPoolState -StatePath $statePath21 -State $stale21
    $repairInit21 = Invoke-PoolScript -ScriptName 'Initialize-FleetWorktreePool.ps1' -ArgList @('-Repo', $repo21, '-Size', '2', '-Mode', 'json')
    Assert-True ($repairInit21.ExitCode -ne 0) "forged sibling slot path was accepted: $($repairInit21.Stdout)"
    Assert-True ($repairInit21.Stderr -match 'Unparseable pool state') "identity rejection missing: $($repairInit21.Stderr)"
  }

  Case 'stolen provisioning token performs zero slot I/O' {
    $repo22 = New-TestRepo 'pool-token-race'
    $ident22 = Resolve-FleetPoolRepoIdentity -Repo $repo22; $statePath22 = Get-FleetPoolStatePath $ident22.RepoKey
    $sentinelSlot = Get-FleetPoolSlotPath $ident22.RepoKey 'slot-01'
    $seed22 = [ordered]@{
      schema_version = $script:FleetPoolSchema; repo_key = $ident22.RepoKey; repo_name = $ident22.RepoName
      repo_path = $ident22.RepoPath; git_common_dir = $ident22.CommonDir; size = 2; base_ref_default = 'HEAD'
      slots = @((New-FleetPoolSlotRecord -SlotId 'slot-01' -Path $sentinelSlot -State 'provisioning'), (New-FleetPoolSlotRecord -SlotId 'slot-02' -Path (Get-FleetPoolSlotPath $ident22.RepoKey 'slot-02') -State 'ready'))
    }
    Write-FleetPoolState -StatePath $statePath22 -State $seed22
    $previousSteal = $env:FLEET_POOL_TEST_STEAL_PROVISION_TOKEN
    try {
      $env:FLEET_POOL_TEST_STEAL_PROVISION_TOKEN = 'slot-01'
      $race = Invoke-PoolScript -ScriptName 'Initialize-FleetWorktreePool.ps1' -ArgList @('-Repo', $repo22, '-Size', '2', '-Mode', 'json')
      Assert-True ($race.ExitCode -ne 0) "stolen token was accepted: $($race.Stdout)"
      Assert-True ($race.Stderr -match 'token mismatch') "missing stolen-token rejection: $($race.Stderr)"
      Assert-True (-not (Test-Path -LiteralPath $sentinelSlot)) 'slot sentinel exists: token race performed slot I/O'
    } finally { $env:FLEET_POOL_TEST_STEAL_PROVISION_TOKEN = $previousSteal }
  }
}
