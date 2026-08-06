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
)

$total = $cases.Count
$i = 0
foreach ($c in $cases) {
  $i++
  $got = Test-FleetLaneRefusal -Result $c.Result -ExitCode $c.ExitCode -IsSecuritySensitive $c.IsSecuritySensitive
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
)

foreach ($fc in $failoverCases) {
  $i++
  $total++
  $gotEligible = Test-FailoverEligible -ResultText $fc.Result -ExitCode $fc.ExitCode
  if ($gotEligible -ne $fc.ExpectEligible) {
    Write-Host ("selftest: FAIL {0}/{1} case={2} got={{eligible={3}}} expected={{eligible={4}}}" -f $i, $total, $fc.Name, $gotEligible, $fc.ExpectEligible)
    exit 1
  }
}

Write-Host ("selftest: PASS {0}/{1}" -f $total, $total)
exit 0
