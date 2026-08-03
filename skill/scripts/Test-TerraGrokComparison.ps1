$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "Run-TerraGrokComparison.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("terra-grok-comparison-" + [guid]::NewGuid().ToString("n"))
try {
  $repo = Join-Path $temp "repo"; $out = Join-Path $temp "out"
  New-Item -ItemType Directory -Force -Path $repo | Out-Null
  & git -C $repo init | Out-Null; & git -C $repo config user.name test; & git -C $repo config user.email test@example.invalid
  [IO.File]::WriteAllText((Join-Path $repo "seed.txt"), "seed")
  [IO.File]::WriteAllText((Join-Path $repo ".gitignore"), "node_modules/`n")
  & git -C $repo add .; & git -C $repo commit -m baseline | Out-Null

  $fakeCodex = Join-Path $temp "codex.ps1"
  [IO.File]::WriteAllText($fakeCodex, @'
param([string]$ArgumentEnvelope,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
if ($ArgumentEnvelope) { $Args = @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgumentEnvelope)) -split [char]0) }
if ($Args -contains "--version") { Write-Output "codex-test 1.0"; exit 0 }
$cwdIndex = [Array]::IndexOf($Args, "-C")
if ($Args -notcontains "gpt-5.6-terra" -or $Args -notcontains 'model_reasoning_effort=medium' -or $cwdIndex -lt 0) { [Console]::Error.WriteLine(($Args -join '|')); exit 41 }
[IO.File]::WriteAllText((Join-Path $Args[$cwdIndex + 1] "result.txt"), "candidate")
Write-Output '{"type":"task.completed"}'
'@)
  $fakeGrokInspect = Join-Path $temp "grok-inspect.ps1"
  [IO.File]::WriteAllText($fakeGrokInspect, @'
param([string]$ArgumentEnvelope,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
if ($ArgumentEnvelope) { $Args = @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgumentEnvelope)) -split [char]0) }
if ($Args -contains "inspect" -and $Args -contains "--json") { if ($env:FAKE_INSPECT_MODE -eq 'bad') { Write-Output 'not-json' } else { Write-Output '{"rules":[],"skills":[],"plugins":[],"hooks":[],"mcp_servers":[]}' }; exit 0 }
exit 44
'@)
  $fakeGrok = Join-Path $temp "grok-wrapper.ps1"
  [IO.File]::WriteAllText($fakeGrok, @'
param([string]$PromptFile,[string]$WorkingDirectory,[string]$BashCapability,[switch]$IsolatedWorktree,[switch]$LeanSystemPrompt,[int]$TimeoutSeconds,[string]$Mode)
$prompt = [IO.File]::ReadAllText($PromptFile)
if ($BashCapability -ne "Auto" -or -not $IsolatedWorktree -or -not $LeanSystemPrompt -or $prompt -notmatch '^SHADOW_COVERED:' -or $prompt -notmatch 'Allowed changed paths:' -or $prompt -notmatch 'result.txt' -or $prompt -notmatch 'Maximum changed lines:' -or $prompt -notmatch 'Required gates') { exit 42 }
[IO.File]::WriteAllText((Join-Path $WorkingDirectory "result.txt"), "candidate")
if ($env:FAKE_JUNCTION_TARGET) { $link = Join-Path $WorkingDirectory "node_modules\outside-link"; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $link) | Out-Null; New-Item -ItemType Junction -Path $link -Target $env:FAKE_JUNCTION_TARGET | Out-Null }
$mode = $env:FAKE_GROK_MODE
if ($mode -eq "failed") { exit 43 }
$observed = if ($mode -eq "bad") { "wrong-model" } else { "grok-4.5" }
$taskStatus = if ($mode -eq "bad") { "partial" } else { "done" }
@{status="ok";task_status=$taskStatus;model="grok-4.5";observed_model=$observed;grok_version="test-0.2.99";model_evidence="unified-log";effective_prompt_sha256=(('a' * 64) -join '');session_id="fake-session"} | ConvertTo-Json -Compress
'@)
  $tasks = @{ tasks = @(
    @{ id="bug"; prompt="Fix bounded bug."; allowed_paths=@("result.txt"); max_diff_lines=10; gate_commands=@('if (-not (Test-Path result.txt)) { exit 1 }') },
    @{ id="refactor"; prompt="Simplify bounded code."; allowed_paths=@("result.txt"); max_diff_lines=10; gate_commands=@('if (-not (Test-Path result.txt)) { exit 1 }') },
    @{ id="test"; prompt="Add bounded regression test."; allowed_paths=@("result.txt"); max_diff_lines=10; gate_commands=@('if (-not (Test-Path result.txt)) { exit 1 }') }
  ) }
  $taskFile = Join-Path $temp "tasks.json"; [IO.File]::WriteAllText($taskFile, ($tasks | ConvertTo-Json -Depth 6))
  $outside = Join-Path $temp "outside"; New-Item -ItemType Directory -Path $outside | Out-Null; [IO.File]::WriteAllText((Join-Path $outside "keep.txt"), "keep")
  $env:FAKE_JUNCTION_TARGET = $outside
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -TaskFile $taskFile -OutputDirectory $out -CodexExecutable $fakeCodex -GrokExecutable $fakeGrokInspect -GrokWrapper $fakeGrok | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "comparison runner failed" }
  $report = Get-Content (Join-Path $out "private\reveal.json") -Raw | ConvertFrom-Json
  if (@($report.results).Count -ne 3) { throw "expected three comparisons" }
  foreach ($result in @($report.results)) {
    if ($result.terra.run.requested_model -ne "gpt-5.6-terra" -or $result.terra.run.requested_effort -ne "medium") { throw "Terra pin missing" }
    if ($result.grok.run.requested_model -ne "grok-4.5" -or $result.grok.run.requested_effort -ne "high" -or $result.grok.run.observed_model -ne "grok-4.5" -or $result.grok.run.grok_version -ne "test-0.2.99") { throw "Grok proof missing" }
    if ($result.terra.artifacts.status -ne "eligible" -or $result.grok.artifacts.status -ne "eligible") { $terraError=Get-Content $result.terra.run.run.stderr -Raw; throw "candidate not score-eligible: terra=$($result.terra.artifacts.status) grok=$($result.grok.artifacts.status) terraTransport=$($result.terra.run.transport_status) terraExit=$($result.terra.run.run.exit_code) terraGate=$($result.terra.artifacts.gates[0].output) terraError=$terraError" }
    $blindTask = Join-Path $out "blind\$($result.task_id)"
    if (-not (Test-Path (Join-Path $blindTask "candidate-a.diff")) -or -not (Test-Path (Join-Path $blindTask "candidate-b.diff"))) { throw "blind artifacts missing" }
    $prompt = Get-Content (Join-Path $blindTask "prompt.txt") -Raw
    if ($prompt -notmatch 'result.txt' -or $prompt -notmatch 'Maximum changed lines: 10' -or $prompt -notmatch 'Required gates') { throw "shared charter incomplete" }
  }
  $blindText = (Get-ChildItem (Join-Path $out "blind") -File -Recurse | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
  if ($blindText -match 'blind_mapping|gpt-5\.6-terra|observed_model|terra\.stdout|grok\.stdout') { throw "blind packet leaks identity" }
  foreach ($result in @($report.results)) { if (@($result.blind_mapping.candidate_a,$result.blind_mapping.candidate_b | Sort-Object -Unique).Count -ne 2) { throw "private blind mapping invalid" } }
  if ($report.results[0].execution_order[0] -ne 'terra' -or $report.results[1].execution_order[0] -ne 'grok') { throw "execution-order balancing missing" }
  if (Test-Path (Join-Path $out "worktrees\bug-terra")) { throw "worktrees were not cleaned" }
  if ((Get-Content (Join-Path $outside "keep.txt") -Raw) -ne "keep") { throw "reparse cleanup touched target" }
  Write-Output "PASS 3-task comparison, scope parity, blind split, model pins, and safe reparse cleanup"

  $env:FAKE_JUNCTION_TARGET = ""; $env:FAKE_GROK_MODE = "bad"
  $badTasks = @{ tasks = @($tasks.tasks[0], $tasks.tasks[1]) }; [IO.File]::WriteAllText($taskFile, ($badTasks | ConvertTo-Json -Depth 6))
  $badOut = Join-Path $temp "bad-transport"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -TaskFile $taskFile -OutputDirectory $badOut -CodexExecutable $fakeCodex -GrokExecutable $fakeGrokInspect -GrokWrapper $fakeGrok | Out-Null
  $badReport = Get-Content (Join-Path $badOut "private\reveal.json") -Raw | ConvertFrom-Json
  if ($badReport.results[0].grok.run.transport_status -ne "error" -or $badReport.results[0].grok.artifacts.status -ne "eligible") { throw "transport and scoring eligibility were conflated" }
  Write-Output "PASS wrong-model partial Grok transport fails adoption without hiding scoreable diff"

  $env:FAKE_GROK_MODE = ""
  $timeoutTasks = @{ tasks = @(
    @{ id="gate-timeout"; prompt="Exercise bounded gate timeout."; allowed_paths=@("result.txt"); max_diff_lines=10; gate_commands=@('Start-Sleep -Seconds 3') },
    @{ id="gate-fast"; prompt="Exercise normal bounded gate."; allowed_paths=@("result.txt"); max_diff_lines=10; gate_commands=@('if (-not (Test-Path result.txt)) { exit 1 }') }
  ) }
  [IO.File]::WriteAllText($taskFile, ($timeoutTasks | ConvertTo-Json -Depth 6)); $timeoutOut=Join-Path $temp 'gate-timeout'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -TaskFile $taskFile -OutputDirectory $timeoutOut -CodexExecutable $fakeCodex -GrokExecutable $fakeGrokInspect -GrokWrapper $fakeGrok -GateTimeoutSeconds 1 | Out-Null
  $timeoutReport=Get-Content (Join-Path $timeoutOut 'private\reveal.json') -Raw | ConvertFrom-Json; $timeoutResult=@($timeoutReport.results|Where-Object task_id -eq 'gate-timeout')[0]
  if ($timeoutResult.terra.artifacts.status -ne 'gate_failed' -or -not $timeoutResult.terra.artifacts.gates[0].timed_out -or $timeoutResult.grok.artifacts.status -ne 'gate_failed' -or -not $timeoutResult.grok.artifacts.gates[0].timed_out) { throw 'bounded gate timeout not enforced for both lanes' }
  Write-Output "PASS gate timeout closes stdin, kills process tree, and marks both candidates failed"

  $env:FAKE_INSPECT_MODE='bad';$safeTasks=@{tasks=@($tasks.tasks[0],$tasks.tasks[1])};[IO.File]::WriteAllText($taskFile,($safeTasks|ConvertTo-Json -Depth 6));$old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -TaskFile $taskFile -OutputDirectory (Join-Path $temp 'bad-inspect') -CodexExecutable $fakeCodex -GrokExecutable $fakeGrokInspect -GrokWrapper $fakeGrok 2>$null|Out-Null;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old;$env:FAKE_INSPECT_MODE=''}
  if($code-eq0){throw'invalid Grok inspect fingerprint accepted'};Write-Output 'PASS invalid Grok inspect fingerprint fails closed before comparison'

  $tasks.tasks[0].id = "../escape"; [IO.File]::WriteAllText($taskFile, ($tasks | ConvertTo-Json -Depth 6)); $old=$ErrorActionPreference
  try { $ErrorActionPreference="Continue"; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -TaskFile $taskFile -OutputDirectory (Join-Path $temp "bad-id") -CodexExecutable $fakeCodex -GrokExecutable $fakeGrokInspect -GrokWrapper $fakeGrok 2>$null | Out-Null; $code=$LASTEXITCODE } finally { $ErrorActionPreference=$old }
  if ($code -eq 0) { throw "unsafe task id accepted" }; Write-Output "PASS unsafe task id rejected"
  $tasks.tasks[0].id="safe-id"; $tasks.tasks[0].allowed_paths=@("../outside"); [IO.File]::WriteAllText($taskFile, ($tasks | ConvertTo-Json -Depth 6))
  try { $ErrorActionPreference="Continue"; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -TaskFile $taskFile -OutputDirectory (Join-Path $temp "bad-path") -CodexExecutable $fakeCodex -GrokExecutable $fakeGrokInspect -GrokWrapper $fakeGrok 2>$null | Out-Null; $code=$LASTEXITCODE } finally { $ErrorActionPreference=$old }
  if ($code -eq 0) { throw "unsafe allowed path accepted" }; Write-Output "PASS unsafe allowed path rejected"

  # v1 golden blind/reveal keys — must not regress when wrapper_pair lands
  $tasks.tasks[0].id="bug"; $tasks.tasks[0].allowed_paths=@("result.txt"); [IO.File]::WriteAllText($taskFile, ($tasks | ConvertTo-Json -Depth 6))
  $goldenOut = Join-Path $temp "golden-v1"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -TaskFile $taskFile -OutputDirectory $goldenOut -CodexExecutable $fakeCodex -GrokExecutable $fakeGrokInspect -GrokWrapper $fakeGrok | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "golden v1 run failed" }
  $gReport = Get-Content (Join-Path $goldenOut "private\reveal.json") -Raw | ConvertFrom-Json
  $gPacket = Get-Content (Join-Path $goldenOut "blind\bug\packet.json") -Raw | ConvertFrom-Json
  $packetKeys = @('task_id','comparison_mode','shared_charter_sha256','base_sha','candidate_a','candidate_b')
  foreach ($k in $packetKeys) { if (-not ($gPacket.PSObject.Properties.Name -contains $k)) { throw "v1 blind packet missing golden key: $k" } }
  $candKeys = @('scoring_status','adoption_status','diff_lines','changed_files','gates')
  foreach ($k in $candKeys) { if (-not ($gPacket.candidate_a.PSObject.Properties.Name -contains $k)) { throw "v1 candidate_a missing: $k" } }
  if ($gPacket.comparison_mode -ne 'grok_review_only') { throw "v1 comparison_mode regressed" }
  if ($gPacket.candidate_a.PSObject.Properties.Name -contains 'wrapper' -or $gPacket.candidate_b.PSObject.Properties.Name -contains 'wrapper') { throw "v1 blind packet must not grow lane-spec echo fields" }
  $revealKeys = @('schema_version','run_id','repo','base_sha','task_file','blind_folder','timing_scope','results')
  foreach ($k in $revealKeys) { if (-not ($gReport.PSObject.Properties.Name -contains $k)) { throw "v1 reveal missing: $k" } }
  $r0 = $gReport.results[0]
  foreach ($k in @('task_id','comparison_mode','shared_charter_sha256','base_sha','execution_order','blind_assignment','blind_mapping','runtime_fingerprints','terra','grok')) {
    if (-not ($r0.PSObject.Properties.Name -contains $k)) { throw "v1 result missing: $k" }
  }
  if ($r0.comparison_mode -ne 'grok_review_only') { throw "v1 reveal comparison_mode regressed" }
  Write-Output "PASS v1 blind packet + reveal golden keys byte-compatible (no lane-spec echo regression)"
}
finally {
  $env:FAKE_GROK_MODE=""; $env:FAKE_JUNCTION_TARGET=""; $env:FAKE_INSPECT_MODE=""
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
