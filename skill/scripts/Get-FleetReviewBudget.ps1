# Builds the exact no-tool review transport and selects an Opus/GLM provider budget.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$PromptFile,

  [Parameter(Mandatory = $true)]
  [string[]]$ArtifactFile,

  [string]$PacketManifest,

  [Parameter(Mandatory = $true)]
  [ValidateSet("mechanical", "behavior", "hard")]
  [string]$ReviewRisk,

  # The Opus seat's wall time is model-dependent: Opus 5 measured ~2-3x Opus 4.8 on an
  # identical frozen packet, and the contract tells supervisors to budget for it. Until
  # this parameter existed the selector handed both models the SAME timeout, so the
  # documented mandate was unimplemented and a large packet could no_contest spuriously.
  # Default is the counted seat (Opus 5, 2026-07-26). Defaulting to 4.8 budgeted 600s
  # for a lane that needs 1500s whenever a caller omitted the flag - a silent no_contest.
  [ValidateSet("claude-opus-4-8", "claude-opus-5")]
  [string]$OpusModel = "claude-opus-5",

  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-TierRank {
  param([string]$Tier)
  switch ($Tier) {
    "tiny" { return 0 }
    "standard" { return 1 }
    "hard" { return 2 }
    default { throw "Unknown review tier: $Tier" }
  }
}

function Get-RiskTier {
  param([string]$Risk)
  switch ($Risk) {
    "mechanical" { return "tiny" }
    "behavior" { return "standard" }
    "hard" { return "hard" }
    default { throw "Unknown review risk: $Risk" }
  }
}

if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
  throw "PromptFile not found: $PromptFile"
}

$resolvedPrompt = (Resolve-Path -LiteralPath $PromptFile).Path
$promptText = [IO.File]::ReadAllText($resolvedPrompt)
if ([string]::IsNullOrWhiteSpace($promptText)) { throw "PromptFile is empty: $resolvedPrompt" }

# Match Invoke-Opus48.ps1 and Invoke-PiGlm.ps1 exactly: each listed artifact is
# appended to the prompt with its resolved path and canonical framing.
$artifactPaths = @($ArtifactFile | ForEach-Object { $_ -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($artifactPaths.Count -eq 0) { throw "At least one ArtifactFile is required." }
$packetAttestation = $null
if (-not [string]::IsNullOrWhiteSpace($PacketManifest)) {
  $packetValidator = Join-Path $PSScriptRoot "Assert-FleetReviewPacketManifest.ps1"
  $packetAttestation = (& $packetValidator -ManifestPath $PacketManifest -ArtifactFile $artifactPaths | ConvertFrom-Json)
}

$artifacts = @()
foreach ($artifactPath in $artifactPaths) {
  if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "ArtifactFile not found: $artifactPath"
  }
  $resolvedArtifact = (Resolve-Path -LiteralPath $artifactPath).Path
  $artifactText = [IO.File]::ReadAllText($resolvedArtifact)
  $promptText += "`n`n===== FROZEN ARTIFACT: $resolvedArtifact =====`n$artifactText"
  $artifactBytes = $utf8.GetBytes($artifactText)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    $artifactHash = ([BitConverter]::ToString($hasher.ComputeHash($artifactBytes))).Replace("-", "").ToLowerInvariant()
  }
  finally { $hasher.Dispose() }
  $artifacts += [ordered]@{ path = $resolvedArtifact; bytes = $artifactBytes.Length; sha256 = $artifactHash }
}
if ($packetAttestation) {
  $expectedArtifacts = @($packetAttestation.artifacts)
  if ($expectedArtifacts.Count -ne $artifacts.Count) { throw "Frozen review packet changed during budget serialization: artifact count" }
  for ($index = 0; $index -lt $artifacts.Count; $index++) {
    if ([int64]$expectedArtifacts[$index].bytes -ne [int64]$artifacts[$index].bytes -or $expectedArtifacts[$index].sha256 -ne $artifacts[$index].sha256) {
      throw "Frozen review packet changed during budget serialization: artifact index $index"
    }
  }
}

$transportBytes = $utf8.GetBytes($promptText)
$transportHasher = [Security.Cryptography.SHA256]::Create()
try {
  $transportHash = ([BitConverter]::ToString($transportHasher.ComputeHash($transportBytes))).Replace("-", "").ToLowerInvariant()
}
finally { $transportHasher.Dispose() }

$byteTier = if ($transportBytes.Length -le (50 * 1024)) { "tiny" } elseif ($transportBytes.Length -le (250 * 1024)) { "standard" } else { "hard" }
$riskTier = Get-RiskTier $ReviewRisk
$selectedTier = if ((Get-TierRank $riskTier) -gt (Get-TierRank $byteTier)) { $riskTier } else { $byteTier }

# codex = the Sol/Terra review seats via Invoke-Sol.ps1 -TimeoutSeconds. They previously
# got a flat caller-chosen budget; 2026-08-03 r9 killed a mid-work Sol review at 900s on
# a hard-tier (94KB) packet. Scale them by the same tier as the other seats.
$budgets = @{
  tiny = @{ opus = 120; glm = 180; codex = 300 }
  standard = @{ opus = 300; glm = 600; codex = 900 }
  hard = @{ opus = 600; glm = 900; codex = 1800 }
}
$promotionReason = if ($selectedTier -ne $byteTier) {
  "review_risk=$ReviewRisk promoted byte_tier=$byteTier to $selectedTier"
}
else {
  "transport_bytes=$($transportBytes.Length) selected byte_tier=$byteTier"
}

# Opus 5 runs measurably slower on the same packet; scale its provider budget rather than
# letting the seat time out. Wrapper hard-caps at 3600s.
$opusMultiplier = if ($OpusModel -eq 'claude-opus-5') { 2.5 } else { 1 }
$opusTimeout = [int][math]::Min(3600, [math]::Ceiling($budgets[$selectedTier].opus * $opusMultiplier))

$result = [ordered]@{
  schema_version = "1"
  prompt_path = $resolvedPrompt
  packet_manifest_sha256 = if ($packetAttestation) { [string]$packetAttestation.packet_sha256 } else { $null }
  artifact_paths = @($artifacts | ForEach-Object { $_.path })
  artifacts = $artifacts
  transport_bytes = $transportBytes.Length
  transport_sha256 = $transportHash
  byte_tier = $byteTier
  review_risk = $ReviewRisk
  risk_tier = $riskTier
  selected_tier = $selectedTier
  selection_reason = $promotionReason
  opus_model = $OpusModel
  opus_timeout_multiplier = $opusMultiplier
  opus_timeout_seconds = $opusTimeout
  glm_timeout_seconds = $budgets[$selectedTier].glm
  codex_timeout_seconds = $budgets[$selectedTier].codex
}

$json = $result | ConvertTo-Json -Depth 6 -Compress
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
  $parent = Split-Path -Parent $resolvedOutput
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($resolvedOutput, $json + [Environment]::NewLine, $utf8)
}

Write-Output $json
