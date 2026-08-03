# Offline suite for Enqueue-FleetShadow stratified boost. Temp fixtures only;
# never touches real BENCH-*.jsonl. Exit 0 all pass / 1 any fail.
$ErrorActionPreference = 'Stop'
$enqueue = Join-Path $PSScriptRoot 'Enqueue-FleetShadow.ps1'
$start = Join-Path $PSScriptRoot 'Start-FleetAutoShadow.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-enq-boost-' + [guid]::NewGuid().ToString('n'))
$passed = 0; $failed = 0
$utf8 = New-Object Text.UTF8Encoding($false)
$baseSha = 'a' * 40

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }
function Write-Json([string]$Path, $Obj) {
  $dir = Split-Path -Parent $Path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 8), $utf8)
}
function Write-Ledger([string]$Path, [string[]]$Lines) {
  $dir = Split-Path -Parent $Path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $utf8)
}
function New-Policy([string]$Root, [bool]$Enabled = $true, [int]$Cap = 2, [int]$K3Target = 10, [int]$OpusTarget = 5) {
  $p = @{ schema_version='1'; auto_shadow=@{ default_p_shadow=0.15; stratified_boost=@{
    enabled=$Enabled; daily_boost_cap=$Cap; strata=@(
      @{ name='k3-qualification'; n_target=$K3Target; ledger='BENCH-k3-qualification.jsonl'; n_current_source='dispatched_full_rows'; job_kind='k3_full_review' }
      @{ name='opus5-pairs'; n_target=$OpusTarget; ledger='BENCH-opus5-pairs.jsonl'; n_current_source='valid_rows'; job_kind='opus5_pair' }
    ) } } }
  $path = Join-Path $Root 'fleet-policy.json'; Write-Json $path $p; return $path
}
function Enq([hashtable]$extra) {
  $defaults = @{ RunId='run1'; TaskStratum='standard'; Seed='seed-boost'; Challenger='terra'; BaseSha=$baseSha }
  foreach ($k in $defaults.Keys) { if (-not $extra.ContainsKey($k)) { $extra[$k] = $defaults[$k] } }
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$enqueue)
  foreach ($k in $extra.Keys) {
    $v = $extra[$k]
    if ($k -eq 'Force' -and ($v -eq $true -or "$v" -eq 'true' -or $v -is [switch])) { $args += '-Force' }
    else { $args += @("-$k", [string]$v) }
  }
  ($(& powershell.exe @args) -join "`n") | ConvertFrom-Json
}
function Prov-Ok($r) {
  foreach ($n in @('qualification_stratum','qualification_n_current','qualification_n_target','qualification_job_kind','base_p_shadow','effective_p_shadow','boost_applied','sampling_rate_source','daily_boost_cap','daily_boost_used','boost_suppressed_reason')) {
    if ($null -eq $r.PSObject.Properties[$n]) { throw "missing provenance field $n" }
  }
}
function New-GitRepo([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  & git -C $Path init -q; & git -C $Path config user.name t; & git -C $Path config user.email t@t.invalid
  [IO.File]::WriteAllText((Join-Path $Path 'a.txt'), 'x'); & git -C $Path add .; & git -C $Path commit -q -m base | Out-Null
  return (& git -C $Path rev-parse HEAD).Trim()
}
function Fx([string]$Name) {
  $fx = Join-Path $temp $Name; $q = Join-Path $fx 'queue'; $led = Join-Path $fx 'ledgers'
  New-Item -ItemType Directory -Force -Path $led,$q | Out-Null
  return @{ fx=$fx; q=$q; led=$led; pol=(New-Policy $fx) }
}

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null

  Case 'under-target ledger -> effective p=1.0 and boost_applied=true' {
    $f = Fx 'under'
    Write-Ledger (Join-Path $f.led 'BENCH-k3-qualification.jsonl') @('{"run_id":"r1","review_tier":"FULL","dispatched":true}')
    Write-Ledger (Join-Path $f.led 'BENCH-opus5-pairs.jsonl') @('{"pair_id":"p1"}')
    $r = Enq @{ TaskId='t-under'; QueueRoot=$f.q; PolicyPath=$f.pol; LedgerRoot=$f.led; JobKind='k3_full_review' }
    Assert-True ($r.effective_p_shadow -eq 1.0 -and $r.boost_applied -eq $true -and $r.sampled -eq $true) "p=$($r.effective_p_shadow) boost=$($r.boost_applied)"
    Assert-True ($r.sampling_rate_source -eq 'stratified_boost' -and $r.qualification_stratum -eq 'k3-qualification') "src=$($r.sampling_rate_source)"
    Assert-True ($r.qualification_n_current -eq 1 -and $r.qualification_n_target -eq 10 -and $r.qualification_job_kind -eq 'k3_full_review') "n/kind"
    $e = Get-Content -LiteralPath $r.queue_path -Raw | ConvertFrom-Json
    Assert-True ($e.boost_applied -eq $true -and $e.effective_p_shadow -eq 1.0 -and $e.qualification_job_kind -eq 'k3_full_review') 'queue provenance'
  }
  Case 'target-filled ledger -> effective p=0.15 and boost_applied=false' {
    $fx = Join-Path $temp 'filled'; $q = Join-Path $fx 'queue'; $led = Join-Path $fx 'ledgers'
    New-Item -ItemType Directory -Force -Path $led,$q | Out-Null
    $pol = New-Policy $fx -K3Target 1 -OpusTarget 1
    Write-Ledger (Join-Path $led 'BENCH-k3-qualification.jsonl') @('{"run_id":"r1","review_tier":"FULL","dispatched":true}')
    Write-Ledger (Join-Path $led 'BENCH-opus5-pairs.jsonl') @('{"pair_id":"p1"}')
    $r = Enq @{ TaskId='t-filled'; QueueRoot=$q; PolicyPath=$pol; LedgerRoot=$led; JobKind='k3_full_review' }
    Assert-True ($r.effective_p_shadow -eq 0.15 -and $r.boost_applied -eq $false -and $r.sampling_rate_source -eq 'base_rate' -and $r.base_p_shadow -eq 0.15) "filled=$($r.effective_p_shadow)"
  }
  Case 'cap reached (two UTC-day boosted entries) -> next decision base rate' {
    $fx = Join-Path $temp 'cap'; $q = Join-Path $fx 'queue'; $led = Join-Path $fx 'ledgers'
    New-Item -ItemType Directory -Force -Path $led,(Join-Path $q 'prior') | Out-Null
    $pol = New-Policy $fx -Cap 2; Write-Ledger (Join-Path $led 'BENCH-k3-qualification.jsonl') @()
    $now = [datetimeoffset]::UtcNow.ToString('o')
    foreach ($i in 1..2) { Write-Json (Join-Path $q "prior\boost$i.json") ([ordered]@{ schema_version='1'; status='pending'; boost_applied=$true; enqueued_at=$now; task_id="prior$i" }) }
    $r = Enq @{ TaskId='t-cap'; QueueRoot=$q; PolicyPath=$pol; LedgerRoot=$led; JobKind='k3_full_review' }
    Assert-True ($r.daily_boost_used -eq 2 -and $r.daily_boost_cap -eq 2 -and $r.boost_applied -eq $false) "used=$($r.daily_boost_used)"
    Assert-True ($r.effective_p_shadow -eq 0.15 -and $r.boost_suppressed_reason -eq 'daily_boost_cap' -and $r.sampling_rate_source -eq 'base_rate') "cap reason=$($r.boost_suppressed_reason)"
  }
  Case 'malformed ledger -> base rate + nonempty boost_suppressed_reason' {
    $f = Fx 'mal'
    [IO.File]::WriteAllText((Join-Path $f.led 'BENCH-k3-qualification.jsonl'), "{not-json`n", $utf8)
    Write-Ledger (Join-Path $f.led 'BENCH-opus5-pairs.jsonl') @('{"pair_id":"1"}','{"pair_id":"2"}','{"pair_id":"3"}','{"pair_id":"4"}','{"pair_id":"5"}')
    $r = Enq @{ TaskId='t-mal'; QueueRoot=$f.q; PolicyPath=$f.pol; LedgerRoot=$f.led; JobKind='k3_full_review' }
    Assert-True ($r.effective_p_shadow -eq 0.15 -and $r.boost_applied -eq $false) "mal p=$($r.effective_p_shadow)"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$r.boost_suppressed_reason) -and [string]$r.boost_suppressed_reason -match 'malformed') "reason=$($r.boost_suppressed_reason)"
  }
  Case 'explicit override -> recorded as override, no boost' {
    $f = Fx 'ovr'
    $r = Enq @{ TaskId='t-ovr'; QueueRoot=$f.q; PolicyPath=$f.pol; LedgerRoot=$f.led; JobKind='k3_full_review'; PShadow='0.0' }
    Assert-True ($r.effective_p_shadow -eq 0.0 -and $r.boost_applied -eq $false -and $r.sampled -eq $false) "ovr p=$($r.effective_p_shadow)"
    Assert-True ($r.boost_suppressed_reason -eq 'explicit_override' -and $r.sampling_rate_source -eq 'base_rate') "ovr reason=$($r.boost_suppressed_reason)"
  }
  Case 'base draw unaffected when stratified_boost.enabled=false' {
    $fx = Join-Path $temp 'off'; $q = Join-Path $fx 'queue'; $led = Join-Path $fx 'ledgers'
    New-Item -ItemType Directory -Force -Path $led,$q | Out-Null
    $pol = New-Policy $fx -Enabled $false
    $r = Enq @{ TaskId='t-off'; QueueRoot=$q; PolicyPath=$pol; LedgerRoot=$led; JobKind='k3_full_review' }
    Assert-True ($r.effective_p_shadow -eq 0.15 -and $r.boost_applied -eq $false -and $r.sampling_rate_source -eq 'base_rate') "off p=$($r.effective_p_shadow)"
    Assert-True ($r.boost_suppressed_reason -eq 'stratified_boost_disabled') "reason=$($r.boost_suppressed_reason)"
  }
  Case 'provenance fields all present on the decision object' {
    $f = Fx 'prov'
    $r = Enq @{ TaskId='t-prov'; QueueRoot=$f.q; PolicyPath=$f.pol; LedgerRoot=$f.led; Force=$true }
    Prov-Ok $r
    Assert-True ($r.sampling_rate_source -eq 'forced_canary' -and $r.boost_applied -eq $false -and $r.base_p_shadow -eq 0.15 -and $r.qualification_job_kind -eq 'generic') 'force fields'
    Prov-Ok (Enq @{ TaskId='t-prov-skip'; QueueRoot=$f.q; PolicyPath=$f.pol; LedgerRoot=$f.led; PShadow='0.0' })
  }
  Case 'k3-kind job under target boosts' {
    $f = Fx 'k3boost'
    Write-Ledger (Join-Path $f.led 'BENCH-k3-qualification.jsonl') @(); Write-Ledger (Join-Path $f.led 'BENCH-opus5-pairs.jsonl') @('{"pair_id":"p1"}')
    $r = Enq @{ TaskId='t-k3'; QueueRoot=$f.q; PolicyPath=$f.pol; LedgerRoot=$f.led; JobKind='k3_full_review' }
    Assert-True ($r.boost_applied -eq $true -and $r.qualification_stratum -eq 'k3-qualification' -and $r.qualification_job_kind -eq 'k3_full_review' -and $r.effective_p_shadow -eq 1.0) 'k3 boost'
  }
  Case 'generic job does NOT boost even when strata under-filled' {
    $f = Fx 'generic'
    Write-Ledger (Join-Path $f.led 'BENCH-k3-qualification.jsonl') @(); Write-Ledger (Join-Path $f.led 'BENCH-opus5-pairs.jsonl') @()
    $r = Enq @{ TaskId='t-gen'; QueueRoot=$f.q; PolicyPath=$f.pol; LedgerRoot=$f.led; JobKind='generic' }
    Assert-True ($r.boost_applied -eq $false -and $r.effective_p_shadow -eq 0.15 -and $r.sampling_rate_source -eq 'base_rate') "gen p=$($r.effective_p_shadow)"
    Assert-True ($r.boost_suppressed_reason -eq 'job_kind_ineligible' -and $r.qualification_job_kind -eq 'generic') "reason=$($r.boost_suppressed_reason)"
  }
  Case 'opus-kind job routes to opus stratum' {
    $f = Fx 'opus'
    Write-Ledger (Join-Path $f.led 'BENCH-k3-qualification.jsonl') @(); Write-Ledger (Join-Path $f.led 'BENCH-opus5-pairs.jsonl') @('{"pair_id":"p1"}')
    $r = Enq @{ TaskId='t-opus'; QueueRoot=$f.q; PolicyPath=$f.pol; LedgerRoot=$f.led; JobKind='opus5_pair' }
    Assert-True ($r.boost_applied -eq $true -and $r.qualification_stratum -eq 'opus5-pairs' -and $r.qualification_job_kind -eq 'opus5_pair') "stratum=$($r.qualification_stratum)"
    Assert-True ($r.qualification_n_current -eq 1 -and $r.qualification_n_target -eq 5) "n=$($r.qualification_n_current)"
  }
  Case 'malformed first stratum retains reason when healthy stratum boosts' {
    $f = Fx 'malboost'
    [IO.File]::WriteAllText((Join-Path $f.led 'BENCH-k3-qualification.jsonl'), "{not-json`n", $utf8)
    Write-Ledger (Join-Path $f.led 'BENCH-opus5-pairs.jsonl') @('{"pair_id":"p1"}')
    $r = Enq @{ TaskId='t-malboost'; QueueRoot=$f.q; PolicyPath=$f.pol; LedgerRoot=$f.led; JobKind='opus5_pair' }
    Assert-True ($r.boost_applied -eq $true -and $r.sampling_rate_source -eq 'stratified_boost') "boost=$($r.boost_applied) src=$($r.sampling_rate_source)"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$r.boost_suppressed_reason) -and [string]$r.boost_suppressed_reason -match 'malformed' -and [string]$r.boost_suppressed_reason -match 'BENCH-k3') "reason=$($r.boost_suppressed_reason)"
  }
  Case 'concurrent enqueues never exceed daily boost cap' {
    $fx = Join-Path $temp 'conc space'; $q = Join-Path $fx 'queue'; $led = Join-Path $fx 'ledgers'
    New-Item -ItemType Directory -Force -Path $led,$q | Out-Null
    $pol = New-Policy $fx -Cap 2
    Write-Ledger (Join-Path $led 'BENCH-k3-qualification.jsonl') @(); Write-Ledger (Join-Path $led 'BENCH-opus5-pairs.jsonl') @()
    $procs = @()
    for ($i = 0; $i -lt 4; $i++) {
      $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RunId "run1" -TaskId "t-c{1}" -TaskStratum standard -BaseSha "{2}" -Seed "seed-boost" -Challenger terra -QueueRoot "{3}" -PolicyPath "{4}" -LedgerRoot "{5}" -JobKind k3_full_review' -f $enqueue, $i, $baseSha, $q, $pol, $led
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = 'powershell.exe'; $psi.Arguments = $argLine
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $procs += [Diagnostics.Process]::Start($psi)
    }
    $deadline = (Get-Date).AddSeconds(90); $decisions = @()
    foreach ($p in $procs) {
      $rem = [int][math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds)
      if (-not $p.WaitForExit($rem)) { try { $p.Kill() } catch { }; throw "concurrent enqueue timed out pid=$($p.Id)" }
      $raw = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
      Assert-True ($p.ExitCode -eq 0) "concurrent exit $($p.ExitCode) err=$err raw=$raw"
      $r = $raw | ConvertFrom-Json; Prov-Ok $r; $decisions += $r
    }
    $boosted = @($decisions | Where-Object { $_.boost_applied -eq $true }).Count
    Assert-True ($boosted -le 2) "boosted decisions=$boosted (cap 2)"
    $qBoost = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $q -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      try { $e = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; if ($e.boost_applied -eq $true) { $qBoost++ } } catch { }
    }
    Assert-True ($qBoost -le 2) "boosted queue rows=$qBoost (cap 2)"
  }
  function Assert-BytesEqual([byte[]]$A, [byte[]]$B, [string]$Label) {
    Assert-True ($A.Length -eq $B.Length) "$Label length $($A.Length) vs $($B.Length)"
    for ($i = 0; $i -lt $A.Length; $i++) { Assert-True ($A[$i] -eq $B[$i]) "$Label byte $i changed" }
  }
  Case 'no-model and deferred outcomes do not increment qualification ledgers' {
    $fx = Join-Path $temp 'lednone'; $q = Join-Path $fx 'queue'; $led = Join-Path $fx 'ledgers'; $repo = Join-Path $fx 'repo'
    New-Item -ItemType Directory -Force -Path $led,$q | Out-Null
    $sha = New-GitRepo $repo; $pol = New-Policy $fx
    $k3Path = Join-Path $led 'BENCH-k3-qualification.jsonl'; $opusPath = Join-Path $led 'BENCH-opus5-pairs.jsonl'
    Write-Ledger $k3Path @(); Write-Ledger $opusPath @()
    $k3Before = [IO.File]::ReadAllBytes($k3Path); $opusBefore = [IO.File]::ReadAllBytes($opusPath)
    $rK = Enq @{ TaskId='t-nomodel'; QueueRoot=$q; PolicyPath=$pol; LedgerRoot=$led; JobKind='k3_full_review'; BaseSha=$sha; Force=$true }
    Assert-True ($rK.sampled -eq $true) 'k3 enqueue failed'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q -RepoRoot $repo -LedgerPath (Join-Path $fx 'shadow-nm.jsonl') -LedgerRoot $led -NoModel
    Assert-BytesEqual $k3Before ([IO.File]::ReadAllBytes($k3Path)) 'k3 after NoModel'
    Assert-BytesEqual $opusBefore ([IO.File]::ReadAllBytes($opusPath)) 'opus after NoModel'
    $q2 = Join-Path $fx 'queue-live'; New-Item -ItemType Directory -Force -Path $q2 | Out-Null
    $rL = Enq @{ TaskId='t-live'; QueueRoot=$q2; PolicyPath=$pol; LedgerRoot=$led; JobKind='opus5_pair'; BaseSha=$sha; Force=$true; RunId='run-live' }
    Assert-True ($rL.sampled -eq $true) 'live enqueue failed'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q2 -RepoRoot $repo -LedgerPath (Join-Path $fx 'shadow-live.jsonl') -LedgerRoot $led
    Assert-BytesEqual $k3Before ([IO.File]::ReadAllBytes($k3Path)) 'k3 after deferred_no_spec'
    Assert-BytesEqual $opusBefore ([IO.File]::ReadAllBytes($opusPath)) 'opus after deferred_no_spec'
  }
  Case 'successful K3 FULL completion increments only K3 qualification ledger' {
    $fx = Join-Path $temp 'ledk3'; $q = Join-Path $fx 'queue'; $led = Join-Path $fx 'ledgers'; $repo = Join-Path $fx 'repo'
    New-Item -ItemType Directory -Force -Path $led,$q | Out-Null
    $sha = New-GitRepo $repo; $pol = New-Policy $fx
    $k3Path = Join-Path $led 'BENCH-k3-qualification.jsonl'; $opusPath = Join-Path $led 'BENCH-opus5-pairs.jsonl'
    Write-Ledger $k3Path @(); Write-Ledger $opusPath @()
    $opusBefore = [IO.File]::ReadAllBytes($opusPath)
    $rK = Enq @{ TaskId='t-k3ok'; QueueRoot=$q; PolicyPath=$pol; LedgerRoot=$led; JobKind='k3_full_review'; BaseSha=$sha; Force=$true }
    Assert-True ($rK.sampled -eq $true) 'k3 enqueue failed'
    $inj = Join-Path $fx 'completion-k3.json'
    Write-Json $inj ([ordered]@{ task_id = 't-k3ok'; kind = 'k3_full_review'; success = $true; wall_seconds = 12 })
    $env:FLEET_SHADOW_TEST_INJECT = '1'
    try {
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q -RepoRoot $repo -LedgerPath (Join-Path $fx 'shadow-k3.jsonl') -LedgerRoot $led -InjectedCompletionPath $inj
    } finally { Remove-Item Env:\FLEET_SHADOW_TEST_INJECT -ErrorAction SilentlyContinue }
    $k3Lines = @((Get-Content -LiteralPath $k3Path | Where-Object { $_ }))
    Assert-True ($k3Lines.Count -eq 1) "k3 rows=$($k3Lines.Count)"
    $k3Row = $k3Lines[0] | ConvertFrom-Json
    Assert-True ($k3Row.dispatched -eq $true -and $k3Row.review_tier -eq 'FULL' -and [int]$k3Row.wall_seconds -eq 12) 'k3 row shape/wall'
    Assert-BytesEqual $opusBefore ([IO.File]::ReadAllBytes($opusPath)) 'opus mutated by k3 success'
  }
  Case 'successful Opus-5 pair completion increments only Opus qualification ledger' {
    $fx = Join-Path $temp 'ledopus'; $q = Join-Path $fx 'queue'; $led = Join-Path $fx 'ledgers'; $repo = Join-Path $fx 'repo'
    New-Item -ItemType Directory -Force -Path $led,$q | Out-Null
    $sha = New-GitRepo $repo; $pol = New-Policy $fx
    $k3Path = Join-Path $led 'BENCH-k3-qualification.jsonl'; $opusPath = Join-Path $led 'BENCH-opus5-pairs.jsonl'
    Write-Ledger $k3Path @(); Write-Ledger $opusPath @()
    $k3Before = [IO.File]::ReadAllBytes($k3Path)
    $rO = Enq @{ TaskId='t-opusok'; QueueRoot=$q; PolicyPath=$pol; LedgerRoot=$led; JobKind='opus5_pair'; BaseSha=$sha; Force=$true }
    Assert-True ($rO.sampled -eq $true) 'opus enqueue failed'
    $inj = Join-Path $fx 'completion-opus.json'
    Write-Json $inj ([ordered]@{ task_id = 't-opusok'; kind = 'opus5_pair'; success = $true; wall_seconds = 9 })
    $env:FLEET_SHADOW_TEST_INJECT = '1'
    try {
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q -RepoRoot $repo -LedgerPath (Join-Path $fx 'shadow-opus.jsonl') -LedgerRoot $led -InjectedCompletionPath $inj
    } finally { Remove-Item Env:\FLEET_SHADOW_TEST_INJECT -ErrorAction SilentlyContinue }
    $opusLines = @((Get-Content -LiteralPath $opusPath | Where-Object { $_ }))
    Assert-True ($opusLines.Count -eq 1) "opus rows=$($opusLines.Count)"
    $opusRow = $opusLines[0] | ConvertFrom-Json
    Assert-True ($opusRow.dispatched -eq $true -and [int]$opusRow.wall_seconds -eq 9) 'opus row shape/wall'
    Assert-BytesEqual $k3Before ([IO.File]::ReadAllBytes($k3Path)) 'k3 mutated by opus success'
  }
  Case 'TaskSpecJson publish rejects null/zero primary wall' {
    $f = Fx 'failclosed'
    $spec = '{"id":"t-fc","prompt":"x","allowed_paths":["a.txt"],"gate_commands":[]}'
    $threwNull = $false; $threwZero = $false
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enqueue -RunId run1 -TaskId t-fc-null -TaskStratum standard -Seed seed-boost -Challenger terra -BaseSha $baseSha -Force -QueueRoot $f.q -PolicyPath $f.pol -LedgerRoot $f.led -TaskSpecJson $spec -PrimaryLane terra 2>&1
      if ($LASTEXITCODE -ne 0) { $threwNull = $true }
    } catch { $threwNull = $true }
    try {
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enqueue -RunId run1 -TaskId t-fc-zero -TaskStratum standard -Seed seed-boost -Challenger terra -BaseSha $baseSha -Force -QueueRoot $f.q -PolicyPath $f.pol -LedgerRoot $f.led -TaskSpecJson $spec -PrimaryLane terra -PrimaryWallSeconds 0 2>&1
      if ($LASTEXITCODE -ne 0) { $threwZero = $true }
    } catch { $threwZero = $true }
    finally { $ErrorActionPreference = $oldEap }
    Assert-True $threwNull 'null wall should fail publish'
    Assert-True $threwZero 'wall=0 should fail publish'
  }
  Case 'partial-snapshot entry is deferred_no_spec with no qualification write' {
    $fx = Join-Path $temp 'partial'; $q = Join-Path $fx 'queue'; $led = Join-Path $fx 'ledgers'; $repo = Join-Path $fx 'repo'
    New-Item -ItemType Directory -Force -Path $led,(Join-Path $q 'runP') | Out-Null
    $sha = New-GitRepo $repo
    $k3Path = Join-Path $led 'BENCH-k3-qualification.jsonl'; $opusPath = Join-Path $led 'BENCH-opus5-pairs.jsonl'
    Write-Ledger $k3Path @(); Write-Ledger $opusPath @()
    $k3Before = [IO.File]::ReadAllBytes($k3Path); $opusBefore = [IO.File]::ReadAllBytes($opusPath)
    $partial = [ordered]@{
      schema_version='1'; status='pending'; run_id='runP'; task_id='t-part'; task_stratum='standard'
      base_sha=$sha; challenger='terra'; sample_seed='s'; selection_probability=1
      estimand='optimized_system'; coverage_scope='x'; shadow_mode='post_hoc_async'
      adopted_into_run=$false; critical_path_delay_seconds=0; qualification_job_kind='k3_full_review'
      task_spec=@{ id='t-part'; prompt='do x'; allowed_paths=@('a.txt'); gate_commands=@() }
      primary_lane='terra'; primary_wall_seconds=0
    }
    $ep = Join-Path $q 'runP\t-part.json'
    Write-Json $ep $partial
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q -RepoRoot $repo -LedgerPath (Join-Path $fx 'shadow-part.jsonl') -LedgerRoot $led
    $rows = @(Get-Content -LiteralPath (Join-Path $fx 'shadow-part.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $t = @($rows | Where-Object { $_.task_id -eq 't-part' })
    Assert-True ($t.Count -eq 1 -and $t[0].status -eq 'deferred_no_spec') "status=$($t[0].status)"
    Assert-BytesEqual $k3Before ([IO.File]::ReadAllBytes($k3Path)) 'k3 after partial'
    Assert-BytesEqual $opusBefore ([IO.File]::ReadAllBytes($opusPath)) 'opus after partial'
    $entry = Get-Content -LiteralPath $ep -Raw | ConvertFrom-Json
    Assert-True ($entry.status -eq 'processed_deferred') "entry=$($entry.status)"
  }
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
