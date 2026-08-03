[CmdletBinding()]
param(
  [ValidateSet("All","Wrapper","WrapperSlow","Runner")][string]$Phase = "All",
  [string]$CasePattern = "."
)

$ErrorActionPreference = "Stop"
$wrapper = Join-Path $PSScriptRoot "Invoke-Grok45.ps1"
# Sibling of this skill checkout (skills/fleet → skills/grok-build-audit). Worktrees under
# fleet-worktrees/ are not siblings of the audit skill, so fall back to the canonical install.
$runner = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "grok-build-audit\scripts\start-grok-build-audit.ps1"
if (-not (Test-Path -LiteralPath $runner)) {
  $runner = Join-Path $env:USERPROFILE ".codex\skills\grok-build-audit\scripts\start-grok-build-audit.ps1"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ("fleet-grok-test-" + [guid]::NewGuid().ToString("n"))
$fakeHome = Join-Path $temp "home"
$fakeLog = Join-Path $fakeHome "logs\unified.jsonl"
$fakePs1 = Join-Path $temp "fake-grok.ps1"
$fakeCmd = Join-Path $temp "grok.cmd"
$childPidFile = Join-Path $temp "child.pid"
$wrapperSource = Join-Path $temp "wrapper-source"
$wrapperWorktree = Join-Path $temp "wrapper-worktree"
$passed = 0
$failed = 0
$skipped = 0
  $testEnvNames = @("GROK_HOME", "FLEET_GROK_EXECUTABLE", "FLEET_GROK_MODEL_LOG", "FLEET_GROK_FAKE_SCENARIO", "FLEET_GROK_CHILD_PID_FILE", "FLEET_GROK_RUN", "FLEET_GROK_WORKTREE_PARENT", "NO_COLOR", "FORCE_COLOR")
$originalEnv = @{}
foreach ($name in $testEnvNames) { $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
  function Quote-TestArgs([string[]]$Tokens) {
    ($Tokens | ForEach-Object {
      $token = [string]$_
      if ($token.Length -eq 0) { '""' }
      elseif ($token -notmatch '[\s"]') { $token }
      else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
    }) -join " "
  }
  function Run-Wrapper([string]$Scenario, [int]$Timeout = 10, [switch]$Auto, [switch]$Review, [switch]$ReadOnly, [string]$Mode = "json", [int]$MinimumAuditPasses = 1, [int]$MaxTurns = 0, [switch]$Lean, [switch]$Memory, [switch]$Subagents, [string]$Resume = "", [string]$Effort = "high", [int]$FirstTurnTimeout = -1, [int]$HeartbeatSeconds = -1) {
  $env:FLEET_GROK_FAKE_SCENARIO = $Scenario
  $args = @("-NoProfile", "-NoLogo", "-ExecutionPolicy", "Bypass", "-File", $wrapper, "-Prompt", "offline contract", "-WorkingDirectory", $wrapperWorktree, "-Mode", $Mode, "-TimeoutSeconds", [string]$Timeout, "-MinimumAuditPasses", [string]$MinimumAuditPasses)
  if ($HeartbeatSeconds -ge 1) { $args += @("-HeartbeatSeconds", [string]$HeartbeatSeconds) }
  if ($Auto) { $args += @("-BashCapability", "Auto", "-IsolatedWorktree") }
    if ($Review) { $args += "-Review" }
    if ($ReadOnly) { $args += "-ReadOnly" }
    if ($MaxTurns -gt 0) { $args += @("-MaxTurns", [string]$MaxTurns) }
    if ($Lean) { $args += "-LeanSystemPrompt" }
    if ($Memory) { $args += "-ExperimentalMemory" }
    if ($Subagents) { $args += "-EnableSubagents" }
  if ($Resume) { $args += @("-ResumeSessionId", $Resume) }
  if ($FirstTurnTimeout -ge 0) { $args += @("-FirstTurnTimeoutSeconds", [string]$FirstTurnTimeout) }
  $args += @("-Effort", $Effort)
  $old = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    # .NET Process avoids PS 5.1 ErrorRecord wrapping of native stderr on non-zero exit.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = Quote-TestArgs $args
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $null = $proc.WaitForExit(120000)
    $rawOut = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { "" }
    $rawErr = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { "" }
    $code = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
    if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
    $proc.Dispose()
  } finally { $ErrorActionPreference = $old }
  [pscustomobject]@{ ExitCode = $code; Raw = $rawOut.TrimEnd(); Stderr = $rawErr.TrimEnd() }
}
function Case([string]$Name, [scriptblock]$Body) {
  if ($Name -notmatch $CasePattern) { $script:skipped++; return }
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Skip([string]$Name, [string]$Reason) { $script:skipped++; Write-Host "SKIP $Name - $Reason" }

try {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fakeLog) | Out-Null
  New-Item -ItemType Directory -Force -Path $wrapperSource | Out-Null
  & git -C $wrapperSource init | Out-Null
  & git -C $wrapperSource config user.name test
  & git -C $wrapperSource config user.email test@example.invalid
  [IO.File]::WriteAllText((Join-Path $wrapperSource "seed.txt"), "seed")
  & git -C $wrapperSource add .
  & git -C $wrapperSource commit -m baseline | Out-Null
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & git -C $wrapperSource worktree add --detach $wrapperWorktree HEAD 2>$null | Out-Null
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  $expiry = [datetimeoffset]::UtcNow.AddHours(1).ToString("o")
  [IO.File]::WriteAllText((Join-Path $fakeHome "auth.json"), "{`"test`":{`"expires_at`":`"$expiry`"}}")
  [IO.File]::WriteAllText($fakeCmd, "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fakePs1`" %*")
  [IO.File]::WriteAllText($fakePs1, @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
if ($Args -contains "--version") { Write-Output "grok 9.9.9 (fake) [stable]"; exit 0 }
$scenario = $env:FLEET_GROK_FAKE_SCENARIO
if ($scenario -eq "heartbeat-slow") { Start-Sleep -Seconds 3 }
if ($scenario -eq "timeout") {
  $child = Start-Process ping.exe -ArgumentList "-n","60","127.0.0.1" -WindowStyle Hidden -PassThru
  [IO.File]::WriteAllText($env:FLEET_GROK_CHILD_PID_FILE, [string]$child.Id)
  Start-Sleep -Seconds 5
  exit 0
}
# Wrapper Process.Start on .cmd tracks cmd.exe; log pid must match that parent, not $PID.
if ($scenario -eq "first-turn-alive") {
  $logPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
  $sidAlive = [guid]::NewGuid().ToString("n")
  $logDirAlive = Split-Path -Parent $env:FLEET_GROK_MODEL_LOG
  New-Item -ItemType Directory -Force -Path $logDirAlive | Out-Null
  # Flush via .NET AppendAllText (not Add-Content) so deadline poll cannot race an unflushed pipeline.
  [IO.File]::AppendAllText($env:FLEET_GROK_MODEL_LOG, ((@{ sid=$sidAlive; pid=$logPid; msg="model changed"; ctx=@{model="grok-4.5"} } | ConvertTo-Json -Compress) + "`n"))
  [IO.File]::AppendAllText($env:FLEET_GROK_MODEL_LOG, ((@{ sid=$sidAlive; pid=$logPid; msg="shell.turn.tool_prep_done"; ctx=@{} } | ConvertTo-Json -Compress) + "`n"))
  Start-Sleep -Seconds 3
  Write-Output (@{ sessionId=$sidAlive; requestId="fake"; text="# Review`nAlive first turn." } | ConvertTo-Json -Compress -Depth 4)
  exit 0
}
if ($scenario -eq "first-turn-dead") {
  $logPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
  $sidDead = [guid]::NewGuid().ToString("n")
  $logDirDead = Split-Path -Parent $env:FLEET_GROK_MODEL_LOG
  New-Item -ItemType Directory -Force -Path $logDirDead | Out-Null
  [IO.File]::AppendAllText($env:FLEET_GROK_MODEL_LOG, ((@{ sid=$sidDead; pid=$logPid; msg="model changed"; ctx=@{model="grok-4.5"} } | ConvertTo-Json -Compress) + "`n"))
  Start-Sleep -Seconds 10
  exit 0
}
if ($scenario -eq "first-turn-other-pid") {
  $sidOther = [guid]::NewGuid().ToString("n")
  $logDirOther = Split-Path -Parent $env:FLEET_GROK_MODEL_LOG
  New-Item -ItemType Directory -Force -Path $logDirOther | Out-Null
  [IO.File]::AppendAllText($env:FLEET_GROK_MODEL_LOG, ((@{ sid=$sidOther; pid=1; msg="shell.turn.tool_prep_done"; ctx=@{} } | ConvertTo-Json -Compress) + "`n"))
  [IO.File]::AppendAllText($env:FLEET_GROK_MODEL_LOG, ((@{ sid=$sidOther; pid=1; msg="shell.turn.inference_done"; ctx=@{model_elapsed_ms=100;prompt_tokens=1;cached_prompt_tokens=0;completion_tokens=1;reasoning_tokens=0} } | ConvertTo-Json -Compress) + "`n"))
  Start-Sleep -Seconds 10
  exit 0
}
if ($scenario -eq "malformed") { Write-Output "not json"; exit 0 }
if ($scenario -eq "empty-output") {
  $sidEmpty = [guid]::NewGuid().ToString("n")
  $logDirEmpty = Split-Path -Parent $env:FLEET_GROK_MODEL_LOG
  New-Item -ItemType Directory -Force -Path $logDirEmpty | Out-Null
  @{ sid=$sidEmpty; msg="model changed"; ctx=@{model="grok-4.5"} } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FLEET_GROK_MODEL_LOG
  Write-Output (@{ sessionId=$sidEmpty; requestId="fake"; text=""; structuredOutput=$null } | ConvertTo-Json -Compress -Depth 4)
  exit 0
}
if ($scenario -eq "review-markdown") {
  if ($Args -contains "--json-schema") { exit 41 }
  $promptIndexRm = [Array]::IndexOf($Args, "--prompt-file")
  $promptTextRm = [IO.File]::ReadAllText($Args[$promptIndexRm + 1])
  if ($promptTextRm -match "Return only the JSON object" -or $promptTextRm -notmatch "free-form Markdown") { exit 42 }
  $sidRm = [guid]::NewGuid().ToString("n")
  $logDirRm = Split-Path -Parent $env:FLEET_GROK_MODEL_LOG
  New-Item -ItemType Directory -Force -Path $logDirRm | Out-Null
  @{ sid=$sidRm; msg="model changed"; ctx=@{model="grok-4.5"} } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FLEET_GROK_MODEL_LOG
  Write-Output (@{ sessionId=$sidRm; requestId="fake"; text="# Review`nFinding: none material." } | ConvertTo-Json -Compress -Depth 4)
  exit 0
}
if ($scenario -eq "review-empty") {
  if ($Args -contains "--json-schema") { exit 41 }
  $sidRe = [guid]::NewGuid().ToString("n")
  $logDirRe = Split-Path -Parent $env:FLEET_GROK_MODEL_LOG
  New-Item -ItemType Directory -Force -Path $logDirRe | Out-Null
  @{ sid=$sidRe; msg="model changed"; ctx=@{model="grok-4.5"} } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FLEET_GROK_MODEL_LOG
  Write-Output (@{ sessionId=$sidRe; requestId="fake"; text="   " } | ConvertTo-Json -Compress -Depth 4)
  exit 0
}
if ($scenario -eq "transport-error") { [Console]::Error.WriteLine("local transport failed"); exit 32 }
if ($scenario -eq "turn-limit-error") { [Console]::Error.WriteLine("maximum turns reached"); exit 33 }
if ($scenario -eq "default-no-turn-cap" -and $Args -contains "--max-turns") { exit 23 }
if ($scenario -eq "lean-memory-subagents") {
  $promptIndex = [Array]::IndexOf($Args, "--system-prompt-override")
  if ($promptIndex -lt 0) { exit 25 }
  if ($promptIndex + 1 -ge $Args.Count -or $Args[$promptIndex + 1] -notmatch "Apply Ponytail directly") { exit 34 }
  if ($Args -notcontains "--experimental-memory") { [Console]::Error.WriteLine(($Args -join '|')); exit 26 }
  if ($Args -contains "--no-subagents") { exit 27 }
  if ($env:FLEET_GROK_RUN -ne "1") { exit 28 }
}
if ($scenario -eq "resume" -and ($Args -notcontains "--resume" -or $Args -notcontains "resume-test")) { exit 29 }
if ($scenario -eq "explicit-turn-cap") {
  $turnIndex = [Array]::IndexOf($Args, "--max-turns")
  if ($turnIndex -lt 0 -or $Args[$turnIndex + 1] -ne "37") { exit 24 }
}
if ($scenario -eq "unbalanced-json") { Write-Output '{"sessionId":"broken","structuredOutput":{'; exit 0 }
if ($scenario -eq "stage") { [IO.File]::WriteAllText((Join-Path (Get-Location) "staged.txt"), "forbidden"); & git add staged.txt }
if ($scenario -eq "trailing") { [IO.File]::WriteAllText((Join-Path (Get-Location) "bad.txt"), "bad `t`n") }
  if ($scenario -eq "ignored-write") { [IO.File]::WriteAllText((Join-Path (Get-Location) ".ignored-secret"), "mutated") }
  if ($scenario -eq "generated-output") { New-Item -ItemType Directory -Force -Path (Join-Path (Get-Location) "node_modules\cache") | Out-Null; [IO.File]::WriteAllText((Join-Path (Get-Location) "node_modules\cache\result.txt"), "generated") }
if ($scenario -eq "binary") { [IO.File]::WriteAllBytes((Join-Path (Get-Location) "binary.bin"), [byte[]](0,1,2,0,255)) }
if ($scenario -eq "big-diff") { [IO.File]::WriteAllText((Join-Path (Get-Location) "big.txt"), ((1..10 | ForEach-Object { "line$_" }) -join "`n")) }
if ($scenario -eq "out-of-scope") { [IO.File]::WriteAllText((Join-Path (Get-Location) "outside.txt"), "outside") }
if ($scenario -eq "audit-mismatch") { [IO.File]::WriteAllText((Join-Path (Get-Location) "actual.txt"), "actual") }
if ($scenario -eq "forbidden-artifact") { New-Item -ItemType Directory -Path (Join-Path (Get-Location) "mcps") -Force | Out-Null; [IO.File]::WriteAllText((Join-Path (Get-Location) "mcps\x.txt"), "x") }
$isBashProbe = $Args -contains "run_terminal_cmd,task,get_task_output,kill_task"
if ($scenario -eq "windows-shell-contract" -and -not $isBashProbe) {
  if ($env:NO_COLOR -or $env:FORCE_COLOR) { exit 30 }
  $promptIndex = [Array]::IndexOf($Args, "--prompt-file")
  $promptText = [IO.File]::ReadAllText($Args[$promptIndex + 1])
  if ($promptText -notmatch "Windows PowerShell 5.1" -or $promptText -notmatch "Never use Bash heredocs" -or $promptText -notmatch "Never use node -e" -or $promptText -notmatch "search_replace" -or $promptText -notmatch "helper scripts/temp source files" -or $promptText -notmatch "Terra/Codex owns full suites") { exit 31 }
}
if ($isBashProbe) {
  if ($scenario -eq "bash-schema") { [Console]::Error.WriteLine("auto_background_on_timeout requires enabled_background"); exit 1 }
  if ($scenario -eq "bash-transient") { [Console]::Error.WriteLine("temporary network failure"); exit 2 }
  $promptIndex = [Array]::IndexOf($Args, "--prompt-file")
  $probeText = [IO.File]::ReadAllText($Args[$promptIndex + 1])
  $proofPath = [regex]::Match($probeText, "(?m)^PROOF_PATH=(.+)$").Groups[1].Value.Trim()
  $proofToken = [regex]::Match($probeText, "(?m)^PROOF_TOKEN=(.+)$").Groups[1].Value.Trim()
  if ($proofPath) { [IO.File]::WriteAllText($proofPath, $proofToken) }
}
$sid = [guid]::NewGuid().ToString("n")
$model = if ($scenario -eq "wrong-model") { "grok-wrong" } else { "grok-4.5" }
$logDir = Split-Path -Parent $env:FLEET_GROK_MODEL_LOG
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
if ($scenario -eq "spaced-log") {
  Add-Content -LiteralPath $env:FLEET_GROK_MODEL_LOG -Value (' { "ctx": { "model": "' + $model + '" }, "msg": "model changed", "sid": "' + $sid + '" } ')
  Add-Content -LiteralPath $env:FLEET_GROK_MODEL_LOG -Value (' { "msg": "shell.tool.exec_done", "sid": "' + $sid + '", "ctx": { "success": false } } ')
} else {
  @{ sid=$sid; msg="model changed"; ctx=@{model=$model} } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FLEET_GROK_MODEL_LOG
  @{ sid=$sid; msg="shell.turn.inference_done"; ctx=@{model_elapsed_ms=1250;prompt_tokens=500;cached_prompt_tokens=400;completion_tokens=25;reasoning_tokens=5} } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FLEET_GROK_MODEL_LOG
  @{ sid=$sid; msg="shell.tool.exec_done"; ctx=@{success=$true;elapsed_ms=250} } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FLEET_GROK_MODEL_LOG
  if ($scenario -eq "recovered-tool-error") { @{ sid=$sid; msg="shell.tool.exec_done"; ctx=@{success=$false} } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FLEET_GROK_MODEL_LOG }
}
$audit = if ($scenario -eq "missing-audit") { $null } elseif ($scenario -eq "invalid-audit") { @{ status="done" } } else {
  [object[]]$changed = @()
  if ($scenario -eq "stage") { $changed = @("staged.txt") } elseif ($scenario -eq "trailing") { $changed = @("bad.txt") } elseif ($scenario -eq "binary") { $changed=@("binary.bin") } elseif ($scenario -eq "big-diff") { $changed=@("big.txt") } elseif ($scenario -eq "out-of-scope") { $changed=@("outside.txt") } elseif ($scenario -eq "audit-mismatch") { $changed=@("claimed.txt") } elseif ($scenario -eq "forbidden-artifact") { $changed=@("mcps/x.txt") } elseif ($scenario -eq "unreviewed") {
    # Unique path each run keeps wrapper worktree isolation clean across cases.
    $xname = "x-" + [guid]::NewGuid().ToString("n") + ".txt"
    [IO.File]::WriteAllText((Join-Path (Get-Location) $xname), "x"); $changed=@($xname)
  }
  # Productive done/partial must claim the observed delta. Unique touch when no scenario write.
  # Runner suites allow plan.md; wrapper worktrees have no plan.md so use a unique path.
  if ($changed.Count -eq 0 -and $scenario -ne "blocked-no-write") {
    $planPath = Join-Path (Get-Location) "plan.md"
    if (Test-Path -LiteralPath $planPath) {
      [IO.File]::AppendAllText($planPath, "`n")
      $changed = @("plan.md")
    } else {
      $okName = "fleet-lane-" + [guid]::NewGuid().ToString("n") + ".txt"
      [IO.File]::WriteAllText((Join-Path (Get-Location) $okName), "ok")
      $changed = @($okName)
    }
  }
  [object[]]$findings = @()
  if ($scenario -eq "blank-finding") { $findings = @(@{severity="low";problem="";fix=""}) }
  $notes = if ($scenario -eq "braces-and-quotes") { 'contains { braces } and "escaped quotes"' } elseif ($scenario -eq "nonstring-notes") { 123 } else { "" }
  [object[]]$criteria = if ($scenario -eq "empty-criteria") { ,@() } elseif ($scenario -eq "failed-criterion") { @(@{criterion="contract";status="failed";evidence="failed"}) } elseif ($scenario -eq "partial") { @(@{criterion="contract";status="blocked";evidence="executable check remains"}) } else { @(@{criterion="contract";status="passed";evidence="static inspection"}) }
  # files_reviewed may omit changed paths (changed is inherently reviewed). unreviewed proves that.
  # Non-empty decorative reviewed avoids PS 5.1 ConvertTo-Json empty-array nulling.
  [object[]]$reviewed = if ($scenario -eq "unreviewed") { [object[]]@("docs/read-only.md") } else { [object[]]$changed }
  [object[]]$fixes = [object[]]@()
  if ($scenario -eq "nonstring-array") { $fixes = [object[]]@(123) }
  @{ schema_version="1"; status=$(if ($scenario -eq "partial") { "partial" } else { "done" }); files_changed=[object[]]$changed; files_reviewed=$reviewed; acceptance_criteria=$criteria; audit_passes=$(if ($scenario -eq "below-passes") { 1 } else { 2 }); findings=[object[]]$findings; fixes=$fixes; remaining_executable_checks=@("tests by Terra"); self_check=$(if ($scenario -eq "blank-self-check") { " " } else { "static review" }); notes=$notes }
}
$finalObject = @{ sessionId=$sid; requestId="fake"; text=$(if ($isBashProbe) { "GROK_BASH_OK" } else { "done" }); structuredOutput=$audit }
$final = if ($scenario -in @("multiline-final","multiline-progress-final","braces-and-quotes")) { $finalObject | ConvertTo-Json -Depth 6 } else { $finalObject | ConvertTo-Json -Compress -Depth 6 }
if ($scenario -eq "progress-json") { Write-Output '{"type":"progress","message":"working"}' }
if ($scenario -eq "multiline-progress-final") { @{type="progress";message="working";detail=@{step=1}} | ConvertTo-Json -Depth 4 | Write-Output }
Write-Output $final
if ($scenario -eq "duplicate-finals") { Write-Output $final }
if ($scenario -eq "trailing-junk") { Write-Output "unexpected trailing text" }
'@)
  $env:GROK_HOME = $fakeHome
  $env:FLEET_GROK_EXECUTABLE = $fakeCmd
  $env:FLEET_GROK_MODEL_LOG = $fakeLog
  $env:FLEET_GROK_CHILD_PID_FILE = $childPidFile

  if ($Phase -in @("All","Wrapper")) {
  Case "success and schema" {
    $run = Run-Wrapper "success"
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($json.status -eq "ok" -and $json.lane -eq "implementation" -and $json.self_audit_required -eq $true -and $json.self_audit_verified -and $json.gate_validation_required -eq $false -and $json.effective_prompt_sha256 -match '^[0-9a-f]{64}$') "expected verified audit and effective prompt hash"
  }
  Case "success emits exactly one result object (no fallback double-emit)" {
    $run = Run-Wrapper "success"
    Assert-True ($run.ExitCode -eq 0) "expected exit 0: $($run.Raw)"
    Assert-True (-not [string]::IsNullOrWhiteSpace($run.Raw)) "expected non-empty stdout"
    $objects = @($run.Raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True ($objects.Count -eq 1) "expected exactly one stdout object, got $($objects.Count): $($run.Raw)"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($json.status -eq "ok") "expected status ok, not fallback: $($run.Raw)"
    Assert-True ($json.status -ne "error") "fallback must not fire on success path: $($run.Raw)"
  }
  Case "heartbeat writes to sidecar file, never pollutes stdout/stderr" {
    # Audit fix 2026-08-03: heartbeats used to go to [Console]::Error, and a caller
    # merging 2>&1 got a NativeCommandError-wrapped heartbeat line ahead of the real
    # result JSON. Heartbeats must now land only in the sidecar file.
    $run = Run-Wrapper "heartbeat-slow" 15 -HeartbeatSeconds 1
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "ok") "expected heartbeat-slow success: $($run.Raw)"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$json.heartbeat_path)) "expected heartbeat_path in result: $($run.Raw)"
    Assert-True (Test-Path -LiteralPath $json.heartbeat_path) "expected heartbeat sidecar file to exist: $($json.heartbeat_path)"
    $hbLines = @(Get-Content -LiteralPath $json.heartbeat_path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True ($hbLines.Count -ge 1) "expected at least one heartbeat line in sidecar"
    foreach ($line in $hbLines) {
      $hb = $line | ConvertFrom-Json
      Assert-True ($hb.type -eq "heartbeat" -and $hb.lane -eq "grok-4.5" -and $null -ne $hb.elapsed_seconds) "malformed heartbeat line: $line"
    }
    Assert-True ($run.Stderr -notmatch '"type"\s*:\s*"heartbeat"') "heartbeat leaked onto stderr"
    Assert-True ($run.Raw -notmatch '"type"\s*:\s*"heartbeat"') "heartbeat leaked onto stdout"
    # The exact failure mode this fixes: line 1 of stdout must parse clean on its own.
    $firstLine = ($run.Raw -split "`r?`n")[0]
    $null = $firstLine | ConvertFrom-Json
    Remove-Item -LiteralPath $json.heartbeat_path -Force -ErrorAction SilentlyContinue
  }
  Case "early wrapper failure emits error result on stdout" {
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = "powershell.exe"
      $psi.Arguments = Quote-TestArgs @("-NoProfile", "-NoLogo", "-ExecutionPolicy", "Bypass", "-File", $wrapper, "-PromptFile", (Join-Path $temp "missing-prompt.txt"), "-WorkingDirectory", $wrapperWorktree, "-Mode", "json", "-TimeoutSeconds", "10")
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $proc = [Diagnostics.Process]::Start($psi)
      $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
      $stderrTask = $proc.StandardError.ReadToEndAsync()
      $null = $proc.WaitForExit(120000)
      $rawOut = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { "" }
      $code = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
      if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
      $proc.Dispose()
    } finally { $ErrorActionPreference = $old }
    Assert-True ($code -ne 0) "expected nonzero exit: $rawOut"
    Assert-True (-not [string]::IsNullOrWhiteSpace($rawOut)) "expected non-empty stdout result: code=$code"
    $json = $rawOut.Trim() | ConvertFrom-Json
    Assert-True ($json.status -eq "error") "expected status=error: $rawOut"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$json.fail_reason)) "expected non-empty fail_reason: $rawOut"
    Assert-True ($null -ne $json.PSObject.Properties["failure_category"]) "expected failure_category key: $rawOut"
    Assert-True ($null -ne $json.PSObject.Properties["exit_code"]) "expected exit_code key: $rawOut"
  }
  Case "review has no Fleet turn cap by default" { $run = Run-Wrapper "default-no-turn-cap" 10 -Review; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $null -eq $json.max_turns) "unexpected default turn cap" }
  Case "review default timeout is 15 minutes" { $run = Run-Wrapper "success" 0 -Review; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.timeout_seconds -eq 900) "wrong review timeout" }
  Case "implementation default timeout is 20 minutes" { $run = Run-Wrapper "success" 0; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.timeout_seconds -eq 1200) "wrong implementation timeout" }
  Case "xhigh maps to highest supported effort" { $run = Run-Wrapper "success" 10 -Effort "xhigh"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.requested_effort -eq "xhigh" -and $json.effective_effort -eq "high") "xhigh was not mapped" }
  Case "phase telemetry is emitted" { $run = Run-Wrapper "success"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.model_turns -eq 1 -and $json.model_seconds -eq 1.25 -and $json.tool_call_count -eq 1 -and $json.tool_seconds -eq 0.25 -and $json.final_prompt_tokens -eq 500) "missing phase telemetry" }
  Case "explicit turn cap remains available" { $run = Run-Wrapper "explicit-turn-cap" 10 -Review -MaxTurns 37; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.max_turns -eq 37) "explicit max turns not forwarded" }
  Case "recovered tool error is trusted telemetry" { $run = Run-Wrapper "recovered-tool-error"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.tool_error_count -eq 1) "expected one trusted tool error" }
  Case "spaced reordered log evidence is captured" { $run=Run-Wrapper "spaced-log";$json=$run.Raw|ConvertFrom-Json;Assert-True ($run.ExitCode -eq 0 -and $json.observed_model -eq "grok-4.5" -and $json.tool_error_count -eq 1) "expected structural log attribution" }
  Case "progress JSON before final envelope succeeds" { $run=Run-Wrapper "progress-json"; Assert-True ($run.ExitCode -eq 0) "expected progress-tolerant success" }
  Case "multiline final envelope succeeds" { $run=Run-Wrapper "multiline-final"; Assert-True ($run.ExitCode -eq 0) "expected multiline success" }
  Case "multiline progress then multiline final succeeds" { $run=Run-Wrapper "multiline-progress-final"; Assert-True ($run.ExitCode -eq 0) "expected concatenated multiline success" }
  Case "braces and escaped quotes inside strings succeed" { $run=Run-Wrapper "braces-and-quotes"; Assert-True ($run.ExitCode -eq 0) "expected string-aware tokenizer" }
  Case "trailing junk after final envelope fails" { $run=Run-Wrapper "trailing-junk"; Assert-True ($run.ExitCode -ne 0) "expected trailing junk failure" }
  Case "unbalanced JSON fails" { $run=Run-Wrapper "unbalanced-json"; Assert-True ($run.ExitCode -ne 0) "expected unbalanced failure" }
  Case "duplicate finals fail" { $run=Run-Wrapper "duplicate-finals"; Assert-True ($run.ExitCode -ne 0) "expected ambiguity failure" }
  Case "malformed JSON fails closed" { $run = Run-Wrapper "malformed"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -ne 0 -and $json.failure_category -eq "report") "expected report failure" }
  Case "transport exit is classified" { $run = Run-Wrapper "transport-error"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -ne 0 -and $json.failure_category -eq "transport") "expected transport failure" }
  Case "nonzero turn limit is model budget" { $run = Run-Wrapper "turn-limit-error"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -ne 0 -and $json.failure_category -eq "model_budget") "expected model-budget failure" }
  Case "missing audit becomes needs_gate_validation" {
    $run = Run-Wrapper "missing-audit"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation" -and $json.self_audit_required -eq $true -and $json.self_audit_verified -eq $false -and $json.gate_validation_required -eq $true -and $json.failure_category -eq "report" -and $json.fail_reason -match "manager gate validation") "expected salvage: $($run.Raw)"
  }
  Case "invalid audit becomes needs_gate_validation" {
    $run = Run-Wrapper "invalid-audit"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation" -and $json.gate_validation_required -eq $true -and $null -ne $json.audit) "expected salvage with partial audit: $($run.Raw)"
  }
  Case "blank finding becomes needs_gate_validation" { $run = Run-Wrapper "blank-finding"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation") "expected salvage" }
  Case "below minimum audit passes becomes needs_gate_validation" { $run = Run-Wrapper "below-passes" 10 -MinimumAuditPasses 2; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation") "expected salvage" }
  Case "empty criteria becomes needs_gate_validation" { $run = Run-Wrapper "empty-criteria"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation") "expected salvage" }
  Case "failed criterion becomes needs_gate_validation" { $run = Run-Wrapper "failed-criterion"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation") "expected salvage" }
  Case "worker-success self-audit mismatch clears failure_category, sets self_audit_missing" {
    # Audit fix 2026-08-03: exit 0 + parseable worker JSON (status done, files_changed
    # populated) but the audit manifest check fails (claimed file != observed delta).
    # Must land as needs_gate_validation with NO failure_category/fail_reason (real work,
    # not an error) plus self_audit_missing=true and an explanatory note.
    $run = Run-Wrapper "audit-mismatch"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation") "expected salvage status: $($run.Raw)"
    Assert-True ($json.self_audit_missing -eq $true) "expected self_audit_missing true: $($run.Raw)"
    Assert-True ($null -eq $json.failure_category) "expected failure_category cleared on worker-success salvage: $($run.Raw)"
    Assert-True ($null -eq $json.fail_reason) "expected fail_reason cleared on worker-success salvage: $($run.Raw)"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$json.self_audit_missing_note) -and $json.self_audit_missing_note -match "manager gate") "expected explanatory note: $($run.Raw)"
  }
  Case "missing worker JSON keeps failure_category=report (genuine failure, not salvaged)" {
    # No worker JSON at all is NOT the false-failure shape the fix targets; keep the
    # existing error-shaped failure_category/fail_reason unchanged.
    $run = Run-Wrapper "missing-audit"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($json.status -eq "needs_gate_validation" -and $json.failure_category -eq "report" -and $json.self_audit_missing -eq $true) "expected genuine no-worker-json path unchanged: $($run.Raw)"
  }
  Case "clean success reports self_audit_missing false with no note" {
    $run = Run-Wrapper "success"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($json.self_audit_missing -eq $false -and $null -eq $json.self_audit_missing_note) "expected self_audit_missing false on clean success: $($run.Raw)"
  }
  Case "changed file absent from files_reviewed is accepted when observed matches" {
    $run = Run-Wrapper "unreviewed"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "ok" -and $json.self_audit_verified -eq $true -and $json.observed_manifest_available -eq $true) "expected accept without reviewed containment: $($run.Raw)"
  }
  Case "non-string array item becomes needs_gate_validation" { $run = Run-Wrapper "nonstring-array"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation") "expected salvage" }
  Case "blank self-check becomes needs_gate_validation" { $run = Run-Wrapper "blank-self-check"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation") "expected salvage" }
  Case "non-string notes becomes needs_gate_validation" { $run = Run-Wrapper "nonstring-notes"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "needs_gate_validation") "expected salvage" }
  Case "empty output remains fail-closed" {
    $run = Run-Wrapper "empty-output"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -ne 0 -and $json.failure_category -eq "report") "expected empty-output failure: $($run.Raw)"
  }
  Case "review markdown json mode" {
    $run = Run-Wrapper "review-markdown" 10 -Review
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "ok" -and $json.lane -eq "read_only" -and $json.self_audit_required -eq $false -and $json.self_audit_verified -eq $false -and $json.gate_validation_required -eq $false -and $null -eq $json.audit -and $null -eq $json.task_status -and $json.response -match "Review") "expected read_only markdown result: $($run.Raw)"
  }
  Case "read-only alias matches review" {
    $run = Run-Wrapper "review-markdown" 10 -ReadOnly
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -eq 0 -and $json.lane -eq "read_only" -and $json.response -match "Review") "expected ReadOnly alias: $($run.Raw)"
  }
  Case "review markdown text mode success writes markdown only" {
    $run = Run-Wrapper "review-markdown" 10 -Review -Mode "text"
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match "Review" -and $run.Raw -notmatch '"status"') "expected markdown stdout only: $($run.Raw)"
  }
  Case "review empty text fails closed with failure json on stderr" {
    $run = Run-Wrapper "review-empty" 10 -Review -Mode "text"
    Assert-True ($run.ExitCode -ne 0) "expected review empty failure"
    Assert-True ([string]::IsNullOrWhiteSpace($run.Raw)) "expected empty stdout for blank response"
    $err = $run.Stderr | ConvertFrom-Json
    Assert-True ($err.failure_category -eq "report" -and $err.lane -eq "read_only") "expected failure JSON on stderr: $($run.Stderr)"
  }
  Case "review text failure with nonblank partial markdown on stdout and failure json on stderr" {
    $run = Run-Wrapper "wrong-model" 10 -Review -Mode "text"
    Assert-True ($run.ExitCode -eq 1) "expected review text failure exit 1: $($run.Raw)"
    Assert-True (-not [string]::IsNullOrWhiteSpace($run.Raw)) "expected nonblank partial markdown on stdout: $($run.Raw)"
    Assert-True ($run.Raw -notmatch '"failure_category"') "expected markdown on stdout, not failure JSON: $($run.Raw)"
    $err = $run.Stderr | ConvertFrom-Json
    Assert-True ($err.failure_category -eq "model" -and $err.lane -eq "read_only" -and $err.status -ne "ok") "expected normalized failure JSON on stderr: $($run.Stderr)"
  }
  Case "review json failure writes normalized json on stdout" {
    $run = Run-Wrapper "wrong-model" 10 -Review -Mode "json"
    Assert-True ($run.ExitCode -eq 1) "expected review json failure exit 1: $($run.Raw)"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($json.failure_category -eq "model" -and $json.lane -eq "read_only" -and $json.status -ne "ok") "expected normalized failure JSON on stdout: $($run.Raw)"
  }
  Case "wrong model fails closed" { $run = Run-Wrapper "wrong-model"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -ne 0 -and $json.failure_category -eq "model") "expected model failure" }
  Case "partial result is valid transport but not completed work" { $run = Run-Wrapper "partial"; $json=$run.Raw|ConvertFrom-Json; Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "ok" -and $json.lane -eq "implementation" -and $json.task_status -eq "partial" -and $json.self_audit_verified -eq $true) "expected valid partial transport" }
  Case "lean memory subagents are explicit and Fleet-marked" { $run=Run-Wrapper "lean-memory-subagents" 10 -Lean -Memory -Subagents; Assert-True ($run.ExitCode -eq 0) "expected opt-in flags: $($run.Raw)" }
  Case "resume session id is forwarded" { $run=Run-Wrapper "resume" 10 -Resume "resume-test"; Assert-True ($run.ExitCode -eq 0) "expected resume flag" }
  Case "Windows shell contract removes noisy color env" {
    $env:NO_COLOR = "1"; $env:FORCE_COLOR = "1"
    $run = Run-Wrapper "windows-shell-contract" 10 -Auto
    Assert-True ($run.ExitCode -eq 0) "expected Windows guidance and sanitized child env: $($run.Raw)"
  }
  Case "expired auth fails before launch" {
    [IO.File]::WriteAllText((Join-Path $fakeHome "auth.json"), "{`"test`":{`"expires_at`":`"$([datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o'))`"}}")
    $run = Run-Wrapper "success"
    Assert-True ($run.ExitCode -ne 0) "expected failure"
    [IO.File]::WriteAllText((Join-Path $fakeHome "auth.json"), "{`"test`":{`"expires_at`":`"$expiry`"}}")
  }
  Case "non-expiring auth entry is accepted" {
    [IO.File]::WriteAllText((Join-Path $fakeHome "auth.json"), '{"api_key":{"token":"test-only"}}')
    $run = Run-Wrapper "success"
    Assert-True ($run.ExitCode -eq 0) "expected non-expiring credential entry acceptance"
    [IO.File]::WriteAllText((Join-Path $fakeHome "auth.json"), "{`"test`":{`"expires_at`":`"$expiry`"}}")
  }
  Case "Auto Bash probe is cached by version" {
    Remove-Item -LiteralPath (Join-Path $fakeHome "fleet\bash-capability-v2-9.9.9-fake.json") -Force -ErrorAction SilentlyContinue
    $run = Run-Wrapper "success" 10 -Auto
    Assert-True ($run.ExitCode -eq 0) "expected success"
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($json.bash_capable -and $json.bash_enabled) "expected enabled proven terminal"
    $cache = [IO.File]::ReadAllText((Join-Path $fakeHome "fleet\bash-capability-v2-9.9.9-fake.json")) | ConvertFrom-Json
    Assert-True ([bool]$cache.'9.9.9-fake') "expected exact-version cache"
  }
  Case "known Bash schema failure caches disabled" {
    Remove-Item -LiteralPath (Join-Path $fakeHome "fleet\bash-capability-v2-9.9.9-fake.json") -Force -ErrorAction SilentlyContinue
    $run = Run-Wrapper "bash-schema" 10 -Auto
    $json = $run.Raw | ConvertFrom-Json
    $cache = [IO.File]::ReadAllText((Join-Path $fakeHome "fleet\bash-capability-v2-9.9.9-fake.json")) | ConvertFrom-Json
    Assert-True ($run.ExitCode -eq 0 -and -not $json.bash_enabled -and -not [bool]$cache.'9.9.9-fake') "expected cached disabled capability"
  }
  Case "isolated worktree with escaping junction is refused; victim survives" {
    $jbase = Join-Path $temp ("junction-" + [guid]::NewGuid().ToString('n'))
    $jwt = Join-Path $jbase "worktree"; $victim = Join-Path $jbase "victim-checkout"
    New-Item -ItemType Directory -Force -Path $jwt, $victim | Out-Null
    [IO.File]::WriteAllText((Join-Path $victim "precious.txt"), "DO NOT DELETE")
    & cmd /c mklink /J "$jwt\node_modules" "$victim" | Out-Null
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt x -WorkingDirectory $jwt -IsolatedWorktree -Mode json -TimeoutSeconds 10 2>&1
      $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $text = ($raw -join "`n")
    Assert-True ($code -ne 0 -and $text -match "Refusing isolated-worktree run" -and $text -match "escapes" -and (Test-Path -LiteralPath (Join-Path $victim "precious.txt"))) "expected junction refusal with victim intact: $text"
    & cmd /c rmdir "$jwt\node_modules" 2>$null | Out-Null
    Remove-Item -LiteralPath $jbase -Recurse -Force -ErrorAction SilentlyContinue
  }
  Case "first-turn alive review completes normally" {
    $run = Run-Wrapper "first-turn-alive" 30 -Review -FirstTurnTimeout 1
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -eq 0 -and $json.status -eq "ok" -and $json.lane -eq "read_only" -and $json.failure_category -ne "no_first_turn" -and $json.timed_out -ne $true -and $json.first_turn_timeout_seconds -eq 1 -and $json.response -match "Alive") "expected alive first-turn success: $($run.Raw)"
  }
  Case "first-turn dead review kills early with no_first_turn" {
    $run = Run-Wrapper "first-turn-dead" 30 -Review -FirstTurnTimeout 1
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -ne 0 -and $json.status -eq "timeout" -and $json.failure_category -eq "no_first_turn" -and $json.timed_out -eq $true -and $json.first_turn_timeout_seconds -eq 1 -and $json.duration_seconds -lt 15 -and $json.fail_reason -match "No first turn") "expected no_first_turn kill: $($run.Raw)"
  }
  Case "first-turn concurrency ignores other pid turns" {
    $run = Run-Wrapper "first-turn-other-pid" 30 -Review -FirstTurnTimeout 1
    $json = $run.Raw | ConvertFrom-Json
    Assert-True ($run.ExitCode -ne 0 -and $json.status -eq "timeout" -and $json.failure_category -eq "no_first_turn" -and $json.timed_out -eq $true -and $json.duration_seconds -lt 15) "expected other-pid still dead: $($run.Raw)"
  }
  Case "Test-GrokFirstTurnSeen injects log lines (no sleep race)" {
    # Deterministic probe: construct unified.jsonl, call helper directly. No wrapper sleep race.
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "wrapper parse errors for first-turn unit"
    $fnAst = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Test-GrokFirstTurnSeen" }, $true) | Select-Object -First 1
    Assert-True ($null -ne $fnAst) "missing Test-GrokFirstTurnSeen"
    # Helper closes over $modelLogPath from wrapper scope; bind a temp log for the probe.
    $probeLog = Join-Path $temp ("first-turn-probe-" + [guid]::NewGuid().ToString("n") + ".jsonl")
    $modelLogPath = $probeLog
    Invoke-Expression $fnAst.Extent.Text
    $probePid = 424242
    $offset = 0
    # NEGATIVE: empty log / wrong pid / non-turn msg -> not seen
    Assert-True (-not (Test-GrokFirstTurnSeen -ProcessId $probePid -Offset $offset)) "empty log must be unseen"
    [IO.File]::WriteAllText($probeLog, ((@{ sid="s1"; pid=1; msg="shell.turn.tool_prep_done"; ctx=@{} } | ConvertTo-Json -Compress) + "`n"))
    Assert-True (-not (Test-GrokFirstTurnSeen -ProcessId $probePid -Offset $offset)) "other pid must be ignored"
    [IO.File]::AppendAllText($probeLog, ((@{ sid="s2"; pid=$probePid; msg="model changed"; ctx=@{model="grok-4.5"} } | ConvertTo-Json -Compress) + "`n"))
    Assert-True (-not (Test-GrokFirstTurnSeen -ProcessId $probePid -Offset $offset)) "model-changed alone is not first turn"
    # POSITIVE: matching pid + tool_prep_done
    [IO.File]::AppendAllText($probeLog, ((@{ sid="s3"; pid=$probePid; msg="shell.turn.tool_prep_done"; ctx=@{} } | ConvertTo-Json -Compress) + "`n"))
    Assert-True (Test-GrokFirstTurnSeen -ProcessId $probePid -Offset $offset) "tool_prep_done for pid must be seen"
    # POSITIVE: matching pid + inference_done; offset skips earlier lines
    $offset2 = (Get-Item -LiteralPath $probeLog).Length
    [IO.File]::AppendAllText($probeLog, ((@{ sid="s4"; pid=$probePid; msg="shell.turn.inference_done"; ctx=@{} } | ConvertTo-Json -Compress) + "`n"))
    Assert-True (Test-GrokFirstTurnSeen -ProcessId $probePid -Offset $offset2) "inference_done after offset must be seen"
    # NEGATIVE: offset past the only matching line
    $past = (Get-Item -LiteralPath $probeLog).Length
    Assert-True (-not (Test-GrokFirstTurnSeen -ProcessId $probePid -Offset $past)) "offset past end must be unseen"
    Remove-Item -LiteralPath $probeLog -Force -ErrorAction SilentlyContinue
  }
  Case "Get-GitStatusDelta content fingerprint (already-dirty re-edit)" {
    # Direct unit test against a real temp git repo. Does not launch Grok.
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "wrapper parse errors for git delta unit"
    foreach ($fnName in @("Get-GitWorktreeFingerprint","Get-GitStatusPathMap","Get-GitStatusDelta")) {
      $fnAst = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Select-Object -First 1
      Assert-True ($null -ne $fnAst) "missing function $fnName"
      # Early pipeline stop (Select-Object -First) races PowerShell's $LASTEXITCODE write for
      # native commands: measured 2/400 calls keep the PREVIOUS command's code, so a good
      # snapshot read as failed and a complete lane silently became needs_gate_validation.
      Assert-True ($fnAst.Extent.Text -notmatch '(?m)&\s*git[^\r\n|]*\|\s*Select-Object') "$fnName must drain git output before reading LASTEXITCODE"
      Invoke-Expression $fnAst.Extent.Text
    }
    $repo = Join-Path $temp ("git-delta-" + [guid]::NewGuid().ToString("n"))
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & git -C $repo init | Out-Null
    & git -C $repo config user.name test
    & git -C $repo config user.email test@example.invalid
    [IO.File]::WriteAllText((Join-Path $repo "tracked.txt"), "v1")
    [IO.File]::WriteAllText((Join-Path $repo "keep-dirty.txt"), "committed")
    [IO.File]::WriteAllText((Join-Path $repo "to-delete.txt"), "bye")
    & git -C $repo add tracked.txt keep-dirty.txt to-delete.txt | Out-Null
    & git -C $repo commit -m seed | Out-Null
    # Already dirty before lane; stay byte-identical between snapshots (false-positive control).
    [IO.File]::WriteAllText((Join-Path $repo "keep-dirty.txt"), "dirty-stable")
    # Already dirty before lane; edited again between snapshots (NEGATIVE defect control).
    [IO.File]::WriteAllText((Join-Path $repo "reedit.txt"), "before")
    # Untracked stable (must not appear).
    [IO.File]::WriteAllText((Join-Path $repo "stable-untracked.txt"), "stable")
    Start-Sleep -Milliseconds 30
    $before = Get-GitStatusPathMap -Path $repo
    Assert-True ($null -ne $before) "before snapshot"
    Assert-True ($before.ContainsKey("keep-dirty.txt")) "keep-dirty must be in before map"
    Assert-True ($before.ContainsKey("reedit.txt")) "reedit must be in before map"
    Start-Sleep -Milliseconds 30
    [IO.File]::WriteAllText((Join-Path $repo "reedit.txt"), "after-lane-edit")
    [IO.File]::WriteAllText((Join-Path $repo "tracked.txt"), "v2")
    [IO.File]::WriteAllText((Join-Path $repo "brand-new.txt"), "new")
    Remove-Item -LiteralPath (Join-Path $repo "to-delete.txt") -Force
    $after = Get-GitStatusPathMap -Path $repo
    Assert-True ($null -ne $after) "after snapshot"
    $delta = Get-GitStatusDelta -Before $before -After $after
    Assert-True ($null -ne $delta) "delta must not be null when both snapshots exist"
    $deltaSet = @{}
    foreach ($p in @($delta)) { $deltaSet[[string]$p] = $true }
    # NEGATIVE (defect): already-dirty re-edit MUST appear
    Assert-True ($deltaSet.ContainsKey("reedit.txt")) "already-dirty re-edit must appear in delta"
    # POSITIVE: untouched already-dirty / untracked must NOT appear
    Assert-True (-not $deltaSet.ContainsKey("keep-dirty.txt")) "untouched dirty must not appear"
    Assert-True (-not $deltaSet.ContainsKey("stable-untracked.txt")) "untouched untracked must not appear"
    # POSITIVE: clean edited, new untracked, deleted
    Assert-True ($deltaSet.ContainsKey("tracked.txt")) "clean edited file must appear"
    Assert-True ($deltaSet.ContainsKey("brand-new.txt")) "new untracked must appear"
    Assert-True ($deltaSet.ContainsKey("to-delete.txt")) "deleted file must appear"
    # POSITIVE: nothing changed -> empty ARRAY not $null
    $deltaSame = Get-GitStatusDelta -Before $after -After $after
    Assert-True ($null -ne $deltaSame) "unchanged delta must not be null"
    Assert-True (@($deltaSame).Count -eq 0) "unchanged delta must be empty array"
    $deltaEmpty = Get-GitStatusDelta -Before @{} -After @{}
    Assert-True ($null -ne $deltaEmpty -and @($deltaEmpty).Count -eq 0) "empty maps -> empty array not null"
    $nongit = Join-Path $temp ("nongit-" + [guid]::NewGuid().ToString("n"))
    New-Item -ItemType Directory -Force -Path $nongit | Out-Null
    Assert-True ($null -eq (Get-GitStatusPathMap -Path $nongit)) "non-git must return null map"
    Assert-True ($null -eq (Get-GitStatusDelta -Before $null -After @{})) "null before -> null delta"
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $nongit -Recurse -Force -ErrorAction SilentlyContinue
  }
  Case "Test-StructuredAudit observed-manifest equality and path shape" {
    # Extract helper + validator from wrapper (no real Grok). $schema required by Test-StructuredAudit.
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "wrapper parse errors"
    $need = @("Test-FleetAuditPathShape","Normalize-FleetAuditPath","Test-StructuredAudit")
    foreach ($fnName in $need) {
      $fnAst = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Select-Object -First 1
      Assert-True ($null -ne $fnAst) "missing function $fnName"
      Invoke-Expression $fnAst.Extent.Text
    }
    $schema = [ordered]@{
      required = @("schema_version","status","files_changed","files_reviewed","acceptance_criteria","audit_passes","findings","fixes","remaining_executable_checks","self_check","notes")
    }
    function New-ValidAudit {
      param([string]$Status = "done", [object[]]$Changed = @("src/a.ts"), [object[]]$Reviewed = @(), [object[]]$Criteria = $null, [object[]]$Findings = @(), [object[]]$Fixes = @(), [string]$SelfCheck = "static", [object]$Notes = "")
      if ($null -eq $Criteria) {
        if ($Status -eq "done") { $Criteria = @(@{criterion="c";status="passed";evidence="e"}) }
        elseif ($Status -eq "blocked") { $Criteria = @(@{criterion="c";status="blocked";evidence="blocked"}) }
        else { $Criteria = @(@{criterion="c";status="blocked";evidence="partial"}) }
      }
      [pscustomobject]@{
        schema_version = "1"; status = $Status
        files_changed = [object[]]$Changed; files_reviewed = [object[]]$Reviewed
        acceptance_criteria = [object[]]$Criteria; audit_passes = 1
        findings = [object[]]$Findings; fixes = [object[]]$Fixes
        remaining_executable_checks = [object[]]@(); self_check = $SelfCheck; notes = $Notes
      }
    }
    # POSITIVE 1: changed ABSENT from files_reviewed, exact observed match (measured defect)
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("src/a.ts") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("src/a.ts")
    Assert-True ($r.valid -and $r.observed_manifest_available) "P1 unreviewed changed must accept"
    # POSITIVE 2: also present in files_reviewed
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("src/a.ts") -Reviewed @("src/a.ts")) -MinimumPasses 1 -ObservedChangedFiles @("src/a.ts")
    Assert-True ($r.valid) "P2 reviewed overlap must accept"
    # POSITIVE 3: mixed slash + case vs observed
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("Src\A.ts") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("src/a.ts")
    Assert-True ($r.valid) "P3 slash/case normalize"
    # POSITIVE 4: multiple files different order
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("b.ts","a.ts") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("a.ts","b.ts")
    Assert-True ($r.valid) "P4 order-independent set equality"
    # POSITIVE 5: duplicate entries, normalized set equal
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("a.ts","a.ts","A.ts") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("a.ts")
    Assert-True ($r.valid) "P5 duplicates collapse to set"
    # POSITIVE 6: parentheses in concrete filename
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("docs/design (old).md") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("docs/design (old).md")
    Assert-True ($r.valid) "P6 parentheses filename"
    # POSITIVE 7: blocked, zero changed, otherwise valid
    $r = Test-StructuredAudit -Value (New-ValidAudit -Status "blocked" -Changed @() -Reviewed @("readme.md")) -MinimumPasses 1 -ObservedChangedFiles @()
    Assert-True ($r.valid) "P7 blocked zero-change allowed"
    # NEGATIVE 1: fabricated claim
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("src/fabricated.ts") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("src/real.ts")
    Assert-True (-not $r.valid) "N1 fabricated claim"
    # NEGATIVE 2: observed omitted from claim
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @() -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("src/real.ts")
    Assert-True (-not $r.valid) "N2 observed omitted"
    # NEGATIVE 3: claim while observed empty
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("src/a.ts") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @()
    Assert-True (-not $r.valid) "N3 claim with empty observed"
    # NEGATIVE 4: done both empty
    $r = Test-StructuredAudit -Value (New-ValidAudit -Status "done" -Changed @() -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @()
    Assert-True (-not $r.valid) "N4 done empty"
    # NEGATIVE 5: partial both empty
    $r = Test-StructuredAudit -Value (New-ValidAudit -Status "partial" -Changed @() -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @()
    Assert-True (-not $r.valid) "N5 partial empty"
    # NEGATIVE 6: empty/default audit object
    $r = Test-StructuredAudit -Value ([pscustomobject]@{}) -MinimumPasses 1 -ObservedChangedFiles @()
    Assert-True (-not $r.valid) "N6 empty object"
    # NEGATIVE 7: empty files_changed + decorative reviewed under productive status
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @() -Reviewed @("docs/read.md","src/other.ts")) -MinimumPasses 1 -ObservedChangedFiles @()
    Assert-True (-not $r.valid) "N7 decorative reviewed only"
    # NEGATIVE 8: glob
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("src/**") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("src/**")
    Assert-True (-not $r.valid) "N8 glob"
    # NEGATIVE 9: annotated pseudo-path with wildcard
    $pseudo = "spikes/tauri-capabilities/** (throwaway probe worktree)"
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @($pseudo) -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @($pseudo)
    Assert-True (-not $r.valid) "N9 annotated wildcard pseudo-path"
    # NEGATIVE 10: absolute drive, UNC, leading-root, traversal
    foreach ($bad in @("C:\src\a.ts","\\server\share\a.ts","/src/a.ts","src/../secret.ts","src/./a.ts")) {
      $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @($bad) -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @($bad)
      Assert-True (-not $r.valid) "N10 bad path shape: $bad"
    }
    # NEGATIVE 11: whitespace-only or non-string
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("   ") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("   ")
    Assert-True (-not $r.valid) "N11 whitespace-only"
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("src/a.ts") -Reviewed @() -Fixes @(123)) -MinimumPasses 1 -ObservedChangedFiles @("src/a.ts")
    Assert-True (-not $r.valid) "N11 non-string array item"
    # NEGATIVE 12: existing malformed criterion / finding / self_check / notes
    $r = Test-StructuredAudit -Value (New-ValidAudit -Criteria @() -Changed @("src/a.ts")) -MinimumPasses 1 -ObservedChangedFiles @("src/a.ts")
    Assert-True (-not $r.valid) "N12 empty criteria"
    $r = Test-StructuredAudit -Value (New-ValidAudit -Findings @(@{severity="low";problem="";fix="x"}) -Changed @("src/a.ts")) -MinimumPasses 1 -ObservedChangedFiles @("src/a.ts")
    Assert-True (-not $r.valid) "N12 blank finding"
    $r = Test-StructuredAudit -Value (New-ValidAudit -SelfCheck " " -Changed @("src/a.ts")) -MinimumPasses 1 -ObservedChangedFiles @("src/a.ts")
    Assert-True (-not $r.valid) "N12 blank self_check"
    $r = Test-StructuredAudit -Value (New-ValidAudit -Notes 123 -Changed @("src/a.ts")) -MinimumPasses 1 -ObservedChangedFiles @("src/a.ts")
    Assert-True (-not $r.valid) "N12 non-string notes"
    $r = Test-StructuredAudit -Value (New-ValidAudit -Criteria @(@{criterion="c";status="failed";evidence="e"}) -Changed @("src/a.ts")) -MinimumPasses 1 -ObservedChangedFiles @("src/a.ts")
    Assert-True (-not $r.valid) "N12 failed criterion under done"
    # NEGATIVE 13: one fabricated extra path (anti-no-op)
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("src/real.ts","src/extra.ts") -Reviewed @()) -MinimumPasses 1 -ObservedChangedFiles @("src/real.ts")
    Assert-True (-not $r.valid) "N13 extra fabricated path"
    # POSITIVE 14 / skip path: no observed manifest param → accept otherwise-valid; available=false
    $r = Test-StructuredAudit -Value (New-ValidAudit -Changed @("src/a.ts") -Reviewed @()) -MinimumPasses 1
    Assert-True ($r.valid -and -not $r.observed_manifest_available) "P14 skip equality when no manifest"
  }
  }
  if ($Phase -in @("All","WrapperSlow")) {
    Case "timeout kills process tree" {
      Remove-Item -LiteralPath $childPidFile -Force -ErrorAction SilentlyContinue
      $run = Run-Wrapper "timeout" 1
      Start-Sleep -Milliseconds 500
      $childPid = if (Test-Path $childPidFile) { [int][IO.File]::ReadAllText($childPidFile) } else { 0 }
      $json = $run.Raw | ConvertFrom-Json
      Assert-True ($run.ExitCode -ne 0 -and $json.failure_category -eq "timeout" -and $childPid -gt 0 -and -not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) "expected timeout result and dead child"
    }
    Case "transient Bash failure is not cached" {
      Remove-Item -LiteralPath (Join-Path $fakeHome "fleet\bash-capability-v2-9.9.9-fake.json") -Force -ErrorAction SilentlyContinue
      $run = Run-Wrapper "bash-transient" 10 -Auto
      Assert-True ($run.ExitCode -eq 0 -and -not (Test-Path (Join-Path $fakeHome "fleet\bash-capability-v2-9.9.9-fake.json"))) "expected unknown capability without cache"
    }
    Case "Auto Bash blocked outside isolated worktree" {
      $env:FLEET_GROK_FAKE_SCENARIO = "success"; $old=$ErrorActionPreference
      try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt nope -WorkingDirectory $temp -BashCapability Auto -Mode json 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
      Assert-True ($code -ne 0) "expected failure"
    }
    Case "Auto Bash rejects primary checkout assertion" {
      $old=$ErrorActionPreference
      try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt nope -WorkingDirectory $wrapperSource -BashCapability Auto -IsolatedWorktree -Mode json 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
      Assert-True ($code -ne 0) "expected linked-worktree validation failure"
    }
  }
  if ($Phase -in @("All","Runner")) {
  $env:FLEET_GROK_WORKTREE_PARENT = Join-Path $temp "worktrees"
  $repo = Join-Path $temp "repo"
  New-Item -ItemType Directory -Path $repo | Out-Null
  & git -C $repo init | Out-Null
  & git -C $repo config user.name test
  & git -C $repo config user.email test@example.invalid
  [IO.File]::WriteAllText((Join-Path $repo ".gitignore"), ".omx/`n.ignored-secret`nnode_modules/`n")
  [IO.File]::WriteAllText((Join-Path $repo "plan.md"), "No code changes. Inspect and return a clean structured audit.")
  & git -C $repo add .
  & git -C $repo commit -m baseline | Out-Null
  Case "build-audit delegates and preserves index" {
    $before = (& git -C $repo write-tree).Trim()
    $env:FLEET_GROK_FAKE_SCENARIO = "success"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug offline -AllowedChangedPathList plan.md -MaxDiffLines 100 -GrokRunTimeoutSeconds 60
    Assert-True ($LASTEXITCODE -eq 0) "runner failed"
    $after = (& git -C $repo write-tree).Trim()
    Assert-True ($before -eq $after) "index tree changed"
    $visibleRunner = Get-ChildItem (Join-Path $repo ".omx\grok-build-audit") -Filter run-grok-visible.ps1 -Recurse | Select-Object -First 1
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($visibleRunner.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "generated visible runner has parse errors"
  }
  Case "build-audit rejects index mutation" {
    $repo = Join-Path $temp "repo"
    $env:FLEET_GROK_FAKE_SCENARIO = "stage"
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug staged -AllowedChangedPathList staged.txt -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 2>$null | Out-Null
      $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    Assert-True ($code -ne 0) "runner accepted staged changes"
  }
  Case "build-audit rejects untracked trailing whitespace" {
    $repo = Join-Path $temp "repo"; $env:FLEET_GROK_FAKE_SCENARIO = "trailing"
    $old=$ErrorActionPreference; try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug trailing -AllowedChangedPathList bad.txt -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    Assert-True ($code -ne 0) "runner accepted trailing whitespace"
  }
  Case "build-audit keeps recovered tool error as telemetry" {
    $repo=Join-Path $temp "repo";$env:FLEET_GROK_FAKE_SCENARIO="recovered-tool-error"
    $old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug toolerror -AllowedChangedPathList plan.md -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    Assert-True ($code -eq 0) "runner rejected recovered tool error"
  }
  Case "actual run requires scope bounds" {
    $repo=Join-Path $temp "repo";$old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug unbounded 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    Assert-True ($code -ne 0) "runner accepted unbounded run"
  }
  Case "actual run rejects current tree" {
    $repo=Join-Path $temp "repo";$old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug current -UseCurrentTree -AllowedChangedPathList plan.md -MaxDiffLines 100 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    Assert-True ($code -ne 0) "runner accepted current-tree run"
  }
  Case "lean-copy fallback runs" {
    $repo=Join-Path $temp "repo";$env:FLEET_GROK_FAKE_SCENARIO="success"
    [IO.File]::WriteAllText((Join-Path $repo ".ignored-secret"), "must-not-copy")
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug lean -LeanCopyPathList ".gitignore,plan.md" -AllowedChangedPathList plan.md -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "lean copy failed"
    $leanRoot = Get-ChildItem $env:FLEET_GROK_WORKTREE_PARENT -Directory -Filter "lean-*" | Select-Object -First 1
    Assert-True ($leanRoot -and -not (Test-Path (Join-Path $leanRoot.FullName ".ignored-secret"))) "lean copy exposed ignored secret"
  }
  Case "build-audit allows new ignored generated output" {
    $repo=Join-Path $temp "repo";$env:FLEET_GROK_FAKE_SCENARIO="generated-output"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug generated -AllowedChangedPathList plan.md -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "runner rejected ignored generated output"
  }
  Case "build-audit rejects binary change" {
    $repo=Join-Path $temp "repo";$env:FLEET_GROK_FAKE_SCENARIO="binary";$old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug binary -AllowedChangedPathList binary.bin -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old};Assert-True ($code -ne 0) "runner accepted binary change"
  }
  Case "build-audit rejects exceeded diff budget" {
    $repo=Join-Path $temp "repo";$env:FLEET_GROK_FAKE_SCENARIO="big-diff";$old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug big -AllowedChangedPathList big.txt -MaxDiffLines 2 -GrokRunTimeoutSeconds 60 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old};Assert-True ($code -ne 0) "runner accepted oversized diff"
  }
  Case "build-audit rejects out-of-scope path" {
    $repo=Join-Path $temp "repo";$env:FLEET_GROK_FAKE_SCENARIO="out-of-scope";$old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug scope -AllowedChangedPathList allowed.txt -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old};Assert-True ($code -ne 0) "runner accepted out-of-scope path"
  }
  Case "build-audit rejects audit path mismatch" {
    $repo=Join-Path $temp "repo";$env:FLEET_GROK_FAKE_SCENARIO="audit-mismatch";$old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug mismatch -AllowedChangedPathList actual.txt -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old};Assert-True ($code -ne 0) "runner accepted audit mismatch"
  }
  Case "build-audit rejects forbidden artifact" {
    $repo=Join-Path $temp "repo";$env:FLEET_GROK_FAKE_SCENARIO="forbidden-artifact";$old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug forbidden -AllowedChangedPathList mcps -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old};Assert-True ($code -ne 0) "runner accepted forbidden artifact"
  }
  Case "lean-copy rejects reparse source" {
    $repo=Join-Path $temp "repo";$target=Join-Path $temp "outside";New-Item -ItemType Directory -Path $target|Out-Null;[IO.File]::WriteAllText((Join-Path $target "x.txt"),"x");New-Item -ItemType Junction -Path (Join-Path $repo "linked") -Target $target|Out-Null
    $old=$ErrorActionPreference;try{$ErrorActionPreference="Continue";& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -Plan (Join-Path $repo "plan.md") -Slug reparse -LeanCopyPathList "linked" -AllowedChangedPathList linked -MaxDiffLines 100 -GrokRunTimeoutSeconds 60 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    Assert-True ($code -ne 0) "runner accepted reparse source"
  }
  Case "Get-LastJsonObject recovers the final audit from concatenated snapshots" {
    $src = [IO.File]::ReadAllText($wrapper)
    $fnText = [regex]::Match($src, '(?s)function Get-LastJsonObject \{.*?\r?\n\}').Value
    Assert-True (-not [string]::IsNullOrWhiteSpace($fnText)) "Get-LastJsonObject not found in wrapper"
    Invoke-Expression $fnText
    # Real shape: Grok streams a bootstrap snapshot, then the completed audit.
    $bootstrap = '{"schema_version":"1","status":"partial","files_changed":[],"acceptance_criteria":[{"criterion":"bootstrap","status":"blocked","evidence":"starting"}]}'
    $final = '{"schema_version":"1","status":"done","files_changed":["a.ts","b.ts"],"acceptance_criteria":[{"criterion":"c","status":"passed","evidence":"e"}]}'
    $recovered = Get-LastJsonObject -Text ($bootstrap + "`n" + $final)
    Assert-True ($recovered.status -eq "done" -and @($recovered.files_changed).Count -eq 2) "did not recover the LAST object"
    # A single object still works.
    Assert-True ((Get-LastJsonObject -Text $final).status -eq "done") "single object regressed"
    # Braces inside strings must not split objects.
    Assert-True ((Get-LastJsonObject -Text '{"a":"}{","b":2}').b -eq 2) "brace inside string split the object"
    # An ESCAPED quote keeps the string open, so a brace after it is still literal.
    Assert-True ((Get-LastJsonObject -Text '{"a":"x\"}y","b":3}').b -eq 3) "escaped quote broke the scan"
    # An escaped BACKSLASH closes the string, so the next brace really does close the object.
    $escBackslash = Get-LastJsonObject -Text '{"a":"x\\"}'
    Assert-True ($null -ne $escBackslash -and $escBackslash.a -eq ('x' + [char]92)) "escaped backslash mis-scanned"
    # Negative controls: nothing to recover.
    Assert-True ($null -eq (Get-LastJsonObject -Text "no json at all")) "returned an object for non-JSON text"
    Assert-True ($null -eq (Get-LastJsonObject -Text "")) "returned an object for empty text"
    Assert-True ($null -eq (Get-LastJsonObject -Text '{"unterminated":1')) "accepted an unterminated object"
  }
  if ($env:OS -eq "Windows_NT") { Skip "strict sandbox outside-root negative" "NO_CONTEST: Grok Build has no Windows OS enforcement" }
  else { Skip "strict sandbox outside-root negative" "requires live Grok sandbox executable; fake transport cannot prove OS containment" }
  }
}
finally {
  foreach ($name in $testEnvNames) { [Environment]::SetEnvironmentVariable($name, $originalEnv[$name], "Process") }
  if (Test-Path $wrapperSource) { & git -C $wrapperSource worktree remove --force $wrapperWorktree 2>$null; & git -C $wrapperSource worktree prune 2>$null }
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$passed passed, $failed failed, $skipped skipped"
if ($failed) { exit 1 } else { exit 0 }
