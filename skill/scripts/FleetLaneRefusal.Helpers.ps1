# Dot-sourceable refusal detector for Fleet multi-model routing.
# NO top-level side effects. Callers: . (Join-Path $PSScriptRoot 'FleetLaneRefusal.Helpers.ps1')
# Contract: Test-FleetLaneRefusal returns { refused = bool; reason = enum-or-null }.
#   reasons: content_filter:*, policy_decline, capability_decline, hosted_refusal_soft,
#   security_empty_verdict, transport_error, null.
# Contract: Test-FailoverEligible returns bool (stricter failover gate).

# Security-softening oracle (Test-FleetLaneHasExploitDepth / Test-FleetLaneSecuritySoftening).
. (Join-Path $PSScriptRoot 'FleetLaneSoftening.Helpers.ps1')

function ConvertTo-FleetLaneStraightApostrophe {
  param([AllowNull()][string]$Text)
  if ($null -eq $Text) { return '' }
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  return ($Text -replace ([char]0x2019), "'")
}

function Get-FleetLaneResponseText {
  param([AllowNull()][string]$Raw)
  if ($null -eq $Raw) { return '' }
  if ([string]::IsNullOrEmpty($Raw)) { return '' }
  $trimmed = $Raw.Trim()
  if ($trimmed.Length -eq 0) { return '' }
  # Wrapper JSON: extract model body from response and/or verdict, never envelope keys.
  if ($trimmed.StartsWith('{')) {
    try {
      $obj = $trimmed | ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $obj) {
        $names = @($obj.PSObject.Properties | ForEach-Object { $_.Name })
        $hasResponse = ($names -contains 'response')
        $hasVerdict = ($names -contains 'verdict')
        $looksWrapper = $hasResponse -or $hasVerdict -or (
          ($names -contains 'status') -and (
            ($names -contains 'lane') -or
            ($names -contains 'model') -or
            ($names -contains 'observed_model') -or
            ($names -contains 'failure_category')
          )
        )
        if ($looksWrapper) {
          $parts = New-Object System.Collections.Generic.List[string]
          if ($hasResponse -and ($null -ne $obj.response)) {
            $resp = [string]$obj.response
            if (-not [string]::IsNullOrWhiteSpace($resp)) {
              [void]$parts.Add($resp)
            }
          }
          if ($hasVerdict -and ($null -ne $obj.verdict)) {
            $ver = ([string]$obj.verdict).Trim()
            if ($ver.Length -gt 0) {
              if ($ver -match '^(?i)(BLOCK|NEEDS-FIX|CLEAR|APPROVE|WATCH|PASS|FAIL)$') {
                [void]$parts.Add(('VERDICT: {0}' -f $ver))
              }
              else {
                [void]$parts.Add($ver)
              }
            }
          }
          if ($parts.Count -eq 0) { return '' }
          return ($parts -join "`n")
        }
      }
    }
    catch { }
  }
  return $Raw
}

function Test-FleetLaneReviewSubstance {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  # Completed review only: real VERDICT, evidence-bearing finding, or explicit no-findings.
  # Bare severity alone does NOT count (refusal + "HIGH" stays a refusal).
  if (Test-FleetLaneHasVerdictLine -Text $Text) { return $true }
  if (Test-FleetLaneHasFindingWithEvidence -Text $Text) { return $true }
  if (Test-FleetLaneHasNoFindings -Text $Text) { return $true }
  return $false
}

function Test-FleetLaneHasSubstantiveProse {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  $t = $Text.Trim()
  $words = [regex]::Matches($t, '\b\w{2,}\b')
  if ($words.Count -ge 5) { return $true }
  if ($t.Length -ge 40) { return $true }
  return $false
}

function Test-FleetLaneHasVerdictLine {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return [bool]($Text -match '(?i)\bVERDICT:\s*(GO|NO-GO|BLOCK|NEEDS-FIX|CLEAR|APPROVE|WATCH|PASS|FAIL)\b')
}

function Test-FleetLaneHasFindingWithEvidence {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  # Severity token must carry evidence (not a bare word alone).
  if ($Text -match '(?i)\b(CRITICAL|HIGH|MEDIUM|LOW)\b(:\s+|\s+[-]\s+)\S+') { return $true }
  if ($Text -match '(?i)\S+:\d+[^\r\n]{0,80}?\b(CRITICAL|HIGH|MEDIUM|LOW)\b') { return $true }
  if ($Text -match '(?i)\b(CRITICAL|HIGH|MEDIUM|LOW)\b[^\r\n]{0,80}?\S+:\d+') { return $true }
  return $false
}

function Test-FleetLaneHasNoFindings {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return [bool]($Text -match '(?i)\b(no findings|none material|zero findings|no material findings)\b')
}

function Test-FleetLaneContentFilter {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  if ($Text -match '(?i)flagged for possible cybersecurity risk') {
    return 'content_filter:codex_cyber_flag'
  }
  if ($Text -match '(?i)Trusted Access for Cyber') {
    return 'content_filter:trusted_access'
  }
  return $null
}

function Test-FleetLanePolicyDecline {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  $t = ConvertTo-FleetLaneStraightApostrophe -Text $Text
  # I'm not able to / I'm unable to / I can't / I won't (apostrophe forms).
  if ($t -match "(?i)\bI'?m\s+(not\s+able\s+to|unable\s+to|can(?:not|'t)|won'?t)\b") { return $true }
  # First-person decline + action verb (expanded grammar).
  if ($t -match "(?i)\bI\s+(can(?:\s+not|not|'t)|won(?:'t)|will\s+not|unable\s+to|not\s+able\s+to|do(?:\s+not|n't))\b[\s\S]{0,120}?\b(review|provide|assist|help|comply|complete|perform|continue|do\s+that)\b") {
    return $true
  }
  if ($t -match '(?i)\b(must\s+decline|have\s+to\s+decline)\b') { return $true }
  if ($t -match '(?i)\b(policy|safety\s+guidelines)\b[\s\S]{0,120}?\b(prevents|prohibits|does\s+not\s+allow\s+me|cannot\s+allow\s+me)\b') {
    return $true
  }
  # Impersonal decline: "this falls outside what I can", "I do not / don't ... this".
  if ($t -match '(?i)\bthis\s+falls\s+outside\s+what\s+I\s+can\b') { return $true }
  if ($t -match "(?i)\bI\s+(do(?:\s+not|n't))\b[\s\S]{0,80}?\bthis\b") { return $true }
  return $false
}

function Test-FleetLaneCapabilityDecline {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  $t = ConvertTo-FleetLaneStraightApostrophe -Text $Text
  if ($t -match "(?i)\bI'?m\s+(not\s+able\s+to|unable\s+to)\b") { return $true }
  if ($t -match "(?i)\bI\s+(don(?:'t)|do\s+not)\s+have\s+the\s+(capability|ability|tools|access\s+to)\b") {
    return $true
  }
  # do not|don't|cannot + have access|have the access
  if ($t -match "(?i)\b(do(?:\s+not|n't)|can(?:not|'t))\s+have\s+(the\s+)?access\b") {
    return $true
  }
  return $false
}

function New-FleetLaneRefusalResult {
  param(
    [bool]$Refused,
    $Reason = $null
  )
  return [pscustomobject]@{
    refused = $Refused
    reason  = $Reason
  }
}

# Given a lane's captured result (raw text or wrapper JSON), exit code, and
# IsSecuritySensitive, classify model refusal for orchestrator reroute.
# Exit code alone never determines refusal.
# Precedence: explicit content_filter / policy_decline / capability_decline WIN
# over bare severity. Completed review (VERDICT line, evidence-bearing finding,
# or no-findings) wins over quoted refusal literals. Bare HIGH/CRITICAL alone
# never promotes a decline into a completion.
# security_empty_verdict = blank body OR no review substance AND no substantive prose.
# Nonzero exit with no refusal signal stays transport (refused=$false).
function Test-FleetLaneRefusal {
  param(
    [AllowNull()][string]$Result,
    [int]$ExitCode = 0,
    [bool]$IsSecuritySensitive = $false,
    # Softening detection is OFF by default and gated SEPARATELY from IsSecuritySensitive:
    # it must run ONLY on lanes whose signed review_role is 'security-review' (role, NOT
    # profile — a general-role lane under a security-sensitive profile stays off), never on
    # every hosted completion — a general review in the canonical VERDICT/FINDINGS grammar
    # must never be classified soft (adversarial-review CRITICAL, Grok+GLM concur
    # 2026-08-14). IsSecuritySensitive still drives security_empty_verdict.
    [bool]$DetectSoftening = $false
  )

  $message = Get-FleetLaneResponseText -Raw $Result
  $message = ConvertTo-FleetLaneStraightApostrophe -Text $message

  $hasSubstance = Test-FleetLaneReviewSubstance -Text $message

  # 1) content_filter — explicit decline wins over bare severity (no substance).
  $cf = Test-FleetLaneContentFilter -Text $message
  if ($null -ne $cf) {
    if (-not $hasSubstance) {
      return (New-FleetLaneRefusalResult -Refused $true -Reason $cf)
    }
  }

  # 2) policy / capability declines — same precedence vs bare severity.
  if (Test-FleetLanePolicyDecline -Text $message) {
    if (-not $hasSubstance) {
      return (New-FleetLaneRefusalResult -Refused $true -Reason 'policy_decline')
    }
  }
  if (Test-FleetLaneCapabilityDecline -Text $message) {
    if (-not $hasSubstance) {
      return (New-FleetLaneRefusalResult -Refused $true -Reason 'capability_decline')
    }
  }

  # Real completed review (after explicit-decline checks) is never a refusal —
  # UNLESS it is a softened security review: completed SHAPE, zero exploit depth.
  # This branch replaces the old blind substance short-circuit that was the hole.
  if ($hasSubstance) {
    if ($DetectSoftening -and ($ExitCode -eq 0) -and (Test-FleetLaneSecuritySoftening -Text $message)) {
      return (New-FleetLaneRefusalResult -Refused $true -Reason 'hosted_refusal_soft')
    }
    return (New-FleetLaneRefusalResult -Refused $false -Reason $null)
  }

  # 3) security_empty_verdict — blank OR no substance AND no substantive prose only.
  if ($IsSecuritySensitive -and ($ExitCode -eq 0)) {
    $blank = [string]::IsNullOrWhiteSpace($message)
    $hasProse = Test-FleetLaneHasSubstantiveProse -Text $message
    if ($blank -or (-not $hasProse)) {
      return (New-FleetLaneRefusalResult -Refused $true -Reason 'security_empty_verdict')
    }
  }

  # Nonzero exit with no refusal signal => transport, not refusal.
  if ($ExitCode -ne 0) {
    return (New-FleetLaneRefusalResult -Refused $false -Reason 'transport_error')
  }

  return (New-FleetLaneRefusalResult -Refused $false -Reason $null)
}

# Failover eligibility: exit 0 + substantive completed review + not refused.
# Stricter than hosted refusal: bare severity does NOT override an explicit
# content_filter / policy_decline / capability_decline signal — those require
# a real VERDICT: line (not a bare severity token) to be eligible.
function Test-FailoverEligible {
  param(
    [AllowNull()][string]$ResultText,
    [int]$ExitCode,
    # Pass $true ONLY when the failover is for a genuine security review, so a softened
    # completion cannot itself serve as the failover. Default $false preserves the
    # general-lane contract. Never pass $true for general reviews (would deadlock the gate).
    [bool]$DetectSoftening = $false
  )

  if ($ExitCode -ne 0) { return $false }

  $message = Get-FleetLaneResponseText -Raw $ResultText
  $message = ConvertTo-FleetLaneStraightApostrophe -Text $message

  $hasVerdict = Test-FleetLaneHasVerdictLine -Text $message
  $hasFinding = Test-FleetLaneHasFindingWithEvidence -Text $message
  $hasNone = Test-FleetLaneHasNoFindings -Text $message
  if (-not ($hasVerdict -or $hasFinding -or $hasNone)) {
    return $false
  }

  $cf = Test-FleetLaneContentFilter -Text $message
  $policy = Test-FleetLanePolicyDecline -Text $message
  $cap = Test-FleetLaneCapabilityDecline -Text $message
  if (($null -ne $cf) -or $policy -or $cap) {
    if (-not $hasVerdict) { return $false }
  }

  $refusal = Test-FleetLaneRefusal -Result $ResultText -ExitCode $ExitCode -DetectSoftening $DetectSoftening
  if ($refusal.refused) { return $false }

  return $true
}
