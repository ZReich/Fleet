# Deterministic file-size gate for Fleet runs. Flags TOUCHED source files that end
# over the line cap AND grew (or are new) relative to the base ref. Untouched
# inherited monsters are not this gate's job (they are refactor-wave work).
# Manager quotes the summary line in gate evidence like the Fallow line:
#   filesize: N violations
param(
  [Parameter(Mandatory=$true)][string]$BaseRef,
  [string]$RepoPath = (Get-Location).Path,
  [int]$MaxLines = 300,
  # Report-only never exits nonzero; default gates (exit 1 on violations).
  [switch]$ReportOnly,
  # Files ALREADY over the cap at BaseRef may take minimal in-place edits
  # (policy: never net growth on monsters, but small fixes are legal). Additions
  # at or under this grace are WARN, not violation.
  [int]$GraceLines = 15,
  # Test SUITES legitimately hold many negative-control cases and blow the source cap
  # every feature. They get a higher (still bounded) cap; abuse is caught in review.
  [int]$TestFileMaxLines = 600,
  [string]$TestFilePattern = '(^|/)Test-[^/]*\.ps1$|\.Tests\.(ps1|ts|tsx|js|jsx|py)$|(^|/)[^/]*\.(test|spec)\.(ts|tsx|js|jsx|py)$',
  # Extensions treated as source. Keep tight; artifacts/locks are not source.
  [string[]]$SourceExtensions = @('.ts','.tsx','.js','.jsx','.vue','.py','.ps1','.psm1','.cs','.go','.rb','.php','.java'),
  [string]$ExcludePattern = '(^|/)(dist|build|node_modules|coverage)/|\.min\.|package-lock|\.d\.ts$'
)
function Get-EffectiveMaxLines([string]$Path) {
  if ($Path -match $TestFilePattern) { return $TestFileMaxLines }
  return $MaxLines
}
$ErrorActionPreference = 'Stop'
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path

& git -C $RepoPath rev-parse --verify --quiet $BaseRef *> $null
if ($LASTEXITCODE -ne 0) { throw "BaseRef '$BaseRef' is not a valid committish in $RepoPath" }

# numstat vs base including uncommitted work: added<TAB>deleted<TAB>path
$numstat = & git -C $RepoPath diff --numstat $BaseRef
$violations = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
foreach ($line in @($numstat)) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $parts = $line -split "`t"
  if ($parts.Count -lt 3) { continue }
  if ($parts[0] -eq '-') { continue } # binary
  $added = 0; [void][int]::TryParse($parts[0], [ref]$added)
  $path = $parts[2]
  $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
  if ($SourceExtensions -notcontains $ext) { continue }
  if ($path -match $ExcludePattern) { continue }
  if ($added -le 0) { continue } # pure deletions/renames never violate
  $full = Join-Path $RepoPath ($path -replace '/', '\')
  if (-not (Test-Path -LiteralPath $full)) { continue } # deleted file
  $count = 0
  $reader = New-Object IO.StreamReader($full)
  try { while ($null -ne $reader.ReadLine()) { $count++ } } finally { $reader.Dispose() }
  $effMax = Get-EffectiveMaxLines $path
  if ($count -le $effMax) { continue }
  # Was it already over the cap at base? (New files fail `git show` -> base 0.)
  $baseCount = 0
  $baseContent = & git -C $RepoPath show ("{0}:{1}" -f $BaseRef, $path) 2>$null
  if ($LASTEXITCODE -eq 0) { $baseCount = @($baseContent).Count }
  if ($baseCount -gt $effMax -and $added -le $GraceLines) {
    [void]$warnings.Add([pscustomobject]@{ lines = $count; added = $added; path = $path })
    continue
  }
  [void]$violations.Add([pscustomobject]@{ lines = $count; added = $added; path = $path })
}

# Untracked source files are invisible to git-diff numstat (LESSONS 2026-07-29).
# Treat each untracked source file over the cap as a full-file violation.
$seenPaths = @{}
foreach ($v in $violations) { $seenPaths[$v.path] = $true }
foreach ($w in $warnings) { $seenPaths[$w.path] = $true }
$oldEap = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  $untracked = @(& git -C $RepoPath ls-files --others --exclude-standard 2>$null)
} finally { $ErrorActionPreference = $oldEap }
foreach ($upath in $untracked) {
  if ([string]::IsNullOrWhiteSpace($upath)) { continue }
  $path = ($upath -replace '\\', '/').Trim()
  if ($seenPaths.ContainsKey($path)) { continue }
  $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
  if ($SourceExtensions -notcontains $ext) { continue }
  if ($path -match $ExcludePattern) { continue }
  $full = Join-Path $RepoPath ($path -replace '/', '\')
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
  $count = 0
  $reader = New-Object IO.StreamReader($full)
  try { while ($null -ne $reader.ReadLine()) { $count++ } } finally { $reader.Dispose() }
  if ($count -le (Get-EffectiveMaxLines $path)) { continue }
  [void]$violations.Add([pscustomobject]@{ lines = $count; added = $count; path = $path })
}

foreach ($v in ($violations | Sort-Object lines -Descending)) {
  Write-Output ("VIOLATION {0} lines (+{1}) {2}" -f $v.lines, $v.added, $v.path)
}
foreach ($w in ($warnings | Sort-Object lines -Descending)) {
  Write-Output ("WARN {0} lines (+{1}, inherited-over-cap minimal edit) {2}" -f $w.lines, $w.added, $w.path)
}
Write-Output ("filesize: {0} violations, {1} warnings (cap {2}, grace {3}, base {4})" -f $violations.Count, $warnings.Count, $MaxLines, $GraceLines, $BaseRef)
if ($violations.Count -gt 0 -and -not $ReportOnly) { exit 1 }
exit 0
