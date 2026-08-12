# Deterministic PowerShell-validity gate for Fleet runs. The PS analog of the tsc gate:
# focused vitest does not typecheck, and eyeballing a .ps1 against ps51-footguns does not
# RUN it -- so a syntax/tokenizer bug (the em-dash-in-a-string class) or a runtime bug a
# self-test would catch sails through a Grok handoff and lands on the orchestrator. This
# gate makes that impossible at the barrier:
#   1. Every changed/untracked .ps1 / .psm1 is AST parse-checked (catches syntax + tokenizer
#      breakage without executing anything).
#   2. Changed Test-*.ps1 suites are RUN (exit 0 required). A changed non-test Foo.ps1 whose
#      companion Test-Foo.ps1 exists runs that companion. Fail-closed on nonzero/timeout.
# Manager quotes the summary line like the Fallow/filesize lines:
#   psvalid: N parse errors, M test failures over K changed .ps1 (T tests run, base <ref>)
# Exit 1 on any parse error or test failure (unless -ReportOnly). PS5.1-safe, ASCII only.
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$BaseRef,
  [string]$RepoPath = (Get-Location).Path,
  [int]$TestTimeoutSeconds = 300,
  [switch]$ReportOnly,
  [Parameter(ParameterSetName = 'SelfTest')][switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

# --- core, unit-testable pieces (no git) ------------------------------------------------
# Parse a .ps1 with the real PowerShell parser. Returns the parse-error records (empty = clean).
function Get-PsParseError([string]$Path) {
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
  if ($null -eq $errors) { return @() }
  return @($errors)
}
# Run a Test-*.ps1 suite (or `script -SelfTest`) in a child powershell.
# Returns @{ ExitCode; Tail; TimedOut }.
function Invoke-PsTestFile([string]$Path, [int]$TimeoutSeconds, [string[]]$ExtraArgs = @()) {
  $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
  $timedOut = $false; $code = -1
  try {
    # Fleet worktrees live under a user-profile path that contains a SPACE. Start-Process with an
    # -ArgumentList ARRAY joins elements with spaces but does NOT quote them, so a spaced $Path
    # splits at the space (-File truncated mid-path). Pass ONE pre-quoted string instead; the extra flags
    # (e.g. -SelfTest) are space-free and safe to append. (Bug surfaced by fleet-clipins-20260807.)
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $Path + '"'
    if ($ExtraArgs.Count -gt 0) { $argLine = $argLine + ' ' + ($ExtraArgs -join ' ') }
    $p = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow `
      -ArgumentList $argLine `
      -RedirectStandardOutput $out -RedirectStandardError $err
    # PS gotcha: Start-Process -PassThru leaves ExitCode unpopulated unless the handle is
    # cached before the process exits. Touch .Handle so $p.ExitCode is reliable below.
    try { $null = $p.Handle } catch {}
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
      $timedOut = $true
      try { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null } catch {}
      try { [void]$p.WaitForExit(5000) } catch {}
    }
    else { $code = $p.ExitCode }
  }
  catch { return @{ ExitCode = -1; Tail = $_.Exception.Message; TimedOut = $false } }
  $text = ''
  foreach ($f in @($out, $err)) { if (Test-Path -LiteralPath $f) { $text += [IO.File]::ReadAllText($f) } }
  Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
  $tail = (@($text -split "`r?`n" | Where-Object { $_ }) | Select-Object -Last 1)
  return @{ ExitCode = $code; Tail = [string]$tail; TimedOut = $timedOut }
}
# Companion test path for a script: Foo.ps1 -> <dir>/Test-Foo.ps1. A Test-*.ps1 is its own test.
function Get-CompanionTest([string]$FullPath) {
  $name = [IO.Path]::GetFileName($FullPath)
  $dir = [IO.Path]::GetDirectoryName($FullPath)
  if ($name -like 'Test-*') { return $FullPath }
  $cand = Join-Path $dir ("Test-" + $name)
  if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
  return $null
}
# Does this script expose a `-SelfTest` switch (fleet's other self-test convention)?
function Test-SupportsSelfTest([string]$FullPath) {
  try { return ([IO.File]::ReadAllText($FullPath) -match '\[switch\]\s*\$SelfTest\b') } catch { return $false }
}

if ($SelfTest) {
  $fail = 0
  function Check([string]$n, [bool]$ok) { if ($ok) { Write-Output "PASS $n" } else { Write-Output "FAIL $n"; $script:fail++ } }
  $dir = Join-Path $env:TEMP ("psvalid-selftest-" + $PID); New-Item -ItemType Directory -Force -Path $dir | Out-Null
  # clean parses; em-dash-in-string does not
  $clean = Join-Path $dir 'Clean.ps1'; "Write-Output 'ok'" | Set-Content -LiteralPath $clean -Encoding UTF8
  Check 'clean script has no parse errors' ((Get-PsParseError $clean).Count -eq 0)
  $broken = Join-Path $dir 'Broken.ps1'
  [IO.File]::WriteAllText($broken, "Write-Output `"bad " + [char]0x2014 + " dash`"; if (`$x) { ")
  Check 'broken script reports parse errors' ((Get-PsParseError $broken).Count -gt 0)
  # passing + failing companion test execution
  $pass = Join-Path $dir 'Test-Pass.ps1'; "exit 0" | Set-Content -LiteralPath $pass -Encoding UTF8
  Check 'passing test => ExitCode 0' ((Invoke-PsTestFile $pass 60).ExitCode -eq 0)
  $failt = Join-Path $dir 'Test-Fail.ps1'; "exit 3" | Set-Content -LiteralPath $failt -Encoding UTF8
  Check 'failing test => nonzero ExitCode' ((Invoke-PsTestFile $failt 60).ExitCode -ne 0)
  # companion resolution
  $foo = Join-Path $dir 'Foo.ps1'; "Write-Output 1" | Set-Content -LiteralPath $foo -Encoding UTF8
  $tfoo = Join-Path $dir 'Test-Foo.ps1'; "exit 0" | Set-Content -LiteralPath $tfoo -Encoding UTF8
  Check 'companion of Foo.ps1 is Test-Foo.ps1' ((Get-CompanionTest $foo) -eq $tfoo)
  Check 'a Test-*.ps1 is its own companion' ((Get-CompanionTest $tfoo) -eq $tfoo)
  # -SelfTest detection + `script -SelfTest` execution
  $stScript = Join-Path $dir 'HasSelfTest.ps1'
  Set-Content -LiteralPath $stScript -Encoding UTF8 -Value @('param([switch]$SelfTest)', 'if ($SelfTest) { Write-Output ok; exit 0 }', 'exit 7')
  Check 'detects a -SelfTest switch' (Test-SupportsSelfTest $stScript)
  Check 'runs script with -SelfTest (exit 0), not bare (exit 7)' ((Invoke-PsTestFile $stScript 60 @('-SelfTest')).ExitCode -eq 0)
  # spaced path: fleet worktrees have a space in the path; the test runner must survive it
  $spaceDir = Join-Path $dir 'has space'; New-Item -ItemType Directory -Force -Path $spaceDir | Out-Null
  $spaceTest = Join-Path $spaceDir 'Test-Spaced.ps1'; "exit 0" | Set-Content -LiteralPath $spaceTest -Encoding UTF8
  Check 'runs a test from a spaced path (worktree case)' ((Invoke-PsTestFile $spaceTest 60).ExitCode -eq 0)
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  if ($fail -eq 0) { Write-Output 'Test-AssertFleetPowerShellValid: passed (9 checks)'; exit 0 }
  Write-Output "Test-AssertFleetPowerShellValid: FAILED ($fail)"; exit 1
}

# --- gate: enumerate changed + untracked .ps1/.psm1, parse-check all, run relevant tests ---
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
& git -C $RepoPath rev-parse --verify --quiet $BaseRef *> $null
if ($LASTEXITCODE -ne 0) { throw "BaseRef '$BaseRef' is not a valid committish in $RepoPath" }

function Test-IsPs([string]$p) {
  $e = [IO.Path]::GetExtension($p).ToLowerInvariant()
  return ($e -eq '.ps1' -or $e -eq '.psm1')
}
$changed = @{}
# tracked changes vs base including uncommitted work
foreach ($line in @(& git -C $RepoPath diff --name-only $BaseRef)) {
  if (-not [string]::IsNullOrWhiteSpace($line) -and (Test-IsPs $line)) { $changed[$line.Trim()] = $true }
}
# untracked files are invisible to diff --name-only (LESSONS 2026-07-29 blind-spot)
$oldEap = $ErrorActionPreference
try { $ErrorActionPreference = 'Continue'; $others = @(& git -C $RepoPath ls-files --others --exclude-standard 2>$null) }
finally { $ErrorActionPreference = $oldEap }
foreach ($line in $others) { if (-not [string]::IsNullOrWhiteSpace($line) -and (Test-IsPs $line)) { $changed[($line -replace '\\','/').Trim()] = $true } }

$parseErrors = New-Object System.Collections.ArrayList
$testFailures = New-Object System.Collections.ArrayList
$testsToRun = @{}   # dedup companion/self tests
$changedPaths = @($changed.Keys | Sort-Object)
foreach ($rel in $changedPaths) {
  $full = Join-Path $RepoPath ($rel -replace '/', '\')
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }  # deleted
  foreach ($pe in (Get-PsParseError $full)) {
    $ln = 0; try { $ln = $pe.Extent.StartLineNumber } catch {}
    [void]$parseErrors.Add([pscustomobject]@{ path = $rel; line = $ln; message = [string]$pe.Message })
  }
  # Prefer a Test-Foo.ps1 companion; else, if the script self-tests, run `script -SelfTest`.
  $companion = Get-CompanionTest $full
  if ($null -ne $companion) { $testsToRun[$companion] = @() }
  elseif (Test-SupportsSelfTest $full) { $testsToRun[$full] = @('-SelfTest') }
}
foreach ($testPath in @($testsToRun.Keys)) {
  $r = Invoke-PsTestFile $testPath $TestTimeoutSeconds $testsToRun[$testPath]
  if ($r.TimedOut) { [void]$testFailures.Add([pscustomobject]@{ path = $testPath; reason = ("timeout > {0}s" -f $TestTimeoutSeconds) }) }
  elseif ($r.ExitCode -ne 0) { [void]$testFailures.Add([pscustomobject]@{ path = $testPath; reason = ("exit {0}: {1}" -f $r.ExitCode, $r.Tail) }) }
}

foreach ($pe in $parseErrors) { Write-Output ("PARSE-ERROR {0}:{1} {2}" -f $pe.path, $pe.line, $pe.message) }
foreach ($tf in $testFailures) { Write-Output ("TEST-FAIL {0} ({1})" -f $tf.path, $tf.reason) }
Write-Output ("psvalid: {0} parse errors, {1} test failures over {2} changed .ps1 ({3} tests run, base {4})" -f `
  $parseErrors.Count, $testFailures.Count, $changedPaths.Count, $testsToRun.Count, $BaseRef)
if (($parseErrors.Count -gt 0 -or $testFailures.Count -gt 0) -and -not $ReportOnly) { exit 1 }
exit 0
