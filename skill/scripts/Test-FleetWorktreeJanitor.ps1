# Fixture-root tests for Invoke-FleetWorktreeJanitor. NEVER touch real %USERPROFILE%\.codex\worktrees.
$ErrorActionPreference = 'Stop'
$janitor = Join-Path $PSScriptRoot 'Invoke-FleetWorktreeJanitor.ps1'
$enter = Join-Path $PSScriptRoot 'Enter-FleetRunLease.ps1'
$exitLease = Join-Path $PSScriptRoot 'Exit-FleetRunLease.ps1'
$purge = Join-Path $PSScriptRoot 'purge_orphan_tree.py'
$utf8 = New-Object Text.UTF8Encoding $false
$passed = 0; $failed = 0
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('fleet-janitor-test-' + [guid]::NewGuid().ToString('n'))
$oldProfile = $env:USERPROFILE
$oldForce = $env:FLEET_JANITOR_FORCE_FAIL
$oldHarness = $env:FLEET_TEST_HARNESS
$sleepProcs = New-Object System.Collections.ArrayList

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Utf8([string]$Path, [string]$Text) {
  $p = Split-Path -Parent $Path
  if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Write-Sidecar([string]$TreePath, [string]$RunId, [string]$RepoPath = '', [datetimeoffset]$Created = [datetimeoffset]::UtcNow.AddHours(-100)) {
  $obj = [ordered]@{
    schema_version = '1'; run_id = $RunId; repo_path = $RepoPath
    git_common_dir = $(if ($RepoPath) { Join-Path $RepoPath '.git' } else { '' })
    created_utc = $Created.ToString('o'); ownership = 'run-owned'
  }
  Write-Utf8 (($TreePath.TrimEnd('\') + '.fleet-run.json')) ($obj | ConvertTo-Json -Compress)
}
function Age-Path([string]$Path, [int]$Hours = 100) {
  $t = [datetime]::UtcNow.AddHours(-$Hours)
  try { [IO.Directory]::SetLastWriteTimeUtc($Path, $t) } catch { }
  try { [IO.File]::SetLastWriteTimeUtc($Path, $t) } catch { }
  Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      if ($_.PSIsContainer) { [IO.Directory]::SetLastWriteTimeUtc($_.FullName, $t) }
      else { [IO.File]::SetLastWriteTimeUtc($_.FullName, $t) }
    } catch { }
  }
}
function Get-TreeHash([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root)) { return 'missing' }
  $sb = New-Object System.Text.StringBuilder
  Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue |
    Sort-Object FullName |
    ForEach-Object {
      $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
      [void]$sb.Append($rel).Append('|').Append([int]$_.Attributes).Append('|')
      if (-not $_.PSIsContainer) {
        try { [void]$sb.Append($_.Length).Append('|').Append((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash) } catch { [void]$sb.Append('?') }
      }
      [void]$sb.AppendLine()
    }
  return $sb.ToString()
}
function Invoke-Janitor([string]$Mode, [string]$WtRoot, [int]$MinAge = 72, [string]$ReportPath = '') {
  if ([string]::IsNullOrEmpty($ReportPath)) {
    $ReportPath = Join-Path $tempRoot ('report-' + [guid]::NewGuid().ToString('n') + '.json')
  }
  $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $janitor + '" -Mode ' + $Mode + ' -MinAgeHours ' + $MinAge + ' -WorktreeRoot "' + $WtRoot + '" -ReportPath "' + $ReportPath + '"'
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'; $psi.Arguments = $arg
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $env:USERPROFILE
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  $report = $null
  if (Test-Path -LiteralPath $ReportPath) {
    try { $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json } catch { }
  }
  return @{ Code = $p.ExitCode; Out = $out; Err = $err; Report = $report; ReportPath = $ReportPath }
}
function New-FixtureRepo {
  $repo = Join-Path $tempRoot ('repo-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $repo | Out-Null
  & git -C $repo init -q 2>$null | Out-Null
  & git -C $repo config user.email 'janitor-test@example.com' | Out-Null
  & git -C $repo config user.name 'Janitor Test' | Out-Null
  Write-Utf8 (Join-Path $repo 'README.md') 'fixture'
  & git -C $repo add README.md | Out-Null
  & git -C $repo commit -q -m 'init' | Out-Null
  return $repo
}
function New-RegisteredWorktree([string]$Repo, [string]$WtRoot, [string]$RunId) {
  $slug = (Split-Path -Leaf $Repo).ToLowerInvariant()
  $path = Join-Path $WtRoot ($slug + '\' + $RunId)
  $parent = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $branch = 'fleet/' + $RunId
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $null = & git -C $Repo worktree add -b $branch -- $path HEAD 2>&1
    Assert-True ($LASTEXITCODE -eq 0) ('worktree add failed for ' + $path)
  } finally { $ErrorActionPreference = $prev }
  Write-Sidecar -TreePath $path -RunId $RunId -RepoPath $Repo -Created ([datetimeoffset]::UtcNow.AddHours(-100))
  Age-Path $path 100
  return $path
}

try {
  $env:FLEET_TEST_HARNESS = '1'
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  $profile = Join-Path $tempRoot 'profile'
  New-Item -ItemType Directory -Force -Path (Join-Path $profile '.codex\fleet\run-leases') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $profile '.codex\worktrees') | Out-Null
  $env:USERPROFILE = $profile
  $wtRoot = Join-Path $profile '.codex\worktrees'
  $leaseRoot = Join-Path $profile '.codex\fleet\run-leases'

  # purge self-test first (junction canary baseline of the deleter itself)
  Case 'purge_orphan_tree self-test' {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & python $purge --self-test 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    Assert-True ($code -eq 0) ('purge self-test exit ' + $code + ': ' + $out)
  }

  Case 'Report mode mutates nothing and classifies mixed content' {
    $repo = New-FixtureRepo
    $aged = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'aged-20260801-report'
    $young = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'young-run-keep'
    # Force young age via sidecar created_utc (path already aged by helper; rewrite sidecar).
    Write-Sidecar -TreePath $young -RunId 'young-run-keep' -RepoPath $repo -Created ([datetimeoffset]::UtcNow.AddHours(-1))
    $amb = Join-Path $wtRoot 'slug-amb\random-notes'
    New-Item -ItemType Directory -Force -Path $amb | Out-Null
    Write-Utf8 (Join-Path $amb 'x.txt') 'x'
    $poolDir = Join-Path $wtRoot 'poolkey\slot-01'
    New-Item -ItemType Directory -Force -Path $poolDir | Out-Null
    Write-Utf8 (Join-Path $wtRoot 'poolkey\.fleet-pool\pool.json') '{"schema_version":"1"}'
    Write-Sidecar -TreePath $poolDir -RunId 'pool-slot-run' -Created ([datetimeoffset]::UtcNow.AddHours(-100))
    Age-Path $poolDir 100
    $before = Get-TreeHash $wtRoot
    $r = Invoke-Janitor -Mode Report -WtRoot $wtRoot -MinAge 72
    $after = Get-TreeHash $wtRoot
    Assert-True ($r.Code -eq 0) ('Report exit ' + $r.Code + ' err=' + $r.Err)
    Assert-True ($before -eq $after) 'Report mode mutated the tree'
    Assert-True ($null -ne $r.Report) 'missing report JSON'
    $rows = @($r.Report.candidates)
    Assert-True ($rows.Count -ge 3) ('expected >=3 candidates, got ' + $rows.Count)
    $agedRow = $rows | Where-Object { [string]$_.path -eq $aged } | Select-Object -First 1
    Assert-True ($null -ne $agedRow -and [string]$agedRow.action -eq 'would_quarantine') ('aged not would_quarantine: ' + ($agedRow | ConvertTo-Json -Compress))
    $youngRow = $rows | Where-Object { [string]$_.path -eq $young } | Select-Object -First 1
    Assert-True ($null -ne $youngRow -and [string]$youngRow.reason -eq 'too_young') ('young not too_young')
    $ambRow = $rows | Where-Object { [string]$_.path -eq $amb } | Select-Object -First 1
    # Bare no-git dirs now classify as orphan (quarantine pipeline); young => too_young skip.
    Assert-True ($null -ne $ambRow -and [string]$ambRow.action -eq 'skip' -and ([string]$ambRow.reason -in @('ownership_ambiguous', 'too_young'))) 'ambiguous not skipped'
    $poolRow = $rows | Where-Object { [string]$_.path -eq $poolDir } | Select-Object -First 1
    Assert-True ($null -ne $poolRow -and ([string]$poolRow.reason -eq 'pool_marker' -or [string]$poolRow.reason -eq 'ownership_ambiguous')) 'pool not skipped'
  }

  Case 'Apply quarantines aged git-registered worktree and prunes registration' {
    $repo = New-FixtureRepo
    $runId = 'apply-git-20260801'
    $path = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId $runId
    Assert-True (Test-Path -LiteralPath $path) 'registered fixture missing'
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True ($r.Code -eq 0) ('Apply exit ' + $r.Code + ' ' + $r.Err)
    Assert-True (-not (Test-Path -LiteralPath $path)) 'registered worktree still at original path'
    $row = @($r.Report.candidates) | Where-Object { [string]$_.run_id -eq $runId -and [string]$_.action -eq 'quarantined' } | Select-Object -First 1
    Assert-True ($null -ne $row) ('no quarantined row for ' + $runId)
    Assert-True ([string]$row.delete_via -eq 'quarantine_move+worktree_prune') ('delete_via=' + $row.delete_via)
    $qdirs = @(Get-ChildItem -LiteralPath (Join-Path $wtRoot '.fleet-quarantine') -Directory -Force | Where-Object { $_.Name -like ($runId + '-*') })
    Assert-True ($qdirs.Count -eq 1) 'quarantined content missing'
    $list = @(& git -C $repo worktree list --porcelain 2>$null) -join "`n"
    Assert-True ($list -notmatch [regex]::Escape($path)) 'git still lists quarantined worktree'
  }

  Case 'Apply skips unregistered orphan and forged sidecar' {
    # Candidate-controlled HEAD/sidecar cannot authorize an orphan purge.
    $orphan = Join-Path $wtRoot ('orphan-slug\fleet-orphan-20260801')
    New-Item -ItemType Directory -Force -Path $orphan | Out-Null
    & git -C $orphan init -q 2>$null | Out-Null
    & git -C $orphan config user.email 'janitor-test@example.com' | Out-Null
    & git -C $orphan config user.name 'Janitor Test' | Out-Null
    Write-Utf8 (Join-Path $orphan 'junk.txt') 'orphan-data'
    & git -C $orphan add junk.txt | Out-Null
    & git -C $orphan commit -q -m 'orphan' | Out-Null
    & git -C $orphan branch -M fleet/fleet-orphan-20260801 | Out-Null
    Write-Sidecar -TreePath $orphan -RunId 'fleet-orphan-20260801' -Created ([datetimeoffset]::UtcNow.AddHours(-100))
    Age-Path $orphan 100
    # Forged: valid-looking sidecar, no git corroboration, innocent dir.
    $forged = Join-Path $wtRoot ('forged-slug\innocent-dir')
    New-Item -ItemType Directory -Force -Path $forged | Out-Null
    Write-Utf8 (Join-Path $forged 'keep.txt') 'keep-me'
    Write-Sidecar -TreePath $forged -RunId 'forged-run-20260801' -RepoPath $tempRoot -Created ([datetimeoffset]::UtcNow.AddHours(-100))
    Age-Path $forged 100
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True ($r.Code -eq 0) ('orphan apply exit ' + $r.Code)
    Assert-True (Test-Path -LiteralPath $orphan) 'unregistered orphan was deleted'
    Assert-True (Test-Path -LiteralPath $forged) 'forged sidecar tree was deleted'
    $row = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $orphan -and [string]$_.reason -eq 'ownership_ambiguous' } | Select-Object -First 1
    Assert-True ($null -ne $row) 'unregistered orphan was not marked ownership_ambiguous'
    $frow = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $forged } | Select-Object -First 1
    Assert-True ($null -ne $frow -and [string]$frow.action -eq 'skip' -and [string]$frow.reason -eq 'ownership_ambiguous') ('forged not skipped: ' + ($frow | ConvertTo-Json -Compress))
  }

  Case 'Survival: live lease run dir intact' {
    $repo = New-FixtureRepo
    $runId = 'live-lease-20260801'
    $path = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId $runId
    $now = [datetimeoffset]::Now
    $lease = [ordered]@{
      schema_version = '2'; run_id = $runId; owner_pid = $PID
      started_at = $now.ToString('o'); heartbeat_at = $now.ToString('o')
      expires_at = $now.AddHours(20).ToString('o')
      receipt_hmac_key_id = ('b' * 32)
      receipt_hmac_key_b64 = [Convert]::ToBase64String((New-Object byte[] 32))
    }
    Write-Utf8 (Join-Path $leaseRoot ($runId + '.json')) ($lease | ConvertTo-Json -Compress)
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True (Test-Path -LiteralPath $path) 'live-lease tree was deleted'
    $row = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $path } | Select-Object -First 1
    Assert-True ($null -ne $row -and [string]$row.reason -eq 'live_lease') ('reason=' + $row.reason)
    Remove-Item -LiteralPath (Join-Path $leaseRoot ($runId + '.json')) -Force -ErrorAction SilentlyContinue
    # cleanup registered tree via git
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = & git -C $repo worktree remove --force -- $path 2>&1 } catch { } finally { $ErrorActionPreference = $prev }
  }

  Case 'Survival: younger than MinAgeHours intact' {
    $repo = New-FixtureRepo
    $young = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'fleet-young-keep'
    Write-Sidecar -TreePath $young -RunId 'fleet-young-keep' -RepoPath $repo -Created ([datetimeoffset]::UtcNow.AddHours(-1))
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True (Test-Path -LiteralPath $young) 'young tree deleted'
    $row = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $young } | Select-Object -First 1
    Assert-True ($null -ne $row -and [string]$row.reason -eq 'too_young') 'young not too_young'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = & git -C $repo worktree remove --force -- $young 2>&1 } catch { } finally { $ErrorActionPreference = $prev }
  }

  Case 'Survival: pool-marker ancestor intact' {
    $slot = Join-Path $wtRoot 'pk2\slot-02'
    New-Item -ItemType Directory -Force -Path $slot | Out-Null
    Write-Utf8 (Join-Path $slot 'keep.txt') 'pool'
    Write-Utf8 (Join-Path $wtRoot 'pk2\.fleet-pool\pool.json') '{"schema_version":"1"}'
    Write-Sidecar -TreePath $slot -RunId 'pool-keep' -Created ([datetimeoffset]::UtcNow.AddHours(-100))
    Age-Path $slot 100
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True (Test-Path -LiteralPath $slot) 'pool slot deleted'
    $row = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $slot } | Select-Object -First 1
    Assert-True ($null -ne $row -and ([string]$row.reason -match 'pool_marker|ownership_ambiguous')) 'pool not skipped'
  }

  Case 'Survival: ambiguous no-sidecar dir intact' {
    $amb = Join-Path $wtRoot 'amb2\just-a-folder'
    New-Item -ItemType Directory -Force -Path $amb | Out-Null
    Write-Utf8 (Join-Path $amb 'data.bin') 'zzz'
    Age-Path $amb 100
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True (Test-Path -LiteralPath $amb) 'ambiguous dir deleted'
    $row = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $amb } | Select-Object -First 1
    # 100h-old bare dir is an orphan below the 336h quarantine age: skipped, still on disk.
    Assert-True ($null -ne $row -and [string]$row.action -eq 'skip' -and ([string]$row.reason -in @('ownership_ambiguous', 'too_young'))) 'ambiguous not classified'
  }

  Case 'Legacy no-sidecar requires name pattern plus Git evidence' {
    $nameOnly = Join-Path $wtRoot 'legacy-name\fleet-name-only-20260801'
    New-Item -ItemType Directory -Force -Path $nameOnly | Out-Null
    Write-Utf8 (Join-Path $nameOnly 'keep.txt') 'keep'
    Age-Path $nameOnly 100
    $withGitEvidence = Join-Path $wtRoot 'legacy-git\fleet-evidence-20260801'
    New-Item -ItemType Directory -Force -Path $withGitEvidence | Out-Null
    & git -C $withGitEvidence init -q 2>$null | Out-Null
    & git -C $withGitEvidence config user.email 'janitor-test@example.com' | Out-Null
    & git -C $withGitEvidence config user.name 'Janitor Test' | Out-Null
    Write-Utf8 (Join-Path $withGitEvidence 'eligible.txt') 'eligible'
    & git -C $withGitEvidence add eligible.txt | Out-Null
    & git -C $withGitEvidence commit -q -m 'legacy evidence' | Out-Null
    & git -C $withGitEvidence branch -M fleet/legacy-evidence | Out-Null
    Age-Path $withGitEvidence 100
    $registeredWrongBranch = Join-Path $wtRoot 'legacy-registered\fleet-registered-wrong-20260801'
    New-Item -ItemType Directory -Force -Path $registeredWrongBranch | Out-Null
    & git -C $registeredWrongBranch init -q 2>$null | Out-Null
    & git -C $registeredWrongBranch config user.email 'janitor-test@example.com' | Out-Null
    & git -C $registeredWrongBranch config user.name 'Janitor Test' | Out-Null
    Write-Utf8 (Join-Path $registeredWrongBranch 'keep.txt') 'keep'
    & git -C $registeredWrongBranch add keep.txt | Out-Null
    & git -C $registeredWrongBranch commit -q -m 'wrong branch' | Out-Null
    & git -C $registeredWrongBranch branch -M feature/not-fleet | Out-Null
    Age-Path $registeredWrongBranch 100
    $r = Invoke-Janitor -Mode Report -WtRoot $wtRoot -MinAge 72
    Assert-True (Test-Path -LiteralPath $nameOnly) 'name-only legacy dir was deleted'
    $nameOnlyRow = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $nameOnly } | Select-Object -First 1
    # No git identity at all => orphan class now; 100h < quarantine age => too_young skip.
    Assert-True ($null -ne $nameOnlyRow -and [string]$nameOnlyRow.action -eq 'skip' -and ([string]$nameOnlyRow.reason -in @('ownership_ambiguous', 'too_young'))) ('name-only legacy not skipped: ' + ($nameOnlyRow | ConvertTo-Json -Compress))
    $evidenceRow = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $withGitEvidence } | Select-Object -First 1
    Assert-True ($null -ne $evidenceRow -and [string]$evidenceRow.action -eq 'would_quarantine' -and [string]$evidenceRow.ownership -eq 'legacy') ('Git-evidenced legacy not eligible: ' + ($evidenceRow | ConvertTo-Json -Compress))
    $wrongBranchRow = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $registeredWrongBranch } | Select-Object -First 1
    Assert-True ($null -ne $wrongBranchRow -and [string]$wrongBranchRow.reason -eq 'ownership_ambiguous') ('registered wrong-branch legacy not ambiguous: ' + ($wrongBranchRow | ConvertTo-Json -Compress))
  }

  Case 'Legacy REGISTERED non-fleet branch: work guards gate removal' {
    $repo = New-FixtureRepo
    $slug = (Split-Path -Leaf $repo).ToLowerInvariant()
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $clean = Join-Path $wtRoot ($slug + '\fleet-clean-nonfleet-20260801')
      $null = & git -C $repo worktree add -b feat/clean-nf -- $clean HEAD 2>&1
      Assert-True ($LASTEXITCODE -eq 0) 'clean worktree add failed'
      $dirty = Join-Path $wtRoot ($slug + '\fleet-dirty-nonfleet-20260801')
      $null = & git -C $repo worktree add -b feat/dirty-nf -- $dirty HEAD 2>&1
      Assert-True ($LASTEXITCODE -eq 0) 'dirty worktree add failed'
      Write-Utf8 (Join-Path $dirty 'uncommitted.txt') 'precious'
      $unmerged = Join-Path $wtRoot ($slug + '\fleet-unmerged-nonfleet-20260801')
      $null = & git -C $repo worktree add -b feat/unmerged-nf -- $unmerged HEAD 2>&1
      Assert-True ($LASTEXITCODE -eq 0) 'unmerged worktree add failed'
      Write-Utf8 (Join-Path $unmerged 'only-here.txt') 'unpushed'
      $null = & git -C $unmerged add only-here.txt 2>&1
      $null = & git -C $unmerged commit -q -m 'commit reachable only from this branch' 2>&1
      Assert-True ($LASTEXITCODE -eq 0) 'unmerged commit failed'
    } finally { $ErrorActionPreference = $prev }
    Age-Path $clean 400; Age-Path $dirty 400; Age-Path $unmerged 400
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True ($r.Code -eq 0) ('Apply exit ' + $r.Code + ' ' + $r.Err)
    $rows = @($r.Report.candidates)
    $cleanRow = $rows | Where-Object { [string]$_.path -eq $clean } | Select-Object -First 1
    Assert-True ($null -ne $cleanRow -and [string]$cleanRow.action -eq 'quarantined' -and [string]$cleanRow.ownership -eq 'legacy') ('clean registered non-fleet not quarantined: ' + ($cleanRow | ConvertTo-Json -Compress))
    Assert-True ([string]$cleanRow.delete_via -eq 'quarantine_move+worktree_prune') ('clean delete_via: ' + $cleanRow.delete_via)
    Assert-True (-not (Test-Path -LiteralPath $clean)) 'clean tree still at original path'
    $qc = @(Get-ChildItem -LiteralPath (Join-Path $wtRoot '.fleet-quarantine') -Directory -Force | Where-Object { $_.Name -like 'fleet-clean-nonfleet-*' })
    Assert-True ($qc.Count -eq 1) 'clean tree not in quarantine'
    $wtList = @(& git -C $repo worktree list --porcelain 2>$null) -join "`n"
    Assert-True ($wtList -notmatch [regex]::Escape($clean)) 'stale registration not pruned'
    $dirtyRow = $rows | Where-Object { [string]$_.path -eq $dirty } | Select-Object -First 1
    Assert-True ($null -ne $dirtyRow -and [string]$dirtyRow.reason -eq 'dirty_tree') ('dirty tree not guarded: ' + ($dirtyRow | ConvertTo-Json -Compress))
    Assert-True (Test-Path -LiteralPath (Join-Path $dirty 'uncommitted.txt')) 'dirty tree uncommitted file lost'
    $unmergedRow = $rows | Where-Object { [string]$_.path -eq $unmerged } | Select-Object -First 1
    Assert-True ($null -ne $unmergedRow -and [string]$unmergedRow.reason -eq 'unmerged_commits') ('unmerged tree not guarded: ' + ($unmergedRow | ConvertTo-Json -Compress))
    Assert-True (Test-Path -LiteralPath $unmerged) 'unmerged tree deleted'
  }

  Case 'Bare orphan: two-stage quarantine then purge' {
    $orphan = Join-Path $wtRoot 'orph\stale-copy-dir'
    New-Item -ItemType Directory -Force -Path (Join-Path $orphan 'sub') | Out-Null
    Write-Utf8 (Join-Path $orphan 'sub\data.txt') 'old junk'
    Age-Path $orphan 400
    $young = Join-Path $wtRoot 'orph\young-copy-dir'
    New-Item -ItemType Directory -Force -Path $young | Out-Null
    Write-Utf8 (Join-Path $young 'y.txt') 'young'
    Age-Path $young 100
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True ($r.Code -eq 0) ('Apply exit ' + $r.Code + ' ' + $r.Err)
    $rows = @($r.Report.candidates)
    $oRow = $rows | Where-Object { [string]$_.path -eq $orphan } | Select-Object -First 1
    Assert-True ($null -ne $oRow -and [string]$oRow.action -eq 'quarantined') ('aged orphan not quarantined: ' + ($oRow | ConvertTo-Json -Compress))
    Assert-True (-not (Test-Path -LiteralPath $orphan)) 'orphan still at original path'
    $qroot = Join-Path $wtRoot '.fleet-quarantine'
    $qdirs = @(Get-ChildItem -LiteralPath $qroot -Directory -Force | Where-Object { $_.Name -like 'stale-copy-dir-*' })
    Assert-True ($qdirs.Count -eq 1) ('expected 1 quarantined dir, got ' + $qdirs.Count)
    Assert-True (Test-Path -LiteralPath (Join-Path $qdirs[0].FullName 'sub\data.txt')) 'quarantined content lost'
    Assert-True (Test-Path -LiteralPath ($qdirs[0].FullName + '.quarantined.json')) 'quarantine marker missing'
    $yRow = $rows | Where-Object { [string]$_.path -eq $young } | Select-Object -First 1
    Assert-True ($null -ne $yRow -and [string]$yRow.action -eq 'skip' -and [string]$yRow.reason -eq 'too_young') ('young orphan not held: ' + ($yRow | ConvertTo-Json -Compress))
    # Fresh quarantine must HOLD on the next run (marker clock just started).
    $r2 = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True (Test-Path -LiteralPath $qdirs[0].FullName) 'fresh quarantine purged early'
    $hold = @($r2.Report.candidates) | Where-Object { [string]$_.path -eq $qdirs[0].FullName } | Select-Object -First 1
    Assert-True ($null -ne $hold -and [string]$hold.reason -eq 'quarantine_holding') ('no holding row: ' + ($hold | ConvertTo-Json -Compress))
    # Expire the marker; next Apply purges the quarantined dir and its marker.
    $expired = @{ schema_version = '1'; quarantined_utc = [datetimeoffset]::UtcNow.AddHours(-400).ToString('o'); original_path = $orphan } | ConvertTo-Json -Compress
    Write-Utf8 ($qdirs[0].FullName + '.quarantined.json') $expired
    $r3 = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True (-not (Test-Path -LiteralPath $qdirs[0].FullName)) 'expired quarantine not purged'
    Assert-True (-not (Test-Path -LiteralPath ($qdirs[0].FullName + '.quarantined.json'))) 'marker not cleaned'
    $purged = @($r3.Report.candidates) | Where-Object { [string]$_.path -eq $qdirs[0].FullName } | Select-Object -First 1
    Assert-True ($null -ne $purged -and [string]$purged.action -eq 'removed' -and [string]$purged.reason -eq 'quarantine_expired') ('no purge row: ' + ($purged | ConvertTo-Json -Compress))
  }

  Case 'JUNCTION CANARY: victim outside survives purge path' {
    $victim = Join-Path $tempRoot ('victim-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $victim | Out-Null
    $canaryFile = Join-Path $victim 'must-survive.txt'
    Write-Utf8 $canaryFile 'alive'
    $cand = Join-Path $wtRoot ('junc-slug\fleet-junc-20260801')
    New-Item -ItemType Directory -Force -Path (Join-Path $cand 'nested') | Out-Null
    Write-Utf8 (Join-Path $cand 'nested\junk.txt') 'junk'
    $link = Join-Path $cand 'nested\escape-junction'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $null = & cmd /c mklink /J "$link" "$victim" 2>&1
      Assert-True ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $link)) 'mklink failed'
    } finally { $ErrorActionPreference = $prev }
    # Branch corroboration so deletion is attempted via purge (junction-safe).
    & git -C $cand init -q 2>$null | Out-Null
    & git -C $cand config user.email 'janitor-test@example.com' | Out-Null
    & git -C $cand config user.name 'Janitor Test' | Out-Null
    Write-Utf8 (Join-Path $cand 'tracked.txt') 't'
    & git -C $cand add tracked.txt | Out-Null
    & git -C $cand commit -q -m 'junc' | Out-Null
    & git -C $cand branch -M fleet/fleet-junc-20260801 | Out-Null
    Write-Sidecar -TreePath $cand -RunId 'fleet-junc-20260801' -Created ([datetimeoffset]::UtcNow.AddHours(-100))
    Age-Path $cand 100
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True (Test-Path -LiteralPath $canaryFile) 'CANARY DELETED - junction followed into victim'
    Assert-True ((Get-Content -LiteralPath $canaryFile -Raw).Trim() -eq 'alive') 'canary content changed'
    $row = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $cand } | Select-Object -First 1
    Assert-True ($null -ne $row) 'junction candidate missing from report'
    if ([string]$row.action -eq 'removed') {
      Assert-True (-not (Test-Path -LiteralPath $cand)) 'removed action but path remains'
      Assert-True ([string]$row.delete_via -eq 'purge_orphan_tree') 'expected purge for orphan junction tree'
    }
  }

  Case 'Survival: live process cwd inside candidate intact' {
    $repo = New-FixtureRepo
    $cand = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'fleet-proc-20260801'
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -Command Start-Sleep -Seconds 120'
    $psi.WorkingDirectory = $cand
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    [void]$sleepProcs.Add($proc)
    Start-Sleep -Milliseconds 500
    try {
      $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
      Assert-True (Test-Path -LiteralPath $cand) 'live-process cwd tree was deleted'
      $row = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $cand } | Select-Object -First 1
      Assert-True ($null -ne $row -and [string]$row.reason -match 'live_process') ('expected live_process, got ' + $row.reason)
    } finally {
      try { $proc.Kill() } catch { }
      try { $proc.WaitForExit(5000) } catch { }
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { $null = & git -C $repo worktree remove --force -- $cand 2>&1 } catch { } finally { $ErrorActionPreference = $prev }
    }
  }

  Case 'L3 liveness: stale HB+live PID, dead PID+fresh/missing HB, malformed, unreadable skip; dead+stale deletes' {
    $repo = New-FixtureRepo
    $now = [datetimeoffset]::Now
    $keyId = ('c' * 32); $keyB64 = [Convert]::ToBase64String((New-Object byte[] 32))
    # stale heartbeat + live PID → LIVE → skip
    $p1 = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'l3-stalehb-livepid'
    Write-Utf8 (Join-Path $leaseRoot 'l3-stalehb-livepid.json') (([ordered]@{
      schema_version='2'; run_id='l3-stalehb-livepid'; owner_pid=$PID
      started_at=$now.AddHours(-10).ToString('o'); heartbeat_at=$now.AddHours(-10).ToString('o')
      expires_at=$now.AddHours(20).ToString('o'); receipt_hmac_key_id=$keyId; receipt_hmac_key_b64=$keyB64
    }) | ConvertTo-Json -Compress)
    # dead PID + fresh heartbeat → LIVE → skip
    $p2 = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'l3-deadpid-freshhb'
    Write-Utf8 (Join-Path $leaseRoot 'l3-deadpid-freshhb.json') (([ordered]@{
      schema_version='2'; run_id='l3-deadpid-freshhb'; owner_pid=999990
      started_at=$now.ToString('o'); heartbeat_at=$now.ToString('o')
      expires_at=$now.AddHours(20).ToString('o'); receipt_hmac_key_id=$keyId; receipt_hmac_key_b64=$keyB64
    }) | ConvertTo-Json -Compress)
    # malformed lease → LIVE → skip
    $p3 = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'l3-malformed'
    Write-Utf8 (Join-Path $leaseRoot 'l3-malformed.json') '{not-json'
    # unreadable owner state (owner_pid non-numeric) → LIVE → skip
    $p4 = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'l3-unreadable'
    Write-Utf8 (Join-Path $leaseRoot 'l3-unreadable.json') (([ordered]@{
      schema_version='2'; run_id='l3-unreadable'; owner_pid='not-a-pid'
      started_at=$now.AddHours(-10).ToString('o'); heartbeat_at=$now.AddHours(-10).ToString('o')
      expires_at=$now.AddHours(20).ToString('o'); receipt_hmac_key_id=$keyId; receipt_hmac_key_b64=$keyB64
    }) | ConvertTo-Json -Compress)
    # Missing heartbeat + dead PID is incomplete evidence, therefore LIVE/fail-closed.
    $pMissing = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'l3-missinghb-deadpid'
    Write-Utf8 (Join-Path $leaseRoot 'l3-missinghb-deadpid.json') (([ordered]@{
      schema_version='2'; run_id='l3-missinghb-deadpid'; owner_pid=999990
      started_at=$now.AddHours(-10).ToString('o'); expires_at=$now.AddHours(20).ToString('o'); receipt_hmac_key_id=$keyId; receipt_hmac_key_b64=$keyB64
    }) | ConvertTo-Json -Compress)
    # legitimate: dead PID + stale HB + git corroboration → delete
    $p5 = New-RegisteredWorktree -Repo $repo -WtRoot $wtRoot -RunId 'l3-dead-stale-ok'
    Write-Utf8 (Join-Path $leaseRoot 'l3-dead-stale-ok.json') (([ordered]@{
      schema_version='2'; run_id='l3-dead-stale-ok'; owner_pid=999990
      started_at=$now.AddHours(-10).ToString('o'); heartbeat_at=$now.AddHours(-10).ToString('o')
      expires_at=$now.AddHours(20).ToString('o'); receipt_hmac_key_id=$keyId; receipt_hmac_key_b64=$keyB64
    }) | ConvertTo-Json -Compress)
    $r = Invoke-Janitor -Mode Apply -WtRoot $wtRoot -MinAge 72
    Assert-True (Test-Path -LiteralPath $p1) 'staleHB+livePID deleted'
    Assert-True (Test-Path -LiteralPath $p2) 'deadPID+freshHB deleted'
    Assert-True (Test-Path -LiteralPath $p3) 'malformed lease tree deleted'
    Assert-True (Test-Path -LiteralPath $p4) 'unreadable owner tree deleted'
    Assert-True (Test-Path -LiteralPath $pMissing) 'missing heartbeat + dead PID tree deleted'
    Assert-True (-not (Test-Path -LiteralPath $p5)) 'dead+stale legitimate tree not deleted'
    foreach ($pair in @(@($p1,'live_lease'),@($p2,'live_lease'),@($p3,'live_lease'),@($p4,'live_lease'),@($pMissing,'live_lease'))) {
      $row = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $pair[0] } | Select-Object -First 1
      Assert-True ($null -ne $row -and [string]$row.reason -match [string]$pair[1]) ('expected ' + $pair[1] + ' for ' + $pair[0] + ' got ' + $row.reason)
    }
    $ok = @($r.Report.candidates) | Where-Object { [string]$_.path -eq $p5 -and [string]$_.action -eq 'quarantined' } | Select-Object -First 1
    Assert-True ($null -ne $ok) 'legitimate aged fixture not quarantined'
    foreach ($id in @('l3-stalehb-livepid','l3-deadpid-freshhb','l3-malformed','l3-unreadable','l3-missinghb-deadpid','l3-dead-stale-ok')) {
      Remove-Item -LiteralPath (Join-Path $leaseRoot ($id + '.json')) -Force -ErrorAction SilentlyContinue
    }
    foreach ($p in @($p1,$p2,$p3,$p4,$pMissing)) {
      if (Test-Path -LiteralPath $p) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $null = & git -C $repo worktree remove --force -- $p 2>&1 } catch { } finally { $ErrorActionPreference = $prev }
      }
    }
  }

  Case 'Enter stdout one lease path; janitor after mutex; crash does not fail lease' {
    $capPsi = {
      param($Script, $ScriptArgs, $Profile)
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = 'powershell.exe'
      $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" ' + $ScriptArgs
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $psi.EnvironmentVariables['USERPROFILE'] = $Profile
      $p = [Diagnostics.Process]::Start($psi)
      $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); $p.WaitForExit()
      return @{ Out = $o; Err = $e; Code = $p.ExitCode }
    }
    $c1 = & $capPsi $enter '-RunId enter-janitor-order' $profile
    $lines = @($c1.Out -split "`r?`n" | Where-Object { $_ })
    Assert-True ($c1.Code -eq 0) ('enter exit ' + $c1.Code + ' err=' + $c1.Err)
    Assert-True ($lines.Count -eq 1) ('stdout lines=' + $lines.Count + ' raw=' + $c1.Out)
    Assert-True (Test-Path -LiteralPath $lines[0]) 'lease path missing'
    $mi = $c1.Err.IndexOf('fleet-lease-order: mutex-released')
    $ji = $c1.Err.IndexOf('fleet-lease-order: janitor-begin')
    Assert-True ($mi -ge 0) ('missing mutex-released marker: ' + $c1.Err)
    Assert-True ($ji -ge 0) ('missing janitor-begin marker: ' + $c1.Err)
    Assert-True ($mi -lt $ji) ('janitor before mutex release: mi=' + $mi + ' ji=' + $ji)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exitLease -RunId 'enter-janitor-order' | Out-Null

    $env:FLEET_JANITOR_FORCE_FAIL = '1'
    try {
      $c2 = & $capPsi $enter '-RunId enter-janitor-crash' $profile
      Assert-True ($c2.Code -eq 0) ('crash enter exit ' + $c2.Code + ' err=' + $c2.Err)
      $lines2 = @($c2.Out -split "`r?`n" | Where-Object { $_ })
      Assert-True ($lines2.Count -eq 1 -and (Test-Path -LiteralPath $lines2[0])) 'crash spoiled stdout/lease'
      Assert-True ($c2.Err -match 'janitor skipped|forced janitor failure') ('expected crash warn: ' + $c2.Err)
    } finally { Remove-Item Env:\FLEET_JANITOR_FORCE_FAIL -ErrorAction SilentlyContinue }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exitLease -RunId 'enter-janitor-crash' | Out-Null
  }
}
finally {
  $env:FLEET_TEST_HARNESS = $oldHarness
  foreach ($p in @($sleepProcs)) {
    try { if (-not $p.HasExited) { $p.Kill() } } catch { }
    try { $p.Dispose() } catch { }
  }
  $env:USERPROFILE = $oldProfile
  if ($null -eq $oldForce) { Remove-Item Env:\FLEET_JANITOR_FORCE_FAIL -ErrorAction SilentlyContinue }
  else { $env:FLEET_JANITOR_FORCE_FAIL = $oldForce }
  # cleanup any leftover registered worktrees under temp repos
  Get-ChildItem -LiteralPath $tempRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -like 'repo-*') {
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try {
        $wts = @(& git -C $_.FullName worktree list --porcelain 2>$null)
        foreach ($line in $wts) {
          if ($line -match '^worktree (.+)$') {
            $wp = $Matches[1]
            if ($wp -ne $_.FullName) { $null = & git -C $_.FullName worktree remove --force -- $wp 2>&1 }
          }
        }
      } catch { } finally { $ErrorActionPreference = $prev }
    }
  }
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$total = $passed + $failed
if ($failed) { Write-Host "selftest: FAIL $passed/$total"; exit 1 }
Write-Host "selftest: PASS $passed/$passed"
exit 0
