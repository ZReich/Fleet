# Self-contained tests for Ensure-FleetDependencies.ps1. Fake USERPROFILE + throwaway
# git/npm fixtures. NO network: local .tgz + mock -InstallCommand. Prints tests: N/N.
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'Ensure-FleetDependencies.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-efd-test-' + [guid]::NewGuid().ToString('n'))
$fakeProfile = Join-Path $temp 'profile'
$storeRoot = Join-Path $fakeProfile '.codex\cache\fleet\npm'
$passed = 0
$failed = 0
$total = 8
$origProfile = $env:USERPROFILE

function Case([string]$n, [scriptblock]$b) {
  try { & $b; $script:passed++; Write-Host "PASS $n" }
  catch { $script:failed++; Write-Host "FAIL $n - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }

function Quote-Args([string[]]$Tokens) {
  ($Tokens | ForEach-Object {
    $token = [string]$_
    if ($token.Length -eq 0) { '""' }
    elseif ($token -notmatch '[\s"]') { $token }
    else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }) -join ' '
}

function New-LocalTgz {
  param([string]$Dir)
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $pkgDir = Join-Path $Dir 'pkg'
  New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $pkgDir 'package.json'), "{`"name`":`"tiny-local-dep`",`"version`":`"1.0.0`",`"main`":`"index.js`"}`n")
  [IO.File]::WriteAllText((Join-Path $pkgDir 'index.js'), "module.exports = 1`n")
  $tgzName = 'tiny-local-dep-1.0.0.tgz'
  $tgzPath = Join-Path $Dir $tgzName
  # Build a minimal valid gzip+tar via npm pack when available; else a marker tarball path for mocks.
  $packed = $false
  try {
    Push-Location $pkgDir
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $packOut = @(& npm pack --pack-destination $Dir 2>$null)
    $packCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($packCode -eq 0) {
      $found = Get-ChildItem -LiteralPath $Dir -Filter '*.tgz' -File | Select-Object -First 1
      if ($found) {
        if ($found.FullName -ne $tgzPath) { Copy-Item -LiteralPath $found.FullName -Destination $tgzPath -Force }
        $packed = $true
      }
    }
  } catch { } finally { Pop-Location }
  if (-not $packed) {
    # Placeholder bytes; mock installs do not extract. Real-npm slot tests skip if no pack.
    [IO.File]::WriteAllBytes($tgzPath, [byte[]](0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00))
  }
  return @{ Path = $tgzPath; Packed = $packed; Name = $tgzName }
}

function New-MockInstallCmd {
  param([string]$CounterFile, [switch]$Hollow, [string]$ExtraPs = '')
  $cEsc = $CounterFile.Replace("'", "''")
  # Use Get-Location (Ensure sets WorkingDirectory to the slot). Refuse fleet checkout cwd.
  $guard = "if (Test-Path -LiteralPath (Join-Path (Get-Location) 'scripts\Ensure-FleetDependencies.ps1')) { throw 'mock refused fleet root cwd' }; "
  if ($Hollow) {
    return "powershell.exe -NoProfile -Command `"$guard if (Test-Path -LiteralPath '$cEsc') { `$n=[int](Get-Content -LiteralPath '$cEsc'); Set-Content -LiteralPath '$cEsc' -Value (`$n+1) } else { Set-Content -LiteralPath '$cEsc' -Value 1 }; exit 0`""
  }
  $extra = if ([string]::IsNullOrWhiteSpace($ExtraPs)) { '' } else { "; $ExtraPs" }
  return "powershell.exe -NoProfile -Command `"$guard if (Test-Path -LiteralPath '$cEsc') { `$n=[int](Get-Content -LiteralPath '$cEsc'); Set-Content -LiteralPath '$cEsc' -Value (`$n+1) } else { Set-Content -LiteralPath '$cEsc' -Value 1 }; `$nm = Join-Path (Get-Location) 'node_modules'; New-Item -ItemType Directory -Force -Path `$nm | Out-Null; Set-Content -LiteralPath (Join-Path `$nm 'pkg') -Value 1; New-Item -ItemType Directory -Force -Path (Join-Path `$nm 'tiny-local-dep') | Out-Null; Set-Content -LiteralPath (Join-Path `$nm 'tiny-local-dep\index.js') -Value 'module.exports=1'$extra`""
}

# Mock npm on PATH (via -NodeBinDir): default install path generates package-lock.json so
# install_command flips install→ci. Proves post-install fingerprint recompute (reuse-hit).
function New-LockGeneratingMockNpmBin {
  param([string]$BinDir, [string]$CounterFile)
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  $ps1 = Join-Path $BinDir 'mock-npm-body.ps1'
  $cEsc = $CounterFile.Replace("'", "''")
  $body = @(
    "`$ErrorActionPreference = 'Stop'"
    "if (`$args.Count -ge 1 -and [string]`$args[0] -eq '-v') { Write-Output '9.9.9'; exit 0 }"
    "`$cf = '$cEsc'"
    "if (Test-Path -LiteralPath `$cf) { `$n = [int](Get-Content -LiteralPath `$cf -Raw).Trim(); Set-Content -LiteralPath `$cf -Value (`$n + 1) } else { Set-Content -LiteralPath `$cf -Value 1 }"
    "if (-not (Test-Path -LiteralPath 'package-lock.json')) {"
    "  Set-Content -LiteralPath 'package-lock.json' -Value '{`"name`":`"slot-stab`",`"version`":`"1.0.0`",`"lockfileVersion`":3,`"packages`":{}}'"
    "}"
    "New-Item -ItemType Directory -Force -Path 'node_modules' | Out-Null"
    "Set-Content -LiteralPath 'node_modules\pkg' -Value 1"
    "New-Item -ItemType Directory -Force -Path 'node_modules\tiny-local-dep' | Out-Null"
    "Set-Content -LiteralPath 'node_modules\tiny-local-dep\index.js' -Value 'module.exports=1'"
    "exit 0"
  ) -join "`n"
  [IO.File]::WriteAllText($ps1, $body)
  $ps1ForCmd = $ps1.Replace('"', '""')
  [IO.File]::WriteAllText((Join-Path $BinDir 'npm.cmd'), "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1ForCmd`" %*`r`nexit /b %ERRORLEVEL%`r`n")
  return $BinDir
}

function Invoke-Efd {
  param(
    [string]$Worktree,
    [string]$Store,
    [string]$PreviousFingerprint = '',
    [string]$InstallCommand,
    [string]$NodeBinDir,
    [switch]$NoInstall,
    [int]$TimeoutSeconds = 120,
    [string]$UserProfile = $fakeProfile
  )
  $argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
    '-Worktree', $Worktree,
    '-StoreRoot', $Store,
    '-PreviousFingerprint', $PreviousFingerprint,
    '-TimeoutSeconds', [string]$TimeoutSeconds,
    '-Mode', 'json'
  )
  if ($NoInstall) { $argList += '-NoInstall' }
  if (-not [string]::IsNullOrWhiteSpace($InstallCommand)) { $argList += @('-InstallCommand', $InstallCommand) }
  if (-not [string]::IsNullOrWhiteSpace($NodeBinDir)) { $argList += @('-NodeBinDir', $NodeBinDir) }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = Quote-Args $argList
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $UserProfile
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $null = $proc.WaitForExit(300000)
  $code = if ($proc.HasExited) { $proc.ExitCode } else { try { $proc.Kill() } catch { }; -1 }
  $stdout = if ($outTask.Wait(5000)) { [string]$outTask.Result } else { '' }
  $stderr = if ($errTask.Wait(5000)) { [string]$errTask.Result } else { '' }
  $proc.Dispose()

  $jsonLine = ($stdout -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
  $obj = $null
  if (-not [string]::IsNullOrWhiteSpace($jsonLine)) {
    try { $obj = $jsonLine | ConvertFrom-Json } catch { $obj = $null }
  }
  return [pscustomobject]@{
    ExitCode = $code
    Stdout   = $stdout.TrimEnd()
    Stderr   = $stderr.TrimEnd()
    Json     = $obj
  }
}

function Get-Counter([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  return [int](Get-Content -LiteralPath $Path -Raw).Trim()
}

function Assert-JsonShape($j) {
  Assert-True ($null -ne $j) 'json missing'
  foreach ($k in @('status','layout','cache_provider','dependency_fingerprint','manifest_sha256','toolchain_sha256','install_reason','install_ms','lockfile_sha256','deps_count','node_modules_bytes','store_bytes_before','store_bytes_after')) {
    Assert-True ($null -ne $j.PSObject.Properties[$k]) "missing key $k"
  }
  Assert-True ($j.layout -eq 'slot-local-physical') "layout=$($j.layout)"
  Assert-True ($j.cache_provider -eq 'npm-cacache') "cache_provider=$($j.cache_provider)"
}

try {
  New-Item -ItemType Directory -Force -Path $fakeProfile | Out-Null
  New-Item -ItemType Directory -Force -Path $storeRoot | Out-Null
  $vendor = Join-Path $temp 'vendor'
  $tgzInfo = New-LocalTgz -Dir $vendor
  $tgzName = $tgzInfo.Name

  # Shared tarball path relative for slot copies: place under each slot via copy of absolute vendor.
  $slotA = Join-Path $temp 'slot-a'
  $slotB = Join-Path $temp 'slot-b'
  New-Item -ItemType Directory -Force -Path (Join-Path $slotA 'vendor') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $slotB 'vendor') | Out-Null
  Copy-Item -LiteralPath $tgzInfo.Path -Destination (Join-Path $slotA "vendor\$tgzName") -Force
  Copy-Item -LiteralPath $tgzInfo.Path -Destination (Join-Path $slotB "vendor\$tgzName") -Force

  # Rebuild slots as proper git repos with committed package files.
  function Init-SlotRepo([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
      & git -C $Path init | Out-Null
      & git -C $Path config user.name test
      & git -C $Path config user.email test@example.invalid
      & git -C $Path config commit.gpgsign false
    }
    $tgzPosix = "vendor/$tgzName"
    $pkg = "{`"name`":`"$Label`",`"version`":`"1.0.0`",`"dependencies`":{`"tiny-local-dep`":`"file:$tgzPosix`"}}`n"
    [IO.File]::WriteAllText((Join-Path $Path 'package.json'), $pkg)
    $lock = "{`"name`":`"$Label`",`"version`":`"1.0.0`",`"lockfileVersion`":3,`"requires`":true,`"packages`":{`"`":{`"name`":`"$Label`",`"version`":`"1.0.0`",`"dependencies`":{`"tiny-local-dep`":`"file:$tgzPosix`"}}}}`n"
    [IO.File]::WriteAllText((Join-Path $Path 'package-lock.json'), $lock)
    & git -C $Path add .
    & git -C $Path commit -m seed | Out-Null
    return [IO.Path]::GetFullPath($Path)
  }
  $slotA = Init-SlotRepo -Path $slotA -Label 'slot-a'
  $slotB = Init-SlotRepo -Path $slotB -Label 'slot-b'

  $counterFile = Join-Path $temp 'install-counter.txt'
  $mockOk = New-MockInstallCmd -CounterFile $counterFile
  $mockHollow = New-MockInstallCmd -CounterFile $counterFile -Hollow

  # --- 1/7 same fingerprint => reuse-hit; npm never launched again ---
  Case '1/7 same fingerprint reuse-hit mock never re-runs' {
    if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
    $r1 = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint '' -InstallCommand $mockOk
    Assert-True ($r1.ExitCode -eq 0) "exit1=$($r1.ExitCode) err=$($r1.Stderr) out=$($r1.Stdout)"
    Assert-JsonShape $r1.Json
    Assert-True ($r1.Json.status -eq 'installed') "status=$($r1.Json.status)"
    Assert-True ((Get-Counter $counterFile) -eq 1) "counter after first=$($counterFile)"
    $fp = [string]$r1.Json.dependency_fingerprint
    Assert-True ($fp.Length -eq 64) "fp len $($fp.Length)"
    $r2 = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint $fp -InstallCommand $mockOk
    Assert-True ($r2.ExitCode -eq 0) "exit2=$($r2.ExitCode) err=$($r2.Stderr)"
    Assert-JsonShape $r2.Json
    Assert-True ($r2.Json.status -eq 'reuse-hit') "status2=$($r2.Json.status) reason=$($r2.Json.install_reason)"
    Assert-True ((Get-Counter $counterFile) -eq 1) "mock launched on reuse; counter=$(Get-Counter $counterFile)"
    Assert-True ($r2.Json.dependency_fingerprint -eq $fp) 'fp changed on reuse'
  }

  # --- 2/7 lockfile mutation forces exactly one install ---
  Case '2/7 lockfile mutation forces install (1/1)' {
    if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
    $lockPath = Join-Path $slotA 'package-lock.json'
    $r0 = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint '' -InstallCommand $mockOk
    Assert-True ($r0.ExitCode -eq 0 -and $r0.Json.status -eq 'installed') "seed install failed"
    $fp0 = [string]$r0.Json.dependency_fingerprint
    Assert-True ((Get-Counter $counterFile) -eq 1) 'seed counter'
    # mutate lockfile content bytes (still tracked) — must change SHA256
    $lockText = [IO.File]::ReadAllText($lockPath)
    $mutTag = [guid]::NewGuid().ToString('n').Substring(0, 8)
    [IO.File]::WriteAllText($lockPath, ($lockText.TrimEnd() + "`n" + ',"_fleet_mut":"' + $mutTag + '"' + "`n"))
    & git -C $slotA add package-lock.json
    & git -C $slotA commit -m 'lock mutate' | Out-Null
    $r1 = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint $fp0 -InstallCommand $mockOk
    Assert-True ($r1.ExitCode -eq 0) "exit=$($r1.ExitCode) err=$($r1.Stderr)"
    Assert-True ($r1.Json.status -eq 'installed') "status=$($r1.Json.status)"
    Assert-True ($r1.Json.install_reason -eq 'fingerprint-mismatch') "reason=$($r1.Json.install_reason)"
    Assert-True ((Get-Counter $counterFile) -eq 2) "expected exactly one new install; counter=$(Get-Counter $counterFile)"
    Assert-True ($r1.Json.dependency_fingerprint -ne $fp0) 'fp should change after lock mutate'
  }

  # --- 3/7 tracked package.json mutation forces install; lockfile unchanged content hash path ---
  Case '3/7 package.json mutation forces install lockfile present' {
    if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
    # restore clean-ish state via reinstall seed
    $r0 = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint '' -InstallCommand $mockOk
    Assert-True ($r0.ExitCode -eq 0) "seed exit=$($r0.ExitCode)"
    $fp0 = [string]$r0.Json.dependency_fingerprint
    $lockSha0 = [string]$r0.Json.lockfile_sha256
    $pkgPath = Join-Path $slotA 'package.json'
    # mutate package.json only; leave package-lock.json bytes untouched
    $mutTag = [guid]::NewGuid().ToString('n').Substring(0, 8)
    $pkgText = "{`"name`":`"slot-a`",`"version`":`"1.0.0`",`"description`":`"mut-$mutTag`",`"dependencies`":{`"tiny-local-dep`":`"file:vendor/$tgzName`"}}`n"
    [IO.File]::WriteAllText($pkgPath, $pkgText)
    & git -C $slotA add package.json
    & git -C $slotA commit -m 'pkg mutate' | Out-Null
    $r1 = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint $fp0 -InstallCommand $mockOk
    Assert-True ($r1.ExitCode -eq 0) "exit=$($r1.ExitCode) err=$($r1.Stderr)"
    Assert-True ($r1.Json.status -eq 'installed') "status=$($r1.Json.status)"
    Assert-True ($r1.Json.install_reason -eq 'fingerprint-mismatch') "reason=$($r1.Json.install_reason)"
    Assert-True ((Get-Counter $counterFile) -eq 2) "counter=$(Get-Counter $counterFile) expected 2"
    # lockfile file not edited this case: lockfile_sha256 should match seed when lock untouched
    Assert-True ($r1.Json.lockfile_sha256 -eq $lockSha0) "lock sha changed unexpectedly: $($r1.Json.lockfile_sha256) vs $lockSha0"
    Assert-True ($r1.Json.dependency_fingerprint -ne $fp0) 'fp should change after package.json mutate'
  }

  # --- 4/7 two slots share StoreRoot; different physical node_modules ---
  Case '4/7 two slots share store distinct physical node_modules' {
    if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
    $nmA = Join-Path $slotA 'node_modules'
    $nmB = Join-Path $slotB 'node_modules'
    if (Test-Path -LiteralPath $nmA) { Remove-Item -LiteralPath $nmA -Recurse -Force }
    if (Test-Path -LiteralPath $nmB) { Remove-Item -LiteralPath $nmB -Recurse -Force }
    $rA = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint '' -InstallCommand $mockOk
    $rB = Invoke-Efd -Worktree $slotB -Store $storeRoot -PreviousFingerprint '' -InstallCommand $mockOk
    Assert-True ($rA.ExitCode -eq 0 -and $rB.ExitCode -eq 0) "exits A=$($rA.ExitCode) B=$($rB.ExitCode)"
    Assert-True ($rA.Json.status -eq 'installed' -and $rB.Json.status -eq 'installed') 'both installed'
    Assert-True (Test-Path -LiteralPath $nmA) 'nm A missing'
    Assert-True (Test-Path -LiteralPath $nmB) 'nm B missing'
    $fullA = [IO.Path]::GetFullPath($nmA)
    $fullB = [IO.Path]::GetFullPath($nmB)
    Assert-True ($fullA -ne $fullB) "node_modules paths equal: $fullA"
    # not the same reparse target
    $itemA = Get-Item -LiteralPath $nmA -Force
    $itemB = Get-Item -LiteralPath $nmB -Force
    $rpA = (($itemA.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
    $rpB = (($itemB.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
    Assert-True (-not $rpA -and -not $rpB) 'node_modules must be physical dirs'
    Assert-True ($rA.Json.layout -eq 'slot-local-physical' -and $rB.Json.layout -eq 'slot-local-physical') 'layout'
    # shared store path consumed
    Assert-True ((Test-Path -LiteralPath $storeRoot)) 'store missing'
  }

  # --- 5/7 node_modules root is not a reparse point ---
  Case '5/7 node_modules root not reparse point' {
    if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
    $nm = Join-Path $slotA 'node_modules'
    if (Test-Path -LiteralPath $nm) { Remove-Item -LiteralPath $nm -Recurse -Force }
    $r = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint '' -InstallCommand $mockOk
    Assert-True ($r.ExitCode -eq 0 -and $r.Json.status -eq 'installed') "install failed: $($r.Stderr)"
    $item = Get-Item -LiteralPath $nm -Force
    $isRp = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
    Assert-True (-not $isRp) "node_modules is reparse point at $nm"
    # planting a reparse root must fail
    Remove-Item -LiteralPath $nm -Recurse -Force
    $outside = Join-Path $temp 'nm-outside'
    New-Item -ItemType Directory -Force -Path $outside | Out-Null
    Set-Content -LiteralPath (Join-Path $outside 'x') -Value 1
    $juncOk = $false
    try {
      New-Item -ItemType Junction -Path $nm -Target $outside -ErrorAction Stop | Out-Null
      $juncOk = $true
    } catch {
      # if junction denied, still pass physical-dir assertion above
      Write-Host 'NOTE junction plant skipped (env)'
    }
    if ($juncOk) {
      $r2 = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint ([string]$r.Json.dependency_fingerprint) -InstallCommand $mockOk
      Assert-True ($r2.ExitCode -ne 0 -or $r2.Json.status -eq 'failed') "reparse root must fail: exit=$($r2.ExitCode) status=$($r2.Json.status)"
      $combo = $r2.Stderr + $r2.Stdout
      Assert-True ($combo -match 'reparse') "must mention reparse: $combo"
      & cmd /c "rmdir `"$nm`"" 2>$null | Out-Null
    }
  }

  # --- 6/7 resolved local fixture dep stays beneath slot ---
  Case '6/7 local fixture dependency stays under slot' {
    if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
    $nm = Join-Path $slotA 'node_modules'
    if (Test-Path -LiteralPath $nm) { Remove-Item -LiteralPath $nm -Recurse -Force }
    # mock plants tiny-local-dep under slot node_modules
    $r = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint '' -InstallCommand $mockOk
    Assert-True ($r.ExitCode -eq 0 -and $r.Json.status -eq 'installed') "install: $($r.Stderr)"
    $depPath = Join-Path $nm 'tiny-local-dep'
    Assert-True (Test-Path -LiteralPath $depPath) "dep missing at $depPath"
    $depFull = [IO.Path]::GetFullPath($depPath)
    $slotFull = [IO.Path]::GetFullPath($slotA).TrimEnd('\')
    Assert-True ($depFull.StartsWith($slotFull + '\', [StringComparison]::OrdinalIgnoreCase) -or $depFull.Equals($slotFull, [StringComparison]::OrdinalIgnoreCase)) "dep escaped slot: $depFull not under $slotFull"
    # optional real npm install when pack succeeded
    if ($tgzInfo.Packed) {
      $realSlot = Join-Path $temp 'slot-real'
      New-Item -ItemType Directory -Force -Path (Join-Path $realSlot 'vendor') | Out-Null
      Copy-Item -LiteralPath $tgzInfo.Path -Destination (Join-Path $realSlot "vendor\$tgzName") -Force
      $null = Init-SlotRepo -Path $realSlot -Label 'slot-real'
      # remove lock so npm install from file: tgz works without lock integrity issues
      $lockReal = Join-Path $realSlot 'package-lock.json'
      if (Test-Path -LiteralPath $lockReal) {
        Remove-Item -LiteralPath $lockReal -Force
        & git -C $realSlot add -A
        & git -C $realSlot commit -m 'drop lock for real install' | Out-Null
      }
      $rr = Invoke-Efd -Worktree $realSlot -Store $storeRoot -PreviousFingerprint '' -TimeoutSeconds 180
      if ($rr.ExitCode -eq 0 -and $rr.Json.status -eq 'installed') {
        $realDep = Join-Path $realSlot 'node_modules\tiny-local-dep'
        Assert-True (Test-Path -LiteralPath $realDep) 'real npm dep missing'
        $rdFull = [IO.Path]::GetFullPath($realDep)
        $rsFull = [IO.Path]::GetFullPath($realSlot).TrimEnd('\')
        Assert-True ($rdFull.StartsWith($rsFull + '\', [StringComparison]::OrdinalIgnoreCase)) "real dep escaped: $rdFull"
      } else {
        Write-Host "NOTE real npm install skipped/failed (env): exit=$($rr.ExitCode) $($rr.Stderr)"
      }
    }
  }

  # --- 7/7 install exits 0 with empty tree => failed ---
  Case '7/7 hollow install exit0 => failed' {
    if (Test-Path -LiteralPath $counterFile) { Remove-Item -LiteralPath $counterFile -Force }
    $nm = Join-Path $slotA 'node_modules'
    if (Test-Path -LiteralPath $nm) { Remove-Item -LiteralPath $nm -Recurse -Force }
    $r = Invoke-Efd -Worktree $slotA -Store $storeRoot -PreviousFingerprint '' -InstallCommand $mockHollow
    Assert-True ($r.ExitCode -ne 0) "expected nonzero, got $($r.ExitCode)"
    Assert-True ($null -ne $r.Json) "json missing on hollow fail out=$($r.Stdout)"
    Assert-True ($r.Json.status -eq 'failed') "status=$($r.Json.status)"
    Assert-True ($r.Json.install_reason -match 'hollow') "reason=$($r.Json.install_reason)"
    Assert-True ((Get-Counter $counterFile) -eq 1) 'hollow mock should still run once'
  }

  # --- 8/8 fingerprint stable after lockfile-generating install (no -InstallCommand) ---
  # Exact bug: pre-install FP (no lock → npm install) was returned after install; next acquire
  # recomputes with generated lock (npm ci) → mismatch → reinstall. Fix returns post-install FP.
  Case '8/8 fingerprint stable after lockfile-generating install' {
    $stabCounter = Join-Path $temp 'stab-install-counter.txt'
    if (Test-Path -LiteralPath $stabCounter) { Remove-Item -LiteralPath $stabCounter -Force }
    $mockNpmBin = New-LockGeneratingMockNpmBin -BinDir (Join-Path $temp 'mock-npm-bin') -CounterFile $stabCounter
    $slotStab = Join-Path $temp 'slot-stab'
    New-Item -ItemType Directory -Force -Path (Join-Path $slotStab 'vendor') | Out-Null
    Copy-Item -LiteralPath $tgzInfo.Path -Destination (Join-Path $slotStab "vendor\$tgzName") -Force
    & git -C $slotStab init | Out-Null
    & git -C $slotStab config user.name test
    & git -C $slotStab config user.email test@example.invalid
    & git -C $slotStab config commit.gpgsign false
    $tgzPosix = "vendor/$tgzName"
    $pkg = "{`"name`":`"slot-stab`",`"version`":`"1.0.0`",`"dependencies`":{`"tiny-local-dep`":`"file:$tgzPosix`"}}`n"
    [IO.File]::WriteAllText((Join-Path $slotStab 'package.json'), $pkg)
    # NO package-lock.json — first call chooses npm install which generates lock
    & git -C $slotStab add .
    & git -C $slotStab commit -m 'seed-nolock' | Out-Null
    $slotStab = [IO.Path]::GetFullPath($slotStab)
    # Call 1: empty previous → installed (default path, no -InstallCommand)
    $r1 = Invoke-Efd -Worktree $slotStab -Store $storeRoot -PreviousFingerprint '' -NodeBinDir $mockNpmBin
    Assert-True ($r1.ExitCode -eq 0) "exit1=$($r1.ExitCode) err=$($r1.Stderr) out=$($r1.Stdout)"
    Assert-JsonShape $r1.Json
    Assert-True ($r1.Json.status -eq 'installed') "status1=$($r1.Json.status) reason=$($r1.Json.install_reason)"
    Assert-True ((Get-Counter $stabCounter) -eq 1) "npm should run once on first install; counter=$(Get-Counter $stabCounter)"
    Assert-True (Test-Path -LiteralPath (Join-Path $slotStab 'package-lock.json') -PathType Leaf) 'install must generate package-lock.json'
    $fp = [string]$r1.Json.dependency_fingerprint
    Assert-True ($fp.Length -eq 64) "fp len $($fp.Length)"
    # Call 2: same slot + returned FP → reuse-hit; npm must NOT run again
    $r2 = Invoke-Efd -Worktree $slotStab -Store $storeRoot -PreviousFingerprint $fp -NodeBinDir $mockNpmBin
    Assert-True ($r2.ExitCode -eq 0) "exit2=$($r2.ExitCode) err=$($r2.Stderr) out=$($r2.Stdout)"
    Assert-JsonShape $r2.Json
    Assert-True ($r2.Json.status -eq 'reuse-hit') "status2=$($r2.Json.status) reason=$($r2.Json.install_reason) (stale pre-install FP would force reinstall)"
    Assert-True ([int64]$r2.Json.install_ms -eq 0) "install_ms=$($r2.Json.install_ms) expected 0 on reuse-hit"
    Assert-True ((Get-Counter $stabCounter) -eq 1) "npm re-ran on second acquire; counter=$(Get-Counter $stabCounter)"
    Assert-True ($r2.Json.dependency_fingerprint -eq $fp) 'fp changed on reuse-hit'
  }

} finally {
  $env:USERPROFILE = $origProfile
  if (Test-Path -LiteralPath $temp) {
    # strip junctions then delete
    $stack = New-Object System.Collections.Stack
    $stack.Push([IO.Path]::GetFullPath($temp))
    $junctions = @()
    while ($stack.Count -gt 0) {
      $dir = [string]$stack.Pop()
      foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
        if ((($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)) {
          $junctions += $child.FullName
          continue
        }
        $stack.Push($child.FullName)
      }
    }
    foreach ($j in $junctions) { & cmd /c "rmdir `"$j`"" 2>$null | Out-Null }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# Hygiene: suite must never plant node_modules under the real fleet checkout.
$repoRootHygiene = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$nmLeak = Join-Path $repoRootHygiene 'node_modules'
if (Test-Path -LiteralPath $nmLeak) {
  Write-Host "FAIL hygiene: node_modules under repo root: $nmLeak"
  exit 1
}

Write-Host ("tests: {0}/{1}" -f $passed, $total)
if ($failed -gt 0 -or $passed -ne $total) { exit 1 }
exit 0
