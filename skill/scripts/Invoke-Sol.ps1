# Canonical Fleet GPT-5.6 Sol wrapper (plan / design / architecture / security lane).
# Sol previously had NO wrapper while every other external lane did; that gap left Sol
# with: effort inheritance (config default xhigh -> looks hung), PATH fragility (codex
# only in the nvm node dir -> "command not found" reads as a Sol failure), an unbounded
# 0-turn hang (Grok's liveness kill lived only in its wrapper), and a SILENT model-cache
# schema skew. This wrapper closes all four. Root cause + evidence:
#   memory reference_codex_sol_cache_skew  ("supports_reasoning_summaries" TTL-renew fail).
# PowerShell 5.1 safe: no ternary / null-coalescing / && ; ASCII source only.
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Run')]
  [string]$Prompt,

  [Parameter(ParameterSetName = 'Probe')]
  [switch]$Probe,                                   # SOL_OK model-resolution + liveness probe

  [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
  [string]$Effort = 'high',                         # Sol default high; xhigh only ambiguous/high-impact

  [string]$Model = 'gpt-5.6-sol',

  [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
  [string]$Sandbox = 'read-only',

  [string]$OutputJson,                              # optional codex -o <path>
  [string]$WorkingDirectory,

  [ValidateSet('text', 'json')]
  [string]$Mode = 'text',

  [ValidateRange(10, 3600)]
  [int]$TimeoutSeconds = 1200,                      # standard; caller sizes per mode/tier

  [ValidateRange(15, 900)]
  [int]$FirstOutputSeconds = 180,                   # 0-turn liveness kill (mirror Invoke-Grok45)

  [switch]$SkipGitRepoCheck
)

$ErrorActionPreference = 'Stop'
$fleetTerseTrailer = 'OUTPUT STYLE (mandatory): terse ' + [char]0x2014 + ' drop articles, filler, pleasantries, hedging; fragments OK; technical substance exact; code, diffs, JSON, file:line references verbatim and complete. Compress prose, never evidence.'
$proc = $null

function Resolve-CodexLauncher {
  # Deterministic order: explicit override -> approved pin (approved-clis.json) ->
  # known native nvm binary -> PATH Application -> known nvm .cmd shim. Ignore
  # aliases/functions. Directory overrides are rejected (-PathType Leaf); fall through.
  # The approved-pin hop lets a leased side-by-side upgrade (e.g. the codex
  # supports_reasoning_summaries catalog-schema skew) route Sol to a proven build
  # without an in-place npm replace; a future bump is just an approved-clis.json edit.
  if ($env:FLEET_CODEX_LAUNCHER -and (Test-Path -LiteralPath $env:FLEET_CODEX_LAUNCHER -PathType Leaf)) {
    return $env:FLEET_CODEX_LAUNCHER
  }
  $approvedPin = if ($env:FLEET_APPROVED_CLIS) { $env:FLEET_APPROVED_CLIS } else { Join-Path $env:USERPROFILE '.codex\fleet\approved-clis.json' }
  if (Test-Path -LiteralPath $approvedPin) {
    try {
      $pinPath = (Get-Content -Raw -LiteralPath $approvedPin | ConvertFrom-Json).clis.codex.path
      if ($pinPath -and (Test-Path -LiteralPath $pinPath -PathType Leaf)) { return $pinPath }
    } catch { }
  }
  $knownNative = @(
    "$env:LOCALAPPDATA\nvm\v22.22.2\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe",
    "$env:LOCALAPPDATA\nvm\v20.20.2\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe"
  )
  foreach ($k in $knownNative) { if (Test-Path -LiteralPath $k -PathType Leaf) { return $k } }
  $onPath = @(Get-Command codex -All -ErrorAction SilentlyContinue | Where-Object {
      $_.CommandType -eq 'Application' -and
      -not [string]::IsNullOrWhiteSpace([string]$_.Source) -and
      ([string]$_.Source -notlike "$env:ProgramFiles\WindowsApps\*") -and
      (Test-Path -LiteralPath ([string]$_.Source) -PathType Leaf)
    } | Select-Object -First 1)
  if ($onPath.Count -gt 0) { return [string]$onPath[0].Source }
  $known = @(
    "$env:LOCALAPPDATA\nvm\v22.22.2\codex.cmd",
    "$env:LOCALAPPDATA\nvm\v20.20.2\codex.cmd"
  )
  foreach ($k in $known) { if (Test-Path -LiteralPath $k -PathType Leaf) { return $k } }
  throw "codex launcher not found. codex is not on PATH (it lives in the nvm node dir, e.g. $($known[0])). Set FLEET_CODEX_LAUNCHER or add the nvm dir to PATH before dispatch."
}

# Windows CRT / CommandLineToArgvW quoting: 2n+1 backslashes before an embedded
# quote, 2n before the closing quote. Fixes backslash-quote prompt splits.
function ConvertTo-WindowsCommandLineArgument {
  param([string]$Arg)
  if ($null -eq $Arg) { $Arg = '' }
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

function ConvertTo-WindowsCommandLine {
  param([string[]]$ArgumentTokens)
  (($ArgumentTokens | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Arg ([string]$_) }) -join ' ')
}

function Test-CmdLauncherArgumentsSafe {
  param([string[]]$Arguments)
  # cmd.exe re-parses the /c line. Structural -c model="..." wrappers add quotes
  # we own; screen only raw caller-controllable values that enter the cmd line.
  # Prefer native codex.exe for values that need these characters.
  foreach ($arg in $Arguments) {
    if ($null -eq $arg) { continue }
    if ([string]$arg -match '[&%|<>^!"]') {
      throw "cmd launcher refuses unsafe argument characters (& % | < > ^ ! quotes). Set FLEET_CODEX_LAUNCHER to a native codex.exe for values that need those characters."
    }
  }
}

function Stop-Tree {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try { $processId = $Process.Id } catch { return }
  try { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null } catch { }
  try { $null = $Process.WaitForExit(5000) } catch { }
}

try {
  if ($Probe) { $Prompt = 'Reply with exactly the token SOL_OK and nothing else.' }
  if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'Prompt is empty.' }
  if (-not $Probe) { $Prompt = $Prompt + "`n" + $fleetTerseTrailer }

  $launcher = Resolve-CodexLauncher

  # Build the codex arg string. Force model + effort so Sol never inherits the config
  # default (xhigh) which silently makes Sol slow and reads as a hang.
  $codexArgs = @('exec', '-c', ('model="{0}"' -f $Model), '-c', ('model_reasoning_effort="{0}"' -f $Effort), '-s', $Sandbox)
  if ($SkipGitRepoCheck) { $codexArgs += '--skip-git-repo-check' }
  if ($OutputJson) { $codexArgs += @('-o', $OutputJson) }
  # Pass prompt through stdin so Windows command-line length and cmd.exe metacharacter
  # handling cannot corrupt a frozen review packet. codex exec treats '-' as stdin.
  $codexArgs += '-'

  $argumentText = ConvertTo-WindowsCommandLine -ArgumentTokens $codexArgs

  $psi = New-Object Diagnostics.ProcessStartInfo
  if ($launcher -match '\.cmd$') {
    # .cmd launchers require cmd.exe plus CALL so the outer process waits.
    # Fail closed on every caller-controllable value that enters the cmd line.
    $cmdScreen = @($Model)
    if ($OutputJson) { $cmdScreen += $OutputJson }
    Test-CmdLauncherArgumentsSafe -Arguments $cmdScreen
    $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
    $psi.Arguments = '/d /c call "' + $launcher + '" ' + $argumentText
  } else {
    # Native launcher: direct ProcessStartInfo (no cmd.exe); CRT-quoted Arguments.
    $psi.FileName = $launcher
    $psi.Arguments = $argumentText
  }
  if ($WorkingDirectory) { $psi.WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path }
  else { $psi.WorkingDirectory = (Get-Location).Path }
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  if (-not $proc.Start()) { throw 'Failed to start codex.' }
  try {
    $promptBytes = [Text.UTF8Encoding]::new($false).GetBytes($Prompt)
    $proc.StandardInput.BaseStream.Write($promptBytes, 0, $promptBytes.Length)
    $proc.StandardInput.BaseStream.Flush()
    $proc.StandardInput.Close()
  } catch { throw "Failed to write Codex prompt to stdin: $($_.Exception.Message)" }

  $startedAt = Get-Date

  # Event-based capture so we can observe FIRST output mid-stream (0-turn liveness).
  $state = [hashtable]::Synchronized(@{ First = $null; Out = New-Object Text.StringBuilder; Err = New-Object Text.StringBuilder })
  $sink = {
    $d = $Event.SourceEventArgs.Data
    if ($null -ne $d) { $s = $Event.MessageData; if (-not $s.First) { $s.First = Get-Date }; [void]$s.Out.AppendLine($d) }
  }
  $sinkErr = {
    $d = $Event.SourceEventArgs.Data
    if ($null -ne $d) { $s = $Event.MessageData; if (-not $s.First) { $s.First = Get-Date }; [void]$s.Err.AppendLine($d) }
  }
  $evtOut = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $state -Action $sink
  $evtErr = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $state -Action $sinkErr
  $proc.BeginOutputReadLine(); $proc.BeginErrorReadLine()

  # Kill the tree if codex produces NO output within FirstOutputSeconds (the 0-turn hang
  # class Grok's wrapper already guards) or exceeds the hard budget. Bounded either way.
  # The two kills are DIFFERENT diagnoses and must be labeled apart: a 0-turn hang means
  # transport/model never started; an over-budget kill means the model was mid-work and
  # the budget was too small for the packet (r9 2026-08-03: a working 94KB review killed
  # at 900s was mislabeled "hang", which misdirected the retry).
  $killedForHang = $false
  $timeoutKind = $null
  while (-not $proc.HasExited) {
    Start-Sleep -Milliseconds 300
    $elapsed = ((Get-Date) - $startedAt).TotalSeconds
    if (-not $state.First -and $elapsed -ge $FirstOutputSeconds) { $killedForHang = $true; $timeoutKind = 'no_first_output'; break }
    if ($elapsed -ge $TimeoutSeconds) { $killedForHang = $true; $timeoutKind = 'over_budget'; break }
  }
  if ($killedForHang) { Stop-Tree $proc } else { try { $null = $proc.WaitForExit(5000) } catch { } }
  Start-Sleep -Milliseconds 150   # let final event callbacks flush
  Unregister-Event -SourceIdentifier $evtOut.Name -ErrorAction SilentlyContinue
  Unregister-Event -SourceIdentifier $evtErr.Name -ErrorAction SilentlyContinue
  Remove-Job -Job $evtOut, $evtErr -Force -ErrorAction SilentlyContinue

  $stdout = $state.Out.ToString()
  $stderr = $state.Err.ToString()
  $duration = ((Get-Date) - $startedAt).TotalSeconds
  $exited = $proc.HasExited
  $exitCode = if ($exited -and -not $killedForHang) { $proc.ExitCode } else { -1 }

  # Surface the model-cache schema skew instead of letting it pass silently every run.
  $cacheSkew = ($stderr -match 'failed to renew cache TTL' -or $stderr -match 'supports_reasoning_summaries')
  $skewNote = $null
  if ($cacheSkew) {
    $skewNote = 'codex model-cache TTL renewal failed (supports_reasoning_summaries). Installed codex-cli lags the server model-catalog schema; Sol/Terra fall back to embedded defaults and re-fetch every run. Fix: promote a newer codex via the leased CLI-update flow (see cli-update-status.json codex row).'
  }

  $response = $stdout.Trim()
  $probeOk = $false
  if ($Probe) { $probeOk = ($response -match 'SOL_OK') }

  $status = 'ok'
  $reason = $null
  if ($killedForHang) {
    $status = 'timeout'
    if ($timeoutKind -eq 'no_first_output') { $reason = "No first output within $FirstOutputSeconds s; process tree killed (0-turn/hang guard)." }
    else { $reason = "Over budget: no completion within $TimeoutSeconds s while producing output; model was mid-work - size the budget to the packet (Get-FleetReviewBudget codex_timeout_seconds), do not treat as a hang." }
  }
  elseif ($exitCode -ne 0) { $status = 'error'; $reason = "codex exited with code $exitCode." }
  elseif ($Probe -and -not $probeOk) { $status = 'error'; $reason = 'Probe did not return SOL_OK; gpt-5.6-sol may be unresolved/renamed.' }
  elseif ([string]::IsNullOrWhiteSpace($response)) { $status = 'error'; $reason = 'Sol returned empty output.' }

  $result = [ordered]@{
    status           = $status
    timeout_kind     = $timeoutKind
    model_requested  = $Model
    effort           = $Effort
    sandbox          = $Sandbox
    launcher         = $launcher
    response         = $response
    duration_seconds = [math]::Round($duration, 2)
    timed_out        = [bool]$killedForHang
    exit_code        = $exitCode
    model_cache_skew = [bool]$cacheSkew
    fail_reason      = $reason
  }
  if ($cacheSkew) { $result.model_cache_skew_note = $skewNote }
  if ($Probe) { $result.probe_ok = $probeOk }
  if ($status -ne 'ok') {
    $tail = @($stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 30)
    if ($tail.Count) { $result.stderr_tail = $tail }
  }

  if ($Mode -eq 'json') { Write-Output ($result | ConvertTo-Json -Compress -Depth 7) }
  else {
    if ($status -eq 'ok') {
      Write-Output $response
      if ($cacheSkew) { [Console]::Error.WriteLine('WARN sol: ' + $skewNote) }
    }
    else { [Console]::Error.WriteLine(($result | ConvertTo-Json -Compress -Depth 7)) }
  }
  if ($status -eq 'ok') { exit 0 } else { exit 1 }
}
finally {
  if ($proc -and -not $proc.HasExited) { Stop-Tree $proc }
  if ($proc) { try { $proc.Dispose() } catch { } }
}
