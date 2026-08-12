# Selected-voice preflight unit tests. Injectable ProbeCommandTable proves each BLOCK
# class and cache policy without live CLI auth. Public script path smoke-tested via
# powershell.exe -File (exit isolation).
$ErrorActionPreference = "Stop"
$helperPath = Join-Path $PSScriptRoot "FleetReviewPreflight.Helpers.ps1"
$scriptPath = Join-Path $PSScriptRoot "Test-FleetExternalLanes.ps1"
. $helperPath
$root = Join-Path ([IO.Path]::GetTempPath()) ("fleet-review-preflight-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$pass = 0
$fail = 0
$utf8 = New-Object Text.UTF8Encoding $false
$oldHarness = $env:FLEET_TEST_HARNESS

function Assert-True([bool]$Condition, [string]$Message) {
  if ($Condition) { $script:pass++; Write-Host "PASS $Message" }
  else { $script:fail++; Write-Host "FAIL $Message" }
}

function New-Manifest([string]$Path, [string]$RunId, $Selected) {
  $obj = [ordered]@{ schema_version = "1"; run_id = $RunId; selected = @($Selected) }
  [IO.File]::WriteAllText($Path, (($obj | ConvertTo-Json -Depth 5 -Compress) + "`n"), $utf8)
}

function New-PassInvoke([string]$Detail = "PREFLIGHT_OK") {
  $d = $Detail
  return {
    param($voice, $profile, $tmp)
    return [pscustomobject]@{
      ExitCode = 0; Output = $d; Cli = "mock-cli"; Version = "1.0.0"; WrapperSha256 = "deadbeef"
    }
  }.GetNewClosure()
}

function New-FailInvoke([int]$Code, [string]$OutputText) {
  $c = $Code; $o = $OutputText
  return {
    param($voice, $profile, $tmp)
    return [pscustomobject]@{
      ExitCode = $c; Output = $o; Cli = "mock-cli"; Version = "1.0.0"; WrapperSha256 = "deadbeef"
    }
  }.GetNewClosure()
}

function Invoke-UnitPreflight {
  param(
    [string]$ManifestPath,
    [string]$RunId,
    [hashtable]$Table,
    [string]$OutPath,
    [string]$CachePath,
    [string]$LeaseDir,
    [object]$UtcNow,
    [switch]$ForceProbe
  )
  $splat = @{
    SelectedVoiceManifest = $ManifestPath
    RunId = $RunId
    Mode = "json"
    ScriptRoot = $PSScriptRoot
  }
  if ($null -ne $Table) { $splat.ProbeCommandTable = $Table }
  if ($OutPath) { $splat.OutputPath = $OutPath }
  if ($CachePath) { $splat.CachePathOverride = $CachePath }
  if ($LeaseDir) { $splat.LeaseDirOverride = $LeaseDir }
  if ($null -ne $UtcNow) { $splat.UtcNowOverride = $UtcNow }
  if ($ForceProbe) { $splat.ForceProbe = $true }
  return Invoke-FleetReviewPreflight @splat
}

try {
  $env:FLEET_TEST_HARNESS = '1'
  $runId = "preflight-unit-1"
  $manifestPath = Join-Path $root "selected-voices.json"
  $row = [ordered]@{ lane_id = "v-sol"; voice = "sol"; probe_profile = "plan" }
  New-Manifest $manifestPath $runId $row
  $meta = @{ Cli = "mock-cli"; Version = "1.0.0"; WrapperSha256 = "deadbeef" }

  # --- BLOCK: expired-auth marker ---
  $r = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath (Join-Path $root "cache-auth.json") -OutPath (Join-Path $root "out-auth.json") -Table @{
    sol = ($meta + @{ Invoke = (New-FailInvoke 0 "OAuth expired: please re-login (401)") })
  }
  Assert-True (-not $r.Ready -and $r.Status -eq "BLOCKED") "expired-auth: BLOCKED"
  Assert-True ($r.StatusLine -match 'review-preflight: BLOCKED') "expired-auth: status line"
  Assert-True ($r.Failed -eq 1) "expired-auth: failed=1"
  # NEGATIVE CONTROL: same path with pass probe must READY
  $rOk = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath (Join-Path $root "cache-auth-ok.json") -Table @{
    sol = ($meta + @{ Invoke = (New-PassInvoke) })
  }
  Assert-True ($rOk.Ready -and $rOk.Status -eq "READY") "negative-control: pass probe READY"

  # --- BLOCK: empty output ---
  $r = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath (Join-Path $root "cache-empty.json") -Table @{
    sol = ($meta + @{ Invoke = (New-FailInvoke 0 "") })
  }
  Assert-True (-not $r.Ready -and $r.StatusLine -match 'BLOCKED') "empty-output: BLOCKED"

  # --- BLOCK: missing -PromptFile arg error ---
  $outPf = Join-Path $root "out-pf.json"
  $r = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath (Join-Path $root "cache-pf.json") -OutPath $outPf -Table @{
    sol = ($meta + @{ Invoke = (New-FailInvoke 1 "Provide exactly one of -Prompt or -PromptFile.") })
  }
  $evPf = Get-Content -LiteralPath $outPf -Raw | ConvertFrom-Json
  Assert-True (-not $r.Ready -and $evPf.status -eq "BLOCKED") "missing-PromptFile: BLOCKED"
  Assert-True ($evPf.voices[0].detail -match 'argument') "missing-PromptFile: argument detail"

  # --- BLOCK: unsupported -Repo arg error ---
  $outRepo = Join-Path $root "out-repo.json"
  $r = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath (Join-Path $root "cache-repo.json") -OutPath $outRepo -Table @{
    sol = ($meta + @{ Invoke = (New-FailInvoke 1 "A parameter cannot be found that matches parameter name 'Repo'.") })
  }
  $evRepo = Get-Content -LiteralPath $outRepo -Raw | ConvertFrom-Json
  Assert-True (-not $r.Ready -and $evRepo.status -eq "BLOCKED") "unsupported-Repo: BLOCKED"
  Assert-True ($evRepo.voices[0].detail -match 'argument') "unsupported-Repo: argument detail"

  # --- BLOCK: omitted selected voice (hashtable without Invoke) ---
  $outOmit = Join-Path $root "out-omit.json"
  $r = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath (Join-Path $root "cache-omit.json") -OutPath $outOmit -Table @{
    sol = @{ Cli = "mock-cli"; Version = "1.0.0"; WrapperSha256 = "deadbeef" }
  }
  $evOmit = Get-Content -LiteralPath $outOmit -Raw | ConvertFrom-Json
  Assert-True (-not $r.Ready -and $evOmit.status -eq "BLOCKED") "omitted-voice: BLOCKED"
  Assert-True ($evOmit.voices[0].detail -match 'omitted|no probe') "omitted-voice: detail"

  # unknown voice (no derived probe)
  $badVoiceManifest = Join-Path $root "selected-unknown.json"
  New-Manifest $badVoiceManifest $runId ([ordered]@{ lane_id = "v-x"; voice = "not-a-voice"; probe_profile = "plan" })
  $outUnk = Join-Path $root "out-unk.json"
  $r = Invoke-UnitPreflight -ManifestPath $badVoiceManifest -RunId $runId -CachePath (Join-Path $root "cache-unk.json") -OutPath $outUnk -Table @{}
  $evUnk = Get-Content -LiteralPath $outUnk -Raw | ConvertFrom-Json
  Assert-True (-not $r.Ready -and $evUnk.status -eq "BLOCKED") "unknown-voice omitted: BLOCKED"

  # --- Cache: warm second run reports cached: C>0 and skips probes ---
  $cacheWarm = Join-Path $root "cache-warm.json"
  $probeCalls = [ref]0
  $countingProbe = {
    param($voice, $profile, $tmp)
    $probeCalls.Value++
    return [pscustomobject]@{
      ExitCode = 0; Output = "PREFLIGHT_OK"; Cli = "mock-cli"; Version = "1.0.0"; WrapperSha256 = "deadbeef"
    }
  }.GetNewClosure()
  $tableWarm = @{ sol = ($meta + @{ Invoke = $countingProbe }) }
  $now = [datetimeoffset]::Parse("2026-08-10T12:00:00Z")
  $r1 = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheWarm -UtcNow $now -Table $tableWarm
  Assert-True ($r1.Ready) "cache-warm: first run READY"
  Assert-True ($probeCalls.Value -eq 1) "cache-warm: first run invoked probe once"
  $r2 = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheWarm -UtcNow $now.AddMinutes(30) -Table $tableWarm
  Assert-True ($r2.Ready -and $r2.Cached -gt 0) "cache-warm: second run cached: C>0"
  Assert-True ($probeCalls.Value -eq 1) "cache-warm: second run skipped probe (still 1 call)"
  Assert-True ($r2.StatusLine -match 'cached: [1-9]') "cache-warm: status line shows cached"

  # --- ForceProbe re-probes ---
  $r3 = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheWarm -UtcNow $now.AddMinutes(40) -Table $tableWarm -ForceProbe
  Assert-True ($r3.Ready -and $probeCalls.Value -eq 2) "ForceProbe: re-probes (call count 2)"
  Assert-True ($r3.Cached -eq 0) "ForceProbe: cached: 0"

  # --- Stale cache beyond TTL (24h default, no lease) ---
  $cacheStale = Join-Path $root "cache-stale.json"
  $staleCalls = [ref]0
  $staleProbe = {
    param($voice, $profile, $tmp)
    $staleCalls.Value++
    return [pscustomobject]@{ ExitCode = 0; Output = "OK"; Cli = "mock-cli"; Version = "1.0.0"; WrapperSha256 = "deadbeef" }
  }.GetNewClosure()
  $tableStale = @{ sol = ($meta + @{ Invoke = $staleProbe }) }
  $t0 = [datetimeoffset]::Parse("2026-08-01T00:00:00Z")
  $null = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheStale -UtcNow $t0 -Table $tableStale
  Assert-True ($staleCalls.Value -eq 1) "stale: seed probe"
  $null = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheStale -UtcNow $t0.AddHours(25) -Table $tableStale
  Assert-True ($staleCalls.Value -eq 2) "stale cache beyond 24h re-probes"

  # --- Live-lease TTL 1h enforced (fixture lease file) ---
  $leaseDir = Join-Path $root "leases"
  New-Item -ItemType Directory -Force -Path $leaseDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $leaseDir "live-run.json"), "{`"run_id`":`"x`"}`n", $utf8)
  $cacheLease = Join-Path $root "cache-lease.json"
  $leaseCalls = [ref]0
  $leaseProbe = {
    param($voice, $profile, $tmp)
    $leaseCalls.Value++
    return [pscustomobject]@{ ExitCode = 0; Output = "OK"; Cli = "mock-cli"; Version = "1.0.0"; WrapperSha256 = "deadbeef" }
  }.GetNewClosure()
  $tableLease = @{ sol = ($meta + @{ Invoke = $leaseProbe }) }
  $tL = [datetimeoffset]::Parse("2026-08-10T10:00:00Z")
  $null = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheLease -LeaseDir $leaseDir -UtcNow $tL -Table $tableLease
  Assert-True ($leaseCalls.Value -eq 1) "lease-ttl: seed"
  $null = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheLease -LeaseDir $leaseDir -UtcNow $tL.AddMinutes(90) -Table $tableLease
  Assert-True ($leaseCalls.Value -eq 2) "lease-ttl 1h: re-probe after 90m with live lease"
  $null = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheLease -LeaseDir $leaseDir -UtcNow $tL.AddMinutes(100) -Table $tableLease
  Assert-True ($leaseCalls.Value -eq 2) "lease-ttl: cache hit within 1h keeps call count"

  # --- Failure never cached ---
  $cacheFail = Join-Path $root "cache-fail.json"
  $failCalls = [ref]0
  $failThenPass = {
    param($voice, $profile, $tmp)
    $failCalls.Value++
    if ($failCalls.Value -eq 1) {
      return [pscustomobject]@{ ExitCode = 1; Output = "login_required OAuth expired"; Cli = "mock-cli"; Version = "1.0.0"; WrapperSha256 = "deadbeef" }
    }
    return [pscustomobject]@{ ExitCode = 0; Output = "OK"; Cli = "mock-cli"; Version = "1.0.0"; WrapperSha256 = "deadbeef" }
  }.GetNewClosure()
  $tableFail = @{ sol = ($meta + @{ Invoke = $failThenPass }) }
  $tF = [datetimeoffset]::Parse("2026-08-10T08:00:00Z")
  $rF1 = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheFail -UtcNow $tF -Table $tableFail
  Assert-True (-not $rF1.Ready) "fail-cache: first run BLOCKED"
  $cacheText = if (Test-Path -LiteralPath $cacheFail) { Get-Content -LiteralPath $cacheFail -Raw } else { "" }
  Assert-True ($cacheText -notmatch '"result"\s*:\s*"pass"') "fail-cache: no success entry after failure"
  $rF2 = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath $cacheFail -UtcNow $tF.AddMinutes(5) -Table $tableFail
  Assert-True ($failCalls.Value -eq 2) "fail-cache: second run re-probes (failure never cached)"
  Assert-True ($rF2.Ready) "fail-cache: second run can pass when probe heals"

  # READY line shape
  $rReady = Invoke-UnitPreflight -ManifestPath $manifestPath -RunId $runId -CachePath (Join-Path $root "cache-shape.json") -Table @{
    sol = ($meta + @{ Invoke = (New-PassInvoke) })
  }
  Assert-True ($rReady.StatusLine -match '^review-preflight: READY \| selected: 1 \| passed: 1 \| cached: \d+ \| failed: 0$') "READY line exact shape"

  # Public script smoke: unknown voice exits nonzero with BLOCKED last line (no injectables).
  $smokeManifest = Join-Path $root "smoke-unknown.json"
  New-Manifest $smokeManifest "smoke-run" ([ordered]@{ lane_id = "v-x"; voice = "not-a-voice"; probe_profile = "plan" })
  $smokeOut = Join-Path $root "smoke-out.txt"
  $smokeErr = Join-Path $root "smoke-err.txt"
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = "powershell.exe"
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -SelectedVoiceManifest `"$smokeManifest`" -RunId smoke-run -Mode text"
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $proc = [Diagnostics.Process]::Start($psi)
  $null = $proc.Handle
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit(60000) | Out-Null
  [IO.File]::WriteAllText($smokeOut, $stdout, $utf8)
  [IO.File]::WriteAllText($smokeErr, $stderr, $utf8)
  Assert-True ($proc.ExitCode -ne 0) "public-script smoke: unknown voice exit nonzero"
  Assert-True ($stdout -match 'review-preflight: BLOCKED') "public-script smoke: BLOCKED last-line class"

  Write-Host "TOTAL $pass passed, $fail failed"
  if ($fail -gt 0) { exit 1 }
  Write-Host "PASS Test-FleetReviewPreflight ($pass checks)"
  exit 0
}
finally {
  $env:FLEET_TEST_HARNESS = $oldHarness
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
