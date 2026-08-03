# Robust blind-grade parser shared by Fleet benchmark aggregation. Every grader's output
# is recoverable; do not let a dropped brace, a code fence, or the Grok worker-JSON
# envelope discard a real grade. Returns the parsed object (with a .grades property) or
# $null. Usage: . Parse-FleetGrades.ps1 ; $g = Get-FleetGrades -Path <file> -Grader grok
param()

function ConvertFrom-JsonLoose {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  # Strip code fences and locate the grades object.
  $t = $Text -replace '(?s)```[A-Za-z]*', ''
  $idx = $t.IndexOf('{"grades"')
  if ($idx -lt 0) { $idx = $t.IndexOf('{ "grades"') }
  if ($idx -lt 0) { $idx = $t.IndexOf('{') }
  if ($idx -lt 0) { return $null }
  $sub = $t.Substring($idx)
  # Trim to the last closing brace, then brace-balance-repair (append missing '}').
  $lc = $sub.LastIndexOf('}')
  if ($lc -ge 0) { $sub = $sub.Substring(0, $lc + 1) }
  $open = ([regex]::Matches($sub, '\{')).Count
  $close = ([regex]::Matches($sub, '\}')).Count
  $cands = @()
  $cands += $sub
  if ($open -gt $close) { $cands += ($sub + ('}' * ($open - $close))) }
  foreach ($c in $cands) {
    try { $o = $c | ConvertFrom-Json -ErrorAction Stop; if ($o.PSObject.Properties['grades']) { return $o } } catch { }
  }
  return $null
}

function Get-FleetGrades {
  param([Parameter(Mandatory)][string]$Path, [ValidateSet('sol', 'grok', 'glm', 'opus', 'auto')][string]$Grader = 'auto')
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $raw = [IO.File]::ReadAllText($Path)
  # Grok: wrapper JSON -> .response (worker JSON) -> .notes (grades JSON, cleanly nested).
  if ($Grader -in @('grok', 'auto')) {
    try {
      $resp = ($raw | ConvertFrom-Json).response
      if ($resp) {
        try { $worker = $resp | ConvertFrom-Json; if ($worker.notes) { $g = ConvertFrom-JsonLoose ([string]$worker.notes); if ($g) { return $g } } } catch { }
        $g = ConvertFrom-JsonLoose ([string]$resp); if ($g) { return $g }
      }
    } catch { }
  }
  # Opus: wrapper JSON -> .response (grades JSON).
  if ($Grader -in @('opus', 'auto')) {
    try { $resp = ($raw | ConvertFrom-Json).response; if ($resp) { $g = ConvertFrom-JsonLoose ([string]$resp); if ($g) { return $g } } } catch { }
  }
  # GLM: text with heartbeat lines; Sol: raw JSON stdout. Both: strip heartbeats, loose-parse.
  $clean = ($raw -split "`r?`n" | Where-Object { $_ -notmatch '"type":"heartbeat"' }) -join "`n"
  return (ConvertFrom-JsonLoose $clean)
}
