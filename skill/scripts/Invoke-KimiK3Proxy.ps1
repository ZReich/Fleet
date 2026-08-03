# Fleet Kimi K3 PROXY-HARNESS lane: runs K3-the-model inside the claude-code agentic
# harness via the Kimi coding subscription's Anthropic-compatible endpoint. Tests the
# "stronger harness" hypothesis (the Grok lesson) WITHOUT a metered platform key.
#
# Auth: the user's existing Kimi Code OAuth (api.kimi.com/coding is Anthropic-compatible).
# The 15-min access token is refreshed via Invoke-KimiK3.ps1 right before launch, and
# claude-code runs in an ISOLATED config dir so it can never fall back to (or contaminate)
# the machine's real Anthropic / Opus login. Env is set on the child process only, never
# persisted or printed. Rows are estimand=optimized_system, harness_variant=claude_code_proxy.
param(
  [string]$Prompt,
  [string]$PromptFile,
  [string]$Model = 'kimi-k3',
  [string]$BaseUrl = 'https://api.kimi.com/coding',
  [ValidateRange(1, 3600)][int]$TimeoutSeconds = 900,
  [ValidateSet('text', 'json')][string]$Mode = 'text'
)

$ErrorActionPreference = 'Stop'
$scripts = $PSScriptRoot
$kimiWrapper = Join-Path $scripts 'Invoke-KimiK3.ps1'
$approvedManifest = Join-Path $env:USERPROFILE '.codex\fleet\approved-clis.json'
$configDir = $null
$proc = $null

function Fail([string]$m) {
  $r = [ordered]@{ status = 'error'; harness = 'claude_code_proxy'; model = $Model; base_url = $BaseUrl; fail_reason = $m }
  if ($Mode -eq 'json') { Write-Output ($r | ConvertTo-Json -Compress) } else { [Console]::Error.WriteLine($m) }
  exit 1
}

try {
  if ([string]::IsNullOrWhiteSpace($Prompt) -eq [string]::IsNullOrWhiteSpace($PromptFile)) { Fail 'Provide exactly one of -Prompt or -PromptFile.' }
  if ($PromptFile) { if (-not (Test-Path -LiteralPath $PromptFile)) { Fail "PromptFile not found: $PromptFile" }; $Prompt = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path) }
  if ([string]::IsNullOrWhiteSpace($Prompt)) { Fail 'Prompt is empty.' }

  # Approved, pinned claude-code binary (same pin as Opus; we NEVER share its login — the
  # isolated config dir below guarantees the proxy child cannot see the machine credential).
  if (-not (Test-Path -LiteralPath $approvedManifest)) { Fail 'Approved Claude manifest missing.' }
  $claudePath = (Get-Content -Raw -LiteralPath $approvedManifest | ConvertFrom-Json).clis.claude.path
  if (-not (Test-Path -LiteralPath $claudePath)) { Fail "Approved claude launcher missing: $claudePath" }

  # Refresh the Kimi OAuth (writes the rotated token back to the source store), then read it.
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $kimiWrapper -Prompt 'KIMI_OK. Do not call tools.' -Mode json -TimeoutSeconds 90 > $null 2>&1
  $credPath = Join-Path $env:USERPROFILE '.kimi-code\credentials\kimi-code.json'
  if (-not (Test-Path -LiteralPath $credPath)) { Fail 'Kimi credential not found; run the native Kimi login first.' }
  $cred = Get-Content -Raw -LiteralPath $credPath | ConvertFrom-Json
  $token = [string]$cred.access_token
  if ([string]::IsNullOrWhiteSpace($token)) { Fail 'Kimi access token empty.' }
  # Token is short-lived; a run that outlives ~15 min may 401. Bounded prompts only.
  $expiresAt = 0L; try { $expiresAt = [int64]$cred.expires_at } catch { }

  $configDir = Join-Path ([IO.Path]::GetTempPath()) ('fleet-k3proxy-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $configDir | Out-Null

  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $claudePath
  $psi.Arguments = '-p --model ' + $Model + ' --output-format json'
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  # Child-scoped env ONLY. Isolated config dir + empty API key => cannot use the machine's
  # Anthropic/Opus credential; forced onto the Kimi endpoint via the bearer token.
  $psi.EnvironmentVariables['ANTHROPIC_BASE_URL'] = $BaseUrl
  $psi.EnvironmentVariables['ANTHROPIC_AUTH_TOKEN'] = $token
  $psi.EnvironmentVariables['ANTHROPIC_API_KEY'] = ''
  $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $configDir
  $psi.EnvironmentVariables['DISABLE_TELEMETRY'] = '1'
  $psi.EnvironmentVariables['DISABLE_AUTOUPDATER'] = '1'
  $psi.EnvironmentVariables['DISABLE_UPDATES'] = '1'
  $psi.EnvironmentVariables['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] = '1'

  $proc = New-Object Diagnostics.Process; $proc.StartInfo = $psi
  if (-not $proc.Start()) { Fail 'Failed to start claude-code proxy child.' }
  $started = Get-Date
  $proc.StandardInput.Write($Prompt); $proc.StandardInput.Close()
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $finished = $proc.WaitForExit(($TimeoutSeconds + 10) * 1000)
  if (-not $finished) { try { & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null } catch { } }
  $stdout = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { '' }
  $duration = [math]::Round(((Get-Date) - $started).TotalSeconds, 2)

  $parsed = $null; try { $parsed = $stdout | ConvertFrom-Json } catch { }
  $isError = $true; $text = ''
  if ($parsed) { $isError = [bool]$parsed.is_error; $text = [string]$parsed.result }
  if (-not $finished) { Fail 'Timed out; process tree killed.' }
  if (-not $parsed) { Fail 'Proxy child returned no parseable JSON.' }
  if ($isError) { Fail ('Proxy child API error: ' + $text) }

  $result = [ordered]@{
    status = 'ok'
    harness = 'claude_code_proxy'
    harness_variant = 'claude_code_proxy'
    estimand = 'optimized_system'
    transport = 'claude-code->' + $BaseUrl
    model = $Model
    model_evidence = 'base-url-pinned+model-arg'
    base_url = $BaseUrl
    token_expires_at = $expiresAt
    duration_seconds = $duration
    response = $text
  }
  if ($Mode -eq 'json') { Write-Output ($result | ConvertTo-Json -Compress -Depth 6) } else { Write-Output $text }
  exit 0
}
catch { Fail $_.Exception.Message }
finally {
  if ($proc -and -not $proc.HasExited) { try { & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null } catch { } }
  if ($proc) { try { $proc.Dispose() } catch { } }
  if ($configDir -and (Test-Path -LiteralPath $configDir)) { Remove-Item -Recurse -Force -LiteralPath $configDir -ErrorAction SilentlyContinue }
}
