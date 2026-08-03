# Offline suite for fleet canary manifest + Enqueue-FleetCanary.
# Temp fixture queue/policy only; never touches real .fleet/shadow-queue.
# Exit 0 all pass / 1 any fail.
$ErrorActionPreference = 'Stop'
$enqueue = Join-Path $PSScriptRoot 'Enqueue-FleetCanary.ps1'
$enqueueShadow = Join-Path $PSScriptRoot 'Enqueue-FleetShadow.ps1'
$start = Join-Path $PSScriptRoot 'Start-FleetAutoShadow.ps1'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$realManifest = Join-Path $repoRoot 'fleet-canaries.json'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-canary-test-' + [guid]::NewGuid().ToString('n'))
$passed = 0; $failed = 0
$utf8 = New-Object Text.UTF8Encoding($false)
$baseSha = 'a' * 40
$requiredFields = @('id','title','source','prompt','task_stratum','allowed_paths','mutation','gate_commands')

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }
function Write-Json([string]$Path, $Obj) {
  $dir = Split-Path -Parent $Path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 10), $utf8)
}
function New-CanaryPolicy([string]$Root, [bool]$Enabled = $true, [string]$ManifestRel = 'fleet-canaries.json', [int]$Repeat = 3) {
  $p = @{
    schema_version = '1'
    auto_shadow = @{
      default_p_shadow = 0.15
      canary_set = @{
        enabled = $Enabled
        manifest = $ManifestRel
        repeat_count = $Repeat
        tasks_per_batch = 1
        sole_ship_gate = $false
      }
      stratified_boost = @{ enabled = $false; daily_boost_cap = 2; strata = @() }
    }
  }
  $path = Join-Path $Root 'fleet-policy.json'
  Write-Json $path $p
  return $path
}
function Invoke-Enq([hashtable]$extra) {
  $runId = 'canary-run1'
  if ($extra.ContainsKey('RunId') -and -not [string]::IsNullOrWhiteSpace([string]$extra['RunId'])) {
    $runId = [string]$extra['RunId']
  }
  $shaArg = $baseSha
  if ($extra.ContainsKey('BaseSha') -and -not [string]::IsNullOrWhiteSpace([string]$extra['BaseSha'])) {
    $shaArg = [string]$extra['BaseSha']
  }
  $argv = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$enqueue,
    '-RunId',$runId,'-BaseSha',$shaArg
  )
  foreach ($k in $extra.Keys) {
    if ($k -eq 'RunId' -or $k -eq 'BaseSha') { continue }
    $v = $extra[$k]
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { continue }
    $argv += @("-$k", [string]$v)
  }
  $old = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $raw = & powershell.exe @argv 2>&1
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $old }
  $text = (($raw | ForEach-Object { "$_" }) -join "`n")
  return [pscustomobject]@{ ExitCode = $code; Raw = $text }
}
function Select-IdBySeed([string]$S, [string[]]$Ids) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($S)) }
  finally { $sha.Dispose() }
  $idx = [int]([BitConverter]::ToUInt32($hash, 0) % [uint32]$Ids.Count)
  return $Ids[$idx]
}

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null

  Case 'manifest: exactly 8 unique ids and required fields nonempty' {
    Assert-True (Test-Path -LiteralPath $realManifest) "missing $realManifest"
    $man = Get-Content -LiteralPath $realManifest -Raw | ConvertFrom-Json
    $tasks = @($man.tasks)
    Assert-True ($tasks.Count -eq 8) "expected 8 tasks, got $($tasks.Count)"
    $ids = @($tasks | ForEach-Object { [string]$_.id })
    $uniq = @($ids | Select-Object -Unique)
    Assert-True ($uniq.Count -eq 8) "ids not unique: $($ids -join ',')"
    foreach ($t in $tasks) {
      foreach ($f in $requiredFields) {
        $prop = $t.PSObject.Properties[$f]
        Assert-True ($null -ne $prop) "task $($t.id) missing field $f"
        $val = $prop.Value
        if ($f -eq 'source') {
          Assert-True (-not [string]::IsNullOrWhiteSpace([string]$val.commit)) "empty source.commit on $($t.id)"
          Assert-True (-not [string]::IsNullOrWhiteSpace([string]$val.evidence)) "empty source.evidence on $($t.id)"
        } elseif ($f -eq 'mutation') {
          Assert-True (-not [string]::IsNullOrWhiteSpace([string]$val.path)) "empty mutation.path on $($t.id)"
          Assert-True (-not [string]::IsNullOrWhiteSpace([string]$val.break)) "empty mutation.break on $($t.id)"
        } elseif ($f -eq 'allowed_paths' -or $f -eq 'gate_commands') {
          $arr = @($val)
          Assert-True ($arr.Count -ge 1) "empty $f on $($t.id)"
          foreach ($item in $arr) {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$item)) "blank $f entry on $($t.id)"
          }
        } else {
          Assert-True (-not [string]::IsNullOrWhiteSpace([string]$val)) "empty $f on $($t.id)"
        }
      }
    }
  }

  Case 'manifest: every mutation.path exists in repo' {
    $man = Get-Content -LiteralPath $realManifest -Raw | ConvertFrom-Json
    foreach ($t in @($man.tasks)) {
      $mp = [string]$t.mutation.path
      $full = Join-Path $repoRoot ($mp -replace '/', [IO.Path]::DirectorySeparatorChar)
      Assert-True (Test-Path -LiteralPath $full -PathType Leaf) "mutation.path missing for $($t.id): $mp"
    }
  }

  Case 'deterministic selection: same seed -> same canary id (2 runs)' {
    $fx = Join-Path $temp 'det'
    $q = Join-Path $fx 'queue'
    New-Item -ItemType Directory -Force -Path $q | Out-Null
    $pol = New-CanaryPolicy $fx
    # Point policy manifest at real canaries via absolute copy path name relative to RepoRoot
    $r1 = Invoke-Enq @{ Seed='seed-fixed-A'; QueueRoot=$q; PolicyPath=$pol; RepoRoot=$repoRoot; ManifestPath=$realManifest; RunId='det1' }
    Assert-True ($r1.ExitCode -eq 0) "run1 failed: $($r1.Raw)"
    $o1 = $r1.Raw | ConvertFrom-Json
    $r2 = Invoke-Enq @{ Seed='seed-fixed-A'; QueueRoot=$q; PolicyPath=$pol; RepoRoot=$repoRoot; ManifestPath=$realManifest; RunId='det2' }
    Assert-True ($r2.ExitCode -eq 0) "run2 failed: $($r2.Raw)"
    $o2 = $r2.Raw | ConvertFrom-Json
    Assert-True ([string]$o1.canary_id -eq [string]$o2.canary_id) "same seed diverged: $($o1.canary_id) vs $($o2.canary_id)"
    $man = Get-Content -LiteralPath $realManifest -Raw | ConvertFrom-Json
    $ids = @($man.tasks | ForEach-Object { [string]$_.id })
    $expected = Select-IdBySeed 'seed-fixed-A' $ids
    Assert-True ([string]$o1.canary_id -eq $expected) "selection not matching proven hash: got $($o1.canary_id) want $expected"
  }

  Case 'deterministic selection: different seeds can differ' {
    $fx = Join-Path $temp 'diffseed'
    $q = Join-Path $fx 'queue'
    New-Item -ItemType Directory -Force -Path $q | Out-Null
    $pol = New-CanaryPolicy $fx
    $man = Get-Content -LiteralPath $realManifest -Raw | ConvertFrom-Json
    $ids = @($man.tasks | ForEach-Object { [string]$_.id })
    $foundDiff = $false
    $a = Select-IdBySeed 'seed-alpha-1' $ids
    foreach ($s in @('seed-beta-2','seed-gamma-3','seed-delta-4','seed-epsilon-5','seed-zeta-6','seed-eta-7','seed-theta-8')) {
      if ((Select-IdBySeed $s $ids) -ne $a) { $foundDiff = $true; break }
    }
    Assert-True $foundDiff 'all probe seeds selected the same canary (selection not seed-dependent)'
    $rA = Invoke-Enq @{ Seed='seed-alpha-1'; QueueRoot=$q; PolicyPath=$pol; RepoRoot=$repoRoot; ManifestPath=$realManifest; RunId='sa' }
    $rB = Invoke-Enq @{ Seed='seed-beta-2'; QueueRoot=$q; PolicyPath=$pol; RepoRoot=$repoRoot; ManifestPath=$realManifest; RunId='sb' }
    Assert-True ($rA.ExitCode -eq 0 -and $rB.ExitCode -eq 0) "seed runs failed: $($rA.Raw) | $($rB.Raw)"
    # If these two happen to collide, selection still proven by hash probe above.
    $oa = $rA.Raw | ConvertFrom-Json; $ob = $rB.Raw | ConvertFrom-Json
    Assert-True ([string]$oa.canary_id -eq (Select-IdBySeed 'seed-alpha-1' $ids)) "alpha mismatch"
    Assert-True ([string]$ob.canary_id -eq (Select-IdBySeed 'seed-beta-2' $ids)) "beta mismatch"
  }

  Case 'enqueue: exactly 3 entries with canary labels + forced_canary provenance' {
    $fx = Join-Path $temp 'enq'
    $q = Join-Path $fx 'queue'
    New-Item -ItemType Directory -Force -Path $q | Out-Null
    $pol = New-CanaryPolicy $fx
    $r = Invoke-Enq @{
      CanaryId='sol-crt-backslash-quote'; QueueRoot=$q; PolicyPath=$pol
      RepoRoot=$repoRoot; ManifestPath=$realManifest; RunId='enq1'
    }
    Assert-True ($r.ExitCode -eq 0) "enqueue failed: $($r.Raw)"
    $o = $r.Raw | ConvertFrom-Json
    Assert-True ($o.canary_id -eq 'sol-crt-backslash-quote') "id=$($o.canary_id)"
    Assert-True ($o.canary_repeat_count -eq 3) "repeat_count=$($o.canary_repeat_count)"
    Assert-True ($o.sole_ship_gate -eq $false) 'sole_ship_gate not false'
    Assert-True ($o.sampling_rate_source -eq 'forced_canary') "source=$($o.sampling_rate_source)"
    $files = @(Get-ChildItem -LiteralPath (Join-Path $q 'enq1') -Filter '*.json' -File)
    Assert-True ($files.Count -eq 3) "expected 3 queue files, got $($files.Count)"
    $need = @(
      'qualification_stratum','qualification_n_current','qualification_n_target',
      'base_p_shadow','effective_p_shadow','boost_applied','sampling_rate_source',
      'daily_boost_cap','daily_boost_used','boost_suppressed_reason',
      'canary','canary_id','canary_repeat','canary_repeat_count','sole_ship_gate'
    )
    $repeats = @()
    foreach ($f in $files) {
      $e = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
      Assert-True ($e.canary -eq $true) "canary not true in $($f.Name)"
      Assert-True ($e.canary_id -eq 'sol-crt-backslash-quote') "canary_id in $($f.Name)"
      Assert-True ($e.canary_repeat_count -eq 3) "repeat_count in $($f.Name)"
      Assert-True ($e.sole_ship_gate -eq $false) "sole_ship_gate in $($f.Name)"
      Assert-True ($e.sampling_rate_source -eq 'forced_canary') "rate source in $($f.Name)"
      Assert-True ($e.boost_applied -eq $false) "boost_applied must be false for canary"
      Assert-True ($e.effective_p_shadow -eq 1.0) "effective_p not 1.0"
      Assert-True ($e.status -eq 'pending') "status in $($f.Name)"
      Assert-True ($e.critical_path_delay_seconds -eq 0) "critical path delay"
      foreach ($n in $need) {
        Assert-True ($null -ne $e.PSObject.Properties[$n]) "missing field $n in $($f.Name)"
      }
      $repeats += [int]$e.canary_repeat
    }
    $sorted = @($repeats | Sort-Object)
    Assert-True (($sorted -join ',') -eq '1,2,3') "canary_repeat set=$($sorted -join ',')"
  }

  Case 'policy gate: canary_set.enabled=false refuses with clear error' {
    $fx = Join-Path $temp 'off'
    $q = Join-Path $fx 'queue'
    New-Item -ItemType Directory -Force -Path $q | Out-Null
    $pol = New-CanaryPolicy $fx -Enabled $false
    $r = Invoke-Enq @{
      CanaryId='sol-crt-backslash-quote'; QueueRoot=$q; PolicyPath=$pol
      RepoRoot=$repoRoot; ManifestPath=$realManifest; RunId='off1'
    }
    Assert-True ($r.ExitCode -ne 0) "disabled policy should fail: $($r.Raw)"
    Assert-True ($r.Raw -match 'enabled=false|canary_set\.enabled') "unclear error: $($r.Raw)"
    $leftover = @(Get-ChildItem -LiteralPath $q -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-True ($leftover.Count -eq 0) "queue written despite refuse: $($leftover.Count)"
  }

  Case 'policy gate: absent canary_set fails closed' {
    $fx = Join-Path $temp 'absent'
    $q = Join-Path $fx 'queue'
    New-Item -ItemType Directory -Force -Path $q | Out-Null
    $polPath = Join-Path $fx 'fleet-policy.json'
    Write-Json $polPath @{ schema_version='1'; auto_shadow=@{ default_p_shadow=0.15 } }
    $r = Invoke-Enq @{
      CanaryId='sol-crt-backslash-quote'; QueueRoot=$q; PolicyPath=$polPath
      RepoRoot=$repoRoot; ManifestPath=$realManifest; RunId='abs1'
    }
    Assert-True ($r.ExitCode -ne 0) "absent canary_set should fail: $($r.Raw)"
    Assert-True ($r.Raw -match 'canary_set absent|fail closed') "unclear absent error: $($r.Raw)"
  }

  Case 'no-model proof: enqueue script has no model process invocation' {
    $src = Get-Content -LiteralPath $enqueue -Raw
    $patterns = @(
      'Invoke-Grok45', 'Invoke-Sol', 'Invoke-Opus', 'Invoke-Kimi', 'Invoke-PiGlm', 'Invoke-Gemini',
      'codex\.exe', 'grok\.exe', 'claude\.exe', 'kimi\.exe',
      '\bcodex\s+exec\b', '\bgrok\s+-p\b', '\bclaude\s+-p\b'
    )
    foreach ($p in $patterns) {
      Assert-True ($src -notmatch $p) "enqueue path references model process pattern: $p"
    }
    # Must still be enqueue-only: no Start-FleetAutoShadow / comparison.
    Assert-True ($src -notmatch 'Start-FleetAutoShadow|Run-TerraGrokComparison') 'enqueue must not start consumer/comparison'
  }

  Case 'explicit CanaryId selection ignores seed for identity' {
    $fx = Join-Path $temp 'explicit'
    $q = Join-Path $fx 'queue'
    New-Item -ItemType Directory -Force -Path $q | Out-Null
    $pol = New-CanaryPolicy $fx
    $r = Invoke-Enq @{
      CanaryId='artifact-array-file-binding'; Seed='seed-fixed-A'; QueueRoot=$q
      PolicyPath=$pol; RepoRoot=$repoRoot; ManifestPath=$realManifest; RunId='ex1'
    }
    Assert-True ($r.ExitCode -eq 0) "explicit failed: $($r.Raw)"
    $o = $r.Raw | ConvertFrom-Json
    Assert-True ($o.canary_id -eq 'artifact-array-file-binding') "explicit id ignored: $($o.canary_id)"
  }

  Case 'consumer ledger preserves canary identity and safety fields' {
    $fx = Join-Path $temp 'consumer'; $q = Join-Path $fx 'queue'; $repo = Join-Path $fx 'repo'
    $ledger = Join-Path $fx 'BENCH-shadow.jsonl'
    New-Item -ItemType Directory -Force -Path $q,$repo | Out-Null
    & git -C $repo init -q; & git -C $repo config user.name t; & git -C $repo config user.email t@t.invalid
    [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'x'); & git -C $repo add .; & git -C $repo commit -q -m base | Out-Null
    $sha = (& git -C $repo rev-parse HEAD).Trim(); $pol = New-CanaryPolicy $fx
    $r = Invoke-Enq @{ CanaryId='sol-crt-backslash-quote'; QueueRoot=$q; PolicyPath=$pol; RepoRoot=$repoRoot; ManifestPath=$realManifest; RunId='cons1'; BaseSha=$sha }
    Assert-True ($r.ExitCode -eq 0) "canary enqueue failed: $($r.Raw)"
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $q -RepoRoot $repo -LedgerPath $ledger -NoModel
    $rows = @(Get-Content -LiteralPath $ledger | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($rows.Count -ge 1) "no consumer rows: $($rows.Count)"
    foreach ($row in $rows) {
      Assert-True ($row.canary -eq $true -and $row.canary_id -eq 'sol-crt-backslash-quote') "canary identity on $($row.task_id)"
      Assert-True (($null -ne $row.canary_repeat) -and $row.canary_repeat_count -eq 3 -and $row.sole_ship_gate -eq $false) "safety fields on $($row.task_id)"
    }
    $qOrg = Join-Path $fx 'queue-org'; $ledgerOrg = Join-Path $fx 'BENCH-shadow-org.jsonl'
    New-Item -ItemType Directory -Force -Path $qOrg | Out-Null
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enqueueShadow -RunId org1 -TaskId t-org -TaskStratum standard -Seed seed-org -Challenger terra -BaseSha $sha -Force -QueueRoot $qOrg
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -QueueRoot $qOrg -RepoRoot $repo -LedgerPath $ledgerOrg -NoModel
    $orgRows = @(Get-Content -LiteralPath $ledgerOrg | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($orgRows.Count -eq 1 -and $orgRows[0].canary -eq $false) "organic canary not false"
  }
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
