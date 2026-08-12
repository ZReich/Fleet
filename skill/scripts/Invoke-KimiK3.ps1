# Canonical Fleet Kimi K3 artifact-analysis transport.
# Kimi prompt mode auto-approves regular tools, so this wrapper never exposes a
# repository: it runs from a disposable home/workspace with static deny rules.
# The full task (lane rules, request, and frozen text artifacts) is written to one
# frozen file under the runtime root and delivered via a Read call scoped to that
# exact path (kimi 0.31.1 has no --prompt-file/stdin flag for -p; this keeps the
# CLI argv short and fixed-size regardless of artifact/request size). Images are
# copied into the runtime and ReadMediaFile is the only other optionally permitted
# read tool.
param(
  [string]$Prompt,
  [string]$PromptFile,
  [string[]]$ArtifactFile = @(),
  [string[]]$ImageFile = @(),

  [switch]$RequireJsonResponse,

  # Guarded research-swarm lane: opens read-only web research and K3's own
  # sub-agent fan-out. Still no repository, shell, write, plan, cron, MCP, or
  # skill access. Off by default keeps the strict artifact-only lane unchanged.
  [switch]$ResearchSwarm,

  # Deterministic citation validation: cross-check URLs cited in the response against
  # URLs actually fetched this run. Default ON for research/web lanes. Fail = reject the
  # run like a disallowed tool call; Flag = return citation_verified=false + the list.
  [switch]$RequireVerifiedCitations,
  [ValidateSet('Fail', 'Flag')][string]$CitationPolicy = 'Fail',

  # Design-workspace lane: K3 may Write/Edit/Read inside an ephemeral workspace only
  # (no repo, shell, web, subagents) to iterate a runnable visual/3D prototype.
  [switch]$DesignWorkspace,

  # Optional durable export for design-workspace deliverables. When set with
  # -DesignWorkspace, every regular file under the ephemeral workspace is copied
  # here (relative paths preserved) BEFORE runtime cleanup deletes the workspace.
  [string]$DesignOutputDir,

  # Repo copy-sandbox lane: materialize a frozen git-archive snapshot of a repo
  # into the ephemeral runtime (tracked files only; no .git, no untracked secrets).
  # Mutually exclusive with -DesignWorkspace and -ResearchSwarm.
  [string]$RepoSandbox,
  [string]$RepoSandboxRef = 'HEAD',

  [ValidateSet("text", "json")]
  [string]$Mode = "text",

  # Default 1800; design-workspace lane defaults to 3600 (set below) unless the
  # caller passed an explicit value — multi-file prototype builds routinely
  # exceed 1800s and a hard kill mid-build destroys the deliverable.
  [ValidateRange(1, 7200)]
  [int]$TimeoutSeconds = 1800,

  [ValidateRange(1, 16)]
  [int]$MaxArtifacts = 8,

 [ValidateRange(1024, 4194304)]
  [int]$MaxArtifactBytes = 1048576,
  [ValidateRange(1024, 52428800)]
  [int]$MaxImageBytes = 26214400,

  # Thinking effort for the underlying model. Fleet default 'high' matches the source
  # config default. REVIEW / SECURITY lanes on large briefs MUST pass 'low' (diagnosed
  # 2026-08-11): high-effort thinking on a >~40KB brief exceeds the Moonshot ~200s server
  # request deadline and the provider returns api_error 500; 'low' completes the same brief
  # well under the deadline. Pairs with the ~55KB brief-size ceiling (K3's Read window).
  [ValidateSet('low', 'high', 'max')]
  [string]$Thinking = 'high'
)

$ErrorActionPreference = "Stop"
$ExpectedModel = "kimi-code/k3"
$fleetTerseOutputTrailer = 'OUTPUT STYLE (mandatory): terse ' + [char]0x2014 + ' drop articles, filler, pleasantries, hedging; fragments OK; technical substance exact; code, diffs, JSON, file:line references verbatim and complete. Compress prose, never evidence.'
$proc = $null
$runtimeRoot = $null
$runtimeHome = $null
$startedAt = $null
$credentialCleanupVerified = $null
$promptBytes = $null
$ownerMarkerStatus = $null
$sourceCredentialSnapshot = $null
$sourceCredentialRestored = $false
$sourceCredentialsDir = $null
# Windows CreateProcess command-line ceiling is 32767. The prompt itself now rides a
# file (see prompt-file transport below), so this only guards a pathological runtime
# path length, not artifact size - raised close to the real ceiling with headroom.
$script:MaxKimiCommandLineChars = 32000
$script:KimiRuntimeCleanupDiagnostic = 'not-run'

# Per-root owner marker for Clear-StaleKimiK3Runtime: { pid, start_time 'o' }.
# Never throws the lane; caller records written|failed.
. (Join-Path $PSScriptRoot 'FleetKimi.Runtime.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetKimi.Config.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetKimi.Phases.Helpers.ps1')


try {
  $inv = Resolve-KimiInvocationInput -Prompt $Prompt -PromptFile $PromptFile -DesignWorkspace ([bool]$DesignWorkspace) -TimeoutBound ($PSBoundParameters.ContainsKey('TimeoutSeconds')) -TimeoutSeconds $TimeoutSeconds -ArtifactFile $ArtifactFile -ImageFile $ImageFile -MaxArtifacts $MaxArtifacts -MaxImageBytes $MaxImageBytes -RepoSandbox $RepoSandbox -RepoSandboxRef $RepoSandboxRef -ResearchSwarm ([bool]$ResearchSwarm)
  $Prompt = [string]$inv.Prompt; $TimeoutSeconds = $inv.TimeoutSeconds
  $repoSandboxActive = [bool]$inv.RepoSandboxActive; $repoSandboxPath = $inv.RepoSandboxPath

  $executable = Get-KimiExecutable
  $version = Get-KimiVersion -Executable $executable
  $sourceHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $env:USERPROFILE '.kimi-code' }
  $sourceConfig = Join-Path $sourceHome 'config.toml'
  if (-not (Test-Path -LiteralPath $sourceConfig -PathType Leaf)) { throw "Kimi source config.toml not found." }
  $sourceCredentials = Join-Path $sourceHome 'credentials'
  if (-not (Test-Path -LiteralPath $sourceCredentials -PathType Container)) { throw "Kimi credential store not found." }
  # Preflight: refuse a dead/cleared source credential before any child launch.
  # Snapshot exact bytes so restore-on-regression can undo a worse end state.
  Assert-KimiSourceCredential -SourceCredentialsDir $sourceCredentials
  $sourceCredentialSnapshot = Read-KimiSourceCredentialBytes -SourceCredentialsDir $sourceCredentials
  $sourceCredentialsDir = $sourceCredentials

  $runtimeRoot = Join-Path ([IO.Path]::GetTempPath()) ('fleet-kimi-k3-' + [guid]::NewGuid().ToString('n'))
  $runtimeHome = Join-Path $runtimeRoot 'home'
  $imagesDirectory = Join-Path $runtimeRoot 'images'
  $skillsDirectory = Join-Path $runtimeRoot 'skills'
  $workspaceDirectory = Join-Path $runtimeRoot 'workspace'
  $sandboxDirectory = Join-Path $runtimeRoot 'repo-sandbox'
  New-Item -ItemType Directory -Force -Path $runtimeHome, $imagesDirectory, $skillsDirectory, $workspaceDirectory | Out-Null
  # Claim wrapper ownership immediately so aged sweeps cannot delete pre-launch roots
  # (no live kimi yet; credential copy has not started).
  $ownerMarkerStatus = 'failed'
  try {
    Write-KimiOwnerMarker -Root $runtimeRoot -OwnerPid $PID -StartTime (Get-Process -Id $PID).StartTime
    $ownerMarkerStatus = 'written'
  } catch { $ownerMarkerStatus = 'failed' }

  $sandboxSha = $null
  $sandboxFileCount = 0
  $sandboxPathRecorded = $null
  if ($repoSandboxActive) {
    $sb = New-KimiRepoSandboxSnapshot -repoSandboxPath $repoSandboxPath -RepoSandboxRef $RepoSandboxRef -sandboxDirectory $sandboxDirectory -runtimeRoot $runtimeRoot
    $sandboxSha = $sb.Sha; $sandboxFileCount = [int]$sb.FileCount; $sandboxPathRecorded = $sb.PathRecorded
  }

  # Prompt-file transport path: known before content is written so the permission
  # rule can be composed ahead of the actual New-KimiPrompt call below.
  $promptFilePath = Join-Path $runtimeRoot 'prompt.txt'

  $runtimeConfig = Join-Path $runtimeHome 'config.toml'
  New-GuardedRuntimeConfig -SourceConfig $sourceConfig -DestinationConfig $runtimeConfig -ImagesDirectory $imagesDirectory -AllowImageRead ([bool]$ImageFile.Count) -ResearchSwarm ([bool]$ResearchSwarm) -WorkspaceDirectory $workspaceDirectory -DesignWorkspace ([bool]$DesignWorkspace) -SandboxDirectory $sandboxDirectory -RepoSandbox ([bool]$repoSandboxActive) -PromptFilePath $promptFilePath -ThinkingEffort $Thinking
  $effectiveConfigSha256 = Get-Sha256 -Path $runtimeConfig
  $sourceConfigSha256 = Get-Sha256 -Path $sourceConfig
  # OAuth is file-backed in Kimi Code. Copy it only into this disposable home;
  # never print, hash, retain, or reuse it after the child process exits.
  Copy-Item -LiteralPath $sourceCredentials -Destination (Join-Path $runtimeHome 'credentials') -Recurse -Force

  $sourceTui = Join-Path $sourceHome 'tui.toml'
  if (Test-Path -LiteralPath $sourceTui -PathType Leaf) {
    Copy-Item -LiteralPath $sourceTui -Destination (Join-Path $runtimeHome 'tui.toml') -Force
  }

  $img = Copy-KimiImages -ImageFile $ImageFile -imagesDirectory $imagesDirectory
  $copiedImages = @($img.Copied); $allowedImagePaths = @($img.Allowed)

  $effectivePrompt = New-KimiPrompt -Request $Prompt -Artifacts $ArtifactFile -Images $copiedImages -MaxBytes $MaxArtifactBytes -ResearchSwarm ([bool]$ResearchSwarm) -DesignWorkspace ([bool]$DesignWorkspace) -WorkspaceDirectory $workspaceDirectory -RepoSandbox ([bool]$repoSandboxActive) -SandboxDirectory $sandboxDirectory -SandboxSha ([string]$sandboxSha)
  $effectivePrompt += "`n" + $fleetTerseOutputTrailer
  $promptBytes = $effectivePrompt.Length
  # Prompt-file transport (audit fix 2026-08-03): kimi 0.31.1's -p flag has no
  # --prompt-file/stdin alternative (verified against the installed CLI's own
  # --help; LESSONS 2026-07-18/2026-07-20 record the same gap on 0.27.0), and a
  # large task previously rode argv straight into the Windows ~32767-char
  # CreateProcess ceiling ("prompt_exceeds_command_line" at prompt_bytes 47368).
  # The full task spec now goes to $promptFilePath (scoped Read allow rule added
  # above); -p carries only this short static instruction, so argv length no
  # longer scales with artifact/request size.
  [IO.File]::WriteAllText($promptFilePath, $effectivePrompt, (New-Object Text.UTF8Encoding($false)))
  # Brief-size guard (2026-08-11): K3's single transport Read caps a large file at a
  # ~59KB window (long embedded-code lines hit it at ~20 lines), and the lane rules forbid
  # a second Read, so a brief over the ceiling reaches the model TRUNCATED. Warn loudly so
  # the caller chunks the artifacts or narrows the brief; proceeding on an over-cap brief
  # yields a review of a partial artifact (silent under-coverage). ~55KB keeps headroom.
  $promptBytes = ([Text.UTF8Encoding]::new($false)).GetByteCount($effectivePrompt)
  if ($promptBytes -gt 56320) {
    [Console]::Error.WriteLine(("kimi-k3: WARNING brief is {0} bytes (> ~55KB single-Read ceiling); K3 will see a truncated preview and the lane forbids re-reading. Chunk artifacts or narrow the brief." -f $promptBytes))
  }
  $normalizedPromptFilePath = $promptFilePath -replace '\\', '/'
  $staticPrompt = "FLEET KIMI K3 FILE-PROMPT TRANSPORT. PROMPT_FILE: $normalizedPromptFilePath`nUse your Read tool to read PROMPT_FILE (that exact path) exactly once now. Its content is your complete task: lane rules, the request, and any frozen artifacts. Follow every instruction in it precisely and respond exactly as it specifies. Do not read any other path with the Read tool. If the Read call on that exact path is denied or fails, report that failure verbatim instead of guessing content."
  # Keep parser options before the (now short, fixed-size) prompt arg. This avoids
  # Windows command shim edge cases while preserving the native Kimi CLI arg contract.
  $arguments = @('--model', $ExpectedModel, '--skills-dir', $skillsDirectory, '--output-format', 'stream-json', '--prompt', $staticPrompt)
  if (@($arguments | Where-Object { $_ -in @('--yolo', '--auto', '--plan', '-y') }).Count) { throw 'Unsafe Kimi flag construction blocked.' }

  $psi = New-KimiProcessStartInfo -executable $executable -arguments $arguments -runtimeRoot $runtimeRoot -runtimeHome $runtimeHome

  # Resolve the durable export root BEFORE launch so incremental export can run
  # while K3 is still writing (survives a hard timeout kill). Baseline the caller's
  # dir first: pre-placed briefs must not count as lane output (panel 2026-07-26).
  # Never delete DesignOutputDir - it is the caller's deliverable.
  $exportRoot = $null
  $exportedPaths = @{}
  $exportBaseline = @{}
  $exportFailReason = $null
  if ($DesignWorkspace -and -not [string]::IsNullOrWhiteSpace($DesignOutputDir)) {
    try {
      if (-not (Test-Path -LiteralPath $DesignOutputDir)) {
        New-Item -ItemType Directory -Force -Path $DesignOutputDir | Out-Null
      }
      $exportRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DesignOutputDir).Path)
      foreach ($f in @(Get-ChildItem -LiteralPath $exportRoot -File -Recurse -ErrorAction SilentlyContinue)) {
        $exportBaseline[$f.FullName] = [string]$f.Length + '|' + $f.LastWriteTimeUtc.Ticks
      }
    }
    catch { $exportFailReason = 'Design workspace export failed: ' + $_.Exception.Message }
  }

  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  if (-not $proc.Start()) { throw 'Failed to start Kimi Code.' }
  # Child is the true owner for the rest of the lane; leave wrapper marker if
  # StartTime is unreadable (attributable-to-wrapper is safe; partial is not).
  try {
    $childStart = $proc.StartTime
    try {
      Write-KimiOwnerMarker -Root $runtimeRoot -OwnerPid $proc.Id -StartTime $childStart
      $ownerMarkerStatus = 'written'
    } catch { $ownerMarkerStatus = 'failed' }
  } catch { }
  $startedAt = Get-Date
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  # Poll instead of one blocking WaitForExit so design-workspace deliverables
  # export incrementally; a hard timeout kill then loses at most the last ~2s of
  # writes. A graceful "stop writing" signal at ~85% of budget is NOT possible on
  # kimi 0.27.0: there is no stdin/control transport and the permission config is
  # only read at startup, so the partial-export result (status=timeout_partial)
  # is the graceful-degradation path.
  $hardDeadline = $startedAt.AddSeconds($TimeoutSeconds + 10)
  $finished = $false
  while (-not $finished) {
    $finished = $proc.WaitForExit(2000)
    if ($exportRoot) { Export-WorkspaceIncrement -WorkspaceDirectory $workspaceDirectory -ExportRoot $exportRoot -ExportedPaths $exportedPaths }
    if (-not $finished -and (Get-Date) -ge $hardDeadline) { break }
  }
  if (-not $finished) { Stop-Tree $proc }
  $stdout = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { '' }
  $stderr = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { '' }
  $duration = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)
  $exitCode = if ($finished -and $proc.HasExited) { $proc.ExitCode } else { -1 }

  $wc = Get-KimiWorkspaceCapture -DesignWorkspace ([bool]$DesignWorkspace) -workspaceDirectory $workspaceDirectory -exportRoot $exportRoot -exportedPaths $exportedPaths -exportBaseline $exportBaseline -exportFailReason $exportFailReason -finished ([bool]$finished)
  $workspaceFiles = @($wc.Files); $workspaceExportDir = $wc.ExportDir; $workspaceExportedCount = [int]$wc.Count
  $exportedPaths = $wc.ExportedPaths; $exportFailReason = $wc.FailReason; $timeoutPartial = [bool]$wc.TimeoutPartial

  $sp = Read-KimiStreamEvents -stdout $stdout
  $events = @($sp.Events); $assistantText = @($sp.AssistantText); $toolCalls = @($sp.ToolCalls); $sessionId = $sp.SessionId

  $tp = Test-KimiToolCallPolicy -toolCalls $toolCalls -promptFilePath $promptFilePath -runtimeRoot $runtimeRoot -allowedImagePaths $allowedImagePaths -DesignWorkspace ([bool]$DesignWorkspace) -workspaceDirectory $workspaceDirectory -repoSandboxActive ([bool]$repoSandboxActive) -sandboxDirectory $sandboxDirectory -ResearchSwarm ([bool]$ResearchSwarm)
  $unsafeToolCall = [bool]$tp.Unsafe; $toolEvidence = @($tp.Evidence)

  $response = if ($assistantText.Count) { [string]$assistantText[$assistantText.Count - 1] } else { '' }
  $responseJsonValid = $false
  if ($RequireJsonResponse -and -not [string]::IsNullOrWhiteSpace($response)) {
    try { $null = $response | ConvertFrom-Json -ErrorAction Stop; $responseJsonValid = $true } catch { }
  }

  # Citation validation: URLs the response cites must have been fetched this run.
  $fetchedUrls = @($toolCalls | Where-Object { $_.name -in @('FetchURL', 'WebSearch') -and $_.url } | ForEach-Object { Get-NormalizedUrl $_.url } | Where-Object { $_ } | Select-Object -Unique)
  $citedUrls = @(Get-CitedUrls $response)
  $citedButUnfetched = @($citedUrls | Where-Object { $_ -notin $fetchedUrls })
  $citationApplies = [bool]$RequireVerifiedCitations -or [bool]$ResearchSwarm
  $citationVerified = -not ($citationApplies -and $citedButUnfetched.Count -gt 0)

  $reason = $null
  if (-not $finished) { $reason = 'Timed out; process tree killed.' }
  elseif ($exitCode -ne 0) { $reason = "Kimi Code exited with code $exitCode." }
  elseif (-not $events.Count) { $reason = 'Kimi returned no stream-json events.' }
  elseif ($unsafeToolCall) { $reason = 'Kimi attempted a disallowed or non-isolated tool call.' }
  elseif (-not (@($toolEvidence | Where-Object { $_.name -eq 'Read' -and $_.in_prompt_file }).Count)) { $reason = 'Kimi did not read the prompt file.' }
  elseif ($ImageFile.Count -and -not (@($toolCalls | Where-Object { $_.name -eq 'ReadMediaFile' }).Count)) { $reason = 'Kimi did not read the copied visual evidence.' }
  elseif ([string]::IsNullOrWhiteSpace($response)) { $reason = 'Kimi returned no assistant text.' }
  elseif ($RequireJsonResponse -and -not $responseJsonValid) { $reason = 'Kimi response was not valid JSON.' }
  elseif ($citationApplies -and $CitationPolicy -eq 'Fail' -and $citedButUnfetched.Count -gt 0) { $reason = 'Cited URLs were not fetched this run: ' + ($citedButUnfetched -join ', ') }
  if ($exportFailReason) {
    $reason = if ($reason) { $reason + ' ' + $exportFailReason } else { $exportFailReason }
  }
  # Design-workspace deliverable is exported files. Cheerful chat with zero new
  # files under DesignOutputDir is a failed lane (mirrors Opus empty-export gate).
  # timeout_partial already requires exports > 0; leave that status distinct.
  if ($DesignWorkspace -and $exportRoot -and $workspaceExportedCount -eq 0 -and -not $timeoutPartial -and -not $reason) {
    $reason = 'Design lane wrote no files to ' + $exportRoot + '.'
  }

  if ($proc) { try { $proc.Dispose() } catch { } ; $proc = $null }
  # Persist any rotated token back to the user's store BEFORE deleting the disposable
  # home, so short-lived-token refresh does not silently expire the source credential.
  $credentialRefreshed = Update-SourceCredential -RuntimeHome $runtimeHome -SourceCredentialsDir $sourceCredentials
  # After writeback: if source is now empty/cleared while the preflight snapshot was
  # valid, restore so a fleet run never leaves the login worse than it started.
  $sourceCredentialRestored = Restore-KimiSourceCredentialIfRegressed -SourceCredentialsDir $sourceCredentials -SnapshotBytes $sourceCredentialSnapshot
  $credentialCleanupVerified = Remove-KimiRuntimeRoot -Path $runtimeRoot
  if ($credentialCleanupVerified) { $runtimeRoot = $null }
  if (-not $credentialCleanupVerified) {
    $cleanupReason = 'Disposable Kimi runtime cleanup failed; copied credentials may remain in the temporary directory.'
    $reason = if ($reason) { $reason + ' ' + $cleanupReason } else { $cleanupReason }
  }

  # status=timeout_partial: design-workspace run was hard-killed at the deadline
  # but incremental export preserved completed files. Distinct from a bare error
  # so the orchestrator can grade the exported core instead of scoring no_contest.
  $status = if ($timeoutPartial) { 'timeout_partial' } elseif ($reason) { 'error' } else { 'ok' }
  $result = [ordered]@{
    status = $status
    model = $ExpectedModel
    model_evidence = 'requested-cli-argument+isolated-config'
    kimi_version = $version
    cli_path = $executable
    cli_sha256 = Get-Sha256 -Path $executable
    effective_config_sha256 = $effectiveConfigSha256
    source_config_sha256 = $sourceConfigSha256
    source_credential_refreshed = [bool]$credentialRefreshed
    source_credential_restored = [bool]$sourceCredentialRestored
    lane = if ($DesignWorkspace) { 'design-workspace' } elseif ($repoSandboxActive) { 'repo-sandbox' } elseif ($ResearchSwarm) { 'research-swarm' } else { 'artifact-only' }
    workspace_files = @($workspaceFiles)
    workspace_export_dir = $workspaceExportDir
    workspace_exported_count = [int]$workspaceExportedCount
    workspace_exported_files = @($exportedPaths.Keys | Sort-Object)
    sandbox_ref_sha = $sandboxSha
    sandbox_file_count = [int]$sandboxFileCount
    sandbox_path = $sandboxPathRecorded
    permission_policy = if ($repoSandboxActive) { 'repo copy-sandbox; Read/Grep/Glob on frozen archive only; no write/shell/web' } elseif ($ResearchSwarm) { 'guarded research-swarm; web+swarm allow, no repo/write/shell; copied media only' } elseif ($DesignWorkspace) { 'design-workspace; Write/Edit/Read scoped to ephemeral workspace only' } else { 'static-deny artifact-only; copied media only' }
    credential_transport = 'ephemeral-home-copy'
    credential_cleanup_verified = [bool]$credentialCleanupVerified
    credential_cleanup_diagnostic = $script:KimiRuntimeCleanupDiagnostic
    auto_update_disabled = $true
    telemetry_disabled = $true
    timeout_seconds = $TimeoutSeconds
    artifact_count = $ArtifactFile.Count
    image_count = $ImageFile.Count
    prompt_bytes = $promptBytes
    prompt_transport = 'file'
    tool_call_count = $toolCalls.Count
    tool_evidence = $toolEvidence
    response_json_valid = $responseJsonValid
    citation_policy = if ($citationApplies) { $CitationPolicy } else { 'not_applicable' }
    citation_verified = [bool]$citationVerified
    cited_url_count = $citedUrls.Count
    fetched_url_count = $fetchedUrls.Count
    cited_but_unfetched = @($citedButUnfetched)
    response = $response
    session_id = $sessionId
    duration_seconds = $duration
    timed_out = [bool](-not $finished)
    exit_code = $exitCode
    fail_reason = $reason
    owner_marker = if ($ownerMarkerStatus) { $ownerMarkerStatus } else { 'failed' }
  }
  if ($reason -and -not [string]::IsNullOrWhiteSpace($stderr)) {
    $result.stderr_tail = @($stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 20)
  }
  Write-Result -Result $result -OutputMode $Mode -Success (-not $reason)
  if ($reason) { exit 1 }
  exit 0
}
catch {
  $failureMessage = $_.Exception.Message
  if ($proc) { Stop-Tree $proc; try { $proc.Dispose() } catch { } ; $proc = $null }
  if ($runtimeRoot) {
    $credentialCleanupVerified = Remove-KimiRuntimeRoot -Path $runtimeRoot
    if ($credentialCleanupVerified) { $runtimeRoot = $null }
  }
  if ($null -eq $credentialCleanupVerified) { $credentialCleanupVerified = $true }
  if (-not $credentialCleanupVerified) { $failureMessage += ' Disposable Kimi runtime cleanup failed; copied credentials may remain in the temporary directory.' }
  # Restore source if this run left it empty/cleared after a valid preflight snapshot.
  if ($null -ne $sourceCredentialSnapshot -and -not [string]::IsNullOrWhiteSpace($sourceCredentialsDir)) {
    $sourceCredentialRestored = Restore-KimiSourceCredentialIfRegressed -SourceCredentialsDir $sourceCredentialsDir -SnapshotBytes $sourceCredentialSnapshot
  }
  $result = [ordered]@{
    status = 'error'
    model = $ExpectedModel
    model_evidence = 'requested-cli-argument+isolated-config'
    response = ''
    prompt_bytes = $promptBytes
    source_credential_restored = [bool]$sourceCredentialRestored
    credential_cleanup_verified = [bool]$credentialCleanupVerified
    credential_cleanup_diagnostic = $script:KimiRuntimeCleanupDiagnostic
    duration_seconds = if ($startedAt) { [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2) } else { 0 }
    timed_out = $false
    exit_code = $null
    fail_reason = $failureMessage
    owner_marker = if ($ownerMarkerStatus) { $ownerMarkerStatus } else { 'failed' }
  }
  Write-Result -Result $result -OutputMode $Mode -Success $false
  exit 1
}
finally {
  if ($proc -and -not $proc.HasExited) { Stop-Tree $proc }
  if ($proc) { try { $proc.Dispose() } catch { } }
  if ($runtimeRoot -and (Test-Path -LiteralPath $runtimeRoot)) { $null = Remove-KimiRuntimeRoot -Path $runtimeRoot }
}
