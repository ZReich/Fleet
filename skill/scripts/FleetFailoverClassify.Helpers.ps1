# Dot-sourceable parent-outcome classifier for review failover.
# NO top-level side effects. Loaded by Invoke-FleetReviewFailover.ps1 AFTER
# FleetLaneRefusal.Helpers.ps1 (whose Get-FleetLaneResponseText / Test-FleetLaneRefusal /
# Test-FleetLaneHasFindingWithEvidence / Test-FleetLaneHasNoFindings these call at runtime).
# Classifies a refused-parent receipt into: refusal (dispatch failover), negative (no
# failover), transport (retry), or ineligible. Split out of the failover orchestrator as a
# real boundary (classification vs dispatch), 2026-08-14.

function Test-CompletedNegative([string]$Body, [int]$ExitCode) {
  if ($ExitCode -ne 0) { return $false }
  $msg = Get-FleetLaneResponseText -Raw $Body
  if ([string]::IsNullOrWhiteSpace($msg)) { return $false }
  if ($msg -match '(?i)\bVERDICT:\s*(BLOCK|NEEDS-FIX)\b') { return $true }
  if (Test-FleetLaneHasFindingWithEvidence -Text $msg) {
    if ($msg -match '(?i)\bVERDICT:\s*(CLEAR|APPROVE|PASS|WATCH)\b') { return $false }
    if (Test-FleetLaneHasNoFindings -Text $msg) { return $false }
    return $true
  }
  return $false
}

function Get-ParentKind($Rec, [string]$ResultBody) {
  $oc = [string]$Rec.outcome
  $ex = 0; try { $ex = [int]$Rec.exit_code } catch { $ex = 0 }
  if ($oc -ceq 'refused') { return 'refusal' }
  if ($oc -ceq 'completed') {
    # A softened SECURITY review (completed shape, generic hedge, zero exploit depth) is a
    # refusal that needs failover — check it BEFORE Test-CompletedNegative, which would
    # otherwise classify the same "VERDICT: NO-GO + finding + hedge" body as 'negative' and
    # strand it (integrity reclassifies it refused => C<R deadlock). Role-gated: a general
    # review is never soft-classified. SignedLane marks soft-at-source, so this is the
    # belt-and-suspenders path for any non-SignedLane emitter (adversarial follow-up A).
    $secRole = ([string]$Rec.review_role -ceq 'security-review')
    if ($secRole) {
      $rfSoft = Test-FleetLaneRefusal -Result $ResultBody -ExitCode $ex -IsSecuritySensitive $secRole -DetectSoftening $secRole
      if ($rfSoft.refused) { return 'refusal' }
    }
    if (Test-CompletedNegative $ResultBody $ex) { return 'negative' }
    $sec = ([string]$Rec.review_role -ceq 'security-review') -or ([string]$Rec.review_profile -match 'security')
    $rf = Test-FleetLaneRefusal -Result $ResultBody -ExitCode $ex -IsSecuritySensitive $sec
    if ($rf.refused) { return 'refusal' }
    return 'negative'  # completed success/non-refusal is never a failover trigger
  }
  if ($oc -ceq 'failed') { return 'transport' }
  if ($ex -ne 0) {
    $sec = ([string]$Rec.review_role -ceq 'security-review')
    $rf = Test-FleetLaneRefusal -Result $ResultBody -ExitCode $ex -IsSecuritySensitive $sec
    if ($rf.refused) { return 'refusal' }
    return 'transport'
  }
  return 'ineligible'
}
