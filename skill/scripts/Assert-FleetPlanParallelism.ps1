#requires -Version 5
<#
.SYNOPSIS
  Deterministic max-parallelism gate for Fleet wave plans (owner directive 2026-08-14:
  "maximally parallel is the standard, not orchestrator discretion").

.DESCRIPTION
  The planner must embed a machine-readable block in the plan markdown:

    ```plan-graph
    { "width": 5, "critical_path": 2,
      "tasks": [
        { "id": "T1", "wave": 1, "files": ["src/a.ts"], "deps": [] },
        { "id": "T2", "wave": 2, "files": ["src/b.ts"],
          "deps": [ { "on": "T1", "reason": "consumes T1 schema" } ] } ] }
    ```

  This gate parses that block and FAILS (exit 1) unless the plan is maximally parallel
  GIVEN ITS DECLARED DEPENDENCY EDGES:
    - every task's wave == 1 + max(wave of its deps)  (deps none => wave 1). A task
      placed any later is NEEDLESS SERIALIZATION - the exact defect this gate exists
      to block. Deliberate ordering is expressed as a dep edge WITH a reason.
    - every dep edge names an existing task, is acyclic, sits in an earlier wave, and
      carries a non-empty reason (an unexplained edge is a planning defect).
    - no two tasks in the same wave share a file scope (normalized; prefix containment
      counts, so src/ vs src/a.ts collides).
    - stated width / critical_path match the computed values (no aspirational numbers).
    - exactly ONE plan-graph block (a second block cannot shadow the real one).
  SCOPE LIMIT (deliberate): edge LEGITIMACY is not machine-checkable - a fabricated
  edge with a junk reason passes this gate. That is the design: the gate makes every
  serialization EXPLICIT and AUDITABLE (an edge + reason the plan reviewer must see),
  it does not prove the reason true. Fake edges are a plan-review finding.
  Merge-order / resource-contention is NOT a build dep: keep those tasks same-wave
  (isolated worktrees; ordering handled at integration), never fabricate an edge.

  Emits one reducer line (quote it verbatim in the run report; missing line = gate did
  not run): plan-parallelism: width W across N waves; critical path M; defects: K (...)
#>
param(
  [string]$PlanPath,
  [string]$GraphJsonPath,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-PlanGraphJson {
  # Returns @{ Json = <string-or-null>; Count = <int> }. Exactly one block is legal:
  # zero = planner did not emit it; two+ = a decoy block could shadow the real graph.
  param([string]$MarkdownText)
  $ms = [regex]::Matches($MarkdownText, '(?s)```plan-graph\s*(.*?)```')
  if ($ms.Count -ne 1) { return @{ Json = $null; Count = $ms.Count } }
  return @{ Json = $ms[0].Groups[1].Value; Count = 1 }
}

function Get-TaskDeps {
  # PS 5.1: @($null).Count -eq 1 - an omitted/null deps key must read as EMPTY, never
  # as one phantom edge (that false-failed honest parallel plans; adversarial HIGH).
  param($Task)
  if ($null -eq $Task.deps) { return @() }
  return @($Task.deps | Where-Object { $null -ne $_ })
}

function ConvertTo-NormalizedScope {
  param([string]$Path)
  $x = ([string]$Path).Trim().Replace('\', '/')
  while ($x.StartsWith('./')) { $x = $x.Substring(2) }
  while ($x.Contains('//')) { $x = $x.Replace('//', '/') }
  return $x.TrimEnd('/')
}

function Test-FleetPlanParallelism {
  # Returns @{ Line = <reducer line>; Defects = <int>; Details = <string[]> }
  param([Parameter(Mandatory)][string]$GraphJson)

  $details = New-Object System.Collections.Generic.List[string]
  $serial = 0; $overlap = 0; $edge = 0; $order = 0; $stated = 0; $shape = 0

  $g = $null
  try { $g = $GraphJson | ConvertFrom-Json -ErrorAction Stop }
  catch { return @{ Line = 'plan-parallelism: FAILED (plan-graph JSON unparseable)'; Defects = 1; Details = @("unparseable: $($_.Exception.Message)") } }
  $tasks = @($g.tasks)
  if ($tasks.Count -eq 0) { return @{ Line = 'plan-parallelism: FAILED (no tasks in plan-graph)'; Defects = 1; Details = @('no tasks') } }

  # shape + id uniqueness; parse wave ONCE (garbage wave = shape defect + wave 0, never
  # a later [int] crash - the reducer line must always emit)
  $byId = @{}; $waveOf = @{}
  foreach ($t in $tasks) {
    $id = [string]$t.id
    if ([string]::IsNullOrWhiteSpace($id)) { $shape++; [void]$details.Add('task with empty id'); continue }
    if ($byId.ContainsKey($id)) { $shape++; [void]$details.Add("duplicate task id: $id"); continue }
    $w = 0; try { $w = [int]$t.wave } catch { $w = 0 }
    if ($w -lt 1) { $shape++; [void]$details.Add("task ${id}: wave must be a positive int"); $w = 0 }
    $byId[$id] = $t
    $waveOf[$id] = $w
  }

  # dep edges: exist, earlier wave, non-empty reason, no self-dep
  foreach ($t in $tasks) {
    $id = [string]$t.id
    if (-not $waveOf.ContainsKey($id)) { continue }
    foreach ($d in (Get-TaskDeps $t)) {
      $on = [string]$d.on
      if ([string]::IsNullOrWhiteSpace($on) -or -not $byId.ContainsKey($on)) { $edge++; [void]$details.Add("task ${id}: dep on unknown task '$on'"); continue }
      if ($on -ceq $id) { $edge++; [void]$details.Add("task ${id}: self-dependency"); continue }
      if ([string]::IsNullOrWhiteSpace([string]$d.reason)) { $edge++; [void]$details.Add("task ${id}: dep on $on has NO reason (unexplained edge = planning defect)") }
      if ($waveOf[$on] -ge $waveOf[$id]) { $order++; [void]$details.Add("task ${id} (wave $($waveOf[$id])): dep $on is not in an earlier wave (wave $($waveOf[$on]))") }
    }
  }

  # cycle check (DFS over dep edges)
  $visiting = @{}; $done = @{}
  function Test-Cycle([string]$Id) {
    if ($done.ContainsKey($Id)) { return $false }
    if ($visiting.ContainsKey($Id)) { return $true }
    $visiting[$Id] = $true
    foreach ($d in (Get-TaskDeps $byId[$Id])) {
      $on = [string]$d.on
      if ($byId.ContainsKey($on)) { if (Test-Cycle $on) { return $true } }
    }
    $visiting.Remove($Id); $done[$Id] = $true
    return $false
  }
  foreach ($id in @($byId.Keys)) {
    if (Test-Cycle $id) { $edge++; [void]$details.Add("dependency cycle involving $id"); break }
  }

  # MAX-PARALLEL RULE: wave == 1 + max(dep waves); no deps => wave 1.
  foreach ($t in $tasks) {
    $id = [string]$t.id
    if (-not $waveOf.ContainsKey($id)) { continue }
    $minWave = 1
    foreach ($d in (Get-TaskDeps $t)) {
      $on = [string]$d.on
      if ($waveOf.ContainsKey($on)) {
        $dw = 1 + $waveOf[$on]
        if ($dw -gt $minWave) { $minWave = $dw }
      }
    }
    if ($waveOf[$id] -gt $minWave) {
      $serial++
      [void]$details.Add("NEEDLESS SERIALIZATION: task ${id} sits in wave $($waveOf[$id]) but its deps allow wave ${minWave} - move it earlier or declare the missing dep edge with a reason")
    }
  }

  # same-wave file-scope overlap: normalized paths; prefix containment counts, so a
  # dir scope src/ collides with src/a.ts in the same wave.
  $byWave = $tasks | Where-Object { $waveOf.ContainsKey([string]$_.id) } | Group-Object { $waveOf[[string]$_.id] }
  foreach ($grp in $byWave) {
    $seen = @{}
    foreach ($t in $grp.Group) {
      foreach ($f in @($t.files)) {
        $fp = ConvertTo-NormalizedScope -Path ([string]$f)
        if ([string]::IsNullOrWhiteSpace($fp)) { continue }
        $hit = $null
        foreach ($k in @($seen.Keys)) {
          if (($k -eq $fp) -or $k.StartsWith($fp + '/') -or $fp.StartsWith($k + '/')) { $hit = $k; break }
        }
        if ($null -ne $hit -and [string]$seen[$hit] -ne [string]$t.id) { $overlap++; [void]$details.Add("wave $($grp.Name): tasks $($seen[$hit]) and $($t.id) overlap on scope $fp vs $hit") }
        elseif ($null -eq $hit) { $seen[$fp] = [string]$t.id }
      }
    }
  }

  # stated vs computed width / critical path
  $computedWaves = (@($waveOf.Values) | Measure-Object -Maximum).Maximum
  $computedWidth = ($byWave | ForEach-Object { $_.Group.Count } | Measure-Object -Maximum).Maximum
  if ($null -eq $computedWidth) { $computedWidth = 0 }
  $statedWidth = -1; $statedCrit = -1
  try { $statedWidth = [int]$g.width } catch { }
  try { $statedCrit = [int]$g.critical_path } catch { }
  if ($statedWidth -ne $computedWidth) { $stated++; [void]$details.Add("stated width $statedWidth != computed $computedWidth") }
  if ($statedCrit -ne $computedWaves) { $stated++; [void]$details.Add("stated critical_path $statedCrit != computed $computedWaves") }

  $defects = $serial + $overlap + $edge + $order + $stated + $shape
  $line = "plan-parallelism: width $computedWidth across $computedWaves waves; critical path $computedWaves; defects: $defects (serial $serial, overlap $overlap, edge $edge, order $order, stated $stated, shape $shape)"
  return @{ Line = $line; Defects = $defects; Details = @($details) }
}

function Invoke-SelfTest {
  $script:sfFail = 0
  function Check($cond, $msg) { if ($cond) { Write-Host "PASS $msg" } else { Write-Host "FAIL $msg"; $script:sfFail++ } }

  $good = '{"width":2,"critical_path":2,"tasks":[{"id":"T1","wave":1,"files":["a.ts"],"deps":[]},{"id":"T2","wave":1,"files":["b.ts"],"deps":[]},{"id":"T3","wave":2,"files":["c.ts"],"deps":[{"on":"T1","reason":"consumes T1 schema"}]}]}'
  $r = Test-FleetPlanParallelism -GraphJson $good
  Check ($r.Defects -eq 0) 'maximally parallel plan passes'

  $lazy = '{"width":1,"critical_path":3,"tasks":[{"id":"T1","wave":1,"files":["a.ts"],"deps":[]},{"id":"T2","wave":2,"files":["b.ts"],"deps":[]},{"id":"T3","wave":3,"files":["c.ts"],"deps":[]}]}'
  $r = Test-FleetPlanParallelism -GraphJson $lazy
  Check ($r.Defects -ge 2 -and ($r.Details -join ';') -match 'NEEDLESS SERIALIZATION') 'lazy serial chain of independent tasks FAILS'

  $noReason = '{"width":1,"critical_path":2,"tasks":[{"id":"T1","wave":1,"files":["a.ts"],"deps":[]},{"id":"T2","wave":2,"files":["b.ts"],"deps":[{"on":"T1","reason":""}]}]}'
  $r = Test-FleetPlanParallelism -GraphJson $noReason
  Check ($r.Defects -ge 1 -and ($r.Details -join ';') -match 'NO reason') 'unexplained dep edge FAILS'

  $overlapJson = '{"width":2,"critical_path":1,"tasks":[{"id":"T1","wave":1,"files":["x.ts"],"deps":[]},{"id":"T2","wave":1,"files":["x.ts"],"deps":[]}]}'
  $r = Test-FleetPlanParallelism -GraphJson $overlapJson
  Check ($r.Defects -ge 1 -and ($r.Details -join ';') -match 'overlap on scope x.ts') 'same-wave scope overlap FAILS'

  $cycle = '{"width":1,"critical_path":2,"tasks":[{"id":"T1","wave":1,"files":["a.ts"],"deps":[{"on":"T2","reason":"r"}]},{"id":"T2","wave":2,"files":["b.ts"],"deps":[{"on":"T1","reason":"r"}]}]}'
  $r = Test-FleetPlanParallelism -GraphJson $cycle
  Check ($r.Defects -ge 1 -and ($r.Details -join ';') -match 'cycle|not in an earlier wave') 'cycle / bad ordering FAILS'

  $aspirational = '{"width":99,"critical_path":1,"tasks":[{"id":"T1","wave":1,"files":["a.ts"],"deps":[]}]}'
  $r = Test-FleetPlanParallelism -GraphJson $aspirational
  Check ($r.Defects -ge 1 -and ($r.Details -join ';') -match 'stated width') 'aspirational stated width FAILS'

  $md = "# plan`n" + '```plan-graph' + "`n" + $good + "`n" + '```' + "`nrest"
  $blk = Get-PlanGraphJson -MarkdownText $md
  Check ($null -ne $blk.Json -and (Test-FleetPlanParallelism -GraphJson $blk.Json).Defects -eq 0) 'plan-graph block extracts from markdown'

  $none = Get-PlanGraphJson -MarkdownText '# plan with no block'
  Check ($null -eq $none.Json -and $none.Count -eq 0) 'missing plan-graph block returns null (caller fails closed)'

  $two = Get-PlanGraphJson -MarkdownText ($md + "`n" + '```plan-graph' + "`n{}`n" + '```')
  Check ($null -eq $two.Json -and $two.Count -eq 2) 'second (decoy) plan-graph block fails closed'

  # PS 5.1 @($null) footgun: an OMITTED deps key must read as no deps, not a phantom edge
  $omitted = '{"width":2,"critical_path":1,"tasks":[{"id":"T1","wave":1,"files":["a.ts"]},{"id":"T2","wave":1,"files":["b.ts"]}]}'
  $r = Test-FleetPlanParallelism -GraphJson $omitted
  Check ($r.Defects -eq 0) 'omitted deps key = maximally parallel plan still passes'

  $garbageWave = '{"width":1,"critical_path":1,"tasks":[{"id":"T1","wave":"soon","files":["a.ts"],"deps":[]}]}'
  $r = Test-FleetPlanParallelism -GraphJson $garbageWave
  Check ($r.Defects -ge 1 -and $r.Line -match '^plan-parallelism:') 'garbage wave emits reducer + defects, never crashes'

  $dirOverlap = '{"width":2,"critical_path":1,"tasks":[{"id":"T1","wave":1,"files":["src/"],"deps":[]},{"id":"T2","wave":1,"files":["src/a.ts"],"deps":[]}]}'
  $r = Test-FleetPlanParallelism -GraphJson $dirOverlap
  Check ($r.Defects -ge 1 -and ($r.Details -join ';') -match 'overlap on scope') 'dir-scope prefix overlap in same wave FAILS'

  if ($script:sfFail -gt 0) { Write-Host "selftest: FAIL $($script:sfFail)"; exit 1 }
  Write-Host 'selftest: PASS 12/12'; exit 0
}

if ($SelfTest) { Invoke-SelfTest }

# -PlanPath is the PRODUCTION path (the gate input IS the dispatched plan document).
# -GraphJsonPath is for tests/tools only - it decouples the graph from the plan, so the
# certification gate always uses -PlanPath against the locked plan.
$json = $null
if ($GraphJsonPath) { $json = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $GraphJsonPath).Path, $utf8) }
elseif ($PlanPath) {
  $mdText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PlanPath).Path, $utf8)
  $blk = Get-PlanGraphJson -MarkdownText $mdText
  if ($null -eq $blk.Json) {
    if ($blk.Count -gt 1) { Write-Host "plan-parallelism: FAILED ($($blk.Count) plan-graph blocks - exactly one required; a decoy block cannot shadow the graph)" }
    else { Write-Host 'plan-parallelism: FAILED (plan has no plan-graph block - planner must emit it)' }
    exit 1
  }
  $json = $blk.Json
}
else { throw 'Specify -PlanPath (markdown with a plan-graph block) or -GraphJsonPath (tests only).' }

$result = Test-FleetPlanParallelism -GraphJson $json
foreach ($d in $result.Details) { Write-Host "  defect: $d" }
Write-Host $result.Line
if ($result.Defects -gt 0) { exit 1 }
exit 0
