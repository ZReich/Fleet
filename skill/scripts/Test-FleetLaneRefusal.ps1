# Self-test for FleetLaneRefusal.Helpers.ps1
# Prints `selftest: PASS k/k` and exits 0; exits 1 on first mismatch.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File Test-FleetLaneRefusal.ps1
#        (optional -SelfTest is accepted for orchestrator symmetry)

param(
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetLaneRefusal.Helpers.ps1')

$cases = @(
  @{
    Name = 'codex-cyber-flag'
    Result = 'Request flagged for possible cybersecurity risk by the safety system.'
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'content_filter:codex_cyber_flag'
  }
  @{
    Name = 'trusted-access'
    Result = 'This requires Trusted Access for Cyber before proceeding.'
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'content_filter:trusted_access'
  }
  @{
    Name = 'policy-decline'
    Result = 'I cannot help with that request.'
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'policy_decline'
  }
  @{
    Name = 'capability-decline'
    Result = "I don't have the tools to inspect that environment."
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'capability_decline'
  }
  @{
    Name = 'security-empty-verdict'
    Result = ''
    ExitCode = 0
    IsSecuritySensitive = $true
    ExpectRefused = $true
    ExpectReason = 'security_empty_verdict'
  }
  @{
    Name = 'NEG:block-verdict-quoting-refusal-literal'
    Result = @"
## Adversarial review
Finding: response quoted Trusted Access for Cyber as evidence of a policy miss.
VERDICT: BLOCK
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    Name = 'NEG:real-review-with-HIGH-finding'
    Result = @"
## Findings
- scripts/foo.ps1:12 HIGH - missing auth check on admin path.
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    Name = 'NEG:nonzero-exit-no-signal'
    Result = 'connection reset by peer'
    ExitCode = 1
    IsSecuritySensitive = $false
    ExpectRefused = $false
    ExpectReason = 'transport_error'
  }
  @{
    Name = 'NEG:general-empty-exit0'
    Result = ''
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    Name = 'grammar-cannot-review'
    Result = 'I cannot review this change'
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'policy_decline'
  }
  @{
    Name = 'grammar-dont-have-access'
    Result = "I don't have access to that"
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'capability_decline'
  }
  @{
    Name = 'grammar-curly-apostrophe-cant-help'
    Result = ('I can{0}t help with that request.' -f [char]0x2019)
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'policy_decline'
  }
  @{
    Name = 'structured-verdict-empty-response'
    Result = '{"status":"ok","verdict":"BLOCK","response":""}'
    ExitCode = 0
    IsSecuritySensitive = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    Name = 'NEG:substantive-unstructured-prose'
    Result = 'scripts/auth.ps1 exposes an unauthenticated admin endpoint that leaks session tokens to any remote caller without checks.'
    ExitCode = 0
    IsSecuritySensitive = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    # Round-3: bare HIGH must not beat explicit policy decline.
    Name = 'refusal-bare-HIGH-still-refusal'
    Result = 'I cannot help with this HIGH-risk request.'
    ExitCode = 0
    IsSecuritySensitive = $true
    ExpectRefused = $true
    ExpectReason = 'policy_decline'
  }
  @{
    Name = 'refusal-bare-CRITICAL-still-refusal'
    Result = 'I must decline. CRITICAL.'
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'policy_decline'
  }
  @{
    Name = 'content-filter-plus-bare-HIGH-still-filter'
    Result = 'Request flagged for possible cybersecurity risk by the safety system. HIGH'
    ExitCode = 0
    IsSecuritySensitive = $true
    ExpectRefused = $true
    ExpectReason = 'content_filter:codex_cyber_flag'
  }
  @{
    Name = 'grammar-im-not-able-to-complete'
    Result = "I'm not able to complete this review"
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'policy_decline'
  }
  @{
    Name = 'grammar-im-unable-to-help'
    Result = "I'm unable to help"
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'policy_decline'
  }
  @{
    Name = 'grammar-impersonal-falls-outside'
    Result = 'This falls outside what I can assist with for this task.'
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'policy_decline'
  }
  @{
    Name = 'grammar-im-curly-not-able'
    Result = ('I{0}m not able to complete this review' -f [char]0x2019)
    ExitCode = 0
    IsSecuritySensitive = $false
    ExpectRefused = $true
    ExpectReason = 'policy_decline'
  }
  # --- hosted_refusal_soft (softened security review; owner directive 2026-08-14) ---
  # Softening fires ONLY when DetectSoftening=$true (genuine security review).
  @{
    Name = 'soft-generic-validate'
    Result = @"
## Findings
- HIGH: consider validating user input across the surface.
VERDICT: NEEDS-FIX
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $true
    ExpectReason = 'hosted_refusal_soft'
  }
  @{
    # Production charter grammar (FINDINGS: / VERDICT: NO-GO), softened.
    Name = 'soft-canonical-grammar-hedge'
    Result = @"
VERDICT: NO-GO
FINDINGS:
- HIGH | F001 | src/auth.ts:22 | input handling is weak; ensure proper input validation and follow security best practices
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $true
    ExpectReason = 'hosted_refusal_soft'
  }
  @{
    Name = 'soft-fileline-hedge'
    Result = @"
## Findings
- scripts/foo.ps1:12 HIGH - consider validating user input
VERDICT: NEEDS-FIX
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $true
    ExpectReason = 'hosted_refusal_soft'
  }
  @{
    # FN closed: attacker-can with no exploitation verb no longer buys depth.
    Name = 'soft-attacker-can-theoretically'
    Result = @"
## Findings
- HIGH: consider validating user input across the surface. An attacker can theoretically cause issues if validation is weak.
VERDICT: NEEDS-FIX
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $true
    ExpectReason = 'hosted_refusal_soft'
  }
  @{
    Name = 'real-sqli-chain-not-soft'
    Result = @"
## Findings
- scripts/Query.ps1:44 HIGH - SQL injection: attacker-controlled `$Filter reaches Invoke-Sqlcmd via string concat; payload ' OR 1=1-- dumps dbo.Users.
VERDICT: BLOCK
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    Name = 'real-authz-attacker-can-not-soft'
    Result = @"
## Findings
- scripts/Grant.ps1:88 CRITICAL - unauthenticated admin endpoint; an attacker can execute Grant-Admin with no session cookie (authz-bypass).
VERDICT: NO-GO
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    Name = 'real-cwe-id-not-soft'
    Result = @"
## Findings
- lib/state.py:88 CRITICAL - insecure deserialization (CWE-502): pickle.loads on attacker-controlled session blob, gadget chain to RCE.
VERDICT: BLOCK
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    # Real finding, class OUTSIDE the depth lexicon, NO hedge => never soft (require-hedge
    # rule; adversarial HIGH-3: secrets/DoS findings must not be flagged).
    Name = 'real-secret-no-hedge-not-soft'
    Result = @"
VERDICT: BLOCK
FINDINGS:
- CRITICAL | F001 | config/prod.env:4 | plaintext AWS keys committed; rotate and move to a secrets vault
- MEDIUM | F002 | src/ratelimit.go:9 | limiter admits unbounded bursts from any IP
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    Name = 'clean-no-findings-not-soft'
    Result = @"
## Findings
- none material
VERDICT: CLEAR
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    # Production clean grammar: FINDINGS: none with an earlier prose bullet must not be soft.
    Name = 'clean-canonical-findings-none-not-soft'
    Result = @"
Checked the auth surface end to end.
- reviewed session handling
VERDICT: GO
FINDINGS: none
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    # CRITICAL fix: general review in canonical grammar is NEVER soft-flagged
    # (DetectSoftening=$false), even though IsSecuritySensitive is $true at the integrity gate.
    Name = 'general-canonical-review-not-soft'
    Result = @"
VERDICT: NO-GO
FINDINGS:
- HIGH | F001 | src/cache.ts:40 | race on cache write; add a lock
- MEDIUM | F002 | src/util.ts:9 | naming inconsistency, could be improved
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $false
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    Name = 'soft-ignored-when-not-detecting'
    Result = @"
## Findings
- HIGH: consider validating user input across the surface.
VERDICT: NEEDS-FIX
"@
    ExitCode = 0
    IsSecuritySensitive = $false
    DetectSoftening = $false
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    # WATCH-1 closed: a real authn finding phrased "must be authenticated" is NOT a hedge
    # (authenticated/authorized dropped from the modal marker) => real finding, not soft.
    Name = 'real-jwt-authn-finding-not-soft'
    Result = @"
VERDICT: BLOCK
FINDINGS:
- CRITICAL | F001 | src/jwt.ts:14 | alg=none accepted; tokens must be authenticated with RS256, current code trusts the header alg
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $false
    ExpectReason = $null
  }
  @{
    # WATCH-2 closed: an unanchored "no issues with X" mid-body must NOT launder a hedged
    # review clean; the hedge still makes it soft.
    Name = 'soft-unanchored-no-issues-still-soft'
    Result = @"
Consider validating user input on the upload path. There are no issues with the limiter itself.
VERDICT: NEEDS-FIX
"@
    ExitCode = 0
    IsSecuritySensitive = $true
    DetectSoftening = $true
    ExpectRefused = $true
    ExpectReason = 'hosted_refusal_soft'
  }
)

$total = $cases.Count
$i = 0
foreach ($c in $cases) {
  $i++
  $detectSoft = [bool]$c.DetectSoftening
  $got = Test-FleetLaneRefusal -Result $c.Result -ExitCode $c.ExitCode -IsSecuritySensitive $c.IsSecuritySensitive -DetectSoftening $detectSoft
  $refusedOk = ($got.refused -eq $c.ExpectRefused)
  $reasonOk = $false
  if ($null -eq $c.ExpectReason) {
    $reasonOk = ($null -eq $got.reason)
  }
  else {
    $reasonOk = ([string]$got.reason -eq [string]$c.ExpectReason)
  }
  if (-not $refusedOk -or -not $reasonOk) {
    $gotReason = if ($null -eq $got.reason) { '<null>' } else { [string]$got.reason }
    $expReason = if ($null -eq $c.ExpectReason) { '<null>' } else { [string]$c.ExpectReason }
    Write-Host ("selftest: FAIL {0}/{1} case={2} got={{refused={3};reason={4}}} expected={{refused={5};reason={6}}}" -f $i, $total, $c.Name, $got.refused, $gotReason, $c.ExpectRefused, $expReason)
    exit 1
  }
}

# Failover eligibility cases (separate contract; assert bool only).
$failoverCases = @(
  @{
    Name = 'failover-verdict-eligible'
    Result = 'VERDICT: BLOCK - auth path open without login.'
    ExitCode = 0
    ExpectEligible = $true
  }
  @{
    Name = 'failover-refusal-bare-severity'
    Result = 'I cannot perform this. CRITICAL.'
    ExitCode = 0
    ExpectEligible = $false
  }
  @{
    Name = 'failover-exit1-real-verdict'
    Result = 'VERDICT: BLOCK - real finding with evidence.'
    ExitCode = 1
    ExpectEligible = $false
  }
  @{
    Name = 'failover-soft-security-ineligible'
    Result = @"
## Findings
- HIGH: consider validating user input across the surface.
VERDICT: NEEDS-FIX
"@
    ExitCode = 0
    DetectSoftening = $true
    ExpectEligible = $false
  }
  @{
    Name = 'failover-soft-general-still-eligible'
    Result = @"
## Findings
- HIGH: consider validating user input across the surface.
VERDICT: NEEDS-FIX
"@
    ExitCode = 0
    DetectSoftening = $false
    ExpectEligible = $true
  }
)

foreach ($fc in $failoverCases) {
  $i++
  $total++
  $detectFlag = [bool]$fc.DetectSoftening
  $gotEligible = Test-FailoverEligible -ResultText $fc.Result -ExitCode $fc.ExitCode -DetectSoftening $detectFlag
  if ($gotEligible -ne $fc.ExpectEligible) {
    Write-Host ("selftest: FAIL {0}/{1} case={2} got={{eligible={3}}} expected={{eligible={4}}}" -f $i, $total, $fc.Name, $gotEligible, $fc.ExpectEligible)
    exit 1
  }
}

Write-Host ("selftest: PASS {0}/{1}" -f $total, $total)
exit 0
