# Canonical, junction-safe fleet worktree creator.
# Location fixed under $env:USERPROFILE\.codex\worktrees\<repo-slug>\<RunId>.
# Fail-closed on Documents paths, source-sibling paths, existing branches,
# missing CopyFile sources, escaping reparse points, and hollow installs.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$RunId,
  [string]$BaseRef = 'HEAD',
  [string[]]$CopyFile = @(),
  [switch]$Install,  # no-op alias; install is default when package.json exists
  [switch]$NoInstall,
  [string]$InstallCommand,
  [string]$NodeBinDir,
  [int]$InstallTimeoutSeconds = 1800,
  [ValidateSet('text', 'json')][string]$Mode = 'text'
)

$ErrorActionPreference = 'Stop'
$script:exitCode = 1
$script:installStatus = 'skipped'
$script:copiedCount = 0
$script:depsCount = 0
$script:worktreePath = $null
$script:branchName = "fleet/$RunId"

function Write-Fail([string]$Message) { [Console]::Error.WriteLine($Message) }

function Assert-NoEscapingReparsePoints {
  param([string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return }
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $stack = New-Object System.Collections.Stack; $stack.Push($rootFull)
  while ($stack.Count -gt 0) {
    $dir = [string]$stack.Pop()
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) {
        $target = $null; try { $target = (Get-Item -LiteralPath $child.FullName -Force).Target } catch { }
        $anyTarget = $false
        foreach ($t in @($target)) {
          if ([string]::IsNullOrWhiteSpace([string]$t)) { continue }
          $anyTarget = $true
          $resolved = if ([IO.Path]::IsPathRooted([string]$t)) { [string]$t } else { Join-Path (Split-Path -Parent $child.FullName) ([string]$t) }
          $tFull = try { [IO.Path]::GetFullPath($resolved).TrimEnd('\') } catch { [string]$resolved }
          if (-not (Test-UnderRoot -Path $tFull -Root $rootFull)) {
            throw "Refusing worktree: reparse point '$($child.FullName)' escapes to '$tFull' outside the worktree. A recursive delete could follow it into another checkout. Remove the junction (rmdir the link) or use an npm-installed dependency tree (npm ci)."
          }
        }
        if (-not $anyTarget) {
          throw "Refusing worktree: unresolvable reparse point at '$($child.FullName)'. Remove it before using (fail closed)."
        }
        continue
      }
      $stack.Push([string]$child.FullName)
    }
  }
}

function Test-UnderDocuments([string]$Path) {
  foreach ($part in ([IO.Path]::GetFullPath($Path) -split '[\\/]+')) {
    if ($part -eq 'Documents') { return $true }
  }
  return $false
}

function Test-UnderRoot([string]$Path, [string]$Root) {
  $p = [IO.Path]::GetFullPath($Path).TrimEnd('\'); $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  return $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or ($p + '\').StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-SiblingOfSource([string]$WorktreePath, [string]$RepoPath) {
  $wtParent = [IO.Path]::GetFullPath((Split-Path -Parent $WorktreePath)).TrimEnd('\')
  $repoParent = [IO.Path]::GetFullPath((Split-Path -Parent $RepoPath)).TrimEnd('\')
  return $wtParent.Equals($repoParent, [StringComparison]::OrdinalIgnoreCase)
}

# Walk ancestors; follow reparse targets. Returns physical path + first escape offender.
function Resolve-PhysicalWorktreePath {
  param([string]$LogicalPath, [string]$CanonicalRoot)
  $bs = [string][char]92
  $full = [IO.Path]::GetFullPath($LogicalPath).TrimEnd($bs)
  $root = [IO.Path]::GetPathRoot($full)
  $rel = if ($full.Length -gt $root.Length) { $full.Substring($root.Length).TrimStart($bs) } else { '' }
  $segments = @(); if ($rel) { $segments = @($rel -split '[\\/]+' | Where-Object { $_ }) }
  $current = $root; $offPath = $null; $offTarget = $null; $visited = @{}; $i = 0
  while ($i -lt $segments.Count) {
    $next = Join-Path $current $segments[$i]
    if (-not (Test-Path -LiteralPath $next)) {
      $current = [IO.Path]::GetFullPath((Join-Path $current ($segments[$i..($segments.Count - 1)] -join $bs))).TrimEnd($bs)
      break
    }
    $item = Get-Item -LiteralPath $next -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) {
      $targetRaw = $null; try { $targetRaw = $item.Target } catch { }
      $t = $null
      foreach ($cand in @($targetRaw)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$cand)) { $t = [string]$cand; break }
      }
      if ([string]::IsNullOrWhiteSpace($t)) { throw "Refusing worktree: unresolvable reparse point at '$next'." }
      if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $next) $t }
      $tFull = [IO.Path]::GetFullPath($t).TrimEnd($bs)
      $key = $next.ToLowerInvariant()
      if ($visited.ContainsKey($key)) { throw "Refusing worktree: cyclic reparse point at '$next'." }
      $visited[$key] = $true
      if (-not (Test-UnderRoot -Path $tFull -Root $CanonicalRoot) -and $null -eq $offPath) {
        $offPath = $next; $offTarget = $tFull
      }
      $current = $tFull; $i++; continue
    }
    $current = [IO.Path]::GetFullPath($next).TrimEnd($bs); $i++
  }
  return @{ Path = [IO.Path]::GetFullPath($current).TrimEnd($bs); OffenderPath = $offPath; OffenderTarget = $offTarget }
}

function Get-DepsCount([string]$Root) {
  $nm = Join-Path $Root 'node_modules'
  if (-not (Test-Path -LiteralPath $nm)) { return 0 }
  return @(Get-ChildItem -LiteralPath $nm -Force -ErrorAction SilentlyContinue).Count
}

function Stop-Tree {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try { $processId = $Process.Id } catch { return }
  try { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null } catch { }
  try { $null = $Process.WaitForExit(5000) } catch { }
}

function Emit-Summary {
  param([string]$Path, [string]$Branch, [int]$Copied, [string]$Install, [int]$Deps)
  if ($Mode -eq 'json') {
    Write-Output (([ordered]@{ worktree = $Path; branch = $Branch; copied = $Copied; install = $Install; deps = $Deps } | ConvertTo-Json -Compress))
  } else {
    Write-Output ("worktree: $Path | branch: $Branch | copied: $Copied | install: $Install | deps: $Deps entries")
  }
}

function Invoke-Install {
  param([string]$WorktreeRoot, [string]$Command, [string]$BinDir, [int]$TimeoutSeconds)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'
  $psi.Arguments = "/d /c $Command"
  $psi.WorkingDirectory = $WorktreeRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  if (-not [string]::IsNullOrWhiteSpace($BinDir)) {
    $existing = $psi.EnvironmentVariables['PATH']
    $psi.EnvironmentVariables['PATH'] = $BinDir.TrimEnd('\') + ';' + $existing
  }
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $ms = [Math]::Max(1, $TimeoutSeconds) * 1000
  $finished = $proc.WaitForExit($ms)
  if (-not $finished) {
    Stop-Tree -Process $proc
    $null = $stdoutTask.Wait(2000)
    $null = $stderrTask.Wait(2000)
    $proc.Dispose()
    throw "Install timed out after ${TimeoutSeconds}s: $Command"
  }
  $code = $proc.ExitCode
  $err = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { '' }
  $out = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { '' }
  $proc.Dispose()
  if ($code -ne 0) {
    if ($err) { Write-Fail $err.TrimEnd() }
    if ($out) { Write-Fail $out.TrimEnd() }
    throw "Install exited ${code}: $Command"
  }
}

try {
  if ([string]::IsNullOrWhiteSpace($Repo)) { throw 'Repo is required.' }
  if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'RunId is required.' }
  if ($RunId -match '[\\/]' -or $RunId -match '\.\.') { throw "RunId must be a single path segment, got: $RunId" }

  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  if (-not (Test-Path -LiteralPath $repoFull)) { throw "Repo path does not exist: $repoFull" }
  $gitOk = & git -C $repoFull rev-parse --is-inside-work-tree 2>$null
  if ($LASTEXITCODE -ne 0 -or $gitOk -ne 'true') { throw "Repo is not a git work tree: $repoFull" }

  $repoSlug = ([IO.Path]::GetFileName($repoFull)).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($repoSlug)) { throw "Could not derive repo-slug from: $repoFull" }

  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw 'USERPROFILE is not set.' }
  $canonicalRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex\worktrees'))
  $script:worktreePath = [IO.Path]::GetFullPath((Join-Path $canonicalRoot "$repoSlug\$RunId"))
  $script:branchName = "fleet/$RunId"

  if (Test-UnderDocuments -Path $script:worktreePath) { throw "Refusing worktree path under a Documents directory: $($script:worktreePath)" }
  if (Test-SiblingOfSource -WorktreePath $script:worktreePath -RepoPath $repoFull) {
    throw "Refusing worktree path that would be a sibling of the source checkout: $($script:worktreePath)"
  }
  $resolved = Resolve-PhysicalWorktreePath -LogicalPath $script:worktreePath -CanonicalRoot $canonicalRoot
  if (-not (Test-UnderRoot -Path $resolved.Path -Root $canonicalRoot)) {
    if ($resolved.OffenderPath) {
      throw "Refusing worktree: ancestor reparse point '$($resolved.OffenderPath)' resolves to '$($resolved.OffenderTarget)' outside the canonical worktree root '$canonicalRoot'."
    }
    throw "Refusing worktree: resolved path '$($resolved.Path)' escapes canonical worktree root '$canonicalRoot'."
  }
  if (Test-UnderDocuments -Path $resolved.Path) { throw "Refusing worktree path under a Documents directory: $($resolved.Path)" }
  if (Test-SiblingOfSource -WorktreePath $resolved.Path -RepoPath $repoFull) {
    throw "Refusing worktree path that would be a sibling of the source checkout: $($resolved.Path)"
  }
  if (Test-Path -LiteralPath $script:worktreePath) { throw "Worktree path already exists: $($script:worktreePath)" }

  & git -C $repoFull show-ref --verify --quiet "refs/heads/$($script:branchName)" 2>$null
  if ($LASTEXITCODE -eq 0) {
    throw "Branch already exists: $($script:branchName) (refusing to reuse; pick a new RunId)"
  }

  $parent = Split-Path -Parent $script:worktreePath
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  $prevEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & git -C $repoFull worktree add -b $script:branchName -- $script:worktreePath $BaseRef 2>&1 | ForEach-Object { $_ }
    $wtCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEap
  }
  if ($wtCode -ne 0) {
    throw "git worktree add failed for $($script:worktreePath) branch $($script:branchName) (exit $wtCode)"
  }

  # Flatten comma-joined lists (callers sometimes pass "a,b" as one arg) and normalize.
  $copyEntries = New-Object System.Collections.ArrayList
  foreach ($item in @($CopyFile)) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    foreach ($piece in ([string]$item -split ',')) {
      $p = $piece.Trim(); if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$copyEntries.Add($p) }
    }
  }
  $repoRootFull = [IO.Path]::GetFullPath($repoFull).TrimEnd('\')
  foreach ($rel in $copyEntries) {
    $norm = $rel -replace '/', '\'
    if ($norm -match '(^|\\)\.\.(\\|$)') { throw "CopyFile may not contain '..': $rel" }
    # An ABSOLUTE path INSIDE the repo is fine (resolve it to repo-relative); outside the repo is refused.
    if ([IO.Path]::IsPathRooted($norm)) {
      $abs = [IO.Path]::GetFullPath($norm)
      if (($abs + '\').StartsWith($repoRootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $norm = $abs.Substring($repoRootFull.Length).TrimStart('\')
      } else {
        throw "CopyFile absolute path is outside the repo (refused): $rel"
      }
    }
    $src = Join-Path $repoFull $norm
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
      throw "CopyFile source missing (hard failure): $rel (looked for $src)"
    }
    $dst = Join-Path $script:worktreePath $norm
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) {
      New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $script:copiedCount++
  }

  # -Install is accepted as a no-op for backward compatibility; install is default when package.json exists.
  $null = $Install
  $pkgJson = Join-Path $script:worktreePath 'package.json'
  $hasPackageJson = Test-Path -LiteralPath $pkgJson -PathType Leaf
  if ($NoInstall) {
    $script:installStatus = 'skipped(-NoInstall)'
    $script:depsCount = Get-DepsCount -Root $script:worktreePath
  } elseif (-not $hasPackageJson) {
    $script:installStatus = 'skipped(no package.json)'
    $script:depsCount = Get-DepsCount -Root $script:worktreePath
  } else {
    if (-not [string]::IsNullOrWhiteSpace($InstallCommand)) {
      $cmd = $InstallCommand
    } elseif (Test-Path -LiteralPath (Join-Path $script:worktreePath 'package-lock.json') -PathType Leaf) {
      $cmd = 'npm ci'
    } else {
      $cmd = 'npm install'
    }
    try {
      Invoke-Install -WorktreeRoot $script:worktreePath -Command $cmd -BinDir $NodeBinDir -TimeoutSeconds $InstallTimeoutSeconds
      $script:depsCount = Get-DepsCount -Root $script:worktreePath
      if ($script:depsCount -le 0) {
        $script:installStatus = 'failed'
        throw "Install exited 0 but node_modules is empty/absent under $($script:worktreePath) (install did not materialise deps)"
      }
      $script:installStatus = 'ok'
    } catch {
      $script:installStatus = 'failed'
      $script:depsCount = Get-DepsCount -Root $script:worktreePath
      Write-Fail $_.Exception.Message
      Emit-Summary -Path $script:worktreePath -Branch $script:branchName -Copied $script:copiedCount -Install $script:installStatus -Deps $script:depsCount
      exit 1
    }
  }

  Assert-NoEscapingReparsePoints -Root $script:worktreePath

  Emit-Summary -Path $script:worktreePath -Branch $script:branchName -Copied $script:copiedCount -Install $script:installStatus -Deps $script:depsCount
  $script:exitCode = 0
  exit 0
} catch {
  Write-Fail $_.Exception.Message
  if ($script:worktreePath -and (Test-Path -LiteralPath $script:worktreePath) -and $script:installStatus -eq 'failed') {
    Emit-Summary -Path $script:worktreePath -Branch $script:branchName -Copied $script:copiedCount -Install $script:installStatus -Deps $script:depsCount
  }
  exit 1
}
