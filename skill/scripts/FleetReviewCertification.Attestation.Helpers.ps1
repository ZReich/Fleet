# Complete-authority attestation helpers for Assert-FleetReviewCertification.ps1.
# Uses the caller's Get-FileSha256Hex plus its script-scoped attestation maps.

function Get-FleetCertificationCommitSha([string]$RepoPath, [string]$Ref) {
  if ([string]::IsNullOrWhiteSpace($RepoPath) -or [string]::IsNullOrWhiteSpace($Ref)) { return $null }
  $oldEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $raw = & git -C $RepoPath rev-parse --verify ($Ref + '^{commit}') 2>$null
    $code = $LASTEXITCODE
  }
  catch { return $null }
  finally { $ErrorActionPreference = $oldEap }
  $sha = (($raw | ForEach-Object { "$_" }) -join '').Trim().ToLowerInvariant()
  if ($code -ne 0 -or $sha -notmatch '^[0-9a-f]{40}$') { return $null }
  return $sha
}

function Register-FleetFrozenTouchedAttestations([string]$RepoPath, $Entries) {
  $backslash = [string][char]92
  $root = [IO.Path]::GetFullPath($RepoPath).TrimEnd($backslash)
  $index = 0
  foreach ($entry in @($Entries)) {
    $relative = ([string]$entry.path).Replace('/', $backslash).TrimStart($backslash)
    $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
    $key = 'frozen_touched:' + $index
    $script:AttestPath[$key] = $full
    $script:AttestSha[$key] = if (Test-Path -LiteralPath $full -PathType Leaf) { Get-FileSha256Hex $full } else { 'absent' }
    $script:ArtifactHashes[$key] = $script:AttestSha[$key]
    $index++
  }
  return $true
}

function Register-FleetCommitAttestation([string]$Key, [string]$RepoPath, [string]$Ref) {
  $sha = Get-FleetCertificationCommitSha $RepoPath $Ref
  if ($null -eq $sha) { return $false }
  $script:AttestPath[$Key] = $RepoPath
  $script:AttestSha[$Key] = $sha
  $script:ArtifactHashes[$Key] = $sha
  return $true
}

function Get-FleetCertificationAttestHashNow([string]$Key, [string]$Path) {
  if ($Key.StartsWith('frozen_touched:')) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileSha256Hex $Path) }
    return 'absent'
  }
  if ($Key.StartsWith('git_commit:')) {
    return (Get-FleetCertificationCommitSha $Path ($Key.Substring('git_commit:'.Length)))
  }
  return $null
}

# Packet-manifest verification (moved from Assert-FleetReviewCertification.ps1 at the size
# split; consumes $script:... state of the certification script that dot-sources this file).
function Test-PacketManifest([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return @{ Ok = $false; Sha = '' }
  }
  try {
    $obj = [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json -ErrorAction Stop
  }
  catch { return @{ Ok = $false; Sha = '' } }
  $sha = ''; if ($obj.PSObject.Properties['packet_sha256']) { $sha = ([string]$obj.packet_sha256).ToLowerInvariant() }
  if ($sha -notmatch '^[0-9a-f]{64}$') { return @{ Ok = $false; Sha = '' } }
  $sv = ''; if ($obj.PSObject.Properties['schema_version']) { $sv = [string]$obj.schema_version }
  if ($sv -cne '1') { return @{ Ok = $false; Sha = $sha } }
  $artifacts = @($obj.artifacts)
  if ($artifacts.Count -eq 0) { return @{ Ok = $false; Sha = $sha } }
  $preflight = @($artifacts | Where-Object { [string]$_.name -ceq 'review-preflight.json' })
  if ($preflight.Count -ne 1 -or ([string]$preflight[0].sha256).ToLowerInvariant() -notmatch '^[0-9a-f]{64}$') { return @{ Ok = $false; Sha = $sha } }
  foreach ($artifact in $artifacts) {
    if ([string]::IsNullOrWhiteSpace([string]$artifact.name) -or [string]::IsNullOrWhiteSpace([string]$artifact.path)) { return @{ Ok = $false; Sha = $sha } }
    if (([string]$artifact.sha256).ToLowerInvariant() -notmatch '^[0-9a-f]{64}$') { return @{ Ok = $false; Sha = $sha } }
    try { if ([int64]$artifact.bytes -lt 0) { return @{ Ok = $false; Sha = $sha } } } catch { return @{ Ok = $false; Sha = $sha } }
  }
  $frozen = @($obj.frozen_touched_files)
  if ($frozen.Count -eq 0) { return @{ Ok = $false; Sha = $sha } }
  foreach ($entry in $frozen) {
    $pathValue = [string]$entry.path
    if ([string]::IsNullOrWhiteSpace($pathValue) -or $pathValue -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($pathValue)) { return @{ Ok = $false; Sha = $sha } }
    $exists = $false; try { $exists = [bool]$entry.exists } catch { return @{ Ok = $false; Sha = $sha } }
    if ($exists -and ([string]$entry.sha256).ToLowerInvariant() -notmatch '^[0-9a-f]{64}$') { return @{ Ok = $false; Sha = $sha } }
    if (-not $exists -and -not [string]::IsNullOrEmpty([string]$entry.sha256)) { return @{ Ok = $false; Sha = $sha } }
  }
  $risk = [string]$obj.review_risk
  if ($risk -notin @('mechanical', 'behavior', 'hard')) { return @{ Ok = $false; Sha = $sha } }
  $material = "review_risk|$risk`n" + (($artifacts | ForEach-Object { "$($_.name)|$($_.bytes)|$($_.sha256)" }) -join "`n") + "`nfrozen_touched_files`n" + (($frozen | ForEach-Object { "$($_.path)|$($_.exists)|$($_.sha256)" }) -join "`n")
  $hasher = [Security.Cryptography.SHA256]::Create()
  try { $recomputed = -join ($hasher.ComputeHash($utf8.GetBytes($material)) | ForEach-Object { $_.ToString('x2') }) }
  finally { $hasher.Dispose() }
  if ($sha -cne $recomputed) { return @{ Ok = $false; Sha = '' } }
  return @{ Ok = $true; Sha = $sha; PreflightSha = ([string]$preflight[0].sha256).ToLowerInvariant(); Artifacts = $artifacts; FrozenTouchedFiles = $frozen; ReviewRisk = $risk }
}

function Get-TransportArtifactAttestation([string]$Path) {
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $bytes = $utf8.GetBytes([IO.File]::ReadAllText($Path, $utf8))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return @{ Bytes = [int64]$bytes.Length; Sha = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } }
    finally { $sha.Dispose() }
  }
  catch { return $null }
}
