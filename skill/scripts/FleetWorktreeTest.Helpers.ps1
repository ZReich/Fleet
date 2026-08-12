# Reusable black-box fixtures for Fleet warm worktree pool integration tests.
# PS 5.1. Dot-source only. Slot cleanup via git worktree remove only (never recursive slot delete).
$ErrorActionPreference = 'Stop'
$script:FwtUtf8 = New-Object System.Text.UTF8Encoding $false
$script:FwtRegisteredWorktrees = New-Object System.Collections.ArrayList
$script:FwtSleepChildren = New-Object System.Collections.ArrayList
$script:FwtJunctions = New-Object System.Collections.ArrayList
$script:FwtTempRoots = New-Object System.Collections.ArrayList

function Write-FwtUtf8File {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $script:FwtUtf8)
}

function Quote-FwtArgs {
  param([string[]]$Tokens)
  (@($Tokens) | ForEach-Object {
    $token = [string]$_
    if ($token.Length -eq 0) { '""' }
    elseif ($token -notmatch '[\s"]') { $token }
    else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }) -join ' '
}

function New-FleetPoolTestHome {
  param([string]$Prefix = 'fleet-pool-test')
  $root = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + '-' + [guid]::NewGuid().ToString('n'))
  $lhome = Join-Path $root 'profile'
  $npm = Join-Path $lhome '.codex\cache\fleet\npm'
  $build = Join-Path $lhome '.codex\cache\fleet\build\sha256'
  $wts = Join-Path $lhome '.codex\worktrees'
  $ev = Join-Path $lhome '.codex\fleet'
  foreach ($d in @($lhome, $npm, $build, $wts, $ev)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  $counterPath = Join-Path $lhome '.codex\cache\fleet\test-install-count.txt'
  Write-FwtUtf8File -Path $counterPath -Text '0'
  [void]$script:FwtTempRoots.Add($root)
  return [pscustomobject]@{ Root=$root; UserProfile=$lhome; NpmStoreRoot=$npm; BuildStoreRoot=$build; WorktreesRoot=$wts; CounterPath=$counterPath }
}

function Get-FleetPoolInstallCount {
  param([Parameter(Mandatory)][string]$CounterPath)
  if (-not (Test-Path -LiteralPath $CounterPath)) { return 0 }
  $raw = [IO.File]::ReadAllText($CounterPath).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) { return 0 }
  return [int]$raw
}

function Reset-FleetPoolInstallCount {
  param([Parameter(Mandatory)][string]$CounterPath)
  Write-FwtUtf8File -Path $CounterPath -Text '0'
}

function New-FleetMockInstallCommand {
  param([Parameter(Mandatory)][string]$CounterPath, [string]$PackageName = 'fleet-fixture-dep')
  $installPs1 = Join-Path (Split-Path -Parent $CounterPath) 'mock-install.ps1'
  $cEsc = $CounterPath.Replace("'", "''"); $pEsc = $PackageName.Replace("'", "''")
  # Always write under process WorkingDirectory (Ensure sets slot cwd). Refuse if cwd looks like a real git root with .fleet scripts marker absent from pool fixtures.
  $body = @(
    '$ErrorActionPreference = ''Stop'''
    "`$cPath = '$cEsc'"; "`$pkg = '$pEsc'"; '$n = 0'
    'if (Test-Path -LiteralPath $cPath) { $t = [IO.File]::ReadAllText($cPath).Trim(); if ($t -match ''^\d+$'') { $n = [int]$t } }'
    '$n++; $parent = Split-Path -Parent $cPath'
    'if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }'
    '[IO.File]::WriteAllText($cPath, [string]$n)'
    '$cwd = [IO.Path]::GetFullPath((Get-Location).Path).TrimEnd(''\'')'
    # Guard: never plant node_modules into a path that still contains scripts\Ensure-FleetDependencies.ps1 (real fleet checkout).
    'if (Test-Path -LiteralPath (Join-Path $cwd ''scripts\Ensure-FleetDependencies.ps1'')) { throw "mock-install refused: cwd is fleet scripts root ($cwd)" }'
    '$nmRoot = Join-Path $cwd ''node_modules'''
    '$dest = Join-Path $nmRoot $pkg'
    'New-Item -ItemType Directory -Force -Path $dest | Out-Null'
    '[IO.File]::WriteAllText((Join-Path $dest ''index.js''), ''module.exports=1'')'
    '[IO.File]::WriteAllText((Join-Path $dest ''package.json''), (''{"name":"'' + $pkg + ''","version":"1.0.0"}''))'
    'exit 0'
  ) -join "`n"
  Write-FwtUtf8File -Path $installPs1 -Text ($body + "`n")
  return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $installPs1 + '"'
}

function New-FwtUstarHeader {
  param([string]$Name, [int]$Size, [string]$TypeFlag = '0')
  $block = New-Object byte[] 512; $ascii = [Text.Encoding]::ASCII
  $nameBytes = $ascii.GetBytes($Name)
  if ($nameBytes.Length -gt 100) { throw "tar name too long: $Name" }
  [Array]::Copy($nameBytes, 0, $block, 0, $nameBytes.Length)
  foreach ($pair in @(@(100,'0000644'),@(108,'0000000'),@(116,'0000000'),@(124,('{0:00000000000}' -f $Size)),@(136,'00000000000'))) {
    $b = $ascii.GetBytes([string]$pair[1]); [Array]::Copy($b, 0, $block, [int]$pair[0], [Math]::Min($b.Length, 12))
  }
  for ($i = 148; $i -lt 156; $i++) { $block[$i] = 0x20 }
  $block[156] = [byte][char]$TypeFlag
  $u = $ascii.GetBytes('ustar'); [Array]::Copy($u, 0, $block, 257, $u.Length)
  $block[262] = 0x30; $block[263] = 0x30
  $sum = 0; foreach ($b in $block) { $sum += $b }
  $chk = $ascii.GetBytes(('{0:000000} ' -f $sum)); [Array]::Copy($chk, 0, $block, 148, [Math]::Min(8, $chk.Length))
  return $block
}

function New-FleetLocalTgzPackage {
  param([Parameter(Mandatory)][string]$VendorDir, [string]$Name = 'fleet-fixture-dep', [string]$Version = '1.0.0')
  if (-not (Test-Path -LiteralPath $VendorDir)) { New-Item -ItemType Directory -Force -Path $VendorDir | Out-Null }
  $pkgJson = "{`"name`":`"$Name`",`"version`":`"$Version`",`"main`":`"index.js`"}"
  $idxJs = 'module.exports = { ok: true };'
  $entries = @(@{ Name='package/package.json'; Bytes=$script:FwtUtf8.GetBytes($pkgJson) }, @{ Name='package/index.js'; Bytes=$script:FwtUtf8.GetBytes($idxJs) })
  $ms = New-Object IO.MemoryStream
  foreach ($ent in $entries) {
    $hdr = New-FwtUstarHeader -Name $ent.Name -Size $ent.Bytes.Length -TypeFlag '0'
    $ms.Write($hdr, 0, 512); $ms.Write($ent.Bytes, 0, $ent.Bytes.Length)
    $pad = (512 - ($ent.Bytes.Length % 512)) % 512
    if ($pad -gt 0) { $ms.Write((New-Object byte[] $pad), 0, $pad) }
  }
  $ms.Write((New-Object byte[] 1024), 0, 1024); $tarBytes = $ms.ToArray(); $ms.Dispose()
  $tgzPath = Join-Path $VendorDir ($Name + '-' + $Version + '.tgz')
  Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
  $fs = [IO.File]::Create($tgzPath)
  try {
    $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Compress, $true)
    try { $gz.Write($tarBytes, 0, $tarBytes.Length) } finally { $gz.Dispose() }
  } finally { $fs.Dispose() }
  if (-not (Test-Path -LiteralPath $tgzPath)) { throw "tgz missing after pack: $tgzPath" }
  return $tgzPath
}

function New-FleetPoolTestRepo {
  param([Parameter(Mandatory)][string]$ParentDir, [string]$Name = 'pool-fixture-repo', [string]$DepName = 'fleet-fixture-dep')
  $path = Join-Path $ParentDir $Name
  if (Test-Path -LiteralPath $path) { throw "repo path exists: $path" }
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  $gitOut = @(& git -C $path init 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "git init failed: $gitOut" }
  & git -C $path config user.name 'fleet-pool-test' | Out-Null
  & git -C $path config user.email 'fleet-pool-test@example.invalid' | Out-Null
  & git -C $path config commit.gpgsign false | Out-Null
  $vendor = Join-Path $path 'vendor'; New-Item -ItemType Directory -Force -Path $vendor | Out-Null
  $tgz = New-FleetLocalTgzPackage -VendorDir $vendor -Name $DepName -Version '1.0.0'
  $tgzRel = 'vendor/' + [IO.Path]::GetFileName($tgz)
  $depJson = '    "' + $DepName + '": "file:./' + $tgzRel + '"'
  Write-FwtUtf8File -Path (Join-Path $path 'package.json') ("{`n  `"name`": `"fleet-pool-fixture`",`n  `"version`": `"1.0.0`",`n  `"private`": true,`n  `"dependencies`": {`n$depJson`n  }`n}`n")
  Write-FwtUtf8File -Path (Join-Path $path 'package-lock.json') ("{`n  `"name`": `"fleet-pool-fixture`",`n  `"version`": `"1.0.0`",`n  `"lockfileVersion`": 3,`n  `"requires`": true,`n  `"packages`": {`n    `"`": {`n      `"name`": `"fleet-pool-fixture`",`n      `"version`": `"1.0.0`",`n      `"dependencies`": {`n$depJson`n      }`n    }`n  }`n}`n")
  Write-FwtUtf8File -Path (Join-Path $path '.gitignore') "node_modules/`ndist/`n.env`n*.log`n"
  Write-FwtUtf8File -Path (Join-Path $path 'README.md') "fleet pool fixture`n"
  Write-FwtUtf8File -Path (Join-Path $path '.env') "SECRET=fixture-env-1`n"
  $pkgDir = Join-Path $path 'packages\backend'; New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
  Write-FwtUtf8File -Path (Join-Path $pkgDir '.env') "SECRET=backend-env-1`n"
  Write-FwtUtf8File -Path (Join-Path $path 'tracked.txt') "baseline`n"
  & git -C $path add -A | Out-Null
  $cOut = @(& git -C $path commit -m 'fixture baseline' 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "git commit failed: $cOut" }
  return [pscustomobject]@{ Path=$path; Head=((& git -C $path rev-parse HEAD).Trim()); DepName=$DepName; TgzRel=$tgzRel; EnvRel='packages/backend/.env' }
}

function New-FleetPoolVictimDir {
  param([Parameter(Mandatory)][string]$ParentDir, [string]$Name = 'victim')
  $path = Join-Path $ParentDir $Name; New-Item -ItemType Directory -Force -Path $path | Out-Null
  $marker = Join-Path $path 'KEEP_ME.txt'; $payload = 'victim-bytes-' + [guid]::NewGuid().ToString('n')
  Write-FwtUtf8File -Path $marker -Text $payload
  return [pscustomobject]@{ Path=$path; MarkerPath=$marker; Payload=$payload }
}

function Get-FleetVictimSnapshot {
  param([Parameter(Mandatory)]$Victim)
  $exists = Test-Path -LiteralPath $Victim.MarkerPath
  $text = if ($exists) { [IO.File]::ReadAllText($Victim.MarkerPath) } else { $null }
  $fileCount = 0
  if (Test-Path -LiteralPath $Victim.Path) { $fileCount = @(Get-ChildItem -LiteralPath $Victim.Path -Recurse -File -Force -ErrorAction SilentlyContinue).Count }
  return [pscustomobject]@{ Exists=$exists; Text=$text; FileCount=$fileCount }
}

function Assert-FleetVictimUnchanged {
  param([Parameter(Mandatory)]$Victim, [Parameter(Mandatory)]$Before, [string]$Context = 'victim')
  $after = Get-FleetVictimSnapshot -Victim $Victim
  if (-not $after.Exists) { throw "$Context : victim marker missing" }
  if ($after.Text -cne $Before.Text) { throw "$Context : victim bytes changed" }
  if ($after.FileCount -ne $Before.FileCount) { throw "$Context : victim file count changed ($($Before.FileCount)->$($after.FileCount))" }
}

function New-FleetPoolJunction {
  param([Parameter(Mandatory)][string]$LinkPath, [Parameter(Mandatory)][string]$TargetPath)
  $parent = Split-Path -Parent $LinkPath
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  if (Test-Path -LiteralPath $LinkPath) { throw "junction link path already exists: $LinkPath" }
  $cmdOut = & cmd.exe /c "mklink /J `"$LinkPath`" `"$TargetPath`"" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "mklink /J failed: $cmdOut" }
  [void]$script:FwtJunctions.Add($LinkPath); return $LinkPath
}

function Remove-FleetPoolJunction {
  param([Parameter(Mandatory)][string]$LinkPath)
  if (-not (Test-Path -LiteralPath $LinkPath)) { return }
  & cmd.exe /c "rmdir `"$LinkPath`"" 2>$null | Out-Null
}

function Remove-FleetPoolJunctionsUnder {
  param([string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return }
  $stack = New-Object System.Collections.Stack; $stack.Push([IO.Path]::GetFullPath($Root))
  $found = New-Object System.Collections.ArrayList
  while ($stack.Count -gt 0) {
    $dir = [string]$stack.Pop()
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) { [void]$found.Add($child.FullName); continue }
      $stack.Push($child.FullName)
    }
  }
  foreach ($junc in $found) { Remove-FleetPoolJunction -LinkPath $junc }
}

function Register-FleetPoolWorktree {
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Path)
  $full = [IO.Path]::GetFullPath($Path)
  foreach ($existing in @($script:FwtRegisteredWorktrees)) { if ($existing.Path -eq $full) { return } }
  [void]$script:FwtRegisteredWorktrees.Add(@{ Repo=$Repo; Path=$full })
}

function Remove-FleetPoolRegisteredWorktrees {
  $items = @($script:FwtRegisteredWorktrees); [void]$script:FwtRegisteredWorktrees.Clear()
  foreach ($entry in $items) {
    $repoPath = [string]$entry.Repo; $wtPath = [string]$entry.Path
    if ([string]::IsNullOrWhiteSpace($repoPath) -or [string]::IsNullOrWhiteSpace($wtPath)) { continue }
    if (-not (Test-Path -LiteralPath $wtPath)) { continue }
    Remove-FleetPoolJunctionsUnder -Root $wtPath
    $prevEap = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $null = & git -C $repoPath worktree remove --force -- $wtPath 2>&1
      if ($LASTEXITCODE -ne 0) { $null = & git -C $repoPath worktree prune 2>&1 }
    } finally { $ErrorActionPreference = $prevEap }
  }
}

function Start-FleetPoolSleepChild {
  param([int]$Seconds = 600)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command Start-Sleep -Seconds $Seconds"
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $proc = [System.Diagnostics.Process]::Start($psi); Start-Sleep -Milliseconds 250
  $live = Get-Process -Id $proc.Id -ErrorAction Stop
  $rec = [pscustomobject]@{ ProcessId=$proc.Id; ProcessStartUtc=$live.StartTime.ToUniversalTime().ToString('o'); Process=$proc }
  [void]$script:FwtSleepChildren.Add($rec); return $rec
}

function Stop-FleetPoolSleepChild {
  param($Child)
  if ($null -eq $Child) { return }
  $procObj = $Child.Process; $procId = [int]$Child.ProcessId
  try {
    if ($null -ne $procObj -and -not $procObj.HasExited) { & taskkill.exe /PID $procId /T /F 2>$null | Out-Null; $null = $procObj.WaitForExit(10000) }
    elseif (Get-Process -Id $procId -ErrorAction SilentlyContinue) { & taskkill.exe /PID $procId /T /F 2>$null | Out-Null }
  } catch { }
  try { if ($null -ne $procObj) { $procObj.Dispose() } } catch { }
}

function Stop-AllFleetPoolSleepChildren {
  foreach ($child in @($script:FwtSleepChildren)) { Stop-FleetPoolSleepChild -Child $child }
  [void]$script:FwtSleepChildren.Clear()
}

function Invoke-FleetPoolScript {
  param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$UserProfile, [string[]]$ArgumentList = @(), [int]$TimeoutSeconds = 300)
  if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "script missing: $ScriptPath" }
  $argTokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ArgumentList)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'; $psi.Arguments = Quote-FwtArgs -Tokens $argTokens
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $UserProfile
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
  $finished = $proc.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
  if (-not $finished) {
    try { & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null } catch { }
    try { $null = $proc.WaitForExit(5000) } catch { }
    $proc.Dispose(); throw "timeout after ${TimeoutSeconds}s: $ScriptPath"
  }
  $code = $proc.ExitCode
  $stdout = if ($outTask.Wait(5000)) { [string]$outTask.Result } else { '' }
  $stderr = if ($errTask.Wait(5000)) { [string]$errTask.Result } else { '' }
  $proc.Dispose()
  return [pscustomobject]@{ ExitCode=$code; Stdout=$stdout.TrimEnd(); Stderr=$stderr.TrimEnd() }
}

function ConvertFrom-FleetPoolJsonOutput {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $candidates = @($Text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') })
  if ($candidates.Count -eq 0) { return $null }
  try { return ($candidates[$candidates.Count - 1].Trim() | ConvertFrom-Json) } catch { return $null }
}

function Get-FleetJsonProp {
  param($Obj, [string[]]$Names)
  if ($null -eq $Obj) { return $null }
  foreach ($name in @($Names)) {
    $prop = $Obj.PSObject.Properties[$name]
    if ($null -eq $prop -or $null -eq $prop.Value) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$prop.Value)) { continue }
    return $prop.Value
  }
  return $null
}

function Get-FleetWorktreeListCount {
  param([Parameter(Mandatory)][string]$Repo)
  $lines = @(& git -C $Repo worktree list --porcelain 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "git worktree list failed: $lines" }
  $count = 0; foreach ($line in $lines) { if ($line -like 'worktree *') { $count++ } }
  return $count
}

function Find-FleetPoolJsonPath {
  param([Parameter(Mandatory)][string]$UserProfile)
  $root = Join-Path $UserProfile '.codex\worktrees'
  if (-not (Test-Path -LiteralPath $root)) { return $null }
  $hit = @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'pool.json' -File -Force -ErrorAction SilentlyContinue)
  if ($hit.Count -eq 0) { return $null }
  return $hit[0].FullName
}

function Get-FleetPoolSlotStates {
  param([Parameter(Mandatory)][string]$UserProfile)
  $poolPath = Find-FleetPoolJsonPath -UserProfile $UserProfile
  if ([string]::IsNullOrWhiteSpace($poolPath) -or -not (Test-Path -LiteralPath $poolPath)) { return @() }
  $obj = ([IO.File]::ReadAllText($poolPath) | ConvertFrom-Json)
  if ($null -ne $obj.slots) { return @($obj.slots) }
  if ($null -ne $obj.Slots) { return @($obj.Slots) }
  return @()
}

function Clear-FleetPoolTestArtifacts {
  param([string]$Repo)
  Stop-AllFleetPoolSleepChildren
  foreach ($junc in @($script:FwtJunctions)) { Remove-FleetPoolJunction -LinkPath $junc }
  [void]$script:FwtJunctions.Clear()
  if (-not [string]::IsNullOrWhiteSpace($Repo)) {
    Remove-FleetPoolRegisteredWorktrees
    try {
      $porcelain = @(& git -C $Repo worktree list --porcelain 2>&1)
      $main = [IO.Path]::GetFullPath($Repo).TrimEnd('\'); $current = $null
      foreach ($line in $porcelain) {
        if ($line -like 'worktree *') { $current = $line.Substring(9).Trim() }
        elseif (($line -eq '') -and $current) {
          $full = [IO.Path]::GetFullPath($current).TrimEnd('\')
          if (-not $full.Equals($main, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-FleetPoolJunctionsUnder -Root $full
            $null = & git -C $Repo worktree remove --force -- $full 2>&1
          }
          $current = $null
        }
      }
      if ($current) {
        $full = [IO.Path]::GetFullPath($current).TrimEnd('\')
        if (-not $full.Equals($main, [StringComparison]::OrdinalIgnoreCase)) {
          Remove-FleetPoolJunctionsUnder -Root $full
          $null = & git -C $Repo worktree remove --force -- $full 2>&1
        }
      }
      $null = & git -C $Repo worktree prune 2>&1
    } catch { }
  }
  foreach ($root in @($script:FwtTempRoots)) {
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
    Remove-FleetPoolJunctionsUnder -Root $root
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
  [void]$script:FwtTempRoots.Clear()
}
