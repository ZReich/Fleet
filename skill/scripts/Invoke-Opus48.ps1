# Canonical Fleet Opus 4.8 review wrapper shared by Codex and Claude.
param(
  [string]$Prompt,
  [string]$PromptFile,
  [string[]]$ArtifactFile,
  [string]$PacketManifest,
  [string]$CandidateManifest,

  [ValidateSet("low", "medium", "high")]
  [string]$Effort = "high",

  # claude-opus-5 REPLACED claude-opus-4-8 as the counted Opus panel seat (2026-07-26).
  # 4.8 stays reachable ONLY as outage fallback (record voice_substituted) or as an
  # explicit benchmark pair partner. The default is the counted seat on purpose: a
  # dispatch that omits -Model used to silently field the retired voice. Same isolation
  # either way; budget the Opus 5 lane for its ~2-3x wall time (Get-FleetReviewBudget).
  [ValidateSet("claude-opus-4-8", "claude-opus-5")]
  [string]$Model = "claude-opus-5",

  # DESIGN WORKSPACE (2026-07-26). Review lanes stay toolless: the deliverable is prose
  # and the transport keeps only the FINAL assistant message. A DESIGN deliverable is
  # files (30-40KB of HTML each), which that transport cannot carry - a live run lost the
  # head of a design system, then two continuation lanes returned hand-stitch fragments
  # (~40 min wall, nothing assembled) while Kimi's -DesignWorkspace wrote 4 complete
  # files. With -DesignOutputDir the lane gets Write/Read/Edit SCOPED TO THAT DIR and the
  # response only has to carry the rationale + manifest.
  [string]$DesignOutputDir,

  [ValidateSet("text", "json")]
  [string]$Mode = "text",

  [ValidateRange(1, 3600)]
  [int]$TimeoutSeconds = 900,

  [ValidateRange(1, 3600)]
  [int]$HeartbeatSeconds = 30
)

$ErrorActionPreference = "Stop"
$ExpectedModel = $Model
$fleetTerseOutputTrailer = 'OUTPUT STYLE (mandatory): terse ' + [char]0x2014 + ' drop articles, filler, pleasantries, hedging; fragments OK; technical substance exact; code, diffs, JSON, file:line references verbatim and complete. Compress prose, never evidence.'
$proc = $null
$ownedMcpConfig = $null
$ownedWorkingDirectory = $null
# Only ever holds a wrapper-CREATED temp dir. A caller-supplied design workspace is the
# deliverable and is never eligible for cleanup.
$ownedEphemeralCwd = $null

function Quote-Arguments {
  param([string[]]$Tokens)
  ($Tokens | ForEach-Object {
    $token = [string]$_
    if ($token.Length -eq 0) { '""' }
    elseif ($token -notmatch '[\s"]') { $token }
    else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }) -join " "
}

function Stop-Tree {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try { $processId = $Process.Id } catch { return }
  try { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null } catch { }
  try { $null = $Process.WaitForExit(5000) } catch { }
}

function Write-Heartbeat {
  param([double]$Elapsed)
  [Console]::Error.WriteLine((([ordered]@{
    type = "heartbeat"
    lane = $ExpectedModel
    elapsed_seconds = [math]::Round($Elapsed, 1)
  }) | ConvertTo-Json -Compress))
}

function Invoke-ClaudeProbe {
  param(
    [string]$Path,
    [ValidateSet('--version', '--help')][string]$Argument,
    [int]$TimeoutMs
  )
  $escaped = $Path.Replace("'", "''")
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& '$escaped' $Argument"))
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = "-NoProfile -EncodedCommand $encoded"
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['DISABLE_UPDATES'] = '1'
  $candidate = [Diagnostics.Process]::Start($psi)
  try {
    $stdoutTask = $candidate.StandardOutput.ReadToEndAsync()
    $stderrTask = $candidate.StandardError.ReadToEndAsync()
    $timedOut = -not $candidate.WaitForExit($TimeoutMs)
    if ($timedOut) { Stop-Tree $candidate }
    $stdout = if ($stdoutTask.Wait(2000)) { [string]$stdoutTask.Result } else { '' }
    $stderr = if ($stderrTask.Wait(2000)) { [string]$stderrTask.Result } else { '' }
    $exitCode = if ($candidate.HasExited) { $candidate.ExitCode } else { -1 }
    return [pscustomobject]@{ TimedOut = $timedOut; ExitCode = $exitCode; Stdout = $stdout; Stderr = $stderr }
  }
  finally { $candidate.Dispose() }
}

function Get-ClaudeVersionLine([string]$Path) {
  $probe = Invoke-ClaudeProbe -Path $Path -Argument '--version' -TimeoutMs 5000
  if ($probe.TimedOut -or $probe.ExitCode -ne 0) { return $null }
  return ($probe.Stdout -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
}

function Get-ClaudeIntegrity([string]$Path, [string]$Version) {
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  $payload = $resolved
  $packageVersion = $Version
  $packageRoot = Join-Path (Split-Path -Parent $resolved) 'node_modules\@anthropic-ai\claude-code'
  $packageJson = Join-Path $packageRoot 'package.json'
  $packageBinary = Join-Path $packageRoot 'bin\claude.exe'
  if ((Test-Path -LiteralPath $packageJson -PathType Leaf) -and (Test-Path -LiteralPath $packageBinary -PathType Leaf)) {
    try { $packageVersion = [string](Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json -ErrorAction Stop).version }
    catch { throw "Claude package metadata is invalid beside launcher: $resolved" }
    $payload = (Resolve-Path -LiteralPath $packageBinary).Path
  }
  return [pscustomobject]@{
    LauncherSha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
    PayloadPath = $payload
    PayloadSha256 = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
    PackageVersion = $packageVersion
  }
}

function Get-ClaudeExecutable {
  $isCandidateProbe = -not [string]::IsNullOrWhiteSpace($CandidateManifest)
  $manifestPath = if ($isCandidateProbe) { $CandidateManifest } else { Join-Path $env:USERPROFILE '.codex\fleet\approved-clis.json' }
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Claude approval manifest missing: $manifestPath"
  }
  try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "Claude approval manifest is invalid: $manifestPath" }
  if ($isCandidateProbe -and $manifest.probe_only -ne $true) { throw 'Candidate manifest must declare probe_only=true.' }
  $approved = $manifest.clis.claude
  if (-not $approved -or [string]::IsNullOrWhiteSpace([string]$approved.path)) {
    throw "Claude approval manifest lacks a candidate path: $manifestPath"
  }

  # Exhaustive PATH/NVM/native discovery belongs to the daily audit. Runtime
  # validates only the pinned path, avoiding latency or failure from unrelated installs.
  $paths = @([string]$approved.path)

  $candidates = foreach ($path in @($paths | Sort-Object -Unique)) {
    $line = Get-ClaudeVersionLine $path
    if ([string]$line -match '(?<version>\d+\.\d+\.\d+)(?![-A-Za-z0-9])') {
      $integrity = Get-ClaudeIntegrity -Path $path -Version $Matches.version
      [pscustomobject]@{
        Source = [string](Resolve-Path -LiteralPath $path).Path
        Version = [version]$Matches.version
        VersionLine = [string]$line
        Sha256 = $integrity.LauncherSha256
        PayloadPath = $integrity.PayloadPath
        PayloadSha256 = $integrity.PayloadSha256
        PackageVersion = $integrity.PackageVersion
      }
    }
  }
  if (-not $candidates) { throw 'No usable Claude Code executable found on PATH, under NVM_HOME, or in the native install cache.' }

  $approvedPath = (Resolve-Path -LiteralPath ([string]$approved.path) -ErrorAction SilentlyContinue).Path
  if ($isCandidateProbe) {
    $selected = $candidates | Where-Object { $_.Source -eq $approvedPath } | Select-Object -First 1
    if (-not $selected) { throw 'Candidate Claude executable is missing, invalid, or prerelease.' }
    return $selected
  }
  if ([string]::IsNullOrWhiteSpace([string]$approved.version) -or [string]::IsNullOrWhiteSpace([string]$approved.sha256) -or
      [string]::IsNullOrWhiteSpace([string]$approved.payload_path) -or [string]::IsNullOrWhiteSpace([string]$approved.payload_sha256) -or
      [string]::IsNullOrWhiteSpace([string]$approved.package_version)) {
    throw "Claude approval manifest lacks launcher or payload integrity fields: $manifestPath"
  }
  $selected = $candidates | Where-Object {
    $_.Source -eq $approvedPath -and $_.Version.ToString() -eq [string]$approved.version -and
    $_.Sha256 -eq ([string]$approved.sha256).ToLowerInvariant() -and
    $_.PayloadPath -eq (Resolve-Path -LiteralPath ([string]$approved.payload_path) -ErrorAction SilentlyContinue).Path -and
    $_.PayloadSha256 -eq ([string]$approved.payload_sha256).ToLowerInvariant() -and
    $_.PackageVersion -eq [string]$approved.package_version
  } | Select-Object -First 1
  if (-not $selected) { throw 'Approved Claude executable is missing, changed, version-mismatched, or not discoverable. Refusing unapproved fallback.' }
  return $selected
}

$hasPrompt = -not [string]::IsNullOrWhiteSpace($Prompt)
$hasFile = -not [string]::IsNullOrWhiteSpace($PromptFile)
if ($hasPrompt -eq $hasFile) { throw "Specify exactly one of -Prompt or -PromptFile." }

try {
  if ($hasFile) {
    if (-not (Test-Path -LiteralPath $PromptFile)) { throw "PromptFile not found: $PromptFile" }
    $promptText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path)
  }
  else { $promptText = [string]$Prompt }
  if ([string]::IsNullOrWhiteSpace($promptText)) { throw "Prompt is empty." }

  $designMode = -not [string]::IsNullOrWhiteSpace($DesignOutputDir)
  $resolvedDesignDir = $null
  if ($designMode) {
    if (-not (Test-Path -LiteralPath $DesignOutputDir)) {
      New-Item -ItemType Directory -Path $DesignOutputDir -Force | Out-Null
    }
    $resolvedDesignDir = (Resolve-Path -LiteralPath $DesignOutputDir).Path
  }

  $artifacts = @()
  $artifactPaths = @($ArtifactFile | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $packetAttestation = $null
  if (-not [string]::IsNullOrWhiteSpace($PacketManifest)) {
    $packetValidator = Join-Path $PSScriptRoot "Assert-FleetReviewPacketManifest.ps1"
    $packetAttestation = (& $packetValidator -ManifestPath $PacketManifest -ArtifactFile $artifactPaths | ConvertFrom-Json)
  }
  foreach ($artifactPath in $artifactPaths) {
    if ([string]::IsNullOrWhiteSpace($artifactPath)) { continue }
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
    if ($expectedArtifacts.Count -ne $artifacts.Count) { throw "Frozen review packet changed during Opus serialization: artifact count" }
    for ($index = 0; $index -lt $artifacts.Count; $index++) {
      if ([int64]$expectedArtifacts[$index].bytes -ne [int64]$artifacts[$index].bytes -or $expectedArtifacts[$index].sha256 -ne $artifacts[$index].sha256) {
        throw "Frozen review packet changed during Opus serialization: artifact index $index"
      }
    }
  }
  if ($designMode) {
    # The response text is NOT the deliverable here - the files are. Saying so prevents
    # the model from trying to inline 40KB of HTML into a transport that keeps only the
    # last message (the exact 2026-07-26 failure).
    $promptText += "`n" + 'DELIVERABLE TRANSPORT (mandatory): your working directory IS the deliverable directory. WRITE each file with the Write tool, complete, one file at a time, most important file FIRST so an interruption still leaves a gradable core. Do NOT paste file contents into your response - the response keeps only your FINAL message and long inline files are silently truncated. After writing, your response carries ONLY: the file manifest (filename + byte count + one-line purpose), the rationale, and the token reference. Never emit a fragment, a "continued from" marker, or instructions to concatenate anything.'
  }
  $promptText += "`n" + $fleetTerseOutputTrailer
  if ($Model -eq 'claude-opus-5') {
    # Owner directive 2026-07-26: Opus 5 is markedly verbose; escalate to caveman ULTRA.
    $promptText += "`n" + 'ULTRA TERSE (Opus 5 mandatory): telegraph style. Fragment over sentence. One line per finding: file:line + defect + trigger + fix. No preamble, no restating the charter, no narrative walkthroughs, no recap, no closing summary. Cut every word that does not change a decision. Evidence (code, diffs, SQL, exact identifiers) stays verbatim and complete — compress prose only. Entire response in ONE message.'
  }

  $claude = Get-ClaudeExecutable
  $claudeVersion = $claude.VersionLine
  $helpProbe = Invoke-ClaudeProbe -Path $claude.Source -Argument '--help' -TimeoutMs 10000
  if ($helpProbe.TimedOut -or $helpProbe.ExitCode -ne 0) { throw 'Claude Code --help probe failed or timed out.' }
  $claudeHelp = $helpProbe.Stdout + "`n" + $helpProbe.Stderr
  $isolationFlags = @()
  # Claude Code 2.1.119 removed --safe-mode. Keep compatibility with versions
  # that still advertise it, but never pass an unsupported flag.
  if ($claudeHelp -match '(?m)^\s+--safe-mode(?:\s|$)') {
    $isolationFlags += "--safe-mode"
  }
  if ($claudeHelp -match '(?m)^\s+--setting-sources(?:\s|$)') { $isolationFlags += @("--setting-sources", "user") }
  if ($claudeHelp -match '(?m)^\s+--disable-slash-commands(?:\s|$)') { $isolationFlags += "--disable-slash-commands" }
  if ($claudeHelp -match '(?m)^\s+--no-chrome(?:\s|$)') { $isolationFlags += "--no-chrome" }
  if ($claudeHelp -match '(?m)^\s+--strict-mcp-config(?:\s|$)' -and $claudeHelp -match '(?m)^\s+--mcp-config(?:\s|$)') {
    $ownedMcpConfig = Join-Path ([IO.Path]::GetTempPath()) ("fleet-opus-mcp-" + [guid]::NewGuid().ToString("n") + ".json")
    [IO.File]::WriteAllText($ownedMcpConfig, '{"mcpServers":{}}', (New-Object Text.UTF8Encoding($false)))
    $isolationFlags += @("--strict-mcp-config", "--mcp-config", $ownedMcpConfig)
  }
  if ($designMode) {
    # Baseline the workspace BEFORE the model runs. Callers routinely pre-place a brief in
    # the design dir, and counting those made "model wrote nothing" read as ok
    # (panel-found 2026-07-26: wrote nothing, status=ok, design_file_count=1).
    $designBaseline = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $resolvedDesignDir -File -Recurse -ErrorAction SilentlyContinue)) {
      $designBaseline[$f.FullName] = [string]$f.Length + '|' + $f.LastWriteTimeUtc.Ticks
    }
    # Workspace IS the working directory, so writes land where the caller collects them.
    # It is the CALLER'S directory and the deliverable: cleanup must never touch it.
    # (2026-07-26: it was assigned to $ownedWorkingDirectory, which the finally block
    # recurse-deletes - the wrapper reported status=ok with design_files populated and
    # then destroyed the directory, including files that pre-dated the run.)
    $ownedWorkingDirectory = $resolvedDesignDir
  } else {
    $ownedWorkingDirectory = Join-Path ([IO.Path]::GetTempPath()) ("fleet-opus-cwd-" + [guid]::NewGuid().ToString("n"))
    New-Item -ItemType Directory -Path $ownedWorkingDirectory | Out-Null
    $ownedEphemeralCwd = $ownedWorkingDirectory
  }

  $toolFlags = if ($designMode) {
    @("--tools", "Write,Read,Edit", "--add-dir", $resolvedDesignDir)
  } else {
    @("--tools", "")
  }

  $args = @($isolationFlags) + @(
    "-p",
    "--model", $ExpectedModel,
    "--effort", $Effort,
    "--permission-mode", "dontAsk"
  ) + $toolFlags + @(
    "--no-session-persistence",
    "--output-format", "json"
  )

  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = [string]$claude.Source
  $psi.Arguments = Quote-Arguments -Tokens $args
  $psi.WorkingDirectory = $ownedWorkingDirectory
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  # Fleet owns promotion. Prevent Claude's normal startup/periodic updater from
  # replacing the approved executable while this review lane is running.
  $psi.EnvironmentVariables['DISABLE_UPDATES'] = '1'

  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  if (-not $proc.Start()) { throw "Failed to start Claude Code." }

  $startedAt = Get-Date
  $deadline = $startedAt.AddSeconds($TimeoutSeconds)
  $nextHeartbeat = $startedAt.AddSeconds($HeartbeatSeconds)
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $promptBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($promptText)
  $writeTask = $proc.StandardInput.BaseStream.WriteAsync($promptBytes, 0, $promptBytes.Length)
  $timedOut = $false

  while (-not $writeTask.IsCompleted -and -not $proc.HasExited) {
    $now = Get-Date
    if ($now -ge $deadline) { $timedOut = $true; Stop-Tree $proc; break }
    Start-Sleep -Milliseconds 25
  }
  if ($writeTask.IsCompleted -and -not $writeTask.IsFaulted) {
    [void]$writeTask.GetAwaiter().GetResult()
    $proc.StandardInput.BaseStream.Close()
  }
  elseif (-not $timedOut) {
    try { $proc.StandardInput.BaseStream.Close() } catch { }
    Stop-Tree $proc
  }

  while (-not $timedOut -and -not $proc.HasExited) {
    $now = Get-Date
    if ($now -ge $deadline) { $timedOut = $true; Stop-Tree $proc; break }
    if ($now -ge $nextHeartbeat) {
      Write-Heartbeat (($now - $startedAt).TotalSeconds)
      $nextHeartbeat = $now.AddSeconds($HeartbeatSeconds)
    }
    Start-Sleep -Milliseconds 50
  }

  try { $null = $proc.WaitForExit(5000) } catch { }
  $stdout = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { "" }
  $stderr = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { "" }
  $duration = ((Get-Date) - $startedAt).TotalSeconds
  $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
  $envelope = $null
  try { $envelope = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { }
  $observedModels = @()
  if ($envelope -and $envelope.modelUsage) { $observedModels = @($envelope.modelUsage.psobject.Properties.Name) }

  $status = "error"
  $reason = $null
  if ($timedOut) { $status = "timeout"; $reason = "Timed out; process tree killed." }
  elseif ($exitCode -ne 0) { $reason = "Claude exited with code $exitCode." }
  elseif ($null -eq $envelope) { $reason = "Claude returned invalid JSON." }
  elseif ([bool]$envelope.is_error -or [string]$envelope.subtype -ne "success") { $reason = [string]$envelope.result }
  elseif (-not ($observedModels | Where-Object { $_ -eq $ExpectedModel -or $_ -like ($ExpectedModel + "-*") })) { $reason = "Expected model absent from modelUsage." }
  elseif ([string]::IsNullOrWhiteSpace([string]$envelope.result)) { $reason = "Claude returned empty output." }
  else { $status = "ok" }

  # EVIDENCE INTEGRITY: for a design lane the FILES are the deliverable, so the result
  # states what actually landed. Zero files written is a failure even when the model
  # replied happily (a 0-byte result file next to real deliverables, or a chatty
  # response next to an empty dir, both misread as success on 2026-07-26).
  $designFiles = @()
  if ($designMode -and (Test-Path -LiteralPath $resolvedDesignDir)) {
    $designFiles = @(
      Get-ChildItem -LiteralPath $resolvedDesignDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
          $stamp = [string]$_.Length + '|' + $_.LastWriteTimeUtc.Ticks
          -not ($designBaseline.ContainsKey($_.FullName) -and $designBaseline[$_.FullName] -eq $stamp)
        } |
        ForEach-Object { [ordered]@{ path = $_.FullName; bytes = $_.Length } }
    )
    if ($status -eq "ok" -and $designFiles.Count -eq 0) {
      $status = "error"
      $reason = "Design lane wrote no files to $resolvedDesignDir."
    }
  }

  $result = [ordered]@{
    status = $status
    model = $ExpectedModel
    design_output_dir = $resolvedDesignDir
    design_files = $designFiles
    design_file_count = $designFiles.Count
    cli_path = [string]$claude.Source
    cli_version = [string]$claudeVersion
    isolation_flags = @($isolationFlags)
    packet_manifest_sha256 = if ($packetAttestation) { [string]$packetAttestation.packet_sha256 } else { $null }
    artifacts = @($artifacts)
    observed_models = $observedModels
    response = if ($envelope) { [string]$envelope.result } else { "" }
    session_id = if ($envelope) { [string]$envelope.session_id } else { $null }
    duration_seconds = [math]::Round($duration, 2)
    cost_usd = if ($envelope) { $envelope.total_cost_usd } else { $null }
    timed_out = [bool]$timedOut
    exit_code = $exitCode
    fail_reason = $reason
  }

  if ($status -ne "ok") {
    $tail = @($stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 30)
    if ($tail.Count) { $result.stderr_tail = $tail }
    if ($Mode -eq "json") { Write-Output ($result | ConvertTo-Json -Compress -Depth 6) }
    else { [Console]::Error.WriteLine(($result | ConvertTo-Json -Compress -Depth 6)) }
    exit 1
  }

  if ($Mode -eq "json") { Write-Output ($result | ConvertTo-Json -Compress -Depth 6) }
  else { Write-Output $result.response }
  exit 0
}
catch {
  # Same invariant as Invoke-Grok45: a terminating error must not leave 0-byte stdout with
  # no reason. External kills cannot be caught; this covers the wrapper's own throws.
  Write-Output ([ordered]@{
    status = "error"
    fail_reason = [string]$_.Exception.Message
    failure_category = "transport"
    exit_code = 1
  } | ConvertTo-Json -Compress)
  exit 1
}
finally {
  if ($proc) {
    try { $proc.StandardInput.BaseStream.Close() } catch { }
    if (-not $proc.HasExited) { Stop-Tree $proc }
    try { $proc.Dispose() } catch { }
  }
  foreach ($path in @($ownedMcpConfig, $ownedEphemeralCwd)) {
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
