# Black-box integration suite for Fleet warm worktree pool lifecycle.
# Runs at the integration barrier after pool scripts merge. Parses now; skips if scripts absent.
# PS 5.1. Offline fixtures only (no Harken, no registry, no real USERPROFILE).
$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$requiredScripts = @(
  'Initialize-FleetWorktreePool.ps1',
  'Enter-FleetWorktreePoolSlot.ps1',
  'Exit-FleetWorktreePoolSlot.ps1',
  'Invoke-FleetWorktreePoolReap.ps1',
  'Set-FleetWorktreePoolProcess.ps1',
  'Ensure-FleetDependencies.ps1'
)
$missing = @($requiredScripts | Where-Object { -not (Test-Path -LiteralPath (Join-Path $scriptDir $_)) })
if ($missing.Count -gt 0) {
  Write-Host 'tests: 0/0 SKIPPED (scripts absent — runs at barrier)'
  exit 0
}

. (Join-Path $scriptDir 'FleetWorktreeTest.Helpers.ps1')

$initScript = Join-Path $scriptDir 'Initialize-FleetWorktreePool.ps1'
$enterScript = Join-Path $scriptDir 'Enter-FleetWorktreePoolSlot.ps1'
$exitScript = Join-Path $scriptDir 'Exit-FleetWorktreePoolSlot.ps1'
$reapScript = Join-Path $scriptDir 'Invoke-FleetWorktreePoolReap.ps1'
$procScript = Join-Path $scriptDir 'Set-FleetWorktreePoolProcess.ps1'

$passCount = 0
$failCount = 0
$totalCases = 15
$testHome = $null
$testRepo = $null
$fixtureRoot = $null
$script:RepoRootForHygiene = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
. (Join-Path $scriptDir 'FleetWorktreePool.State.Helpers.ps1')
. (Join-Path $scriptDir 'FleetWorktreePool.Liveness.Helpers.ps1')
. (Join-Path $scriptDir 'FleetWorktreePool.Sanitize.Helpers.ps1')

function Write-CaseResult {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) { $script:passCount++; Write-Host ("PASS {0}" -f $Name) }
  else {
    $script:failCount++
    if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("FAIL {0}" -f $Name) }
    else { Write-Host ("FAIL {0} - {1}" -f $Name, $Detail) }
  }
}
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }

function Invoke-PoolInit {
  param([string]$Repo, [string]$UserProfile, [int]$Size = 2, [string]$BaseRef = 'HEAD', [string]$InstallCommand = '')
  $argList = @('-Repo', $Repo, '-Size', [string]$Size, '-BaseRef', $BaseRef)
  if (-not [string]::IsNullOrWhiteSpace($InstallCommand)) { $argList += @('-InstallCommand', $InstallCommand) }
  return Invoke-FleetPoolScript -ScriptPath $initScript -UserProfile $UserProfile -ArgumentList $argList -TimeoutSeconds 600
}

function Invoke-PoolEnter {
  param(
    [string]$Repo,
    [string]$UserProfile,
    [string]$RunId,
    [string]$BaseRef = 'HEAD',
    [string[]]$CopyFile = @(),
    [string]$InstallCommand = '',
    [switch]$NoInstall
  )
  $argList = @('-Repo', $Repo, '-RunId', $RunId, '-BaseRef', $BaseRef, '-Mode', 'json')
  foreach ($cf in @($CopyFile)) {
    if (-not [string]::IsNullOrWhiteSpace($cf)) { $argList += @('-CopyFile', $cf) }
  }
  if (-not [string]::IsNullOrWhiteSpace($InstallCommand)) {
    $argList += @('-InstallCommand', $InstallCommand)
  }
  if ($NoInstall) { $argList += '-NoInstall' }
  $result = Invoke-FleetPoolScript -ScriptPath $enterScript -UserProfile $UserProfile -ArgumentList $argList -TimeoutSeconds 600
  $json = ConvertFrom-FleetPoolJsonOutput -Text $result.Stdout
  if ($null -eq $json) { $json = ConvertFrom-FleetPoolJsonOutput -Text $result.Stderr }
  $slotPath = [string](Get-FleetJsonProp -Obj $json -Names @('worktree', 'path', 'slot_path', 'SlotPath', 'Worktree'))
  $leaseId = [string](Get-FleetJsonProp -Obj $json -Names @('lease_id', 'leaseId', 'LeaseId'))
  $slotId = [string](Get-FleetJsonProp -Obj $json -Names @('slot_id', 'slot', 'slotId', 'SlotId', 'Slot'))
  if (-not [string]::IsNullOrWhiteSpace($slotPath)) {
    Register-FleetPoolWorktree -Repo $Repo -Path $slotPath
  }
  return [pscustomobject]@{
    ExitCode = $result.ExitCode
    Stdout   = $result.Stdout
    Stderr   = $result.Stderr
    Json     = $json
    Path     = $slotPath
    LeaseId  = $leaseId
    SlotId   = $slotId
    ReuseHit = (Get-FleetJsonProp -Obj $json -Names @('reuse_hit', 'reuseHit', 'ReuseHit'))
  }
}

function Invoke-PoolExit {
  param([string]$Repo, [string]$UserProfile, [string]$RunId, [string]$LeaseId)
  $result = Invoke-FleetPoolScript -ScriptPath $exitScript -UserProfile $UserProfile -ArgumentList @('-Repo', $Repo, '-RunId', $RunId, '-LeaseId', $LeaseId) -TimeoutSeconds 300
  $json = ConvertFrom-FleetPoolJsonOutput -Text $result.Stdout
  if ($null -eq $json) { $json = ConvertFrom-FleetPoolJsonOutput -Text $result.Stderr }
  return [pscustomobject]@{ ExitCode = $result.ExitCode; Stdout = $result.Stdout; Stderr = $result.Stderr; Json = $json; State = [string](Get-FleetJsonProp -Obj $json -Names @('state', 'status', 'outcome', 'slot_state')) }
}
function Invoke-PoolReap {
  param([string]$Repo, [string]$UserProfile)
  return Invoke-FleetPoolScript -ScriptPath $reapScript -UserProfile $UserProfile -ArgumentList @('-Repo', $Repo) -TimeoutSeconds 300
}
function Invoke-PoolProcessRegister {
  param([string]$UserProfile, [string]$Repo, [string]$LeaseId, [int]$ProcessId, [string]$ProcessStartUtc, [string]$Action = 'Register')
  return Invoke-FleetPoolScript -ScriptPath $procScript -UserProfile $UserProfile -ArgumentList @('-Action', $Action, '-Repo', $Repo, '-LeaseId', $LeaseId, '-ProcessId', [string]$ProcessId, '-ProcessStartUtc', $ProcessStartUtc) -TimeoutSeconds 60
}
function Test-NodeModulesPresent {
  param([string]$SlotPath, [string]$PackageName = 'fleet-fixture-dep')
  if ([string]::IsNullOrWhiteSpace($SlotPath)) { return $false }
  return (Test-Path -LiteralPath (Join-Path $SlotPath 'node_modules')) -and (Test-Path -LiteralPath (Join-Path (Join-Path $SlotPath 'node_modules') $PackageName))
}

function Test-TextLooksQuarantined {
  param([string]$State, [string]$Stdout, [string]$Stderr)
  return ((($State + ' ' + $Stdout + ' ' + $Stderr)).ToLowerInvariant() -match 'quarantine')
}
function Get-SlotStateFromPool {
  param([string]$UserProfile, [string]$SlotPath, [string]$SlotId)
  foreach ($slot in @(Get-FleetPoolSlotStates -UserProfile $UserProfile)) {
    $sid = [string](Get-FleetJsonProp -Obj $slot -Names @('slot_id', 'id', 'slot', 'name'))
    $spath = [string](Get-FleetJsonProp -Obj $slot -Names @('path', 'worktree', 'slot_path'))
    $st = [string](Get-FleetJsonProp -Obj $slot -Names @('state', 'status'))
    if (-not [string]::IsNullOrWhiteSpace($SlotId) -and $sid -and ($sid -eq $SlotId)) { return $st }
    if (-not [string]::IsNullOrWhiteSpace($SlotPath) -and $spath) {
      try {
        if ([IO.Path]::GetFullPath($spath).TrimEnd('\').Equals([IO.Path]::GetFullPath($SlotPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $st }
      } catch { }
    }
  }
  return $null
}
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Integration.Helpers.ps1')

try {
  $originalLivenessRelax = $env:FLEET_POOL_TEST_RELAX_UNRELATED
  $originalHarness = $env:FLEET_TEST_HARNESS
  $env:FLEET_TEST_HARNESS = '1'
  $env:FLEET_POOL_TEST_RELAX_UNRELATED = '1'
  $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('fleet-pool-int-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
  [void]$script:FwtTempRoots.Add($fixtureRoot)

  $testHome = New-FleetPoolTestHome -Prefix 'fleet-pool-home'
  $testRepo = New-FleetPoolTestRepo -ParentDir $fixtureRoot -Name 'pool-fixture-repo'
  $mockInstall = New-FleetMockInstallCommand -CounterPath $testHome.CounterPath -PackageName $testRepo.DepName
  $lhome = $testHome.UserProfile
  $repoPath = $testRepo.Path

  # ---- 1. commit + release + re-acquire preserves node_modules (reuse) ----
  try {
    Reset-FleetPoolInstallCount -CounterPath $testHome.CounterPath
    # Size 4 (max allowed) leaves spare slots after quarantine cases 5-6.
    $init1 = Invoke-PoolInit -Repo $repoPath -UserProfile $lhome -Size 4 -BaseRef 'HEAD'
    Assert-True ($init1.ExitCode -eq 0) "init exit=$($init1.ExitCode) err=$($init1.Stderr) out=$($init1.Stdout)"

    $enter1 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'reuse-a1' -InstallCommand $mockInstall
    Assert-True ($enter1.ExitCode -eq 0) "enter1 exit=$($enter1.ExitCode) err=$($enter1.Stderr) out=$($enter1.Stdout)"
    Assert-True (-not [string]::IsNullOrWhiteSpace($enter1.Path)) 'enter1 missing path'
    Assert-True (-not [string]::IsNullOrWhiteSpace($enter1.LeaseId)) 'enter1 missing lease_id'
    Assert-True (Test-NodeModulesPresent -SlotPath $enter1.Path -PackageName $testRepo.DepName) 'node_modules missing after first acquire'

    # Clean commit on lane branch, then release.
    Write-FwtUtf8File -Path (Join-Path $enter1.Path 'lane-note.txt') "committed-work`n"
    & git -C $enter1.Path add lane-note.txt | Out-Null
    $cm = @(& git -C $enter1.Path commit -m 'lane work' 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) "commit failed: $cm"

    $countAfterFirst = Get-FleetPoolInstallCount -CounterPath $testHome.CounterPath
    Assert-True ($countAfterFirst -ge 1) "expected install counter >= 1 after first acquire, got $countAfterFirst"

    $exit1 = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'reuse-a1' -LeaseId $enter1.LeaseId
    Assert-True ($exit1.ExitCode -eq 0) "exit1 exit=$($exit1.ExitCode) err=$($exit1.Stderr) out=$($exit1.Stdout)"
    Assert-True (Test-NodeModulesPresent -SlotPath $enter1.Path -PackageName $testRepo.DepName) 'node_modules lost on release'

    $enter2 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'reuse-a2' -InstallCommand $mockInstall
    Assert-True ($enter2.ExitCode -eq 0) "enter2 exit=$($enter2.ExitCode) err=$($enter2.Stderr) out=$($enter2.Stdout)"
    Assert-True (-not [string]::IsNullOrWhiteSpace($enter2.Path)) 'enter2 missing path'
    $path1 = [IO.Path]::GetFullPath($enter1.Path).TrimEnd('\')
    $path2 = [IO.Path]::GetFullPath($enter2.Path).TrimEnd('\')
    Assert-True ($path1.Equals($path2, [StringComparison]::OrdinalIgnoreCase)) "expected same slot re-acquire ($path1 vs $path2)"
    Assert-True (Test-NodeModulesPresent -SlotPath $enter2.Path -PackageName $testRepo.DepName) 'node_modules missing on re-acquire'
    $countAfterSecond = Get-FleetPoolInstallCount -CounterPath $testHome.CounterPath
    Assert-True ($countAfterSecond -eq $countAfterFirst) "reuse must not install (counter $countAfterFirst -> $countAfterSecond)"

    $null = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'reuse-a2' -LeaseId $enter2.LeaseId
    Write-CaseResult -Name '1-reuse-preserves-node_modules' -Ok $true
  } catch {
    Write-CaseResult -Name '1-reuse-preserves-node_modules' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 2. two acquisitions receive distinct slots + lease ids ----
  try {
    $ea = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'dist-a' -InstallCommand $mockInstall
    Assert-True ($ea.ExitCode -eq 0) "enter A exit=$($ea.ExitCode) err=$($ea.Stderr)"
    $eb = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'dist-b' -InstallCommand $mockInstall
    Assert-True ($eb.ExitCode -eq 0) "enter B exit=$($eb.ExitCode) err=$($eb.Stderr)"
    Assert-True (-not [string]::IsNullOrWhiteSpace($ea.Path) -and -not [string]::IsNullOrWhiteSpace($eb.Path)) 'missing paths'
    Assert-True (-not [string]::IsNullOrWhiteSpace($ea.LeaseId) -and -not [string]::IsNullOrWhiteSpace($eb.LeaseId)) 'missing lease ids'
    $pa = [IO.Path]::GetFullPath($ea.Path).TrimEnd('\')
    $pb = [IO.Path]::GetFullPath($eb.Path).TrimEnd('\')
    Assert-True (-not $pa.Equals($pb, [StringComparison]::OrdinalIgnoreCase)) "slots not distinct: $pa"
    Assert-True ($ea.LeaseId -cne $eb.LeaseId) "lease ids not distinct: $($ea.LeaseId)"
    if (-not [string]::IsNullOrWhiteSpace($ea.SlotId) -and -not [string]::IsNullOrWhiteSpace($eb.SlotId)) {
      Assert-True ($ea.SlotId -cne $eb.SlotId) "slot ids not distinct: $($ea.SlotId)"
    }
    $null = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'dist-a' -LeaseId $ea.LeaseId
    $null = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'dist-b' -LeaseId $eb.LeaseId
    Write-CaseResult -Name '2-distinct-slots-and-leases' -Ok $true
  } catch {
    Write-CaseResult -Name '2-distinct-slots-and-leases' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 3. lockfile mutation increments install counter exactly once ----
  try {
    Reset-FleetPoolInstallCount -CounterPath $testHome.CounterPath
    # Fresh init on mutated baseline would reinstall; use existing pool + commit lock change on main.
    $e3a = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'lock-a' -InstallCommand $mockInstall
    Assert-True ($e3a.ExitCode -eq 0) "enter lock-a exit=$($e3a.ExitCode) err=$($e3a.Stderr)"
    $null = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'lock-a' -LeaseId $e3a.LeaseId
    $beforeMut = Get-FleetPoolInstallCount -CounterPath $testHome.CounterPath

    $lockPath = Join-Path $repoPath 'package-lock.json'
    # Guaranteed lockfile byte change (fingerprint input) while remaining valid lock JSON.
    $depLine = '        "' + $testRepo.DepName + '": "file:./' + $testRepo.TgzRel + '"'
    $nmKey = 'node_modules/' + $testRepo.DepName
    $newLock = @(
      '{',
      '  "name": "fleet-pool-fixture",',
      '  "version": "1.0.0",',
      '  "lockfileVersion": 3,',
      '  "requires": true,',
      '  "packages": {',
      '    "": {',
      '      "name": "fleet-pool-fixture",',
      '      "version": "1.0.0",',
      '      "dependencies": {',
      $depLine,
      '      }',
      '    },',
      ('    "' + $nmKey + '": {'),
      '      "version": "1.0.0",',
      ('      "resolved": "file:./' + $testRepo.TgzRel + '",'),
      '      "integrity": "sha512-fleetlockmut0000000000000000000000000000000000000000000000000000=="',
      '    }',
      '  }',
      '}',
      ''
    ) -join "`n"
    Write-FwtUtf8File -Path $lockPath -Text $newLock
    & git -C $repoPath add package-lock.json | Out-Null
    $cmut = @(& git -C $repoPath commit -m 'mutate lockfile' 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) "lock commit failed: $cmut"

    $e3b = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'lock-b' -BaseRef 'HEAD' -InstallCommand $mockInstall
    Assert-True ($e3b.ExitCode -eq 0) "enter lock-b exit=$($e3b.ExitCode) err=$($e3b.Stderr)"
    $afterMut = Get-FleetPoolInstallCount -CounterPath $testHome.CounterPath
    Assert-True ($afterMut -eq ($beforeMut + 1)) "lock mutation must install exactly once (before=$beforeMut after=$afterMut)"
    $null = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'lock-b' -LeaseId $e3b.LeaseId

    $e3c = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'lock-c' -BaseRef 'HEAD' -InstallCommand $mockInstall
    Assert-True ($e3c.ExitCode -eq 0) "enter lock-c exit=$($e3c.ExitCode) err=$($e3c.Stderr)"
    $afterReuse = Get-FleetPoolInstallCount -CounterPath $testHome.CounterPath
    Assert-True ($afterReuse -eq $afterMut) "post-mutation re-acquire must reuse (counter $afterMut -> $afterReuse)"
    $null = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'lock-c' -LeaseId $e3c.LeaseId
    Write-CaseResult -Name '3-lockfile-mutation-installs-once' -Ok $true
  } catch {
    Write-CaseResult -Name '3-lockfile-mutation-installs-once' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 4. copied .env + ignored build output removed; node_modules survives ----
  try {
    $e4 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'clean-env' -CopyFile @($testRepo.EnvRel) -InstallCommand $mockInstall
    Assert-True ($e4.ExitCode -eq 0) "enter clean-env exit=$($e4.ExitCode) err=$($e4.Stderr)"
    $envDst = Join-Path $e4.Path ($testRepo.EnvRel -replace '/', '\')
    Assert-True (Test-Path -LiteralPath $envDst) "copied .env missing at $envDst"
    $distDir = Join-Path $e4.Path 'dist'
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    $distFile = Join-Path $distDir 'out.js'
    Write-FwtUtf8File -Path $distFile -Text "console.log('build')`n"
    Assert-True (Test-Path -LiteralPath $distFile) 'build output not created'
    Assert-True (Test-NodeModulesPresent -SlotPath $e4.Path -PackageName $testRepo.DepName) 'node_modules missing before release'

    $x4 = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'clean-env' -LeaseId $e4.LeaseId
    Assert-True ($x4.ExitCode -eq 0) "exit clean-env exit=$($x4.ExitCode) err=$($x4.Stderr)"
    Assert-True (-not (Test-Path -LiteralPath $envDst)) "copied .env survived release: $envDst"
    Assert-True (-not (Test-Path -LiteralPath $distFile)) "ignored build output survived release: $distFile"
    Assert-True (Test-NodeModulesPresent -SlotPath $e4.Path -PackageName $testRepo.DepName) 'node_modules removed on clean release'
    Write-CaseResult -Name '4-release-strips-env-and-build-keeps-deps' -Ok $true
  } catch {
    Write-CaseResult -Name '4-release-strips-env-and-build-keeps-deps' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 5. dirty tracked edit quarantined; bytes preserved ----
  try {
    $e5 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'dirty-1' -InstallCommand $mockInstall
    Assert-True ($e5.ExitCode -eq 0) "enter dirty exit=$($e5.ExitCode) err=$($e5.Stderr)"
    $tracked = Join-Path $e5.Path 'tracked.txt'
    Assert-True (Test-Path -LiteralPath $tracked) 'tracked.txt missing in slot'
    $dirtyPayload = 'dirty-uncommitted-' + [guid]::NewGuid().ToString('n')
    Write-FwtUtf8File -Path $tracked -Text $dirtyPayload
    $x5 = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'dirty-1' -LeaseId $e5.LeaseId
    $qText = Test-TextLooksQuarantined -State $x5.State -Stdout $x5.Stdout -Stderr $x5.Stderr
    $poolState = Get-SlotStateFromPool -UserProfile $lhome -SlotPath $e5.Path -SlotId $e5.SlotId
    $poolQ = ($poolState -and ($poolState.ToLowerInvariant() -match 'quarantine'))
    Assert-True ($qText -or $poolQ -or ($x5.ExitCode -ne 0)) "dirty release must quarantine (exit=$($x5.ExitCode) state=$($x5.State) pool=$poolState out=$($x5.Stdout) err=$($x5.Stderr))"
    Assert-True (Test-Path -LiteralPath $tracked) 'dirty file deleted'
    $kept = [IO.File]::ReadAllText($tracked)
    Assert-True ($kept -ceq $dirtyPayload) 'dirty bytes not preserved'
    Write-CaseResult -Name '5-dirty-slot-quarantined' -Ok $true
  } catch {
    Write-CaseResult -Name '5-dirty-slot-quarantined' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 6. escaping junction quarantined; victim byte-identical ----
  try {
    # Need a ready slot; if prior quarantine exhausted pool, re-init may be required.
    $readyEnter = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'junc-1' -InstallCommand $mockInstall
    if ($readyEnter.ExitCode -ne 0) {
      # Pool may be exhausted by quarantine; initialize size 3 on same repo identity if allowed, else fail clearly.
      $null = Invoke-PoolInit -Repo $repoPath -UserProfile $lhome -Size 2 -BaseRef 'HEAD'
      $readyEnter = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'junc-1' -InstallCommand $mockInstall
    }
    Assert-True ($readyEnter.ExitCode -eq 0) "enter junc exit=$($readyEnter.ExitCode) err=$($readyEnter.Stderr) out=$($readyEnter.Stdout)"
    $victim = New-FleetPoolVictimDir -ParentDir $fixtureRoot -Name 'escape-victim'
    $beforeVic = Get-FleetVictimSnapshot -Victim $victim
    $linkPath = Join-Path $readyEnter.Path 'escape-link'
    $null = New-FleetPoolJunction -LinkPath $linkPath -TargetPath $victim.Path
    Assert-True (Test-Path -LiteralPath $linkPath) 'junction not created'
    $x6 = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'junc-1' -LeaseId $readyEnter.LeaseId
    $q6 = Test-TextLooksQuarantined -State $x6.State -Stdout $x6.Stdout -Stderr $x6.Stderr
    $pool6 = Get-SlotStateFromPool -UserProfile $lhome -SlotPath $readyEnter.Path -SlotId $readyEnter.SlotId
    $poolQ6 = ($pool6 -and ($pool6.ToLowerInvariant() -match 'quarantine'))
    Assert-True ($q6 -or $poolQ6 -or ($x6.ExitCode -ne 0)) "escaping junction must quarantine (exit=$($x6.ExitCode) state=$($x6.State) pool=$pool6)"
    Assert-FleetVictimUnchanged -Victim $victim -Before $beforeVic -Context 'escaping-junction'
    # Safety: remove link with rmdir only (never recurse through it).
    Remove-FleetPoolJunction -LinkPath $linkPath
    Write-CaseResult -Name '6-escaping-junction-victim-safe' -Ok $true
  } catch {
    Write-CaseResult -Name '6-escaping-junction-victim-safe' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 7. live registered child blocks release; after death release/reap works ----
  try {
    # Ensure at least one ready slot available.
    $e7 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'live-proc' -InstallCommand $mockInstall
    if ($e7.ExitCode -ne 0) {
      $null = Invoke-PoolInit -Repo $repoPath -UserProfile $lhome -Size 3 -BaseRef 'HEAD'
      $e7 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'live-proc' -InstallCommand $mockInstall
    }
    Assert-True ($e7.ExitCode -eq 0) "enter live-proc exit=$($e7.ExitCode) err=$($e7.Stderr)"
    $child = Start-FleetPoolSleepChild -Seconds 600
    $reg = Invoke-PoolProcessRegister -UserProfile $lhome -Repo $repoPath -LeaseId $e7.LeaseId -ProcessId $child.ProcessId -ProcessStartUtc $child.ProcessStartUtc -Action 'Register'
    Assert-True ($reg.ExitCode -eq 0) "register exit=$($reg.ExitCode) err=$($reg.Stderr) out=$($reg.Stdout)"

    $xLive = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'live-proc' -LeaseId $e7.LeaseId
    Assert-True ($xLive.ExitCode -ne 0) "live child must block release (exit=$($xLive.ExitCode) out=$($xLive.Stdout) err=$($xLive.Stderr))"

    Stop-FleetPoolSleepChild -Child $child
    Start-Sleep -Milliseconds 400

    $xDead = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'live-proc' -LeaseId $e7.LeaseId
    if ($xDead.ExitCode -ne 0) {
      $reap7 = Invoke-PoolReap -Repo $repoPath -UserProfile $lhome
      Assert-True ($reap7.ExitCode -eq 0) "reap after death exit=$($reap7.ExitCode) err=$($reap7.Stderr)"
    } else {
      Assert-True ($true) 'release succeeded after child death'
    }
    Write-CaseResult -Name '7-live-child-blocks-then-release' -Ok $true
  } catch {
    Write-CaseResult -Name '7-live-child-blocks-then-release' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 8. reap never removes a worktree ----
  try {
    $beforeCount = Get-FleetWorktreeListCount -Repo $repoPath
    Assert-True ($beforeCount -ge 1) "expected registered worktrees, got $beforeCount"
    $reap8 = Invoke-PoolReap -Repo $repoPath -UserProfile $lhome
    Assert-True ($reap8.ExitCode -eq 0) "reap exit=$($reap8.ExitCode) err=$($reap8.Stderr) out=$($reap8.Stdout)"
    $afterCount = Get-FleetWorktreeListCount -Repo $repoPath
    Assert-True ($afterCount -eq $beforeCount) "reap changed worktree count ($beforeCount -> $afterCount)"
    Write-CaseResult -Name '8-reap-preserves-worktrees' -Ok $true
  } catch {
    Write-CaseResult -Name '8-reap-preserves-worktrees' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 9. live registered worker blocks reap AND exit; after death Exit or reap-quarantine ----
  try {
    $e9 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'live-block' -InstallCommand $mockInstall
    if ($e9.ExitCode -ne 0) { $null = Invoke-PoolInit -Repo $repoPath -UserProfile $lhome -Size 3 -BaseRef 'HEAD' -InstallCommand $mockInstall; $e9 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'live-block' -InstallCommand $mockInstall }
    Assert-True ($e9.ExitCode -eq 0) "enter live-block exit=$($e9.ExitCode)"
    $child9 = Start-FleetPoolSleepChild -Seconds 600
    Assert-True ((Invoke-PoolProcessRegister -UserProfile $lhome -Repo $repoPath -LeaseId $e9.LeaseId -ProcessId $child9.ProcessId -ProcessStartUtc $child9.ProcessStartUtc -Action 'Register').ExitCode -eq 0) 'register'
    Assert-True ((Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'live-block' -LeaseId $e9.LeaseId).ExitCode -ne 0) 'live blocks exit'
    Assert-True ((Invoke-PoolReap -Repo $repoPath -UserProfile $lhome).ExitCode -eq 0) 'reap live'
    $poolLive = Get-SlotStateFromPool -UserProfile $lhome -SlotPath $e9.Path -SlotId $e9.SlotId
    Assert-True ($poolLive -and ($poolLive.ToLowerInvariant() -match 'acquir')) "reap left $poolLive"
    Stop-FleetPoolSleepChild -Child $child9; Start-Sleep -Milliseconds 400
    $xDead9 = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'live-block' -LeaseId $e9.LeaseId
    if ($xDead9.ExitCode -ne 0) {
      $null = Invoke-PoolProcessRegister -UserProfile $lhome -Repo $repoPath -LeaseId $e9.LeaseId -ProcessId $child9.ProcessId -ProcessStartUtc $child9.ProcessStartUtc -Action 'Unregister'
      $xDead9b = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'live-block' -LeaseId $e9.LeaseId
      if ($xDead9b.ExitCode -ne 0) {
        Assert-True ((Invoke-PoolReap -Repo $repoPath -UserProfile $lhome).ExitCode -eq 0) 'reap dead'
        $poolDead = Get-SlotStateFromPool -UserProfile $lhome -SlotPath $e9.Path -SlotId $e9.SlotId
        Assert-True ($poolDead -and ($poolDead.ToLowerInvariant() -match 'quarantine') -and ($poolDead.ToLowerInvariant() -ne 'ready')) "pool=$poolDead"
      }
    }
    Write-CaseResult -Name '9-live-worker-blocks-reap-and-exit' -Ok $true
  } catch {
    Write-CaseResult -Name '9-live-worker-blocks-reap-and-exit' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 10. orphan acquired (no registration) quarantined; not re-acquired ----
  try {
    Restore-FleetPoolReadySlots -UserProfile $lhome
    $e10 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'orphan-1' -InstallCommand $mockInstall
    if ($e10.ExitCode -ne 0) {
      $null = Invoke-PoolInit -Repo $repoPath -UserProfile $lhome -Size 3 -BaseRef 'HEAD' -InstallCommand $mockInstall
      $e10 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'orphan-1' -InstallCommand $mockInstall
    }
    Assert-True ($e10.ExitCode -eq 0) "enter orphan exit=$($e10.ExitCode) err=$($e10.Stderr)"
    # Poison owner to dead + clear processes (orphan shape)
    $poolJson = Find-FleetPoolJsonPath -UserProfile $lhome
    Assert-True (-not [string]::IsNullOrWhiteSpace($poolJson)) 'pool.json missing'
    $stObj = ([IO.File]::ReadAllText($poolJson) | ConvertFrom-Json)
    foreach ($s in @($stObj.slots)) {
      if ([string]$s.lease_id -eq $e10.LeaseId) {
        $s.owner_pid = 999999
        $s.owner_start_utc = '2000-01-01T00:00:00.0000000+00:00'
        $s.processes = @()
        break
      }
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($poolJson, ($stObj | ConvertTo-Json -Depth 10), $utf8)
    $reap10 = Invoke-PoolReap -Repo $repoPath -UserProfile $lhome
    Assert-True ($reap10.ExitCode -eq 0) "reap orphan exit=$($reap10.ExitCode)"
    $pool10 = Get-SlotStateFromPool -UserProfile $lhome -SlotPath $e10.Path -SlotId $e10.SlotId
    Assert-True ($pool10 -and ($pool10.ToLowerInvariant() -match 'quarantine')) "orphan must quarantine (pool=$pool10)"
    # Second acquirer must not get the orphan path
    $e10b = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'orphan-2' -InstallCommand $mockInstall
    if ($e10b.ExitCode -eq 0) {
      $pA = [IO.Path]::GetFullPath($e10.Path).TrimEnd('\')
      $pB = [IO.Path]::GetFullPath($e10b.Path).TrimEnd('\')
      Assert-True (-not $pA.Equals($pB, [StringComparison]::OrdinalIgnoreCase)) "double-occupancy on orphan path"
      $null = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'orphan-2' -LeaseId $e10b.LeaseId
    }
    Write-CaseResult -Name '10-orphan-acquired-quarantined' -Ok $true
  } catch {
    Write-CaseResult -Name '10-orphan-acquired-quarantined' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 11. live preparing untouched; dead preparing => orphan-stuck ----
  try {
    Restore-FleetPoolReadySlots -UserProfile $lhome
    $poolJson11 = Find-FleetPoolJsonPath -UserProfile $lhome
    Assert-True (-not [string]::IsNullOrWhiteSpace($poolJson11)) 'pool.json missing'
    $st11 = ([IO.File]::ReadAllText($poolJson11) | ConvertFrom-Json)
    $prepSlot = $null; foreach ($s in @($st11.slots)) { if ([string]$s.state -eq 'ready') { $prepSlot = $s; break } }
    if ($null -eq $prepSlot) {
      $null = Invoke-PoolInit -Repo $repoPath -UserProfile $lhome -Size 3 -BaseRef 'HEAD' -InstallCommand $mockInstall
      $st11 = ([IO.File]::ReadAllText((Find-FleetPoolJsonPath -UserProfile $lhome)) | ConvertFrom-Json)
      foreach ($s in @($st11.slots)) { if ([string]$s.state -eq 'ready') { $prepSlot = $s; break } }
    }
    Assert-True ($null -ne $prepSlot) 'need ready'
    $prepSlot.state = 'preparing'; $prepSlot.lease_id = ([guid]::NewGuid().ToString('n')); $prepSlot.run_id = 'prep-int-live'
    $prepSlot.owner_pid = $PID; $prepSlot.owner_start_utc = (Get-FleetPoolProcessStartUtc -ProcessId $PID); $prepSlot.processes = @()
    $prepIdLive = [string]$prepSlot.id; $utf8b = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Find-FleetPoolJsonPath -UserProfile $lhome), ($st11 | ConvertTo-Json -Depth 10), $utf8b)
    Assert-True ((Invoke-PoolReap -Repo $repoPath -UserProfile $lhome).ExitCode -eq 0) 'reap live prep'
    $pool11a = Get-SlotStateFromPool -UserProfile $lhome -SlotId $prepIdLive
    Assert-True ($pool11a -and ($pool11a.ToLowerInvariant() -eq 'preparing')) "live prep $pool11a"
    $st11b = ([IO.File]::ReadAllText((Find-FleetPoolJsonPath -UserProfile $lhome)) | ConvertFrom-Json)
    foreach ($s in @($st11b.slots)) { if ([string]$s.id -eq $prepIdLive) { $s.owner_pid = 999999; $s.owner_start_utc = '2000-01-01T00:00:00.0000000+00:00'; $s.processes = @() } }
    [IO.File]::WriteAllText((Find-FleetPoolJsonPath -UserProfile $lhome), ($st11b | ConvertTo-Json -Depth 10), $utf8b)
    Assert-True ((Invoke-PoolReap -Repo $repoPath -UserProfile $lhome).ExitCode -eq 0) 'reap dead prep'
    $pool11b = Get-SlotStateFromPool -UserProfile $lhome -SlotId $prepIdLive
    Assert-True ($pool11b -and ($pool11b.ToLowerInvariant() -match 'quarantine')) "dead prep $pool11b"
    Write-CaseResult -Name '11-preparing-dead-lease-quarantines' -Ok $true
  } catch {
    Write-CaseResult -Name '11-preparing-dead-lease-quarantines' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 12. -NoInstall on pool path does not run npm ----
  try {
    Restore-FleetPoolReadySlots -UserProfile $lhome
    Reset-FleetPoolInstallCount -CounterPath $testHome.CounterPath
    $beforeNi = Get-FleetPoolInstallCount -CounterPath $testHome.CounterPath
    $eNi = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'noinst-int' -InstallCommand $mockInstall -NoInstall
    Assert-True ($eNi.ExitCode -eq 0) "enter NoInstall exit=$($eNi.ExitCode) err=$($eNi.Stderr) out=$($eNi.Stdout)"
    $afterNi = Get-FleetPoolInstallCount -CounterPath $testHome.CounterPath
    Assert-True ($afterNi -eq $beforeNi) "NoInstall must not bump install counter ($beforeNi -> $afterNi)"
    $null = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'noinst-int' -LeaseId $eNi.LeaseId
    Write-CaseResult -Name '12-NoInstall-skips-npm' -Ok $true
  } catch {
    Write-CaseResult -Name '12-NoInstall-skips-npm' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 13. delete-target containment via escaping junction (victim byte-identical) ----
  try {
    Restore-FleetPoolReadySlots -UserProfile $lhome
    $e13 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'contain-1' -InstallCommand $mockInstall
    Assert-True ($e13.ExitCode -eq 0) "enter contain exit=$($e13.ExitCode)"
    $victim13 = New-FleetPoolVictimDir -ParentDir $fixtureRoot -Name 'contain-victim'
    $beforeVic13 = Get-FleetVictimSnapshot -Victim $victim13
    $link13 = Join-Path $e13.Path 'contain-escape'; $null = New-FleetPoolJunction -LinkPath $link13 -TargetPath $victim13.Path
    $x13 = Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'contain-1' -LeaseId $e13.LeaseId
    $pool13 = Get-SlotStateFromPool -UserProfile $lhome -SlotPath $e13.Path -SlotId $e13.SlotId
    Assert-True ((Test-TextLooksQuarantined -State $x13.State -Stdout $x13.Stdout -Stderr $x13.Stderr) -or ($pool13 -and ($pool13.ToLowerInvariant() -match 'quarantine')) -or ($x13.ExitCode -ne 0)) "containment exit=$($x13.ExitCode) pool=$pool13"
    Assert-FleetVictimUnchanged -Victim $victim13 -Before $beforeVic13 -Context 'delete-containment'
    Remove-FleetPoolJunction -LinkPath $link13
    Write-CaseResult -Name '13-delete-target-containment' -Ok $true
  } catch {
    Write-CaseResult -Name '13-delete-target-containment' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 14. e2e: resolve context + live cmdline quarantine + reap never ready ----
  try {
    Restore-FleetPoolReadySlots -UserProfile $lhome
    $e14 = Invoke-PoolEnter -Repo $repoPath -UserProfile $lhome -RunId 'e2e-int' -InstallCommand $mockInstall
    Assert-True ($e14.ExitCode -eq 0) "enter e2e exit=$($e14.ExitCode)"
    $st14 = ([IO.File]::ReadAllText((Find-FleetPoolJsonPath -UserProfile $lhome)) | ConvertFrom-Json)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$st14.repo_path)) 'repo_path missing'
    $prevProf = $env:USERPROFILE
    try {
      $env:USERPROFILE = $lhome
      $ctx = Resolve-FleetPoolSlotContext -WorkingDirectory $e14.Path
      Assert-True (($null -ne $ctx) -and ([string]$ctx.LeaseId -eq $e14.LeaseId)) 'ctx root'
      $sub = Join-Path $e14.Path 'packages\backend'; if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Force -Path $sub | Out-Null }
      Assert-True (([string](Resolve-FleetPoolSlotContext -WorkingDirectory $sub).LeaseId) -eq $e14.LeaseId) 'ctx sub'
      Assert-True ([IO.Path]::GetFullPath([string]$ctx.RepoPath).TrimEnd('\').Equals([IO.Path]::GetFullPath($repoPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) 'RepoPath'
    } finally { $env:USERPROFILE = $prevProf }
    $spath14 = [IO.Path]::GetFullPath($e14.Path).TrimEnd('\')
    $psi14 = New-Object System.Diagnostics.ProcessStartInfo
    $psi14.FileName = 'powershell.exe'; $psi14.Arguments = "-NoProfile -Command `"Start-Sleep -Seconds 600; Write-Output '$spath14'`""
    $psi14.UseShellExecute = $false; $psi14.CreateNoWindow = $true; $psi14.RedirectStandardOutput = $true; $psi14.RedirectStandardError = $true
    $child14 = [System.Diagnostics.Process]::Start($psi14)
    try {
      Start-Sleep -Milliseconds 400
      Assert-True ((Invoke-PoolReap -Repo $repoPath -UserProfile $lhome).ExitCode -eq 0) 'reap live cmdline'
      Assert-True (((Get-SlotStateFromPool -UserProfile $lhome -SlotPath $e14.Path -SlotId $e14.SlotId) + '').ToLowerInvariant() -match 'acquir') 'reap left acquired'
      Assert-True ((Invoke-PoolExit -Repo $repoPath -UserProfile $lhome -RunId 'e2e-int' -LeaseId $e14.LeaseId).ExitCode -ne 0) 'exit refuse'
      Assert-True (((Get-SlotStateFromPool -UserProfile $lhome -SlotPath $e14.Path -SlotId $e14.SlotId) + '').ToLowerInvariant() -match 'quarantine') 'exit quarantine'
    } finally { try { if (-not $child14.HasExited) { $child14.Kill() } } catch { }; try { $null = $child14.WaitForExit(3000) } catch { }; $child14.Dispose() }
    $poolJsonDead = Find-FleetPoolJsonPath -UserProfile $lhome
    $stDead = ([IO.File]::ReadAllText($poolJsonDead) | ConvertFrom-Json)
    $beforeReady = @($stDead.slots | Where-Object { [string]$_.state -eq 'ready' }).Count
    foreach ($s in @($stDead.slots)) { if ([string]$s.state -eq 'acquired') { $s.owner_pid = 999986; $s.owner_start_utc = '2000-01-01T00:00:00.0000000+00:00'; $s.processes = @() } }
    [IO.File]::WriteAllText($poolJsonDead, ($stDead | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    $reapDead = Invoke-PoolReap -Repo $repoPath -UserProfile $lhome
    Assert-True ($reapDead.ExitCode -eq 0) 'reap dead'
    $rj = ConvertFrom-FleetPoolJsonOutput -Text $reapDead.Stdout; if ($null -eq $rj) { $rj = ConvertFrom-FleetPoolJsonOutput -Text $reapDead.Stderr }
    if ($null -ne $rj) { Assert-True ([int]$rj.reaped -eq 0) "reaped=$($rj.reaped)" }
    $afterReady = @(([IO.File]::ReadAllText((Find-FleetPoolJsonPath -UserProfile $lhome)) | ConvertFrom-Json).slots | Where-Object { [string]$_.state -eq 'ready' }).Count
    Assert-True ($afterReady -le $beforeReady) "ready grew $beforeReady->$afterReady"
    Write-CaseResult -Name '14-e2e-context-cmdline-never-ready' -Ok $true
  } catch {
    Write-CaseResult -Name '14-e2e-context-cmdline-never-ready' -Ok $false -Detail $_.Exception.Message
  }

  # ---- 15. mandatory lifecycle telemetry ----
  try {
    $ledger15 = Join-Path $lhome '.codex\fleet\worktree-pool.jsonl'
    Assert-True (Test-Path -LiteralPath $ledger15) 'telemetry ledger missing'
    $telemetry15 = @([IO.File]::ReadAllLines($ledger15) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    $events15 = @($telemetry15 | ForEach-Object { $_.event })
    Assert-True ($events15 -contains 'acquire_complete') "acquire_complete absent: $($events15 -join ',')"
    Assert-True ($events15 -contains 'release_complete') "release_complete absent: $($events15 -join ',')"
    foreach ($row15 in @($telemetry15 | Where-Object { [string]$_.event -in @('acquire_complete', 'release_complete') })) {
      Assert-True (-not [string]::IsNullOrWhiteSpace([string]$row15.outcome)) "empty outcome for $($row15.event)"
      Assert-True (-not [string]::IsNullOrWhiteSpace([string]$row15.reason)) "empty reason for $($row15.event)"
      Assert-True (-not [string]::IsNullOrWhiteSpace([string]$row15.ownership)) "empty ownership for $($row15.event)"
      Assert-True ($null -ne $row15.duration_ms) "empty duration_ms for $($row15.event)"
    }
    Write-CaseResult -Name '15-mandatory-acquire-release-telemetry' -Ok $true
  } catch {
    Write-CaseResult -Name '15-mandatory-acquire-release-telemetry' -Ok $false -Detail $_.Exception.Message
  }

  $nmLeak = Join-Path $script:RepoRootForHygiene 'node_modules'
  Assert-True (-not (Test-Path -LiteralPath $nmLeak)) "suite left node_modules at repo root: $nmLeak"
}
finally {
  $env:FLEET_TEST_HARNESS = $originalHarness
  $env:FLEET_POOL_TEST_RELAX_UNRELATED = $originalLivenessRelax
  $repoForCleanup = $null; if ($null -ne $testRepo) { $repoForCleanup = $testRepo.Path }
  try { Clear-FleetPoolTestArtifacts -Repo $repoForCleanup } catch { Write-Host ("cleanup-warn: {0}" -f $_.Exception.Message) }
  try {
    $nmLeakF = Join-Path $script:RepoRootForHygiene 'node_modules'
    if (Test-Path -LiteralPath $nmLeakF) { Write-Host ("cleanup-warn: removing leaked node_modules at {0}" -f $nmLeakF); Remove-Item -LiteralPath $nmLeakF -Recurse -Force -ErrorAction SilentlyContinue }
  } catch { }
}
Write-Host ("tests: {0}/{1}" -f $passCount, $totalCases)
if ($failCount -gt 0 -or $passCount -ne $totalCases) { exit 1 }
exit 0
