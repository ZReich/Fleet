# Fleet PLAN-mode contribution ledger: deterministic per-seat counts of which plan
# items survived merge -> attack -> ratify. Parses `[P-###] [seat,seat] text` lines
# from PLAN-MERGED.md and PLAN-FINAL.md plus `[P-###] cut:` / `[P-###] veto:` lines
# (including parenthetical qualifiers like `cut (partial):`) anywhere in the plan
# dir, plus blanket-lock ranges in PLAN-FINAL.md. No model calls; provenance is
# counted, not judged.
param(
  [Parameter(Mandatory)][string]$PlanDir,
  [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$seats = @('sol', 'grok', 'glm', 'kimi', 'gemini', 'fable')
$itemRx = '(?m)^\s*(?:[-*]\s*)?\[(P-\d+)\]\s*\[([a-z,\s]+)\]'
# cut/veto, optionally with a short parenthetical qualifier: cut (partial):, veto (scope):
$dropRx = '(?m)\[(P-\d+)\]\s*(?:cut|veto)\s*(?:\([^)]{0,40}\))?\s*:'
$lockRx = '(?i)items?\s+P-(\d+)\s+through\s+P-(\d+)\s+remain\s+locked'

function Get-Items([string]$path) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $path)) { return $map }
  foreach ($m in [regex]::Matches([IO.File]::ReadAllText($path), $itemRx)) {
    $tags = @($m.Groups[2].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -in $seats })
    if ($tags.Count) { $map[$m.Groups[1].Value] = $tags }
  }
  return $map
}

function Get-PlanItemNumber([string]$id) {
  $numMatch = [regex]::Match($id, '^P-(\d+)$')
  if ($numMatch.Success) { return [int]$numMatch.Groups[1].Value }
  return -1
}

$merged = Get-Items (Join-Path $PlanDir 'PLAN-MERGED.md')
$finalPath = Join-Path $PlanDir 'PLAN-FINAL.md'
$final = Get-Items $finalPath
if (-not $merged.Count) { throw "No '[P-###] [seats]' items found in $PlanDir/PLAN-MERGED.md" }

# Explicit cut/veto IDs (attack-cuts.md, PLAN-FINAL.md risk register, findings files).
$dropped = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($f in Get-ChildItem -LiteralPath $PlanDir -Filter '*.md' -File) {
  foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f.FullName), $dropRx)) { [void]$dropped.Add($m.Groups[1].Value) }
}

# Blanket-lock ranges from PLAN-FINAL: "items P-001 through P-299 remain locked".
# In-range merged items count as survived unless they appear in the explicit-drop set.
$lockRanges = New-Object Collections.Generic.List[object]
$lockRangeLabels = New-Object Collections.Generic.List[string]
if (Test-Path -LiteralPath $finalPath) {
  foreach ($m in [regex]::Matches([IO.File]::ReadAllText($finalPath), $lockRx)) {
    $a = [int]$m.Groups[1].Value
    $b = [int]$m.Groups[2].Value
    if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
    $lockRanges.Add([pscustomobject]@{ Start = $a; End = $b })
    $lockRangeLabels.Add(('P-{0}..P-{1}' -f $a, $b))
  }
}

function Test-InLockRange([string]$id) {
  $n = Get-PlanItemNumber $id
  if ($n -lt 0) { return $false }
  foreach ($range in $lockRanges) {
    if ($n -ge $range.Start -and $n -le $range.End) { return $true }
  }
  return $false
}

function Test-ItemSurvived([string]$id) {
  # Restated items stay survived (legacy dual-count with explicit drops still applies
  # via Test-ItemDropped). Lock-range items survive only when not explicitly dropped.
  if ($final.ContainsKey($id)) { return $true }
  if ($dropped.Contains($id)) { return $false }
  return (Test-InLockRange $id)
}

function Test-ItemDropped([string]$id) {
  if ($dropped.Contains($id)) { return $true }
  if ($final.ContainsKey($id)) { return $false }
  if (Test-InLockRange $id) { return $false }
  return $true
}

# Attack additions appear only in PLAN-FINAL; count them as merged too for seat credit.
foreach ($id in $final.Keys) { if (-not $merged.ContainsKey($id)) { $merged[$id] = $final[$id] } }

$perSeat = [ordered]@{}
foreach ($s in $seats) {
  $mine = @($merged.Keys | Where-Object { $merged[$_] -contains $s })
  $live = @($mine | Where-Object { Test-ItemSurvived $_ })
  $perSeat[$s] = [ordered]@{
    merged          = $mine.Count
    survived        = $live.Count
    unique_survived = @($live | Where-Object { $merged[$_].Count -eq 1 }).Count
    dropped         = @($mine | Where-Object { Test-ItemDropped $_ }).Count
    survival_rate   = if ($mine.Count) { [math]::Round($live.Count / $mine.Count, 3) } else { $null }
  }
}
$result = [ordered]@{
  plan_dir = (Resolve-Path -LiteralPath $PlanDir).Path
  total_merged = $merged.Count
  total_final = $final.Count
  explicit_drops = $dropped.Count
  lock_ranges = @($lockRangeLabels)
  seats = $perSeat
}
$json = $result | ConvertTo-Json -Depth 5
if (-not $OutputPath) { $OutputPath = Join-Path $PlanDir 'contribution.json' }
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output $json
