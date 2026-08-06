# Deterministic file-size gate for Fleet runs. Bands, not a wall: a clean file at 305
# should not trigger mechanical compression. TOUCHED source files that grew (or are new):
#   <= WARN threshold  -> clean
#   WARN < n <= BLOCK  -> WARN (is this cohesive, or should it split? never `;`-jam to pass)
#   > BLOCK            -> VIOLATION (real bloat; split by a real boundary)
# Prod: warn 300 / block 400. Test SUITES (many negative-control cases): warn 400 / block 600.
# Manager quotes the summary line in gate evidence like the Fallow line:
#   filesize: N violations, M warnings (warn/block prod 300/400, test 400/600)
param(
  [Parameter(Mandatory=$true)][string]$BaseRef,
  [string]$RepoPath = (Get-Location).Path,
  # Soft target (WARN threshold) for production source.
  [int]$MaxLines = 300,
  # Hard ceiling (BLOCK) for production source. Over this is a violation.
  [int]$HardMaxLines = 400,
  # Test-suite thresholds (higher — comprehensive negative-control cases are legit).
  [int]$TestFileMaxLines = 400,
  [int]$TestHardMaxLines = 600,
  [string]$TestFilePattern = '(^|/)Test-[^/]*\.ps1$|\.Tests\.(ps1|ts|tsx|js|jsx|py)$|(^|/)[^/]*\.(test|spec)\.(ts|tsx|js|jsx|py)$',
  # Report-only never exits nonzero; default gates (exit 1 on violations only, not warnings).
  [switch]$ReportOnly,
  # Files ALREADY over the block ceiling at BaseRef may take minimal in-place edits
  # (never net growth on monsters, but small fixes are legal). Additions at/under grace = WARN.
  [int]$GraceLines = 15,
  # Extensions treated as source. Keep tight; artifacts/locks are not source.
  [string[]]$SourceExtensions = @('.ts','.tsx','.js','.jsx','.vue','.py','.ps1','.psm1','.cs','.go','.rb','.php','.java'),
  [string]$ExcludePattern = '(^|/)(dist|build|node_modules|coverage)/|\.min\.|package-lock|\.d\.ts$'
)
# Returns @{ Warn = <soft target>; Block = <hard ceiling> } for the file.
function Get-FileSizeThresholds([string]$Path) {
  if ($Path -match $TestFilePattern) { return @{ Warn = $TestFileMaxLines; Block = $TestHardMaxLines } }
  return @{ Warn = $MaxLines; Block = $HardMaxLines }
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
  $th = Get-FileSizeThresholds $path
  if ($count -le $th.Warn) { continue }              # clean
  # Was it already over the block ceiling at base? (New files fail `git show` -> base 0.)
  $baseCount = 0
  $baseContent = & git -C $RepoPath show ("{0}:{1}" -f $BaseRef, $path) 2>$null
  if ($LASTEXITCODE -eq 0) { $baseCount = @($baseContent).Count }
  if ($baseCount -gt $th.Block -and $added -le $GraceLines) {
    [void]$warnings.Add([pscustomobject]@{ lines = $count; added = $added; path = $path })
    continue
  }
  if ($count -le $th.Block) {                        # warn band: soft target passed, ceiling not hit
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
  $th = Get-FileSizeThresholds $path
  if ($count -le $th.Warn) { continue }
  if ($count -le $th.Block) { [void]$warnings.Add([pscustomobject]@{ lines = $count; added = $count; path = $path }); continue }
  [void]$violations.Add([pscustomobject]@{ lines = $count; added = $count; path = $path })
}

foreach ($v in ($violations | Sort-Object lines -Descending)) {
  Write-Output ("VIOLATION {0} lines (+{1}) {2}" -f $v.lines, $v.added, $v.path)
}
foreach ($w in ($warnings | Sort-Object lines -Descending)) {
  Write-Output ("WARN {0} lines (+{1}, over soft target -- split by a real boundary if it grows, do not compress just to pass) {2}" -f $w.lines, $w.added, $w.path)
}
Write-Output ("filesize: {0} violations, {1} warnings (warn/block prod {2}/{3}, test {4}/{5}, base {6})" -f $violations.Count, $warnings.Count, $MaxLines, $HardMaxLines, $TestFileMaxLines, $TestHardMaxLines, $BaseRef)
if ($violations.Count -gt 0 -and -not $ReportOnly) { exit 1 }
exit 0
