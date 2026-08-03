$ErrorActionPreference = 'Stop'
$enqueue = Join-Path $PSScriptRoot 'Enqueue-FleetShadow.ps1'
$start = Join-Path $PSScriptRoot 'Start-FleetAutoShadow.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-shadow-test-' + [guid]::NewGuid().ToString('n'))
$repo = Join-Path $temp 'repo'
$queue = Join-Path $temp 'shadow-queue'
$ledger = Join-Path $temp 'BENCH-shadow.jsonl'
$passed = 0; $failed = 0

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }
function Enq([hashtable]$extra) {
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$enqueue,'-RunId','run1','-TaskStratum','standard','-Seed','seed-123','-Challenger','terra','-QueueRoot',$queue) + @($extra.GetEnumerator() | ForEach-Object { @("-$($_.Key)", [string]$_.Value) }) | ForEach-Object { $_ }
  ($(& powershell.exe @args) -join "`n") | ConvertFrom-Json
}

try {
  New-Item -ItemType Directory -Force -Path $repo | Out-Null
  & git -C $repo init -q; & git -C $repo config user.name t; & git -C $repo config user.email t@t.invalid
  [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'x'); & git -C $repo add .; & git -C $repo commit -q -m base | Out-Null
  $baseSha = (& git -C $repo rev-parse HEAD).Trim()

  Case 'Force enqueue creates a pending entry with zero critical-path delay' {
    $r = Enq @{ TaskId='t1'; BaseSha=$baseSha; Force=$true }
    Assert-True ($r.sampled -eq $true -and (Test-Path -LiteralPath $r.queue_path)) 'no queue entry created'
    $e = Get-Content -LiteralPath $r.queue_path -Raw | ConvertFrom-Json
    Assert-True ($e.status -eq 'pending' -and $e.critical_path_delay_seconds -eq 0 -and $e.shadow_mode -eq 'post_hoc_async') 'entry shape wrong'
  }
  Case 'p=0 is never sampled; p=1 always sampled; draw is deterministic' {
    $skip = Enq @{ TaskId='t2'; BaseSha=$baseSha; PShadow='0.0' }
    $take = Enq @{ TaskId='t2'; BaseSha=$baseSha; PShadow='1.0' }
    $again = Enq @{ TaskId='t2'; BaseSha=$baseSha; PShadow='1.0' }
    Assert-True ($skip.sampled -eq $false -and $skip.shadow_skipped_reason -eq 'not_drawn') 'p=0 was sampled'
    Assert-True ($take.sampled -eq $true) 'p=1 not sampled'
    Assert-True ($take.draw_value -eq $again.draw_value) 'draw not deterministic for same seed+task'
  }
  Case 'enqueue is idempotent per task' {
    $first = Enq @{ TaskId='t3'; BaseSha=$baseSha; Force=$true }
    $second = Enq @{ TaskId='t3'; BaseSha=$baseSha; Force=$true }
    Assert-True ($second.already_queued -eq $true) 'second enqueue was not idempotent'
  }
  Case 'consumer -NoModel processes pending and writes a delay-0 ledger row' {
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $queue -RepoRoot $repo -LedgerPath $ledger -NoModel | Out-String | ForEach-Object { $_.Trim() }) | ConvertFrom-Json
    Assert-True ($out.count -ge 1) 'nothing processed'
    $rows = @(Get-Content -LiteralPath $ledger | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $dry = @($rows | Where-Object { $_.status -eq 'deferred_no_model' })
    Assert-True ($dry.Count -ge 1 -and ($dry | ForEach-Object { $_.critical_path_delay_seconds }) -notcontains 1) 'no delay-0 dry ledger row'
  }
  Case 'base_drift is excluded, never graded' {
    $drift = Enq @{ TaskId='t4'; BaseSha=('0' * 40); Force=$true }
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $queue -RepoRoot $repo -LedgerPath $ledger -NoModel | Out-Null
    $rows = @(Get-Content -LiteralPath $ledger | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $excluded = @($rows | Where-Object { $_.task_id -eq 't4' })
    Assert-True ($excluded.Count -ge 1 -and $excluded[0].status -eq 'excluded' -and $excluded[0].base_drift -eq $true -and $excluded[0].exclusion_reason -eq 'base_drift') 'base_drift not excluded'
  }
  Case 'legacy live path without task_spec is deferred_no_spec (never graded)' {
    $ql = Join-Path $temp 'shadow-queue2'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enqueue -RunId run1 -TaskId t5 -TaskStratum standard -Seed seed-123 -Challenger terra -BaseSha $baseSha -Force -QueueRoot $ql | Out-Null
    $ledger2 = Join-Path $temp 'BENCH-shadow2.jsonl'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $ql -RepoRoot $repo -LedgerPath $ledger2 | Out-Null
    $rows = @(Get-Content -LiteralPath $ledger2 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $t5 = @($rows | Where-Object { $_.task_id -eq 't5' })
    $entry = Get-Content -LiteralPath (Join-Path $ql 'run1\t5.json') -Raw | ConvertFrom-Json
    Assert-True ($t5.Count -ge 1 -and $t5[0].status -eq 'deferred_no_spec' -and $entry.status -eq 'processed_deferred') 'legacy path falsely claimed graded or left pending'
  }
  Case 'shared queue: two consumers claim one entry exactly once' {
    $qc = Join-Path $temp 'shadow-queue-claim'
    $ledC = Join-Path $temp 'BENCH-shadow-claim.jsonl'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enqueue -RunId runC -TaskId t-claim -TaskStratum standard -Seed seed-123 -Challenger terra -BaseSha $baseSha -Force -QueueRoot $qc | Out-Null
    $entryPath = Join-Path $qc 'runC\t-claim.json'
    Assert-True (Test-Path -LiteralPath $entryPath) 'claim entry missing'
    $procs = @()
    for ($i = 0; $i -lt 2; $i++) {
      $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -QueueRoot "{1}" -RepoRoot "{2}" -LedgerPath "{3}" -NoModel' -f $start, $qc, $repo, $ledC
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = 'powershell.exe'; $psi.Arguments = $argLine
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $procs += [Diagnostics.Process]::Start($psi)
    }
    foreach ($p in $procs) {
      if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; throw 'claim consumer timed out' }
      Assert-True ($p.ExitCode -eq 0) "claim consumer exit $($p.ExitCode) err=$($p.StandardError.ReadToEnd())"
    }
    $rows = @()
    if (Test-Path -LiteralPath $ledC) {
      $rows = @(Get-Content -LiteralPath $ledC | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    $forTask = @($rows | Where-Object { $_.task_id -eq 't-claim' })
    Assert-True ($forTask.Count -eq 1) "expected exactly 1 ledger row, got $($forTask.Count)"
    Assert-True ($forTask[0].status -eq 'deferred_no_model') "row status=$($forTask[0].status)"
    $entry = Get-Content -LiteralPath $entryPath -Raw | ConvertFrom-Json
    Assert-True ($entry.status -eq 'processed_dry') "entry status=$($entry.status) (not dual-processed)"
  }
  Case 'InjectedCompletionPath refused without FLEET_SHADOW_TEST_INJECT' {
    $qi = Join-Path $temp 'shadow-queue-inj'
    $ledI = Join-Path $temp 'BENCH-shadow-inj.jsonl'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enqueue -RunId runI -TaskId t-inj -TaskStratum standard -Seed seed-123 -Challenger terra -BaseSha $baseSha -Force -QueueRoot $qi | Out-Null
    $inj = Join-Path $temp 'forge.json'
    [IO.File]::WriteAllText($inj, '{"task_id":"t-inj","kind":"k3_full_review","success":true,"wall_seconds":3}')
    Remove-Item Env:\FLEET_SHADOW_TEST_INJECT -ErrorAction SilentlyContinue
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $qi -RepoRoot $repo -LedgerPath $ledI -InjectedCompletionPath $inj | Out-String).Trim() | ConvertFrom-Json
    Assert-True ($out.injected_completion_refused -eq $true) "inject not refused: $($out | ConvertTo-Json -Compress)"
    $rows = @(Get-Content -LiteralPath $ledI | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $t = @($rows | Where-Object { $_.task_id -eq 't-inj' })
    Assert-True ($t.Count -eq 1 -and $t[0].status -eq 'deferred_no_spec') 'forge path graded without env gate'
  }
  Case 'partial snapshot (spec present, wall missing) is deferred_no_spec' {
    $qp = Join-Path $temp 'shadow-queue-partial'
    New-Item -ItemType Directory -Force -Path (Join-Path $qp 'runP') | Out-Null
    $partial = [ordered]@{
      schema_version='1'; status='pending'; run_id='runP'; task_id='t-partial'; task_stratum='standard'
      base_sha=$baseSha; challenger='terra'; sample_seed='s'; selection_probability=1
      estimand='optimized_system'; coverage_scope='x'; shadow_mode='post_hoc_async'
      adopted_into_run=$false; critical_path_delay_seconds=0; qualification_job_kind='generic'
      task_spec=@{ id='t-partial'; prompt='do x'; allowed_paths=@('a.txt'); gate_commands=@() }
      primary_lane=$null; primary_wall_seconds=$null
    }
    $ep = Join-Path $qp 'runP\t-partial.json'
    [IO.File]::WriteAllText($ep, ($partial | ConvertTo-Json -Depth 6))
    $ledP = Join-Path $temp 'BENCH-shadow-partial.jsonl'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $qp -RepoRoot $repo -LedgerPath $ledP | Out-Null
    $rows = @(Get-Content -LiteralPath $ledP | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $t = @($rows | Where-Object { $_.task_id -eq 't-partial' })
    $entry = Get-Content -LiteralPath $ep -Raw | ConvertFrom-Json
    Assert-True ($t.Count -eq 1 -and $t[0].status -eq 'deferred_no_spec' -and $entry.status -eq 'processed_deferred') 'partial snapshot not deferred_no_spec'
  }
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
