$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "Assert-FleetRepairCoverage.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("fleet-repair-coverage-newfile-" + [guid]::NewGuid().ToString("N"))
$passed = 0
$failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Case([string]$Name, [scriptblock]$Body) {
  try {
    & $Body
    $script:passed++
    Write-Host "PASS $Name"
  }
  catch {
    $script:failed++
    Write-Host "FAIL $Name - $($_.Exception.Message)"
  }
}

function New-Verdict([string]$Path, [string]$TrailerJson) {
  $nl = [Environment]::NewLine
  $body = "# Arbitration verdict" + $nl + $nl + "NO-GO residual blockers remain." + $nl + $nl + "<!-- FLEET_REQUIRED_BLOCKERS_V1" + $nl + $TrailerJson + $nl + "FLEET_REQUIRED_BLOCKERS_V1 -->" + $nl
  [IO.File]::WriteAllText($Path, $body, (New-Object Text.UTF8Encoding $false))
}

function Invoke-Coverage([string]$Verdict, [string]$Diff, [string]$Output = $null) {
  $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath, "-VerdictPath", $Verdict, "-RepairDiffPath", $Diff)
  if ($Output) { $args += @("-OutputPath", $Output) }
  $old = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $raw = & powershell.exe @args 2>&1
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $old
  }
  $text = ($raw | ForEach-Object { "$_" }) -join "`n"
  $json = $null
  try { $json = $text | ConvertFrom-Json -ErrorAction Stop } catch { }
  return [pscustomobject]@{ ExitCode = $code; Raw = $text; Json = $json }
}

function New-FileDiffFull([string]$RepoPath, [string]$BodyLine) {
  $nl = "`n"
  return @(
    "diff --git a/$RepoPath b/$RepoPath",
    "new file mode 100644",
    "index 0000000..e1e31e0",
    "--- /dev/null",
    "+++ b/$RepoPath",
    "@@ -0,0 +1,1 @@",
    "+$BodyLine"
  ) -join $nl
}

function New-FileDiffDevNullOnly([string]$RepoPath, [string]$BodyLine) {
  $nl = "`n"
  return @(
    "diff --git a/$RepoPath b/$RepoPath",
    "index 0000000..e1e31e0",
    "--- /dev/null",
    "+++ b/$RepoPath",
    "@@ -0,0 +1,1 @@",
    "+$BodyLine"
  ) -join $nl
}

try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null

  Case "removed-clause on NEW file (full shape) is N/A covered" {
    $dir = Join-Path $root "new-full"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $path = "scripts/Invoke-ShadowReplay.ps1"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B4","summary":"lanefit new-file removed","evidence":[{"path":"' + $path + '","change":"removed","pattern":"silent.success"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, (New-FileDiffFull $path 'function Invoke-ShadowReplay {}'), (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True ($run.Json.status -eq "covered") "expected covered: $($run.Raw)"
    Assert-True ($run.Json.blockers[0].evidence[0].matched -eq $true) "expected matched true"
    Assert-True ($run.Json.blockers[0].evidence[0].reason -match 'not_applicable') "expected N/A reason: $($run.Json.blockers[0].evidence[0].reason)"
  }

  Case "removed-clause on new file via --- /dev/null only is N/A" {
    $dir = Join-Path $root "new-devnull"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $path = "scripts/NewOnlyDevNull.ps1"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"devnull only","evidence":[{"path":"' + $path + '","change":"removed","pattern":"never.there"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, (New-FileDiffDevNullOnly $path 'Write-Host hello'), (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 0 -and $run.Json.status -eq "covered") "expected covered: $($run.Raw)"
    Assert-True ($run.Json.blockers[0].evidence[0].reason -match 'not_applicable') "expected N/A reason"
  }

  Case "removed-clause on MODIFIED file missing pattern stays uncovered" {
    $dir = Join-Path $root "mod-miss"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"must remove","evidence":[{"path":"scripts/x.ps1","change":"removed","pattern":"silent success"}]}]}'
    New-Verdict $verdict $trailer
    $diffText = "diff --git a/scripts/x.ps1 b/scripts/x.ps1`n--- a/scripts/x.ps1`n+++ b/scripts/x.ps1`n@@ -1,3 +1,2 @@`n keep`n-return other thing`n remaining`n"
    [IO.File]::WriteAllText($diff, $diffText, (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 1 -and $run.Json.status -eq "uncovered") "expected uncovered: $($run.Raw)"
    Assert-True ($run.Json.blockers[0].evidence[0].matched -eq $false) "expected unmatched"
    Assert-True ($run.Json.blockers[0].evidence[0].reason -eq "pattern did not match any removed line") "expected miss reason: $($run.Json.blockers[0].evidence[0].reason)"
  }

  Case "removed-clause on path NOT in diff stays uncovered" {
    $dir = Join-Path $root "absent-path"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"missing path","evidence":[{"path":"scripts/missing.ps1","change":"removed","pattern":"foo"}]}]}'
    New-Verdict $verdict $trailer
    $diffText = "diff --git a/scripts/other.ps1 b/scripts/other.ps1`n--- a/scripts/other.ps1`n+++ b/scripts/other.ps1`n@@ -1,1 +1,2 @@`n keep`n+added`n"
    [IO.File]::WriteAllText($diff, $diffText, (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 1 -and $run.Json.status -eq "uncovered") "expected uncovered: $($run.Raw)"
    Assert-True ($run.Json.blockers[0].evidence[0].reason -eq "path not present in repair diff") "expected path-absent reason"
  }

  Case "mixed blocker: added matched + removed N/A on new file is covered" {
    $dir = Join-Path $root "mixed-na"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $path = "scripts/MixedNew.ps1"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"mixed","evidence":[{"path":"' + $path + '","change":"added","pattern":"needs_gate_validation"},{"path":"' + $path + '","change":"removed","pattern":"old.dead.code"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, (New-FileDiffFull $path 'status = "needs_gate_validation"'), (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 0 -and $run.Json.status -eq "covered") "expected covered: $($run.Raw)"
    Assert-True ($run.Json.blockers[0].evidence[0].matched -eq $true) "added should match"
    Assert-True ($run.Json.blockers[0].evidence[1].matched -eq $true) "removed N/A should match"
    Assert-True ($run.Json.blockers[0].evidence[1].reason -match 'not_applicable') "removed should be N/A"
  }

  Case "helpers dot-source is cwd-independent" {
    $dir = Join-Path $root "cwd-indep"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $path = "scripts/CwdNew.ps1"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"cwd","evidence":[{"path":"' + $path + '","change":"removed","pattern":"anything"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, (New-FileDiffFull $path 'body'), (New-Object Text.UTF8Encoding $false))
    Push-Location -LiteralPath $root
    try {
      $run = Invoke-Coverage $verdict $diff
    }
    finally {
      Pop-Location
    }
    Assert-True ($run.ExitCode -eq 0 -and $run.Json.status -eq "covered") "expected covered from alt cwd: $($run.Raw)"
    Assert-True ($run.Json.blockers[0].evidence[0].reason -match 'not_applicable') "expected N/A from alt cwd"
  }

  Write-Host "$passed passed, $failed failed"
  if ($failed) { exit 1 } else { exit 0 }
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
