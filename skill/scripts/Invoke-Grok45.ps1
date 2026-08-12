# Canonical Fleet Grok 4.5 transport. All Fleet Grok launches route here.
# Heartbeat transport (audit fix 2026-08-03): heartbeats are appended as JSONL lines
# to a SIDECAR file (default <temp>\fleet-grok-heartbeat-<pid>.jsonl, override via
# -HeartbeatPath), never written to stdout/stderr. This is what previously polluted
# line 1 of every captured result JSON with PowerShell NativeCommandError noise when
# a caller redirected 2>&1. The orchestrator still watches liveness by tailing that
# file; heartbeat_path is echoed in the result JSON for discovery.
param(
  [string]$Prompt,
  [string]$PromptFile,
  [string]$WorkingDirectory = (Get-Location).Path,
  [string]$HeartbeatPath,

  [ValidateSet("low", "medium", "high", "xhigh", "max")]
  [string]$Effort = "high",

  [Alias("ReadOnly")]
  [switch]$Review,
  [switch]$Visible,
  [switch]$LeanSystemPrompt,
  [switch]$ExperimentalMemory,
  [switch]$EnableSubagents,
  [switch]$EnableWebSearch,
  [string]$ResumeSessionId,

  [ValidateSet("Disabled", "Auto")]
  [string]$BashCapability = "Disabled",

  [switch]$IsolatedWorktree,

  [ValidateRange(1, 10)]
  [int]$MinimumAuditPasses = 1,

  # Zero means Fleet imposes no turn cap. Wall-clock timeout and structured
  # output validation remain mandatory. Set only for an explicitly bounded run.
  [ValidateRange(0, 1000)]
  [int]$MaxTurns = 0,

  [ValidateSet("text", "json")]
  [string]$Mode = "text",

  [ValidateRange(0, 7200)]
  [int]$TimeoutSeconds = 0,

  [ValidateRange(1, 3600)]
  [int]$HeartbeatSeconds = 30,

  # 0 means lane default: Review=180s, implementation=disabled.
  # Explicit 0 always disables. Probe once at deadline by pid in unified log.
  [ValidateRange(0, 3600)]
  [int]$FirstTurnTimeoutSeconds = 0
)

$ErrorActionPreference = "Stop"
$ExpectedModel = "grok-4.5"
$proc = $null
$ownedPrompt = $null
$ownedProbePrompt = $null
$poolReg = $null
. (Join-Path $PSScriptRoot 'GrokPoolIntegration.Helpers.ps1')
$script:heartbeatPath = if (-not [string]::IsNullOrWhiteSpace($HeartbeatPath)) { $HeartbeatPath } else { Join-Path ([IO.Path]::GetTempPath()) ("fleet-grok-heartbeat-" + $PID + ".jsonl") }
try { Remove-Item -LiteralPath $script:heartbeatPath -Force -ErrorAction SilentlyContinue } catch { }
$grokHome = if ([string]::IsNullOrWhiteSpace($env:GROK_HOME)) { Join-Path $env:USERPROFILE ".grok" } else { $env:GROK_HOME }
$modelLogPath = if ($env:FLEET_GROK_MODEL_LOG) { $env:FLEET_GROK_MODEL_LOG } else { Join-Path $grokHome "logs\unified.jsonl" }
$compatEnvNames = @(
  "GROK_CURSOR_SKILLS_ENABLED", "GROK_CURSOR_RULES_ENABLED", "GROK_CURSOR_AGENTS_ENABLED", "GROK_CURSOR_MCPS_ENABLED", "GROK_CURSOR_HOOKS_ENABLED",
  "GROK_CLAUDE_SKILLS_ENABLED", "GROK_CLAUDE_RULES_ENABLED", "GROK_CLAUDE_AGENTS_ENABLED", "GROK_CLAUDE_MCPS_ENABLED", "GROK_CLAUDE_HOOKS_ENABLED",
  "GROK_CODEX_SKILLS_ENABLED", "GROK_CODEX_RULES_ENABLED", "GROK_CODEX_AGENTS_ENABLED", "GROK_CODEX_MCPS_ENABLED", "GROK_CODEX_HOOKS_ENABLED"
)
$fleetTerseOutputTrailer = 'OUTPUT STYLE (mandatory): terse ' + [char]0x2014 + ' drop articles, filler, pleasantries, hedging; fragments OK; technical substance exact; code, diffs, JSON, file:line references verbatim and complete. Compress prose, never evidence.'
$fleetSystemPrompt = "You are Grok 4.5, Fleet's first-class non-design worker. Follow the locked charter. Read any tracked source, test, config, caller, or dependency needed for correctness; edit only allowed paths. Choose private implementation details inside locked behavior. Apply Ponytail directly: make the smallest correct change; delete or reuse before adding; prefer installed dependencies and existing utilities; add no abstraction, file, or dependency unless the locked charter requires it. File-size discipline (bands, matching Assert-FleetFileSize): target ~250 lines; 300 is a SOFT WARN - prefer splitting along existing boundaries but it is not a hard stop; 400 is the HARD CAP - never create or grow a source file past 400 lines, split first; a file already over 400 gets only minimal in-place edits, never net growth, unless the locked charter explicitly orders otherwise (test files: 400 warn / 600 cap). Do not over-split to chase 250 - a cohesive 320-line file beats three fragmented ones. Stop only for unresolved UX, product, public API, cross-service architecture, or security-policy decisions. Never commit, stage, push, merge, access secrets, or cause external side effects. Run task-relevant checks. Evidence integrity: report what each check ACTUALLY exercised (tests collected and passed, files scanned, records processed) - a check that ran nothing is a failure, not a pass; never derive a test's expected value from the code under test; never let a mock stand in for the behavior being verified; a new test is unproven until you have seen it fail with the code broken. One requested structured self-review replaces nested review workflows. Return required JSON with observed evidence only."
# Space not newline: --system-prompt-override rides Windows argv; raw newlines drop trailing flags.
$fleetSystemPrompt = $fleetSystemPrompt + " " + $fleetTerseOutputTrailer
$windowsShellGuidance = " Runtime is Windows PowerShell 5.1. Never use Bash heredocs such as << or python - <<. Never use node -e, node --eval, or python -c for source-file writes. Use search_replace for source edits; do not rewrite whole source files through inline shell quoting or create helper scripts/temp source files."
$schema = [ordered]@{
  type = "object"
  additionalProperties = $false
  required = @("schema_version", "status", "files_changed", "files_reviewed", "acceptance_criteria", "audit_passes", "findings", "fixes", "remaining_executable_checks", "self_check", "notes")
  properties = [ordered]@{
    schema_version = @{ type = "string"; enum = @("1") }
    status = @{ type = "string"; enum = @("done", "blocked", "partial") }
    files_changed = @{ type = "array"; items = @{ type = "string" } }
    files_reviewed = @{ type = "array"; items = @{ type = "string" } }
    acceptance_criteria = @{ type = "array"; minItems = 1; items = @{ type = "object"; additionalProperties = $false; required = @("criterion", "status", "evidence"); properties = @{ criterion = @{type="string";minLength=1}; status = @{type="string";enum=@("passed","failed","blocked")}; evidence = @{type="string";minLength=1} } } }
    audit_passes = @{ type = "integer"; minimum = 1 }
    findings = @{ type = "array"; items = @{ type = "object"; additionalProperties = $false; required = @("severity", "problem", "fix"); properties = @{ severity = @{type="string";enum=@("critical","high","medium","low")}; problem = @{type="string";minLength=1}; fix = @{type="string";minLength=1} } } }
    fixes = @{ type = "array"; items = @{ type = "string" } }
    remaining_executable_checks = @{ type = "array"; items = @{ type = "string" } }
    self_check = @{ type = "string"; minLength = 1 }
    notes = @{ type = "string" }
  }
}
$schemaJson = $schema | ConvertTo-Json -Compress -Depth 8

function Quote-Arguments {
  param([string[]]$Tokens)
  ($Tokens | ForEach-Object {
    $token = [string]$_
    if ($token.Length -eq 0) { '""' }
    elseif ($token -notmatch '[\s"]') { $token }
    else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }) -join " "
}

function Get-TextSha256([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))) -replace '-', '').ToLowerInvariant()) }
  finally { $sha.Dispose() }
}

function Stop-Tree {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try { $processId = $Process.Id } catch { return }
  try { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null } catch { }
  try { $null = $Process.WaitForExit(5000) } catch { }
}

function Stop-StaleOwnedGrokSessions {
  $statePath = Join-Path $grokHome "active_sessions.json"
  if (-not (Test-Path -LiteralPath $statePath)) { return }
  try { $entries = @([IO.File]::ReadAllText($statePath) | ConvertFrom-Json) } catch { return }
  foreach ($entry in $entries) {
    $pidValue = 0
    if (-not [int]::TryParse([string]$entry.pid, [ref]$pidValue) -or $pidValue -le 0) { continue }
    $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $process) { continue }
    try { $stale = ((Get-Date) - $process.StartTime).TotalHours -gt 2 } catch { $stale = $false }
    if (-not $stale) { continue }
    $cmd = Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
    if ([string]$cmd.CommandLine -match 'fleet-grok-[0-9a-f]+\.txt') { Stop-Tree $process }
  }
}

function Get-GrokExecutable {
  if ($env:FLEET_GROK_EXECUTABLE) { return $env:FLEET_GROK_EXECUTABLE }
  $managedExe = Join-Path $grokHome "bin\grok.exe"
  if (Test-Path -LiteralPath $managedExe) { return $managedExe }
  $command = Get-Command grok.exe, grok, grok.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $command) { throw "Grok executable not found." }
  return [string]$command.Source
}

function Assert-IsolatedGitWorktree([string]$Path) {
  $top = (& git -C $Path rev-parse --show-toplevel 2>$null | Select-Object -First 1)
  $gitDir = (& git -C $Path rev-parse --git-dir 2>$null | Select-Object -First 1)
  $commonDir = (& git -C $Path rev-parse --git-common-dir 2>$null | Select-Object -First 1)
  if (-not $top -or -not $gitDir -or -not $commonDir) { throw "Bash requires a valid isolated Git worktree." }
  $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  if (-not $root.Equals([IO.Path]::GetFullPath($top).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw "WorkingDirectory must be the isolated worktree root." }
  if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $root $gitDir }
  if (-not [IO.Path]::IsPathRooted($commonDir)) { $commonDir = Join-Path $root $commonDir }
  if ([IO.Path]::GetFullPath($gitDir).TrimEnd('\').Equals([IO.Path]::GetFullPath($commonDir).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw "Bash requires a linked worktree, not a primary checkout." }
}

function Assert-NoEscapingReparsePoints {
  # Structural enforcement of LESSONS 2026-07-09/07-17: a junction (reparse point)
  # inside an isolated worktree that targets another checkout turns any later
  # recursive delete into catastrophic main-checkout data loss. Walk the tree
  # WITHOUT descending into reparse points (so we never follow one), and fail
  # closed if any reparse point escapes the worktree root or cannot be resolved.
  param([string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return }
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $stack = New-Object System.Collections.Stack
  $stack.Push($rootFull)
  # Directory reparse points are the catastrophic case: a recursive delete follows
  # a dir junction/symlink into another tree. Deleting a file reparse point only
  # removes the link, so enumerate directories only and skip the file-count cost of
  # a real node_modules.
  while ($stack.Count -gt 0) {
    $dir = [string]$stack.Pop()
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
      if ((($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)) {
        $target = $null
        try { $target = (Get-Item -LiteralPath $child.FullName -Force).Target } catch { }
        $targets = @($target) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        if (-not $targets.Count) { throw "Refusing isolated-worktree run: unresolvable reparse point at '$($child.FullName)'. Remove it before running (fail closed)." }
        foreach ($t in $targets) {
          $resolved = if ([IO.Path]::IsPathRooted([string]$t)) { [string]$t } else { Join-Path (Split-Path -Parent $child.FullName) ([string]$t) }
          $tFull = try { [IO.Path]::GetFullPath($resolved).TrimEnd('\') } catch { [string]$resolved }
          $inside = $tFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or ($tFull + '\').StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
          if (-not $inside) { throw "Refusing isolated-worktree run: reparse point '$($child.FullName)' escapes to '$tFull' outside the worktree. A recursive delete could follow it into another checkout. Remove the junction (rmdir the link) or use an npm-installed dependency tree (npm ci)." }
        }
        continue  # never descend into a reparse point, even one targeting inside
      }
      $stack.Push([string]$child.FullName)
    }
  }
}

function Read-GrokAuth {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Grok auth preflight failed: missing $Path" }
  try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { throw "Grok auth preflight failed: unreadable auth.json" }
}

function Write-GrokAuth {
  param([string]$Path, $Auth)
  $suffix = [guid]::NewGuid().ToString('n')
  $temporary = "$Path.$suffix.tmp"
  $backup = "$Path.$suffix.bak"
  try {
    [IO.File]::WriteAllText($temporary, ($Auth | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    # PowerShell 5.1 can bind File.Replace(..., $null) to an invalid overload on
    # Windows. A same-directory backup keeps the replacement atomic and avoids
    # losing a rotated refresh token when the access token expires.
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $backup) }
    else { Move-Item -LiteralPath $temporary -Destination $Path }
  }
  finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
  }
}

function Refresh-GrokAuth {
  param([string]$Path, $Auth)
  $entry = $Auth.PSObject.Properties.Value | Where-Object {
    $_.PSObject.Properties.Name -contains 'refresh_token' -and
    $_.PSObject.Properties.Name -contains 'oidc_issuer' -and
    $_.PSObject.Properties.Name -contains 'oidc_client_id' -and
    -not [string]::IsNullOrWhiteSpace([string]$_.refresh_token) -and
    -not [string]::IsNullOrWhiteSpace([string]$_.oidc_issuer) -and
    -not [string]::IsNullOrWhiteSpace([string]$_.oidc_client_id)
  } | Select-Object -First 1
  if (-not $entry) { throw "Grok auth preflight failed: credentials expired and no refresh token is available." }

  try {
    $issuer = ([string]$entry.oidc_issuer).TrimEnd('/')
    $discovery = Invoke-RestMethod -Uri "$issuer/.well-known/openid-configuration" -Method Get
    if ([string]::IsNullOrWhiteSpace([string]$discovery.token_endpoint)) { throw "OIDC discovery omitted token_endpoint." }
    $token = Invoke-RestMethod -Uri ([string]$discovery.token_endpoint) -Method Post -ContentType 'application/x-www-form-urlencoded' -Body @{
      grant_type = 'refresh_token'
      client_id = [string]$entry.oidc_client_id
      refresh_token = [string]$entry.refresh_token
    }
  }
  catch { throw "Grok auth refresh failed: $($_.Exception.Message)" }

  if ([string]::IsNullOrWhiteSpace([string]$token.access_token)) { throw "Grok auth refresh failed: token response omitted access_token." }
  $seconds = 0
  if (-not [int]::TryParse([string]$token.expires_in, [ref]$seconds) -or $seconds -le 120) { throw "Grok auth refresh failed: token response omitted a usable expires_in." }

  $entry.key = [string]$token.access_token
  if (-not [string]::IsNullOrWhiteSpace([string]$token.refresh_token)) { $entry.refresh_token = [string]$token.refresh_token }
  $entry.expires_at = [datetimeoffset]::UtcNow.AddSeconds($seconds).ToString('o')
  Write-GrokAuth -Path $Path -Auth $Auth
}

function Assert-GrokAuthReady {
  param([string]$Path)
  $auth = Read-GrokAuth -Path $Path
  $expiries = @(
    foreach ($entry in $auth.PSObject.Properties.Value) {
      if ($entry.PSObject.Properties.Name -contains "expires_at") {
        try { [datetimeoffset]::Parse([string]$entry.expires_at) } catch { }
      }
    }
  )
  if (-not $expiries.Count) {
    if ($auth.PSObject.Properties.Count -gt 0) { return }
    throw "Grok auth preflight failed: auth.json has no credential entries"
  }
  if (($expiries | Sort-Object -Descending | Select-Object -First 1) -le [datetimeoffset]::UtcNow.AddMinutes(2)) {
    Refresh-GrokAuth -Path $Path -Auth $auth
    $auth = Read-GrokAuth -Path $Path
    $refreshedExpiries = @(
      foreach ($entry in $auth.PSObject.Properties.Value) {
        if ($entry.PSObject.Properties.Name -contains "expires_at") {
          try { [datetimeoffset]::Parse([string]$entry.expires_at) } catch { }
        }
      }
    )
    if (-not $refreshedExpiries.Count -or ($refreshedExpiries | Sort-Object -Descending | Select-Object -First 1) -le [datetimeoffset]::UtcNow.AddMinutes(2)) {
      throw "Grok auth refresh failed: refreshed credentials are still expired."
    }
  }
}

function Get-GrokVersion {
  param([string]$Executable)
  $versionText = (& $Executable --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '(\d+\.\d+\.\d+)') { throw "Unable to determine Grok version." }
  $semanticVersion = $Matches[1]
  $build = if ($versionText -match '\(([^)]+)\)') { $Matches[1] } else { "unknown-build" }
  return (($semanticVersion + "-" + $build) -replace '[^A-Za-z0-9._-]', '-')
}

function Read-CapabilityCache {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return @{} }
  try {
    $value = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $map = @{}
    foreach ($property in $value.PSObject.Properties) { $map[$property.Name] = [bool]$property.Value }
    return $map
  }
  catch { return @{} }
}

function Write-CapabilityCache {
  param([string]$Path, [hashtable]$Cache)
  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $temporary = "$Path.$([guid]::NewGuid().ToString('n')).tmp"
  try {
    [IO.File]::WriteAllText($temporary, ($Cache | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    try {
      if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $null) }
      else { Move-Item -LiteralPath $temporary -Destination $Path }
    }
    catch {
      if (-not (Test-Path -LiteralPath $Path)) { throw }
    }
  }
  finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Invoke-BashCapabilityProbe {
  param([string]$Executable, [string]$Version, [string]$CachePath)
  $cache = Read-CapabilityCache -Path $CachePath
  if ($cache.ContainsKey($Version)) { return [bool]$cache[$Version] }
  $probeRoot = Join-Path ([IO.Path]::GetTempPath()) ("fleet-grok-probe-" + [guid]::NewGuid().ToString("n"))
  New-Item -ItemType Directory -Path $probeRoot | Out-Null
  $proofPath = Join-Path $probeRoot "proof.txt"
  $proofToken = [guid]::NewGuid().ToString("n")
  $script:ownedProbePrompt = Join-Path $probeRoot "prompt.txt"
  [IO.File]::WriteAllText($script:ownedProbePrompt, "Use Bash to create this proof file containing exactly the token. Do not use Write or Edit.`nPROOF_PATH=$proofPath`nPROOF_TOKEN=$proofToken", (New-Object Text.UTF8Encoding($false)))
  $probeTools = "run_terminal_cmd,task,get_task_output,kill_task"
  $probeArgs = @("-m", $ExpectedModel, "--effort", "low", "--sandbox", "strict", "--no-memory", "--no-subagents", "--verbatim", "--always-approve", "--tools", $probeTools, "--deny", "MCPTool(*)", "--disable-web-search", "--max-turns", "3", "--output-format", "json", "--prompt-file", $script:ownedProbePrompt)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Executable
  $psi.Arguments = Quote-Arguments $probeArgs
  $psi.WorkingDirectory = $probeRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  foreach ($name in $compatEnvNames) { $psi.EnvironmentVariables[$name] = "false" }
  $psi.EnvironmentVariables["FLEET_GROK_RUN"] = "1"
  $probe = [Diagnostics.Process]::Start($psi)
  $stdoutTask = $probe.StandardOutput.ReadToEndAsync()
  $stderrTask = $probe.StandardError.ReadToEndAsync()
  if (-not $probe.WaitForExit(90000)) { Stop-Tree $probe }
  $stdout = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { "" }
  $stderr = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { "" }
  $passed = $probe.HasExited -and $probe.ExitCode -eq 0 -and (Test-Path -LiteralPath $proofPath) -and ([IO.File]::ReadAllText($proofPath).Trim() -eq $proofToken)
  $knownSchemaFailure = $stderr -match 'auto_background_on_timeout requires enabled_background'
  if ($passed -or $knownSchemaFailure) {
    $cache[$Version] = [bool]$passed
    Write-CapabilityCache -Path $CachePath -Cache $cache
  }
  # Never recurse-delete through a reparse point: if the probe root is somehow
  # contaminated, leak the temp dir rather than follow a junction out of it.
  try { Assert-NoEscapingReparsePoints $probeRoot } catch { $probeRoot = $null }
  if ($probeRoot) { Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue }
  return [bool]$passed
}

function Get-LastJsonObject {
  # Grok streams PROGRESSIVE audit snapshots and concatenates them in `text`
  # (bootstrap object first, final audit last - measured 2026-07-26: 19/19
  # needs_gate_validation lanes carried 2-7 objects, 18 of which had a valid audit
  # as the LAST object). A single ConvertFrom-Json over the whole string throws on
  # the extra data, so the wrapper reported "missing audit" for complete work and
  # the manager paid a verification pass every time. Scan top-level braces
  # (string/escape aware) and return the last complete object.
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $depth = 0; $start = -1; $last = $null; $inString = $false; $escaped = $false
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]
    if ($inString) {
      if ($escaped) { $escaped = $false }
      elseif ($ch -eq '\') { $escaped = $true }
      elseif ($ch -eq '"') { $inString = $false }
      continue
    }
    if ($ch -eq '"') { $inString = $true; continue }
    if ($ch -eq '{') { if ($depth -eq 0) { $start = $i }; $depth++ }
    elseif ($ch -eq '}') {
      $depth--
      if ($depth -eq 0 -and $start -ge 0) { $last = $Text.Substring($start, $i - $start + 1); $start = -1 }
    }
  }
  if ($null -eq $last) { return $null }
  try { return $last | ConvertFrom-Json } catch { return $null }
}

function Test-FleetAuditPathShape {
  # Concrete repo-relative file path. Reject rooted/drive/UNC/traversal/wildcard/control.
  # Do not Trim('/') — launders rooted paths. Parentheses legal; wildcards not.
  param($Path)
  if ($Path -isnot [string]) { return $false }
  $p = $Path.Trim()
  if ([string]::IsNullOrEmpty($p)) { return $false }
  if ($p.IndexOfAny([char[]]@(0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E,0x0F,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1A,0x1B,0x1C,0x1D,0x1E,0x1F,0x7F)) -ge 0) { return $false }
  if ($p -match '[*?]') { return $false }  # globs only: [ and ] are legal path chars (Next.js dynamic routes)
  if ($p -match '^[A-Za-z]:') { return $false }
  if ($p.StartsWith('\\') -or $p.StartsWith('//')) { return $false }
  if ($p.StartsWith('/') -or $p.StartsWith('\')) { return $false }
  $normalized = $p -replace '\\', '/'
  if ($normalized -match '(^|/)\.\.?(?:/|$)') { return $false }
  foreach ($seg in ($normalized -split '/')) {
    if ([string]::IsNullOrEmpty($seg)) { return $false }
    if ($seg -match '[<>:"|]') { return $false }
  }
  return $true
}

function Normalize-FleetAuditPath {
  param([string]$Path)
  return (($Path.Trim() -replace '\\', '/').ToLowerInvariant())
}

function Get-GitStatusPathMap {
  # Snapshot porcelain path -> "token|fingerprint". Fingerprint is size:LastWriteTimeUtc.Ticks
  # (or missing/dir) so a path already dirty (same porcelain token) that is edited again
  # still differs between snapshots. $null when not a git work tree / snapshot fails.
  param([string]$Path)
  try {
    # Drain into an array BEFORE reading $LASTEXITCODE. Piping a native command straight
    # into Select-Object -First 1 stops the upstream pipeline early, and PowerShell then
    # races the exit-code write: measured 2/400 calls kept the PREVIOUS command's code,
    # so a successful rev-parse read as a failure, the manifest read as unavailable, and
    # a complete lane came back needs_gate_validation (silent, load-dependent).
    $topLines = @(& git -C $Path rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    $top = if ($topLines.Count) { [string]$topLines[0] } else { "" }
    if (-not $top) { return $null }
    $raw = & git -C $Path status --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $sep = [string][char]92
    $map = @{}
    foreach ($line in @($raw)) {
      if ([string]::IsNullOrWhiteSpace([string]$line) -or ([string]$line).Length -lt 4) { continue }
      $xy = ([string]$line).Substring(0, 2)
      $rest = ([string]$line).Substring(3)
      if ($rest -match '^(?:")?(.+?)(?:")? -> (?:")?(.+?)(?:")?$') {
        $fromRel = $Matches[1] -replace '\\', '/'
        $toRel = $Matches[2] -replace '\\', '/'
        $map[$fromRel] = "from:${xy}|" + (Get-GitWorktreeFingerprint -Root $top -RelativePath $fromRel -DirectorySeparator $sep)
        $map[$toRel] = "to:${xy}|" + (Get-GitWorktreeFingerprint -Root $top -RelativePath $toRel -DirectorySeparator $sep)
      } else {
        $pathOnly = ($rest.Trim('"') -replace '\\', '/')
        $map[$pathOnly] = "${xy}|" + (Get-GitWorktreeFingerprint -Root $top -RelativePath $pathOnly -DirectorySeparator $sep)
      }
    }
    return $map
  } catch { return $null }
}

function Get-GitWorktreeFingerprint {
  # Cheap content identity: length + LastWriteTimeUtc.Ticks. Avoids hashing the tree.
  param([string]$Root, [string]$RelativePath, [string]$DirectorySeparator)
  $full = Join-Path $Root ($RelativePath.Replace('/', $DirectorySeparator))
  if (-not (Test-Path -LiteralPath $full)) { return "missing" }
  try {
    $item = Get-Item -LiteralPath $full -Force
    if ($item.PSIsContainer) { return "dir" }
    return ("{0}:{1}" -f [long]$item.Length, [long]$item.LastWriteTimeUtc.Ticks)
  } catch { return "unreadable" }
}

function Get-GitStatusDelta {
  # Paths whose porcelain token or content fingerprint changed (includes renames/deletes/untracked).
  param($Before, $After)
  if ($null -eq $Before -or $null -eq $After) { return $null }
  $keys = @{}
  foreach ($k in @($Before.Keys)) { $keys[[string]$k] = $true }
  foreach ($k in @($After.Keys)) { $keys[[string]$k] = $true }
  $changed = New-Object Collections.Generic.List[string]
  foreach ($k in @($keys.Keys)) {
    $b = if ($Before.ContainsKey($k)) { [string]$Before[$k] } else { '' }
    $a = if ($After.ContainsKey($k)) { [string]$After[$k] } else { '' }
    if ($b -cne $a) { $changed.Add($k) }
  }
  # Comma operator: an EMPTY @() unwraps to $null through the return, which made
  # "no observed changes" indistinguishable from "could not observe" - so a lane that
  # wrote nothing while claiming files_changed self-validated as ok (panel-found
  # 2026-07-26, the single most dangerous fabrication shape).
  return ,@($changed)
}

function Test-StructuredAudit {
  # Returns @{ valid; observed_manifest_available }. Changed files are inherently reviewed.
  # When ObservedChangedFiles is bound, require set-equality vs claimed files_changed.
  # Unbound = skip equality (not git / snapshot failed); never treat unobserved as matched.
  param($Value, [int]$MinimumPasses, [string[]]$ObservedChangedFiles)
  $manifestAvailable = $PSBoundParameters.ContainsKey('ObservedChangedFiles')
  $fail = { param($m) return [pscustomobject]@{ valid = $false; observed_manifest_available = $m } }
  if ($null -eq $Value) { return (& $fail $manifestAvailable) }
  $names = @($Value.PSObject.Properties.Name)
  foreach ($name in $schema.required) { if ($name -notin $names) { return (& $fail $manifestAvailable) } }
  if ($Value.status -notin @("done", "blocked", "partial") -or [int]$Value.audit_passes -lt $MinimumPasses) { return (& $fail $manifestAvailable) }
  foreach ($name in @("files_changed", "files_reviewed", "acceptance_criteria", "findings", "fixes", "remaining_executable_checks")) {
    $field = $Value.$name
    if ($null -eq $field -or $field -is [string] -or $field -isnot [Collections.IEnumerable]) { return (& $fail $manifestAvailable) }
  }
  foreach ($name in @("files_changed", "files_reviewed", "fixes", "remaining_executable_checks")) {
    foreach ($item in @($Value.$name)) { if ($item -isnot [string]) { return (& $fail $manifestAvailable) } }
  }
  foreach ($name in @("files_changed", "files_reviewed")) {
    foreach ($item in @($Value.$name)) {
      if (-not (Test-FleetAuditPathShape $item)) { return (& $fail $manifestAvailable) }
    }
  }
  if (-not @($Value.acceptance_criteria).Count) { return (& $fail $manifestAvailable) }
  foreach ($criterion in @($Value.acceptance_criteria)) {
    if (-not $criterion.criterion -or -not $criterion.evidence -or $criterion.status -notin @("passed", "failed", "blocked")) { return (& $fail $manifestAvailable) }
    if ($Value.status -eq "done" -and $criterion.status -ne "passed") { return (& $fail $manifestAvailable) }
  }
  if ($Value.status -ne "done" -and -not @($Value.acceptance_criteria | Where-Object { $_.status -ne "passed" }).Count) { return (& $fail $manifestAvailable) }
  foreach ($finding in @($Value.findings)) { if ([string]::IsNullOrWhiteSpace([string]$finding.problem) -or [string]::IsNullOrWhiteSpace([string]$finding.fix)) { return (& $fail $manifestAvailable) } }
  foreach ($finding in @($Value.findings)) {
    if ($finding.severity -notin @("critical", "high", "medium", "low") -or -not ($finding.PSObject.Properties.Name -contains "problem") -or -not ($finding.PSObject.Properties.Name -contains "fix")) { return (& $fail $manifestAvailable) }
  }
  if ($Value.schema_version -ne "1" -or [string]::IsNullOrWhiteSpace([string]$Value.self_check) -or $Value.notes -isnot [string]) { return (& $fail $manifestAvailable) }
  if ($manifestAvailable) {
    $claimed = @{}
    foreach ($p in @($Value.files_changed)) { $claimed[(Normalize-FleetAuditPath $p)] = $true }
    $observed = @{}
    foreach ($p in @($ObservedChangedFiles)) {
      if ([string]::IsNullOrWhiteSpace([string]$p)) { continue }
      $observed[(($p.Trim() -replace '\\', '/').ToLowerInvariant())] = $true
    }
    if ($claimed.Count -ne $observed.Count) { return (& $fail $manifestAvailable) }
    foreach ($k in @($claimed.Keys)) { if (-not $observed.ContainsKey($k)) { return (& $fail $manifestAvailable) } }
    if ($Value.status -in @("done", "partial") -and $observed.Count -eq 0) { return (& $fail $manifestAvailable) }
  }
  return [pscustomobject]@{ valid = $true; observed_manifest_available = $manifestAvailable }
}

function Write-Heartbeat {
  # Sidecar-file transport only (never stdout/stderr): a caller capturing stdout or
  # merging 2>&1 must never see a heartbeat line ahead of/inside the result JSON.
  param([double]$Elapsed)
  $line = (([ordered]@{ type = "heartbeat"; lane = "grok-4.5"; elapsed_seconds = [math]::Round($Elapsed, 1) }) | ConvertTo-Json -Compress)
  try { [IO.File]::AppendAllText($script:heartbeatPath, $line + "`n", (New-Object Text.UTF8Encoding($false))) } catch { }
}

function Read-SessionLogEvidence {
  param([string]$SessionId, [long]$Offset)
  $evidence = [ordered]@{
    session_id = $null
    observed_model = $null
    model_turns = 0
    model_elapsed_ms = 0
    final_prompt_tokens = $null
    cached_prompt_tokens = $null
    completion_tokens = 0
    reasoning_tokens = 0
    tool_call_count = 0
    tool_elapsed_ms = 0
    tool_error_count = 0
  }
  if (-not (Test-Path -LiteralPath $modelLogPath)) { return [pscustomobject]$evidence }
  $stream = $null
  $reader = $null
  try {
    $entries = @()
    $stream = [IO.File]::Open($modelLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    if ($Offset -le $stream.Length) { [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin) }
    $reader = New-Object IO.StreamReader($stream)
    while (-not $reader.EndOfStream) {
      $line = $reader.ReadLine()
      try { $entry = $line | ConvertFrom-Json } catch { continue }
      if ($entry.sid) { $entries += $entry }
    }
    $targetSessionId = $SessionId
    if ([string]::IsNullOrWhiteSpace($targetSessionId)) {
      $sessionIds = @($entries | ForEach-Object { [string]$_.sid } | Where-Object { $_ } | Select-Object -Unique)
      if ($sessionIds.Count -eq 1) { $targetSessionId = $sessionIds[0] }
    }
    if ([string]::IsNullOrWhiteSpace($targetSessionId)) { return [pscustomobject]$evidence }
    $evidence.session_id = $targetSessionId
    foreach ($entry in $entries) {
      if ([string]$entry.sid -cne $targetSessionId) { continue }
      if ($entry.msg -eq "model changed") { $evidence.observed_model = [string]$entry.ctx.model }
      if ($entry.msg -eq "shell.turn.inference_done") {
        $evidence.model_turns++
        $evidence.model_elapsed_ms += [long]$entry.ctx.model_elapsed_ms
        $evidence.final_prompt_tokens = [long]$entry.ctx.prompt_tokens
        $evidence.cached_prompt_tokens = [long]$entry.ctx.cached_prompt_tokens
        $evidence.completion_tokens += [long]$entry.ctx.completion_tokens
        $evidence.reasoning_tokens += [long]$entry.ctx.reasoning_tokens
      }
      if ($entry.msg -eq "shell.tool.exec_done") {
        $evidence.tool_call_count++
        $evidence.tool_elapsed_ms += [long]$entry.ctx.elapsed_ms
        if ($entry.ctx.success -eq $false) { $evidence.tool_error_count++ }
      }
    }
    return [pscustomobject]$evidence
  }
  finally {
    if ($reader) { $reader.Dispose() }
    elseif ($stream) { $stream.Dispose() }
  }
}

# Pid-filtered first-turn liveness. Do not reuse Read-SessionLogEvidence: its single-sid
# guard false-negatives when concurrent Fleet lanes share unified.jsonl.
function Test-GrokFirstTurnSeen {
  param([int]$ProcessId, [long]$Offset)
  if (-not (Test-Path -LiteralPath $modelLogPath)) { return $false }
  $stream = $null
  $reader = $null
  try {
    $stream = [IO.File]::Open($modelLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    if ($Offset -le $stream.Length) { [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin) }
    $reader = New-Object IO.StreamReader($stream)
    while (-not $reader.EndOfStream) {
      $line = $reader.ReadLine()
      try { $entry = $line | ConvertFrom-Json } catch { continue }
      if ($null -eq $entry.pid) { continue }
      if ([long]$entry.pid -ne [long]$ProcessId) { continue }
      if ($entry.msg -eq "shell.turn.tool_prep_done" -or $entry.msg -eq "shell.turn.inference_done") { return $true }
    }
    return $false
  }
  finally {
    if ($reader) { $reader.Dispose() }
    elseif ($stream) { $stream.Dispose() }
  }
}

function Get-FinalEnvelope {
  param([string]$Text)
  $documents = New-Object Collections.ArrayList
  $depth = 0
  $start = -1
  $inString = $false
  $escaped = $false
  for ($index = 0; $index -lt $Text.Length; $index++) {
    $character = $Text[$index]
    if ($depth -eq 0) {
      if ([char]::IsWhiteSpace($character)) { continue }
      if ($character -ne '{') { return $null }
      $start = $index
      $depth = 1
      continue
    }
    if ($inString) {
      if ($escaped) { $escaped = $false; continue }
      if ($character -eq '\') { $escaped = $true; continue }
      if ($character -eq '"') { $inString = $false }
      continue
    }
    if ($character -eq '"') { $inString = $true; continue }
    if ($character -eq '{') { $depth++; continue }
    if ($character -eq '}') {
      $depth--
      if ($depth -eq 0) {
        $json = $Text.Substring($start, $index - $start + 1)
        try { [void]$documents.Add(($json | ConvertFrom-Json -ErrorAction Stop)) } catch { return $null }
        $start = -1
      }
    }
  }
  if ($depth -ne 0 -or $inString -or $escaped -or $start -ne -1) { return $null }
  $finals = @()
  for ($index = 0; $index -lt $documents.Count; $index++) {
    $value = $documents[$index]
    $names = @($value.PSObject.Properties.Name)
    # Read-only and implementation lanes share the outer Grok transport envelope.
    # Accept sessionId plus either text or structuredOutput (D2).
    if ($value.sessionId -and (("structuredOutput" -in $names) -or ("text" -in $names))) {
      $finals += [pscustomobject]@{ Index=$index; Value=$value }
    }
  }
  if ($finals.Count -ne 1) { return $null }
  $final = $finals[0]
  if ($final.Index -ne ($documents.Count - 1)) { return $null }
  return $final.Value
}

# Guarantee machine-readable stdout on wrapper-owned exits. External kills
# (taskkill/Ctrl-C) cannot be intercepted reliably; this covers exceptions and
# early-return paths only.
$script:resultEmitted = $false
$hasPrompt = -not [string]::IsNullOrWhiteSpace($Prompt)
$hasFile = -not [string]::IsNullOrWhiteSpace($PromptFile)
$effectiveTimeoutSeconds = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } elseif ($Review) { 900 } else { 1200 }
$effectiveFirstTurnSeconds = if ($PSBoundParameters.ContainsKey('FirstTurnTimeoutSeconds')) { $FirstTurnTimeoutSeconds } elseif ($Review) { 180 } else { 0 }

try {
  if ($hasPrompt -eq $hasFile) { throw "Specify exactly one of -Prompt or -PromptFile." }
  $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
  $poolReg = Initialize-GrokPoolRegistration -WorkingDirectory $WorkingDirectory -ScriptRoot $PSScriptRoot -WrapperProcessId $PID
  # Grok 1.0.0's sandbox is proven reliable inside an isolated worktree (terminal proof
  # passes, writes stay contained, self-verification works -- fleet-parstress/clipins runs).
  # So an isolated IMPLEMENTATION lane gets more freedom BY DEFAULT: bash + subagents + web,
  # matching the stated adapter policy ("isolated impl lanes get subagents + web default-on").
  # Any caller can still override each explicitly; Review lanes and non-isolated lanes are
  # unchanged. Safety rails are untouched below: bash still requires an isolated worktree,
  # nested-agent spawns (codex/grok/claude) stay denied, MCP stays denied, manager re-verifies.
  if ($IsolatedWorktree -and -not $Review) {
    if (-not $PSBoundParameters.ContainsKey('BashCapability')) { $BashCapability = 'Auto' }
    if (-not $PSBoundParameters.ContainsKey('EnableSubagents')) { $EnableSubagents = $true }
    if (-not $PSBoundParameters.ContainsKey('EnableWebSearch')) { $EnableWebSearch = $true }
  }
  if ($BashCapability -eq "Auto" -and -not $IsolatedWorktree) { throw "BashCapability Auto requires -IsolatedWorktree." }
  if ($BashCapability -eq "Auto") { Assert-IsolatedGitWorktree $WorkingDirectory }
  if ($IsolatedWorktree) { Assert-NoEscapingReparsePoints $WorkingDirectory }
  Stop-StaleOwnedGrokSessions
  $authPath = Join-Path $grokHome "auth.json"
  Assert-GrokAuthReady -Path $authPath
  $promptText = if ($hasFile) {
    if (-not (Test-Path -LiteralPath $PromptFile)) { throw "PromptFile not found: $PromptFile" }
    [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path)
  } else { [string]$Prompt }
  if ([string]::IsNullOrWhiteSpace($promptText)) { throw "Prompt is empty." }
  $grok = Get-GrokExecutable
  $version = Get-GrokVersion -Executable $grok
  $bashCapable = $false
  if ($BashCapability -eq "Auto") {
    $cachePath = Join-Path $grokHome "fleet\bash-capability-v2-$version.json"
    $bashCapable = Invoke-BashCapabilityProbe -Executable $grok -Version $version -CachePath $cachePath
  }

  if ($promptText -notmatch '(?m)^SHADOW_COVERED:') { $promptText = "SHADOW_COVERED:fleet/grok45`n" + $promptText }
  if ($Review) {
    $promptText += "`nReturn free-form Markdown as the review deliverable. Do not return the implementation worker JSON envelope."
  } else {
    $promptText += "`nReturn only the JSON object required by the supplied schema. Populate every field. Perform exactly $MinimumAuditPasses static adversarial self-review pass(es); fix actionable findings before returning. Report only checks actually run. Reserve enough context and time for the final JSON."
    if ($env:OS -eq "Windows_NT") { $promptText += $windowsShellGuidance }
    if ($bashCapable) { $promptText += " You have a real terminal in an isolated worktree -- use it to VERIFY YOUR OWN WORK before returning: run the build/typecheck for the package(s) you touched and the tests that exercise your change, read the failures, and fix them so you hand off green. A new or heavily-changed source file that you never compiled/typechecked is not done. Prefer the smallest command that proves your slice (the touched package's build + your focused tests) over re-running the entire monorepo suite every pass. The manager still runs the authoritative barrier gate once; arriving already-green just saves repair rounds. Do NOT spawn nested coding agents (codex/grok/claude) and do NOT run destructive or repo-wide mutations outside your locked scope." }
  }
  if (-not $LeanSystemPrompt) { $promptText += "`n" + $fleetTerseOutputTrailer }
  $effectivePromptHash = Get-TextSha256 $promptText
  $ownedPrompt = Join-Path ([IO.Path]::GetTempPath()) ("fleet-grok-" + [guid]::NewGuid().ToString("n") + ".txt")
  [IO.File]::WriteAllText($ownedPrompt, $promptText, (New-Object Text.UTF8Encoding($false)))

  $tools = if ($Review) { "read_file,grep,list_dir" } else { "read_file,grep,list_dir,search_replace" }
  if ($bashCapable -and -not $Review) { $tools += ",run_terminal_cmd,task,get_task_output,kill_task" }
  elseif ($EnableSubagents -and -not $Review) { $tools += ",task,get_task_output,kill_task" }
  if ($EnableWebSearch) { $tools += ",web_search,web_fetch" }
  # Grok CLI 0.2.99 accepts high/medium/low only. Fleet's `max` contract means
  # highest available effort, so preserve it in telemetry while passing `high`.
  $effectiveEffort = if ($Effort -in @("xhigh", "max")) { "high" } else { $Effort }
  $args = @("-m", $ExpectedModel, "--effort", $effectiveEffort, "--sandbox", "strict", "--verbatim", "--output-format", "json")
  # Worker-JSON schema is implementation-only; read-only review keeps outer JSON transport without --json-schema (D2).
  if (-not $Review) { $args += @("--json-schema", $schemaJson) }
  if ($LeanSystemPrompt) { $args += @("--system-prompt-override", $fleetSystemPrompt) }
  if ($Review -or -not $ExperimentalMemory) { $args += "--no-memory" } else { $args += "--experimental-memory" }
  if ($Review -or -not $EnableSubagents) { $args += "--no-subagents" }
  if ($ResumeSessionId) { $args += @("--resume", $ResumeSessionId) }
  if ($Review) {
    $args += @("--permission-mode", "dontAsk", "--tools", $tools, "--allow", "Read", "--allow", "Grep", "--deny", "Edit", "--deny", "Write", "--deny", "Bash(*)", "--deny", "MCPTool(*)")
  } else {
    $args += @("--always-approve", "--tools", $tools, "--deny", "MCPTool(*)")
    $args += @("--deny", "Bash(codex *)", "--deny", "Bash(grok *)", "--deny", "Bash(claude *)")
    if (-not $bashCapable) { $args += @("--deny", "Bash(*)") }
  }
  if (-not $EnableWebSearch) { $args += "--disable-web-search" }
  if ($MaxTurns -gt 0) { $args += @("--max-turns", [string]$MaxTurns) }
  $args += @("--prompt-file", $ownedPrompt)

  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $grok
  $psi.Arguments = Quote-Arguments $args
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = -not $Visible
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  # Codex may set both variables. Node then warns on stderr, and Windows
  # PowerShell can convert that harmless warning into a failed native command.
  foreach ($name in @("NO_COLOR", "FORCE_COLOR")) { $psi.EnvironmentVariables.Remove($name) }
  foreach ($name in $compatEnvNames) { $psi.EnvironmentVariables[$name] = "false" }
  $psi.EnvironmentVariables["FLEET_GROK_RUN"] = "1"

  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  $modelLogOffset = if (Test-Path -LiteralPath $modelLogPath) { (Get-Item -LiteralPath $modelLogPath).Length } else { 0 }
  # Pre-lane git porcelain snapshot so observed_changed is the delta, not pre-existing dirty.
  $gitStatusBefore = if (-not $Review) { Get-GitStatusPathMap -Path $WorkingDirectory } else { $null }
  if (-not $proc.Start()) { throw "Failed to start Grok." }
  Register-GrokPoolWorkerRoot -PoolRegistration $poolReg -WorkerProcessId ([int]$proc.Id)
  $startedAt = Get-Date
  $deadline = $startedAt.AddSeconds($effectiveTimeoutSeconds)
  $firstTurnDeadline = if ($effectiveFirstTurnSeconds -gt 0) { $startedAt.AddSeconds($effectiveFirstTurnSeconds) } else { $null }
  $firstTurnSeen = $false
  $noFirstTurn = $false
  $nextHeartbeat = $startedAt.AddSeconds($HeartbeatSeconds)
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $timedOut = $false
  while (-not $proc.HasExited) {
    $now = Get-Date
    if ($now -ge $deadline) { $timedOut = $true; Stop-Tree $proc; break }
    if ($firstTurnDeadline -and -not $firstTurnSeen -and $now -ge $firstTurnDeadline) {
      if (Test-GrokFirstTurnSeen -ProcessId $proc.Id -Offset $modelLogOffset) { $firstTurnSeen = $true }
      else { $noFirstTurn = $true; $timedOut = $true; Stop-Tree $proc; break }
    }
    if ($now -ge $nextHeartbeat) { Write-Heartbeat (($now - $startedAt).TotalSeconds); $nextHeartbeat = $now.AddSeconds($HeartbeatSeconds) }
    Start-Sleep -Milliseconds 50
  }
  try { $null = $proc.WaitForExit(5000) } catch { }
  $stdout = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { "" }
  $stderr = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { "" }
  $duration = ((Get-Date) - $startedAt).TotalSeconds
  $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
  $envelope = Get-FinalEnvelope -Text $stdout
  $sessionId = if ($envelope) { [string]$envelope.sessionId } else { $null }
  $logEvidence = Read-SessionLogEvidence -SessionId $sessionId -Offset $modelLogOffset
  $observedModel = $logEvidence.observed_model
  $structured = if ($envelope) { $envelope.structuredOutput } else { $null }
  if (-not $structured -and -not $Review -and $envelope -and $envelope.text) {
    try { $structured = [string]$envelope.text | ConvertFrom-Json } catch { }
    if (-not $structured) { $structured = Get-LastJsonObject -Text ([string]$envelope.text) }
  }
  $responseText = if ($envelope) { [string]$envelope.text } else { "" }
  $payloadPresent = (-not [string]::IsNullOrWhiteSpace($responseText)) -or (
    $null -ne $structured -and @($structured.PSObject.Properties).Count -gt 0
  )
  $observedManifestAvailable = $false
  $observedChangedFiles = $null
  if (-not $Review -and $null -ne $gitStatusBefore) {
    $gitStatusAfter = Get-GitStatusPathMap -Path $WorkingDirectory
    $delta = Get-GitStatusDelta -Before $gitStatusBefore -After $gitStatusAfter
    if ($null -ne $delta) {
      $observedManifestAvailable = $true
      $observedChangedFiles = @($delta)
    }
  }
  $auditCheck = if ($Review) {
    [pscustomobject]@{ valid = $false; observed_manifest_available = $false }
  } elseif ($observedManifestAvailable) {
    Test-StructuredAudit -Value $structured -MinimumPasses $MinimumAuditPasses -ObservedChangedFiles $observedChangedFiles
  } else {
    # Sol ruling: never let "could not observe" read as "matched". An implementation lane
    # with no observable manifest cannot have its file claims verified, so it is not a
    # verified audit - the manager's gates decide.
    $shapeOnly = Test-StructuredAudit -Value $structured -MinimumPasses $MinimumAuditPasses
    [pscustomobject]@{ valid = $false; observed_manifest_available = $false; shape_valid = [bool]$shapeOnly.valid }
  }
  $auditValid = [bool]$auditCheck.valid
  $observedManifestAvailable = [bool]$auditCheck.observed_manifest_available

  $status = "error"
  $reason = $null
  $failureCategory = $null
  $selfAuditMissing = $false
  $selfAuditMissingNote = $null
  $lane = if ($Review) { "read_only" } else { "implementation" }
  $terminationEvidence = if ($envelope) { @($envelope.stop_reason, $envelope.stopReason, $envelope.termination_reason, $envelope.terminationReason) -join " " } else { "" }
  if ($noFirstTurn) {
    $timedOut = $true
    $status = "timeout"
    $failureCategory = "no_first_turn"
    $reason = "No first turn within ${effectiveFirstTurnSeconds}s; transport stall, process tree killed."
  }
  elseif ($timedOut) { $status = "timeout"; $failureCategory = "timeout"; $reason = "Timed out; process tree killed." }
  elseif (($terminationEvidence + "`n" + $stderr) -match '(?i)max(?:imum)? turns? reached|turn limit reached') { $failureCategory = "model_budget"; $reason = "Grok reached its turn limit; output is partial." }
  elseif ($exitCode -ne 0) { $failureCategory = "transport"; $reason = "Grok exited with code $exitCode." }
  elseif ($null -eq $envelope) { $failureCategory = "report"; $reason = "Grok returned invalid JSON." }
  elseif ($observedModel -ne $ExpectedModel) { $failureCategory = "model"; $reason = "Observed Grok model mismatch or missing model evidence." }
  elseif ($Review) {
    # D2: read-only success requires nonblank markdown text and verified model evidence.
    if ([string]::IsNullOrWhiteSpace($responseText)) {
      $failureCategory = "report"
      $reason = "Grok review returned empty markdown output."
    } else {
      $status = "ok"
    }
  }
  elseif (-not $payloadPresent) {
    $failureCategory = "report"
    $reason = "Grok returned empty output."
  }
  elseif (-not $auditValid) {
    # needs_gate_validation: worker self-audit cannot be trusted or machine-consumed.
    # Blocks automated acceptance/rollup based on worker attestation; does NOT mean
    # implementation failed. Manager diff/tests/lint/build/Fallow gates remain the final
    # authority; a lane may complete on those with "self-audit invalid; manager-validated".
    # Exit 0 salvage: valid transport + payload + model, invalid/missing structured audit.
    $status = "needs_gate_validation"
    $selfAuditMissing = $true
    # Audit fix 2026-08-03: 8/13 implementation lanes in one run carried
    # failure_category=report on top of needs_gate_validation despite exit 0, a
    # parseable worker envelope (status done/needs_gate_validation), and a populated
    # files_changed list — real work, misreported as a failure downstream. When the
    # underlying worker signals success this way, drop failure_category/fail_reason
    # entirely (they read as an error to callers checking those fields) and surface
    # self_audit_missing + a note instead; manager gates remain the authority either way.
    $workerStatusField = if ($null -ne $structured -and (@($structured.PSObject.Properties.Name) -contains 'status')) { [string]$structured.status } else { $null }
    $workerFilesChangedField = if ($null -ne $structured -and (@($structured.PSObject.Properties.Name) -contains 'files_changed')) { $structured.files_changed } else { $null }
    # ConvertFrom-Json collapses a single-item JSON array to a scalar, so a real
    # one-file files_changed can arrive as a bare string, not [string[]] - wrap with
    # @() rather than type-checking for an array.
    $workerFilesChangedPresent = ($null -ne $workerFilesChangedField) -and (@(@($workerFilesChangedField) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)
    $workerSignalsSuccess = ($exitCode -eq 0) -and ($null -ne $structured) -and ($workerStatusField -in @("done", "needs_gate_validation")) -and $workerFilesChangedPresent
    if ($workerSignalsSuccess) {
      $failureCategory = $null
      $reason = $null
      $selfAuditMissingNote = "Underlying worker reported status '$workerStatusField' with files_changed populated (exit 0), but the structured self-audit block failed schema/manifest validation. Manager gate must independently validate this lane before acceptance; this is not a lane failure."
    } else {
      $failureCategory = "report"
      $reason = "Structured self-audit missing or invalid; manager gate validation required."
    }
  }
  else { $status = "ok" }

  $selfAuditRequired = -not $Review
  $selfAuditVerified = if ($Review) { $false } else { [bool]$auditValid }
  $gateValidationRequired = ($status -eq "needs_gate_validation")
  $resultAudit = if ($Review) { $null } elseif ($status -eq "needs_gate_validation" -and -not $auditValid) {
    if ($null -ne $structured -and @($structured.PSObject.Properties).Count -gt 0) { $structured } else { $null }
  } else { $structured }

  $result = [ordered]@{
    status = $status
    lane = $lane
    task_status = if ($Review) { $null } elseif ($structured) { [string]$structured.status } else { $null }
    model = $ExpectedModel
    observed_model = $observedModel
    model_evidence = "unified-log"
    grok_version = $version
    max_turns = if ($MaxTurns -gt 0) { $MaxTurns } else { $null }
    requested_effort = $Effort
    effective_effort = $effectiveEffort
    timeout_seconds = $effectiveTimeoutSeconds
    first_turn_timeout_seconds = $effectiveFirstTurnSeconds
    heartbeat_path = $script:heartbeatPath
    bash_capable = [bool]$bashCapable
    bash_enabled = [bool]($bashCapable -and -not $Review)
    lean_system_prompt = [bool]$LeanSystemPrompt
    effective_prompt_sha256 = $effectivePromptHash
    memory_enabled = [bool]($ExperimentalMemory -and -not $Review)
    subagents_enabled = [bool]($EnableSubagents -and -not $Review)
    model_turns = [int]$logEvidence.model_turns
    model_seconds = [math]::Round(([double]$logEvidence.model_elapsed_ms / 1000), 2)
    final_prompt_tokens = $logEvidence.final_prompt_tokens
    cached_prompt_tokens = $logEvidence.cached_prompt_tokens
    completion_tokens = [long]$logEvidence.completion_tokens
    reasoning_tokens = [long]$logEvidence.reasoning_tokens
    tool_call_count = [int]$logEvidence.tool_call_count
    tool_seconds = [math]::Round(([double]$logEvidence.tool_elapsed_ms / 1000), 2)
    tool_error_count = [int]$logEvidence.tool_error_count
    self_audit_required = [bool]$selfAuditRequired
    self_audit_verified = [bool]$selfAuditVerified
    gate_validation_required = [bool]$gateValidationRequired
    self_audit_missing = [bool]$selfAuditMissing
    self_audit_missing_note = $selfAuditMissingNote
    observed_manifest_available = [bool]$observedManifestAvailable
    audit = $resultAudit
    response = $responseText
    session_id = if ($sessionId) { $sessionId } else { [string]$logEvidence.session_id }
    request_id = if ($envelope) { [string]$envelope.requestId } else { $null }
    duration_seconds = [math]::Round($duration, 2)
    timed_out = [bool]$timedOut
    exit_code = $exitCode
    failure_category = $failureCategory
    fail_reason = $reason
  }

  $successStatuses = @("ok", "needs_gate_validation")
  if ($status -notin $successStatuses) {
    $tail = @($stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 30)
    if ($tail.Count) { $result.stderr_tail = $tail }
    if ($Review -and $Mode -eq "text") {
      # D2 text failure: any nonblank partial markdown on stdout; failure JSON on stderr.
      if (-not [string]::IsNullOrWhiteSpace($responseText)) { Write-Output $responseText }
      [Console]::Error.WriteLine(($result | ConvertTo-Json -Compress -Depth 10))
    } elseif ($Mode -eq "json") {
      Write-Output ($result | ConvertTo-Json -Compress -Depth 10)
    } else {
      [Console]::Error.WriteLine(($result | ConvertTo-Json -Compress -Depth 10))
    }
    $script:resultEmitted = $true
    exit 1
  }

  # needs_gate_validation always emits the normalized result JSON (no trustworthy worker report).
  if ($status -eq "needs_gate_validation") {
    Write-Output ($result | ConvertTo-Json -Compress -Depth 10)
    $script:resultEmitted = $true
    exit 0
  }

  if ($Review) {
    if ($Mode -eq "json") { Write-Output ($result | ConvertTo-Json -Compress -Depth 10) }
    else { Write-Output $responseText }
    $script:resultEmitted = $true
    exit 0
  }

  if ($Mode -eq "json") { Write-Output ($result | ConvertTo-Json -Compress -Depth 10) } else { Write-Output ($structured | ConvertTo-Json -Depth 10) }
  $script:resultEmitted = $true
  exit 0
}
catch {
  if (-not $script:resultEmitted) {
    $fallback = [ordered]@{
      status = "error"
      fail_reason = [string]$_.Exception.Message
      failure_category = "transport"
      exit_code = 1
    }
    if ([string]::IsNullOrWhiteSpace([string]$fallback.fail_reason)) {
      $fallback.fail_reason = "Wrapper terminated without a result object."
    }
    Write-Output ($fallback | ConvertTo-Json -Compress -Depth 10)
    $script:resultEmitted = $true
  }
  exit 1
}
finally {
  # Tree-kill on EVERY exit path, not just timeout. On normal completion the wrapper returns
  # as soon as grok writes its result JSON, but grok can leave tool/child processes still
  # tearing down; taskkill /T reaps them (harmless no-op on the already-exited parent). Only
  # OS-defunct zombies survive this -- those are unkillable by any code (reboot-only), not a
  # wrapper bug. (Leak surfaced by fleet-parstress-20260808.)
  if ($proc) { Stop-Tree $proc }
  if ($proc) { try { $proc.Dispose() } catch { } }
  Unregister-GrokPoolRegistration -PoolRegistration $poolReg
  $poolReg = $null
  foreach ($path in @($ownedPrompt, $ownedProbePrompt)) { if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
  # Fallback only when no intentional result was written. Does not cover external kills.
  if (-not $script:resultEmitted) {
    $fallback = [ordered]@{
      status = "error"
      fail_reason = "Wrapper terminated without a result object."
      failure_category = "transport"
      exit_code = 1
    }
    Write-Output ($fallback | ConvertTo-Json -Compress -Depth 10)
    $script:resultEmitted = $true
    exit 1
  }
}
