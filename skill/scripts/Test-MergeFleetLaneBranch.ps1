# Tests for Merge-FleetLaneBranch.ps1. Throwaway git repos under a temp dir.
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'Merge-FleetLaneBranch.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-merge-lane-' + [guid]::NewGuid().ToString('n'))
$passed = 0
$failed = 0
$skipped = 0

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

function Invoke-GitRepo {
  param([string]$Repo, [string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $raw = & git -C $Repo @GitArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  $lines = @()
  if ($null -ne $raw) { foreach ($i in @($raw)) { $lines += [string]$i } }
  return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function New-TestRepo([string]$Name) {
  $path = Join-Path $temp $Name
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  $null = Invoke-GitRepo $path @('init')
  $null = Invoke-GitRepo $path @('-c', 'user.email=test@example.invalid', '-c', 'user.name=test', 'commit', '--allow-empty', '-m', 'seed')
  # Prefer explicit config so later commits need no global identity.
  $null = & git -C $path -c user.email=test@example.invalid -c user.name=test config user.email test@example.invalid 2>&1
  $null = & git -C $path -c user.email=test@example.invalid -c user.name=test config user.name test 2>&1
  $null = & git -C $path config commit.gpgsign false 2>&1
  [IO.File]::WriteAllText((Join-Path $path 'README.md'), "base`n")
  $null = Invoke-GitRepo $path @('add', 'README.md')
  $null = Invoke-GitRepo $path @('-c', 'user.email=test@example.invalid', '-c', 'user.name=test', 'commit', '-m', 'baseline')
  return $path
}

function New-BranchWithFile {
  param([string]$Repo, [string]$Branch, [string]$RelPath, [string]$Content)
  $null = Invoke-GitRepo $Repo @('checkout', '-b', $Branch)
  $full = Join-Path $Repo $RelPath
  $dir = Split-Path -Parent $full
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  [IO.File]::WriteAllText($full, $Content)
  $null = Invoke-GitRepo $Repo @('add', $RelPath)
  $null = Invoke-GitRepo $Repo @('-c', 'user.email=test@example.invalid', '-c', 'user.name=test', 'commit', '-m', "add $RelPath")
  $null = Invoke-GitRepo $Repo @('checkout', '-')
}

function Invoke-Helper {
  param(
    [string]$Repo,
    [string]$Branch,
    [string]$Message,
    [string[]]$ExpectPath = @(),
    [switch]$NoCommit,
    [string]$Mode = 'text'
  )
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
    '-Repo', $Repo, '-Branch', $Branch, '-Mode', $Mode
  )
  if (-not [string]::IsNullOrWhiteSpace($Message)) { $args += @('-Message', $Message) }
  foreach ($ep in @($ExpectPath)) {
    if (-not [string]::IsNullOrWhiteSpace($ep)) { $args += @('-ExpectPath', $ep) }
  }
  if ($NoCommit) { $args += '-NoCommit' }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = Quote-Args $args
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $null = $proc.WaitForExit(120000)
  $code = if ($proc.HasExited) { $proc.ExitCode } else { try { $proc.Kill() } catch { }; -1 }
  return @{
    Code = $code
    Out = [string]$outTask.Result
    Err = [string]$errTask.Result
  }
}

function Test-MergeStateAbsent([string]$Repo) {
  foreach ($name in @('MERGE_HEAD', 'SQUASH_MSG')) {
    $r = Invoke-GitRepo $Repo @('rev-parse', '--git-path', $name)
    if ($r.Code -eq 0 -and $r.Lines.Count -gt 0) {
      $p = $r.Lines[0].Trim()
      if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Repo $p }
      if (Test-Path -LiteralPath $p) { return $false }
    }
  }
  return $true
}

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null

  Case 'happy path: branch with one new file merges, stages, commits, summary format' {
    $repo = New-TestRepo 'happy'
    New-BranchWithFile $repo 'lane-a' 'lane-a.txt' "from-a`n"
    $r = Invoke-Helper -Repo $repo -Branch 'lane-a' -Message 'merge lane-a'
    Assert-True ($r.Code -eq 0) "exit $($r.Code) err=$($r.Err) out=$($r.Out)"
    Assert-True (Test-Path -LiteralPath (Join-Path $repo 'lane-a.txt')) 'lane-a.txt missing after merge'
    $line = ($r.Out -split "`r?`n" | Where-Object { $_ -match '^merge:' } | Select-Object -First 1)
    Assert-True ($line -match '^merge: lane-a \| staged: 1 files \| committed: [0-9a-f]{7,} \| expected-paths: n/a$') "summary format: $line"
    $show = Invoke-GitRepo $repo @('show', '--name-only', '--pretty=format:', 'HEAD')
    Assert-True (($show.Lines -join ' ') -match 'lane-a\.txt') 'commit missing lane-a.txt'
  }

  Case 'dirty index refuses merge and does not land branch content (real incident)' {
    $repo = New-TestRepo 'dirty'
    New-BranchWithFile $repo 'lane-b' 'lane-b.txt' "from-b`n"
    [IO.File]::WriteAllText((Join-Path $repo 'staged-first.txt'), "staged`n")
    $null = Invoke-GitRepo $repo @('add', 'staged-first.txt')
    $r = Invoke-Helper -Repo $repo -Branch 'lane-b'
    Assert-True ($r.Code -eq 1) "expected exit 1, got $($r.Code) out=$($r.Out)"
    Assert-True ($r.Err -match 'staged-first\.txt') "err should name staged file: $($r.Err)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'lane-b.txt'))) 'lane-b content should not be in tree'
    $cat = Invoke-GitRepo $repo @('show', 'HEAD:lane-b.txt')
    Assert-True ($cat.Code -ne 0) 'lane-b.txt should not be in HEAD tree'
  }

  Case 'two sequential merges with commit between both land' {
    $repo = New-TestRepo 'seq'
    New-BranchWithFile $repo 'lane-x' 'x.txt' "x`n"
    New-BranchWithFile $repo 'lane-y' 'y.txt' "y`n"
    $r1 = Invoke-Helper -Repo $repo -Branch 'lane-x'
    Assert-True ($r1.Code -eq 0) "first merge failed: $($r1.Err)"
    $r2 = Invoke-Helper -Repo $repo -Branch 'lane-y'
    Assert-True ($r2.Code -eq 0) "second merge failed: $($r2.Err) out=$($r2.Out)"
    Assert-True (Test-Path -LiteralPath (Join-Path $repo 'x.txt')) 'x.txt missing'
    Assert-True (Test-Path -LiteralPath (Join-Path $repo 'y.txt')) 'y.txt missing'
    $hx = Invoke-GitRepo $repo @('show', 'HEAD:x.txt')
    $hy = Invoke-GitRepo $repo @('show', 'HEAD:y.txt')
    # x may be in parent of HEAD; check tree contains both via ls-tree or cat-file
    $ls = Invoke-GitRepo $repo @('ls-tree', '-r', '--name-only', 'HEAD')
    $names = $ls.Lines -join "`n"
    Assert-True ($names -match '(?m)^x\.txt$') "x.txt not in HEAD tree: $names"
    Assert-True ($names -match '(?m)^y\.txt$') "y.txt not in HEAD tree: $names"
  }

  Case 'missing branch exits 1' {
    $repo = New-TestRepo 'missing'
    $r = Invoke-Helper -Repo $repo -Branch 'no-such-branch'
    Assert-True ($r.Code -eq 1) "expected 1 got $($r.Code)"
    Assert-True ($r.Err -match 'does not exist|no-such-branch') "err: $($r.Err)"
  }

  Case 'branch with nothing new to merge exits 1' {
    $repo = New-TestRepo 'noop'
    $null = Invoke-GitRepo $repo @('branch', 'empty-lane')
    $r = Invoke-Helper -Repo $repo -Branch 'empty-lane'
    Assert-True ($r.Code -eq 1) "expected 1 got $($r.Code)"
    Assert-True ($r.Err -match 'Nothing to merge|no commits') "err: $($r.Err)"
  }

  Case 'conflicting change aborts; no merge in progress; tree usable' {
    $repo = New-TestRepo 'conflict'
    # shared file on main
    [IO.File]::WriteAllText((Join-Path $repo 'shared.txt'), "main-v1`n")
    $null = Invoke-GitRepo $repo @('add', 'shared.txt')
    $null = Invoke-GitRepo $repo @('-c', 'user.email=test@example.invalid', '-c', 'user.name=test', 'commit', '-m', 'shared base')
    $null = Invoke-GitRepo $repo @('checkout', '-b', 'lane-c')
    [IO.File]::WriteAllText((Join-Path $repo 'shared.txt'), "lane-v`n")
    $null = Invoke-GitRepo $repo @('add', 'shared.txt')
    $null = Invoke-GitRepo $repo @('-c', 'user.email=test@example.invalid', '-c', 'user.name=test', 'commit', '-m', 'lane change')
    $null = Invoke-GitRepo $repo @('checkout', '-')
    [IO.File]::WriteAllText((Join-Path $repo 'shared.txt'), "main-v2`n")
    $null = Invoke-GitRepo $repo @('add', 'shared.txt')
    $null = Invoke-GitRepo $repo @('-c', 'user.email=test@example.invalid', '-c', 'user.name=test', 'commit', '-m', 'main change')
    $r = Invoke-Helper -Repo $repo -Branch 'lane-c'
    Assert-True ($r.Code -eq 1) "expected conflict exit 1 got $($r.Code) err=$($r.Err)"
    Assert-True (Test-MergeStateAbsent $repo) 'MERGE_HEAD or SQUASH_MSG still present'
    $st = Invoke-GitRepo $repo @('status', '--porcelain')
    # working tree usable: can commit empty or write new file
    [IO.File]::WriteAllText((Join-Path $repo 'after.txt'), "ok`n")
    $null = Invoke-GitRepo $repo @('add', 'after.txt')
    $c = Invoke-GitRepo $repo @('-c', 'user.email=test@example.invalid', '-c', 'user.name=test', 'commit', '-m', 'still usable')
    Assert-True ($c.Code -eq 0) "repo not usable after abort: $($c.Text)"
  }

  Case 'ExpectPath missing from branch exits 1 naming path' {
    $repo = New-TestRepo 'expect'
    New-BranchWithFile $repo 'lane-e' 'e.txt' "e`n"
    $r = Invoke-Helper -Repo $repo -Branch 'lane-e' -ExpectPath @('never-touched.txt')
    Assert-True ($r.Code -eq 1) "expected 1 got $($r.Code)"
    Assert-True ($r.Err -match 'never-touched\.txt') "err should name path: $($r.Err)"
  }

  Case 'NoCommit stages without committing' {
    $repo = New-TestRepo 'nocommit'
    New-BranchWithFile $repo 'lane-n' 'n.txt' "n`n"
    $headBefore = (Invoke-GitRepo $repo @('rev-parse', 'HEAD')).Lines[0].Trim()
    $r = Invoke-Helper -Repo $repo -Branch 'lane-n' -NoCommit
    Assert-True ($r.Code -eq 0) "exit $($r.Code) err=$($r.Err)"
    $headAfter = (Invoke-GitRepo $repo @('rev-parse', 'HEAD')).Lines[0].Trim()
    Assert-True ($headBefore -eq $headAfter) "HEAD changed: $headBefore -> $headAfter"
    $staged = Invoke-GitRepo $repo @('diff', '--cached', '--name-only')
    Assert-True (($staged.Lines -join ' ') -match 'n\.txt') "staged empty: $($staged.Text)"
    Assert-True ($r.Out -match 'committed: none') "summary: $($r.Out)"
  }

  Case 'json mode parses same fields and exit 0' {
    $repo = New-TestRepo 'json'
    New-BranchWithFile $repo 'lane-j' 'j.txt' "j`n"
    $r = Invoke-Helper -Repo $repo -Branch 'lane-j' -Mode 'json' -ExpectPath @('j.txt')
    Assert-True ($r.Code -eq 0) "exit $($r.Code) err=$($r.Err) out=$($r.Out)"
    $obj = $r.Out.Trim() | ConvertFrom-Json
    Assert-True ($obj.merge -eq 'lane-j') "merge field: $($obj.merge)"
    Assert-True ([int]$obj.staged -ge 1) "staged: $($obj.staged)"
    Assert-True ($obj.committed -match '^[0-9a-f]{7,}$') "committed: $($obj.committed)"
    $ep = $obj.'expected-paths'
    if ($null -eq $ep) { $ep = $obj.expected_paths }
    Assert-True ($ep -eq 'ok') "expected-paths: $ep"
  }
}
finally {
  if (Test-Path -LiteralPath $temp) {
    try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
}

Write-Host ""
Write-Host "cases run: $($passed + $failed + $skipped) / passed: $passed / failed: $failed / skipped: $skipped"
if ($failed -gt 0 -or ($passed + $failed + $skipped) -eq 0) { exit 1 }
exit 0
