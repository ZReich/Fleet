# Heal the codex model-cache version-stamp skew before a Sol/Terra lane launches.
#
# Root cause (proven 2026-08-07): codex writes its OWN version into
# ~/.codex/models_cache.json as `client_version`, and refetches the catalog every run.
# When a DIFFERENT codex version has stamped that shared cache (an interactive codex on a
# different version, or a since-removed alpha that left `client_version: 0.147.0`), the
# running codex hits the TTL-renew path against a foreign-version entry, fails to
# deserialize it (the server catalog omits `supports_reasoning_summaries`), and emits
# `failed to renew cache TTL` / `supports_reasoning_summaries` on stderr -- the skew that
# Invoke-Sol surfaces. Injecting the field does NOT help: codex refetches and overwrites
# it immediately. The only durable, version-independent fix is to remove the stale cache
# when its stamp doesn't match the codex about to run, so codex rebuilds it clean (no
# renew-error path). Steady-state cost is zero: it only acts on a genuine version mismatch.
#
# Prints one line: codex-cache: <cleared stale stamp X != Y | stamp matches Y (no-op) | ...>
# Fail-open: any parse/IO problem is a no-op (never block a Sol launch over cache hygiene).
[CmdletBinding()]
param(
  # Version of the codex that is about to run. Default: the approved pin.
  [string]$CodexVersion,
  [string]$CachePath   = (Join-Path $env:USERPROFILE '.codex\models_cache.json'),
  [string]$ApprovedClis = (Join-Path $env:USERPROFILE '.codex\fleet\approved-clis.json'),
  [switch]$Quiet,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }
$utf8 = New-Object System.Text.UTF8Encoding $false

if ($SelfTest) {
  $fail = 0
  $dir = Join-Path $env:TEMP ("mccache-selftest-" + $PID)
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $self = $PSCommandPath
  function Check([string]$name, [bool]$ok) { if ($ok) { Write-Output "PASS $name" } else { Write-Output "FAIL $name"; $script:fail++ } }
  # mismatch -> cleared
  $c = Join-Path $dir 'a.json'; '{"client_version":"0.147.0","models":[{"slug":"x"}]}' | Set-Content -LiteralPath $c -Encoding UTF8
  & $self -CachePath $c -CodexVersion '0.146.1' -Quiet | Out-Null
  Check 'mismatch stamp is cleared' (-not (Test-Path -LiteralPath $c))
  # match -> kept
  $c = Join-Path $dir 'b.json'; '{"client_version":"0.146.1","models":[{"slug":"x"}]}' | Set-Content -LiteralPath $c -Encoding UTF8
  & $self -CachePath $c -CodexVersion '0.146.1' -Quiet | Out-Null
  Check 'matched stamp is kept' (Test-Path -LiteralPath $c)
  # no stamp -> kept (no-op)
  $c = Join-Path $dir 'c.json'; '{"models":[]}' | Set-Content -LiteralPath $c -Encoding UTF8
  & $self -CachePath $c -CodexVersion '0.146.1' -Quiet | Out-Null
  Check 'no-stamp cache is left untouched' (Test-Path -LiteralPath $c)
  # missing cache -> no throw
  $c = Join-Path $dir 'nope.json'
  $null = & $self -CachePath $c -CodexVersion '0.146.1' -Quiet
  Check 'missing cache is a clean no-op' ($true)
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  if ($fail -eq 0) { Write-Output 'Test-RepairCodexModelsCache: passed (4 checks)'; exit 0 } else { Write-Output "Test-RepairCodexModelsCache: FAILED ($fail)"; exit 1 }
}

# Resolve the expected version: explicit param, else the approved-clis codex pin.
if ([string]::IsNullOrWhiteSpace($CodexVersion)) {
  if (Test-Path -LiteralPath $ApprovedClis -PathType Leaf) {
    try { $CodexVersion = ([IO.File]::ReadAllText($ApprovedClis, $utf8) | ConvertFrom-Json).clis.codex.version } catch {}
  }
}
if ([string]::IsNullOrWhiteSpace($CodexVersion)) { Say 'codex-cache: no expected version known (no-op)'; exit 0 }

if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) { Say 'codex-cache: no cache yet (no-op)'; exit 0 }
try { $doc = [IO.File]::ReadAllText($CachePath, $utf8) | ConvertFrom-Json -ErrorAction Stop }
catch { Say 'codex-cache: unparseable (no-op)'; exit 0 }

$stamp = $null
if ($doc -and $doc.PSObject.Properties['client_version']) { $stamp = [string]$doc.client_version }
if ([string]::IsNullOrWhiteSpace($stamp)) { Say 'codex-cache: no client_version stamp (no-op)'; exit 0 }

if ($stamp -eq $CodexVersion) { Say ("codex-cache: stamp matches {0} (no-op)" -f $CodexVersion); exit 0 }

# Mismatch: a foreign-version codex stamped this cache. Remove it so the running codex
# rebuilds clean and never hits the renew-error skew. Back up once for forensics.
$bak = "$CachePath.skew-$stamp.bak"
try { if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $CachePath -Destination $bak -Force } } catch {}
try { Remove-Item -LiteralPath $CachePath -Force } catch { Say "codex-cache: mismatch $stamp != $CodexVersion but remove failed (no-op): $($_.Exception.Message)"; exit 0 }
Say ("codex-cache: cleared stale stamp {0} != {1} (codex will rebuild clean)" -f $stamp, $CodexVersion)
exit 0
