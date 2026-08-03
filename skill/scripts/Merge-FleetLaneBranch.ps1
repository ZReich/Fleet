# Fail-closed squash-merge of one fleet lane branch into a skill repo.
# Refuses dirty index / in-progress merge; refuses empty or missing branches;
# aborts on conflict; verifies staged set and optional ExpectPath; commits unless -NoCommit.
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$Branch,
  [string]$Message,
  [string[]]$ExpectPath = @(),
  [switch]$NoCommit,
  [ValidateSet('text', 'json')][string]$Mode = 'text'
)
$ErrorActionPreference = 'Stop'
$script:exitCode = 1

function Write-Fail([string]$Message) {
  [Console]::Error.WriteLine($Message)
}

function Invoke-Git {
  param([Parameter(Mandatory)][string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $raw = & git -C $Repo @GitArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  $lines = @()
  if ($null -ne $raw) {
    foreach ($item in @($raw)) { $lines += [string]$item }
  }
  return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Get-GitPath([string]$Name) {
  $r = Invoke-Git @('rev-parse', '--git-path', $Name)
  if ($r.Code -ne 0 -or $r.Lines.Count -eq 0) { return $null }
  $p = $r.Lines[0].Trim()
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }
  if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Repo $p }
  return $p
}

function Get-StagedNames {
  $r = Invoke-Git @('diff', '--cached', '--name-only')
  if ($r.Code -ne 0) { throw "git diff --cached failed: $($r.Text)" }
  return @($r.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Clear-PartialMerge {
  # Leave tracked tree as found. NEVER `reset --hard`: it discards UNSTAGED edits the
  # caller never handed us (panel-found 2026-07-26 - a failed -ExpectPath check silently
  # reverted an uncommitted README to HEAD). A mixed reset unstages what the squash
  # staged while leaving working-tree content alone; untracked files are never touched.
  $null = Invoke-Git @('merge', '--abort')
  $null = Invoke-Git @('reset', '--merge')
  $null = Invoke-Git @('reset', 'HEAD')
  foreach ($name in @('MERGE_HEAD', 'SQUASH_MSG', 'MERGE_MSG', 'CHERRY_PICK_HEAD')) {
    $p = Get-GitPath $name
    if ($p -and (Test-Path -LiteralPath $p)) {
      Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
  }
}

try {
  if (-not (Test-Path -LiteralPath $Repo -PathType Container)) {
    Write-Fail "Repo not found: $Repo"
    exit 1
  }
  $probe = Invoke-Git @('rev-parse', '--is-inside-work-tree')
  if ($probe.Code -ne 0 -or ($probe.Lines -join '') -notmatch 'true') {
    Write-Fail "Not a git work tree: $Repo"
    exit 1
  }

  if ([string]::IsNullOrWhiteSpace($Message)) {
    $Message = "merge $Branch"
  }

  # 1. PRECONDITION: clean index and no in-progress merge/squash.
  $stagedBefore = Get-StagedNames
  if ($stagedBefore.Count -gt 0) {
    Write-Fail ("Refusing merge: index not clean; staged: " + ($stagedBefore -join ', '))
    exit 1
  }
  $blockers = @()
  foreach ($name in @('MERGE_HEAD', 'SQUASH_MSG')) {
    $p = Get-GitPath $name
    if ($p -and (Test-Path -LiteralPath $p)) { $blockers += $name }
  }
  if ($blockers.Count -gt 0) {
    Write-Fail ("Refusing merge: in-progress merge state present: " + ($blockers -join ', '))
    exit 1
  }

  # 2. Branch must exist and have commits not in HEAD.
  $branchProbe = Invoke-Git @('rev-parse', '--verify', $Branch)
  if ($branchProbe.Code -ne 0) {
    Write-Fail "Branch does not exist: $Branch"
    exit 1
  }
  # Refuse unstaged tracked modifications too: a squash merge can overwrite them, and the
  # recovery path must never be asked to restore work we cannot see. Untracked files are
  # fine (they are not at risk from merge or from a mixed reset).
  $unstaged = Invoke-Git @('diff', '--name-only')
  $unstagedNames = @($unstaged.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
  if ($unstagedNames.Count -gt 0) {
    Write-Fail ("Refusing merge: working tree has unstaged changes; modified: " + ($unstagedNames -join ', '))
    exit 1
  }

  $ahead = Invoke-Git @('rev-list', '--count', "HEAD..$Branch")
  if ($ahead.Code -ne 0) {
    Write-Fail "Could not compare branch to HEAD: $($ahead.Text)"
    exit 1
  }
  $aheadCount = 0
  [void][int]::TryParse(($ahead.Lines -join '').Trim(), [ref]$aheadCount)
  if ($aheadCount -le 0) {
    Write-Fail "Nothing to merge: branch '$Branch' has no commits not already in HEAD"
    exit 1
  }

  # 3. Squash-merge.
  $merge = Invoke-Git @('merge', '--squash', $Branch)
  if ($merge.Code -ne 0) {
    $conflict = Invoke-Git @('diff', '--name-only', '--diff-filter=U')
    $paths = @($conflict.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($paths.Count -eq 0) {
      # Fallback: any staged/unstaged names from merge attempt
      $paths = @(Get-StagedNames)
    }
    Clear-PartialMerge
    if ($paths.Count -gt 0) {
      Write-Fail ("Merge conflict aborting; conflicting paths: " + ($paths -join ', '))
    } else {
      Write-Fail ("Merge failed (exit $($merge.Code)): $($merge.Text)")
    }
    exit 1
  }

  # 4. POSTCONDITION: something staged.
  $staged = Get-StagedNames
  if ($staged.Count -eq 0) {
    Clear-PartialMerge
    Write-Fail "Squash merge staged nothing; refusing empty merge for branch '$Branch'"
    exit 1
  }

  # 5. ExpectPath coverage.
  $expectedStatus = 'n/a'
  if (@($ExpectPath).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace(($ExpectPath | Where-Object { $_ }) -join '')) {
    $expectedStatus = 'ok'
    $missing = @()
    $stagedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $staged) { [void]$stagedSet.Add(($s -replace '\\', '/')) }
    foreach ($ep in @($ExpectPath)) {
      if ([string]::IsNullOrWhiteSpace($ep)) { continue }
      $norm = ($ep.Trim() -replace '\\', '/')
      if (-not $stagedSet.Contains($norm)) { $missing += $ep.Trim() }
    }
    if ($missing.Count -gt 0) {
      Clear-PartialMerge
      Write-Fail ("Expected path(s) not staged: " + ($missing -join ', '))
      exit 1
    }
  }

  # 6. Commit unless -NoCommit; verify commit content.
  $committed = 'none'
  if (-not $NoCommit) {
    $commit = Invoke-Git @('commit', '-m', $Message)
    if ($commit.Code -ne 0) {
      Clear-PartialMerge
      Write-Fail "Commit failed: $($commit.Text)"
      exit 1
    }
    $shaR = Invoke-Git @('rev-parse', 'HEAD')
    if ($shaR.Code -ne 0 -or $shaR.Lines.Count -eq 0) {
      Write-Fail "Could not read HEAD after commit"
      exit 1
    }
    $committed = $shaR.Lines[0].Trim()
    $show = Invoke-Git @('show', '--stat', '--name-only', '--pretty=format:', 'HEAD')
    if ($show.Code -ne 0) {
      Write-Fail "git show HEAD failed: $($show.Text)"
      exit 1
    }
    $inCommit = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $show.Lines) {
      $t = $line.Trim()
      if ($t -ne '') { [void]$inCommit.Add(($t -replace '\\', '/')) }
    }
    $notInCommit = @()
    foreach ($s in $staged) {
      $norm = ($s -replace '\\', '/')
      if (-not $inCommit.Contains($norm)) { $notInCommit += $s }
    }
    if ($notInCommit.Count -gt 0) {
      Write-Fail ("Commit missing staged path(s): " + ($notInCommit -join ', '))
      exit 1
    }
  }

  $n = $staged.Count
  if ($Mode -eq 'json') {
    $obj = [ordered]@{
      merge = $Branch
      staged = $n
      committed = $committed
      'expected-paths' = $expectedStatus
    }
    $obj | ConvertTo-Json -Compress
  } else {
    Write-Output "merge: $Branch | staged: $n files | committed: $committed | expected-paths: $expectedStatus"
  }
  $script:exitCode = 0
}
catch {
  Write-Fail $_.Exception.Message
  $script:exitCode = 1
}
exit $script:exitCode
