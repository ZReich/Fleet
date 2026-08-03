# Contract-consistency checks (Fable plan item 10 / L3). Fails closed on drift so the
# two SKILL files, references, and policy stay coherent. Pure ASCII: mojibake bytes are
# referenced by code point, never as literals.
$ErrorActionPreference = 'Stop'
$codexRoot = Split-Path -Parent $PSScriptRoot
$claudeSkill = Join-Path $env:USERPROFILE '.claude\skills\fleet\SKILL.md'
$passed = 0; $failed = 0
function Case([string]$n, [scriptblock]$b) { try { & $b; $script:passed++; Write-Host "PASS $n" } catch { $script:failed++; Write-Host "FAIL $n - $($_.Exception.Message)" } }
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }

$contractFiles = @(
  (Join-Path $codexRoot 'SKILL.md'),
  (Join-Path $codexRoot 'references\mode-selection.md'),
  (Join-Path $codexRoot 'references\review-protocol.md'),
  (Join-Path $codexRoot 'references\benchmark-schema.md'),
  (Join-Path $codexRoot 'references\kimi-k3.md'),
  (Join-Path $codexRoot 'references\auto-shadow.md'),
  $claudeSkill
)

Case 'fleet-policy.json parses and has required blocks' {
  $p = Get-Content -LiteralPath (Join-Path $codexRoot 'fleet-policy.json') -Raw | ConvertFrom-Json
  Assert-True ($null -ne $p.review_tiers.MICRO -and $p.full_panel_voices.Count -eq 5 -and $p.auto_shadow.critical_path_delay_seconds -eq 0) 'policy missing required blocks'
  Assert-True ([bool]$p.auto_shadow.stratified_boost.enabled -eq $true) 'auto_shadow.stratified_boost.enabled must be true'
  Assert-True ([int]$p.auto_shadow.canary_set.repeat_count -eq 3) 'auto_shadow.canary_set.repeat_count must be 3'
}

Case 'no mojibake / replacement chars in contract files' {
  $repl = [char]0xFFFD; $c2 = [char]0x00C2; $c3 = [char]0x00C3
  $bad = @()
  foreach ($f in $contractFiles) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $text = [IO.File]::ReadAllText($f)
    if ($text.Contains($repl) -or $text.Contains($c2) -or $text.Contains($c3)) { $bad += $f }
  }
  Assert-True ($bad.Count -eq 0) ("mojibake in: " + ($bad -join ', '))
}

Case 'all references/*.md links in Codex SKILL.md resolve' {
  $skill = [IO.File]::ReadAllText((Join-Path $codexRoot 'SKILL.md'))
  $missing = @()
  foreach ($m in [regex]::Matches($skill, 'references/([A-Za-z0-9._-]+\.md)')) {
    $rel = $m.Groups[1].Value
    if (-not (Test-Path -LiteralPath (Join-Path $codexRoot ('references\' + $rel)))) { $missing += $rel }
  }
  Assert-True ($missing.Count -eq 0) ("unresolved reference links: " + (($missing | Select-Object -Unique) -join ', '))
}

Case 'benchmark schema example uses effective effort high, not max' {
  $bs = [IO.File]::ReadAllText((Join-Path $codexRoot 'references\benchmark-schema.md'))
  Assert-True ($bs -match '"grok_review_effort":\s*"high"' -and $bs -notmatch '"grok_review_effort":\s*"max"') 'schema example still shows max'
}

Case 'Claude adapter stays a thin surface map' {
  Assert-True (Test-Path -LiteralPath $claudeSkill) 'adapter missing'
  $lines = @(Get-Content -LiteralPath $claudeSkill).Count
  $text = [IO.File]::ReadAllText($claudeSkill)
  Assert-True ($lines -lt 220 -and $text -match 'Codex Fleet is the single source of truth') 'adapter drifted from thin surface map'
}

Case 'ArtifactFile is comma-joined at -File call sites' {
  foreach ($f in @((Join-Path $codexRoot 'SKILL.md'), $claudeSkill)) {
    $text = [IO.File]::ReadAllText($f)
    foreach ($m in [regex]::Matches($text, '-File[^\n]*Invoke-(Opus48|PiGlm)\.ps1[^\n]*-ArtifactFile\s+(\S+)')) {
      Assert-True ($m.Groups[2].Value -notmatch '^\$reviewArtifacts$') "raw-array ArtifactFile at a -File call site in $f"
    }
  }
}

Case "A9 arbitration cap wording is locked in review-protocol" {
  $rp = [IO.File]::ReadAllText((Join-Path $codexRoot 'references\review-protocol.md'))
  Assert-True ($rp -match 'Maximum three Sol arbitration rounds per wave') 'missing three-round cap'
  Assert-True ($rp -match 'Initial arbitration is round 1') 'missing round 1 definition'
  Assert-True ($rp -match 'Assert-FleetRepairCoverage\.ps1') 'missing coverage pre-check script'
  Assert-True ($rp -match 'Before dispatching rounds 2 or 3') 'missing coverage pre-check timing'
  Assert-True ($rp -match 'round-3 repair charter contains only unresolved blocker IDs') 'missing residual-only round-3 charter'
  Assert-True ($rp -match 'No fourth repair/arbitration round is allowed') 'missing freeze after round-3'
  Assert-True ($rp -match 'new Sol-locked plan and new wave') 'missing re-plan resume path'
  Assert-True ($rp -match 'new wave resets the counter') 'missing counter reset'
}

Case "SKILL.md scopes worker JSON to implementation and shows review text capture" {
  $skill = [IO.File]::ReadAllText((Join-Path $codexRoot 'SKILL.md'))
  Assert-True ($skill -match 'needs_gate_validation') 'missing needs_gate_validation docs'
  Assert-True ($skill -match 'implementation lanes only' -or $skill -match 'IMPLEMENTATION lanes only') 'missing implementation-only worker JSON scope'
  Assert-True ($skill -match '-Review -TimeoutSeconds 900 -Mode text' -or $skill -match '-Review -Mode text') 'review capture must show -Mode text'
  Assert-True ($skill -match 'wraps markdown') 'must document Mode json wraps markdown for probes'
  Assert-True ($skill -match 'manager gate' -or $skill -match 'manager-owned') 'must document manager gates for needs_gate_validation'
  Assert-True ($skill -match 'Record-FleetLaneSpan\.ps1') 'SKILL.md must name Record-FleetLaneSpan.ps1'
  Assert-True ($skill -match 'Assert-FleetLaneSpans\.ps1') 'SKILL.md must name Assert-FleetLaneSpans.ps1'
  Assert-True ($skill -match 'lane-spans: <run> \| expected: N \| valid: V \| missing: M \| duplicate: D \|') 'SKILL.md must quote lane-spans summary shape'
  # Wave docs: real script/param names (T4 lane-fit + live shadow); strengthen, no new case.
  Assert-True ($skill -match 'Get-FleetLaneFit\.ps1' -and $skill -match '-SpansPath' -and $skill -match '-GenrePath' -and $skill -match '-ShadowPath' -and $skill -match '-OutputPath') 'SKILL lane-fit script+params'
  Assert-True ($skill -match 'Invoke-ShadowReplay\.ps1' -and $skill -match '-EntryPath' -and $skill -match '-LaneSpecPath') 'SKILL shadow-replay EntryPath/LaneSpecPath'
  Assert-True ($skill -match '-TaskSpecJson' -and $skill -match 'deferred_no_spec' -and $skill -match 'deterministic_partial' -and $skill -match 'max 90') 'SKILL enqueue snapshot + rubric max 90'
  Assert-True ($skill -match 'lane_a' -and $skill -match 'lane_b' -and $skill -match 'wrapper_pair') 'SKILL task-file v2 lane_a/lane_b'
  $fit = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Get-FleetLaneFit.ps1'))
  Assert-True ($fit -match '\$SpansPath' -and $fit -match '\$GenrePath' -and $fit -match '\$ShadowPath' -and $fit -match '\$OutputPath') 'Get-FleetLaneFit.ps1 four params'
  $rep = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Invoke-ShadowReplay.ps1'))
  Assert-True ($rep -match '\$EntryPath' -and $rep -match '\$LaneSpecPath' -and $rep -match 'deterministic_partial' -and $rep -match 'max_score = 90') 'Invoke-ShadowReplay EntryPath/LaneSpecPath/max 90'
  $enq = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Enqueue-FleetShadow.ps1'))
  Assert-True ($enq -match '\$TaskSpecJson') 'Enqueue-FleetShadow TaskSpecJson param'
  $cmp = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Run-TerraGrokComparison.ps1'))
  Assert-True ($cmp -match 'lane_a' -and $cmp -match 'lane_b') 'Run-TerraGrokComparison lane_a/lane_b'
  $as = [IO.File]::ReadAllText((Join-Path $codexRoot 'references\auto-shadow.md'))
  Assert-True ($as -match 'deterministic_partial' -and $as -match 'max 90') 'auto-shadow.md rubric max 90'
}

Case "SKILL.md defines reviewRisk before packet and passes -ReviewRisk" {
  $skill = [IO.File]::ReadAllText((Join-Path $codexRoot 'SKILL.md'))
  Assert-True ($skill -match 'Get-FleetReviewPacket\.ps1.*-ReviewRisk \$reviewRisk') 'packet build must pass -ReviewRisk $reviewRisk'
  $riskIdx = $skill.IndexOf('$reviewRisk =')
  $packetIdx = $skill.IndexOf('Get-FleetReviewPacket.ps1')
  Assert-True ($riskIdx -ge 0 -and $packetIdx -ge 0 -and $riskIdx -lt $packetIdx) 'must define $reviewRisk before Get-FleetReviewPacket.ps1'
}

# Semantic flag-signature compare for shared wrapper launch lines in ```powershell fences.
# Host launcher (powershell vs powershell.exe) and path style differ by design; only
# switch presence + bare-literal values must match per lane. Adapter may omit Codex
# lanes; it must not invent lanes or drift flags.
function Get-FleetWrapperLaneLines([string]$text) {
  $scriptRe = 'Invoke-Grok45\.ps1|Invoke-Opus48\.ps1|Invoke-PiGlm\.ps1|Invoke-Gemini35\.ps1|Get-FleetReviewPacket\.ps1|Get-FleetReviewBudget\.ps1'
  $out = @()
  foreach ($m in [regex]::Matches($text, '(?ms)```powershell\r?\n(.*?)```')) {
    foreach ($raw in ($m.Groups[1].Value -split '\r?\n')) {
      $line = $raw.Trim()
      if ($line -and $line -match $scriptRe) { $out += $line }
    }
  }
  return $out
}
function Get-FleetLaneKey([string]$line) {
  if ($line -match 'Invoke-Grok45\.ps1') {
    if ($line -match '(^|\s)-Review(\s|$)') { return 'grok-review' }
    return 'grok-impl'
  }
  if ($line -match 'Invoke-PiGlm\.ps1') {
    if ($line -match '(^|\s)-NoTools(\s|$)') { return 'glm-review' }
    return 'glm-impl'
  }
  if ($line -match 'Invoke-Opus48\.ps1') { return 'opus-review' }
  if ($line -match 'Get-FleetReviewPacket\.ps1') { return 'packet' }
  if ($line -match 'Get-FleetReviewBudget\.ps1') { return 'budget' }
  if ($line -match 'Invoke-Gemini35\.ps1') { return 'gemini' }
  return $null
}
function Get-FleetFlagSignature([string]$line) {
  $parts = @([regex]::Matches($line, '(?:"[^"]*"|''[^'']*''|\([^\)]*\)|[^\s]+)') | ForEach-Object { $_.Value })
  $sig = @()
  $i = 0
  while ($i -lt $parts.Count) {
    $p = $parts[$i]
    if ($p -match '^-[A-Za-z]') {
      $name = $p.Substring(1)
      $val = $null
      if (($i + 1) -lt $parts.Count -and $parts[$i + 1] -notmatch '^-[A-Za-z]') {
        $val = $parts[$i + 1]
        $i++
      }
      if ($null -ne $val -and $val -match '^[A-Za-z0-9]+$') {
        $sig += "-$name=$val"
      } else {
        $sig += "-$name"
      }
    }
    $i++
  }
  return (($sig | Sort-Object) -join ' ')
}
function Get-FleetLaneSignatureMap([string]$text) {
  $map = @{}
  foreach ($line in (Get-FleetWrapperLaneLines $text)) {
    $lane = Get-FleetLaneKey $line
    if (-not $lane) { continue }
    $sig = Get-FleetFlagSignature $line
    $hasPf = $sig -match '(^|\s)-PromptFile(\s|$| =)' -or $sig -match '(^|\s)-PromptFile$'
    if ($lane -eq 'budget') {
      if (-not $map.ContainsKey($lane)) { $map[$lane] = @() }
      if (@($map[$lane]) -notcontains $sig) { $map[$lane] = @($map[$lane] + $sig) }
    } elseif ($map.ContainsKey($lane)) {
      $old = [string]$map[$lane]
      $oldHasPf = $old -match '(^|\s)-PromptFile(\s|$)' -or $old -match '(^|\s)-PromptFile$'
      if ($hasPf -and -not $oldHasPf) {
        $map[$lane] = $sig
      } elseif ($hasPf -eq $oldHasPf -and (($sig -split ' ').Count -gt ($old -split ' ').Count)) {
        $map[$lane] = $sig
      }
    } else {
      $map[$lane] = $sig
    }
  }
  return $map
}

Case 'Claude adapter canonical lanes match Codex source flags' {
  Assert-True (Test-Path -LiteralPath $claudeSkill) 'adapter missing'
  $codexMap = Get-FleetLaneSignatureMap ([IO.File]::ReadAllText((Join-Path $codexRoot 'SKILL.md')))
  $adapterMap = Get-FleetLaneSignatureMap ([IO.File]::ReadAllText($claudeSkill))
  Assert-True ($adapterMap.Count -gt 0) 'adapter has no wrapper launch lines'
  foreach ($lane in @($adapterMap.Keys)) {
    Assert-True ($codexMap.ContainsKey($lane)) "adapter lane '$lane' missing from Codex source"
    if ($lane -eq 'budget') {
      $aSet = @($adapterMap[$lane] | Sort-Object)
      $cSet = @($codexMap[$lane] | Sort-Object)
      $aJoin = $aSet -join ' | '
      $cJoin = $cSet -join ' | '
      Assert-True (($aSet -join "`n") -eq ($cSet -join "`n")) "lane budget signature set mismatch: adapter=[$aJoin] codex=[$cJoin]"
    } else {
      $aSig = [string]$adapterMap[$lane]
      $cSig = [string]$codexMap[$lane]
      Assert-True ($aSig -eq $cSig) "lane '$lane' flag mismatch: adapter=[$aSig] codex=[$cSig]"
    }
  }
}

Case 'Claude adapter retains canonical lane literals' {
  $text = [IO.File]::ReadAllText($claudeSkill)
  $required = @(
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Invoke-Grok45.ps1" -PromptFile .fleet/T1-grok-prompt.txt -WorkingDirectory <isolated-worktree> -Effort high -BashCapability Auto -IsolatedWorktree -EnableSubagents -EnableWebSearch -LeanSystemPrompt -Mode json'
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Invoke-Grok45.ps1" -PromptFile .fleet/T1-grok-review.txt -WorkingDirectory <repo> -Effort high -Review -TimeoutSeconds 900 -Mode text'
    '$packet = & "$HOME/.codex/skills/fleet/scripts/Get-FleetReviewPacket.ps1" -PacketDir $packetDir -ReviewRisk $reviewRisk -OutputPath "$packetDir/packet-manifest.json" | ConvertFrom-Json'
  )
  foreach ($line in $required) {
    Assert-True ($text.Contains($line)) ("Claude adapter canonical lane drift: missing exact literal: " + $line)
  }
}

Case 'K3 qualification recorder appends, rejects dups, fires promotion at 10' {
  $rec = Join-Path $PSScriptRoot 'Record-K3Qualification.ps1'
  $temp = Join-Path $env:TEMP ('k3q-' + [guid]::NewGuid().ToString()); $ledger = Join-Path $temp 'BENCH-k3-qualification.jsonl'
  New-Item -ItemType Directory -Path $temp | Out-Null
  try {
    $base = @{ Date = '2026-07-23'; ReviewTier = 'FULL'; VerdictSummary = 'ok'; UniqueFindingsCount = 0; VerifiedUniqueAdoptedCatches = 0; FabricationFlags = 0; FalsePositiveCount = 0; LedgerPath = $ledger; KConsidered = $true }
    $r1 = & $rec @base -RunId 'r1' -Dispatched $true -WallSeconds 12 | ConvertFrom-Json
    Assert-True ($r1.rows_total -eq 1 -and $r1.dispatched_full_rows -eq 1 -and -not [bool]$r1.promotion_assessment_due) 'a: first dispatched rows_total=1'
    $dup = $false; try { & $rec @base -RunId 'r1' -Dispatched $true -WallSeconds 1 | Out-Null } catch { $dup = $true }
    Assert-True $dup 'b: duplicate RunId rejected'
    $rSkip = & $rec @base -RunId 'r-skip' -Dispatched $false -WhyNot 'budget' | ConvertFrom-Json
    Assert-True ($rSkip.rows_total -eq 2 -and $rSkip.dispatched_full_rows -eq 1) 'c: non-dispatched with WhyNot'
    $due = $null; for ($i = 2; $i -le 10; $i++) { $due = & $rec @base -RunId ("r$i") -Dispatched $true -WallSeconds $i | ConvertFrom-Json }
    Assert-True ($due.dispatched_full_rows -eq 10 -and [bool]$due.promotion_assessment_due) 'd: 10th promotion_assessment_due=true'
    $r11 = & $rec @base -RunId 'r11' -Dispatched $true -WallSeconds 1 | ConvertFrom-Json
    Assert-True ($r11.dispatched_full_rows -eq 11 -and -not [bool]$r11.promotion_assessment_due) 'd: 11th promotion_assessment_due=false'
  } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Case 'Genre row recorder appends, rejects dups, graduates at 10 standardized' {
  $rec = Join-Path $PSScriptRoot 'Record-GenreRow.ps1'
  $temp = Join-Path $env:TEMP ('genre-' + [guid]::NewGuid().ToString()); $ledger = Join-Path $temp 'BENCH-genre.jsonl'
  New-Item -ItemType Directory -Path $temp | Out-Null
  try {
    $base = @{ Date = '2026-07-23'; Model = 'm1'; Genre = 'synthesis'; Effort = 'high'; Estimand = 'standardized_model'; ScoreType = 'facts'; Score = 1; MaxScore = 1; LedgerPath = $ledger }
    $r1 = & $rec @base -RunId 'g1' | ConvertFrom-Json
    Assert-True ($r1.rows_total -eq 1 -and $r1.model_genre_rows -eq 1 -and $r1.standardized_rows -eq 1 -and -not [bool]$r1.graduated) 'a: first append'
    $dup = $false; try { & $rec @base -RunId 'g1' | Out-Null } catch { $dup = $true }
    Assert-True $dup 'b: duplicate run_id+model+genre rejected'
    $grad = $null; for ($i = 2; $i -le 10; $i++) { $grad = & $rec @base -RunId ("g$i") | ConvertFrom-Json }
    Assert-True ($grad.standardized_rows -eq 10 -and [bool]$grad.graduated) 'c: 10th standardized graduated=true'
  } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Case 'all five Invoke wrappers carry mandatory terse-output trailer' {
  # Pure-ASCII source: em dash via [char]0x2014 so PS 5.1 no-BOM parse stays correct.
  $assign = 'OUTPUT STYLE (mandatory): terse '' + [char]0x2014 + '' drop articles, filler, pleasantries, hedging; fragments OK; technical substance exact; code, diffs, JSON, file:line references verbatim and complete. Compress prose, never evidence.'
  foreach ($name in @('Invoke-Grok45.ps1','Invoke-PiGlm.ps1','Invoke-Opus48.ps1','Invoke-KimiK3.ps1','Invoke-Gemini35.ps1')) {
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))
    Assert-True ($text.Contains($assign)) ("missing trailer literal in $name")
  }
}

Case 'object-returning validators are never used as a bare truthiness test' {
  # 2026-07-26 self-inflicted: Test-StructuredAudit changed from returning [bool] to
  # returning @{valid; observed_manifest_available}. In PowerShell ANY object is truthy,
  # so `if (Test-StructuredAudit ...)` passes even when valid=$false. A probe written that
  # way reported 6 false failures and would as easily have hidden 6 real ones. Call sites
  # must land on the FIELD. Mutation-proven: this case fails when such a line is injected.
  $pattern = 'if\s*\(\s*(-not\s*)?\(?\s*Test-StructuredAudit|\[bool\]\s*\(?\s*Test-StructuredAudit'
  $hits = @(
    Select-String -Path (Join-Path $PSScriptRoot '*.ps1') -Pattern $pattern -AllMatches |
      Where-Object { $_.Line -notmatch '\.valid' -and $_.Line -notmatch '^\s*#' }
  )
  $detail = ($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber) $($_.Line.Trim())" }) -join ' | '
  Assert-True ($hits.Count -eq 0) ("bare truthiness use of an object-returning validator: $detail")
}

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
