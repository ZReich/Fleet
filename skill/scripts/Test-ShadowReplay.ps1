# Offline suite for Invoke-ShadowReplay + consumer live path. Temp fixtures only;
# FAKE wrappers via lane-spec. Exit 0 all pass / 1 any fail.
$ErrorActionPreference = 'Stop'
$enqueue = Join-Path $PSScriptRoot 'Enqueue-FleetShadow.ps1'
$start = Join-Path $PSScriptRoot 'Start-FleetAutoShadow.ps1'
$replay = Join-Path $PSScriptRoot 'Invoke-ShadowReplay.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-shadow-replay-' + [guid]::NewGuid().ToString('n'))
$passed = 0; $failed = 0
$utf8 = New-Object Text.UTF8Encoding($false)

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }
function Assert-BytesEqual([byte[]]$A, [byte[]]$B, [string]$Label) {
  Assert-True ($A.Length -eq $B.Length) "$Label length $($A.Length) vs $($B.Length)"
  for ($i = 0; $i -lt $A.Length; $i++) { Assert-True ($A[$i] -eq $B[$i]) "$Label byte $i changed" }
}
function Write-Json([string]$Path, $Obj) {
  $dir = Split-Path -Parent $Path; if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 10), $utf8)
}
function New-GitRepo([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  & git -C $Path init -q; & git -C $Path config user.name t; & git -C $Path config user.email t@t.invalid
  [IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), 'seed')
  & git -C $Path add .; & git -C $Path commit -q -m base | Out-Null
  return (& git -C $Path rev-parse HEAD).Trim()
}
function New-FakeWrapper([string]$Path, [string]$Mode = 'ok') {
  # Mode: ok | fail_gate | timeout | scope | primary_win | challenger_win | tie5 | patch_ok | patch_bad
  # Accepts Sol-family (-Prompt/-Model) and Grok-style (-PromptFile) shapes.
  $body = @'
param([string]$Prompt,[string]$PromptFile,[string]$Model,[string]$WorkingDirectory,[int]$TimeoutSeconds,[string]$Mode,[string]$LaneId,[switch]$ReadOnly)
$m = $env:FAKE_SHADOW_MODE
if ($m -eq 'timeout') { Start-Sleep -Seconds ([math]::Max(20, $TimeoutSeconds + 15)); @{status='ok'} | ConvertTo-Json -Compress; exit 0 }
# Patch-seat only (Invoke-PiGlm passes -ReadOnly); worktree seats keep writing files.
if ($ReadOnly -and $m -eq 'patch_ok') {
  $patch = @"
diff --git a/result.txt b/result.txt
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/result.txt
@@ -0,0 +1 @@
+patched-ok
"@
  @{status='ok';task_status='done';lane=$LaneId;patch=$patch;observed_model='glm-5.3'} | ConvertTo-Json -Compress
  exit 0
}
if ($ReadOnly -and $m -eq 'patch_bad') {
  $patch = @"
diff --git a/outside.txt b/outside.txt
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/outside.txt
@@ -0,0 +1 @@
+leak
"@
  @{status='ok';task_status='done';lane=$LaneId;patch=$patch;model='glm-5.3';response=$patch} | ConvertTo-Json -Compress
  exit 0
}
$content = 'ok-content'
if ($m -eq 'scope') { $content = 'x'; $p = Join-Path $WorkingDirectory 'outside.txt'; [IO.File]::WriteAllText($p, 'leak') }
elseif ($m -eq 'fail_gate' -and $LaneId -eq $env:FAKE_FAIL_LANE) { $content = 'BAD' }
elseif ($m -eq 'primary_win' -and $LaneId -eq 'terra') { $content = ('P' * 2) }
elseif ($m -eq 'primary_win' -and $LaneId -eq 'grok') { $content = 'G' }
elseif ($m -eq 'challenger_win' -and $LaneId -eq 'grok') { $content = ('C' * 2) }
elseif ($m -eq 'challenger_win' -and $LaneId -eq 'terra') { $content = 'T' }
elseif ($m -eq 'tie5') { $content = 'same' }
if ($WorkingDirectory) { [IO.File]::WriteAllText((Join-Path $WorkingDirectory 'result.txt'), $content) }
@{status='ok';task_status='done';lane=$LaneId;model=$Model} | ConvertTo-Json -Compress
'@
  $dir = Split-Path -Parent $Path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, $body, $utf8)
}
function New-TaskSpec([string]$Gate = "if (-not (Test-Path result.txt)) { exit 1 }; if ((Get-Content result.txt -Raw) -match 'BAD') { exit 1 }", [int]$MaxLines = 50) {
  return @{ id = 't-replay'; prompt = 'Write result.txt'; allowed_paths = @('result.txt'); gate_commands = @($Gate); max_diff_lines = $MaxLines }
}
function EnqSpec([hashtable]$extra) {
  # PS5.1 mangles embedded quotes when splatting args to a native exe (CRT argv
  # lesson); build the command line with CRT escaping + Diagnostics.Process.
  $tokens = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$enqueue)
  foreach ($k in $extra.Keys) {
    $v = $extra[$k]
    if ($k -eq 'Force' -and ($v -eq $true -or "$v" -eq 'true')) { $tokens += '-Force' }
    else { $tokens += @("-$k", [string]$v) }
  }
  $argLine = ($tokens | ForEach-Object { $t = [string]$_; if (-not $t) { '""' } elseif ($t -notmatch '[\s"]') { $t } else { '"' + ($t -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"' } }) -join ' '
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'; $psi.Arguments = $argLine
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit(); $p.Dispose()
  if ($err) { Write-Host $err }
  ($out -join "`n") | ConvertFrom-Json
}

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  $repo = Join-Path $temp 'repo'; $baseSha = New-GitRepo $repo
  # Fakes must live under a scripts/ dir with allowlisted basenames (B1 trust boundary).
  $fakeScripts = Join-Path $temp 'scripts'
  $fakeSol = Join-Path $fakeScripts 'Invoke-Sol.ps1'
  $fakeGrok = Join-Path $fakeScripts 'Invoke-Grok45.ps1'
  $fakeGlm = Join-Path $fakeScripts 'Invoke-PiGlm.ps1'
  New-FakeWrapper $fakeSol; New-FakeWrapper $fakeGrok; New-FakeWrapper $fakeGlm
  $fake = $fakeGrok
  $laneSpec = Join-Path $temp 'lane-spec.json'
  Write-Json $laneSpec @{ wrappers = @{ terra = $fakeSol; grok = $fakeGrok }; models = @{ terra = 'gpt-5.6-terra'; grok = 'grok-4.6' } }
  $specJson = (New-TaskSpec | ConvertTo-Json -Compress -Depth 6)

  Case 'delete packet after enqueue; replay uses embedded snapshot' {
    $fx = Join-Path $temp 'self'; $q = Join-Path $fx 'q'; New-Item -ItemType Directory -Force -Path $q | Out-Null
    $packet = Join-Path $fx 'packet.json'; Write-Json $packet @{ note = 'frozen' }
    $r = EnqSpec @{ RunId='r1'; TaskId='t-self'; TaskStratum='standard'; BaseSha=$baseSha; Seed='s1'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='4'; PacketManifest=$packet }
    Assert-True ($r.sampled -eq $true) 'enqueue failed'
    Remove-Item -LiteralPath $packet -Force
    $entryPath = $r.queue_path
    $env:FAKE_SHADOW_MODE = 'tie5'
    $out = Join-Path $fx 'out'
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $entryPath -RepoRoot $repo -OutputDirectory $out -LaneSpecPath $laneSpec | Out-String
    $c = $raw.Trim() | ConvertFrom-Json
    Assert-True ($true -eq $c.success -and $c.status -eq 'graded' -and (Test-Path -LiteralPath $c.reveal_path)) "replay failed: $($raw.Trim())"
    Assert-True ($null -ne $c.scores -and $c.scores.primary.total -le 90) 'scores missing/max'
  }

  Case 'legacy spec-less entry => deferred_no_spec; zero wrappers; ledgers identical' {
    $fx = Join-Path $temp 'legacy'; $q = Join-Path $fx 'q'; $led = Join-Path $fx 'led'
    New-Item -ItemType Directory -Force -Path $q,$led | Out-Null
    $k3 = Join-Path $led 'BENCH-k3-qualification.jsonl'; $op = Join-Path $led 'BENCH-opus5-pairs.jsonl'
    [IO.File]::WriteAllText($k3, '', $utf8); [IO.File]::WriteAllText($op, '', $utf8)
    $k3b = [IO.File]::ReadAllBytes($k3); $opb = [IO.File]::ReadAllBytes($op)
    $launchLog = Join-Path $fx 'launches.txt'
    $countScripts = Join-Path $fx 'scripts'
    $counting = Join-Path $countScripts 'Invoke-Grok45.ps1'
    $logEsc = $launchLog.Replace("'","''"); $fakeEsc = $fake.Replace("'","''")
    New-Item -ItemType Directory -Force -Path $countScripts | Out-Null
    [IO.File]::WriteAllText($counting, @"
param([string]`$Prompt,[string]`$PromptFile,[string]`$Model,[string]`$WorkingDirectory,[int]`$TimeoutSeconds,[string]`$Mode,[string]`$LaneId)
Add-Content -LiteralPath '$logEsc' -Value 'launch'
& '$fakeEsc' -PromptFile `$PromptFile -WorkingDirectory `$WorkingDirectory -TimeoutSeconds `$TimeoutSeconds -Mode `$Mode -LaneId `$LaneId
"@, $utf8)
    $countSol = Join-Path $countScripts 'Invoke-Sol.ps1'
    Copy-Item -LiteralPath $counting -Destination $countSol -Force
    Write-Json (Join-Path $fx 'lane.json') @{ wrappers = @{ terra = $countSol; grok = $counting } }
    $null = EnqSpec @{ RunId='rL'; TaskId='t-leg'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sL'; Challenger='grok'; QueueRoot=$q; Force=$true; JobKind='k3_full_review' }
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q -RepoRoot $repo -LedgerPath (Join-Path $fx 'shadow.jsonl') -LedgerRoot $led -LaneSpecPath (Join-Path $fx 'lane.json')
    $rows = @(Get-Content -LiteralPath (Join-Path $fx 'shadow.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $e = Get-Content -LiteralPath (Join-Path $q 'rL\t-leg.json') -Raw | ConvertFrom-Json
    Assert-True ($rows[0].status -eq 'deferred_no_spec' -and $e.status -eq 'processed_deferred') "status=$($rows[0].status) entry=$($e.status)"
    Assert-True (-not (Test-Path -LiteralPath $launchLog)) 'wrapper launched for deferred_no_spec'
    Assert-BytesEqual $k3b ([IO.File]::ReadAllBytes($k3)) 'k3'
    Assert-BytesEqual $opb ([IO.File]::ReadAllBytes($op)) 'opus'
  }

  Case 'fake wrappers => blinded diffs, sealed reveal, scores, one v8 row provenance' {
    $fx = Join-Path $temp 'v8'; $q = Join-Path $fx 'q'; New-Item -ItemType Directory -Force -Path $q | Out-Null
    $r = EnqSpec @{ RunId='rV'; TaskId='t-v8'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sV'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='6'; JobKind='generic' }
    $env:FAKE_SHADOW_MODE = 'tie5'
    $ledger = Join-Path $fx 'BENCH-shadow.jsonl'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q -RepoRoot $repo -LedgerPath $ledger -LaneSpecPath $laneSpec
    $rows = @(Get-Content -LiteralPath $ledger | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($rows.Count -eq 1) "row count=$($rows.Count)"
    $row = $rows[0]
    Assert-True ($row.status -eq 'graded' -and $row.critical_path_delay_seconds -eq 0 -and $row.adopted_into_run -eq $false) 'provenance flags'
    Assert-True ($row.schema_version -eq '8' -and $row.rubric -eq 'deterministic_partial' -and $row.max_score -eq 90) 'rubric fields'
    Assert-True ($null -ne $row.reveal_path -and (Test-Path -LiteralPath $row.reveal_path)) 'reveal missing'
    $reveal = Get-Content -LiteralPath $row.reveal_path -Raw | ConvertFrom-Json
    Assert-True ($null -ne $reveal.blind_mapping.candidate_a -and $null -ne $reveal.blind_mapping.candidate_b) 'blind mapping'
    $blindRoot = Join-Path (Split-Path -Parent $row.reveal_path | Split-Path -Parent) 'blind'
    Assert-True ((Test-Path (Join-Path $blindRoot 'candidate-a.diff')) -and (Test-Path (Join-Path $blindRoot 'candidate-b.diff'))) 'blind diffs'
    Assert-True ($row.sample_seed -and $null -ne $row.selection_probability) 'sampling provenance'
    # B4: blind packet must NOT echo lane-spec identity; sealed reveal HAS requested_model.
    $blindText = [IO.File]::ReadAllText((Join-Path $blindRoot 'packet.json'))
    Assert-True ($blindText -notmatch 'requested_model') 'blind packet leaks requested_model'
    Assert-True ($blindText -notmatch '"wrapper"') 'blind packet leaks wrapper'
    Assert-True ($null -ne $reveal.requested_model -and $reveal.requested_model.primary -and $reveal.requested_model.challenger) 'reveal missing requested_model'
  }

  Case 'tie boundary delta 5.00 tie; ineligible cannot win; both-ineligible no_contest' {
    # Equal content => same score => tie (delta 0 <= 5)
    $fx = Join-Path $temp 'tie'; $q = Join-Path $fx 'q'; New-Item -ItemType Directory -Force -Path $q | Out-Null
    $r = EnqSpec @{ RunId='rT'; TaskId='t-tie'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sT'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='6' }
    $env:FAKE_SHADOW_MODE = 'tie5'
    $out = Join-Path $fx 'out'
    $c = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $r.queue_path -RepoRoot $repo -OutputDirectory $out -LaneSpecPath $laneSpec) -join "`n") | ConvertFrom-Json
    Assert-True ($c.result -eq 'tie' -and $true -eq $c.success) "tie got $($c.result)"
    $delta = [math]::Abs([double]$c.scores.primary.total - [double]$c.scores.challenger.total)
    Assert-True ($delta -le 5.0) "delta=$delta"

    # Failed-gate primary cannot win even if we would prefer it: primary BAD, challenger ok
    $fx2 = Join-Path $temp 'inelig'; $q2 = Join-Path $fx2 'q'; New-Item -ItemType Directory -Force -Path $q2 | Out-Null
    $r2 = EnqSpec @{ RunId='rI'; TaskId='t-in'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sI'; Challenger='grok'; QueueRoot=$q2; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='6' }
    $env:FAKE_SHADOW_MODE = 'fail_gate'; $env:FAKE_FAIL_LANE = 'terra'
    $c2 = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $r2.queue_path -RepoRoot $repo -OutputDirectory (Join-Path $fx2 'out') -LaneSpecPath $laneSpec) -join "`n") | ConvertFrom-Json
    Assert-True ($c2.result -eq 'challenger' -and $c2.scores.primary.hard_ineligible -eq $true) "inelig win? $($c2.result) prim=$($c2.scores.primary | ConvertTo-Json -Compress)"

    # Both scope-violate => no_contest
    $fx3 = Join-Path $temp 'both'; $q3 = Join-Path $fx3 'q'; New-Item -ItemType Directory -Force -Path $q3 | Out-Null
    $r3 = EnqSpec @{ RunId='rB'; TaskId='t-both'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sB'; Challenger='grok'; QueueRoot=$q3; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='6' }
    $env:FAKE_SHADOW_MODE = 'scope'; $env:FAKE_FAIL_LANE = ''
    $c3 = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $r3.queue_path -RepoRoot $repo -OutputDirectory (Join-Path $fx3 'out') -LaneSpecPath $laneSpec) -join "`n") | ConvertFrom-Json
    Assert-True ($c3.result -eq 'no_contest' -and $c3.success -eq $false -and $c3.terminal -eq $true) "both-inelig=$($c3 | ConvertTo-Json -Compress)"
  }

  Case 'timeout arm => no_contest; entry stays pending; zero qualification' {
    $fx = Join-Path $temp 'to'; $q = Join-Path $fx 'q'; $led = Join-Path $fx 'led'
    New-Item -ItemType Directory -Force -Path $q,$led | Out-Null
    $k3 = Join-Path $led 'BENCH-k3-qualification.jsonl'; $op = Join-Path $led 'BENCH-opus5-pairs.jsonl'
    [IO.File]::WriteAllText($k3, '', $utf8); [IO.File]::WriteAllText($op, '', $utf8)
    $k3b = [IO.File]::ReadAllBytes($k3); $opb = [IO.File]::ReadAllBytes($op)
    $r = EnqSpec @{ RunId='rTo'; TaskId='t-to'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sTo'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='2'; JobKind='k3_full_review' }
    $env:FAKE_SHADOW_MODE = 'timeout'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q -RepoRoot $repo -LedgerPath (Join-Path $fx 'sh.jsonl') -LedgerRoot $led -LaneSpecPath $laneSpec
    $e = Get-Content -LiteralPath $r.queue_path -Raw | ConvertFrom-Json
    $rows = @(Get-Content -LiteralPath (Join-Path $fx 'sh.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($e.status -eq 'pending') "entry status=$($e.status)"
    Assert-True ($rows.Count -ge 1 -and $rows[-1].status -eq 'no_contest') "ledger=$($rows[-1].status)"
    Assert-BytesEqual $k3b ([IO.File]::ReadAllBytes($k3)) 'k3 timeout'
    Assert-BytesEqual $opb ([IO.File]::ReadAllBytes($op)) 'opus timeout'
  }

  Case 'non-success completion never fires Write-QualificationTrack' {
    $fx = Join-Path $temp 'ns'; $q = Join-Path $fx 'q'; $led = Join-Path $fx 'led'
    New-Item -ItemType Directory -Force -Path $q,$led | Out-Null
    $k3 = Join-Path $led 'BENCH-k3-qualification.jsonl'; $op = Join-Path $led 'BENCH-opus5-pairs.jsonl'
    [IO.File]::WriteAllText($k3, '', $utf8); [IO.File]::WriteAllText($op, '', $utf8)
    $k3b = [IO.File]::ReadAllBytes($k3); $opb = [IO.File]::ReadAllBytes($op)
    $null = EnqSpec @{ RunId='rNs'; TaskId='t-ns'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sNs'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='4'; JobKind='opus5_pair' }
    $inj = Join-Path $fx 'inj.json'
    Write-Json $inj @{ task_id='t-ns'; kind='opus5_pair'; success=$false; wall_seconds=3 }
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q -RepoRoot $repo -LedgerPath (Join-Path $fx 'sh.jsonl') -LedgerRoot $led -InjectedCompletionPath $inj
    Assert-BytesEqual $k3b ([IO.File]::ReadAllBytes($k3)) 'k3 nonsuccess'
    Assert-BytesEqual $opb ([IO.File]::ReadAllBytes($op)) 'opus nonsuccess'
  }

  Case 'concurrent replay ledger appends all parse' {
    $fx = Join-Path $temp 'conc'; $ledger = Join-Path $fx 'BENCH-shadow.jsonl'
    $env:FAKE_SHADOW_MODE = 'tie5'
    $procs = @()
    for ($i = 0; $i -lt 3; $i++) {
      $qi = Join-Path $fx "cq$i"; New-Item -ItemType Directory -Force -Path $qi | Out-Null
      $null = EnqSpec @{ RunId="rX$i"; TaskId="t-x$i"; TaskStratum='standard'; BaseSha=$baseSha; Seed="sX$i"; Challenger='grok'; QueueRoot=$qi; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='4' }
      $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -QueueRoot "{1}" -RepoRoot "{2}" -LedgerPath "{3}" -LaneSpecPath "{4}"' -f $start, $qi, $repo, $ledger, $laneSpec
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = 'powershell.exe'; $psi.Arguments = $argLine
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $procs += [Diagnostics.Process]::Start($psi)
    }
    foreach ($p in $procs) {
      if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch {}; throw 'concurrent timeout' }
      Assert-True ($p.ExitCode -eq 0) "exit $($p.ExitCode) err=$($p.StandardError.ReadToEnd())"
    }
    $lines = @(Get-Content -LiteralPath $ledger | Where-Object { $_ })
    Assert-True ($lines.Count -eq 3) "lines=$($lines.Count)"
    foreach ($line in $lines) { $null = $line | ConvertFrom-Json }
  }
}
finally {
  $env:FAKE_SHADOW_MODE = ''; $env:FAKE_FAIL_LANE = ''
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
