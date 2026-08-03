# Offline test for Get-FleetPlanContribution.ps1 using a synthetic plan dir.
$ErrorActionPreference = 'Stop'
$dir = Join-Path ([IO.Path]::GetTempPath()) ('fleet-plantest-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok) { if ($ok) { $script:pass++; "PASS $name" } else { $script:fail++; "FAIL $name" } }

@'
- [P-001] [sol] login screen
- [P-002] [grok,glm] retry queue
- [P-003] [kimi] offline banner
- [P-004] [gemini] a11y focus order
- [P-005] [fable] rollout flag
'@ | Set-Content -Encoding utf8 (Join-Path $dir 'PLAN-MERGED.md')
@'
- [P-001] [sol] login screen
- [P-002] [grok,glm] retry queue
- [P-004] [gemini] a11y focus order
- [P-005] [fable] rollout flag
- [P-006] [glm] rate-limit copy
Risk register: [P-003] veto: PWA scope out
'@ | Set-Content -Encoding utf8 (Join-Path $dir 'PLAN-FINAL.md')
'[P-003] cut: duplicate of offline handling' | Set-Content -Encoding utf8 (Join-Path $dir 'attack-cuts.md')

$r = & (Join-Path $PSScriptRoot 'Get-FleetPlanContribution.ps1') -PlanDir $dir | ConvertFrom-Json
Check 'totals' ($r.total_merged -eq 6 -and $r.total_final -eq 5)
Check 'sol unique survived' ($r.seats.sol.unique_survived -eq 1 -and $r.seats.sol.survival_rate -eq 1)
Check 'kimi dropped via cut/veto' ($r.seats.kimi.merged -eq 1 -and $r.seats.kimi.survived -eq 0 -and $r.seats.kimi.dropped -eq 1)
Check 'multi-tag credits both' ($r.seats.grok.survived -eq 1 -and $r.seats.glm.survived -eq 2)
Check 'attack addition counted' ($r.seats.glm.unique_survived -eq 1)
Check 'output file written' (Test-Path (Join-Path $dir 'contribution.json'))
Check 'no lock ranges on baseline' (@($r.lock_ranges).Count -eq 0)

Remove-Item -Recurse -Force $dir

# Blanket-lock + partial-cut: FINAL restates a few items, locks a range, and
# attack-cuts drops one in-range item via `cut (partial):`.
$dir2 = Join-Path ([IO.Path]::GetTempPath()) ('fleet-plantest-lock-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $dir2 | Out-Null
@'
- [P-001] [sol] login screen
- [P-002] [grok] retry queue
- [P-003] [kimi] offline banner
- [P-004] [gemini] a11y focus
- [P-005] [fable] rollout flag
'@ | Set-Content -Encoding utf8 (Join-Path $dir2 'PLAN-MERGED.md')
@'
- [P-001] [sol] login screen
- [P-002] [grok] retry queue
[P-001] [sol] PLAN-ATTACKED items P-001 through P-004 remain locked requirements except where this document explicitly vetoes or narrows them.
'@ | Set-Content -Encoding utf8 (Join-Path $dir2 'PLAN-FINAL.md')
'[P-003] cut (partial): narrow offline banner to cache-miss only' | Set-Content -Encoding utf8 (Join-Path $dir2 'attack-cuts.md')

$r2 = & (Join-Path $PSScriptRoot 'Get-FleetPlanContribution.ps1') -PlanDir $dir2 | ConvertFrom-Json
Check 'partial cut counts as explicit drop' ($r2.explicit_drops -gt 0)
Check 'lock range recorded' ((@($r2.lock_ranges) -join ',') -match 'P-1\.\.P-4|P-001\.\.P-004')
# P-004 is in lock range, not restated, not cut -> survived for gemini
Check 'in-range non-restated survived' ($r2.seats.gemini.merged -eq 1 -and $r2.seats.gemini.survived -eq 1 -and $r2.seats.gemini.dropped -eq 0)
# P-003 is in lock range but partial-cut -> dropped for kimi
Check 'partial-cut in-range item dropped' ($r2.seats.kimi.merged -eq 1 -and $r2.seats.kimi.survived -eq 0 -and $r2.seats.kimi.dropped -eq 1)
# P-005 is outside range and not restated -> dropped for fable
Check 'outside-range non-restated dropped' ($r2.seats.fable.merged -eq 1 -and $r2.seats.fable.survived -eq 0 -and $r2.seats.fable.dropped -eq 1)
# Restated items still survived
Check 'restated items still survived' ($r2.seats.sol.survived -eq 1 -and $r2.seats.grok.survived -eq 1)

Remove-Item -Recurse -Force $dir2
"$pass passed, $fail failed"
if ($fail) { exit 1 } else { exit 0 }
