# Codebase-scoped census for refactor mode (references/refactor-mode.md).
#
# Runs the CLI half of the census: the language's static gates per gate-adapters.md, the
# file-size budget, and git churn. The GRAPH half (jcodemunch dead-code/extraction/coupling)
# cannot run here - jcodemunch is an MCP server with no PowerShell surface - so this script
# emits graph_half: "absent" and a Claude-side lane merges those rows in. A census that
# reports gates as measured when the tool was never installed is the exact false green this
# framework exists to stop, so an absent adapter is recorded as not_measured WITH the
# command that would have measured it - never as a zero.

[CmdletBinding()]
param(
  [string]$RepoPath = ".",
  [string]$OutputPath,
  [int]$LineBudget = 300,
  [int]$ComplexityThreshold = 15,
  [int]$DuplicateMinTokens = 50,
  [int]$ChurnDays = 90
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path -LiteralPath $RepoPath).Path
# worktrees is not optional: a checkout living inside the repo makes every file in it a
# false duplicate, which silently inflates D5 and would put phantom rows at the top of the
# refactor ledger. Caught on this script's first run against its own repo (3x Invoke-KimiK3).
#
# MATCHED AGAINST THE REPO-RELATIVE PATH, NEVER THE ABSOLUTE ONE. Matching absolute paths
# meant the repo's own location could exclude its entire contents: every Fleet worktree
# lives under ~/.codex/worktrees/, whose prefix contains both `.codex` and `worktrees`, so
# a census of any worktree silently reported zero findings on every dimension. Found
# against a real production surface - 0 oversize files reported, 67 actual, largest 2190
# lines. A refactor ledger that says "nothing to do" is the worst possible false green.
$excluded = '(^|[\\/])(node_modules|target|dist|build|\.git|\.fleet|\.claude|\.codex|worktrees|vendor|__pycache__)([\\/]|$)'

function Get-RelativePath([string]$FullPath, [string]$Root) {
  if ($FullPath.Length -le $Root.Length) { return "" }
  return $FullPath.Substring($Root.Length).TrimStart('\', '/')
}

function Test-Tool([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function New-Dimension([string]$Id, [string]$Name) {
  return [ordered]@{ id = $Id; name = $Name; status = "not_measured"; reason = ""; command = ""; findings = @() }
}

function Set-NotMeasured($Dim, [string]$Adapter, [string]$Command) {
  $Dim.status = "not_measured"
  # Names the missing ADAPTER, not "Fallow is absent" - see gate-adapters.md rule 1.
  $Dim.reason = "no adapter installed for this dimension: $Adapter"
  $Dim.command = $Command
}

# --- language detection ------------------------------------------------------
$languages = @()
if (Test-Path -LiteralPath (Join-Path $repo "package.json")) { $languages += "js-ts" }
if (Test-Path -LiteralPath (Join-Path $repo "Cargo.toml")) { $languages += "rust" }
if (@(Get-ChildItem -LiteralPath $repo -Filter "*.ps1" -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { (Get-RelativePath $_.FullName $repo) -notmatch $excluded } | Select-Object -First 1).Count -gt 0) { $languages += "powershell" }
if (-not $languages) { $languages = @("unknown") }

$d1 = New-Dimension "D1" "dead code"
$d2 = New-Dimension "D2" "duplication"
$d3 = New-Dimension "D3" "complexity"
$d4 = New-Dimension "D4" "unused dependencies"
$d5 = New-Dimension "D5" "size"

# --- D5 size: always measurable, no external tool ---------------------------
$sourceFiles = @(Get-ChildItem -LiteralPath $repo -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { (Get-RelativePath $_.FullName $repo) -notmatch $excluded -and $_.Extension -match '^\.(ts|tsx|js|jsx|rs|ps1|psm1|py|go|java|cs)$' })
$oversize = @()
foreach ($file in $sourceFiles) {
  $lines = @([IO.File]::ReadAllLines($file.FullName)).Count
  if ($lines -gt $LineBudget) {
    $oversize += [ordered]@{ path = $file.FullName.Substring($repo.Length).TrimStart('\', '/'); lines = $lines }
  }
}
$d5.status = "measured"
$d5.command = "line budget $LineBudget (built in)"
$d5.findings = @($oversize | Sort-Object { -$_.lines })

# --- D2 duplication: jscpd is the portable adapter ---------------------------
if (Test-Tool "jscpd") {
  $jscpdOut = Join-Path $repo ".fleet\census\jscpd"
  New-Item -ItemType Directory -Force -Path $jscpdOut | Out-Null
  & jscpd --min-tokens $DuplicateMinTokens --reporters json --output $jscpdOut --silent $repo 2>&1 | Out-Null
  $report = Join-Path $jscpdOut "jscpd-report.json"
  if (Test-Path -LiteralPath $report) {
    $parsed = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    $d2.status = "measured"
    $d2.command = "jscpd --min-tokens $DuplicateMinTokens"
    $d2.findings = @(@($parsed.duplicates) | ForEach-Object {
      [ordered]@{ first = $_.firstFile.name; second = $_.secondFile.name; tokens = $_.tokens }
    })
  }
  else { Set-NotMeasured $d2 "jscpd ran but wrote no report" "jscpd --min-tokens $DuplicateMinTokens" }
}
else { Set-NotMeasured $d2 "jscpd" "npx jscpd --min-tokens $DuplicateMinTokens ." }

# --- D3 complexity: lizard is the portable adapter ---------------------------
if (Test-Tool "lizard") {
  $lizardRaw = (& lizard -C $ComplexityThreshold -w $repo 2>&1 | Out-String)
  $hot = @()
  foreach ($line in ($lizardRaw -split "`r?`n")) {
    if ($line -match '^\s*(.+?):(\d+):\s*warning:\s*(.+?)\s+has\s+(\d+)\s+CCN') {
      $hot += [ordered]@{ path = $Matches[1]; line = [int]$Matches[2]; symbol = $Matches[3]; ccn = [int]$Matches[4] }
    }
  }
  $d3.status = "measured"
  $d3.command = "lizard -C $ComplexityThreshold"
  $d3.findings = @($hot | Sort-Object { -$_.ccn })
}
else { Set-NotMeasured $d3 "lizard (or rust-code-analysis for Rust)" "pip install lizard; lizard -C $ComplexityThreshold ." }

# --- D1 / D4 are language-specific -------------------------------------------
if ($languages -contains "rust") {
  if (Test-Tool "cargo") {
    $d1.status = "measured"
    $d1.command = "cargo clippy --all-targets -- -D warnings"
    $clippy = (& cargo clippy --all-targets --message-format short 2>&1 | Out-String)
    $d1.findings = @(($clippy -split "`r?`n") | Where-Object { $_ -match 'never used|never read|never constructed' })
    if (Test-Tool "cargo-machete") {
      $d4.status = "measured"
      $d4.command = "cargo machete"
      $machete = (& cargo machete 2>&1 | Out-String)
      $d4.findings = @(($machete -split "`r?`n") | Where-Object { $_ -match '^\s+\S+$' -and $_ -notmatch 'cargo-machete' })
    }
    else { Set-NotMeasured $d4 "cargo-machete" "cargo install cargo-machete; cargo machete" }
  }
  else { Set-NotMeasured $d1 "cargo (toolchain absent)" "cargo clippy --all-targets -- -D warnings" }
}
elseif ($languages -contains "js-ts") {
  if (Test-Tool "fallow") {
    $d1.status = "measured"; $d1.command = "fallow audit"
    $d4.status = "measured"; $d4.command = "fallow audit"
    $d1.findings = @("see fallow-results.json - run from the package root")
  }
  else { Set-NotMeasured $d1 "fallow" "npx fallow audit" }
}
else {
  Set-NotMeasured $d1 "jcodemunch get_dead_code_v2 (graph half, Claude-side lane)" "mcp jcodemunch get_dead_code_v2 --min-confidence 0.67"
  Set-NotMeasured $d4 "no dependency manifest detected" "n/a"
}

# --- churn: ranks the ledger; a hot complex file is a different bet ----------
$churn = @{}
$churnStatus = "measured"
Push-Location $repo
try {
  # Churn is a ranking input, not a gate: a directory with no history still gets a census.
  # git writes to stderr on a non-repo, which $ErrorActionPreference=Stop turns terminating,
  # so the whole census died on any non-git target until this was caught.
  $insideRepo = $false
  try {
    $probe = (& git rev-parse --is-inside-work-tree 2>&1 | Out-String).Trim()
    $insideRepo = ($LASTEXITCODE -eq 0 -and $probe -eq "true")
  }
  catch { $insideRepo = $false }

  if ($insideRepo) {
    $since = "--since=$ChurnDays.days.ago"
    $log = @(& git log $since --name-only --pretty=format: 2>$null) | Where-Object { $_ -and $_ -notmatch $excluded }
    foreach ($path in $log) { if ($churn.ContainsKey($path)) { $churn[$path]++ } else { $churn[$path] = 1 } }
  }
  else { $churnStatus = "not_measured: target is not a git work tree" }
}
finally { Pop-Location }

$dimensions = @($d1, $d2, $d3, $d4, $d5)
$measured = @($dimensions | Where-Object { $_.status -eq "measured" }).Count

$census = [ordered]@{
  schema_version = "1"
  repo = $repo
  languages = $languages
  graph_half = "absent"
  graph_half_reason = "jcodemunch is an MCP server with no PowerShell surface; a Claude-side lane merges dead-code/extraction/coupling rows"
  line_budget = $LineBudget
  dimensions_measured = $measured
  dimensions_total = $dimensions.Count
  dimensions = $dimensions
  churn_status = $churnStatus
  churn_top = @($churn.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 20 |
    ForEach-Object { [ordered]@{ path = $_.Key; commits = $_.Value } })
}

$json = $census | ConvertTo-Json -Depth 8
if ($OutputPath) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
  [IO.File]::WriteAllText($OutputPath, $json, (New-Object Text.UTF8Encoding($false)))
}
else {
  # Payload on stdout ONLY when there is no file to read it from; otherwise stdout carries
  # the summary alone. The two never share a stream, and neither uses stderr (PS 5.1 turns
  # a native command's stderr into terminating ErrorRecords under ErrorActionPreference=Stop).
  Write-Output $json
}

$rows = @($dimensions | ForEach-Object {
  if ($_.status -eq "measured") { "$($_.id) $($_.name): $(@($_.findings).Count)" } else { "$($_.id) $($_.name): WATCH (not measured)" }
})
if ($OutputPath) {
  Write-Host "static-gates: $measured/$($dimensions.Count) measured | $($rows -join ' | ')"
  if ($census.graph_half -eq "absent") {
    Write-Host "graph-half: ABSENT - census is incomplete until a Claude-side lane merges jcodemunch rows"
  }
}
