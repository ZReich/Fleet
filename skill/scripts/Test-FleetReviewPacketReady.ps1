# CLI + self-test for packet readiness (Sol D2). Run WITHOUT -SelfTest to lint a real packet
# before voice dispatch: prints the packet-readiness status line, exit 1 when BLOCKED.
[CmdletBinding()]
param(
  [string]$PacketDir = '',
  [ValidateSet('mechanical', 'behavior', 'hard')][string]$ReviewRisk = 'behavior',
  [string]$RunId = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetReviewPacketReady.Helpers.ps1')
$utf8 = New-Object System.Text.UTF8Encoding $false

# Bare invocation (psvalid runs Test-*.ps1 with no args) = self-test.
if ([string]::IsNullOrWhiteSpace($PacketDir)) { $SelfTest = $true }
if (-not $SelfTest) {
  $r = Get-FleetPacketReadiness -PacketDir $PacketDir -ReviewRisk $ReviewRisk -RunId $RunId
  Write-Output $r.status_line
  foreach ($c in @($r.checks)) { if (-not $c.passed) { Write-Output ("  BLOCKED " + $c.name + ": " + $c.detail) } }
  if ($r.status -ceq 'READY') { exit 0 } else { exit 1 }
}

$fail = 0
function Check([string]$n, [bool]$ok) { if ($ok) { Write-Output "PASS $n" } else { Write-Output "FAIL $n"; $script:fail++ } }
function W([string]$Dir, [string]$Name, [string]$Text) { [IO.File]::WriteAllText((Join-Path $Dir $Name), $Text, $utf8) }
function Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# status-line predicate
Check 'canonical line accepted' (Test-FleetPreflightStatusLineCanonical 'review-preflight: READY | selected: 3 | passed: 3 | cached: 0 | failed: 0')
Check 'loose prefix rejected' (-not (Test-FleetPreflightStatusLineCanonical 'review-preflight: READY (all good)'))
Check 'nonzero failed rejected' (-not (Test-FleetPreflightStatusLineCanonical 'review-preflight: READY | selected: 3 | passed: 2 | cached: 0 | failed: 1'))
Check 'case variant rejected' (-not (Test-FleetPreflightStatusLineCanonical 'REVIEW-PREFLIGHT: READY | selected: 3 | passed: 3 | cached: 0 | failed: 0'))

# RED evidence predicate on a synthetic packet dir
$tmp = Join-Path $env:TEMP ('pktready-st-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  W $tmp 'red-1.log' "expected failure output: 1 test failed`n"
  $redSha = Sha (Join-Path $tmp 'red-1.log')
  function TR([int]$Den, [int]$Obs, [object[]]$Controls) {
    return [pscustomobject]@{ schema_version = '1'; status = 'passed'; commands = @(); red_denominator = $Den; red_observed = $Obs; red_controls = $Controls }
  }
  $goodCtl = [pscustomobject]@{ id = 'R1'; command = 'run failing test'; expected_failure = 'assert fires'; observed_exit_code = 1; sample = '1 test failed'; evidence_path = 'red-1.log'; evidence_sha256 = $redSha }
  $threw = $false; try { Assert-FleetRedEvidence -TestResults (TR 1 1 @($goodCtl)) -PacketDir $tmp -ReviewRisk 'behavior' } catch { $threw = $true }
  Check 'valid 1/1 RED passes' (-not $threw)
  $threw = $false; try { Assert-FleetRedEvidence -TestResults ([pscustomobject]@{ schema_version = '1' }) -PacketDir $tmp -ReviewRisk 'behavior' } catch { $threw = $true }
  Check 'missing RED fields on behavior throws' $threw
  # Terra M4: a present test-results.json must state its RED position even at mechanical.
  $threw = $false; try { Assert-FleetRedEvidence -TestResults ([pscustomobject]@{ schema_version = '1' }) -PacketDir $tmp -ReviewRisk 'mechanical' } catch { $threw = $true }
  Check 'missing RED fields on mechanical throws' $threw
  $threw = $false; try { Assert-FleetRedEvidence -TestResults (TR 0 0 @()) -PacketDir $tmp -ReviewRisk 'hard' } catch { $threw = $true }
  Check '0/0 on hard throws' $threw
  $threw = $false; try { Assert-FleetRedEvidence -TestResults (TR 0 0 @()) -PacketDir $tmp -ReviewRisk 'mechanical' } catch { $threw = $true }
  Check '0/0 on mechanical ok' (-not $threw)
  $threw = $false; try { Assert-FleetRedEvidence -TestResults (TR 2 1 @($goodCtl)) -PacketDir $tmp -ReviewRisk 'behavior' } catch { $threw = $true }
  Check 'observed != denominator throws' $threw
  $threw = $false; try { Assert-FleetRedEvidence -TestResults (TR 2 2 @($goodCtl)) -PacketDir $tmp -ReviewRisk 'behavior' } catch { $threw = $true }
  Check 'controls count mismatch throws' $threw
  $zeroExit = [pscustomobject]@{ id = 'R2'; command = 'c'; expected_failure = 'e'; observed_exit_code = 0; sample = 's'; evidence_path = 'red-1.log'; evidence_sha256 = $redSha }
  $threw = $false; try { Assert-FleetRedEvidence -TestResults (TR 1 1 @($zeroExit)) -PacketDir $tmp -ReviewRisk 'behavior' } catch { $threw = $true }
  Check 'zero observed_exit_code throws' $threw
  $escape = [pscustomobject]@{ id = 'R3'; command = 'c'; expected_failure = 'e'; observed_exit_code = 1; sample = 's'; evidence_path = '..\outside.log'; evidence_sha256 = $redSha }
  $threw = $false; try { Assert-FleetRedEvidence -TestResults (TR 1 1 @($escape)) -PacketDir $tmp -ReviewRisk 'behavior' } catch { $threw = $true }
  Check 'evidence path escape throws' $threw
  $badSha = [pscustomobject]@{ id = 'R4'; command = 'c'; expected_failure = 'e'; observed_exit_code = 1; sample = 's'; evidence_path = 'red-1.log'; evidence_sha256 = ('0' * 64) }
  $threw = $false; try { Assert-FleetRedEvidence -TestResults (TR 1 1 @($badSha)) -PacketDir $tmp -ReviewRisk 'behavior' } catch { $threw = $true }
  Check 'evidence hash mismatch throws' $threw
  $dup = @($goodCtl, $goodCtl)
  $threw = $false; try { Assert-FleetRedEvidence -TestResults (TR 2 2 $dup) -PacketDir $tmp -ReviewRisk 'behavior' } catch { $threw = $true }
  Check 'duplicate control id throws' $threw

  # review_profile predicate
  W $tmp 'locked-plan.md' "plan`nreview_profile: general`n"
  $threw = $false; try { Assert-FleetSingleReviewProfile (Join-Path $tmp 'locked-plan.md') } catch { $threw = $true }
  Check 'single profile ok' (-not $threw)
  W $tmp 'locked-plan.md' "plan`nreview_profile: general`nreview_profile: security-sensitive`n"
  $threw = $false; try { Assert-FleetSingleReviewProfile (Join-Path $tmp 'locked-plan.md') } catch { $threw = $true }
  Check 'duplicate profile throws' $threw
  W $tmp 'locked-plan.md' "plan with no profile`n"
  $threw = $false; try { Assert-FleetSingleReviewProfile (Join-Path $tmp 'locked-plan.md') } catch { $threw = $true }
  Check 'missing profile throws' $threw

  # Readiness wrapper on an incomplete dir: BLOCKED + diagnostic artifact written.
  $r = Get-FleetPacketReadiness -PacketDir $tmp -ReviewRisk 'behavior' -RunId 'st-run'
  Check 'incomplete packet BLOCKED' ($r.status -ceq 'BLOCKED')
  Check 'packet-readiness.json written' (Test-Path -LiteralPath (Join-Path $tmp 'packet-readiness.json'))
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($fail -eq 0) { Write-Output 'Test-FleetReviewPacketReady: passed (19 checks)'; exit 0 }
Write-Output "Test-FleetReviewPacketReady: FAILED ($fail)"; exit 1
