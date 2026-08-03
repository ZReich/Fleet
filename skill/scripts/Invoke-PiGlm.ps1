# Canonical Fleet Pi/GLM wrapper shared by Codex and Claude.
# Uses Pi print mode with prompt content over stdin. Never prints secrets or
# requests Pi's cumulative JSON event stream.
param(
  [string]$Prompt,
  [string]$PromptFile,
  [string[]]$ArtifactFile,
  [string]$PacketManifest,

  [ValidateSet("off", "minimal", "low", "medium", "high", "xhigh")]
  [string]$Thinking = "high",

  [ValidateSet("text", "json")]
  [string]$Mode = "text",

  [switch]$ReadOnly,

  [switch]$NoTools,

  [ValidateRange(1, 86400)]
  [int]$TimeoutSeconds = 900,

  [ValidateRange(1, 3600)]
  [int]$HeartbeatSeconds = 30,

  [switch]$KeepSession
)

$ErrorActionPreference = "Stop"
$ExpectedProvider = "zai"
$ExpectedModel = "glm-5.2"
$fleetTerseOutputTrailer = 'OUTPUT STYLE (mandatory): terse ' + [char]0x2014 + ' drop articles, filler, pleasantries, hedging; fragments OK; technical substance exact; code, diffs, JSON, file:line references verbatim and complete. Compress prose, never evidence.'
$proc = $null
$originalZaiApiKey = [Environment]::GetEnvironmentVariable("ZAI_API_KEY", "Process")

function Write-Heartbeat {
  param([double]$ElapsedSeconds)
  $record = [ordered]@{
    type = "heartbeat"
    transport = "print-stdin"
    elapsed_seconds = [math]::Round($ElapsedSeconds, 1)
  }
  [Console]::Error.WriteLine(($record | ConvertTo-Json -Compress))
}

function ConvertTo-ProcessArgumentList {
  param([string[]]$ArgumentTokens)
  ($ArgumentTokens | ForEach-Object {
    $token = [string]$_
    if ($token -notmatch '[\s"]') { $token }
    else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }) -join " "
}

function Stop-ProcessTree {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try { $processId = $Process.Id } catch { return }
  try { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null } catch { }
  try { $null = $Process.WaitForExit(5000) } catch { }
  try {
    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
      & taskkill.exe /PID $processId /T /F 2>$null | Out-Null
    }
  } catch { }
}

function Resolve-PiLaunch {
  $cmd = Get-Command pi.cmd -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandType -eq "Application" } |
    Select-Object -First 1
  if ($null -eq $cmd) {
    $cmd = Get-Command pi -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandType -in @("Application", "ExternalScript") } |
      Select-Object -First 1
  }
  if ($null -eq $cmd -and -not [string]::IsNullOrWhiteSpace($env:NVM_HOME) -and (Test-Path -LiteralPath $env:NVM_HOME)) {
    $cmd = Get-ChildItem -LiteralPath $env:NVM_HOME -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^v\d+(?:\.\d+){1,3}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName "pi.cmd")) } |
      Sort-Object @{ Expression = { try { [version]$_.Name.Substring(1) } catch { [version]'0.0' } }; Descending = $true } |
      ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName "pi.cmd") } |
      Select-Object -First 1
  }
  if ($null -eq $cmd -and -not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
    $appDataPi = Join-Path $env:APPDATA "npm\pi.cmd"
    if (Test-Path -LiteralPath $appDataPi -PathType Leaf) { $cmd = Get-Item -LiteralPath $appDataPi }
  }
  if ($null -eq $cmd) {
    throw "pi not found on PATH, under NVM_HOME versions, or in APPDATA\npm."
  }
  $source = if ($cmd.PSObject.Properties.Name -contains "Source") { [string]$cmd.Source } else { [string]$cmd.FullName }
  if ($source -match '\.ps1$') {
    return @{
      FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
      PrefixArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $source)
    }
  }
  return @{ FileName = $source; PrefixArgs = @() }
}

$hasPrompt = -not [string]::IsNullOrWhiteSpace($Prompt)
$hasFile = -not [string]::IsNullOrWhiteSpace($PromptFile)
if ($hasPrompt -eq $hasFile) { throw "Specify exactly one of -Prompt or -PromptFile." }
if ($ReadOnly -and $NoTools) { throw "Specify at most one of -ReadOnly or -NoTools." }

try {
  if ($hasFile) {
    if (-not (Test-Path -LiteralPath $PromptFile)) { throw "PromptFile not found: $PromptFile" }
    # PowerShell 5 Get-Content adds ETS file metadata that can leak into JSON or
    # string coercion. ReadAllText guarantees an undecorated, exact string.
    $resolvedPromptPath = (Resolve-Path -LiteralPath $PromptFile -ErrorAction Stop).Path
    $promptText = [System.IO.File]::ReadAllText($resolvedPromptPath)
  }
  else {
    $promptText = [string]$Prompt
  }
  if ([string]::IsNullOrWhiteSpace($promptText)) { throw "Prompt is empty." }

  $artifacts = @()
  $artifactPaths = @($ArtifactFile | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $packetAttestation = $null
  if (-not [string]::IsNullOrWhiteSpace($PacketManifest)) {
    $packetValidator = Join-Path $PSScriptRoot "Assert-FleetReviewPacketManifest.ps1"
    $packetAttestation = (& $packetValidator -ManifestPath $PacketManifest -ArtifactFile $artifactPaths | ConvertFrom-Json)
  }
  foreach ($artifactPath in $artifactPaths) {
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "ArtifactFile not found: $artifactPath" }
    $resolvedArtifact = (Resolve-Path -LiteralPath $artifactPath).Path
    $artifactText = [IO.File]::ReadAllText($resolvedArtifact)
    $promptText += "`n`n===== FROZEN ARTIFACT: $resolvedArtifact =====`n$artifactText"
    $artifactBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($artifactText)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $artifactHash = ([BitConverter]::ToString($hasher.ComputeHash($artifactBytes))).Replace("-", "").ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $artifacts += [ordered]@{ path = $resolvedArtifact; bytes = $artifactBytes.Length; sha256 = $artifactHash }
  }
  if ($packetAttestation) {
    $expectedArtifacts = @($packetAttestation.artifacts)
    if ($expectedArtifacts.Count -ne $artifacts.Count) { throw "Frozen review packet changed during GLM serialization: artifact count" }
    for ($index = 0; $index -lt $artifacts.Count; $index++) {
      if ([int64]$expectedArtifacts[$index].bytes -ne [int64]$artifacts[$index].bytes -or $expectedArtifacts[$index].sha256 -ne $artifacts[$index].sha256) {
        throw "Frozen review packet changed during GLM serialization: artifact index $index"
      }
    }
  }
  $promptText += "`n" + $fleetTerseOutputTrailer

  $authPath = Join-Path $env:USERPROFILE ".local\share\opencode\auth.json"
  if (-not (Test-Path -LiteralPath $authPath)) { throw "Missing opencode auth: $authPath" }
  $authText = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $authPath).Path)
  $auth = $authText | ConvertFrom-Json
  $key = $auth.'zai-coding-plan'.key
  if ([string]::IsNullOrWhiteSpace($key)) { throw "Missing zai-coding-plan key in $authPath" }
  $env:ZAI_API_KEY = $key

  $launch = Resolve-PiLaunch
  $piArgs = New-Object System.Collections.Generic.List[string]
  foreach ($arg in $launch.PrefixArgs) { [void]$piArgs.Add($arg) }
  [void]$piArgs.Add("--provider"); [void]$piArgs.Add($ExpectedProvider)
  [void]$piArgs.Add("--model"); [void]$piArgs.Add($ExpectedModel)
  [void]$piArgs.Add("--thinking"); [void]$piArgs.Add($Thinking)
  [void]$piArgs.Add("-p")
  # Never execute repo-controlled extension code in a process holding ZAI_API_KEY.
  [void]$piArgs.Add("--no-extensions")
  if (-not $KeepSession) { [void]$piArgs.Add("--no-session") }
  if ($NoTools) {
    [void]$piArgs.Add("--no-approve")
    [void]$piArgs.Add("--no-tools")
  }
  elseif ($ReadOnly) {
    [void]$piArgs.Add("--no-approve")
    [void]$piArgs.Add("--tools")
    [void]$piArgs.Add("read,grep,find,ls")
  }
  else {
    [void]$piArgs.Add("--approve")
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $launch.FileName
  $psi.Arguments = ConvertTo-ProcessArgumentList -ArgumentTokens $piArgs.ToArray()
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = (Get-Location).Path

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  if (-not $proc.Start()) { throw "Failed to start pi process." }

  $startedAt = Get-Date
  $deadline = $startedAt.AddSeconds($TimeoutSeconds)
  $nextHeartbeat = $startedAt.AddSeconds($HeartbeatSeconds)
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $timedOut = $false
  $promptAccepted = $false
  $writeFailed = $false

  # Pi print mode merges piped stdin into its initial prompt. Bound the async
  # write by the same deadline so a child that never reads stdin cannot hang us.
  $promptBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($promptText)
  $writeTask = $proc.StandardInput.BaseStream.WriteAsync($promptBytes, 0, $promptBytes.Length)
  while (-not $writeTask.IsCompleted -and -not $proc.HasExited) {
    $now = Get-Date
    if ($now -ge $deadline) {
      $timedOut = $true
      Stop-ProcessTree -Process $proc
      break
    }
    if ($now -ge $nextHeartbeat) {
      Write-Heartbeat -ElapsedSeconds (($now - $startedAt).TotalSeconds)
      $nextHeartbeat = $now.AddSeconds($HeartbeatSeconds)
    }
    Start-Sleep -Milliseconds 25
  }
  if ($writeTask.IsCompleted -and -not $writeTask.IsFaulted) {
    [void]$writeTask.GetAwaiter().GetResult()
    $proc.StandardInput.BaseStream.Close()
    $promptAccepted = $true
  }
  elseif (-not $timedOut) {
    $writeFailed = $true
    try { $proc.StandardInput.BaseStream.Close() } catch { }
    if (-not $proc.HasExited) { Stop-ProcessTree -Process $proc }
  }

  while (-not $timedOut -and -not $proc.HasExited) {
    $now = Get-Date
    if ($now -ge $deadline) {
      $timedOut = $true
      Stop-ProcessTree -Process $proc
      break
    }
    if ($now -ge $nextHeartbeat) {
      Write-Heartbeat -ElapsedSeconds (($now - $startedAt).TotalSeconds)
      $nextHeartbeat = $now.AddSeconds($HeartbeatSeconds)
    }
    Start-Sleep -Milliseconds 50
  }

  try { $null = $proc.WaitForExit(5000) } catch { }
  $responseText = if ($stdoutTask.Wait(5000)) { ([string]$stdoutTask.Result).Trim() } else { "" }
  $stderrText = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { "" }
  # Providers sometimes echo request metadata on failure. Redact the exact key
  # from every child-controlled output surface before normalization or display.
  if (-not [string]::IsNullOrEmpty($key)) {
    $responseText = $responseText.Replace($key, "[REDACTED]")
    $stderrText = $stderrText.Replace($key, "[REDACTED]")
  }
  $duration = ((Get-Date) - $startedAt).TotalSeconds
  $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
  $rawBytes = [Text.Encoding]::UTF8.GetByteCount($responseText)

  $status = "error"
  $failReason = $null
  if ($timedOut) {
    $status = "timeout"
    $failReason = "Timed out after $TimeoutSeconds seconds; process tree killed."
  }
  elseif ($writeFailed) {
    $failReason = "Failed to write prompt to Pi stdin."
  }
  elseif ($exitCode -ne 0) {
    $failReason = "pi exited with code $exitCode."
  }
  elseif ([string]::IsNullOrWhiteSpace($responseText)) {
    $failReason = "Pi returned empty print-mode output."
  }
  else {
    $status = "ok"
  }

  $promptEvidence = if ($promptAccepted) { "stdin-write-completed" } elseif ($timedOut) { "stdin-write-timeout" } else { "stdin-write-failed" }

  $result = [ordered]@{
    status = $status
    provider = $ExpectedProvider
    model = $ExpectedModel
    pi_path = [string]$launch.FileName
    packet_manifest_sha256 = if ($packetAttestation) { [string]$packetAttestation.packet_sha256 } else { $null }
    artifacts = @($artifacts)
    response_model = $null
    response_provider = $null
    model_evidence = "cli-pinned-unobserved"
    model_verified = $false
    response = $responseText
    stop_reason = $null
    duration_seconds = [math]::Round($duration, 2)
    events_seen = 0
    raw_bytes = $rawBytes
    malformed_events = 0
    timed_out = [bool]$timedOut
    prompt_accepted = [bool]$promptAccepted
    prompt_evidence = $promptEvidence
    pi_exit_code = $exitCode
    fail_reason = $failReason
  }

  if ($status -ne "ok") {
    $stderrTail = @($stderrText -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 40)
    if ($stderrTail.Count -gt 0) { $result.stderr_tail = $stderrTail }
    $json = $result | ConvertTo-Json -Compress -Depth 6
    if ($Mode -eq "json") { Write-Output $json }
    else {
      [Console]::Error.WriteLine($json)
      Write-Error $failReason
    }
    exit 1
  }

  if ($Mode -eq "json") { Write-Output ($result | ConvertTo-Json -Compress -Depth 6) }
  else { Write-Output $responseText }
  exit 0
}
finally {
  if ($proc) {
    try { $proc.StandardInput.BaseStream.Close() } catch { }
    if (-not $proc.HasExited) { Stop-ProcessTree -Process $proc }
    try { $proc.Dispose() } catch { }
  }
  [Environment]::SetEnvironmentVariable("ZAI_API_KEY", $originalZaiApiKey, "Process")
}
