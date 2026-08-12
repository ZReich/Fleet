# Live Fleet transport preflight for Grok, Opus, GLM, and Gemini/Antigravity.
# Selected-voice mode (-SelectedVoiceManifest): probe only chosen panel voices before
# packet freeze. See references/review-preflight.md.
param(
  [string]$ImagePath,
  [string]$ExpectedImageText,
  [switch]$RequireOpus,
  [switch]$RequireGlm,
  [switch]$RequireImplementation,
  [switch]$RequireGemini,
  [switch]$RequireKimi,
  [switch]$KimiOnly,
  [switch]$ForceProbe,
  # Selected-voice preflight (T2). When set, legacy flag probes are skipped.
  [string]$SelectedVoiceManifest,
  [string]$RunId,
  [string]$OutputPath,
  [ValidateSet('text', 'json')]
  [string]$Mode = 'text',
  # Private test hooks (not public API): injectable probes + cache/lease overrides.
  [hashtable]$ProbeCommandTable,
  [string]$CachePathOverride,
  [string]$LeaseDirOverride,
  [object]$UtcNowOverride
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ($null -ne $ProbeCommandTable -and $env:FLEET_TEST_HARNESS -cne '1') { throw 'ProbeCommandTable override refused: FLEET_TEST_HARNESS=1 is required.' }

# ---------------------------------------------------------------------------
# Selected-voice preflight path
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($SelectedVoiceManifest)) {
  if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'Selected-voice preflight requires -RunId.' }
  . (Join-Path $scriptRoot 'FleetReviewPreflight.Helpers.ps1')
  $pf = Invoke-FleetReviewPreflight `
    -SelectedVoiceManifest $SelectedVoiceManifest `
    -RunId $RunId `
    -OutputPath $OutputPath `
    -Mode $Mode `
    -ForceProbe:$ForceProbe `
    -ProbeCommandTable $ProbeCommandTable `
    -CachePathOverride $CachePathOverride `
    -LeaseDirOverride $LeaseDirOverride `
    -UtcNowOverride $UtcNowOverride `
    -ScriptRoot $scriptRoot
  if ($Mode -eq 'json') { Write-Output $pf.EvidenceJson }
  Write-Output $pf.StatusLine
  if (-not $pf.Ready) { exit 1 }
  exit 0
}

# ---------------------------------------------------------------------------
# Legacy external-lane probes (unchanged behavior)
# ---------------------------------------------------------------------------

# Version-keyed probe cache: skip re-probing when no CLI version changed. Keyed on the
# required-lane set + the installed CLI versions from cli-update-status.json. Fresh for
# 24h, or 1h while a run lease is held (in-lease work wants tighter liveness).
function Get-LaneCacheKey {
  $status = $null
  try { $status = Get-Content -LiteralPath "$env:USERPROFILE\.codex\fleet\cli-update-status.json" -Raw | ConvertFrom-Json } catch { }
  $versions = if ($status) { @('grok','claude','pi','antigravity','kimi') | ForEach-Object { [string]$status.clis.$_.current_version } } else { @('unknown') }
  $flags = @("O=$([bool]$RequireOpus)", "G=$([bool]$RequireGlm)", "I=$([bool]$RequireImplementation)", "M=$([bool]$RequireGemini)", "K=$([bool]$RequireKimi)")
  $material = ($flags + $versions) -join '|'
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material)) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}
$laneCachePath = "$env:USERPROFILE\.codex\fleet\lane-probe-cache.json"
$laneCacheKey = Get-LaneCacheKey
if (-not $KimiOnly -and -not $ForceProbe -and (Test-Path -LiteralPath $laneCachePath)) {
  try {
    $cache = Get-Content -LiteralPath $laneCachePath -Raw | ConvertFrom-Json
    $inLease = @(Get-ChildItem -LiteralPath "$env:USERPROFILE\.codex\fleet\run-leases" -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0
    $ttlHours = if ($inLease) { 1 } else { 24 }
    # A cached FAILURE is never a hit: entries written before the write-guard below (and any
    # hand-edited file) can carry fail>0, and short-circuiting on one would re-serve a known
    # failure as a pass for the rest of the TTL. Unreadable/absent counts re-probe too.
    $cachedFail = if ($null -ne $cache.PSObject.Properties['fail']) { [int]$cache.fail } else { 1 }
    $cachedPass = if ($null -ne $cache.PSObject.Properties['pass']) { [int]$cache.pass } else { 0 }
    if ($cachedFail -eq 0 -and [string]$cache.key -eq $laneCacheKey -and [datetimeoffset]$cache.checked_at -gt [datetimeoffset]::Now.AddHours(-$ttlHours)) {
      Write-Host "CACHED external lanes verified $($cache.checked_at) (key $($laneCacheKey.Substring(0,12)); pass -ForceProbe to re-probe)"
      # Denominator on every exit path: Test-FleetAll scores a suite by this line, so a
      # bare CACHED line read as "(no denominator line)" + exit 0 = PASS with nothing run.
      Write-Host "TOTAL $cachedPass passed, $cachedFail failed (cached)"
      exit 0
    }
  } catch { }
}
if ($KimiOnly) {
  if (-not $RequireKimi) { throw "KimiOnly requires RequireKimi." }
  $kimiWrapper = Join-Path $PSScriptRoot "Invoke-KimiK3.ps1"
  $kimiRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $kimiWrapper -Prompt "Reply exactly KIMI_OK. Do not call tools." -TimeoutSeconds 180 -Mode json
  $kimi = $null
  try { $kimi = $kimiRaw | ConvertFrom-Json } catch { }
  $kimiTextOk = $LASTEXITCODE -eq 0 -and $kimi.status -eq "ok" -and $kimi.response.Trim() -eq "KIMI_OK" -and $kimi.model -eq "kimi-code/k3" -and $kimi.tool_call_count -eq 0 -and $kimi.credential_cleanup_verified
  if ($kimiTextOk) { Write-Host "PASS Kimi K3 artifact-only wrapper" } else { Write-Host "FAIL Kimi K3 artifact-only wrapper" }
  $kimiImageOk = $true
  if ($ImagePath) {
    if (-not (Test-Path -LiteralPath $ImagePath)) { throw "ImagePath not found: $ImagePath" }
    $kimiImageRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $kimiWrapper -Mode json -ImageFile $ImagePath -Prompt "Inspect only the copied image. Reply only with the exact status text beneath Active in the right sidebar. Do not call any tool except ReadMediaFile for the copied image." -TimeoutSeconds 180
    $kimiImage = $null
    try { $kimiImage = $kimiImageRaw | ConvertFrom-Json } catch { }
    $kimiReadEvidence = @($kimiImage.tool_evidence | Where-Object { $_.name -eq "ReadMediaFile" -and $_.copied_image_path })
    $kimiImageOk = $LASTEXITCODE -eq 0 -and $kimiImage.status -eq "ok" -and $kimiReadEvidence.Count -eq 1 -and $kimiImage.credential_cleanup_verified
    if ($ExpectedImageText) { $kimiImageOk = $kimiImageOk -and $kimiImage.response.Trim() -eq $ExpectedImageText }
    if ($kimiImageOk) { Write-Host "PASS Kimi K3 multimodal copied-image wrapper" } else { Write-Host "FAIL Kimi K3 multimodal copied-image wrapper" }
  }
  if (-not ($kimiTextOk -and $kimiImageOk)) { exit 1 }
  exit 0
}
$pass = 0
$fail = 0
$requiredFail = 0
$root = Join-Path ([IO.Path]::GetTempPath()) ("fleet-external-test-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $root | Out-Null

function Check {
  param([bool]$Condition, [string]$Name, [bool]$Required = $true)
  if ($Condition) { $script:pass++; Write-Host "PASS $Name" }
  else {
    $script:fail++
    if ($Required) { $script:requiredFail++ }
    Write-Host "FAIL $Name ($(if ($Required) { 'required' } else { 'optional/no_contest' }))"
  }
}

try {
  $grokPrompt = Join-Path $root "grok.txt"
  $opusPrompt = Join-Path $root "opus.txt"
  $glmPrompt = Join-Path $root "glm.txt"
  [IO.File]::WriteAllText($grokPrompt, @"
Review this literal transport packet in free-form Markdown; no repository file or executable check is required.
Packet: wrapper=Invoke-Grok45.ps1; requested_model=grok-4.5; expected_mode=markdown-review; mutation_allowed=false.
Write a short review stating the packet is readable and list no blockers.
"@, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($opusPrompt, "Reply exactly OPUS_OK", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($glmPrompt, "Reply exactly GLM_OK", (New-Object Text.UTF8Encoding($false)))

  $grokRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Invoke-Grok45.ps1") `
    -PromptFile $grokPrompt -Effort low -Review -Mode json -TimeoutSeconds 90 -HeartbeatSeconds 120
  $grok = $null
  try { $grok = $grokRaw | ConvertFrom-Json } catch { }
  $grokOk = $LASTEXITCODE -eq 0 -and $grok.status -eq "ok" -and $grok.lane -eq "read_only" -and $grok.self_audit_required -eq $false -and $grok.self_audit_verified -eq $false -and $null -eq $grok.audit -and -not [string]::IsNullOrWhiteSpace([string]$grok.response) -and $grok.observed_model -eq "grok-4.5"
  Check $grokOk "Grok 4.5 wrapper"
  if (-not $grokOk -and $grok) { Write-Host ("  Grok detail: " + ($grok | ConvertTo-Json -Compress -Depth 8)) }

  if ($RequireKimi) {
    $kimiRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Invoke-KimiK3.ps1") -Prompt "Reply exactly KIMI_OK. Do not call tools." -TimeoutSeconds 180 -Mode json
    $kimi = $null
    try { $kimi = $kimiRaw | ConvertFrom-Json } catch { }
    $kimiOk = $LASTEXITCODE -eq 0 -and $kimi.status -eq "ok" -and $kimi.response.Trim() -eq "KIMI_OK" -and $kimi.model -eq "kimi-code/k3" -and $kimi.tool_call_count -eq 0 -and $kimi.credential_cleanup_verified
    Check $kimiOk "Kimi K3 artifact-only wrapper"
    if (-not $kimiOk -and $kimi) { Write-Host ("  Kimi detail: " + ($kimi | ConvertTo-Json -Compress -Depth 8)) }
  }

  if ($RequireImplementation) {
  $implProbeFile = Join-Path $root "grok-implementation-write.txt"
  [IO.File]::WriteAllText($implProbeFile, "PENDING", (New-Object Text.UTF8Encoding($false)))
  $implPrompt = "Use the file-edit tool to replace PENDING in $implProbeFile with exactly FLEET_WRITE_OK. Then return status done, list grok-implementation-write.txt in files_changed and files_reviewed, include one passed acceptance criterion with observed evidence, one audit pass, no findings, no fixes, no remaining checks, and a nonblank self_check."
  $grokImplRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Invoke-Grok45.ps1") `
    -Prompt $implPrompt -WorkingDirectory $root -Effort low -Mode json -TimeoutSeconds 90 -HeartbeatSeconds 120
  $grokImpl = $null
  try { $grokImpl = $grokImplRaw | ConvertFrom-Json } catch { }
  $implBody = if (Test-Path -LiteralPath $implProbeFile) { [IO.File]::ReadAllText($implProbeFile).Trim() } else { "" }
  $grokImplOk = $LASTEXITCODE -eq 0 -and $grokImpl.status -eq "ok" -and $grokImpl.self_audit_verified -and $grokImpl.audit.audit_passes -ge 1 -and $implBody -eq "FLEET_WRITE_OK"
  Check $grokImplOk "Grok 4.5 implementation tools and self-audit"
  if (-not $grokImplOk -and $grokImpl) { Write-Host ("  Grok implementation detail: " + ($grokImpl | ConvertTo-Json -Compress -Depth 8)) }
  }

  $opusRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Invoke-Opus48.ps1") `
    -PromptFile $opusPrompt -Effort low -Mode json -TimeoutSeconds 90 -HeartbeatSeconds 120
  $opus = $null
  try { $opus = $opusRaw | ConvertFrom-Json } catch { }
  # Assert the seat the WRAPPER reports was actually observed, not a hardcoded literal: the
  # seat moved to claude-opus-5 on 2026-07-26 and this line still pinned claude-opus-4-8,
  # so a fully healthy lane (status ok, OPUS_OK, exit 0) failed the preflight.
  $opusSeat = [string]$opus.model
  $opusOk = $LASTEXITCODE -eq 0 -and $opus.status -eq "ok" -and $opus.response.Trim() -eq "OPUS_OK" -and $opusSeat -match '^claude-opus-' -and $opusSeat -in @($opus.observed_models)
  Check $opusOk "Opus wrapper ($(if ($opusSeat) { $opusSeat } else { 'no seat reported' }))" ([bool]$RequireOpus)
  if (-not $opusOk -and $opus) { Write-Host ("  Opus detail: " + ($opus | ConvertTo-Json -Compress -Depth 5)) }

  $glmRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Invoke-PiGlm.ps1") `
    -PromptFile $glmPrompt -Thinking off -NoTools -Mode json -TimeoutSeconds 120 -HeartbeatSeconds 120
  $glm = $null
  try { $glm = $glmRaw | ConvertFrom-Json } catch { }
  $glmOk = $LASTEXITCODE -eq 0 -and $glm.status -eq "ok" -and $glm.response.Trim() -eq "GLM_OK" -and $glm.model -eq "glm-5.2" -and $glm.provider -eq "zai"
  Check $glmOk "GLM 5.2 via Pi wrapper" ([bool]$RequireGlm)
  if (-not $glmOk -and $glm) { Write-Host ("  GLM detail: " + ($glm | ConvertTo-Json -Compress -Depth 5)) }

  if ($RequireGemini -or $ImagePath) {
  $geminiRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Invoke-Gemini35.ps1") `
    -Mode json -Prompt "Reply exactly GEMINI_OK. Do not use tools." -TimeoutSeconds 60
  $gemini = $null
  try { $gemini = $geminiRaw | ConvertFrom-Json } catch { }
  Check ($LASTEXITCODE -eq 0 -and $gemini.status -eq "ok" -and $gemini.response.Trim() -eq "GEMINI_OK" -and $gemini.observed_model -eq "Gemini 3.5 Flash (Low)") "Gemini 3.5 Flash Low via agy" ([bool]$RequireGemini)
  }

  if ($ImagePath) {
    if (-not (Test-Path -LiteralPath $ImagePath)) { throw "ImagePath not found: $ImagePath" }
    $captureDir = Split-Path -Parent (Resolve-Path -LiteralPath $ImagePath).Path
    $imagePrompt = "Inspect the image at $ImagePath. Reply only with the exact status text beneath Active in the right sidebar."
    $imageRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Invoke-Gemini35.ps1") `
      -Mode json -CaptureDir $captureDir -Prompt $imagePrompt -TimeoutSeconds 60
    $image = $null
    try { $image = $imageRaw | ConvertFrom-Json } catch { }
    $imageOk = $LASTEXITCODE -eq 0 -and $image.status -eq "ok" -and $image.observed_model -eq "Gemini 3.5 Flash (Low)"
    if ($ExpectedImageText) { $imageOk = $imageOk -and $image.response.Trim() -eq $ExpectedImageText }
    Check $imageOk "Gemini multimodal image" ([bool]$RequireGemini)

    if ($RequireKimi) {
      $kimiImagePrompt = "Inspect only the copied image. Reply only with the exact status text beneath Active in the right sidebar. Do not call any tool except ReadMediaFile for the copied image."
      $kimiImageRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Invoke-KimiK3.ps1") `
        -Mode json -ImageFile $ImagePath -Prompt $kimiImagePrompt -TimeoutSeconds 180
      $kimiImage = $null
      try { $kimiImage = $kimiImageRaw | ConvertFrom-Json } catch { }
      $kimiReadEvidence = @($kimiImage.tool_evidence | Where-Object { $_.name -eq "ReadMediaFile" -and $_.copied_image_path })
      $kimiImageOk = $LASTEXITCODE -eq 0 -and $kimiImage.status -eq "ok" -and $kimiImage.model -eq "kimi-code/k3" -and $kimiReadEvidence.Count -eq 1 -and $kimiImage.credential_cleanup_verified
      if ($ExpectedImageText) { $kimiImageOk = $kimiImageOk -and $kimiImage.response.Trim() -eq $ExpectedImageText }
      Check $kimiImageOk "Kimi K3 multimodal copied-image wrapper" $true
      if (-not $kimiImageOk -and $kimiImage) { Write-Host ("  Kimi image detail: " + ($kimiImage | ConvertTo-Json -Compress -Depth 8)) }
    }
  }
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "TOTAL $pass passed, $fail failed"
if ($requiredFail) { exit 1 }
# Cache the verified version-keyed result so an unchanged CLI set skips the next probe.
# ONLY on a clean probe: a non-required lane failure leaves exit 0 here, so caching it
# froze "2 passed, 1 failed" into a green CACHED line for the whole TTL (live 2026-07-31).
if ($fail -eq 0) {
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $laneCachePath) | Out-Null
    [IO.File]::WriteAllText($laneCachePath, (@{ key = $laneCacheKey; checked_at = [datetimeoffset]::Now.ToString('o'); pass = $pass; fail = $fail } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
  } catch { }
}
exit 0
