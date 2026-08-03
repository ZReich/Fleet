$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "Assert-FleetRepairCoverage.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("fleet-repair-coverage-test-" + [guid]::NewGuid().ToString("N"))
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

try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null

  Case "covered added pattern" {
    $dir = Join-Path $root "covered"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $out = Join-Path $dir "coverage.json"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"Add needs_gate_validation","evidence":[{"path":"scripts/Invoke-Grok45.ps1","change":"added","pattern":"needs_gate_validation"}]}]}'
    New-Verdict $verdict $trailer
    $diffText = "diff --git a/scripts/Invoke-Grok45.ps1 b/scripts/Invoke-Grok45.ps1`n--- a/scripts/Invoke-Grok45.ps1`n+++ b/scripts/Invoke-Grok45.ps1`n@@ -1,2 +1,3 @@`n keep`n+status = `"needs_gate_validation`"`n remaining`n"
    [IO.File]::WriteAllText($diff, $diffText, (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff $out
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True ($run.Json.status -eq "covered" -and $run.Json.covered_count -eq 1 -and $run.Json.uncovered_count -eq 0) "expected covered result"
    Assert-True (Test-Path -LiteralPath $out) "expected OutputPath write"
    $written = [IO.File]::ReadAllText($out) | ConvertFrom-Json
    Assert-True ($written.status -eq "covered") "written coverage status"
  }

  Case "uncovered missing pattern" {
    $dir = Join-Path $root "uncovered"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"Must add salvage status","evidence":[{"path":"scripts/Invoke-Grok45.ps1","change":"added","pattern":"needs_gate_validation"}]}]}'
    New-Verdict $verdict $trailer
    $diffText = "diff --git a/scripts/Invoke-Grok45.ps1 b/scripts/Invoke-Grok45.ps1`n--- a/scripts/Invoke-Grok45.ps1`n+++ b/scripts/Invoke-Grok45.ps1`n@@ -1,2 +1,3 @@`n keep`n+status = `"ok`"`n remaining`n"
    [IO.File]::WriteAllText($diff, $diffText, (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 1) "expected exit 1: $($run.Raw)"
    Assert-True ($run.Json.status -eq "uncovered" -and $run.Json.uncovered_count -eq 1) "expected uncovered"
    Assert-True ($run.Json.blockers[0].evidence[0].matched -eq $false) "evidence unmatched"
  }

  Case "malformed trailer" {
    $dir = Join-Path $root "malformed"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    [IO.File]::WriteAllText($verdict, "NO-GO without trailer`n", (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected invalid trailer exit 2"
  }

  Case "invalid regex pattern" {
    $dir = Join-Path $root "bad-regex"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"bad regex","evidence":[{"path":"a.txt","change":"added","pattern":"(unclosed"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected invalid regex exit 2: $($run.Raw)"
  }

  Case "invalid path traversal" {
    $dir = Join-Path $root "path-traversal"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"escape","evidence":[{"path":"../secret.txt","change":"touched"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected invalid path exit 2: $($run.Raw)"
  }

  Case "duplicate blocker ids" {
    $dir = Join-Path $root "dup-ids"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"one","evidence":[{"path":"a.txt","change":"touched"}]},{"id":"B1","summary":"two","evidence":[{"path":"b.txt","change":"touched"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected duplicate id exit 2: $($run.Raw)"
  }

  Case "removed-line evidence" {
    $dir = Join-Path $root "removed"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"delete silent success","evidence":[{"path":"scripts/x.ps1","change":"removed","pattern":"silent success"}]}]}'
    New-Verdict $verdict $trailer
    $diffText = "diff --git a/scripts/x.ps1 b/scripts/x.ps1`n--- a/scripts/x.ps1`n+++ b/scripts/x.ps1`n@@ -1,3 +1,2 @@`n keep`n-return silent success`n remaining`n"
    [IO.File]::WriteAllText($diff, $diffText, (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 0 -and $run.Json.status -eq "covered") "expected removed match: $($run.Raw)"
  }

  Case "touched-file evidence" {
    $dir = Join-Path $root "touched"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"touch SKILL","evidence":[{"path":"SKILL.md","change":"touched"}]}]}'
    New-Verdict $verdict $trailer
    $diffText = "diff --git a/SKILL.md b/SKILL.md`n--- a/SKILL.md`n+++ b/SKILL.md`n@@ -1,2 +1,3 @@`n title`n+needs_gate_validation docs`n"
    [IO.File]::WriteAllText($diff, $diffText, (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 0 -and $run.Json.status -eq "covered") "expected touched match: $($run.Raw)"
  }

  Case "catastrophic regex timeout is invalid" {
    $dir = Join-Path $root "regex-timeout"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"hostile regex","evidence":[{"path":"a.txt","change":"added","pattern":"(a+)+$"}]}]}'
    New-Verdict $verdict $trailer
    $hostile = ("a" * 40) + "b"
    $diffText = "diff --git a/a.txt b/a.txt`n--- a/a.txt`n+++ b/a.txt`n@@ -1,1 +1,2 @@`n keep`n+$hostile`n"
    [IO.File]::WriteAllText($diff, $diffText, (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected regex timeout invalid exit 2: $($run.Raw)"
    Assert-True ($run.Raw -match "timed out|RegexMatchTimeoutException") "expected timeout error text: $($run.Raw)"
  }

  Case "scalar required_blockers rejected" {
    $dir = Join-Path $root "scalar-blockers"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":{"id":"B1","summary":"scalar","evidence":[{"path":"a.txt","change":"touched"}]}}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected scalar blockers exit 2: $($run.Raw)"
    Assert-True ($run.Raw -match "required_blockers must be an array") "expected array message: $($run.Raw)"
  }

  Case "scalar evidence rejected" {
    $dir = Join-Path $root "scalar-evidence"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"scalar evidence","evidence":{"path":"a.txt","change":"touched"}}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected scalar evidence exit 2: $($run.Raw)"
  }

  Case "backslash path rejected" {
    $dir = Join-Path $root "backslash-path"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"backslash","evidence":[{"path":"scripts\\x.ps1","change":"touched"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/scripts/x.ps1 b/scripts/x.ps1`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected backslash path exit 2: $($run.Raw)"
    Assert-True ($run.Raw -match "path must be normalized") "expected normalized path message: $($run.Raw)"
  }

  Case "drive path rejected" {
    $dir = Join-Path $root "drive-path"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"drive","evidence":[{"path":"C:/secret.txt","change":"touched"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected drive path exit 2: $($run.Raw)"
    Assert-True ($run.Raw -match "path must be normalized") "expected normalized path message: $($run.Raw)"
  }

  Case "rooted absolute path rejected" {
    $dir = Join-Path $root "rooted-path"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"rooted","evidence":[{"path":"/etc/passwd","change":"touched"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected rooted path exit 2: $($run.Raw)"
    Assert-True ($run.Raw -match "path must be normalized") "expected normalized path message: $($run.Raw)"
  }

  Case "touched evidence with pattern rejected" {
    $dir = Join-Path $root "touched-pattern"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"touched pattern","evidence":[{"path":"a.txt","change":"touched","pattern":"should-not-be-here"}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected touched+pattern exit 2: $($run.Raw)"
    Assert-True ($run.Raw -match "pattern must be omitted for change=touched") "expected touched pattern message: $($run.Raw)"
  }

  Case "touched-with-null-pattern" {
    $dir = Join-Path $root "touched-with-null-pattern"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $verdict = Join-Path $dir "verdict.md"
    $diff = Join-Path $dir "repair.diff"
    $trailer = '{"schema_version":"1","required_blockers":[{"id":"B1","summary":"touched null pattern","evidence":[{"path":"a.txt","change":"touched","pattern":null}]}]}'
    New-Verdict $verdict $trailer
    [IO.File]::WriteAllText($diff, "diff --git a/a.txt b/a.txt`n+ok`n", (New-Object Text.UTF8Encoding $false))
    $run = Invoke-Coverage $verdict $diff
    Assert-True ($run.ExitCode -eq 2 -and $run.Json.status -eq "invalid") "expected touched+null pattern exit 2: $($run.Raw)"
    Assert-True ($run.Raw -match "pattern must be omitted for change=touched") "expected touched null pattern message: $($run.Raw)"
  }

  Write-Host "$passed passed, $failed failed"
  if ($failed) { exit 1 } else { exit 0 }
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
