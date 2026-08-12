# Dot-sourced by Invoke-KimiK3.ps1 (2026-08-12 size split). Functions only; no side effects.
# PS 5.1-safe, ASCII. Uses $script:* state defined by the wrapper before dot-sourcing.
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

# Empty/cleared Kimi OAuth credential (access or refresh blank, or fully wiped shape).
# Never logs token values. Used by preflight, writeback guard, and restore-on-regression.
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
# Benign, no-side-effect, no-path tools always allowed (any lane): they touch no FS/shell/web
# and spawn nothing — the security boundary is write/shell/web/subagent, not the model's own
# scratch planning. Failing a whole review lane over one of these discards good work (K3's
# agent-core-v2 emits an internal TodoList the deny-config can't suppress). 2026-08-07.
$script:KimiBenignAlwaysTools = @('TodoList')

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
