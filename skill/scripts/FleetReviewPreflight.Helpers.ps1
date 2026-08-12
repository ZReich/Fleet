# Selected-voice review preflight helpers. Dot-sourced by Test-FleetExternalLanes.ps1.
# Schema + probe table: references/review-preflight.md
# PS 5.1 safe. No caller-supplied probe commands in the manifest (trust boundary).

function Get-FleetPreflightFileSha256([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $fs = [IO.File]::OpenRead($Path)
    try { return -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) }
    finally { $fs.Dispose() }
  } finally { $sha.Dispose() }
}

# Strict READY check for a hashed packet artifact path only (never repo-root lookup).
function Test-FleetPreflightReadyArtifact([string]$Path, [string]$ExpectedRunId) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $utf8Local = New-Object System.Text.UTF8Encoding $false
    $obj = [IO.File]::ReadAllText($Path, $utf8Local) | ConvertFrom-Json -ErrorAction Stop
  } catch { return $false }
  if ([string]$obj.schema_version -cne '1') { return $false }
  if ([string]::IsNullOrWhiteSpace($ExpectedRunId) -or [string]$obj.run_id -cne $ExpectedRunId) { return $false }
  if ([string]$obj.status -cne 'READY') { return $false }
  $line = ''
  if ($obj.PSObject.Properties['status_line']) { $line = [string]$obj.status_line }
  if ($line -cnotmatch '^review-preflight: READY \| selected: \d+ \| passed: \d+ \| cached: \d+ \| failed: 0$') { return $false }
  $match = [regex]::Match($line, '^review-preflight: READY \| selected: (\d+) \| passed: (\d+) \| cached: (\d+) \| failed: (\d+)$')
  if (-not $match.Success) { return $false }
  $fieldIndex = 1
  foreach ($name in @('selected', 'passed', 'cached', 'failed')) {
    if (-not $obj.PSObject.Properties[$name]) { return $false }
    $n = 0; if (-not [int]::TryParse([string]$obj.$name, [ref]$n) -or $n -ne [int]$match.Groups[$fieldIndex].Value) { return $false }
    $fieldIndex++
  }
  if ([int]$obj.failed -ne 0) { return $false }
  return $true
}

function Get-FleetPreflightCacheKey([string]$Cli, [string]$Version, [string]$Profile, [string]$WrapperSha) {
  $material = "$Cli|$Version|$Profile|$WrapperSha"
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material)) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Test-FleetPreflightAuthFail([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
  return [bool]($Text -match '(?i)\b(401|oauth[^\n]{0,40}expir|login_required|credentials?\s+expir|not\s+authenticated|authentication\s+fail|auth\s+expir|unauthorized)\b')
}

function Test-FleetPreflightArgFail([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  if ($Text -match '(?i)(missing.*-?PromptFile|PromptFile\s+(is\s+)?required|Provide exactly one of\s+-?Prompt)') { return $true }
  if ($Text -match "(?i)(parameter cannot be found that matches parameter name ['\`"]?Repo|unsupported.*-?Repo)") { return $true }
  return $false
}

function Test-FleetPreflightPass([int]$ExitCode, [string]$Output) {
  if ($ExitCode -ne 0) { return $false }
  if ([string]::IsNullOrWhiteSpace($Output)) { return $false }
  if (Test-FleetPreflightAuthFail $Output) { return $false }
  if (Test-FleetPreflightArgFail $Output) { return $false }
  if ($Output -match '(?i)"status"\s*:\s*"(error|failed|blocked)"') { return $false }
  return $true
}

function Get-FleetPreflightCliVersion([string]$Cli) {
  $statusPath = Join-Path $env:USERPROFILE '.codex\fleet\cli-update-status.json'
  if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
    try {
      $st = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
      $key = $Cli
      if ($st.clis.PSObject.Properties[$key]) {
        $v = [string]$st.clis.$key.current_version
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
      }
    } catch { }
  }
  return 'unknown'
}

# Map canonical voice -> wrapper file + cli name (no execution).
function Get-FleetPreflightVoiceMeta {
  param([string]$Voice, [string]$ScriptRoot)
  $vk = $Voice.ToLowerInvariant()
  $map = @{
    'sol'           = @{ File = 'Invoke-Sol.ps1';        Cli = 'codex' }
    'terra'         = @{ File = 'New-CodexLaneHome.ps1';  Cli = 'codex' }
    'opus'          = @{ File = 'Invoke-Opus48.ps1';      Cli = 'claude' }
    'glm'           = @{ File = 'Invoke-PiGlm.ps1';       Cli = 'pi' }
    'glm-security'  = @{ File = 'Invoke-PiGlm.ps1';       Cli = 'pi' }
    'grok'          = @{ File = 'Invoke-Grok45.ps1';      Cli = 'grok' }
    'kimi-security' = @{ File = 'Invoke-KimiK3.ps1';      Cli = 'kimi' }
    'kimi-proxy'    = @{ File = 'Invoke-KimiK3Proxy.ps1'; Cli = 'kimi' }
  }
  if (-not $map.ContainsKey($vk)) {
    return [pscustomobject]@{ Ok = $false; Voice = $vk; WrapperPath = $null; Cli = 'none'; Version = 'none'; WrapperSha256 = 'none'; Detail = "unknown voice '$Voice'" }
  }
  $m = $map[$vk]
  $wp = Join-Path $ScriptRoot $m.File
  $wsha = 'missing'
  if (Test-Path -LiteralPath $wp -PathType Leaf) { $wsha = Get-FleetPreflightFileSha256 $wp }
  $ver = Get-FleetPreflightCliVersion $m.Cli
  return [pscustomobject]@{
    Ok = $true; Voice = $vk; WrapperPath = $wp; Cli = [string]$m.Cli
    Version = $ver; WrapperSha256 = $wsha; Detail = ''
  }
}

function Invoke-FleetWrapperFileProbe {
  param([string]$WrapperPath, [string[]]$ArgList)
  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $WrapperPath @ArgList 2>&1 | Out-String
  return [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = [string]$raw }
}

function Invoke-FleetDefaultVoiceProbe {
  param([string]$Voice, [string]$ProbeProfile, [string]$TempRoot, [string]$ScriptRoot, $Utf8)
  $meta = Get-FleetPreflightVoiceMeta -Voice $Voice -ScriptRoot $ScriptRoot
  if (-not $meta.Ok) {
    return [pscustomobject]@{ ExitCode = 1; Output = $meta.Detail; Cli = $meta.Cli; Version = $meta.Version; WrapperSha256 = $meta.WrapperSha256 }
  }
  $vk = $meta.Voice
  $exitCode = 1
  $output = ''
  $tmpPrompt = Join-Path $TempRoot ("probe-" + $vk + ".txt")
  [IO.File]::WriteAllText($tmpPrompt, "Reply exactly PREFLIGHT_OK", $Utf8)
  try {
    switch ($vk) {
      'sol' {
        $r = Invoke-FleetWrapperFileProbe $meta.WrapperPath @('-Probe', '-Mode', 'json', '-TimeoutSeconds', '120')
        $exitCode = $r.ExitCode; $output = $r.Output
      }
      'terra' {
        $laneHome = (& $meta.WrapperPath -Label 'terra-preflight' 2>$null | Select-Object -Last 1)
        $approved = Join-Path $env:USERPROFILE '.codex\fleet\approved-clis.json'
        $codexPath = $null
        if (Test-Path -LiteralPath $approved) {
          try { $codexPath = [string](Get-Content -LiteralPath $approved -Raw | ConvertFrom-Json).clis.codex.path } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($codexPath) -or -not (Test-Path -LiteralPath $codexPath -PathType Leaf)) {
          $exitCode = 1; $output = 'terra preflight: approved codex path missing'
        } else {
          $prior = $env:CODEX_HOME
          try {
            if (-not [string]::IsNullOrWhiteSpace([string]$laneHome)) { $env:CODEX_HOME = [string]$laneHome }
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $codexPath
            $psi.Arguments = 'exec -c model="gpt-5.6-terra" -c model_reasoning_effort="low" -s read-only --skip-git-repo-check -'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $proc = New-Object Diagnostics.Process; $proc.StartInfo = $psi
            [void]$proc.Start(); $null = $proc.Handle
            $proc.StandardInput.Write('Reply exactly PREFLIGHT_OK'); $proc.StandardInput.Close()
            if (-not $proc.WaitForExit(120000)) { try { $proc.Kill() } catch { }; $exitCode = 1; $output = 'terra preflight: timeout' }
            else { $exitCode = $proc.ExitCode; $output = ($proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()) }
          } finally {
            if ($null -eq $prior) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $prior }
          }
        }
      }
      'opus' {
        $r = Invoke-FleetWrapperFileProbe $meta.WrapperPath @('-Model', 'claude-opus-5', '-PromptFile', $tmpPrompt, '-Effort', 'low', '-Mode', 'json', '-TimeoutSeconds', '90')
        $exitCode = $r.ExitCode; $output = $r.Output
      }
      { $_ -in @('glm', 'glm-security') } {
        $r = Invoke-FleetWrapperFileProbe $meta.WrapperPath @('-PromptFile', $tmpPrompt, '-Thinking', 'off', '-NoTools', '-Mode', 'json', '-TimeoutSeconds', '90')
        $exitCode = $r.ExitCode; $output = $r.Output
      }
      'grok' {
        $r = Invoke-FleetWrapperFileProbe $meta.WrapperPath @('-PromptFile', $tmpPrompt, '-Review', '-Effort', 'low', '-Mode', 'json', '-TimeoutSeconds', '90')
        $exitCode = $r.ExitCode; $output = $r.Output
      }
      'kimi-security' {
        $bits = @()
        $cred = Join-Path $env:USERPROFILE '.kimi-code\credentials\kimi-code.json'
        if (-not (Test-Path -LiteralPath $cred -PathType Leaf)) { $bits += 'kimi credential missing' }
        else {
          try {
            $c = Get-Content -LiteralPath $cred -Raw | ConvertFrom-Json
            $at = if ($c.PSObject.Properties['access_token']) { [string]$c.access_token } else { '' }
            $rt = if ($c.PSObject.Properties['refresh_token']) { [string]$c.refresh_token } else { '' }
            if ([string]::IsNullOrWhiteSpace($at) -and [string]::IsNullOrWhiteSpace($rt)) { $bits += 'kimi OAuth expired / empty tokens' }
          } catch { $bits += 'kimi credential unreadable' }
        }
        # Unsupported -Repo must be rejected (correct param is -RepoSandbox).
        $repoOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $meta.WrapperPath -Repo bogus -Prompt 'x' 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { $bits += 'unsupported -Repo was accepted' }
        if ($bits.Count -eq 0) { $exitCode = 0; $output = 'kimi-security auth+param validation OK' }
        else { $exitCode = 1; $output = ($bits -join '; ') }
      }
      'kimi-proxy' {
        $r = Invoke-FleetWrapperFileProbe $meta.WrapperPath @('-Prompt', 'Reply exactly PREFLIGHT_OK', '-Mode', 'json', '-TimeoutSeconds', '90')
        $exitCode = $r.ExitCode; $output = $r.Output
      }
    }
  } catch {
    $exitCode = 1
    $output = [string]$_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($output)) { $output = [string]$_ }
  }
  return [pscustomobject]@{
    ExitCode = [int]$exitCode; Output = [string]$output
    Cli = $meta.Cli; Version = $meta.Version; WrapperSha256 = $meta.WrapperSha256
  }
}

function Invoke-FleetReviewPreflight {
  param(
    [Parameter(Mandatory)][string]$SelectedVoiceManifest,
    [Parameter(Mandatory)][string]$RunId,
    [string]$OutputPath,
    [ValidateSet('text', 'json')][string]$Mode = 'text',
    [switch]$ForceProbe,
    [hashtable]$ProbeCommandTable,
    [string]$CachePathOverride,
    [string]$LeaseDirOverride,
    [object]$UtcNowOverride,
    [string]$ScriptRoot
  )
  $ErrorActionPreference = 'Stop'
  $utf8 = New-Object Text.UTF8Encoding $false
  if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { throw 'ScriptRoot required for preflight' }
  }

  if (-not (Test-Path -LiteralPath $SelectedVoiceManifest -PathType Leaf)) {
    throw "SelectedVoiceManifest not found: $SelectedVoiceManifest"
  }
  $manifestRaw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $SelectedVoiceManifest).Path)
  try { $manifest = $manifestRaw | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "SelectedVoiceManifest is not valid JSON: $SelectedVoiceManifest" }
  if ([string]$manifest.schema_version -ne '1') { throw 'SelectedVoiceManifest schema_version must be 1' }
  $manifestRun = [string]$manifest.run_id
  if ([string]::IsNullOrWhiteSpace($manifestRun)) { throw 'SelectedVoiceManifest run_id is required' }
  if (-not [string]::Equals($manifestRun, $RunId, [StringComparison]::Ordinal)) {
    throw "SelectedVoiceManifest run_id '$manifestRun' does not match -RunId '$RunId'"
  }
  $selectedRows = @($manifest.selected)
  if ($selectedRows.Count -eq 0) { throw 'SelectedVoiceManifest selected[] is empty' }

  $cachePath = if (-not [string]::IsNullOrWhiteSpace($CachePathOverride)) { $CachePathOverride } else { Join-Path $env:USERPROFILE '.codex\fleet\review-preflight-cache.json' }
  $leaseDir = if (-not [string]::IsNullOrWhiteSpace($LeaseDirOverride)) { $LeaseDirOverride } else { Join-Path $env:USERPROFILE '.codex\fleet\run-leases' }
  $now = if ($null -ne $UtcNowOverride) { [datetimeoffset]$UtcNowOverride } else { [datetimeoffset]::UtcNow }
  $inLease = $false
  if (Test-Path -LiteralPath $leaseDir -PathType Container) {
    $inLease = @(Get-ChildItem -LiteralPath $leaseDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0
  }
  $ttlHours = if ($inLease) { 1 } else { 24 }

  $cacheEntries = @{}
  if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
    try {
      $cacheObj = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
      if ($null -ne $cacheObj -and $null -ne $cacheObj.entries) {
        foreach ($p in @($cacheObj.entries.PSObject.Properties)) {
          if ($p.MemberType -eq 'NoteProperty') { $cacheEntries[$p.Name] = $p.Value }
        }
      }
    } catch { $cacheEntries = @{} }
  }

  $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('fleet-preflight-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
  $voiceResults = New-Object System.Collections.ArrayList
  $passCount = 0; $failCount = 0; $cachedCount = 0; $cacheDirty = $false
  function Add-VoiceResult([string]$LaneId, [string]$Voice, [string]$Profile, [string]$Result, [bool]$CacheHit, [string]$Cli, [string]$Ver, [string]$Wsha, [string]$Detail) {
    [void]$voiceResults.Add([ordered]@{
      lane_id = $LaneId; voice = $Voice; probe_profile = $Profile; result = $Result
      cache_hit = $CacheHit; cli = $Cli; version = $Ver; wrapper_sha256 = $Wsha; detail = $Detail
    })
  }
  try {
    foreach ($row in $selectedRows) {
      $laneId = [string]$row.lane_id; $voice = [string]$row.voice; $profile = [string]$row.probe_profile
      if ([string]::IsNullOrWhiteSpace($laneId) -or [string]::IsNullOrWhiteSpace($voice) -or [string]::IsNullOrWhiteSpace($profile)) {
        Add-VoiceResult $laneId $voice $profile 'fail' $false 'none' 'none' 'none' 'manifest row missing lane_id/voice/probe_profile'
        $failCount++; continue
      }
      $meta = Get-FleetPreflightVoiceMeta -Voice $voice -ScriptRoot $ScriptRoot
      $cli = $meta.Cli; $ver = $meta.Version; $wsha = $meta.WrapperSha256
      if (-not $meta.Ok) {
        Add-VoiceResult $laneId $voice $profile 'fail' $false 'none' 'none' 'none' 'omitted selected voice (no probe derived)'
        $failCount++; continue
      }
      $injectKey = $null
      if ($null -ne $ProbeCommandTable) {
        if ($ProbeCommandTable.ContainsKey($voice)) { $injectKey = $voice }
        elseif ($ProbeCommandTable.ContainsKey($voice.ToLowerInvariant())) { $injectKey = $voice.ToLowerInvariant() }
      }
      if ($null -ne $injectKey -and $ProbeCommandTable[$injectKey] -is [hashtable]) {
        $spec = $ProbeCommandTable[$injectKey]
        if ($spec.ContainsKey('Cli')) { $cli = [string]$spec.Cli }
        if ($spec.ContainsKey('Version')) { $ver = [string]$spec.Version }
        if ($spec.ContainsKey('WrapperSha256')) { $wsha = [string]$spec.WrapperSha256 }
      }
      $ckey = Get-FleetPreflightCacheKey -Cli $cli -Version $ver -Profile $profile -WrapperSha $wsha
      if (-not $ForceProbe -and $cacheEntries.ContainsKey($ckey)) {
        $entry = $cacheEntries[$ckey]
        $checkedAt = $null
        try { $checkedAt = [datetimeoffset]$entry.checked_at } catch { $checkedAt = $null }
        $entryResult = if ($null -ne $entry -and $entry.PSObject.Properties['result']) { [string]$entry.result } else { '' }
        if ($null -ne $checkedAt -and $checkedAt -gt $now.AddHours(-1 * $ttlHours) -and $entryResult -eq 'pass') {
          $passCount++; $cachedCount++
          Add-VoiceResult $laneId $voice $profile 'pass' $true $cli $ver $wsha 'cache hit'
          continue
        }
      }
      $probe = $null
      if ($null -ne $injectKey) {
        $handler = $ProbeCommandTable[$injectKey]
        if ($handler -is [hashtable]) {
          if ($handler.ContainsKey('Invoke')) { $probe = & $handler.Invoke $voice $profile $tmpRoot }
        } else { $probe = & $handler $voice $profile $tmpRoot }
      } else {
        $probe = Invoke-FleetDefaultVoiceProbe -Voice $voice -ProbeProfile $profile -TempRoot $tmpRoot -ScriptRoot $ScriptRoot -Utf8 $utf8
      }
      if ($null -eq $probe) {
        Add-VoiceResult $laneId $voice $profile 'fail' $false $cli $ver $wsha 'omitted selected voice (no probe result)'
        $failCount++; continue
      }
      if ($probe.PSObject.Properties['Cli'] -and -not [string]::IsNullOrWhiteSpace([string]$probe.Cli)) { $cli = [string]$probe.Cli }
      if ($probe.PSObject.Properties['Version'] -and -not [string]::IsNullOrWhiteSpace([string]$probe.Version)) { $ver = [string]$probe.Version }
      if ($probe.PSObject.Properties['WrapperSha256'] -and -not [string]::IsNullOrWhiteSpace([string]$probe.WrapperSha256)) { $wsha = [string]$probe.WrapperSha256 }
      $ckey = Get-FleetPreflightCacheKey -Cli $cli -Version $ver -Profile $profile -WrapperSha $wsha
      $ok = Test-FleetPreflightPass -ExitCode ([int]$probe.ExitCode) -Output ([string]$probe.Output)
      if (-not $ok) {
        $out = [string]$probe.Output
        $detail = 'non-pass output'
        if ([string]::IsNullOrWhiteSpace($out)) { $detail = 'empty output' }
        elseif (Test-FleetPreflightAuthFail $out) { $detail = 'auth failure marker' }
        elseif (Test-FleetPreflightArgFail $out) { $detail = 'argument error' }
        elseif ([int]$probe.ExitCode -ne 0) { $detail = "exit $($probe.ExitCode)" }
        if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
        $failCount++
        Add-VoiceResult $laneId $voice $profile 'fail' $false $cli $ver $wsha $detail
      } else {
        $passCount++
        Add-VoiceResult $laneId $voice $profile 'pass' $false $cli $ver $wsha ''
        $cacheEntries[$ckey] = [pscustomobject]@{
          checked_at = $now.ToString('o'); result = 'pass'; voice = $voice
          probe_profile = $profile; cli = $cli; version = $ver; wrapper_sha256 = $wsha
        }
        $cacheDirty = $true
      }
    }
  } finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  $selectedCount = $selectedRows.Count
  $ready = ($failCount -eq 0 -and $passCount -eq $selectedCount -and $selectedCount -gt 0)
  if ($ready) {
    $statusLine = "review-preflight: READY | selected: $selectedCount | passed: $passCount | cached: $cachedCount | failed: 0"
    $status = 'READY'
  } else {
    $statusLine = "review-preflight: BLOCKED | selected: $selectedCount | passed: $passCount | failed: $failCount | substitution: REQUIRED"
    $status = 'BLOCKED'
  }
  if ($cacheDirty) {
    try {
      $cacheDir = Split-Path -Parent $cachePath
      if (-not [string]::IsNullOrWhiteSpace($cacheDir)) { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null }
      $entriesObj = [pscustomobject]@{}
      foreach ($k in @($cacheEntries.Keys)) { $entriesObj | Add-Member -NotePropertyName $k -NotePropertyValue $cacheEntries[$k] -Force }
      [IO.File]::WriteAllText($cachePath, (([ordered]@{ schema_version = '1'; entries = $entriesObj } | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine), $utf8)
    } catch { }
  }
  $evidence = [ordered]@{
    schema_version = '1'; run_id = $RunId; status = $status; status_line = $statusLine
    selected = $selectedCount; passed = $passCount; cached = $cachedCount; failed = $failCount
    voices = @($voiceResults.ToArray())
  }
  $evidenceJson = ($evidence | ConvertTo-Json -Depth 6 -Compress)
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outResolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $outDir = Split-Path -Parent $outResolved
    if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
      New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    [IO.File]::WriteAllText($outResolved, $evidenceJson + [Environment]::NewLine, $utf8)
  }
  return [pscustomobject]@{
    Ready = $ready; Status = $status; StatusLine = $statusLine; EvidenceJson = $evidenceJson
    Selected = $selectedCount; Passed = $passCount; Cached = $cachedCount; Failed = $failCount
  }
}
