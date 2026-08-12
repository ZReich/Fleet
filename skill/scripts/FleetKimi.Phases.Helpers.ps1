# Dot-sourced by Invoke-KimiK3.ps1 (2026-08-12 size split). Main-flow phase functions;
# bodies verbatim from the wrapper. PS 5.1-safe, ASCII.
function Resolve-KimiInvocationInput {
  param($Prompt, $PromptFile, [bool]$DesignWorkspace, [bool]$TimeoutBound, $TimeoutSeconds, $ArtifactFile, $ImageFile, $MaxArtifacts, $MaxImageBytes, $RepoSandbox, $RepoSandboxRef, [bool]$ResearchSwarm)
  if ([string]::IsNullOrWhiteSpace($Prompt) -eq [string]::IsNullOrWhiteSpace($PromptFile)) { throw "Provide exactly one of Prompt or PromptFile." }
  if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { throw "PromptFile not found." }
    $Prompt = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path)
  }
  if ([string]::IsNullOrWhiteSpace($Prompt)) { throw "Prompt is empty." }
  if ($DesignWorkspace -and -not $TimeoutBound) { $TimeoutSeconds = 3600 }
  if ($ArtifactFile.Count -gt $MaxArtifacts) { throw "ArtifactFile count exceeds MaxArtifacts." }
  foreach ($artifact in $ArtifactFile) {
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw "ArtifactFile not found." }
  }
  foreach ($image in $ImageFile) {
    if (-not (Test-Path -LiteralPath $image -PathType Leaf)) { throw "ImageFile not found." }
    if ((Get-Item -LiteralPath $image).Length -gt $MaxImageBytes) { throw "ImageFile exceeds MaxImageBytes." }
  }

  $repoSandboxActive = -not [string]::IsNullOrWhiteSpace($RepoSandbox)
  if ($repoSandboxActive) {
    if ($DesignWorkspace) { throw '-RepoSandbox is mutually exclusive with -DesignWorkspace.' }
    if ($ResearchSwarm) { throw '-RepoSandbox is mutually exclusive with -ResearchSwarm.' }
    if (-not (Test-Path -LiteralPath $RepoSandbox)) { throw ("-RepoSandbox path does not exist: {0}" -f $RepoSandbox) }
    $repoSandboxPath = (Resolve-Path -LiteralPath $RepoSandbox).Path
    if ([string]::IsNullOrWhiteSpace($RepoSandboxRef)) { throw '-RepoSandboxRef must be a non-empty committish.' }
    # Native git may write to the error stream; keep Continue so we own the message.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $null = & git -C $repoSandboxPath rev-parse --verify $RepoSandboxRef 2>&1
      $refOk = ($LASTEXITCODE -eq 0)
    }
    finally { $ErrorActionPreference = $prevEap }
    if (-not $refOk) {
      throw ("-RepoSandboxRef '{0}' is not a valid committish in '{1}' (git rev-parse --verify failed)." -f $RepoSandboxRef, $repoSandboxPath)
    }
  }
  else {
    $repoSandboxPath = $null
  }

  return @{ Prompt = $Prompt; TimeoutSeconds = $TimeoutSeconds; RepoSandboxActive = $repoSandboxActive; RepoSandboxPath = $repoSandboxPath }
}

function New-KimiRepoSandboxSnapshot {
  param([string]$repoSandboxPath, [string]$RepoSandboxRef, [string]$sandboxDirectory, [string]$runtimeRoot)
  $sandboxSha = $null; $sandboxFileCount = 0; $sandboxPathRecorded = $null
  if ($true) {
    # Materialize frozen tracked-files snapshot via git archive (temp tar file;
    # never pipe binary through the PowerShell pipeline on Windows).
    # Prefer Windows System32 tar.exe: Git's /usr/bin/tar misparses C: drive paths
    # as remote hosts ("Cannot connect to C: resolve failed").
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tarExe -PathType Leaf)) { throw 'Windows System32 tar.exe not found; required for repo-sandbox materialization.' }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $sandboxSha = (& git -C $repoSandboxPath rev-parse $RepoSandboxRef 2>&1 | Out-String).Trim()
      if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sandboxSha) -or $sandboxSha -match '(?i)fatal:') {
        throw ("Failed to resolve sandbox ref sha for '{0}'." -f $RepoSandboxRef)
      }
      New-Item -ItemType Directory -Force -Path $sandboxDirectory | Out-Null
      $tempTar = Join-Path $runtimeRoot ('repo-sandbox-' + [guid]::NewGuid().ToString('n') + '.tar')
      try {
        & git -C $repoSandboxPath archive --format=tar -o $tempTar $sandboxSha 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ("git archive failed for ref '{0}' (exit {1})." -f $sandboxSha, $LASTEXITCODE) }
        if (-not (Test-Path -LiteralPath $tempTar -PathType Leaf)) { throw 'git archive did not produce a tar file.' }
        & $tarExe -xf $tempTar -C $sandboxDirectory
        if ($LASTEXITCODE -ne 0) { throw ("tar extract of sandbox archive failed (exit {0})." -f $LASTEXITCODE) }
      }
      finally {
        if (Test-Path -LiteralPath $tempTar -PathType Leaf) { Remove-Item -LiteralPath $tempTar -Force -ErrorAction SilentlyContinue }
      }
    }
    finally { $ErrorActionPreference = $prevEap }
    # Belt-and-braces verification: no .git, zero reparse points, file count > 0.
    if (Test-Path -LiteralPath (Join-Path $sandboxDirectory '.git')) { throw 'Repo sandbox verification failed: .git entry present at sandbox root (fail closed).' }
    $null = Assert-NoReparsePointsInTree -Root $sandboxDirectory
    $sandboxFileCount = @(Get-ChildItem -LiteralPath $sandboxDirectory -Recurse -File -Force -ErrorAction Stop).Count
    if ($sandboxFileCount -le 0) { throw 'Repo sandbox verification failed: archive produced zero files (fail closed).' }
    $sandboxPathRecorded = [IO.Path]::GetFullPath($sandboxDirectory)
  }

  return @{ Sha = $sandboxSha; FileCount = $sandboxFileCount; PathRecorded = $sandboxPathRecorded }
}

function Copy-KimiImages {
  param($ImageFile, [string]$imagesDirectory)
  $copiedImages = @()
  $imageIndex = 0
  foreach ($image in $ImageFile) {
    $imageIndex++
    $extension = [IO.Path]::GetExtension($image)
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.bin' }
    $destination = Join-Path $imagesDirectory ('image-{0:D2}{1}' -f $imageIndex, $extension)
    Copy-Item -LiteralPath $image -Destination $destination -Force
    $copiedImages += $destination
  }
  $allowedImagePaths = @($copiedImages | ForEach-Object { [IO.Path]::GetFullPath($_) })

  return @{ Copied = $copiedImages; Allowed = $allowedImagePaths }
}

function New-KimiProcessStartInfo {
  param([string]$executable, $arguments, [string]$runtimeRoot, [string]$runtimeHome)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $executable
  $psi.Arguments = Quote-Arguments -Tokens $arguments
  # Sanity net only: with the static instruction above, argv should stay a few
  # hundred chars regardless of artifact size. A raised cap (was 30000, a value
  # that used to trip on realistic artifact packs) still catches a genuinely
  # pathological runtime path length rather than a normal-sized task.
  if ($psi.Arguments.Length -gt $script:MaxKimiCommandLineChars) {
    throw 'prompt_exceeds_command_line; unexpected after file-based prompt transport - check for an oversized runtime/skills-dir path'
  }
  $psi.WorkingDirectory = $runtimeRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['KIMI_CODE_HOME'] = $runtimeHome
  $psi.EnvironmentVariables['KIMI_DISABLE_TELEMETRY'] = '1'
  $psi.EnvironmentVariables['KIMI_CODE_NO_AUTO_UPDATE'] = '1'
  $psi.EnvironmentVariables['KIMI_CODE_BACKGROUND_KEEP_ALIVE_ON_EXIT'] = '0'
  $psi.EnvironmentVariables['KIMI_DISABLE_CRON'] = '1'
  $psi.EnvironmentVariables['KIMI_MODEL_THINKING_EFFORT'] = 'max'

  return $psi
}

function Get-KimiWorkspaceCapture {
  param([bool]$DesignWorkspace, [string]$workspaceDirectory, $exportRoot, $exportedPaths, $exportBaseline, $exportFailReason, [bool]$finished)
  # Capture/export design-workspace deliverables immediately after the child exits
  # and BEFORE stream-json parse (which can throw) or credential cleanup. Otherwise
  # a parse error would wipe the only copy of HTML/JS prototypes.
  $workspaceFiles = @()
  $workspaceExportDir = $null
  $workspaceExportedCount = 0
  if ($DesignWorkspace -and (Test-Path -LiteralPath $workspaceDirectory)) {
    $wsRoot = [IO.Path]::GetFullPath($workspaceDirectory)
    $workspaceFiles = @(Get-ChildItem -LiteralPath $workspaceDirectory -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($wsRoot.Length).TrimStart('\', '/') -replace '\\', '/' })
  }
  # Final export pass: catch the last writes the poll loop missed (files written
  # between the last poll and process exit). Incremental copies already happened
  # in the wait loop, so a hard-killed run still has its completed files here.
  # Official count = new/changed vs pre-launch baseline only (pre-placed files out).
  if ($exportRoot -and -not $exportFailReason) {
    try {
      Export-WorkspaceIncrement -WorkspaceDirectory $workspaceDirectory -ExportRoot $exportRoot -ExportedPaths $exportedPaths
      $workspaceExportDir = $exportRoot
      $laneExports = @{}
      $exportRootFull = [IO.Path]::GetFullPath($exportRoot)
      foreach ($f in @(Get-ChildItem -LiteralPath $exportRoot -File -Recurse -ErrorAction SilentlyContinue)) {
        $stamp = [string]$f.Length + '|' + $f.LastWriteTimeUtc.Ticks
        if ($exportBaseline.ContainsKey($f.FullName) -and $exportBaseline[$f.FullName] -eq $stamp) { continue }
        $rel = $f.FullName.Substring($exportRootFull.Length).TrimStart('\', '/') -replace '\\', '/'
        $laneExports[$rel] = $true
      }
      $exportedPaths = $laneExports
      $workspaceExportedCount = $exportedPaths.Count
    }
    catch { $exportFailReason = 'Design workspace export failed: ' + $_.Exception.Message }
  }
  $timeoutPartial = ($DesignWorkspace -and -not $finished -and $workspaceExportedCount -gt 0)

  return @{ Files = $workspaceFiles; ExportDir = $workspaceExportDir; Count = $workspaceExportedCount; ExportedPaths = $exportedPaths; FailReason = $exportFailReason; TimeoutPartial = $timeoutPartial }
}

function Read-KimiStreamEvents {
  param([string]$stdout)

  $events = @()
  $assistantText = @()
  $toolCalls = @()
  $sessionId = $null
  foreach ($line in @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Kimi returned invalid stream-json.' }
    $events += $event
    $role = [string](Get-ObjectProperty -Object $event -Name 'role')
    if ($role -eq 'assistant') {
      $toolCalls += @(Get-ToolCallDetails -Event $event)
      $content = Get-ObjectProperty -Object $event -Name 'content'
      if ($null -ne $content -and -not [string]::IsNullOrWhiteSpace([string]$content)) { $assistantText += [string]$content }
    }
    # Kimi emits each tool invocation in the preceding Assistant event. Tool
    # result events vary by CLI version and may omit a stable name, so never
    # infer permission from them; validate the documented Assistant call instead.
    if ($role -eq 'meta' -and [string](Get-ObjectProperty -Object $event -Name 'type') -eq 'session.resume_hint') {
      $sessionId = [string](Get-ObjectProperty -Object $event -Name 'session_id')
    }
  }

  return @{ Events = $events; AssistantText = $assistantText; ToolCalls = $toolCalls; SessionId = $sessionId }
}

function Test-KimiToolCallPolicy {
  param($toolCalls, [string]$promptFilePath, [string]$runtimeRoot, $allowedImagePaths, [bool]$DesignWorkspace, [string]$workspaceDirectory, [bool]$repoSandboxActive, [string]$sandboxDirectory, [bool]$ResearchSwarm)

  $promptFilePathFull = [IO.Path]::GetFullPath($promptFilePath)
  $unsafeToolCall = $false
  $toolEvidence = @()
  foreach ($call in $toolCalls) {
    $inPromptFile = $false
    $candidate = [string]$call.path
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      try {
        $candidatePathForPrompt = if ([IO.Path]::IsPathRooted($candidate)) { [IO.Path]::GetFullPath($candidate) } else { [IO.Path]::GetFullPath((Join-Path $runtimeRoot $candidate)) }
        $inPromptFile = $candidatePathForPrompt.Equals($promptFilePathFull, [StringComparison]::OrdinalIgnoreCase)
      }
      catch { }
    }
    $inCopiedImageWorkspace = $false
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      try {
        $candidatePath = if ([IO.Path]::IsPathRooted($candidate)) { [IO.Path]::GetFullPath($candidate) } else { [IO.Path]::GetFullPath((Join-Path $runtimeRoot $candidate)) }
        $inCopiedImageWorkspace = @($allowedImagePaths | Where-Object { $_.Equals($candidatePath, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
      }
      catch { }
    }
    $inWorkspace = $false
    if ($DesignWorkspace -and -not [string]::IsNullOrWhiteSpace($candidate)) {
      try {
        $candidatePath = if ([IO.Path]::IsPathRooted($candidate)) { [IO.Path]::GetFullPath($candidate) } else { [IO.Path]::GetFullPath((Join-Path $workspaceDirectory $candidate)) }
        $wsFull = [IO.Path]::GetFullPath($workspaceDirectory).TrimEnd('\')
        $inWorkspace = ($candidatePath + '\').StartsWith($wsFull + '\', [StringComparison]::OrdinalIgnoreCase) -or $candidatePath.Equals($wsFull, [StringComparison]::OrdinalIgnoreCase)
      }
      catch { }
    }
    $inSandbox = $false
    if ($repoSandboxActive -and -not [string]::IsNullOrWhiteSpace($candidate)) {
      try {
        $candidatePath = if ([IO.Path]::IsPathRooted($candidate)) { [IO.Path]::GetFullPath($candidate) } else { [IO.Path]::GetFullPath((Join-Path $sandboxDirectory $candidate)) }
        $sbFull = [IO.Path]::GetFullPath($sandboxDirectory).TrimEnd('\')
        $inSandbox = ($candidatePath + '\').StartsWith($sbFull + '\', [StringComparison]::OrdinalIgnoreCase) -or $candidatePath.Equals($sbFull, [StringComparison]::OrdinalIgnoreCase)
      }
      catch { }
    }
    $toolEvidence += [pscustomobject]@{ name = [string]$call.name; copied_image_path = [bool]$inCopiedImageWorkspace; in_workspace = [bool]$inWorkspace; in_sandbox = [bool]$inSandbox; in_prompt_file = [bool]$inPromptFile }
    $callAllowed = $false
    if ($script:KimiBenignAlwaysTools -contains [string]$call.name) { $callAllowed = $true }
    elseif ([string]$call.name -eq 'Read' -and $inPromptFile) { $callAllowed = $true }
    elseif ([string]$call.name -eq 'ReadMediaFile' -and $inCopiedImageWorkspace) { $callAllowed = $true }
    elseif ($ResearchSwarm -and ($script:ResearchSwarmAllowTools -contains [string]$call.name)) { $callAllowed = $true }
    elseif ($DesignWorkspace -and ($script:DesignWorkspaceScopedTools -contains [string]$call.name) -and $inWorkspace) { $callAllowed = $true }
    elseif ($repoSandboxActive -and ($script:RepoSandboxScopedTools -contains [string]$call.name) -and $inSandbox) { $callAllowed = $true }
    if (-not $callAllowed) { $unsafeToolCall = $true; break }
  }
  return @{ Unsafe = $unsafeToolCall; Evidence = $toolEvidence }
}


