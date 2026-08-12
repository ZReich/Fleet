# Self-test for FleetReviewGrammar.Helpers.ps1 — grammar block and parser must agree.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetReviewGrammar.Helpers.ps1')
$fail = 0
function Check([string]$Name, [bool]$Ok) {
  if ($Ok) { Write-Output "PASS $Name" } else { Write-Output "FAIL $Name"; $script:fail++ }
}
function P([string]$t) { return (Parse-FleetReviewVerdict $t) }

$goNone = "Solid review body here.`n`nVERDICT: GO`nFINDINGS: none"
$noGo = "Review body.`n`nVERDICT: NO-GO`nFINDINGS:`n- HIGH | F001 | scripts/Example.ps1:123 | Concise actionable finding"

# The grammar block's own examples parse (grammar and parser cannot drift).
$block = Get-FleetReviewGrammarBlock
Check 'grammar block nonempty ASCII' (-not [string]::IsNullOrWhiteSpace($block) -and ($block -cnotmatch '[^\x00-\x7F]'))
Check 'block GO example parses' ((P $goNone).valid)
Check 'block NO-GO example parses' ((P $noGo).valid)

$r = P $goNone
Check 'GO none: verdict/no_findings/mode' ($r.verdict -ceq 'GO' -and $r.no_findings -and $r.parse_mode -ceq 'canonical-v1' -and $r.findings_count -eq 0)
$r = P $noGo
Check 'NO-GO: findings_count/max_severity' ($r.valid -and $r.findings_count -eq 1 -and $r.max_severity -ceq 'HIGH')

# GO with MEDIUM/LOW findings allowed; with HIGH rejected.
$goMed = "Body.`nVERDICT: GO`nFINDINGS:`n- MEDIUM | M1 | a/b.ps1:9 | minor`n- LOW | L1 | a/c.ps1:2 | nit"
Check 'GO + MEDIUM/LOW valid' ((P $goMed).valid)
$goHigh = "Body.`nVERDICT: GO`nFINDINGS:`n- HIGH | H1 | a/b.ps1:9 | bad"
Check 'GO + HIGH rejected' (-not (P $goHigh).valid)
$noGoNone = "Body.`nVERDICT: NO-GO`nFINDINGS: none"
Check 'NO-GO + none rejected' (-not (P $noGoNone).valid)
$noGoEmpty = "Body.`nVERDICT: NO-GO`nFINDINGS:"
Check 'NO-GO + zero findings rejected' (-not (P $noGoEmpty).valid)

# Structural rejections.
Check 'no verdict line rejected' (-not (P "just prose, no verdict").valid)
Check 'trailing text after none rejected' (-not (P "b`nVERDICT: GO`nFINDINGS: none`nthanks!").valid)
Check 'duplicate VERDICT rejected' (-not (P "VERDICT: GO`nmore body`nVERDICT: GO`nFINDINGS: none").valid)
Check 'alias APPROVE rejected' (-not (P "body`nAPPROVE").valid)
Check 'non-ASCII terminal rejected' (-not (P ("b`nVERDICT: GO`nFINDINGS: none " + [char]0x2014 + " ok")).valid)
Check 'missing file:line rejected' (-not (P "b`nVERDICT: NO-GO`nFINDINGS:`n- HIGH | F1 | somewhere | x").valid)
Check 'bad severity rejected' (-not (P "b`nVERDICT: NO-GO`nFINDINGS:`n- SEVERE | F1 | a.ps1:1 | x").valid)

# Mutation test: every token of the canonical GO terminal must matter.
$mutations = @(
  "b`nVERDICT:GO`nFINDINGS: none", "b`nverdict: GO`nFINDINGS: none",
  "b`nVERDICT: go`nFINDINGS: none", "b`nVERDICT: GO`nFINDINGS none",
  "b`nVERDICT: GO`nFINDINGS: None", "b`nVERDICT: OK`nFINDINGS: none"
)
$allRejected = $true
foreach ($m in $mutations) { if ((P $m).valid) { $allRejected = $false } }
Check 'terminal-token mutations all rejected' $allRejected

# Legacy alias (Sol D3): bare terminal GO with provably clean body only.
$r = P "Reviewed everything, looks correct and complete.`n`nVERDICT: GO"
Check 'legacy bare GO clean body accepted' ($r.valid -and $r.parse_mode -ceq 'legacy-go-alias-v1' -and $r.no_findings)
Check 'legacy GO + severity token rejected' (-not (P "One HIGH issue in a.ps1.`nVERDICT: GO").valid)
Check 'legacy GO + evidence bullet rejected' (-not (P "- see scripts/a.ps1:12 broken`nVERDICT: GO").valid)
Check 'legacy GO + negative verdict word rejected' (-not (P "I would REQUEST CHANGES here.`nVERDICT: GO").valid)
Check 'legacy GO + refusal rejected' (-not (P "I cannot assist with that portion.`nVERDICT: GO").valid)
Check 'legacy GO + FINDINGS header rejected' (-not (P "FINDINGS:`nsome stuff`nVERDICT: GO").valid)
Check 'standalone prose approval rejected' (-not (P "Looks good to me, ship it.").valid)

# Terra H1: a clean terminal block cannot launder a findings-bearing body.
Check 'canonical GO+none with severity body rejected' (-not (P "One HIGH issue at scripts/a.ps1:12 remains.`n`nVERDICT: GO`nFINDINGS: none").valid)
Check 'canonical GO+none with evidence bullet rejected' (-not (P "- scripts/a.ps1:12 broken thing`n`nVERDICT: GO`nFINDINGS: none").valid)
Check 'canonical GO+none clean body still accepted' ((P "All checks came back clean after a full pass.`n`nVERDICT: GO`nFINDINGS: none").valid)

# CRLF fixtures parse identically.
Check 'CRLF GO parses' ((P ($goNone -replace "`n", "`r`n")).valid)
Check 'CRLF NO-GO parses' ((P ($noGo -replace "`n", "`r`n")).valid)
# Canonical takes precedence over legacy when both shapes present.
$r = P "body`nVERDICT: GO`nFINDINGS: none"
Check 'canonical precedence over legacy' ($r.parse_mode -ceq 'canonical-v1')

if ($fail -eq 0) { Write-Output 'Test-FleetReviewGrammar: passed (30 checks)'; exit 0 }
Write-Output "Test-FleetReviewGrammar: FAILED ($fail)"; exit 1
