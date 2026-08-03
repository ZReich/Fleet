#requires -Version 5
<#
.SYNOPSIS
  Publish the sanitized Fleet skill package to the PUBLIC GitHub repo.

.DESCRIPTION
  The dev repo (this checkout) is private: it carries hardcoded user-profile paths,
  benchmarks, and working notes that must never go public. This script builds the
  sanitized `skill/` package the public repo expects, scrubs the private user path to
  $env:USERPROFILE, excludes dev-only artifacts, and runs a FAIL-CLOSED gate that aborts
  the whole publish if any private token survives. Hand-written public files (README.md,
  skill/INSTALL.md, skill/examples/*, the package .gitignore) are preserved untouched.

  Default run is a DRY RUN: it stages + scrubs + gates + shows the diff, but never
  commits or pushes. Pass -Push to actually commit (as the public noreply identity) and
  push to origin. Pass -SelfTest to run the scrub/gate unit checks (no git, no network).

.EXAMPLE
  ./Publish-Public.ps1                      # dry run: show exactly what would go public
  ./Publish-Public.ps1 -Push -Message "..." # commit + push for real
  ./Publish-Public.ps1 -SelfTest            # unit-check the scrub + gate logic
#>
param(
  [string]$PublicRemote  = 'https://github.com/ZReich/Fleet.git',
  [string]$Branch        = 'main',
  [string]$WorkDir       = (Join-Path $env:TEMP 'fleet-public-publish'),
  [string]$Message       = 'skill: sync sanitized package from dev repo',
  [string[]]$ForbiddenExtra = @(),
  [string]$AuthorName    = 'ZReich',
  [string]$AuthorEmail   = '61559319+ZReich@users.noreply.github.com',
  [switch]$Push,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# --- private tokens, built dynamically so this file never contains them literally
#     (otherwise the gate below would flag the publisher itself) -----------------
$script:PrivateName = 'Zach' + ' ' + 'Reichert'
$script:UsersSeg    = 'Users'
$script:FindFwd     = "C:/$($script:UsersSeg)/$($script:PrivateName)"   # forward-slash user path
$script:FindBack    = "C:\$($script:UsersSeg)\$($script:PrivateName)"   # back-slash user path

function Convert-FleetPublicText {
  # Literal (non-regex) replacement of the private user path with $env:USERPROFILE,
  # both slash conventions. String.Replace is literal, so no $-escaping surprises.
  param([Parameter(Mandatory)][string]$Text)
  return $Text.Replace($script:FindFwd, '$env:USERPROFILE').Replace($script:FindBack, '$env:USERPROFILE')
}

function Find-FleetForbiddenTokens {
  # Returns a list of "file:line: text" for every line matching a forbidden pattern.
  # Empty list == clean. This is the fail-closed gate.
  param([Parameter(Mandatory)][string[]]$Files, [string[]]$Extra = @())
  $patterns = @(
    [regex]::Escape($script:PrivateName),      # the private name in any context
    ('C:[\\/]' + $script:UsersSeg + '[\\/]')   # any absolute users-profile path (should be scrubbed away)
  )
  foreach ($x in $Extra) { if ($x) { $patterns += [regex]::Escape($x) } }
  $hits = New-Object System.Collections.Generic.List[string]
  foreach ($f in $Files) {
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($f)) {
      $n++
      foreach ($p in $patterns) {
        if ($line -match $p) { [void]$hits.Add(('{0}:{1}: {2}' -f $f, $n, $line.Trim())); break }
      }
    }
  }
  return $hits
}

# --- publish subset rules -------------------------------------------------------
$script:ExcludePrefixes = @('BENCH-', 'Microsoft/', 'docs/', 'reviews/')
$script:ExcludeExact    = @('.gitignore', 'adapters/claude/BENCH-grok45.md', 'adapters/claude/LESSONS.md')
$script:ExcludeSuffixes = @('.original.md')

function Test-FleetManaged {
  # Is this dev-repo-relative tracked path part of the published skill/ package?
  param([Parameter(Mandatory)][string]$Rel)
  foreach ($p in $script:ExcludePrefixes) { if ($Rel.StartsWith($p)) { return $false } }
  foreach ($e in $script:ExcludeExact)    { if ($Rel -eq $e)         { return $false } }
  foreach ($s in $script:ExcludeSuffixes) { if ($Rel.EndsWith($s))   { return $false } }
  return $true
}

function Test-FleetPublicOnly {
  # Hand-written public files under skill/ that the publisher must NEVER overwrite/delete.
  param([Parameter(Mandatory)][string]$SkillRel)
  if ($SkillRel -eq '.gitignore') { return $true }
  if ($SkillRel -eq 'INSTALL.md') { return $true }
  if ($SkillRel.StartsWith('examples/')) { return $true }
  return $false
}

function Invoke-SelfTest {
  $fail = 0
  function Check($cond, $msg) { if ($cond) { Write-Host "PASS $msg" } else { Write-Host "FAIL $msg"; $script:sfFail++ } }
  $script:sfFail = 0

  # scrub both slash forms
  $inFwd  = "path `"$($script:FindFwd)/.codex/x`" end"
  $inBack = "path `"$($script:FindBack)\.codex\x`" end"
  Check ((Convert-FleetPublicText $inFwd)  -eq 'path "$env:USERPROFILE/.codex/x" end') 'scrub forward-slash user path'
  Check ((Convert-FleetPublicText $inBack) -eq 'path "$env:USERPROFILE\.codex\x" end') 'scrub back-slash user path'
  Check ((Convert-FleetPublicText 'no private path here') -eq 'no private path here')   'scrub leaves clean text untouched'

  # gate: dirty file trips, clean file passes
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('flt-selftest-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    $dirty = Join-Path $tmp 'dirty.txt'; $clean = Join-Path $tmp 'clean.txt'
    [IO.File]::WriteAllText($dirty, "ok`nread $($script:FindFwd)/.codex now`nok")
    [IO.File]::WriteAllText($clean, "ok`nread `$env:USERPROFILE/.codex now`nok")
    $dirtyHits = Find-FleetForbiddenTokens -Files @($dirty)
    $cleanHits = Find-FleetForbiddenTokens -Files @($clean)
    Check ($dirtyHits.Count -ge 1) 'gate flags a planted private path'
    Check ($cleanHits.Count -eq 0) 'gate passes a scrubbed file'
    # extra-forbidden token
    [IO.File]::WriteAllText($clean, "mentions AcmeCorp secretly")
    $extraHits = Find-FleetForbiddenTokens -Files @($clean) -Extra @('AcmeCorp')
    Check ($extraHits.Count -ge 1) 'gate honors -ForbiddenExtra tokens'
  } finally { Remove-Item -Recurse -Force $tmp }

  # managed/public-only routing
  Check (Test-FleetManaged 'scripts/Invoke-Sol.ps1')            'scripts are managed'
  Check (Test-FleetManaged 'SKILL.md')                          'SKILL.md is managed'
  Check (-not (Test-FleetManaged 'BENCH-lanes.jsonl'))          'BENCH files excluded'
  Check (-not (Test-FleetManaged 'reviews/x/brief.md'))         'reviews excluded'
  Check (-not (Test-FleetManaged 'adapters/claude/LESSONS.md')) 'adapter LESSONS excluded'
  Check (Test-FleetPublicOnly 'INSTALL.md')                     'INSTALL.md is public-only'
  Check (Test-FleetPublicOnly 'examples/x.json')                'examples are public-only'
  Check (-not (Test-FleetPublicOnly 'SKILL.md'))                'SKILL.md is not public-only'

  if ($script:sfFail -gt 0) { Write-Host "$($script:sfFail) failed"; exit 1 }
  Write-Host 'all self-tests passed'; exit 0
}

if ($SelfTest) { Invoke-SelfTest }

# --- main publish flow ----------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "dev repo   : $RepoRoot"
Write-Host "public repo: $PublicRemote ($Branch)"
Write-Host "mode       : $(if ($Push) { 'PUSH (commit + push)' } else { 'DRY RUN (no commit, no push)' })"

# fresh clone of the public repo
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
& git clone --quiet --depth 1 --branch $Branch $PublicRemote $WorkDir
if ($LASTEXITCODE -ne 0) { throw "clone failed: $PublicRemote ($Branch)" }
$skillDir = Join-Path $WorkDir 'skill'
if (-not (Test-Path $skillDir)) { throw "public repo has no skill/ directory - layout changed, aborting" }

# clear the managed part of skill/ (keep hand-written public-only files).
# Enumerate location-relative (-Name) so an 8.3 short TEMP path can't misalign the
# public-only check and delete INSTALL.md / examples/.
Push-Location $skillDir
try { $existing = @(Get-ChildItem -Recurse -File -Name) } finally { Pop-Location }
foreach ($skillRel in $existing) {
  $rel = $skillRel.Replace('\','/')
  if (-not (Test-FleetPublicOnly $rel)) { Remove-Item -Force -LiteralPath (Join-Path $skillDir $skillRel) }
}

# copy the sanitized dev subset into skill/
$tracked = & git -C $RepoRoot ls-files
if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $RepoRoot" }
$copied = 0
foreach ($rel in $tracked) {
  if (-not (Test-FleetManaged $rel)) { continue }
  $src = Join-Path $RepoRoot ($rel -replace '/', '\')
  if (-not (Test-Path -LiteralPath $src)) { continue }
  $dst = Join-Path $skillDir ($rel -replace '/', '\')
  $dstParent = Split-Path -Parent $dst
  if (-not (Test-Path $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
  $text = [IO.File]::ReadAllText($src)
  [IO.File]::WriteAllText($dst, (Convert-FleetPublicText $text), (New-Object Text.UTF8Encoding($false)))
  $copied++
}
Write-Host "copied $copied sanitized files into skill/"

# FAIL-CLOSED GATE: scan the whole tree (except .git) for surviving private tokens
$scan = Get-ChildItem -Recurse -File -LiteralPath $WorkDir |
  Where-Object { $_.FullName -notmatch '\\\.git\\' } |
  ForEach-Object { $_.FullName }
$hits = Find-FleetForbiddenTokens -Files $scan -Extra $ForbiddenExtra
if ($hits.Count -gt 0) {
  Write-Host ''
  Write-Host "PRIVATE TOKEN LEAK - publish ABORTED. $($hits.Count) offending line(s):" -ForegroundColor Red
  $hits | Select-Object -First 40 | ForEach-Object { Write-Host "  $_" }
  Write-Host "staging left at $WorkDir for inspection; nothing was committed or pushed."
  exit 1
}
Write-Host "gate: clean (0 private tokens across $($scan.Count) files)"

& git -C $WorkDir add -A
$status = & git -C $WorkDir status --porcelain
if (-not $status) { Write-Host 'nothing to publish - public repo already matches the sanitized dev package.'; exit 0 }

Write-Host ''
Write-Host '=== changes staged for the public repo ==='
& git -C $WorkDir diff --cached --stat

if (-not $Push) {
  Write-Host ''
  Write-Host "DRY RUN complete. Review the diff above, then re-run with -Push to publish."
  Write-Host "staging at $WorkDir"
  exit 0
}

& git -C $WorkDir -c "user.name=$AuthorName" -c "user.email=$AuthorEmail" commit -m $Message
if ($LASTEXITCODE -ne 0) { throw 'commit failed' }
& git -C $WorkDir push origin $Branch
if ($LASTEXITCODE -ne 0) { throw 'push failed (check GitHub credentials for the public remote)' }
Write-Host ''
Write-Host "published to $PublicRemote ($Branch) as $AuthorName <$AuthorEmail>"
