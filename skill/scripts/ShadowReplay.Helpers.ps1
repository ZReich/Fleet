# Dot-sourced helpers for Invoke-ShadowReplay.ps1. Caller defines Write-Utf8 + Invoke-GitNative.
# scripts/ basename allowlist + Sol-family launch shape + Apply-LanePatch for read-only seats.

function Quote-Arguments([string[]]$Tokens) {
  ($Tokens | ForEach-Object {
    $t = [string]$_
    if (-not $t) { '""' } elseif ($t -notmatch '[\s"]') { $t } else { '"' + ($t -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"' }
  }) -join ' '
}
function Stop-Tree([Diagnostics.Process]$Process) {
  try { & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null } catch {}
  try { $null = $Process.WaitForExit(5000) } catch {}
}
function Invoke-CapturedProcess([string]$FilePath, [string[]]$Arguments, [string]$Cwd, [string]$StdoutPath, [string]$StderrPath, [int]$TimeoutSeconds, [string]$StdinText = '') {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath; $psi.Arguments = Quote-Arguments $Arguments; $psi.WorkingDirectory = $Cwd
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $proc = [Diagnostics.Process]::Start($psi)
  $outT = $proc.StandardOutput.ReadToEndAsync(); $errT = $proc.StandardError.ReadToEndAsync()
  if ($StdinText) { $proc.StandardInput.Write($StdinText) }
  $proc.StandardInput.Close()
  $timedOut = -not $proc.WaitForExit($TimeoutSeconds * 1000)
  if ($timedOut) { Stop-Tree $proc }
  $stdout = if ($outT.Wait(5000)) { [string]$outT.Result } else { '' }
  $stderr = if ($errT.Wait(5000)) { [string]$errT.Result } else { '' }
  Write-Utf8 $StdoutPath $stdout; Write-Utf8 $StderrPath $stderr
  $code = if ($timedOut) { -1 } else { $proc.ExitCode }
  $proc.Dispose()
  [pscustomobject]@{ exit_code = $code; timed_out = $timedOut; stdout = $StdoutPath; stderr = $StderrPath }
}

$allowedWrappers = @(
  'Invoke-Grok45.ps1', 'Invoke-Sol.ps1', 'Invoke-PiGlm.ps1',
  'Invoke-Opus48.ps1', 'Invoke-KimiK3.ps1', 'Invoke-Gemini35.ps1'
)
$script:ShadowDefaultModels = @{
  terra = 'gpt-5.6-terra'; sol = 'gpt-5.6-sol'; luna = 'gpt-5.6-luna'
  grok = 'grok-4.6'; glm = 'glm-5.3'; opus = 'claude-opus-4-8'
  kimi = 'kimi-code/k3'; gemini = 'Gemini 3.6 Flash (Low)'
}
$script:ShadowWrapperCaps = @{
  'Invoke-Grok45.ps1'   = @{ transport = 'worktree'; needs_cwd = $true;  isolated = $true;  read_only = $false }
  'Invoke-Sol.ps1'      = @{ transport = 'worktree'; needs_cwd = $true;  isolated = $false; read_only = $false; shape = 'sol' }
  'Invoke-PiGlm.ps1'    = @{ transport = 'patch';    needs_cwd = $false; isolated = $false; read_only = $true }
  'Invoke-KimiK3.ps1'   = @{ transport = 'patch';    needs_cwd = $false; isolated = $false; read_only = $false }
  'Invoke-Opus48.ps1'   = @{ transport = 'worktree'; needs_cwd = $false; isolated = $false; read_only = $false }
  'Invoke-Gemini35.ps1' = @{ transport = 'worktree'; needs_cwd = $false; isolated = $false; read_only = $false }
}
$script:SolFamilyLanes = @('sol', 'terra', 'luna')

function Test-AllowedPath([string]$Path, [string[]]$Allowed) {
  $n = ($Path -replace '\\', '/').Trim('/')
  foreach ($root in $Allowed) {
    $c = ($root -replace '\\', '/').Trim('/')
    if ($n.Equals($c, [StringComparison]::OrdinalIgnoreCase) -or $n.StartsWith("$c/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Resolve-TrustedWrapper([string]$WrapperPath) {
  # Trust boundary: leaf must be on allowedWrappers; parent directory must be scripts/.
  if ([string]::IsNullOrWhiteSpace($WrapperPath)) {
    return [pscustomobject]@{ ok = $false; error = 'wrapper path empty' }
  }
  $leaf = Split-Path -Leaf $WrapperPath
  if ($leaf -notin $allowedWrappers) {
    return [pscustomobject]@{ ok = $false; error = "wrapper basename not allowed: $leaf" }
  }
  try { $full = [IO.Path]::GetFullPath($WrapperPath) } catch {
    return [pscustomobject]@{ ok = $false; error = "wrapper path invalid: $WrapperPath" }
  }
  $parentLeaf = Split-Path -Leaf (Split-Path -Parent $full)
  if ($parentLeaf -ne 'scripts') {
    return [pscustomobject]@{ ok = $false; error = "wrapper path not under scripts/: $WrapperPath" }
  }
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    return [pscustomobject]@{ ok = $false; error = "wrapper missing: $WrapperPath" }
  }
  return [pscustomobject]@{ ok = $true; path = $full; leaf = $leaf }
}

function Get-WrapperCap([string]$WrapperFile) {
  $key = Split-Path -Leaf $WrapperFile
  if ($script:ShadowWrapperCaps.ContainsKey($key)) { return $script:ShadowWrapperCaps[$key] }
  return @{ transport = 'worktree'; needs_cwd = $true; isolated = $false; read_only = $false }
}

function Get-LaneModel([string]$Lane, $ModelsMap) {
  if ($null -ne $ModelsMap -and $ModelsMap.ContainsKey($Lane) -and -not [string]::IsNullOrWhiteSpace([string]$ModelsMap[$Lane])) {
    return [string]$ModelsMap[$Lane]
  }
  if ($script:ShadowDefaultModels.ContainsKey($Lane)) { return [string]$script:ShadowDefaultModels[$Lane] }
  return $Lane
}

function Build-ArmLaunchArgs(
  [string]$Lane, [string]$WrapperPath, [string]$Prompt, [string]$PromptPath,
  [string]$Worktree, [int]$Budget, [string]$Model
) {
  $leaf = Split-Path -Leaf $WrapperPath
  $cap = Get-WrapperCap $WrapperPath
  $isSol = ($leaf -eq 'Invoke-Sol.ps1') -or ($script:SolFamilyLanes -contains $Lane)
  # Sol-family: -Prompt + explicit -Model (Invoke-Sol has no -PromptFile).
  if ($isSol) {
    return @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WrapperPath,
      '-Prompt', $Prompt, '-Model', $Model,
      '-WorkingDirectory', $Worktree, '-TimeoutSeconds', "$Budget", '-Mode', 'json'
    )
  }
  # Grok-style / patch seats: -PromptFile + WorkingDirectory (shadow fakes share this shape).
  # Do not pass Grok isolation flags here — real wrapper owns isolation; fakes reject unknown params.
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WrapperPath,
    '-PromptFile', $PromptPath, '-WorkingDirectory', $Worktree,
    '-Mode', 'json', '-TimeoutSeconds', "$Budget"
  )
  if ($cap.read_only) { $args += @('-ReadOnly') }
  return $args
}

function Apply-LanePatch(
  [string]$Lane, [string]$Worktree, [string]$PatchText, [string[]]$Allowed, [string]$ArtifactRoot
) {
  # Mirror Run-TerraGrokComparison: normalize LF, scope-check, git apply --check, then apply.
  $normalized = ([string]$PatchText) -replace "`r`n", "`n" -replace "`r", "`n"
  if ($normalized -and -not $normalized.EndsWith("`n")) { $normalized += "`n" }
  $patchPath = Join-Path $ArtifactRoot "$Lane.patch"
  Write-Utf8 $patchPath $normalized
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return [pscustomobject]@{ ok = $false; reason = 'empty_patch' }
  }
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($line in ($normalized -split "`n")) {
    if ($line -match '^diff --git a/(.+) b/(.+)$') {
      [void]$paths.Add(($Matches[2] -replace '\\', '/').Trim())
    } elseif ($line -match '^\+\+\+ b/(.+)$') {
      $p = ($Matches[1] -replace '\\', '/').Trim()
      if ($p -ne '/dev/null') { [void]$paths.Add($p) }
    }
  }
  $unique = @($paths | Sort-Object -Unique)
  $outside = @($unique | Where-Object { -not (Test-AllowedPath $_ $Allowed) })
  if ($outside.Count) {
    return [pscustomobject]@{ ok = $false; reason = 'patch_scope_violation'; outside = $outside }
  }
  $null = Invoke-GitNative $Worktree @('apply', '--check', '--whitespace=nowarn', $patchPath)
  if ($LASTEXITCODE -ne 0) {
    return [pscustomobject]@{ ok = $false; reason = 'patch_apply_check_failed' }
  }
  $null = Invoke-GitNative $Worktree @('apply', '--whitespace=nowarn', $patchPath)
  if ($LASTEXITCODE -ne 0) {
    return [pscustomobject]@{ ok = $false; reason = 'patch_apply_failed' }
  }
  return [pscustomobject]@{ ok = $true }
}

function New-ExcludedArtifacts([string]$Lane, [string]$Reason, [string]$ArtifactRoot, [string]$BaseSha) {
  $diffPath = Join-Path $ArtifactRoot "$Lane.diff"
  Write-Utf8 $diffPath ''
  [pscustomobject]@{
    status = 'excluded_capability'; exclusion_reason = $Reason
    changed_files = @(); outside_allowed_paths = @(); diff_lines = 0
    head_sha = $BaseSha; diff_path = $diffPath; gates = @()
  }
}

function Get-TransportPatchText($Transport) {
  # Wrappers may return patch OR response (model+response shape vs observed_model+patch).
  if ($null -eq $Transport) { return '' }
  $names = @($Transport.PSObject.Properties.Name)
  if ($names -contains 'patch') { return [string]$Transport.patch }
  if ($names -contains 'response') { return [string]$Transport.response }
  return ''
}

function Test-IsPatchSeat($Cap, $Transport) {
  if ($null -ne $Cap -and [string]$Cap.transport -eq 'patch') { return $true }
  if ($null -eq $Transport) { return $false }
  return (@($Transport.PSObject.Properties.Name) -contains 'patch')
}
