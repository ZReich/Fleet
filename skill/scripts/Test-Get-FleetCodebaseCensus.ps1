# Offline suite for the refactor-mode census.
#
# The census exists to feed a refactor ledger, so its failure modes are both silent: a
# dimension reported as clean when no tool ran, and phantom rows from checkouts living
# inside the repo (the first run against this repo counted Invoke-KimiK3.ps1 three times,
# once per stale worktree, which would have put a nonexistent duplicate at the top).

$ErrorActionPreference = "Stop"
$census = Join-Path $PSScriptRoot "Get-FleetCodebaseCensus.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("fleet-census-test-" + [guid]::NewGuid().ToString("n"))
$passed = 0
$failed = 0

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

function New-Line([int]$Count) { return (1..$Count | ForEach-Object { "# line $_" }) -join "`n" }

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $root "src") | Out-Null
  [IO.File]::WriteAllText((Join-Path $root "src\big.ps1"), (New-Line 400))
  [IO.File]::WriteAllText((Join-Path $root "src\small.ps1"), (New-Line 10))
  # A checkout inside the repo, holding a copy of the same oversize file.
  New-Item -ItemType Directory -Force -Path (Join-Path $root "worktrees\wt1\src") | Out-Null
  [IO.File]::WriteAllText((Join-Path $root "worktrees\wt1\src\big.ps1"), (New-Line 400))
  New-Item -ItemType Directory -Force -Path (Join-Path $root "node_modules\pkg") | Out-Null
  [IO.File]::WriteAllText((Join-Path $root "node_modules\pkg\vendored.ps1"), (New-Line 900))

  $out = Join-Path $root "census.json"
  & $census -RepoPath $root -OutputPath $out -LineBudget 300 | Out-Null
  $result = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
  $d5 = @($result.dimensions | Where-Object { $_.id -eq "D5" })[0]

  Case 'oversize file is found and undersize file is not' {
    Assert-True (@($d5.findings | Where-Object { $_.path -like "*big.ps1" }).Count -ge 1) "oversize file missing from D5"
    Assert-True (@($d5.findings | Where-Object { $_.path -like "*small.ps1" }).Count -eq 0) "undersize file wrongly reported"
  }

  Case 'a checkout inside the repo does not create phantom duplicates' {
    Assert-True (@($d5.findings | Where-Object { $_.path -like "*big.ps1" }).Count -eq 1) "worktree copy double-counted in D5"
    Assert-True (@($d5.findings | Where-Object { $_.path -match 'worktrees' }).Count -eq 0) "worktree path present in the ledger"
  }

  Case 'a repo living under an excluded-looking path still gets censused' {
    # Regression, found against a real production surface: exclusions were matched on the
    # ABSOLUTE path, so a repo whose location contains an excluded segment excluded its own
    # contents. Every Fleet worktree lives under ~/.codex/worktrees/ - both `.codex` and
    # `worktrees` are exclusion terms - so every worktree census reported zero findings.
    # Reported 0 oversize files where 67 existed, largest 2190 lines.
    $nested = Join-Path $root ".codex\worktrees\repo-under-excluded-path\src"
    New-Item -ItemType Directory -Force -Path $nested | Out-Null
    [IO.File]::WriteAllText((Join-Path $nested "huge.ps1"), (New-Line 400))
    $nestedRepo = Split-Path -Parent $nested
    $nestedOut = Join-Path $root "nested-census.json"
    & $census -RepoPath $nestedRepo -OutputPath $nestedOut -LineBudget 300 | Out-Null
    $nestedResult = Get-Content -LiteralPath $nestedOut -Raw | ConvertFrom-Json
    $nestedD5 = @($nestedResult.dimensions | Where-Object { $_.id -eq "D5" })[0]
    Assert-True (@($nestedD5.findings | Where-Object { $_.path -like "*huge.ps1" }).Count -eq 1) "repo under an excluded-looking path reported no findings"
  }

  Case 'vendored code is excluded' {
    Assert-True (@($d5.findings | Where-Object { $_.path -match 'node_modules' }).Count -eq 0) "node_modules counted toward the size budget"
  }

  Case 'an absent adapter reports not_measured WITH the command, never a zero' {
    $unmeasured = @($result.dimensions | Where-Object { $_.status -eq "not_measured" })
    Assert-True ($unmeasured.Count -gt 0) "test environment measured every dimension; case cannot run"
    foreach ($dim in $unmeasured) {
      Assert-True (-not [string]::IsNullOrWhiteSpace($dim.reason)) "$($dim.id) not_measured without a reason"
      Assert-True (-not [string]::IsNullOrWhiteSpace($dim.command)) "$($dim.id) not_measured without the command that would measure it"
      Assert-True (@($dim.findings).Count -eq 0) "$($dim.id) reported findings while not measured"
    }
  }

  Case 'coverage is reported as a fraction, and the graph half is declared absent' {
    Assert-True ($result.dimensions_total -eq 5) "expected five dimensions, got $($result.dimensions_total)"
    Assert-True ($result.dimensions_measured -lt $result.dimensions_total) "measured count should be partial in this environment"
    Assert-True ($result.graph_half -eq "absent" -and -not [string]::IsNullOrWhiteSpace($result.graph_half_reason)) "graph half not declared absent with a reason"
  }
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
