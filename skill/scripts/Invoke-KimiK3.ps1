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
  [int]$MaxImageBytes = 26214400
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
# Windows CreateProcess command-line ceiling is 32767. The prompt itself now rides a
# file (see prompt-file transport below), so this only guards a pathological runtime
# path length, not artifact size - raised close to the real ceiling with headroom.
$script:MaxKimiCommandLineChars = 32000
$script:KimiRuntimeCleanupDiagnostic = 'not-run'

# Per-root owner marker for Clear-StaleKimiK3Runtime: { pid, start_time 'o' }.
# Never throws the lane; caller records written|failed.
function Write-KimiOwnerMarker {
  param([string]$Root, [int]$OwnerPid, [datetime]$StartTime)
  if ($env:FLEET_KIMI_OWNER_MARKER_FAIL -eq '1') { throw 'forced owner marker write failure' }
  $payload = (@{ pid = $OwnerPid; start_time = $StartTime.ToString('o') } | ConvertTo-Json -Compress)
  [IO.File]::WriteAllText((Join-Path $Root 'owner.json'), $payload, (New-Object Text.UTF8Encoding($false)))
}

# Canonical CommandLineToArgvW-compatible quoting. The prior regex form doubled
# every embedded quote to \\" (backslash + closing quote), which truncated any
# prompt containing a " and leaked the tail as separate CLI tokens. This walks
# backslash runs and emits 2n+1 backslashes before an embedded quote and 2n before
# the closing quote, per Microsoft's argv-quoting rules.
function Quote-Argument {
  param([string]$Arg)
  if ($Arg.Length -gt 0 -and $Arg -notmatch '[ \t\n\v"]') { return $Arg }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $i = 0
  while ($i -lt $Arg.Length) {
    $backslashes = 0
    while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') { $i++; $backslashes++ }
    if ($i -eq $Arg.Length) { [void]$sb.Append('\' * ($backslashes * 2)); break }
    elseif ($Arg[$i] -eq '"') { [void]$sb.Append('\' * ($backslashes * 2 + 1)); [void]$sb.Append('"'); $i++ }
    else { [void]$sb.Append('\' * $backslashes); [void]$sb.Append($Arg[$i]); $i++ }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Quote-Arguments {
  param([string[]]$Tokens)
  (($Tokens | ForEach-Object { Quote-Argument -Arg ([string]$_) }) -join " ")
}

function Stop-Tree {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try { $processId = $Process.Id } catch { return }
  try { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null } catch { }
  try { $null = $Process.WaitForExit(5000) } catch { }
}

function Get-KimiRuntimeTreeStamp {
  param([string]$Path)
  try {
    $items = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)
    $latest = @($items | ForEach-Object { $_.LastWriteTimeUtc.Ticks } | Measure-Object -Maximum).Maximum
    return ('{0}:{1}' -f $items.Count, $latest)
  }
  catch { return $null }
}

function Wait-KimiRuntimeQuiescence {
  param([string]$Path)
  $previous = $null
  $stableIntervals = 0
  foreach ($sample in 1..8) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $current = Get-KimiRuntimeTreeStamp -Path $Path
    if ($null -ne $current -and $current -eq $previous) { $stableIntervals++ } else { $stableIntervals = 0 }
    if ($stableIntervals -ge 2) { return $true }
    $previous = $current
    Start-Sleep -Milliseconds 100
  }
  return $false
}

function Remove-KimiRuntimeRoot {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { $script:KimiRuntimeCleanupDiagnostic = 'not-needed'; return $true }
  $tempRoot = ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\')
  $sourcePath = [IO.Path]::GetFullPath($Path)
  if (-not ($sourcePath.StartsWith(($tempRoot + '\fleet-kimi-k3-'), [StringComparison]::OrdinalIgnoreCase))) { throw 'Refusing to clean a Kimi runtime path outside the dedicated temporary prefix.' }
  # A Kimi prompt can finish before its asynchronous session writer releases
  # the data root. First move the whole disposable root out of its expected
  # location, then delete the moved directory; a late write cannot recreate
  # credentials at the path the prompt session was using.
  $cleanupPath = $Path
  $quarantine = Join-Path (Split-Path -Parent $Path) ('fleet-kimi-k3-cleanup-' + [guid]::NewGuid().ToString('n'))
  try {
    Move-Item -LiteralPath $Path -Destination $quarantine -ErrorAction Stop
    $cleanupPath = $quarantine
    $script:KimiRuntimeCleanupDiagnostic = 'quarantined'
  }
  catch { $script:KimiRuntimeCleanupDiagnostic = ('quarantine-failed:{0}' -f $_.Exception.GetType().Name) }
  if (-not (Wait-KimiRuntimeQuiescence -Path $cleanupPath)) {
    $script:KimiRuntimeCleanupDiagnostic = 'runtime-still-writing'
    return $false
  }
  $cleanupCandidates = @($cleanupPath, $Path) | Select-Object -Unique
  foreach ($attempt in 1..8) {
    foreach ($candidate in $cleanupCandidates) {
      if (Test-Path -LiteralPath $candidate) {
        $candidatePath = [IO.Path]::GetFullPath($candidate)
        if (-not ($candidatePath.StartsWith(($tempRoot + '\fleet-kimi-k3-'), [StringComparison]::OrdinalIgnoreCase))) { throw 'Refusing to delete a Kimi runtime path outside the dedicated temporary prefix.' }
        $extendedPath = if ($candidatePath.StartsWith('\\?\')) { $candidatePath } else { '\\?\' + $candidatePath }
        try { [IO.Directory]::Delete($extendedPath, $true) }
        catch {
          $kind = if ($_.Exception.InnerException) { $_.Exception.InnerException.GetType().Name } else { $_.Exception.GetType().Name }
          $script:KimiRuntimeCleanupDiagnostic = ('remove-failed:{0}' -f $kind)
        }
      }
    }
    if (-not (Test-Path -LiteralPath $cleanupPath) -and -not (Test-Path -LiteralPath $Path)) {
      Start-Sleep -Milliseconds 500
      if (-not (Test-Path -LiteralPath $cleanupPath) -and -not (Test-Path -LiteralPath $Path)) {
        $script:KimiRuntimeCleanupDiagnostic = 'removed-and-stable'
        return $true
      }
    }
    Start-Sleep -Milliseconds 500
  }
  if ($script:KimiRuntimeCleanupDiagnostic -eq 'not-run') { $script:KimiRuntimeCleanupDiagnostic = 'path-remained-after-retries' }
  return (-not (Test-Path -LiteralPath $cleanupPath) -and -not (Test-Path -LiteralPath $Path))
}

function Update-SourceCredential {
  # Kimi access tokens are short-lived (expires_in ~900s) and its OAuth rotates the
  # refresh_token. The child refreshes into its disposable home; without writing the
  # rotated credential back to the user's source store, cleanup discards it and auth
  # dies ("login_required") on a later run. This writes ONLY the user's own rotated
  # credential back to their own store, atomically, and never logs the token.
  param([string]$RuntimeHome, [string]$SourceCredentialsDir)
  try {
    $childCred = Join-Path $RuntimeHome 'credentials\kimi-code.json'
    $srcCred = Join-Path $SourceCredentialsDir 'kimi-code.json'
    if (-not (Test-Path -LiteralPath $childCred -PathType Leaf) -or -not (Test-Path -LiteralPath $srcCred -PathType Leaf)) { return $false }
    $child = Get-Content -Raw -LiteralPath $childCred | ConvertFrom-Json
    $src = Get-Content -Raw -LiteralPath $srcCred | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$child.access_token) -or [string]::IsNullOrWhiteSpace([string]$child.refresh_token)) { return $false }
    if ([int64]$child.expires_at -le [int64]$src.expires_at) { return $false }  # only when the child rotated to a newer token
    $tmp = Join-Path $SourceCredentialsDir ('.cred-' + [guid]::NewGuid().ToString('n') + '.tmp')
    Copy-Item -LiteralPath $childCred -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $srcCred -Force
    return $true
  }
  catch { return $false }
}

# Incremental design-workspace export: copy new/changed workspace files to the
# export root as K3 writes them, so a hard timeout kill cannot destroy completed
# files. Locked/mid-write files are skipped and retried on the next poll; the
# post-exit final pass catches the last state. ExportedPaths accumulates every
# relative path ever exported (cumulative), so a file the model later deletes
# still counts as preserved on disk.
function Export-WorkspaceIncrement {
  param([string]$WorkspaceDirectory, [string]$ExportRoot, [hashtable]$ExportedPaths)
  if ([string]::IsNullOrWhiteSpace($ExportRoot) -or -not (Test-Path -LiteralPath $WorkspaceDirectory)) { return }
  $wsRoot = [IO.Path]::GetFullPath($WorkspaceDirectory)
  foreach ($file in @(Get-ChildItem -LiteralPath $WorkspaceDirectory -Recurse -File -ErrorAction SilentlyContinue)) {
    $rel = $file.FullName.Substring($wsRoot.Length).TrimStart('\', '/')
    $dest = Join-Path $ExportRoot $rel
    $needCopy = $true
    $existing = Get-Item -LiteralPath $dest -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length -eq $file.Length -and $existing.LastWriteTimeUtc -ge $file.LastWriteTimeUtc) { $needCopy = $false }
    if ($needCopy) {
      try {
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
      }
      catch { continue }
    }
    $ExportedPaths[($rel -replace '\\', '/')] = $true
  }
}

function Get-KimiExecutable {
  if ($env:FLEET_KIMI_EXECUTABLE) {
    if (-not (Test-Path -LiteralPath $env:FLEET_KIMI_EXECUTABLE -PathType Leaf)) { throw "FLEET_KIMI_EXECUTABLE does not exist." }
    return (Resolve-Path -LiteralPath $env:FLEET_KIMI_EXECUTABLE).Path
  }
  $managed = Join-Path $env:USERPROFILE ".kimi-code\\bin\\kimi.exe"
  if (Test-Path -LiteralPath $managed -PathType Leaf) { return (Resolve-Path -LiteralPath $managed).Path }
  $command = Get-Command kimi.exe, kimi.cmd, kimi -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $command) { throw "Kimi Code executable not found." }
  return [string]$command.Source
}

function Get-KimiVersion {
  param([string]$Executable)
  $versionText = (& $Executable --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^\d+\.\d+\.\d+([-.][A-Za-z0-9._-]+)?$') { throw "Unable to determine Kimi Code version." }
  return $versionText
}

function Get-Sha256 {
  param([string]$Path)
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ObjectProperty {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-ToolCallDetails {
  param($Event)
  $calls = Get-ObjectProperty -Object $Event -Name "tool_calls"
  if ($null -eq $calls) { return @() }
  $details = @()
  foreach ($call in @($calls)) {
    $name = [string](Get-ObjectProperty -Object $call -Name "name")
    if ([string]::IsNullOrWhiteSpace($name)) {
      $function = Get-ObjectProperty -Object $call -Name "function"
      $name = [string](Get-ObjectProperty -Object $function -Name "name")
    }
    $arguments = Get-ObjectProperty -Object $call -Name "arguments"
    if ($null -eq $arguments) {
      $function = Get-ObjectProperty -Object $call -Name "function"
      $arguments = Get-ObjectProperty -Object $function -Name "arguments"
    }
    if ($null -eq $arguments) { $arguments = Get-ObjectProperty -Object $call -Name "input" }
    if ($arguments -is [string]) {
      try { $arguments = $arguments | ConvertFrom-Json -ErrorAction Stop } catch { }
    }
    $path = [string](Get-ObjectProperty -Object $arguments -Name "path")
    $url = [string](Get-ObjectProperty -Object $arguments -Name "url")
    if ([string]::IsNullOrWhiteSpace($url)) { $url = [string](Get-ObjectProperty -Object $arguments -Name "query") }
    $details += [pscustomobject]@{ name = $name; path = $path; url = $url }
  }
  return @($details)
}

function Get-NormalizedUrl {
  param([string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
  $u = $Url.Trim().TrimEnd('.', ',', ')', ']', '>', '"', "'")
  try { $u = [Uri]::UnescapeDataString($u) } catch { }
  # Canonicalize arXiv references to a bare id form so abs/pdf and URL/ID forms match.
  $ax = [regex]::Match($u, '(?i)arxiv\.org/(?:abs|pdf)/(\d{4}\.\d{4,5})')
  if ($ax.Success) { return 'arxiv:' + $ax.Groups[1].Value }
  $bareAx = [regex]::Match($u, '(?i)arxiv:?\s*(\d{4}\.\d{4,5})')
  if ($bareAx.Success -and $u -notmatch '://') { return 'arxiv:' + $bareAx.Groups[1].Value }
  $m = [regex]::Match($u, '(?i)^https?://([^/\s]+)(/[^\s#]*)?')
  if (-not $m.Success) { return $u.ToLowerInvariant() }
  $urlHost = $m.Groups[1].Value.ToLowerInvariant() -replace '^www\.', ''
  $pathPart = ($m.Groups[2].Value -replace '#.*$', '').TrimEnd('/')
  return $urlHost + $pathPart
}

function Get-CitedUrls {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
  $set = @{}
  foreach ($m in [regex]::Matches($Text, '(?i)https?://[^\s)\]}>"''`]+')) { $n = Get-NormalizedUrl $m.Value; if ($n) { $set[$n] = $true } }
  foreach ($m in [regex]::Matches($Text, '(?i)arxiv[:\s]+(\d{4}\.\d{4,5})')) { $set[('arxiv:' + $m.Groups[1].Value)] = $true }
  return @($set.Keys)
}

# Research-swarm allow set: the only tools opened beyond copied-image reads when
# -ResearchSwarm is set. Kept in one place so the config writer and the runtime
# tool-call validator agree on exactly what is permitted.
$script:ResearchSwarmAllowTools = @('AgentSwarm', 'Agent', 'TaskList', 'TaskOutput', 'TaskStop', 'WebSearch', 'FetchURL')
# Design-workspace lane: Write/Edit/Read scoped to the ephemeral workspace ONLY. No repo,
# shell, web, or subagents. Lets K3 iterate a runnable visual/3D prototype in a sandbox.
$script:DesignWorkspaceScopedTools = @('Write', 'Edit', 'Read', 'ReadMediaFile')
# Repo copy-sandbox lane: read-only file tools scoped to the frozen archive snapshot.
# Bare denys stay in place; scoped allows win first-match for paths under the sandbox.
$script:RepoSandboxScopedTools = @('Read', 'Grep', 'Glob')

function Assert-NoReparsePointsInTree {
  # Belt-and-braces for repo-sandbox materialization: git archive cannot emit
  # reparse points, but we refuse any junction/symlink before K3 launch. Walk
  # without descending into reparse points (mirrors Invoke-Grok45 idiom).
  param([string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return 0 }
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $stack = New-Object System.Collections.Stack
  $stack.Push($rootFull)
  $reparseCount = 0
  while ($stack.Count -gt 0) {
    $dir = [string]$stack.Pop()
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
      $isReparse = (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
      if ($isReparse) {
        $reparseCount++
        continue  # never descend into a reparse point
      }
      if ($child.PSIsContainer) { $stack.Push([string]$child.FullName) }
    }
  }
  if ($reparseCount -gt 0) {
    throw ("Repo sandbox reparse verification failed: found {0} reparse point(s) under '{1}'. Fail closed." -f $reparseCount, $rootFull)
  }
  return $reparseCount
}

function New-GuardedRuntimeConfig {
  param(
    [string]$SourceConfig,
    [string]$DestinationConfig,
    [string]$ImagesDirectory,
    [bool]$AllowImageRead,
    [bool]$ResearchSwarm,
    [string]$WorkspaceDirectory,
    [bool]$DesignWorkspace,
    [string]$SandboxDirectory,
    [bool]$RepoSandbox,
    [string]$PromptFilePath
  )
  $source = [IO.File]::ReadAllText($SourceConfig)
  if ($source -match '(?m)^\s*\[\[\s*(permission\.rules|hooks)\s*\]\]' -or $source -match '(?m)^\s*\[\s*permission\s*\]') {
    throw "Kimi source config has user permission rules or hooks; Fleet refuses to compose an ambiguous prompt-mode policy."
  }
  $rules = New-Object Collections.Generic.List[string]
  # Prompt-file transport (audit fix 2026-08-03): kimi 0.31.1 has no --prompt-file or
  # stdin flag for -p, so a large task (artifact packs) previously rode argv straight
  # into the Windows command-line ceiling. The full task spec is now written to one
  # frozen file under the runtime root and Read is scoped to exactly that path; -p
  # itself only carries a short static instruction to read it. Unconditional across
  # every lane (artifact-only/research/design/repo-sandbox all use it).
  if ($PromptFilePath) {
    $rules.Add('[[permission.rules]]')
    $rules.Add('decision = "allow"')
    $rules.Add(('pattern = "Read({0})"' -f ($PromptFilePath -replace '\\', '/')))
    $rules.Add('scope = "session-runtime"')
    $rules.Add('reason = "Fleet prompt-file transport; full task spec delivered by file, not argv"')
    $rules.Add('')
  }
  if ($AllowImageRead) {
    $imagePattern = (($ImagesDirectory -replace '\\', '/') + '/*')
    $rules.Add('[[permission.rules]]')
    $rules.Add('decision = "allow"')
    $rules.Add(('pattern = "ReadMediaFile({0})"' -f $imagePattern))
    $rules.Add('scope = "session-runtime"')
    $rules.Add('reason = "Fleet copied visual evidence only"')
    $rules.Add('')
  }
  # Allow rules come first so they win over the bare deny of the same tool name.
  # Repository read/write, shell, plan, cron, MCP, and skills stay denied in
  # both lanes; research only adds web research and sub-agent fan-out.
  if ($ResearchSwarm) {
    foreach ($tool in $script:ResearchSwarmAllowTools) {
      $rules.Add('[[permission.rules]]')
      $rules.Add('decision = "allow"')
      $rules.Add(('pattern = "{0}"' -f $tool))
      $rules.Add('scope = "session-runtime"')
      $rules.Add('reason = "Fleet guarded research-swarm lane"')
      $rules.Add('')
    }
  }
  # Design-workspace: allow Write/Edit/Read/ReadMediaFile SCOPED to the workspace path
  # only. The bare tool names stay denied below, so writes outside the workspace fail.
  if ($DesignWorkspace) {
    $wsPattern = (($WorkspaceDirectory -replace '\\', '/') + '/*')
    foreach ($tool in $script:DesignWorkspaceScopedTools) {
      $rules.Add('[[permission.rules]]')
      $rules.Add('decision = "allow"')
      $rules.Add(('pattern = "{0}({1})"' -f $tool, $wsPattern))
      $rules.Add('scope = "session-runtime"')
      $rules.Add('reason = "Fleet design-workspace lane; ephemeral workspace only"')
      $rules.Add('')
    }
  }
  # Repo copy-sandbox: allow Read/Grep/Glob SCOPED to the frozen archive path only.
  # Bare denys stay; shell/web/write/subagents remain denied.
  if ($RepoSandbox) {
    $sbPattern = (($SandboxDirectory -replace '\\', '/') + '/*')
    foreach ($tool in $script:RepoSandboxScopedTools) {
      $rules.Add('[[permission.rules]]')
      $rules.Add('decision = "allow"')
      $rules.Add(('pattern = "{0}({1})"' -f $tool, $sbPattern))
      $rules.Add('scope = "session-runtime"')
      $rules.Add('reason = "Fleet repo copy-sandbox lane; frozen archive only"')
      $rules.Add('')
    }
  }
  $denyReason = if ($ResearchSwarm) { 'Fleet guarded research-swarm lane' } elseif ($DesignWorkspace) { 'Fleet design-workspace lane' } elseif ($RepoSandbox) { 'Fleet repo copy-sandbox lane' } else { 'Fleet artifact-only K3 lane' }
  $denyTools = @('Read', 'Write', 'Edit', 'Grep', 'Glob', 'ReadMediaFile', 'Bash', 'WebSearch', 'FetchURL', 'EnterPlanMode', 'ExitPlanMode', 'TodoList', 'Agent', 'AgentSwarm', 'AskUserQuestion', 'Skill', 'TaskList', 'TaskOutput', 'TaskStop', 'CronCreate', 'CronList', 'CronDelete', 'ToolSearch', 'MCP', 'Mcp', 'McpTool', 'mcp__*')
  if ($ResearchSwarm) { $denyTools = @($denyTools | Where-Object { $script:ResearchSwarmAllowTools -notcontains $_ }) }
  foreach ($tool in $denyTools) {
    $rules.Add('[[permission.rules]]')
    $rules.Add('decision = "deny"')
    $rules.Add(('pattern = "{0}"' -f $tool))
    $rules.Add('scope = "session-runtime"')
    $rules.Add(('reason = "{0}"' -f $denyReason))
    $rules.Add('')
  }
  [IO.File]::WriteAllText($DestinationConfig, (($rules -join "`n") + "`n" + $source), (New-Object Text.UTF8Encoding($false)))
}

function New-KimiPrompt {
  param(
    [string]$Request,
    [string[]]$Artifacts,
    [string[]]$Images,
    [int]$MaxBytes,
    [bool]$ResearchSwarm,
    [bool]$DesignWorkspace,
    [string]$WorkspaceDirectory,
    [bool]$RepoSandbox,
    [string]$SandboxDirectory,
    [string]$SandboxSha
  )
  $parts = New-Object Collections.Generic.List[string]
  $parts.Add('NOTE: this file was loaded via the one Read call already permitted for transport (loading this brief). Do not call Read again on this or any other path unless a lane rule below explicitly scopes it.')
  # Static lane preamble only before REQUEST (cache-contract: no temp paths/GUIDs
  # in the stable prefix). Dynamic workspace/sandbox paths land AFTER REQUEST.
  if ($DesignWorkspace) {
    $parts.Add('FLEET KIMI K3 DESIGN-WORKSPACE LANE.')
    $parts.Add('You are a visual/UI/3D design candidate. Build a runnable prototype (HTML/CSS/JS/React/three.js) to satisfy the request.')
    $parts.Add('You may Write/Edit/Read files ONLY under the workspace directory named after REQUEST. Any path outside it, plus repository read, shell, web, and sub-agents, are forbidden and fail the run. Put your final deliverable files in that workspace and summarize them in your response.')
  }
  elseif ($RepoSandbox) {
    $parts.Add('FLEET KIMI K3 REPO COPY-SANDBOX LANE.')
    $parts.Add('You are a security/adversarial review candidate. Analyze the frozen repository copy named after REQUEST. Do not run shell, write or edit files, use web tools, or spawn sub-agents. Any other tool attempt is a failed run.')
  }
  elseif ($ResearchSwarm) {
    $parts.Add('FLEET KIMI K3 RESEARCH-SWARM LANE.')
    # Self-arm against host-file reaches: briefs often name local docs; the model
    # must not attempt Read/filesystem tools (wrapper fail-closed would discard work).
    $parts.Add('TOOLING CONSTRAINT: no file tools are available beyond the Read call already used to load this brief. Do not call Read again, ReadMediaFile, or any other filesystem tool. Use WebSearch and FetchURL only. Any document mentioned in this brief is either quoted inline or out of scope.')
    $parts.Add('You are a research and red-team candidate. Answer the request using the frozen brief below plus open-web research.')
    $webRules = 'You may fan out a sub-agent swarm (AgentSwarm/Agent) and use WebSearch/FetchURL for read-only research. Do not read this repository, run shell, write or edit files, or use any other tool. Any other tool attempt is a failed run. Every external claim must cite its source and state uncertainty; do not assert repository, filesystem, or host facts not present in the supplied evidence. Cite ONLY URLs you yourself fetched THIS run via FetchURL with a successful response; a URL a sub-agent fetched does not count until you re-fetch it. Before finalizing, emit a CITATIONS: block listing every cited URL; delete any claim whose URL you cannot list there or rewrite it as "no verifiable source." Cited URLs you did not fetch will fail the run.'
    if ($Images.Count) { $webRules += ' You may also call ReadMediaFile for the copied visual-evidence paths below.' }
    $parts.Add($webRules)
  }
  else {
    $parts.Add('FLEET KIMI K3 ARTIFACT-ONLY LANE.')
    $parts.Add('You are a planning, design-critique, or red-team candidate. Analyze only this request and the frozen evidence below.')
    if ($Images.Count) {
      $parts.Add('Do not call any tool other than the Read call already used to load this file, and ReadMediaFile for the copied visual-evidence paths below. Any other tool attempt is a failed run. Do not claim repository, web, filesystem, or external facts not contained in the supplied evidence.')
    }
    else {
      $parts.Add('Do not call any tool other than the Read call already used to load this file. Any other tool attempt is a failed run. Do not claim repository, web, filesystem, or external facts not contained in the supplied evidence.')
    }
  }
  $parts.Add('Do not make final architecture, API, security, product, or shipping decisions. State uncertainty and evidence gaps explicitly.')
  $parts.Add('Return direct, auditable prose unless the request explicitly asks for JSON. Do not wrap the answer in a code fence.')
  $parts.Add('')
  $parts.Add('REQUEST:')
  $parts.Add($Request)
  $parts.Add('')
  if ($DesignWorkspace) {
    $parts.Add(('WORKSPACE DIRECTORY: {0}' -f ($WorkspaceDirectory -replace '\\', '/')))
    $parts.Add('')
  }
  elseif ($RepoSandbox) {
    $parts.Add(('REPO SANDBOX: a frozen copy of the repository (tracked files at {0}) is at {1}. Read any file in it freely with your file tools. This is a COPY - there is no live repository, no .git, no secrets; paths outside this sandbox are off-limits and attempts to read them invalidate the run.' -f $SandboxSha, ($SandboxDirectory -replace '\\', '/')))
    $parts.Add('')
  }
  $index = 0
  foreach ($artifact in $Artifacts) {
    $index++
    $info = Get-Item -LiteralPath $artifact
    if ($info.Length -gt $MaxBytes) { throw "Artifact $index exceeds MaxArtifactBytes." }
    $content = [IO.File]::ReadAllText($artifact)
    $sha = Get-Sha256 -Path $artifact
    $parts.Add(('FROZEN ARTIFACT {0} (sha256={1}; bytes={2}):' -f $index, $sha, $info.Length))
    $parts.Add($content)
    $parts.Add(('END FROZEN ARTIFACT {0}' -f $index))
    $parts.Add('')
  }
  if ($Images.Count) {
    $parts.Add('COPIED VISUAL EVIDENCE:')
    foreach ($image in $Images) { $parts.Add(('- {0}' -f $image)) }
    $parts.Add('Read only the copied visual evidence above with ReadMediaFile when it is needed. Do not use any other tool.')
  }
  return ($parts -join "`n")
}

function Write-Result {
  param($Result, [string]$OutputMode, [bool]$Success)
  if ($OutputMode -eq "json") { Write-Output ($Result | ConvertTo-Json -Compress -Depth 10) }
  elseif ($Success) {
    # Design-workspace deliverable is exported files, not chat text. Always emit a
    # non-empty manifest so callers redirecting stdout cannot confuse success with death.
    if ([string]$Result.lane -eq 'design-workspace') {
      $exportDir = [string]$Result.workspace_export_dir
      $files = @($Result.workspace_exported_files)
      $count = [int]$Result.workspace_exported_count
      $parts = New-Object System.Collections.Generic.List[string]
      $parts.Add(('status: {0}' -f $Result.status))
      $parts.Add(('workspace_export_dir: {0}' -f $exportDir))
      $parts.Add(('workspace_exported_count: {0}' -f $count))
      if ($files.Count -eq 0) {
        $parts.Add('no files exported')
      } else {
        foreach ($rel in $files) {
          $bytes = 0
          if (-not [string]::IsNullOrWhiteSpace($exportDir)) {
            $full = Join-Path $exportDir $rel
            if (Test-Path -LiteralPath $full -PathType Leaf) {
              $bytes = [int64](Get-Item -LiteralPath $full).Length
            }
          }
          $parts.Add(('{0} {1} bytes' -f $rel, $bytes))
        }
      }
      $response = [string]$Result.response
      if (-not [string]::IsNullOrEmpty($response)) { $parts.Add($response) }
      Write-Output ($parts -join "`n")
    }
    else { Write-Output ([string]$Result.response) }
  }
  else { [Console]::Error.WriteLine(($Result | ConvertTo-Json -Compress -Depth 10)) }
}

try {
  if ([string]::IsNullOrWhiteSpace($Prompt) -eq [string]::IsNullOrWhiteSpace($PromptFile)) { throw "Provide exactly one of Prompt or PromptFile." }
  if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { throw "PromptFile not found." }
    $Prompt = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path)
  }
  if ([string]::IsNullOrWhiteSpace($Prompt)) { throw "Prompt is empty." }
  if ($DesignWorkspace -and -not $PSBoundParameters.ContainsKey('TimeoutSeconds')) { $TimeoutSeconds = 3600 }
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

  $executable = Get-KimiExecutable
  $version = Get-KimiVersion -Executable $executable
  $sourceHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $env:USERPROFILE '.kimi-code' }
  $sourceConfig = Join-Path $sourceHome 'config.toml'
  if (-not (Test-Path -LiteralPath $sourceConfig -PathType Leaf)) { throw "Kimi source config.toml not found." }
  $sourceCredentials = Join-Path $sourceHome 'credentials'
  if (-not (Test-Path -LiteralPath $sourceCredentials -PathType Container)) { throw "Kimi credential store not found." }

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

  # Prompt-file transport path: known before content is written so the permission
  # rule can be composed ahead of the actual New-KimiPrompt call below.
  $promptFilePath = Join-Path $runtimeRoot 'prompt.txt'

  $runtimeConfig = Join-Path $runtimeHome 'config.toml'
  New-GuardedRuntimeConfig -SourceConfig $sourceConfig -DestinationConfig $runtimeConfig -ImagesDirectory $imagesDirectory -AllowImageRead ([bool]$ImageFile.Count) -ResearchSwarm ([bool]$ResearchSwarm) -WorkspaceDirectory $workspaceDirectory -DesignWorkspace ([bool]$DesignWorkspace) -SandboxDirectory $sandboxDirectory -RepoSandbox ([bool]$repoSandboxActive) -PromptFilePath $promptFilePath
  $effectiveConfigSha256 = Get-Sha256 -Path $runtimeConfig
  $sourceConfigSha256 = Get-Sha256 -Path $sourceConfig
  # OAuth is file-backed in Kimi Code. Copy it only into this disposable home;
  # never print, hash, retain, or reuse it after the child process exits.
  Copy-Item -LiteralPath $sourceCredentials -Destination (Join-Path $runtimeHome 'credentials') -Recurse -Force

  $sourceTui = Join-Path $sourceHome 'tui.toml'
  if (Test-Path -LiteralPath $sourceTui -PathType Leaf) {
    Copy-Item -LiteralPath $sourceTui -Destination (Join-Path $runtimeHome 'tui.toml') -Force
  }

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
  $normalizedPromptFilePath = $promptFilePath -replace '\\', '/'
  $staticPrompt = "FLEET KIMI K3 FILE-PROMPT TRANSPORT. PROMPT_FILE: $normalizedPromptFilePath`nUse your Read tool to read PROMPT_FILE (that exact path) exactly once now. Its content is your complete task: lane rules, the request, and any frozen artifacts. Follow every instruction in it precisely and respond exactly as it specifies. Do not read any other path with the Read tool. If the Read call on that exact path is denied or fails, report that failure verbatim instead of guessing content."
  # Keep parser options before the (now short, fixed-size) prompt arg. This avoids
  # Windows command shim edge cases while preserving the native Kimi CLI arg contract.
  $arguments = @('--model', $ExpectedModel, '--skills-dir', $skillsDirectory, '--output-format', 'stream-json', '--prompt', $staticPrompt)
  if (@($arguments | Where-Object { $_ -in @('--yolo', '--auto', '--plan', '-y') }).Count) { throw 'Unsafe Kimi flag construction blocked.' }

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
    if ([string]$call.name -eq 'Read' -and $inPromptFile) { $callAllowed = $true }
    elseif ([string]$call.name -eq 'ReadMediaFile' -and $inCopiedImageWorkspace) { $callAllowed = $true }
    elseif ($ResearchSwarm -and ($script:ResearchSwarmAllowTools -contains [string]$call.name)) { $callAllowed = $true }
    elseif ($DesignWorkspace -and ($script:DesignWorkspaceScopedTools -contains [string]$call.name) -and $inWorkspace) { $callAllowed = $true }
    elseif ($repoSandboxActive -and ($script:RepoSandboxScopedTools -contains [string]$call.name) -and $inSandbox) { $callAllowed = $true }
    if (-not $callAllowed) { $unsafeToolCall = $true; break }
  }
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
  $result = [ordered]@{
    status = 'error'
    model = $ExpectedModel
    model_evidence = 'requested-cli-argument+isolated-config'
    response = ''
    prompt_bytes = $promptBytes
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
