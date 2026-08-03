# Safety suite for the agent-runtime reaper.
#
# The reaper's dangerous path is its PROTECTION logic, not its kill loop: a bug there
# means a session kills the server it is currently talking to, or its own shell. These
# cases run in dry-run mode only - nothing is ever killed by this suite.

$ErrorActionPreference = "Stop"
$reaper = Join-Path $PSScriptRoot "Clear-StaleAgentRuntime.ps1"
$passed = 0
$failed = 0

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("fleet-reaper-test-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

function Invoke-Reaper([string[]]$ReaperArgs) {
  # Read the payload from -OutputPath, never from stdout: PS 5.1 wraps a native command's
  # stderr in ErrorRecords instead of dropping it on 2>$null, so the summary line leaks
  # into a stdout capture and breaks ConvertFrom-Json. This is what -OutputPath is for.
  $out = Join-Path $scratch ("reaper-" + [guid]::NewGuid().ToString("n") + ".json")
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reaper @ReaperArgs -OutputPath $out | Out-Null
  if (-not (Test-Path -LiteralPath $out)) { throw "reaper wrote no output file" }
  return (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json)
}

Case 'defaults to dry-run and never reports a kill' {
  $result = Invoke-Reaper @("-Name", "no-such-process-xyz")
  Assert-True ($result.mode -eq "dry-run") "default mode was $($result.mode)"
  Assert-True ($result.reaped_count -eq 0) "dry run reported $($result.reaped_count) reaped"
  Assert-True (@($result.candidates).Count -eq 0) "unknown process name produced candidates"
}

Case 'writes parseable JSON to -OutputPath, uncontaminated by the summary line' {
  $result = Invoke-Reaper @("-Name", "no-such-process-xyz")
  Assert-True ($null -ne $result.schema_version) "output file did not parse into an object with schema_version"
}

Case 'never proposes reaping itself or an ancestor' {
  # -MinAgeMinutes 0 removes the age guard, so only the ancestor protection stands between
  # the reaper and the shell running it.
  $result = Invoke-Reaper @("-Name", "powershell", "-MinAgeMinutes", "0")
  $proposed = @($result.candidates | ForEach-Object { [int]$_.Pid })

  $ancestors = @()
  $cursor = $PID
  for ($i = 0; $i -lt 32 -and $cursor -gt 0; $i++) {
    $ancestors += $cursor
    $row = Get-CimInstance Win32_Process -Filter "ProcessId = $cursor" -ErrorAction SilentlyContinue
    if (-not $row) { break }
    $cursor = [int]$row.ParentProcessId
  }
  foreach ($ancestorPid in $ancestors) {
    Assert-True ($proposed -notcontains $ancestorPid) "reaper proposed killing pid $ancestorPid, which is itself or an ancestor"
  }
}

Case 'superseded detection is opt-in' {
  # Without -IncludeSuperseded a live-parent process is never a candidate, whatever its age.
  $withoutFlag = Invoke-Reaper @("-Name", "powershell", "-MinAgeMinutes", "0")
  foreach ($candidate in @($withoutFlag.candidates)) {
    Assert-True ($candidate.Reason -notmatch "superseded") "superseded candidate appeared without -IncludeSuperseded"
  }
}

Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
