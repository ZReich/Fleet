# Offline tests for deterministic Fleet Opus/GLM review-budget selection.
$ErrorActionPreference = "Stop"
$selector = Join-Path $PSScriptRoot "Get-FleetReviewBudget.ps1"
if (-not (Test-Path -LiteralPath $selector)) { throw "Selector missing: $selector" }

$temp = Join-Path ([IO.Path]::GetTempPath()) ("fleet-review-budget-" + [guid]::NewGuid().ToString("n"))
$utf8 = [Text.UTF8Encoding]::new($false)
$pass = 0
function Assert-True {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) { throw "FAIL: $Name" }
  $script:pass++
  Write-Host "PASS: $Name"
}

function Get-Budget {
  param([string]$PromptFile, [string[]]$ArtifactFile, [string]$ReviewRisk, [string]$OutputPath, [string]$OpusModel)
  # Omitting -OpusModel exercises the DEFAULT, which is the point of the seat cases below.
  $raw = if ($OpusModel) {
    & $selector -PromptFile $PromptFile -ArtifactFile $ArtifactFile -ReviewRisk $ReviewRisk -OutputPath $OutputPath -OpusModel $OpusModel
  } else {
    & $selector -PromptFile $PromptFile -ArtifactFile $ArtifactFile -ReviewRisk $ReviewRisk -OutputPath $OutputPath
  }
  return ($raw | ConvertFrom-Json)
}

function Set-ArtifactForTransportBytes {
  param([string]$PromptFile, [string]$ArtifactFile, [int]$TargetBytes)
  $resolvedArtifact = [IO.Path]::GetFullPath($ArtifactFile)
  $prefix = [IO.File]::ReadAllText($PromptFile, $utf8) + "`n`n===== FROZEN ARTIFACT: $resolvedArtifact =====`n"
  $prefixBytes = $utf8.GetBytes($prefix).Length
  if ($TargetBytes -lt $prefixBytes) { throw "Target transport bytes too small: $TargetBytes < $prefixBytes" }
  [IO.File]::WriteAllText($ArtifactFile, ("x" * ($TargetBytes - $prefixBytes)), $utf8)
}

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  $prompt = Join-Path $temp "review prompt.txt"
  $artifact = Join-Path $temp "frozen diff.txt"
  [IO.File]::WriteAllText($prompt, "Review the frozen change.", $utf8)
  [IO.File]::WriteAllText($artifact, "FROZEN_ARTIFACT_TOKEN", $utf8)

  $tiny = Get-Budget -PromptFile $prompt -ArtifactFile @($artifact) -ReviewRisk mechanical -OutputPath (Join-Path $temp "tiny.json")
  # Opus timeouts below are base-tier x the COUNTED seat's 2.5 multiplier (Opus 5 measured
  # ~2-3x Opus 4.8 on an identical packet). GLM budgets are model-independent.
  Assert-True ($tiny.selected_tier -eq "tiny" -and $tiny.opus_timeout_seconds -eq 300 -and $tiny.glm_timeout_seconds -eq 180) "tiny mechanical transport keeps fast budgets"
  Assert-True ($tiny.transport_bytes -gt 0 -and $tiny.transport_sha256.Length -eq 64 -and $tiny.artifacts.Count -eq 1) "selector records exact transport evidence"
  $persistedTiny = [IO.File]::ReadAllText((Join-Path $temp "tiny.json"), $utf8) | ConvertFrom-Json
  Assert-True ((Test-Path -LiteralPath (Join-Path $temp "tiny.json")) -and ($persistedTiny.transport_bytes -eq $tiny.transport_bytes)) "selector persists machine-readable output"

  $behavior = Get-Budget -PromptFile $prompt -ArtifactFile @($artifact) -ReviewRisk behavior -OutputPath (Join-Path $temp "behavior.json")
  Assert-True ($behavior.selected_tier -eq "standard" -and $behavior.opus_timeout_seconds -eq 750 -and $behavior.glm_timeout_seconds -eq 600) "behavior risk promotes small transport to standard"

  $hard = Get-Budget -PromptFile $prompt -ArtifactFile @($artifact) -ReviewRisk hard -OutputPath (Join-Path $temp "hard.json")
  Assert-True ($hard.selected_tier -eq "hard" -and $hard.opus_timeout_seconds -eq 1500 -and $hard.glm_timeout_seconds -eq 900) "hard risk promotes small transport to hard"

  # SEAT DEFAULT (2026-07-31). The selector defaulted to the retired claude-opus-4-8 for
  # months after Opus 5 became the counted seat, so every caller that omitted the flag
  # budgeted 600s for a lane needing 1500s and the seat no_contest'd on large packets.
  Assert-True ($hard.opus_model -eq "claude-opus-5" -and $hard.opus_timeout_multiplier -eq 2.5) "omitted -OpusModel budgets the counted seat, not the retired one"

  $fallbackTiny = Get-Budget -PromptFile $prompt -ArtifactFile @($artifact) -ReviewRisk mechanical -OutputPath (Join-Path $temp "fallback-tiny.json") -OpusModel "claude-opus-4-8"
  $fallbackHard = Get-Budget -PromptFile $prompt -ArtifactFile @($artifact) -ReviewRisk hard -OutputPath (Join-Path $temp "fallback-hard.json") -OpusModel "claude-opus-4-8"
  Assert-True ($fallbackTiny.opus_timeout_seconds -eq 120 -and $fallbackHard.opus_timeout_seconds -eq 600 -and $fallbackHard.opus_timeout_multiplier -eq 1) "explicit 4.8 fallback keeps its own unmultiplied budget"
  Assert-True ($fallbackHard.glm_timeout_seconds -eq $hard.glm_timeout_seconds) "GLM budget does not move with the Opus seat"

  $largeArtifact = Join-Path $temp "large frozen diff.txt"
  [IO.File]::WriteAllText($largeArtifact, ("x" * (60 * 1024)), $utf8)
  $standard = Get-Budget -PromptFile $prompt -ArtifactFile @($largeArtifact) -ReviewRisk mechanical -OutputPath (Join-Path $temp "standard.json")
  Assert-True ($standard.byte_tier -eq "standard" -and $standard.selected_tier -eq "standard" -and $standard.opus_timeout_seconds -eq 750 -and $standard.glm_timeout_seconds -eq 600) "large transport selects standard without risk promotion"

  $tinyBoundaryArtifact = Join-Path $temp "tiny boundary.txt"
  Set-ArtifactForTransportBytes -PromptFile $prompt -ArtifactFile $tinyBoundaryArtifact -TargetBytes (50 * 1024)
  $tinyBoundary = Get-Budget -PromptFile $prompt -ArtifactFile @($tinyBoundaryArtifact) -ReviewRisk mechanical -OutputPath (Join-Path $temp "tiny-boundary.json")
  Assert-True ($tinyBoundary.transport_bytes -eq (50 * 1024) -and $tinyBoundary.selected_tier -eq "tiny") "exact 50 KiB transport remains tiny"

  $standardBoundaryArtifact = Join-Path $temp "standard boundary.txt"
  Set-ArtifactForTransportBytes -PromptFile $prompt -ArtifactFile $standardBoundaryArtifact -TargetBytes (250 * 1024)
  $standardBoundary = Get-Budget -PromptFile $prompt -ArtifactFile @($standardBoundaryArtifact) -ReviewRisk mechanical -OutputPath (Join-Path $temp "standard-boundary.json")
  Assert-True ($standardBoundary.transport_bytes -eq (250 * 1024) -and $standardBoundary.selected_tier -eq "standard") "exact 250 KiB transport remains standard"

  $hardBoundaryArtifact = Join-Path $temp "hard boundary.txt"
  Set-ArtifactForTransportBytes -PromptFile $prompt -ArtifactFile $hardBoundaryArtifact -TargetBytes ((250 * 1024) + 1)
  $hardBoundary = Get-Budget -PromptFile $prompt -ArtifactFile @($hardBoundaryArtifact) -ReviewRisk mechanical -OutputPath (Join-Path $temp "hard-boundary.json")
  Assert-True ($hardBoundary.transport_bytes -eq ((250 * 1024) + 1) -and $hardBoundary.selected_tier -eq "hard") "first byte above 250 KiB selects hard"

  $firstArtifact = Join-Path $temp "first artifact.txt"
  $secondArtifact = Join-Path $temp "second artifact.txt"
  [IO.File]::WriteAllText($firstArtifact, "FIRST_ARTIFACT", $utf8)
  [IO.File]::WriteAllText($secondArtifact, "SECOND_ARTIFACT", $utf8)
  $multi = Get-Budget -PromptFile $prompt -ArtifactFile @($firstArtifact, $secondArtifact) -ReviewRisk mechanical -OutputPath (Join-Path $temp "multi.json")
  $expectedMulti = [IO.File]::ReadAllText($prompt, $utf8) + "`n`n===== FROZEN ARTIFACT: $((Resolve-Path -LiteralPath $firstArtifact).Path) =====`nFIRST_ARTIFACT" + "`n`n===== FROZEN ARTIFACT: $((Resolve-Path -LiteralPath $secondArtifact).Path) =====`nSECOND_ARTIFACT"
  Assert-True ($multi.artifact_paths[0] -eq (Resolve-Path -LiteralPath $firstArtifact).Path -and $multi.artifact_paths[1] -eq (Resolve-Path -LiteralPath $secondArtifact).Path -and $multi.transport_bytes -eq $utf8.GetBytes($expectedMulti).Length) "selector preserves multi-artifact order and serialization"

  $fullTransport = [IO.File]::ReadAllText($prompt, $utf8) + "`n`n===== FROZEN ARTIFACT: $((Resolve-Path -LiteralPath $artifact).Path) =====`n" + [IO.File]::ReadAllText($artifact, $utf8)
  $expectedBytes = $utf8.GetBytes($fullTransport).Length
  Assert-True ($tiny.transport_bytes -eq $expectedBytes) "selector matches wrapper artifact serialization"

  Write-Host "TOTAL: $pass passed, 0 failed"
}
finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
