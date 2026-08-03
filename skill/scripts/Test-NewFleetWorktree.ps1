# Tests for New-FleetWorktree.ps1. Throwaway git repos under a temp dir;
# USERPROFILE redirected so real worktree store is never touched.
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'New-FleetWorktree.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-nfw-test-' + [guid]::NewGuid().ToString('n'))
$fakeProfile = Join-Path $temp 'profile'
$passed = 0
$failed = 0
$skipped = 0
$origProfile = $env:USERPROFILE
$createdRepos = @()
$createdWorktrees = @()  # @{ Repo=; Path= }

function Case([string]$n, [scriptblock]$b) {
  try { & $b; $script:passed++; Write-Host "PASS $n" }
  catch { $script:failed++; Write-Host "FAIL $n - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }
function Skip([string]$n, [string]$reason) { $script:skipped++; Write-Host "SKIP $n - $reason" }

function Quote-Args([string[]]$Tokens) {
  ($Tokens | ForEach-Object {
    $token = [string]$_
    if ($token.Length -eq 0) { '""' }
    elseif ($token -notmatch '[\s"]') { $token }
    else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }) -join ' '
}

function New-TestRepo([string]$Name) {
  $path = Join-Path $temp $Name
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  & git -C $path init | Out-Null
  & git -C $path config user.name test
  & git -C $path config user.email test@example.invalid
  & git -C $path config commit.gpgsign false
  [IO.File]::WriteAllText((Join-Path $path 'README.md'), 'seed')
  $pkgDir = Join-Path $path 'packages\backend'
  New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $pkgDir '.env'), 'SECRET=1')
  & git -C $path add .
  & git -C $path commit -m baseline | Out-Null
  $script:createdRepos += $path
  return $path
}

function New-JsTestRepo([string]$Name, [switch]$WithLock) {
  $path = New-TestRepo $Name
  [IO.File]::WriteAllText((Join-Path $path 'package.json'), '{"name":"t","version":"1.0.0"}')
  if ($WithLock) { [IO.File]::WriteAllText((Join-Path $path 'package-lock.json'), '{"lockfileVersion":3,"packages":{}}') }
  & git -C $path add .; & git -C $path commit -m 'add package.json' | Out-Null
  return $path
}

function New-FakeNpmBin([string]$Name) {
  $bin = Join-Path $temp $Name
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  $argsFile = Join-Path $bin 'last-args.txt'
  [IO.File]::WriteAllText((Join-Path $bin 'npm.cmd'), "@echo off`r`necho %*>`"$argsFile`"`r`nmkdir node_modules 2>nul`r`necho 1>node_modules\pkg`r`nexit /b 0")
  return $bin
}

function Invoke-Helper {
  param(
    [string]$Repo,
    [string]$RunId,
    [string]$BaseRef = 'HEAD',
    [string[]]$CopyFile = @(),
    [switch]$Install,
    [switch]$NoInstall,
    [string]$InstallCommand,
    [string]$NodeBinDir,
    [int]$InstallTimeoutSeconds = 60,
    [string]$Mode = 'text',
    [string]$UserProfile = $fakeProfile
  )
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
    '-Repo', $Repo, '-RunId', $RunId, '-BaseRef', $BaseRef,
    '-InstallTimeoutSeconds', [string]$InstallTimeoutSeconds, '-Mode', $Mode
  )
  foreach ($cf in @($CopyFile)) { $args += @('-CopyFile', $cf) }
  if ($Install) { $args += '-Install' }
  if ($NoInstall) { $args += '-NoInstall' }
  if (-not [string]::IsNullOrWhiteSpace($InstallCommand)) { $args += @('-InstallCommand', $InstallCommand) }
  if (-not [string]::IsNullOrWhiteSpace($NodeBinDir)) { $args += @('-NodeBinDir', $NodeBinDir) }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = Quote-Args $args
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

  $repoSlug = ([IO.Path]::GetFileName([IO.Path]::GetFullPath($Repo))).ToLowerInvariant()
  $expected = [IO.Path]::GetFullPath((Join-Path $UserProfile ".codex\worktrees\$repoSlug\$RunId"))
  if ((Test-Path -LiteralPath $expected) -and ($createdWorktrees | Where-Object { $_.Path -eq $expected }).Count -eq 0) {
    $script:createdWorktrees += @{ Repo = $Repo; Path = $expected }
  }

  return [pscustomobject]@{
    ExitCode = $code
    Stdout   = $stdout.TrimEnd()
    Stderr   = $stderr.TrimEnd()
    Path     = $expected
    Branch   = "fleet/$RunId"
  }
}

function Remove-JunctionsUnder([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root)) { return }
  $stack = New-Object System.Collections.Stack
  $stack.Push([IO.Path]::GetFullPath($Root))
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
  foreach ($j in $junctions) {
    & cmd /c "rmdir `"$j`"" 2>$null | Out-Null
  }
}

try {
  New-Item -ItemType Directory -Force -Path $fakeProfile | Out-Null
  $repo = New-TestRepo 'sample-repo'
  $jsLock = New-JsTestRepo 'js-lock-repo' -WithLock
  $jsNoLock = New-JsTestRepo 'js-nolock-repo'
  $fakeNpm = New-FakeNpmBin 'fake-npm-bin'
  $installOkCmd = 'powershell.exe -NoProfile -Command "New-Item -ItemType Directory -Force -Path node_modules | Out-Null; Set-Content -LiteralPath node_modules\pkg -Value 1"'
  $installHollowCmd = 'powershell.exe -NoProfile -Command "exit 0"'

  Case 'happy path no package.json skips install' {
    $r = Invoke-Helper -Repo $repo -RunId 'happy1'
    Assert-True ($r.ExitCode -eq 0) "exit $($r.ExitCode) stderr=$($r.Stderr) stdout=$($r.Stdout)"
    Assert-True (Test-Path -LiteralPath $r.Path) "worktree missing at $($r.Path)"
    $br = & git -C $repo branch --list 'fleet/happy1'
    Assert-True ($br -match 'fleet/happy1') "branch not created: $br"
    $line = ($r.Stdout -split "`r?`n" | Where-Object { $_ -match '^worktree:' } | Select-Object -Last 1)
    Assert-True ($line -match '^worktree: .+ \| branch: fleet/happy1 \| copied: 0 \| install: skipped\(no package\.json\) \| deps: 0 entries$') "summary mismatch: $line"
  }

  Case 'CopyFile copies relative path' {
    $r = Invoke-Helper -Repo $repo -RunId 'copy1' -CopyFile @('packages\backend\.env')
    Assert-True ($r.ExitCode -eq 0) "exit $($r.ExitCode) stderr=$($r.Stderr)"
    $dst = Join-Path $r.Path 'packages\backend\.env'
    Assert-True (Test-Path -LiteralPath $dst) "copied file missing: $dst"
    Assert-True (([IO.File]::ReadAllText($dst)) -match 'SECRET=1') 'copied content mismatch'
    Assert-True ($r.Stdout -match 'copied: 1') "expected copied: 1 in $($r.Stdout)"
  }

  Case 'missing CopyFile source exits 1' {
    $r = Invoke-Helper -Repo $repo -RunId 'copymiss' -CopyFile @('packages\backend\no-such.env')
    Assert-True ($r.ExitCode -eq 1) "expected exit 1, got $($r.ExitCode)"
    Assert-True ($r.Stderr -match 'CopyFile source missing') "stderr should name missing CopyFile: $($r.Stderr)"
  }

  Case 'existing branch name exits 1 with clear message' {
    & git -C $repo branch 'fleet/dupe-branch' HEAD | Out-Null
    $r = Invoke-Helper -Repo $repo -RunId 'dupe-branch'
    Assert-True ($r.ExitCode -eq 1) "expected exit 1, got $($r.ExitCode)"
    Assert-True ($r.Stderr -match 'Branch already exists' -and $r.Stderr -match 'fleet/dupe-branch') "clear message missing: $($r.Stderr)"
  }

  Case 'Documents-like path refused' {
    $docsProfile = Join-Path $temp 'Documents\user'
    New-Item -ItemType Directory -Force -Path $docsProfile | Out-Null
    $r = Invoke-Helper -Repo $repo -RunId 'docs1' -UserProfile $docsProfile
    Assert-True ($r.ExitCode -eq 1) "expected exit 1, got $($r.ExitCode)"
    Assert-True ($r.Stderr -match 'Documents') "expected Documents refusal: $($r.Stderr)"
    Assert-True (-not (Test-Path -LiteralPath $r.Path)) "must not create under Documents: $($r.Path)"
  }

  Case 'no reparse ancestors creates worktree' {
    $cleanProfile = Join-Path $temp 'clean-profile'
    New-Item -ItemType Directory -Force -Path $cleanProfile | Out-Null
    $r = Invoke-Helper -Repo $repo -RunId 'clean1' -UserProfile $cleanProfile
    Assert-True ($r.ExitCode -eq 0) "exit $($r.ExitCode) stderr=$($r.Stderr) stdout=$($r.Stdout)"
    Assert-True (Test-Path -LiteralPath $r.Path) "worktree missing at $($r.Path)"
    $line = ($r.Stdout -split "`r?`n" | Where-Object { $_ -match '^worktree:' } | Select-Object -Last 1)
    Assert-True ($line -match '^worktree: .+ \| branch: fleet/clean1 \| copied: 0 \| install: skipped\(no package\.json\) \| deps: 0 entries$') "summary mismatch: $line"
  }

  Case 'ancestor junction outside canonical root refused' {
    $juncProfile = Join-Path $temp 'junc-out-profile'
    $escapeStore = Join-Path $temp 'escape-store'
    New-Item -ItemType Directory -Force -Path $juncProfile | Out-Null
    New-Item -ItemType Directory -Force -Path $escapeStore | Out-Null
    $codexLink = Join-Path $juncProfile '.codex'
    $jOk = $false
    try {
      New-Item -ItemType Junction -Path $codexLink -Target $escapeStore -ErrorAction Stop | Out-Null
      $jOk = $true
    } catch {
      Skip 'ancestor junction outside canonical root refused' 'junction creation not permitted in test environment'
    }
    if ($jOk) {
      $r = Invoke-Helper -Repo $repo -RunId 'anc-out' -UserProfile $juncProfile
      Assert-True ($r.ExitCode -eq 1) "expected exit 1, got $($r.ExitCode) out=$($r.Stdout) err=$($r.Stderr)"
      Assert-True ($r.Stderr -match 'ancestor reparse point' -or $r.Stderr -match 'reparse point') "must name reparse: $($r.Stderr)"
      Assert-True ($r.Stderr -match [regex]::Escape($codexLink) -or $r.Stderr -match '\.codex') "must name ancestor: $($r.Stderr)"
      Assert-True ($r.Stderr -match [regex]::Escape($escapeStore) -or $r.Stderr -match 'escape-store') "must name target: $($r.Stderr)"
      Assert-True (-not (Test-Path -LiteralPath $r.Path)) "must not create worktree: $($r.Path)"
      & cmd /c "rmdir `"$codexLink`"" 2>$null | Out-Null
    }
  }

  Case 'ancestor junction inside canonical root allowed' {
    $innerProfile = Join-Path $temp 'junc-in-profile'
    $canonical = Join-Path $innerProfile '.codex\worktrees'
    $realDir = Join-Path $canonical '_real'
    New-Item -ItemType Directory -Force -Path $realDir | Out-Null
    $repoSlug = ([IO.Path]::GetFileName([IO.Path]::GetFullPath($repo))).ToLowerInvariant()
    $slugLink = Join-Path $canonical $repoSlug
    $jOk = $false
    try {
      New-Item -ItemType Junction -Path $slugLink -Target $realDir -ErrorAction Stop | Out-Null
      $jOk = $true
    } catch {
      Skip 'ancestor junction inside canonical root allowed' 'junction creation not permitted in test environment'
    }
    if ($jOk) {
      $r = Invoke-Helper -Repo $repo -RunId 'anc-in' -UserProfile $innerProfile
      Assert-True ($r.ExitCode -eq 0) "exit $($r.ExitCode) stderr=$($r.Stderr) stdout=$($r.Stdout)"
      Assert-True (Test-Path -LiteralPath $r.Path) "worktree missing at $($r.Path)"
      $phys = Join-Path $realDir 'anc-in'
      Assert-True (Test-Path -LiteralPath $phys) "physical worktree missing at $phys"
      Assert-True ($r.Stdout -match 'branch: fleet/anc-in') "summary missing branch: $($r.Stdout)"
    }
  }

  Case 'junction guard fails closed and names path' {
    $outside = Join-Path $temp 'outside-target'
    New-Item -ItemType Directory -Force -Path $outside | Out-Null
    [IO.File]::WriteAllText((Join-Path $outside 'precious.txt'), 'DO NOT DELETE')
    $probeLink = Join-Path $temp 'junction-probe-link'
    $junctionOk = $false
    try {
      New-Item -ItemType Junction -Path $probeLink -Target $outside -ErrorAction Stop | Out-Null
      $junctionOk = $true
      & cmd /c "rmdir `"$probeLink`"" 2>$null | Out-Null
    } catch {
      Skip 'junction guard fails closed and names path' 'junction creation not permitted in test environment'
    }
    if ($junctionOk) {
      # Install plants node_modules (deps ok) + escaping junction; post-install scan must fail.
      $outsideEsc = $outside.Replace("'", "''")
      $installCmd = "powershell.exe -NoProfile -Command `"New-Item -ItemType Directory -Force -Path node_modules | Out-Null; Set-Content -LiteralPath node_modules\pkg -Value 1; New-Item -ItemType Junction -Path bad-junc -Target '$outsideEsc' | Out-Null`""
      $r = Invoke-Helper -Repo $jsLock -RunId 'junc1' -InstallCommand $installCmd
      Assert-True ($r.ExitCode -eq 1) "expected exit 1, got $($r.ExitCode) out=$($r.Stdout) err=$($r.Stderr)"
      $combined = $r.Stderr + "`n" + $r.Stdout
      Assert-True ($combined -match 'reparse point' -or $combined -match 'escapes' -or $combined -match 'bad-junc') "must name escaping path: $combined"
      Assert-True ($combined -match 'bad-junc' -or $combined -match [regex]::Escape($r.Path)) "must name the path: $combined"
      Assert-True (Test-Path -LiteralPath (Join-Path $outside 'precious.txt')) 'outside target must survive'
    }
  }

  Case 'auto install with lockfile uses npm ci' {
    $argsFile = Join-Path $fakeNpm 'last-args.txt'
    if (Test-Path -LiteralPath $argsFile) { Remove-Item -LiteralPath $argsFile -Force }
    $r = Invoke-Helper -Repo $jsLock -RunId 'auto-ci' -NodeBinDir $fakeNpm
    Assert-True ($r.ExitCode -eq 0 -and $r.Stdout -match 'install: ok') "exit $($r.ExitCode) out=$($r.Stdout) err=$($r.Stderr)"
    Assert-True ((Test-Path -LiteralPath $argsFile) -and ([IO.File]::ReadAllText($argsFile).Trim() -match '(^|\s)ci(\s|$)')) "expected npm ci form"
    Assert-True (Test-Path -LiteralPath (Join-Path $r.Path 'node_modules\pkg')) 'node_modules/pkg missing'
  }

  Case 'auto install without lockfile uses npm install' {
    $argsFile = Join-Path $fakeNpm 'last-args.txt'
    if (Test-Path -LiteralPath $argsFile) { Remove-Item -LiteralPath $argsFile -Force }
    $r = Invoke-Helper -Repo $jsNoLock -RunId 'auto-install' -NodeBinDir $fakeNpm
    Assert-True ($r.ExitCode -eq 0 -and $r.Stdout -match 'install: ok') "exit $($r.ExitCode) out=$($r.Stdout) err=$($r.Stderr)"
    Assert-True ((Test-Path -LiteralPath $argsFile) -and ([IO.File]::ReadAllText($argsFile).Trim() -match '(^|\s)install(\s|$)')) "expected npm install form"
  }

  Case '-NoInstall skips even with package.json' {
    $r = Invoke-Helper -Repo $jsLock -RunId 'noinst1' -NoInstall
    Assert-True ($r.ExitCode -eq 0 -and $r.Stdout -match 'install: skipped\(-NoInstall\)') "out=$($r.Stdout) err=$($r.Stderr)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $r.Path 'node_modules'))) 'node_modules must not exist under -NoInstall'
  }

  Case '-Install backward-compat materialises node_modules' {
    $r = Invoke-Helper -Repo $jsLock -RunId 'inst-ok' -Install -InstallCommand $installOkCmd
    Assert-True ($r.ExitCode -eq 0 -and $r.Stdout -match 'install: ok' -and $r.Stdout -match 'deps: [1-9]\d* entries') "out=$($r.Stdout) err=$($r.Stderr)"
    Assert-True (Test-Path -LiteralPath (Join-Path $r.Path 'node_modules\pkg')) 'node_modules/pkg missing'
  }

  Case 'exit 0 but empty node_modules fails' {
    $r = Invoke-Helper -Repo $jsLock -RunId 'inst-hollow' -InstallCommand $installHollowCmd
    Assert-True ($r.ExitCode -eq 1) "expected exit 1, got $($r.ExitCode)"
    $combo = $r.Stdout + $r.Stderr
    Assert-True ($combo -match 'install: failed' -or $combo -match 'node_modules is empty' -or $combo -match 'did not materialise') "hollow not failed closed: $combo"
  }

} finally {
  foreach ($wt in $createdWorktrees) {
    try {
      Remove-JunctionsUnder -Root $wt.Path
      $prev = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      & git -C $wt.Repo worktree remove --force -- $wt.Path 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $wt.Path)) {
        # Path may remain if remove failed; never recurse-delete through junctions (already stripped).
        Remove-Item -LiteralPath $wt.Path -Recurse -Force -ErrorAction SilentlyContinue
      }
      $ErrorActionPreference = $prev
    } catch { }
  }
  foreach ($r in $createdRepos) {
    try {
      $prev = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      & git -C $r worktree prune 2>$null | Out-Null
      # Delete leftover branch refs from tests (best effort).
      foreach ($b in @('fleet/happy1','fleet/copy1','fleet/dupe-branch','fleet/junc1','fleet/auto-ci','fleet/auto-install','fleet/noinst1','fleet/inst-ok','fleet/inst-hollow','fleet/clean1','fleet/anc-out','fleet/anc-in')) {
        & git -C $r branch -D $b 2>$null | Out-Null
      }
      $ErrorActionPreference = $prev
    } catch { }
  }
  $env:USERPROFILE = $origProfile
  if (Test-Path -LiteralPath $temp) {
    Remove-JunctionsUnder -Root $temp
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "DENOMINATOR: cases_run=$($passed + $failed + $skipped) passed=$passed failed=$failed skipped=$skipped"
if ($passed -eq 0 -and $failed -eq 0) { Write-Host 'FAIL suite collected 0 cases'; exit 1 }
if ($failed -gt 0) { exit 1 }
exit 0
