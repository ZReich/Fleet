# Derived lane-fit aggregator. Read-only over ledgers; every number from a ledger row.
# Small samples print `?`, never fake precision. UTF-8 no BOM when writing -OutputPath.
param(
  [string]$SpansPath = '',
  [string]$GenrePath = '',
  [string]$ShadowPath = '',
  [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
# PS5.1: $PSScriptRoot empty in param() defaults when any [Parameter()] is present; resolve here.
$root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrEmpty($SpansPath)) { $SpansPath = Join-Path $root 'BENCH-lanes.jsonl' }
if ([string]::IsNullOrEmpty($GenrePath)) { $GenrePath = Join-Path $root 'BENCH-genre.jsonl' }
if ([string]::IsNullOrEmpty($ShadowPath)) { $ShadowPath = Join-Path $root 'BENCH-shadow.jsonl' }
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$Z = 1.96

function Get-Prop($o, [string]$n) {
  $p = $o.PSObject.Properties[$n]; if ($null -eq $p) { return $null }; return $p.Value
}
function Get-Str($o, [string]$n) {
  $v = Get-Prop $o $n; if ($null -eq $v) { return '' }; return [string]$v
}
function Get-Median([double[]]$vals) {
  if ($null -eq $vals -or $vals.Count -eq 0) { return $null }
  $s = @($vals | Sort-Object); $m = [math]::Floor($s.Count / 2)
  if ($s.Count % 2) { return [double]$s[$m] }
  return ([double]$s[$m - 1] + [double]$s[$m]) / 2.0
}
function Get-NearestRankP95([double[]]$vals) {
  if ($null -eq $vals -or $vals.Count -eq 0) { return $null }
  $s = @($vals | Sort-Object)
  $rank = [int][math]::Ceiling(0.95 * $s.Count)
  if ($rank -lt 1) { $rank = 1 }
  if ($rank -gt $s.Count) { $rank = $s.Count }
  return [double]$s[$rank - 1]
}
function Get-Wilson95([double]$x, [int]$n) {
  # Wilson score interval for proportion x/n at z=1.96. x may be fractional (tie half-wins).
  if ($n -le 0) { return $null }
  $ph = $x / $n; $z2 = $Z * $Z; $den = 1.0 + $z2 / $n
  $ctr = ($ph + $z2 / (2.0 * $n)) / $den
  $rad = $Z * [math]::Sqrt(($ph * (1.0 - $ph) + $z2 / (4.0 * $n)) / $n) / $den
  return @{ lo = $ctr - $rad; hi = $ctr + $rad; p = $ph }
}
function Read-Jsonl([string]$path) {
  $rows = New-Object System.Collections.ArrayList; $malformed = 0
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return @{ rows = @(); malformed = 0; missing = $true; empty = $false }
  }
  $lines = [IO.File]::ReadAllLines($path, $utf8)
  if ($lines.Count -eq 0) { return @{ rows = @(); malformed = 0; missing = $false; empty = $true } }
  $any = $false
  foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $any = $true
    try { [void]$rows.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { $malformed++ }
  }
  return @{ rows = @($rows); malformed = $malformed; missing = $false; empty = (-not $any) }
}
function Fmt-N($v, [int]$d = 4) {
  if ($null -eq $v) { return '' }
  return ([double]$v).ToString(('0.' + ('0' * $d)), [Globalization.CultureInfo]::InvariantCulture)
}

function Try-Dbl($v, [ref]$out) {
  if ($null -eq $v -or "$v" -eq '') { return $false }
  return [double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, $out)
}
function Get-WindowId($r) {
  $w = Get-Str $r 'scoring_window_id'
  if ([string]::IsNullOrWhiteSpace($w)) { return 'none' }
  return $w
}

function Build-SpansSection($pack) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('## Spans (`phase:*`)')
  if ($pack.missing -or $pack.empty) { [void]$sb.AppendLine('no data'); [void]$sb.AppendLine(); return $sb.ToString() }
  $groups = @{}; $mal = [int]$pack.malformed
  foreach ($r in $pack.rows) {
    $model = Get-Str $r 'gen_ai.request.model'; $phase = Get-Str $r 'phase'; $status = Get-Str $r 'status'
    $dur = Get-Prop $r 'duration_s'; $tc = Get-Prop $r 'tool_calls'; $ic = Get-Prop $r 'inference_calls'
    if ([string]::IsNullOrWhiteSpace($model) -or [string]::IsNullOrWhiteSpace($phase)) { $mal++; continue }
    $durD = 0.0; $tcD = 0.0; $icD = 0.0
    if (-not (Try-Dbl $dur ([ref]$durD)) -or -not (Try-Dbl $tc ([ref]$tcD)) -or -not (Try-Dbl $ic ([ref]$icD))) { $mal++; continue }
    if ($status -notin @('ok', 'error', 'timeout', 'no_contest')) { $mal++; continue }
    $cs = Get-Str $r 'coverage_scope'; $est = Get-Str $r 'estimand'; $st = Get-Str $r 'score_type'
    $win = Get-WindowId $r
    $key = "phase:$phase|$model|$cs|$est|$st|window:$win"
    if (-not $groups.ContainsKey($key)) {
      $groups[$key] = @{
        model = $model; phase = $phase; coverage_scope = $cs; estimand = $est; score_type = $st; scoring_window_id = $win
        durs = New-Object System.Collections.ArrayList; tools = New-Object System.Collections.ArrayList
        infs = New-Object System.Collections.ArrayList; ok = 0; error = 0; timeout = 0; no_contest = 0
      }
    }
    $g = $groups[$key]
    [void]$g.durs.Add($durD); [void]$g.tools.Add($tcD); [void]$g.infs.Add($icD)
    switch ($status) { 'ok' { $g.ok++ } 'error' { $g.error++ } 'timeout' { $g.timeout++ } 'no_contest' { $g.no_contest++ } }
  }
  [void]$sb.AppendLine(("malformed_lines: {0}" -f $mal))
  if ($groups.Count -eq 0) { [void]$sb.AppendLine('no data'); [void]$sb.AppendLine(); return $sb.ToString() }
  [void]$sb.AppendLine('| group | model | phase | coverage_scope | estimand | score_type | n | median_duration_s | p95_duration_s | mean_tool_calls | mean_inference_calls | ok | error | timeout | no_contest |')
  [void]$sb.AppendLine('| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
  foreach ($key in ($groups.Keys | Sort-Object)) {
    $g = $groups[$key]; $n = $g.durs.Count; $durs = [double[]]@($g.durs)
    $mt = ($g.tools | Measure-Object -Average).Average; $mi = ($g.infs | Measure-Object -Average).Average
    # n-lt 30 => suppress median/p95 precision (raw n + status counts stay)
    $medS = if ($n -lt 30) { '?' } else { Fmt-N (Get-Median $durs) }
    $p95S = if ($n -lt 30) { '?' } else { Fmt-N (Get-NearestRankP95 $durs) }
    [void]$sb.AppendLine(("| phase:{0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} | {13} | {14} |" -f `
      $g.phase, $g.model, $g.phase, $g.coverage_scope, $g.estimand, $g.score_type, $n, `
      $medS, $p95S, (Fmt-N $mt), (Fmt-N $mi), `
      $g.ok, $g.error, $g.timeout, $g.no_contest))
  }
  [void]$sb.AppendLine(); return $sb.ToString()
}

function Build-GenreSection($pack) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('## Genre (`genre:*`)')
  if ($pack.missing -or $pack.empty) { [void]$sb.AppendLine('no data'); [void]$sb.AppendLine(); return $sb.ToString() }
  $groups = @{}; $mal = [int]$pack.malformed
  foreach ($r in $pack.rows) {
    $model = Get-Str $r 'model'; $genre = Get-Str $r 'genre'
    $est = Get-Str $r 'estimand'; $st = Get-Str $r 'score_type'
    $score = Get-Prop $r 'score'; $max = Get-Prop $r 'max_score'
    if ([string]::IsNullOrWhiteSpace($model) -or [string]::IsNullOrWhiteSpace($genre)) { $mal++; continue }
    if ([string]::IsNullOrWhiteSpace($est) -or [string]::IsNullOrWhiteSpace($st)) { $mal++; continue }
    $scoreD = 0.0; $maxD = 0.0
    if (-not (Try-Dbl $score ([ref]$scoreD)) -or -not (Try-Dbl $max ([ref]$maxD)) -or $maxD -le 0) { $mal++; continue }
    $cs = Get-Str $r 'coverage_scope'; $win = Get-WindowId $r
    $key = "genre:$genre|$model|$cs|$est|$st|window:$win"
    if (-not $groups.ContainsKey($key)) {
      $groups[$key] = @{
        model = $model; genre = $genre; coverage_scope = $cs; estimand = $est; score_type = $st; scoring_window_id = $win
        norms = New-Object System.Collections.ArrayList; walls = New-Object System.Collections.ArrayList
        fabs = 0; wall_n = 0
      }
    }
    $g = $groups[$key]
    [void]$g.norms.Add($scoreD / $maxD)
    $w = Get-Prop $r 'wall_seconds'; $wD = 0.0
    if (Try-Dbl $w ([ref]$wD)) { [void]$g.walls.Add($wD); $g.wall_n++ }
    $f = Get-Prop $r 'fabrications'; $fI = 0
    if ($null -ne $f -and "$f" -ne '' -and [int]::TryParse([string]$f, [ref]$fI)) { $g.fabs += $fI }
  }
  [void]$sb.AppendLine(("malformed_lines: {0}" -f $mal))
  if ($groups.Count -eq 0) { [void]$sb.AppendLine('no data'); [void]$sb.AppendLine(); return $sb.ToString() }
  [void]$sb.AppendLine('| group | model | genre | coverage_scope | estimand | score_type | n | mean_score_norm | mean_wall_seconds | total_fabrications |')
  [void]$sb.AppendLine('| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: |')
  foreach ($key in ($groups.Keys | Sort-Object)) {
    $g = $groups[$key]; $n = $g.norms.Count
    $mn = ($g.norms | Measure-Object -Average).Average
    $mw = if ($g.wall_n -gt 0) { ($g.walls | Measure-Object -Average).Average } else { $null }
    $mwS = if ($null -eq $mw) { '' } else { Fmt-N $mw }
    # genre n-lt 30 => suppress mean_score_norm (n stays visible)
    $mnS = if ($n -lt 30) { '?' } else { Fmt-N $mn }
    [void]$sb.AppendLine(("| genre:{0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} |" -f `
      $g.genre, $g.model, $g.genre, $g.coverage_scope, $g.estimand, $g.score_type, $n, $mnS, $mwS, $g.fabs))
  }
  [void]$sb.AppendLine(); return $sb.ToString()
}

function Resolve-ShadowPair($r) {
  $pair = Get-Str $r 'pair'
  if (-not [string]::IsNullOrWhiteSpace($pair)) { return $pair }
  $ch = Get-Str $r 'challenger'
  if (-not [string]::IsNullOrWhiteSpace($ch)) { return $ch }
  $a = Get-Prop $r 'candidate_a'; $b = Get-Prop $r 'candidate_b'
  if ($null -ne $a -and $null -ne $b) {
    $am = if ($a.PSObject.Properties['model']) { [string]$a.model } else { 'a' }
    $bm = if ($b.PSObject.Properties['model']) { [string]$b.model } else { 'b' }
    return "$am-vs-$bm"
  }
  return ''
}
function Resolve-ShadowOutcome($r) {
  # Challenger-POV vocabulary (group key carries pov:challenger):
  # live graded result primary|challenger|tie|no_contest maps to loss|win|tie|no_contest.
  $res = Get-Str $r 'result'
  if ([string]::IsNullOrWhiteSpace($res)) {
    # status=no_contest with no result field => no_contest, never malformed
    if ((Get-Str $r 'status') -eq 'no_contest') { return 'no_contest' }
    return $null
  }
  # Live v8 graded vocab: 'primary' => loss, 'challenger' => win (challenger POV).
  if ($res -eq 'primary') { return 'loss' }
  if ($res -eq 'challenger') { return 'win' }
  switch -Regex ($res) {
    '^(win|challenger_win|a_win)$' { return 'win' }
    '^(loss|primary_win|b_win)$' { return 'loss' }
    '^tie$' { return 'tie' }
    '^(no_contest|excluded|excluded_design|excluded_capability)$' { return 'no_contest' }
    default { return $null }
  }
}

function Build-ShadowSection($pack) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('## Shadow (`shadow:*`)')
  if ($pack.missing -or $pack.empty) { [void]$sb.AppendLine('no data'); [void]$sb.AppendLine(); return $sb.ToString() }
  $groups = @{}; $mal = [int]$pack.malformed
  foreach ($r in $pack.rows) {
    $pair = Resolve-ShadowPair $r
    $stratum = Get-Str $r 'task_stratum'
    if ([string]::IsNullOrWhiteSpace($stratum)) { $stratum = Get-Str $r 'stratum' }
    $cs = Get-Str $r 'coverage_scope'; $est = Get-Str $r 'estimand'; $out = Resolve-ShadowOutcome $r
    if ([string]::IsNullOrWhiteSpace($pair) -or [string]::IsNullOrWhiteSpace($stratum)) { $mal++; continue }
    if ([string]::IsNullOrWhiteSpace($cs) -or [string]::IsNullOrWhiteSpace($est)) { $mal++; continue }
    if ($null -eq $out) { $mal++; continue }
    $win = Get-WindowId $r
    # pov:challenger documents result mapping (primary => loss)
    $key = "shadow:$stratum|$pair|$cs|$est|window:$win|pov:challenger"
    if (-not $groups.ContainsKey($key)) {
      $groups[$key] = @{
        pair = $pair; task_stratum = $stratum; coverage_scope = $cs; estimand = $est; scoring_window_id = $win
        wins = 0; losses = 0; ties = 0; no_contest = 0; pairs = 0
      }
    }
    $g = $groups[$key]; $g.pairs++
    switch ($out) { 'win' { $g.wins++ } 'loss' { $g.losses++ } 'tie' { $g.ties++ } 'no_contest' { $g.no_contest++ } }
  }
  [void]$sb.AppendLine(("malformed_lines: {0}" -f $mal))
  if ($groups.Count -eq 0) { [void]$sb.AppendLine('no data'); [void]$sb.AppendLine(); return $sb.ToString() }
  [void]$sb.AppendLine('| group | pair | task_stratum | coverage_scope | estimand | pairs | wins | losses | ties | no_contest | eligible | win_rate | ci_low | ci_high | decision_grade |')
  [void]$sb.AppendLine('| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |')
  foreach ($key in ($groups.Keys | Sort-Object)) {
    $g = $groups[$key]; $elig = $g.wins + $g.losses + $g.ties
    $rateS = '?'; $loS = '?'; $hiS = '?'; $dg = 'false'
    if ($elig -ge 30) {
      $w = Get-Wilson95 ([double]$g.wins + 0.5 * [double]$g.ties) $elig
      $rateS = Fmt-N $w.p; $loS = Fmt-N $w.lo; $hiS = Fmt-N $w.hi; $dg = 'true'
    }
    [void]$sb.AppendLine(("| shadow:{0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} | {13} | {14} |" -f `
      $g.task_stratum, $g.pair, $g.task_stratum, $g.coverage_scope, $g.estimand, `
      $g.pairs, $g.wins, $g.losses, $g.ties, $g.no_contest, $elig, $rateS, $loS, $hiS, $dg))
  }
  [void]$sb.AppendLine(); return $sb.ToString()
}

$spans = Read-Jsonl $SpansPath
$genre = Read-Jsonl $GenrePath
$shadow = Read-Jsonl $ShadowPath
$md = New-Object Text.StringBuilder
[void]$md.AppendLine('# Fleet lane-fit (derived)')
[void]$md.AppendLine()
[void]$md.Append((Build-SpansSection $spans))
[void]$md.Append((Build-GenreSection $genre))
[void]$md.Append((Build-ShadowSection $shadow))
$text = ($md.ToString() -replace "`r`n", "`n")
[Console]::Out.Write($text)
if (-not [string]::IsNullOrEmpty($OutputPath)) {
  $dir = Split-Path -Parent $OutputPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($OutputPath, $text, $utf8)
}
exit 0
