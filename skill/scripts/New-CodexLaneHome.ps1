# Give a codex lane its OWN CODEX_HOME so parallel Sol/Terra lanes never share
# ~/.codex/models_cache.json. The shared cache is the root of BOTH the model_cache_skew
# (a foreign-version codex re-stamps it) AND the parallel-lane write race (every codex
# process rewrites the one cache each run). An isolated home means the lane's cache is
# written only by the pinned codex -> always self-stamped -> no renew-error, and no two
# lanes touch the same file. Auth is COPIED fresh each call so the token is current at
# launch; config is copied so model/MCP config still applies (Sol overrides model via -c).
#
# Emits ONE line: the isolated CODEX_HOME path (stdout). Warnings go to stderr. The caller
# sets $env:CODEX_HOME to this path for the codex child, then removes it in a finally.
# PS5.1-safe, ASCII only.
[CmdletBinding()]
param(
  [string]$Label = 'lane',
  [string]$SourceHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$Root = (Join-Path $env:TEMP 'fleet-codex-homes'),
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

# Reap isolated homes older than $maxAgeHours -- a lane whose wrapper crashed never ran
# its finally, so its home (with a ~54MB cache) leaks forever. No real lane runs this long,
# and an ACTIVE lane's home has a fresh LastWriteTime (codex rewrites the cache each run),
# so age-based reaping never touches a live lane. Fail-open: never block a launch on cleanup.
function Remove-StaleLaneHomes([string]$root, [double]$maxAgeHours) {
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
  $cutoff = (Get-Date).AddHours(-1 * $maxAgeHours)
  try {
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
      if ($d.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  catch { }
}

function New-LaneHome([string]$lbl, [string]$src, [string]$root) {
  # Unique per call: label + PID + guid so concurrent lanes never collide.
  $safe = ($lbl -replace '[^A-Za-z0-9._-]', '_')
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'lane' }
  # Reap crash-leaked homes before creating this one (self-healing hygiene).
  Remove-StaleLaneHomes $root 6.0
  $leaf = ('{0}-{1}-{2}' -f $safe, $PID, ([guid]::NewGuid().ToString('n').Substring(0, 8)))
  # NB: never name this $home -- $HOME/$home is a read-only automatic variable (ps51-footguns).
  $laneHome = Join-Path $root $leaf
  New-Item -ItemType Directory -Force -Path $laneHome | Out-Null
  # auth.json: required for the lane to authenticate; copy fresh (current token).
  $srcAuth = Join-Path $src 'auth.json'
  if (Test-Path -LiteralPath $srcAuth -PathType Leaf) { Copy-Item -LiteralPath $srcAuth -Destination (Join-Path $laneHome 'auth.json') -Force }
  else { [Console]::Error.WriteLine("WARN New-CodexLaneHome: no auth.json at $srcAuth; codex will fail to authenticate") }
  # config.toml: optional; copy if present so model/provider/MCP config still applies.
  $srcCfg = Join-Path $src 'config.toml'
  if (Test-Path -LiteralPath $srcCfg -PathType Leaf) { Copy-Item -LiteralPath $srcCfg -Destination (Join-Path $laneHome 'config.toml') -Force }
  return $laneHome
}

if ($SelfTest) {
  $fail = 0
  function Check([string]$n, [bool]$ok) { if ($ok) { Write-Output "PASS $n" } else { Write-Output "FAIL $n"; $script:fail++ } }
  $tmp = Join-Path $env:TEMP ('lanehome-selftest-' + [guid]::NewGuid().ToString('n'))
  $fakeSrc = Join-Path $tmp 'src'; $fakeRoot = Join-Path $tmp 'root'
  New-Item -ItemType Directory -Force -Path $fakeSrc | Out-Null
  Set-Content -LiteralPath (Join-Path $fakeSrc 'auth.json') -Value '{"t":1}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $fakeSrc 'config.toml') -Value 'model = "x"' -Encoding UTF8
  try {
    $h1 = New-LaneHome 'sol' $fakeSrc $fakeRoot
    $h2 = New-LaneHome 'sol' $fakeSrc $fakeRoot
    Check 'creates the home dir' (Test-Path -LiteralPath $h1 -PathType Container)
    Check 'copies auth.json' (Test-Path -LiteralPath (Join-Path $h1 'auth.json') -PathType Leaf)
    Check 'copies config.toml' (Test-Path -LiteralPath (Join-Path $h1 'config.toml') -PathType Leaf)
    Check 'two calls get DISTINCT homes (parallel-safe)' ($h1 -ne $h2)
    # missing auth: still creates home, warns (does not throw)
    $noAuthSrc = Join-Path $tmp 'noauth'; New-Item -ItemType Directory -Force -Path $noAuthSrc | Out-Null
    $h3 = New-LaneHome 'sol' $noAuthSrc $fakeRoot
    Check 'missing auth still returns a home (no throw)' (Test-Path -LiteralPath $h3 -PathType Container)
    Check 'label is sanitized into the path' ((Split-Path $h1 -Leaf) -like 'sol-*')
    # stale-home reaping: an old home is removed, a fresh one survives
    $staleHome = Join-Path $fakeRoot 'stale-1-deadbeef'; New-Item -ItemType Directory -Force -Path $staleHome | Out-Null
    (Get-Item -LiteralPath $staleHome).LastWriteTime = (Get-Date).AddHours(-24)
    New-LaneHome 'sol' $fakeSrc $fakeRoot | Out-Null   # triggers the reap
    Check 'stale home (>6h) is reaped on next create' (-not (Test-Path -LiteralPath $staleHome))
    Check 'fresh homes survive the reap' ((Test-Path -LiteralPath $h1) -and (Test-Path -LiteralPath $h2))
  }
  finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'Test-NewCodexLaneHome: passed (8 checks)'; exit 0 }
  Write-Output "Test-NewCodexLaneHome: FAILED ($fail)"; exit 1
}

Write-Output (New-LaneHome $Label $SourceHome $Root)
exit 0
