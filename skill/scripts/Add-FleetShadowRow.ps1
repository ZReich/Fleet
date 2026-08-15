#requires -Version 5
<#
.SYNOPSIS
  Append one validated row to the light benchmark ledger (BENCH-shadow.jsonl).

.DESCRIPTION
  The heavy paired-implementation benchmark has its own recorder (Record-GrokBenchmark.ps1
  -> BENCH-grok45.jsonl, ~90 fields). This is the LIGHT ledger for plan / review / verdict /
  adversarial / effort-experiment pairs — historically hand-appended, which let graded
  lanes slip through unrecorded (e.g. the 2026-08-14 Grok-xhigh adversarial review). This
  writer makes appending a one-command, schema-checked step so the SKILL contract can make
  it mandatory: a graded pair with no ledger row is an incomplete run.

  Required keys: run, genre, primary, shadow, winner. Everything else (scores, notes,
  effort, per-finding detail) rides in -ExtraJson so the ledger stays heterogeneous.
  ts is auto-stamped (ISO-8601) when omitted. Appends exactly one compact JSON line.

.EXAMPLE
  ./Add-FleetShadowRow.ps1 -Run adv-xhigh-20260815 -Genre adversarial-review `
    -Primary 'gpt-5.6-sol@high' -Shadow 'grok-4.6@xhigh' -Winner grok-4.6 `
    -ExtraJson '{"effort_variant":"grok_xhigh_vs_sol_high","note":"..."}'

  ./Add-FleetShadowRow.ps1 -SelfTest
#>
param(
  [string]$LedgerPath,
  [string]$RepoRoot = (Get-Location).Path,
  [string]$Run,
  [string]$Genre,
  [string]$Primary,
  [string]$Shadow,
  [string]$Winner,
  [string]$Effort = 'high',
  [string]$Note = '',
  [string]$ExtraJson = '',
  [string]$Ts = '',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)

function Resolve-LedgerPath {
  param([string]$Explicit, [string]$Root)
  if ($Explicit) { return $Explicit }
  return (Join-Path $Root 'BENCH-shadow.jsonl')
}

function New-FleetShadowRow {
  # Build the row object; validate required keys; merge ExtraJson (extra never overrides
  # the required/core keys). Returns a compact single-line JSON string (no trailing newline).
  param(
    [string]$Run, [string]$Genre, [string]$Primary, [string]$Shadow, [string]$Winner,
    [string]$Effort, [string]$Note, [string]$ExtraJson, [string]$Ts
  )
  $missing = @()
  foreach ($p in @('Run','Genre','Primary','Shadow','Winner')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $p -ValueOnly))) { $missing += $p.ToLower() }
  }
  if ($missing.Count -gt 0) { throw "Add-FleetShadowRow: missing required field(s): $($missing -join ', ')" }

  $core = [ordered]@{
    ts      = if ([string]::IsNullOrWhiteSpace($Ts)) { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $Ts }
    run     = $Run
    genre   = $Genre
    primary = $Primary
    shadow  = $Shadow
    winner  = $Winner
    effort  = $Effort
  }
  if (-not [string]::IsNullOrWhiteSpace($Note)) { $core['note'] = $Note }

  if (-not [string]::IsNullOrWhiteSpace($ExtraJson)) {
    $extra = $null
    try { $extra = $ExtraJson | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Add-FleetShadowRow: -ExtraJson is not valid JSON: $($_.Exception.Message)" }
    if ($null -ne $extra) {
      foreach ($prop in $extra.PSObject.Properties) {
        if (-not $core.Contains($prop.Name)) { $core[$prop.Name] = $prop.Value }
      }
    }
  }
  return ($core | ConvertTo-Json -Depth 20 -Compress)
}

function Add-FleetShadowRowLine {
  param([string]$Path, [string]$Line)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  # Append one line with a trailing newline; create the file if absent.
  [IO.File]::AppendAllText($Path, ($Line + "`n"), $utf8)
}

function Invoke-SelfTest {
  $fail = 0
  function Check($cond, $msg) { if ($cond) { Write-Host "PASS $msg" } else { Write-Host "FAIL $msg"; $script:sfFail++ } }
  $script:sfFail = 0

  # required-field validation
  $threw = $false
  try { [void](New-FleetShadowRow -Run '' -Genre 'plan' -Primary 'a' -Shadow 'b' -Winner 'a' -Effort 'high' -Note '' -ExtraJson '' -Ts '') }
  catch { $threw = $true }
  Check $threw 'missing required field throws'

  # bad ExtraJson rejected
  $threw = $false
  try { [void](New-FleetShadowRow -Run 'r' -Genre 'plan' -Primary 'a' -Shadow 'b' -Winner 'a' -Effort 'high' -Note '' -ExtraJson '{not json' -Ts '') }
  catch { $threw = $true }
  Check $threw 'invalid ExtraJson throws'

  # good row: valid JSON, required keys present, ts auto-stamped
  $line = New-FleetShadowRow -Run 'r1' -Genre 'adversarial-review' -Primary 'gpt-5.6-sol@high' -Shadow 'grok-4.6@xhigh' -Winner 'grok-4.6' -Effort 'xhigh' -Note 'n' -ExtraJson '{"effort_variant":"xhigh_vs_high","score":9}' -Ts ''
  $obj = $line | ConvertFrom-Json
  Check ($obj.run -eq 'r1' -and $obj.genre -eq 'adversarial-review') 'core keys set'
  Check ($obj.winner -eq 'grok-4.6' -and $obj.effort -eq 'xhigh') 'winner/effort set'
  Check ($obj.effort_variant -eq 'xhigh_vs_high' -and $obj.score -eq 9) 'extra fields merged'
  Check (-not [string]::IsNullOrWhiteSpace([string]$obj.ts)) 'ts auto-stamped'

  # extra cannot override a core key
  $line2 = New-FleetShadowRow -Run 'r2' -Genre 'plan' -Primary 'a' -Shadow 'b' -Winner 'a' -Effort 'high' -Note '' -ExtraJson '{"winner":"HACKED"}' -Ts ''
  $obj2 = $line2 | ConvertFrom-Json
  Check ($obj2.winner -eq 'a') 'extra cannot override core key'

  # append + read back
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('flt-shadow-' + [guid]::NewGuid().ToString('n') + '.jsonl')
  try {
    Add-FleetShadowRowLine -Path $tmp -Line $line
    Add-FleetShadowRowLine -Path $tmp -Line $line2
    $lines = [IO.File]::ReadAllLines($tmp)
    Check ($lines.Count -eq 2) 'two lines appended'
    Check (($lines[0] | ConvertFrom-Json).run -eq 'r1' -and ($lines[1] | ConvertFrom-Json).run -eq 'r2') 'lines round-trip'
  } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }

  if ($script:sfFail -gt 0) { Write-Host "selftest: FAIL $($script:sfFail)"; exit 1 }
  Write-Host 'selftest: PASS 9/9'; exit 0
}

if ($SelfTest) { Invoke-SelfTest }

$line = New-FleetShadowRow -Run $Run -Genre $Genre -Primary $Primary -Shadow $Shadow -Winner $Winner -Effort $Effort -Note $Note -ExtraJson $ExtraJson -Ts $Ts
$path = Resolve-LedgerPath -Explicit $LedgerPath -Root $RepoRoot
Add-FleetShadowRowLine -Path $path -Line $line
Write-Host "shadow-row appended: $path"
Write-Output $line
