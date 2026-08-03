[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ManifestPath,
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ArtifactFile
)

$ErrorActionPreference = "Stop"

function Assert-EqualString([string]$Actual, [string]$Expected, [string]$Label) {
  if (-not [string]::Equals($Actual, $Expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Frozen review packet manifest mismatch: $Label"
  }
}

$resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
if ([IO.Path]::GetFileName($resolvedManifestPath) -ne "packet-manifest.json") {
  throw "Frozen review packet manifest must be named packet-manifest.json"
}

try {
  $manifest = [IO.File]::ReadAllText($resolvedManifestPath) | ConvertFrom-Json -ErrorAction Stop
}
catch {
  throw "Frozen review packet manifest is invalid JSON: $resolvedManifestPath"
}

$packetDirectory = Split-Path -Parent $resolvedManifestPath
$packetBuilder = Join-Path $PSScriptRoot "Get-FleetReviewPacket.ps1"
# D4: rebuild honors manifest review_risk; omitted risk in older manifests means mechanical.
# Pre-D4 manifests (no review_risk field) used legacy packet_sha256 without the review_risk| prefix.
$hasReviewRiskField = $manifest.PSObject.Properties.Name -contains "review_risk"
$manifestRisk = "mechanical"
if ($hasReviewRiskField -and -not [string]::IsNullOrWhiteSpace([string]$manifest.review_risk)) {
  $manifestRisk = [string]$manifest.review_risk
}
if ($manifestRisk -notin @("mechanical", "behavior", "hard")) {
  throw "Frozen review packet manifest has unsupported review_risk"
}
$current = (& $packetBuilder -PacketDir $packetDirectory -ReviewRisk $manifestRisk | ConvertFrom-Json)
if (-not $hasReviewRiskField) {
  $utf8Legacy = [Text.UTF8Encoding]::new($false)
  $legacyMaterial = (($current.artifacts | ForEach-Object { "$($_.name)|$($_.bytes)|$($_.sha256)" }) -join "`n")
  $shaLegacy = [Security.Cryptography.SHA256]::Create()
  try {
    $current.packet_sha256 = -join ($shaLegacy.ComputeHash($utf8Legacy.GetBytes($legacyMaterial)) | ForEach-Object { $_.ToString("x2") })
  }
  finally {
    $shaLegacy.Dispose()
  }
}

if ($manifest.schema_version -ne "1") { throw "Frozen review packet manifest has unsupported schema_version" }
Assert-EqualString ([string]$manifest.packet_dir) ([string]$current.packet_dir) "packet directory"
Assert-EqualString ([string]$current.review_risk) $manifestRisk "review risk"
Assert-EqualString ([string]$manifest.packet_sha256) ([string]$current.packet_sha256) "packet hash"

$providedPaths = @($ArtifactFile | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
$manifestPaths = @($manifest.artifact_paths)
$currentPaths = @($current.artifact_paths)
if ($providedPaths.Count -ne $currentPaths.Count -or $manifestPaths.Count -ne $currentPaths.Count) {
  throw "Frozen review packet manifest mismatch: artifact count"
}

$manifestArtifacts = @($manifest.artifacts)
$currentArtifacts = @($current.artifacts)
if ($manifestArtifacts.Count -ne $currentArtifacts.Count) {
  throw "Frozen review packet manifest mismatch: artifact evidence count"
}

for ($index = 0; $index -lt $currentPaths.Count; $index++) {
  Assert-EqualString ([string]$providedPaths[$index]) ([string]$currentPaths[$index]) "artifact path at index $index"
  Assert-EqualString ([string]$manifestPaths[$index]) ([string]$currentPaths[$index]) "manifest artifact path at index $index"
  Assert-EqualString ([string]$manifestArtifacts[$index].name) ([string]$currentArtifacts[$index].name) "artifact name at index $index"
  Assert-EqualString ([string]$manifestArtifacts[$index].path) ([string]$currentArtifacts[$index].path) "artifact evidence path at index $index"
  if ([int64]$manifestArtifacts[$index].bytes -ne [int64]$currentArtifacts[$index].bytes) {
    throw "Frozen review packet manifest mismatch: artifact bytes at index $index"
  }
  Assert-EqualString ([string]$manifestArtifacts[$index].sha256) ([string]$currentArtifacts[$index].sha256) "artifact hash at index $index"
}

([ordered]@{
  status = "ok"
  manifest_path = $resolvedManifestPath
  packet_sha256 = [string]$current.packet_sha256
  artifact_paths = @($currentPaths)
  artifacts = @($currentArtifacts)
} | ConvertTo-Json -Depth 5 -Compress)
