# Runs every offline Fleet suite and prints ONE summary line with a denominator.
#
# Why this exists: the suites were self-registering only in the sense that a human had to
# remember them. Nothing enumerated scripts/Test-*.ps1, so a suite that was never invoked
# looked exactly like a suite that passed - the same false-green class the review packet's
# "status=passed with zero commands" check exists to stop. Discovery is a glob on purpose:
# a new Test-*.ps1 is picked up without editing a list that can drift.
#
# Not covered here: per-suite timeouts. A hanging suite hangs the run (visible, not silent).

param(
  # Substring filters; omit to run everything. Accepts a comma-joined string as well as an
  # array: a PS array does not survive the `powershell -File` boundary (it splats
  # positionally), the same trap the wrappers document for -ArtifactFile.
  [string[]]$Match,
  [switch]$ListOnly
)

$ErrorActionPreference = "Stop"
if ($Match) { $Match = @($Match | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }

function Test-IsSuite([string]$Path) {
  # A suite EXECUTES cases; a library only defines functions for others to dot-source
  # (Test-GrokBenchmarkRecord.ps1). Running a library exits 0 having asserted nothing,
  # which would inflate the pass count with work that never happened.
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
    return -not $trimmed.StartsWith("function ")
  }
  return $false
}

$suites = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "Test-*.ps1" -File |
  Where-Object { $_.FullName -ne $PSCommandPath } |
  Sort-Object Name)
if ($Match) { $suites = @($suites | Where-Object { $name = $_.Name; ($Match | Where-Object { $name -like "*$_*" }).Count -gt 0 }) }

$run = 0; $passed = 0; $failed = 0; $skipped = 0
$failures = @()

foreach ($suite in $suites) {
  if (-not (Test-IsSuite $suite.FullName)) {
    $skipped++
    Write-Host "SKIP  $($suite.Name) (library, defines functions only)"
    continue
  }
  if ($ListOnly) { $run++; Write-Host "WOULD RUN $($suite.Name)"; continue }

  $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $suite.FullName 2>&1 | Out-String)
  $code = $LASTEXITCODE
  $run++
  # Prefer the suite's own denominator line over a bare exit code.
  $summary = ($output -split "`r?`n" | Where-Object { $_ -match '\d+\s+passed,\s*\d+\s+failed' } | Select-Object -Last 1)
  if (-not $summary) { $summary = "(no denominator line)" }
  # A suite that PRINTS failures and still exits 0 is a false green: found live on the
  # first full run (Test-FleetExternalLanes reported "2 passed, 1 failed", exit 0). Trust
  # the denominator over the exit code whenever the two disagree.
  if ($summary -match '(\d+)\s+failed' -and [int]$Matches[1] -gt 0 -and $code -eq 0) {
    $code = 1
    $summary = "$($summary.Trim())  <-- suite exited 0 despite reporting failures"
  }
  if ($code -eq 0) {
    $passed++
    Write-Host "PASS  $($suite.Name) - $($summary.Trim())"
  }
  else {
    $failed++
    $failures += $suite.Name
    Write-Host "FAIL  $($suite.Name) - $($summary.Trim())"
    foreach ($line in @($output -split "`r?`n" | Where-Object { $_ -match '^(FAIL|ASSERTION FAILED)' } | Select-Object -First 5)) {
      Write-Host "        $($line.Trim())"
    }
  }
}

Write-Host ""
# A run that executed nothing is not a pass. Reported ok on `run: 0` once, which is the
# zero-denominator green this runner was written to stop - a filter that matches no suite
# must fail loudly, not congratulate itself.
$emptyRun = ($run -eq 0)
$verdict = if ($failed -or $emptyRun) { "FAILED" } else { "ok" }
Write-Host "fleet-suites: run: $run | passed: $passed | failed: $failed | skipped: $skipped | verdict: $verdict"
if ($emptyRun) { Write-Host "no suites ran$(if ($Match) { " - filter matched nothing: $($Match -join ', ')" })" }
if ($failures) { Write-Host "failing suites: $($failures -join ', ')" }
if ($failed -or $emptyRun) { exit 1 } else { exit 0 }
