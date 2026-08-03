[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$TaskFile,
  [string]$BaseRef = "HEAD",
  [string]$OutputDirectory = "",
  [string]$CodexExecutable = "codex",
  [string]$GrokExecutable = "",
  [string]$GrokWrapper = "",
  # PS5.1: $PSScriptRoot empty in param() defaults when [Parameter()] present — resolve in body.
  [string]$ScriptsDirectory = "",
  [ValidateRange(60, 7200)][int]$LaneTimeoutSeconds = 1800,
  [ValidateRange(1, 3600)][int]$GateTimeoutSeconds = 900,
  [switch]$KeepWorktrees
)

$ErrorActionPreference = "Stop"
function Invoke-GitNative([string]$Cwd, [string[]]$GitArgs) {
  # EAP=Stop + native stderr = NativeCommandError EVEN with 2>$null (LESSONS 2026-07-26).
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; & git -C $Cwd @GitArgs 2>$null }
  finally { $ErrorActionPreference = $old }
}
$Repo = (Resolve-Path -LiteralPath $Repo).Path
$TaskFile = (Resolve-Path -LiteralPath $TaskFile).Path
if (-not $ScriptsDirectory) { $ScriptsDirectory = $PSScriptRoot }
$ScriptsDirectory = (Resolve-Path -LiteralPath $ScriptsDirectory).Path
if (-not $GrokWrapper) { $GrokWrapper = Join-Path $ScriptsDirectory "Invoke-Grok45.ps1" }
$baseSha = Invoke-GitNative $Repo @('rev-parse','--verify',"$BaseRef`^{commit}")
if ($LASTEXITCODE -ne 0) { throw "Cannot resolve base ref: $BaseRef" }
$baseSha = ([string]$baseSha).Trim()
$tasks = @((Get-Content -LiteralPath $TaskFile -Raw | ConvertFrom-Json).tasks)
if ($tasks.Count -lt 2) { throw "Task file must contain at least two tasks." }

$runId = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("n").Substring(0, 8)
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $env:USERPROFILE ".codex\benchmarks\terra-grok\$runId" }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$privateRoot = Join-Path $OutputDirectory "private"
$blindRoot = Join-Path $OutputDirectory "blind"
$worktreeRoot = Join-Path $OutputDirectory "worktrees"
New-Item -ItemType Directory -Force -Path $privateRoot, $blindRoot, $worktreeRoot | Out-Null
# Data-driven wrapper launch caps (not per-model if-chains). transport=patch => read-only + runner applies patch.
$script:WrapperCaps = @{
  'Invoke-Grok45.ps1' = @{ transport='worktree'; effort_param='Effort'; needs_cwd=$true; isolated=$true }
  'Invoke-KimiK3.ps1' = @{ transport='patch'; effort_param=$null; needs_cwd=$false; isolated=$false }
  'Invoke-PiGlm.ps1'  = @{ transport='patch'; effort_param='Thinking'; needs_cwd=$false; isolated=$false; read_only=$true }
}

function Write-Utf8([string]$Path, [string]$Value) {
  $parent = Split-Path -Parent $Path
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, $Value, (New-Object Text.UTF8Encoding($false)))
}
function Get-TextHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))) -replace '-', '').ToLowerInvariant()) }
  finally { $sha.Dispose() }
}
function Get-FileHashValue([string]$Path) { if (Test-Path -LiteralPath $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null } }
function Get-CryptoBit {
  $bytes = New-Object byte[] 1
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes); return (($bytes[0] -band 1) -eq 1) }
  finally { $rng.Dispose() }
}
function Quote-Arguments([string[]]$Tokens) {
  ($Tokens | ForEach-Object { $token=[string]$_; if(-not $token){'""'}elseif($token -notmatch '[\s"]'){$token}else{'"'+($token -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'} }) -join ' '
}
function Stop-Tree([Diagnostics.Process]$Process) {
  try { & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null } catch {}
  try { $null = $Process.WaitForExit(5000) } catch {}
}
function Resolve-CommandPath([string]$Command) {
  if (Test-Path -LiteralPath $Command) { return (Resolve-Path -LiteralPath $Command).Path }
  $resolved = Get-Command $Command -ErrorAction Stop | Select-Object -First 1
  return [string]$resolved.Source
}
function Invoke-CapturedProcess([string]$FilePath, [string[]]$Arguments, [string]$Cwd, [string]$StdoutPath, [string]$StderrPath, [int]$TimeoutSeconds, [string]$StdinText = "") {
  if ([IO.Path]::GetExtension($FilePath) -eq '.ps1') { $encodedArgs=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]::Join([char]0,$Arguments)));$Arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$FilePath,'-ArgumentEnvelope',$encodedArgs);$FilePath='powershell.exe' }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath; $psi.Arguments = Quote-Arguments $Arguments; $psi.WorkingDirectory = $Cwd
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $process = [Diagnostics.Process]::Start($psi)
  $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
  if ($StdinText) { $process.StandardInput.Write($StdinText) }
  $process.StandardInput.Close()
  $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
  if ($timedOut) { Stop-Tree $process }
  $stdout = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { "" }
  $stderr = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { "" }
  Write-Utf8 $StdoutPath $stdout; Write-Utf8 $StderrPath $stderr
  $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
  $process.Dispose()
  [pscustomobject]@{ exit_code=$exitCode; timed_out=$timedOut; stdout=$StdoutPath; stderr=$StderrPath }
}
function Resolve-LaneWrapper([string]$Wrapper) {
  if ([string]::IsNullOrWhiteSpace($Wrapper)) { throw "wrapper name is required" }
  if ([IO.Path]::IsPathRooted($Wrapper)) { throw "wrapper rejects absolute path: $Wrapper" }
  if ($Wrapper -match '[\\/]' -or $Wrapper -match '\.\.') { throw "wrapper rejects path-like name (scripts/ allowlist only): $Wrapper" }
  if ($Wrapper -notmatch '^Invoke-[A-Za-z0-9][A-Za-z0-9._-]*\.ps1$') { throw "wrapper rejects non-scripts executable / unknown form: $Wrapper" }
  $candidate = Join-Path $ScriptsDirectory $Wrapper
  if (-not (Test-Path -LiteralPath $candidate)) { throw "unknown wrapper name (not under scripts/): $Wrapper" }
  $full = [IO.Path]::GetFullPath($candidate); $root = [IO.Path]::GetFullPath($ScriptsDirectory).TrimEnd('\') + '\'
  if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "wrapper resolves outside scripts/: $Wrapper" }
  return $full
}
function Get-WrapperCap([string]$WrapperFile) {
  $key = [IO.Path]::GetFileName($WrapperFile)
  if ($script:WrapperCaps.ContainsKey($key)) { return $script:WrapperCaps[$key] }
  return @{ transport='worktree'; effort_param='Effort'; needs_cwd=$true; isolated=$false }
}
function Build-WrapperArguments($Spec, [string]$WrapperPath, [string]$PromptPath, [string]$Worktree) {
  $cap = Get-WrapperCap $WrapperPath
  $args = New-Object System.Collections.Generic.List[string]
  foreach ($t in @('-NoProfile','-ExecutionPolicy','Bypass','-File',$WrapperPath,'-PromptFile',$PromptPath,'-Mode','json','-TimeoutSeconds',[string]$LaneTimeoutSeconds)) { [void]$args.Add($t) }
  if ($cap.needs_cwd) { [void]$args.Add('-WorkingDirectory'); [void]$args.Add($Worktree) }
  if ($cap.isolated) { foreach ($t in @('-BashCapability','Auto','-IsolatedWorktree','-LeanSystemPrompt')) { [void]$args.Add($t) } }
  if ($cap.read_only) { [void]$args.Add('-ReadOnly') }
  $effort = if ($Spec.effort) { [string]$Spec.effort } else { $null }
  if ($effort -and $cap.effort_param) { [void]$args.Add("-$($cap.effort_param)"); [void]$args.Add($effort) }
  return ,$args.ToArray()
}
function Invoke-Lane([string]$Name, [string]$Worktree, [string]$Prompt, [string]$PromptPath, [string]$PromptHash, [string]$ArtifactRoot, $LaneSpec = $null) {
  $stdoutPath = Join-Path $ArtifactRoot "$Name.stdout.txt"; $stderrPath = Join-Path $ArtifactRoot "$Name.stderr.txt"
  $started = Get-Date
  if ($null -eq $LaneSpec -and $Name -eq 'terra') {
    $arguments = @('exec','--json','--ignore-user-config','--ignore-rules','-m','gpt-5.6-terra','-c','model_reasoning_effort=medium','-s','workspace-write','-C',$Worktree,'-o',(Join-Path $ArtifactRoot 'terra.last-message.txt'),'-')
    $launch = [ordered]@{ executable=$codexPath; requested_model='gpt-5.6-terra'; requested_effort='medium'; prompt_sha256=$PromptHash; args=$arguments }
    Write-Utf8 (Join-Path $ArtifactRoot 'terra.launch.json') ($launch | ConvertTo-Json -Depth 5)
    $run = Invoke-CapturedProcess $codexPath $arguments $Worktree $stdoutPath $stderrPath $LaneTimeoutSeconds $Prompt
    $transportStatus = if ($run.timed_out) { 'timeout' } elseif ($run.exit_code -eq 0) { 'ok' } else { 'error' }
    return [pscustomobject]@{ transport_status=$transportStatus; requested_model='gpt-5.6-terra'; requested_effort='medium'; observed_model=$null; model_evidence='launch-argv'; delivered_prompt_sha256=$PromptHash; run=$run; seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2) }
  }
  if ($null -eq $LaneSpec -and $Name -eq 'grok') {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$GrokWrapper,'-PromptFile',$PromptPath,'-WorkingDirectory',$Worktree,'-BashCapability','Auto','-IsolatedWorktree','-LeanSystemPrompt','-TimeoutSeconds',[string]$LaneTimeoutSeconds,'-Mode','json')
    $launch = [ordered]@{ executable='powershell.exe'; wrapper=$GrokWrapper; requested_model='grok-4.5'; requested_effort='high'; shared_prompt_sha256=$PromptHash; args=@($arguments | ForEach-Object { if($_ -eq $PromptPath){'<shared-prompt-file>'}else{$_} }) }
    Write-Utf8 (Join-Path $ArtifactRoot 'grok.launch.json') ($launch | ConvertTo-Json -Depth 5)
    $run = Invoke-CapturedProcess 'powershell.exe' $arguments $Worktree $stdoutPath $stderrPath ($LaneTimeoutSeconds + 30)
    $transport = $null; try { $transport = Get-Content -LiteralPath $stdoutPath -Raw | ConvertFrom-Json } catch {}
    $transportStatus = if ($run.timed_out) { 'timeout' } elseif ($run.exit_code -eq 0 -and $transport.status -eq 'ok' -and $transport.task_status -eq 'done' -and $transport.observed_model -eq 'grok-4.5') { 'ok' } else { 'error' }
    return [pscustomobject]@{ transport_status=$transportStatus; requested_model='grok-4.5'; requested_effort='high'; observed_model=$transport.observed_model; grok_version=$transport.grok_version; model_evidence=$transport.model_evidence; delivered_prompt_sha256=$transport.effective_prompt_sha256; wrapper_status=$transport.status; session_id=$transport.session_id; run=$run; seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2) }
  }
  # Wrapper-driven arm (v2 lane spec)
  $wrapperPath = Resolve-LaneWrapper ([string]$LaneSpec.wrapper)
  $reqModel = [string]$LaneSpec.model; $reqEffort = if ($LaneSpec.effort) { [string]$LaneSpec.effort } else { $null }
  $arguments = Build-WrapperArguments $LaneSpec $wrapperPath $PromptPath $Worktree
  $cap = Get-WrapperCap $wrapperPath
  $launch = [ordered]@{ executable='powershell.exe'; wrapper=$wrapperPath; requested_model=$reqModel; requested_effort=$reqEffort; shared_prompt_sha256=$PromptHash; args=@($arguments | ForEach-Object { if($_ -eq $PromptPath){'<shared-prompt-file>'}else{$_} }) }
  Write-Utf8 (Join-Path $ArtifactRoot "$Name.launch.json") ($launch | ConvertTo-Json -Depth 5)
  $run = Invoke-CapturedProcess 'powershell.exe' $arguments $Worktree $stdoutPath $stderrPath ($LaneTimeoutSeconds + 30)
  $transport = $null; try { $transport = Get-Content -LiteralPath $stdoutPath -Raw | ConvertFrom-Json } catch {}
  $statusOk = $null -ne $transport -and [string]$transport.status -in @('ok','done')
  $taskOk = $null -eq $transport -or -not (@($transport.PSObject.Properties.Name) -contains 'task_status') -or [string]$transport.task_status -in @('ok','done','')
  # Canonical wrappers emit model+response; Grok also emits observed_model — accept either.
  $obsM = $null; if ($transport) { if ($transport.PSObject.Properties['observed_model'] -and "$($transport.observed_model)" -ne '') { $obsM = [string]$transport.observed_model } elseif ($transport.PSObject.Properties['model']) { $obsM = [string]$transport.model } }
  $modelOk = $null -ne $obsM -and $obsM -eq $reqModel
  $transportStatus = if ($run.timed_out) { 'timeout' } elseif ($run.exit_code -eq 0 -and $statusOk -and $taskOk -and $modelOk) { 'ok' } else { 'error' }
  [pscustomobject]@{ transport_status=$transportStatus; requested_model=$reqModel; requested_effort=$reqEffort; observed_model=$obsM; model_evidence=$(if($transport){$transport.model_evidence}else{$null}); delivered_prompt_sha256=$PromptHash; wrapper_status=$(if($transport){$transport.status}else{$null}); run=$run; seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2); wrapper=$wrapperPath; transport_json=$transport; cap=$cap }
}
function New-ExcludedArtifacts([string]$Lane, [string]$Reason, [string]$ArtifactRoot) {
  $diffPath = Join-Path $ArtifactRoot "$Lane.diff"; Write-Utf8 $diffPath ""
  [pscustomobject]@{ status='excluded_capability'; exclusion_reason=$Reason; changed_files=@(); outside_allowed_paths=@(); diff_lines=0; head_sha=$baseSha; diff_path=$diffPath; gates=@() }
}
function Apply-LanePatch([string]$Lane, [string]$Worktree, [string]$PatchText, [string[]]$Allowed, [string]$ArtifactRoot) {
  # Normalize LF + exactly one trailing newline (here-strings/model outputs often drop final NL → corrupt patch).
  $normalized = ([string]$PatchText) -replace "`r`n","`n" -replace "`r","`n"
  if ($normalized -and -not $normalized.EndsWith("`n")) { $normalized += "`n" }
  $patchPath = Join-Path $ArtifactRoot "$Lane.patch"; Write-Utf8 $patchPath $normalized
  if ([string]::IsNullOrWhiteSpace($normalized)) { return [pscustomobject]@{ ok=$false; reason='empty_patch' } }
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($line in ($normalized -split "`n")) {
    if ($line -match '^diff --git a/(.+) b/(.+)$') { [void]$paths.Add(($Matches[2] -replace '\\','/').Trim()) }
    elseif ($line -match '^\+\+\+ b/(.+)$') { $p=($Matches[1] -replace '\\','/').Trim(); if ($p -ne '/dev/null') { [void]$paths.Add($p) } }
  }
  $unique = @($paths | Sort-Object -Unique); $outside = @($unique | Where-Object { -not (Test-AllowedPath $_ $Allowed) })
  if ($outside.Count) { return [pscustomobject]@{ ok=$false; reason='patch_scope_violation'; outside=$outside } }
  $null = Invoke-GitNative $Worktree @('apply','--check','--whitespace=nowarn',$patchPath)
  if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ ok=$false; reason='patch_apply_check_failed' } }
  $null = Invoke-GitNative $Worktree @('apply','--whitespace=nowarn',$patchPath)
  if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ ok=$false; reason='patch_apply_failed' } }
  return [pscustomobject]@{ ok=$true }
}
function Test-AllowedPath([string]$Path, [string[]]$Allowed) {
  $normalized=($Path -replace '\\','/').Trim('/'); foreach($root in $Allowed){$candidate=($root -replace '\\','/').Trim('/');if($normalized.Equals($candidate,[StringComparison]::OrdinalIgnoreCase)-or $normalized.StartsWith("$candidate/",[StringComparison]::OrdinalIgnoreCase)){return $true}}; return $false
}
function Get-LaneArtifacts([string]$Lane, [string]$Worktree, $Task, [string]$ArtifactRoot) {
  $null = Invoke-GitNative $Worktree @('add','-N','-A')
  $changed=@(Invoke-GitNative $Worktree @('diff','--name-only',$baseSha) | Where-Object {$_} | Sort-Object -Unique)
  $diff=@(Invoke-GitNative $Worktree @('diff',$baseSha,'--binary','--no-ext-diff'))-join"`n"; $diffPath=Join-Path $ArtifactRoot "$Lane.diff"; Write-Utf8 $diffPath $diff
  $outside=@($changed|Where-Object{-not(Test-AllowedPath $_ @($Task.allowed_paths))});$numstat=@(Invoke-GitNative $Worktree @('diff',$baseSha,'--numstat'));$diffLines=0;$binary=$false
  foreach($line in $numstat){$parts=$line-split"`t";if($parts[0]-eq'-'-or$parts[1]-eq'-'){$binary=$true;continue};$diffLines+=[int]$parts[0]+[int]$parts[1]}
  $gates=@();$gateIndex=0;foreach($command in @($Task.gate_commands)){$started=Get-Date;$gateStem="$Lane.gate-$gateIndex";$gateRun=Invoke-CapturedProcess 'powershell.exe' @('-NoProfile','-Command',[string]$command) $Worktree (Join-Path $ArtifactRoot "$gateStem.stdout.txt") (Join-Path $ArtifactRoot "$gateStem.stderr.txt") $GateTimeoutSeconds;$gateOutput=((Get-Content -LiteralPath $gateRun.stdout -Raw)+((Get-Content -LiteralPath $gateRun.stderr -Raw)));$gates+=[pscustomobject]@{command=[string]$command;exit_code=$gateRun.exit_code;timed_out=$gateRun.timed_out;seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2);output=$gateOutput};$gateIndex++}
  $maxLines=if($Task.max_diff_lines){[int]$Task.max_diff_lines}else{1000};$headSha=([string](Invoke-GitNative $Worktree @('rev-parse','HEAD'))).Trim()
  $status=if($headSha-ne$baseSha){'commit_created'}elseif($outside.Count){'scope_violation'}elseif($binary){'binary_change'}elseif($diffLines-gt$maxLines){'diff_budget_exceeded'}elseif(@($gates|Where-Object exit_code -ne 0).Count){'gate_failed'}else{'eligible'}
  [pscustomobject]@{status=$status;changed_files=$changed;outside_allowed_paths=$outside;diff_lines=$diffLines;head_sha=$headSha;diff_path=$diffPath;gates=$gates}
}
function Remove-SafeWorktree([string]$Path) {
  $full=[IO.Path]::GetFullPath($Path);$prefix=[IO.Path]::GetFullPath($worktreeRoot).TrimEnd('\')+'\'
  if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe worktree cleanup path: $full"}
  foreach($link in @(Get-ChildItem -LiteralPath $full -Force -Recurse -Attributes ReparsePoint -ErrorAction Stop)){$linkPath=[IO.Path]::GetFullPath($link.FullName);if(-not$linkPath.StartsWith($full.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe reparse point: $linkPath"};if($link.PSIsContainer){[IO.Directory]::Delete($linkPath)}else{[IO.File]::Delete($linkPath)}}
  $null = Invoke-GitNative $Repo @('worktree','remove','--force',$full)
  if($LASTEXITCODE-ne 0){throw "Failed safe worktree removal: $full"}
}

$codexPath=$null;$grokPath=$null;$codexVersion=$null;$results=@();$blindIndex=@();$seenIds=@{};$createdWorktrees=@()
function Get-AdoptionStatus($Artifacts, $Run) {
  if ($Artifacts.status -eq 'excluded_capability') { return 'excluded_capability' }
  if ($Artifacts.status -eq 'eligible' -and $Run.transport_status -eq 'ok') { return 'eligible' }
  return 'ineligible'
}
function New-CandidateBlind($Artifacts, $Run, $LaneSpec) {
  $c = @{ scoring_status=$Artifacts.status; adoption_status=(Get-AdoptionStatus $Artifacts $Run); diff_lines=$Artifacts.diff_lines; changed_files=$Artifacts.changed_files; gates=@($Artifacts.gates|ForEach-Object{@{command=$_.command;exit_code=$_.exit_code;timed_out=$_.timed_out;seconds=$_.seconds}}) }
  if ($null -ne $LaneSpec) { $c.wrapper = [string]$LaneSpec.wrapper; $c.requested_model = [string]$LaneSpec.model }
  return $c
}
try {
  for($index=0;$index-lt$tasks.Count;$index++){
    $task=$tasks[$index];if(-not$task.id-or-not$task.prompt-or-not@($task.allowed_paths).Count){throw'Each task needs id, prompt, and allowed_paths.'};$taskId=[string]$task.id
    if($taskId-notmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'-or$seenIds.ContainsKey($taskId)){throw"Task id must be unique and path-safe: $taskId"};$seenIds[$taskId]=$true
    $allowed=@($task.allowed_paths|ForEach-Object{([string]$_-replace'\\','/').Trim('/')});foreach($path in $allowed){if(-not$path-or$path-eq'.'-or[IO.Path]::IsPathRooted($path)-or@($path-split'/'|Where-Object{$_-eq'..'}).Count){throw"allowed_paths must be bounded repo-relative paths: $path"}}
    $hasA=$null-ne$task.lane_a;$hasB=$null-ne$task.lane_b
    if($hasA -xor $hasB){throw"Task $taskId must provide both lane_a and lane_b or neither."}
    $isV2=$hasA -and $hasB
    $maxLines=if($task.max_diff_lines){[int]$task.max_diff_lines}else{1000};$gateText=if(@($task.gate_commands).Count){@($task.gate_commands|ForEach-Object{"- $_"})-join"`n"}else{'- none'}
    $prompt="SHADOW_COVERED:$runId/$taskId`nImplement this non-design task. Read any tracked file needed. Do not commit or make unplanned public-contract decisions or changes; implement explicitly locked contract changes in the task.`nAllowed changed paths:`n$(@($allowed|ForEach-Object{"- $_"})-join"`n")`nMaximum changed lines: $maxLines`nRequired gates (runner repeats these):`n$gateText`n`nTask:`n$($task.prompt)"
    $promptHash=Get-TextHash $prompt;$taskPrivate=Join-Path $privateRoot $taskId;$taskBlind=Join-Path $blindRoot $taskId;New-Item -ItemType Directory -Force -Path $taskPrivate,$taskBlind|Out-Null
    $promptPrivate=Join-Path $taskPrivate 'prompt.txt';Write-Utf8 $promptPrivate $prompt;Write-Utf8 (Join-Path $taskBlind 'prompt.txt') $prompt
    if (-not $isV2) {
      if (-not $codexPath) {
        $codexPath=Resolve-CommandPath $CodexExecutable
        $grokPath=if($GrokExecutable){Resolve-CommandPath $GrokExecutable}elseif($env:FLEET_GROK_EXECUTABLE){Resolve-CommandPath $env:FLEET_GROK_EXECUTABLE}else{$direct=Join-Path $env:USERPROFILE '.grok\bin\grok.exe';if(Test-Path -LiteralPath $direct){(Resolve-Path -LiteralPath $direct).Path}else{Resolve-CommandPath 'grok'}}
        $codexVersion=if([IO.Path]::GetExtension($codexPath)-eq'.ps1'){$versionEnvelope=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('--version'));(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $codexPath -ArgumentEnvelope $versionEnvelope 2>&1|Out-String).Trim()}else{(& $codexPath --version 2>&1|Out-String).Trim()}
      }
      $terraTree=Join-Path $worktreeRoot "$taskId-terra";$grokTree=Join-Path $worktreeRoot "$taskId-grok"
      $null=Invoke-GitNative $Repo @('worktree','add','--detach',$terraTree,$baseSha);if($LASTEXITCODE-ne0){throw"Terra worktree failed: $taskId"};$createdWorktrees+=$terraTree
      $null=Invoke-GitNative $Repo @('worktree','add','--detach',$grokTree,$baseSha);if($LASTEXITCODE-ne0){throw"Grok worktree failed: $taskId"};$createdWorktrees+=$grokTree
      $inspectPath=Join-Path $taskPrivate 'grok.inspect.json';$inspectRun=Invoke-CapturedProcess $grokPath @('inspect','--json') $grokTree $inspectPath (Join-Path $taskPrivate 'grok.inspect.stderr.txt') 30;$inspect=Get-Content -LiteralPath $inspectPath -Raw;if($inspectRun.timed_out-or$inspectRun.exit_code-ne0-or[string]::IsNullOrWhiteSpace($inspect)){throw"Grok inspect fingerprint failed for $taskId"};try{$null=$inspect|ConvertFrom-Json}catch{throw"Grok inspect returned invalid JSON for $taskId"}
      $order=if($index%2-eq0){@('terra','grok')}else{@('grok','terra')};$runs=@{};$trees=@{terra=$terraTree;grok=$grokTree}
      foreach($lane in $order){$runs[$lane]=Invoke-Lane $lane $trees[$lane] $prompt $promptPrivate $promptHash $taskPrivate $null}
      $terraArtifacts=Get-LaneArtifacts 'terra' $terraTree $task $taskPrivate;$grokArtifacts=Get-LaneArtifacts 'grok' $grokTree $task $taskPrivate
      if(-not(Test-Path -LiteralPath $terraArtifacts.diff_path)-or-not(Test-Path -LiteralPath $grokArtifacts.diff_path)){throw"Incomplete arm artifacts for $taskId"}
      $nameA='terra';$nameB='grok';$arts=@{terra=$terraArtifacts;grok=$grokArtifacts};$specs=@{terra=$null;grok=$null}
      $terraIsA=Get-CryptoBit;$cmpMode='grok_review_only'
      $aName=if($terraIsA){'terra'}else{'grok'};$bName=if($terraIsA){'grok'}else{'terra'}
      $fps=@{codex_version=$codexVersion;codex_global_agents_sha256=Get-FileHashValue(Join-Path $env:USERPROFILE '.codex\AGENTS.md');grok_global_agents_sha256=Get-FileHashValue(Join-Path $env:USERPROFILE '.grok\AGENTS.md');grok_wrapper_sha256=Get-FileHashValue $GrokWrapper;grok_executable_sha256=Get-FileHashValue $grokPath;grok_inspect_sha256=Get-TextHash $inspect}
      $resultEntry=[pscustomobject]@{task_id=$taskId;comparison_mode=$cmpMode;shared_charter_sha256=$promptHash;base_sha=$baseSha;execution_order=$order;blind_assignment='cryptographic-random-per-task';blind_mapping=@{candidate_a=$aName;candidate_b=$bName};runtime_fingerprints=$fps;terra=@{run=$runs.terra;artifacts=$terraArtifacts};grok=@{run=$runs.grok;artifacts=$grokArtifacts}}
    } else {
      $laneA=$task.lane_a;$laneB=$task.lane_b
      foreach($ls in @($laneA,$laneB)){if(-not$ls.name-or-not$ls.wrapper-or-not$ls.model){throw"lane specs need name, wrapper, model on $taskId"}}
      $nameA=[string]$laneA.name;$nameB=[string]$laneB.name
      if($nameA-eq$nameB){throw"lane_a/lane_b names must differ on $taskId"}
      if($nameA-notmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'-or$nameB-notmatch'^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'){throw"lane names path-safe on $taskId"}
      $wrapA=Resolve-LaneWrapper ([string]$laneA.wrapper);$wrapB=Resolve-LaneWrapper ([string]$laneB.wrapper)
      $treeA=Join-Path $worktreeRoot "$taskId-$nameA";$treeB=Join-Path $worktreeRoot "$taskId-$nameB"
      $null=Invoke-GitNative $Repo @('worktree','add','--detach',$treeA,$baseSha);if($LASTEXITCODE-ne0){throw"Worktree failed: $taskId/$nameA"};$createdWorktrees+=$treeA
      $null=Invoke-GitNative $Repo @('worktree','add','--detach',$treeB,$baseSha);if($LASTEXITCODE-ne0){throw"Worktree failed: $taskId/$nameB"};$createdWorktrees+=$treeB
      $order=if($index%2-eq0){@($nameA,$nameB)}else{@($nameB,$nameA)}
      $runs=@{};$trees=@{$nameA=$treeA;$nameB=$treeB};$specs=@{$nameA=$laneA;$nameB=$laneB};$wraps=@{$nameA=$wrapA;$nameB=$wrapB}
      foreach($lane in $order){$runs[$lane]=Invoke-Lane $lane $trees[$lane] $prompt $promptPrivate $promptHash $taskPrivate $specs[$lane]}
      $arts=@{}
      foreach($lane in @($nameA,$nameB)){
        $r=$runs[$lane];$cap=$r.cap;$tj=$r.transport_json
        $isPatch=(($null -ne $cap -and $cap.transport -eq 'patch') -or ($null -ne $tj -and ($tj.PSObject.Properties['patch'] -or ($tj.PSObject.Properties['response'] -and [string]$tj.response -match 'diff --git'))))
        if (($r.transport_status -eq 'ok') -and $isPatch) {
          # Patch: top-level patch OR unified diff inside response (fenced/raw); neither usable => empty/apply fail => excluded_capability.
          $patchText=''; if($null -ne $tj){ if($tj.PSObject.Properties['patch'] -and "$($tj.patch)".Trim()){$patchText=[string]$tj.patch} elseif($tj.PSObject.Properties['response']){ $rx=[string]$tj.response; if($rx -match '(?s)```(?:diff)?\s*\r?\n(diff --git[\s\S]*?)```'){$patchText=$Matches[1]} elseif($rx -match '(?s)(diff --git[\s\S]+)'){$patchText=$Matches[1]} elseif("$rx".Trim()){$patchText=$rx} } }
          $applied=Apply-LanePatch $lane $trees[$lane] $patchText $allowed $taskPrivate
          if(-not $applied.ok){$arts[$lane]=New-ExcludedArtifacts $lane $applied.reason $taskPrivate; continue}
        }
        if (-not $arts.ContainsKey($lane)) { $arts[$lane] = Get-LaneArtifacts $lane $trees[$lane] $task $taskPrivate }
      }
      if(-not$arts.ContainsKey($nameA)-or-not$arts.ContainsKey($nameB)){throw"Incomplete arm artifacts for $taskId"}
      if(-not(Test-Path -LiteralPath $arts[$nameA].diff_path)-or-not(Test-Path -LiteralPath $arts[$nameB].diff_path)){throw"Incomplete arm diffs for $taskId"}
      $aIsFirst=Get-CryptoBit;$aName=if($aIsFirst){$nameA}else{$nameB};$bName=if($aIsFirst){$nameB}else{$nameA}
      $cmpMode='wrapper_pair'
      $fps=@{};$fps["${nameA}_wrapper_sha256"]=Get-FileHashValue $wrapA;$fps["${nameB}_wrapper_sha256"]=Get-FileHashValue $wrapB
      # First-wave wrapper pairs default estimand=optimized_system (not standardized_model).
      $resultEntry=[pscustomobject]@{task_id=$taskId;comparison_mode=$cmpMode;estimand='optimized_system';shared_charter_sha256=$promptHash;base_sha=$baseSha;execution_order=$order;blind_assignment='cryptographic-random-per-task';blind_mapping=@{candidate_a=$aName;candidate_b=$bName};runtime_fingerprints=$fps}
      $resultEntry | Add-Member -NotePropertyName $nameA -NotePropertyValue @{run=$runs[$nameA];artifacts=$arts[$nameA];lane_spec=@{name=$nameA;wrapper=[string]$laneA.wrapper;model=[string]$laneA.model;effort=$(if($laneA.effort){[string]$laneA.effort}else{$null})}}
      $resultEntry | Add-Member -NotePropertyName $nameB -NotePropertyValue @{run=$runs[$nameB];artifacts=$arts[$nameB];lane_spec=@{name=$nameB;wrapper=[string]$laneB.wrapper;model=[string]$laneB.model;effort=$(if($laneB.effort){[string]$laneB.effort}else{$null})}}
    }
    $aArtifacts=$arts[$aName];$bArtifacts=$arts[$bName];$aRun=$runs[$aName];$bRun=$runs[$bName]
    Copy-Item $aArtifacts.diff_path (Join-Path $taskBlind 'candidate-a.diff');Copy-Item $bArtifacts.diff_path (Join-Path $taskBlind 'candidate-b.diff')
    $blindPacket=[ordered]@{task_id=$taskId;comparison_mode=$cmpMode;shared_charter_sha256=$promptHash;base_sha=$baseSha;candidate_a=(New-CandidateBlind $aArtifacts $aRun $specs[$aName]);candidate_b=(New-CandidateBlind $bArtifacts $bRun $specs[$bName])}
    Write-Utf8 (Join-Path $taskBlind 'packet.json') ($blindPacket|ConvertTo-Json -Depth 10);$blindIndex+=[pscustomobject]@{task_id=$taskId;packet="$taskId/packet.json"}
    $results+=$resultEntry
  }
  $reveal=[ordered]@{schema_version='1';run_id=$runId;repo=$Repo;base_sha=$baseSha;task_file=$TaskFile;blind_folder=$blindRoot;timing_scope='full transport including preflight';results=$results};Write-Utf8 (Join-Path $privateRoot 'reveal.json') ($reveal|ConvertTo-Json -Depth 15);Write-Utf8 (Join-Path $blindRoot 'index.json') (@{schema_version='1';run_id=$runId;tasks=$blindIndex}|ConvertTo-Json -Depth 6);$reveal|ConvertTo-Json -Depth 15
}
finally {
  if(-not$KeepWorktrees){foreach($tree in @($createdWorktrees|Where-Object{Test-Path -LiteralPath $_})){Remove-SafeWorktree $tree};$null=Invoke-GitNative $Repo @('worktree','prune')}
}
