param(
  [Parameter(Mandatory=$true)][string]$CandidatePath,
  [string]$ManifestPath = "$env:USERPROFILE\.codex\fleet\approved-clis.json",
  # Must match Enter-FleetRunLease's window: both sides have to agree on when a run is
  # abandoned, or a lease Enter has already declared dead still blocks promotion here.
  [ValidateRange(1, 24)][int]$StaleHeartbeatHours = 2
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
$wrapper = Join-Path $PSScriptRoot 'Invoke-Opus48.ps1'
$offlineSuite = Join-Path $PSScriptRoot 'Test-Invoke-Opus48.ps1'
$candidate = (Resolve-Path -LiteralPath $CandidatePath -ErrorAction Stop).Path

function Get-CandidateIntegrity([string]$Path, [string]$FallbackVersion) {
  $payload = $Path
  $packageVersion = $FallbackVersion
  $packageRoot = Join-Path (Split-Path -Parent $Path) 'node_modules\@anthropic-ai\claude-code'
  $packageJson = Join-Path $packageRoot 'package.json'
  $packageBinary = Join-Path $packageRoot 'bin\claude.exe'
  if ((Test-Path -LiteralPath $packageJson -PathType Leaf) -and (Test-Path -LiteralPath $packageBinary -PathType Leaf)) {
    $packageVersion = [string](Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json -ErrorAction Stop).version
    $payload = (Resolve-Path -LiteralPath $packageBinary).Path
  }
  return [pscustomobject]@{
    LauncherSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    PayloadPath = $payload
    PayloadSha256 = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
    PackageVersion = $packageVersion
  }
}

$candidateBefore = Get-CandidateIntegrity -Path $candidate -FallbackVersion ''
$mutex = New-Object Threading.Mutex($false, 'FleetClaudePromotion')
$hasMutex = $false
$probeManifest = $null
$temp = $null
$backup = $null

try {
  $hasMutex = $mutex.WaitOne(0)
  if (-not $hasMutex) { throw 'Another Claude promotion is already running.' }

  $leaseRoot = "$env:USERPROFILE\.codex\fleet\run-leases"
  $leaseNow = [datetimeoffset]::Now
  foreach ($file in @(Get-ChildItem -LiteralPath $leaseRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    try { $lease = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid Fleet run lease blocks promotion: $($file.FullName)" }
    # Same predicate Enter-FleetRunLease uses. Testing expires_at alone made an abandoned
    # run (dead owner PID, or a heartbeat past the staleness window) block promotion for
    # the rest of its 24h TTL while every other consumer already treated it as dead.
    if (-not (Test-FleetLeaseReclaimable $lease $leaseNow $StaleHeartbeatHours)) {
      throw "Fleet run $($lease.run_id) is active until $($lease.expires_at); promotion refused."
    }
    Remove-Item -LiteralPath $file.FullName -Force
  }

  # A candidate must be installed side-by-side. Re-proving the exact approved file
  # is allowed; silently replacing bytes at the approved path is not.
  if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
    try { $current = (Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop).clis.claude }
    catch { throw "Existing Claude approval manifest is invalid: $ManifestPath" }
    $currentPath = (Resolve-Path -LiteralPath ([string]$current.path) -ErrorAction SilentlyContinue).Path
    $payloadWasPinned = -not [string]::IsNullOrWhiteSpace([string]$current.payload_sha256)
    if ($currentPath -eq $candidate -and (([string]$current.sha256).ToLowerInvariant() -ne $candidateBefore.LauncherSha256 -or
        ($payloadWasPinned -and ([string]$current.payload_sha256).ToLowerInvariant() -ne $candidateBefore.PayloadSha256))) {
      throw 'Candidate changed bytes at the approved path. Install side-by-side before promotion.'
    }
  }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $offlineSuite
  if ($LASTEXITCODE -ne 0) { throw 'Opus wrapper offline suite failed; approval refused.' }

  $probeManifest = Join-Path ([IO.Path]::GetTempPath()) ('.fleet-claude-probe-' + [guid]::NewGuid().ToString('n') + '.json')
  $probe = [ordered]@{ schema_version='1'; probe_only=$true; clis=[ordered]@{ claude=[ordered]@{ path=$candidate } } }
  [IO.File]::WriteAllText($probeManifest, ($probe | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Reply exactly OPUS_OK' -CandidateManifest $probeManifest -Mode json -TimeoutSeconds 120
  if ($LASTEXITCODE -ne 0) { throw 'Opus live transport probe failed; approval refused.' }
  $live = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
  if ($live.status -ne 'ok' -or $live.response.Trim() -ne 'OPUS_OK' -or 'claude-opus-4-8' -notin @($live.observed_models)) {
    throw 'Opus live transport proof was incomplete; approval refused.'
  }
  if ([string]$live.cli_path -ne $candidate -or [string]$live.cli_version -notmatch '(?<version>\d+\.\d+\.\d+)(?![-A-Za-z0-9])') {
    throw 'Live probe did not use a non-prerelease semantic-version candidate at the requested path.'
  }
  $version = $Matches.version
  $candidateAfter = Get-CandidateIntegrity -Path $candidate -FallbackVersion $version
  if ($candidateAfter.LauncherSha256 -ne $candidateBefore.LauncherSha256 -or $candidateAfter.PayloadSha256 -ne $candidateBefore.PayloadSha256) {
    throw 'Candidate launcher or payload changed during validation; approval refused.'
  }
  if ($candidateAfter.PackageVersion -ne $version) { throw 'Claude package metadata version differs from live CLI version.' }

  $manifest = [ordered]@{
    schema_version = '1'
    clis = [ordered]@{
      claude = [ordered]@{
        path = $candidate
        version = $version
        sha256 = $candidateAfter.LauncherSha256
        payload_path = $candidateAfter.PayloadPath
        payload_sha256 = $candidateAfter.PayloadSha256
        package_version = $candidateAfter.PackageVersion
        approved_at = (Get-Date).ToString('o')
        proof = [ordered]@{
          offline_suite = 'Test-Invoke-Opus48.ps1: passed'
          live_probe = 'claude-opus-4-8: OPUS_OK'
          live_duration_seconds = $live.duration_seconds
        }
      }
    }
  }
  $parent = Split-Path -Parent $ManifestPath
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temp = Join-Path $parent ('.approved-clis-' + [guid]::NewGuid().ToString('n') + '.json')
  [IO.File]::WriteAllText($temp, ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
  if (Test-Path -LiteralPath $ManifestPath) {
    $backup = Join-Path $parent ('.approved-clis-backup-' + [guid]::NewGuid().ToString('n') + '.json')
    [IO.File]::Replace($temp, $ManifestPath, $backup, $true)
  }
  else { [IO.File]::Move($temp, $ManifestPath) }
  $temp = $null
  Write-Output ($manifest | ConvertTo-Json -Compress -Depth 8)
}
finally {
  foreach ($path in @($probeManifest, $temp, $backup)) {
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  }
  if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
  $mutex.Dispose()
}
