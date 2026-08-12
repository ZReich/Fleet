# Dot-sourced by Invoke-KimiK3.ps1 (2026-08-12 size split). Functions only; no side effects.
# PS 5.1-safe, ASCII. Uses $script:* state defined by the wrapper before dot-sourcing.
function Test-KimiCredentialEmpty {
  param($CredObject)
  if ($null -eq $CredObject) { return $true }
  $access = [string]$CredObject.access_token
  $refresh = [string]$CredObject.refresh_token
  if ([string]::IsNullOrWhiteSpace($access) -or [string]::IsNullOrWhiteSpace($refresh)) { return $true }
  return $false
}

function Get-KimiSourceCredentialPath {
  param([string]$SourceCredentialsDir)
  return (Join-Path $SourceCredentialsDir 'kimi-code.json')
}

# Fail-fast before any child launch when the source store is empty/cleared.
# Message is actionable and must never include token material.
function Assert-KimiSourceCredential {
  param([string]$SourceCredentialsDir)
  $msg = 'Kimi source credential is empty or cleared ' + [char]0x2014 + ' run `kimi login` in a terminal, then retry. (~/.kimi-code/credentials/kimi-code.json)'
  $srcCred = Get-KimiSourceCredentialPath -SourceCredentialsDir $SourceCredentialsDir
  if (-not (Test-Path -LiteralPath $srcCred -PathType Leaf)) { throw $msg }
  try {
    $cred = Get-Content -Raw -LiteralPath $srcCred | ConvertFrom-Json
  }
  catch { throw $msg }
  if (Test-KimiCredentialEmpty -CredObject $cred) { throw $msg }
}

function Read-KimiSourceCredentialBytes {
  param([string]$SourceCredentialsDir)
  $srcCred = Get-KimiSourceCredentialPath -SourceCredentialsDir $SourceCredentialsDir
  return [IO.File]::ReadAllBytes($srcCred)
}

# Core guarantee: a fleet run never leaves the source worse than it started.
# After writeback, if source is empty/cleared/unreadable while the preflight
# snapshot was a valid non-empty credential, restore snapshot bytes atomically.
function Restore-KimiSourceCredentialIfRegressed {
  param([string]$SourceCredentialsDir, [byte[]]$SnapshotBytes)
  if ($null -eq $SnapshotBytes -or $SnapshotBytes.Length -eq 0) { return $false }
  try {
    $snapText = [Text.Encoding]::UTF8.GetString($SnapshotBytes)
    $snapCred = $snapText | ConvertFrom-Json
    if (Test-KimiCredentialEmpty -CredObject $snapCred) { return $false }
  }
  catch { return $false }
  $srcCred = Get-KimiSourceCredentialPath -SourceCredentialsDir $SourceCredentialsDir
  $needsRestore = $false
  if (-not (Test-Path -LiteralPath $srcCred -PathType Leaf)) {
    $needsRestore = $true
  }
  else {
    try {
      $cur = Get-Content -Raw -LiteralPath $srcCred | ConvertFrom-Json
      if (Test-KimiCredentialEmpty -CredObject $cur) { $needsRestore = $true }
    }
    catch { $needsRestore = $true }
  }
  if (-not $needsRestore) { return $false }
  $tmp = Join-Path $SourceCredentialsDir ('.cred-restore-' + [guid]::NewGuid().ToString('n') + '.tmp')
  try {
    [IO.File]::WriteAllBytes($tmp, $SnapshotBytes)
    Move-Item -LiteralPath $tmp -Destination $srcCred -Force
    return $true
  }
  catch {
    if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    return $false
  }
}

function Update-SourceCredential {
  # Kimi access tokens are short-lived (expires_in ~900s) and its OAuth rotates the
  # refresh_token (single-use). The child refreshes into its disposable home; without
  # writing the rotated credential back to the user's source store, cleanup discards
  # it and auth dies ("login_required") on a later run. Persist when the child holds
  # a non-empty credential AND (refresh_token differs OR expires_at is newer). Empty
  # child credentials are never written back. Atomic temp+Move-Item; never logs tokens.
  param([string]$RuntimeHome, [string]$SourceCredentialsDir)
  try {
    $childCred = Join-Path $RuntimeHome 'credentials\kimi-code.json'
    $srcCred = Get-KimiSourceCredentialPath -SourceCredentialsDir $SourceCredentialsDir
    if (-not (Test-Path -LiteralPath $childCred -PathType Leaf) -or -not (Test-Path -LiteralPath $srcCred -PathType Leaf)) { return $false }
    $child = Get-Content -Raw -LiteralPath $childCred | ConvertFrom-Json
    $src = Get-Content -Raw -LiteralPath $srcCred | ConvertFrom-Json
    if (Test-KimiCredentialEmpty -CredObject $child) { return $false }
    $refreshRotated = ([string]$child.refresh_token -ne [string]$src.refresh_token)
    $expiresNewer = ([int64]$child.expires_at -gt [int64]$src.expires_at)
    if (-not $refreshRotated -and -not $expiresNewer) { return $false }
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
    [string]$PromptFilePath,
    [ValidateSet('low', 'high', 'max')][string]$ThinkingEffort = 'high'
  )
  $source = [IO.File]::ReadAllText($SourceConfig)
  if ($source -match '(?m)^\s*\[\[\s*(permission\.rules|hooks)\s*\]\]' -or $source -match '(?m)^\s*\[\s*permission\s*\]') {
    throw "Kimi source config has user permission rules or hooks; Fleet refuses to compose an ambiguous prompt-mode policy."
  }
  # Fleet thinking-effort override (2026-08-11): rewrite the [thinking] effort so review/
  # security lanes can run 'low' and stay under the provider request deadline on big briefs.
  # -creplace-safe: only the literal effort assignment is rewritten (case-sensitive keys).
  if ($source -cmatch '(?m)^\s*effort\s*=\s*"(low|high|max)"') {
    $source = [regex]::Replace($source, '(?m)^(\s*effort\s*=\s*)"(low|high|max)"', ('${1}"' + $ThinkingEffort + '"'))
  } else {
    $source = $source.TrimEnd() + "`n`n[thinking]`neffort = `"$ThinkingEffort`"`n"
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
  # SOURCE FIRST, rules AFTER. Prepending [[permission.rules]] array-of-tables ahead of
  # the source config makes the source's leading TOP-LEVEL keys (default_model, and the
  # [models.*] tables) parse as members of the last permission.rules table, so kimi sees
  # "no default model configured" and exits 1 (repro'd live on kimi 0.34.0 whose config
  # starts with default_model). The source is guarded to contain NO permission rules, so
  # appending our rules after it keeps allow-before-deny order and cannot collide.
  [IO.File]::WriteAllText($DestinationConfig, ($source.TrimEnd() + "`n`n" + ($rules -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
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

