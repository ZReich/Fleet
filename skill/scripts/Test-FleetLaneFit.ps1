# Offline suite for Get-FleetLaneFit.ps1. Synthetic temp ledgers only.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Get-FleetLaneFit.ps1'
$utf8 = [Text.UTF8Encoding]::new($false)
$passed = 0; $failed = 0
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-lanefit-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }
function Write-Lines([string]$path, [string[]]$lines) {
  [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $utf8)
}
function New-Span([double]$dur, [string]$model = 'm1', [string]$phase = 'impl', [string]$status = 'ok', [int]$tools = 2, [int]$infs = 1, [string]$cs = '', [string]$est = '', [string]$st = '', [string]$win = '') {
  $o = [ordered]@{ 'gen_ai.request.model' = $model; phase = $phase; duration_s = $dur; tool_calls = $tools; inference_calls = $infs; status = $status }
  if ($cs -ne '') { $o['coverage_scope'] = $cs }
  if ($est -ne '') { $o['estimand'] = $est }
  if ($st -ne '') { $o['score_type'] = $st }
  if ($win -ne '') { $o['scoring_window_id'] = $win }
  return (($o | ConvertTo-Json -Compress))
}
function New-Genre([string]$model, [string]$genre, [string]$est, [string]$st, [double]$score, [double]$max, [int]$wall = 10, [int]$fab = 0, [string]$cs = '', [string]$win = '') {
  $o = [ordered]@{ model = $model; genre = $genre; estimand = $est; score_type = $st; score = $score; max_score = $max; wall_seconds = $wall; fabrications = $fab }
  if ($cs -ne '') { $o['coverage_scope'] = $cs }
  if ($win -ne '') { $o['scoring_window_id'] = $win }
  return ($o | ConvertTo-Json -Compress)
}
function New-Shadow([string]$pair, [string]$stratum, [string]$cs, [string]$est, [string]$result, [string]$win = '') {
  $o = @{ pair = $pair; task_stratum = $stratum; coverage_scope = $cs; estimand = $est; result = $result }
  if ($win -ne '') { $o['scoring_window_id'] = $win }
  return ($o | ConvertTo-Json -Compress)
}
function Invoke-Fit {
  param([string]$Spans = '', [string]$Genre = '', [string]$Shadow = '', [string]$Out = '')
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
  if ($Spans) { $argList += @('-SpansPath', $Spans) }
  if ($Genre) { $argList += @('-GenrePath', $Genre) }
  if ($Shadow) { $argList += @('-ShadowPath', $Shadow) }
  if ($Out) { $argList += @('-OutputPath', $Out) }
  # Missing ledgers: point at empty non-existent names under temp when not supplied.
  if (-not $Spans) { $argList += @('-SpansPath', (Join-Path $temp 'missing-spans.jsonl')) }
  if (-not $Genre) { $argList += @('-GenrePath', (Join-Path $temp 'missing-genre.jsonl')) }
  if (-not $Shadow) { $argList += @('-ShadowPath', (Join-Path $temp 'missing-shadow.jsonl')) }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = $utf8
  $p = [Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
}
function Fmt4([double]$v) { return $v.ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture) }
function Oracle-Wilson([double]$x, [int]$n) {
  # Independent Wilson 95% (z=1.96) - not imported from SUT.
  $z = 1.96; $ph = $x / $n; $z2 = $z * $z; $den = 1.0 + $z2 / $n
  $ctr = ($ph + $z2 / (2.0 * $n)) / $den
  $rad = $z * [math]::Sqrt(($ph * (1.0 - $ph) + $z2 / (4.0 * $n)) / $n) / $den
  return @{ p = $ph; lo = $ctr - $rad; hi = $ctr + $rad }
}

try {
  Case 'n-lt-30 suppresses median/p95; n-ge-30 shows oracle' {
    # B9 restored: <30 eligible => ? for median/p95 (n+status stay). n=10 must NOT print numerics.
    $durs10 = 10, 20, 30, 40, 50, 60, 70, 80, 90, 100
    $sp10 = Join-Path $temp 'spans-n10.jsonl'
    Write-Lines $sp10 @($durs10 | ForEach-Object { New-Span -dur $_ })
    $r10 = Invoke-Fit -Spans $sp10
    Assert-True ($r10.ExitCode -eq 0) "exit $($r10.ExitCode) stderr=$($r10.StdErr)"
    Assert-True ($r10.StdOut -match '\| 10 \| \? \| \? \|') "n=10 must show ? median/p95:`n$($r10.StdOut)"
    Assert-True ($r10.StdOut -notmatch '\| 10 \| 55\.0000 \|') "n=10 must not leak numeric median"
    # Hand oracle at n=30: durs 1..30; sorted; median=(15+16)/2=15.5; p95 rank=ceil(28.5)=29 -> 29
    $sp30 = Join-Path $temp 'spans-n30.jsonl'
    Write-Lines $sp30 @(1..30 | ForEach-Object { New-Span -dur $_ })
    $r30 = Invoke-Fit -Spans $sp30
    Assert-True ($r30.ExitCode -eq 0) "exit $($r30.ExitCode)"
    Assert-True ($r30.StdOut -match '\| 30 \| 15\.5000 \| 29\.0000 \|') "n=30 oracle median/p95 missing:`n$($r30.StdOut)"
  }

  Case 'Wilson CI oracle (wins=7 losses=3 scaled to n=30, z=1.96)' {
    # Oracle inputs: 21 wins + 9 losses (7:3 ratio), n=30, x=21, z=1.96.
    # Independent Wilson via Oracle-Wilson (not SUT). Expected cells from that oracle.
    $sh = Join-Path $temp 'shadow-wilson.jsonl'
    $lines = @()
    1..21 | ForEach-Object { $lines += New-Shadow 'a-vs-b' 'standard' 'scope-x' 'standardized_model' 'win' }
    1..9 | ForEach-Object { $lines += New-Shadow 'a-vs-b' 'standard' 'scope-x' 'standardized_model' 'loss' }
    Write-Lines $sh $lines
    $r = Invoke-Fit -Shadow $sh
    Assert-True ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
    $o = Oracle-Wilson 21.0 30
    $cell = '| {0} | {1} | {2} | true |' -f (Fmt4 $o.p), (Fmt4 $o.lo), (Fmt4 $o.hi)
    Assert-True ($r.StdOut.Contains($cell)) "Wilson cells missing $cell in:`n$($r.StdOut)"
  }

  Case '29 eligible => ?; 30 eligible => estimate' {
    $sh29 = Join-Path $temp 'shadow-29.jsonl'
    $lines29 = @()
    1..20 | ForEach-Object { $lines29 += New-Shadow 'p' 'hard' 'c1' 'standardized_model' 'win' }
    1..9 | ForEach-Object { $lines29 += New-Shadow 'p' 'hard' 'c1' 'standardized_model' 'loss' }
    # 29 eligible; +5 no_contest not eligible
    1..5 | ForEach-Object { $lines29 += New-Shadow 'p' 'hard' 'c1' 'standardized_model' 'no_contest' }
    Write-Lines $sh29 $lines29
    $r29 = Invoke-Fit -Shadow $sh29
    Assert-True ($r29.StdOut -match '\| 29 \| \? \| \? \| \? \| false \|') "29 must show ? :`n$($r29.StdOut)"

    $sh30 = Join-Path $temp 'shadow-30.jsonl'
    $lines30 = @()
    1..20 | ForEach-Object { $lines30 += New-Shadow 'p' 'hard' 'c1' 'standardized_model' 'win' }
    1..10 | ForEach-Object { $lines30 += New-Shadow 'p' 'hard' 'c1' 'standardized_model' 'loss' }
    Write-Lines $sh30 $lines30
    $r30 = Invoke-Fit -Shadow $sh30
    Assert-True ($r30.StdOut -match '\| 30 \| 0\.6667 \|') "30 must show rate:`n$($r30.StdOut)"
    Assert-True ($r30.StdOut -notmatch '\| 30 \| \? \|') "30 must not show ? rate"
  }

  Case 'differing coverage_scope/estimand stay separate groups' {
    $sp = Join-Path $temp 'spans-sep.jsonl'
    Write-Lines $sp @(
      (New-Span 10 -cs 'scope-a' -est 'standardized_model'),
      (New-Span 20 -cs 'scope-b' -est 'standardized_model'),
      (New-Span 30 -cs 'scope-a' -est 'optimized_system')
    )
    $r = Invoke-Fit -Spans $sp
    $scopeRows = @([regex]::Matches($r.StdOut, '\| phase:impl \| m1 \| impl \|'))
    Assert-True ($scopeRows.Count -eq 3) "expected 3 separate span groups, got $($scopeRows.Count) in:`n$($r.StdOut)"
    Assert-True ($r.StdOut -match 'scope-a' -and $r.StdOut -match 'scope-b') 'coverage_scope values missing'
    Assert-True ($r.StdOut -match 'standardized_model' -and $r.StdOut -match 'optimized_system') 'estimand values missing'

    $ge = Join-Path $temp 'genre-sep.jsonl'
    Write-Lines $ge @(
      (New-Genre 'm' 'synthesis' 'standardized_model' 'facts' 1 1),
      (New-Genre 'm' 'synthesis' 'optimized_system' 'facts' 1 1)
    )
    $rg = Invoke-Fit -Genre $ge
    $gRows = @([regex]::Matches($rg.StdOut, '\| genre:synthesis \| m \| synthesis \|'))
    Assert-True ($gRows.Count -eq 2) "expected 2 genre groups, got $($gRows.Count)"
  }

  Case 'malformed lines skipped+counted; missing ledgers => no data exit 0' {
    $sp = Join-Path $temp 'spans-mal.jsonl'
    Write-Lines $sp @(
      (New-Span 10),
      'NOT-JSON{',
      (New-Span 20)
    )
    $r = Invoke-Fit -Spans $sp
    Assert-True ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
    Assert-True ($r.StdOut -match 'malformed_lines: 1') "malformed count missing:`n$($r.StdOut)"
    Assert-True ($r.StdOut -match '\| 2 \|') 'valid rows should still aggregate n=2'

    $miss = Invoke-Fit
    Assert-True ($miss.ExitCode -eq 0) "missing ledgers exit $($miss.ExitCode)"
    $noData = @([regex]::Matches($miss.StdOut, '(?m)^no data$'))
    Assert-True ($noData.Count -ge 3) "expected 3 no data sections, got $($noData.Count) in:`n$($miss.StdOut)"
  }

  Case 'live v8 result vocab + status-only no_contest (B7 cross-seam)' {
    # Graded live shape: result=primary|tie; status-only no_contest; challenger-POV: primary=>loss
    $sh = Join-Path $temp 'shadow-live-v8.jsonl'
    $lines = @(
      (@{ pair = 'p-vs-c'; task_stratum = 'standard'; coverage_scope = 'scope-x'; estimand = 'standardized_model'; result = 'primary'; status = 'graded' } | ConvertTo-Json -Compress),
      (@{ pair = 'p-vs-c'; task_stratum = 'standard'; coverage_scope = 'scope-x'; estimand = 'standardized_model'; result = 'tie'; status = 'graded' } | ConvertTo-Json -Compress),
      (@{ pair = 'p-vs-c'; task_stratum = 'standard'; coverage_scope = 'scope-x'; estimand = 'standardized_model'; status = 'no_contest' } | ConvertTo-Json -Compress)
    )
    Write-Lines $sh $lines
    $r = Invoke-Fit -Shadow $sh
    Assert-True ($r.ExitCode -eq 0) "exit $($r.ExitCode) stderr=$($r.StdErr)"
    Assert-True ($r.StdOut -match 'malformed_lines: 0') "status-only no_contest must not be malformed:`n$($r.StdOut)"
    # pairs=3 wins=0 losses=1 ties=1 no_contest=1 eligible=2
    Assert-True ($r.StdOut -match '\| 3 \| 0 \| 1 \| 1 \| 1 \| 2 \|') "live v8 counts wrong:`n$($r.StdOut)"
  }

  Case 'scoring_window_id separates groups; window:none for missing (B12)' {
    $sp = Join-Path $temp 'spans-window.jsonl'
    Write-Lines $sp @(
      (New-Span 10 -cs 's' -est 'standardized_model' -win 'w1'),
      (New-Span 20 -cs 's' -est 'standardized_model' -win 'w2'),
      (New-Span 30 -cs 's' -est 'standardized_model')
    )
    $r = Invoke-Fit -Spans $sp
    $rows = @([regex]::Matches($r.StdOut, '\| phase:impl \| m1 \| impl \|'))
    Assert-True ($rows.Count -eq 3) "expected 3 window-separated groups, got $($rows.Count) in:`n$($r.StdOut)"
  }

  Case 'schema-malformed nonnumeric skip+count exit 0 (B13)' {
    $sp = Join-Path $temp 'spans-badnum.jsonl'
    Write-Lines $sp @(
      (New-Span 10),
      '{"gen_ai.request.model":"m1","phase":"impl","duration_s":"not-a-number","tool_calls":1,"inference_calls":1,"status":"ok"}',
      (New-Span 20)
    )
    $r = Invoke-Fit -Spans $sp
    Assert-True ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
    Assert-True ($r.StdOut -match 'malformed_lines: 1') "bad numeric must count malformed:`n$($r.StdOut)"
    Assert-True ($r.StdOut -match '\| 2 \|') 'valid rows still aggregate'

    $ge = Join-Path $temp 'genre-badnum.jsonl'
    Write-Lines $ge @(
      (New-Genre 'm' 'synthesis' 'standardized_model' 'facts' 1 1),
      '{"model":"m","genre":"synthesis","estimand":"standardized_model","score_type":"facts","score":"x","max_score":1}'
    )
    $rg = Invoke-Fit -Genre $ge
    Assert-True ($rg.ExitCode -eq 0) "genre bad-numeric exit $($rg.ExitCode)"
    Assert-True ($rg.StdOut -match 'malformed_lines: 1') "genre bad numeric malformed:`n$($rg.StdOut)"
  }

  Case 'tie-adjusted win rate exact' {
    # wins=3 losses=1 ties=2 => rate=(3+0.5*2)/6=4/6=0.6666... need n>=30: scale x5 => 15w 5l 10t, elig=30, rate=20/30=0.6667
    $sh = Join-Path $temp 'shadow-tie.jsonl'
    $lines = @()
    1..15 | ForEach-Object { $lines += New-Shadow 't' 'review' 'sc' 'standardized_model' 'win' }
    1..5 | ForEach-Object { $lines += New-Shadow 't' 'review' 'sc' 'standardized_model' 'loss' }
    1..10 | ForEach-Object { $lines += New-Shadow 't' 'review' 'sc' 'standardized_model' 'tie' }
    Write-Lines $sh $lines
    $r = Invoke-Fit -Shadow $sh
    Assert-True ($r.StdOut -match '\| 15 \| 5 \| 10 \| 0 \| 30 \| 0\.6667 \|') "tie-adjusted rate wrong:`n$($r.StdOut)"
  }

  Case 'OutputPath bytes equal stdout; no UTF-8 BOM' {
    $sp = Join-Path $temp 'spans-bom.jsonl'
    Write-Lines $sp @((New-Span 42))
    $out = Join-Path $temp 'report.md'
    $r = Invoke-Fit -Spans $sp -Out $out
    Assert-True ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
    $fileBytes = [IO.File]::ReadAllBytes($out)
    $stdoutBytes = $utf8.GetBytes($r.StdOut)
    Assert-True ($fileBytes.Length -eq $stdoutBytes.Length) "len file=$($fileBytes.Length) stdout=$($stdoutBytes.Length)"
    $same = $true
    for ($i = 0; $i -lt $fileBytes.Length; $i++) {
      if ($fileBytes[$i] -ne $stdoutBytes[$i]) { $same = $false; break }
    }
    Assert-True $same 'OutputPath bytes differ from stdout bytes'
    Assert-True (-not ($fileBytes.Length -ge 3 -and $fileBytes[0] -eq 0xEF -and $fileBytes[1] -eq 0xBB -and $fileBytes[2] -eq 0xBF)) 'BOM present EF BB BF'
  }
}
finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
