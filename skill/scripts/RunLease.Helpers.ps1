# Single source of truth for "is this run lease abandoned?".
#
# This predicate was copy-pasted into Enter-FleetRunLease.ps1 and Test-FleetRunLease.ps1,
# and Approve-ClaudeCli.ps1 carried a FOURTH, WEAKER variant that tested `expires_at`
# alone. The copies drifted in exactly the way that matters: an abandoned run (owner PID
# dead, or heartbeat older than the staleness window) was reclaimable by Enter — a new
# run could take the lease — while the promotion gate still read the same file as an
# ACTIVE RUN and refused to promote a CLI for the rest of the lease's 24h TTL. Two
# consumers, opposite verdicts, same bytes on disk.
#
# Dot-source this from the caller's BODY with $PSScriptRoot (never from a param default —
# PS 5.1 does not resolve $PSScriptRoot there).

function Test-FleetLeaseReclaimable($lease, [datetimeoffset]$now, [int]$staleHours) {
  # Unparseable expiry is treated as abandoned: a lease we cannot read cannot be trusted
  # to be alive, and the alternative is a permanently unclearable file.
  try { if ([datetimeoffset]$lease.expires_at -le $now) { return $true } } catch { return $true }
  $leasePid = 0; try { $leasePid = [int]$lease.owner_pid } catch { }
  if ($leasePid -gt 0 -and -not (Get-Process -Id $leasePid -ErrorAction SilentlyContinue)) { return $true }
  $hb = $null; try { $hb = [datetimeoffset]$lease.heartbeat_at } catch { }
  if ($null -ne $hb -and $hb.AddHours($staleHours) -le $now) { return $true }
  return $false
}

# Janitor-only liveness-read: reclaim ONLY when owner is CONCLUSIVELY dead.
# Fresh heartbeat = LIVE (transient shells leave dead PIDs with live runs).
# Missing/invalid PID, access denied, enum failure, or stale HB + live/unknown PID = LIVE.
# Does NOT change Enter/Renew/Exit reclaim semantics (use Test-FleetLeaseReclaimable there).
function Test-FleetOwnerConclusivelyDead($lease, [datetimeoffset]$now, [int]$staleHours) {
  try {
    $hb = $null
    try { $hb = [datetimeoffset]$lease.heartbeat_at } catch { }
    # Absence is not evidence of staleness.  Janitor deletion needs positive proof of
    # BOTH a parseable stale heartbeat and a dead owner PID.
    if ($null -eq $hb) { return $false }
    # Fresh heartbeat is positive liveness evidence even when owner PID is already dead.
    if ($hb.AddHours($staleHours) -gt $now) { return $false }
    $leasePid = 0
    try { $leasePid = [int]$lease.owner_pid } catch { return $false }
    if ($leasePid -le 0) { return $false }
    try {
      $proc = Get-Process -Id $leasePid -ErrorAction Stop
      if ($null -ne $proc) { return $false }
      return $false
    } catch {
      if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return $true }
      return $false
    }
  } catch { return $false }
}

# 32-byte CSPRNG secret + independent 16-byte key id (32 lowercase hex). Never log/return secret.
# Returns a single PSCustomObject (not a bare hashtable) so pipeline assignment never
# enumerates DictionaryEntry rows into the caller's stdout capture.
function New-FleetRunLeaseHmacMaterial {
  $keyBytes = New-Object byte[] 32
  $idBytes = New-Object byte[] 16
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($keyBytes)
    $rng.GetBytes($idBytes)
  }
  finally { $rng.Dispose() }
  $sb = New-Object System.Text.StringBuilder 32
  foreach ($b in $idBytes) { [void]$sb.Append($b.ToString('x2')) }
  # PSCustomObject (not bare hashtable) so assignment never enumerates DictionaryEntry.
  [pscustomobject]@{
    KeyId = $sb.ToString()
    KeyB64 = [Convert]::ToBase64String($keyBytes)
  }
}

# Owner-only ACL on lease file. Fail closed — no world-readable fallback.
# No pipeline output (Enter/Renew stdout must stay a single lease path line).
function Set-FleetLeaseFileAcl([string]$Path) {
  if ([string]::IsNullOrEmpty($Path)) { throw 'Fleet run lease ACL path is required.' }
  try {
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $user) { throw 'current user SID is null' }
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($user, $rights, $allow)
    [void]$acl.AddAccessRule($rule)
    [System.IO.File]::SetAccessControl($Path, $acl)
  }
  catch {
    throw ('Fleet run lease ACL could not be established (fail closed): ' + $_.Exception.Message)
  }
}

# Load ACTIVE lease key by externally-supplied RunId. Never take run_id from a receipt.
function Get-FleetRunLeaseKey {
  param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId,
    [ValidateRange(1, 24)][int]$StaleHeartbeatHours = 2
  )
  $path = "$env:USERPROFILE\.codex\fleet\run-leases\$RunId.json"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Fleet run lease not found for key load: $RunId"
  }
  try { $lease = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "Fleet run lease unparseable for key load: $path" }

  $schema = [string]$lease.schema_version
  if ($schema -ne '2') {
    throw "Fleet run lease schema unsupported for key load: $schema"
  }
  if ([string]$lease.run_id -ne $RunId) {
    throw 'Fleet run lease identity mismatch for key load.'
  }
  $now = [datetimeoffset]::Now
  if (Test-FleetLeaseReclaimable $lease $now $StaleHeartbeatHours) {
    throw "Fleet run lease is reclaimable (expired/stale/dead-owner); key load refused: $RunId"
  }

  $keyB64 = [string]$lease.receipt_hmac_key_b64
  if ([string]::IsNullOrEmpty($keyB64)) {
    throw 'Fleet run lease missing receipt_hmac_key_b64.'
  }
  try { $keyBytes = [Convert]::FromBase64String($keyB64) }
  catch { throw 'Fleet run lease receipt_hmac_key_b64 is not valid base64.' }
  if ($keyBytes.Length -ne 32) {
    throw ("Fleet run lease receipt_hmac_key_b64 is not 32 bytes (got " + $keyBytes.Length + ').')
  }
  $keyId = [string]$lease.receipt_hmac_key_id
  if ($keyId -notmatch '^[0-9a-f]{32}$') {
    throw 'Fleet run lease receipt_hmac_key_id is invalid (need 32 lowercase hex).'
  }
  return @{ KeyId = $keyId; KeyBytes = $keyBytes }
}
