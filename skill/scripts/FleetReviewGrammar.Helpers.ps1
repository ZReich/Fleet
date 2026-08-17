# Single-source review verdict grammar (Sol-locked, fleet-reviewburn-20260811).
# The SAME file owns (a) the human-readable grammar block pasted into every review charter and
# (b) the parser that consumes voice output. A self-test asserts the block's own examples parse,
# so grammar and parser can never drift apart silently. ASCII only, PS 5.1-safe.
$script:FleetReviewGrammarVersion = 'canonical-v1'
$script:FleetReviewSeverities = @('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')

function Get-FleetReviewGrammarBlock {
  return @'
=== REQUIRED VERDICT GRAMMAR (verbatim, machine-parsed) ===
Your review MUST end with this terminal block as the LAST lines of your output (nothing after it):

Either (no findings):
VERDICT: GO
FINDINGS: none

Or (with findings):
VERDICT: NO-GO
FINDINGS:
- HIGH | F001 | scripts/Example.ps1:123 | Concise actionable finding

Rules (violations make the review unusable and it will be re-dispatched):
- Allowed severities: CRITICAL | HIGH | MEDIUM | LOW.
- Finding line syntax: "- <severity> | <id> | <repo-relative-path>:<line> | <summary>".
- "FINDINGS: none" is only valid with "VERDICT: GO".
- "VERDICT: NO-GO" requires at least one finding line.
- Any CRITICAL or HIGH finding requires "VERDICT: NO-GO".
- "VERDICT: GO" may carry only MEDIUM or LOW findings.
- No text of any kind after the terminal block. ASCII only. No aliases (APPROVE/SHIP/LGTM).
=== END VERDICT GRAMMAR ===
'@
}

function Get-FleetGrammarTerminalLines([string]$Text) {
  # Trailing non-empty lines starting at the last 'VERDICT:' line; $null when absent.
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $lines = [regex]::Split($Text.TrimEnd(), '\r?\n')
  $vIdx = -1
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i].Trim() -cmatch '^VERDICT:') { $vIdx = $i; break }
  }
  if ($vIdx -lt 0) { return $null }
  $block = New-Object System.Collections.ArrayList
  for ($i = $vIdx; $i -lt $lines.Count; $i++) {
    $t = $lines[$i].Trim()
    if ($t.Length -gt 0) { [void]$block.Add($t) }
  }
  # vIdx 0 = output IS the terminal block; slicing 0..0 would echo the VERDICT line into
  # Before and false-trip the duplicate check (Sol LOW 2026-08-11).
  $before = if ($vIdx -eq 0) { '' } else { $lines[0..($vIdx - 1)] -join "`n" }
  return @{ Block = @($block); Before = $before }
}

# Lossless punctuation transliteration for the TERMINAL BLOCK only (from the last 'VERDICT:'
# line to EOF). GLM 5.3 reliably emits U+2014/U+2192/curly quotes in finding summaries and the
# strict parser rightly rejects non-ASCII there (2026-08-15 x2, 2026-08-16 x2 = both GLM seats
# lost, panel 4/5). This does NOT relax the parser: it maps typographic punctuation to its ASCII
# equivalent (em dash -> '-', arrow -> '->', curly quote -> '"') and leaves any other non-ASCII
# untouched so the parser still fails closed on real garbage. Body text above the block is never
# modified. Callers keep the raw bytes beside the normalized result.
$script:FleetAsciiPunctuationMap = [ordered]@{
  ([string][char]0x2014) = '-'    # em dash
  ([string][char]0x2013) = '-'    # en dash
  ([string][char]0x2012) = '-'    # figure dash
  ([string][char]0x2212) = '-'    # minus sign
  ([string][char]0x2192) = '->'   # rightwards arrow
  ([string][char]0x21D2) = '=>'   # rightwards double arrow
  ([string][char]0x2190) = '<-'   # leftwards arrow
  ([string][char]0x2194) = '<->'  # left right arrow
  ([string][char]0x2018) = "'"    # left single quote
  ([string][char]0x2019) = "'"    # right single quote
  ([string][char]0x201C) = '"'    # left double quote
  ([string][char]0x201D) = '"'    # right double quote
  ([string][char]0x2026) = '...'  # ellipsis
  ([string][char]0x00A0) = ' '    # nbsp
  ([string][char]0x2022) = '-'    # bullet
  ([string][char]0x00D7) = 'x'    # multiplication sign
  ([string][char]0x2264) = '<='   # less-than-or-equal
  ([string][char]0x2265) = '>='   # greater-than-or-equal
  ([string][char]0x2260) = '!='   # not-equal
}

function ConvertTo-FleetAsciiTerminalBlock([string]$Text) {
  # Returns @{ Text = <normalized>; Changed = <bool>; Replacements = <int> }.
  if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Text = $Text; Changed = $false; Replacements = 0 } }
  $lines = [regex]::Split($Text, '\r?\n')
  $vIdx = -1
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i].Trim() -cmatch '^VERDICT:') { $vIdx = $i; break }
  }
  if ($vIdx -lt 0) { return @{ Text = $Text; Changed = $false; Replacements = 0 } }
  $n = 0
  for ($i = $vIdx; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    foreach ($k in $script:FleetAsciiPunctuationMap.Keys) {
      $c = ([regex]::Matches($l, [regex]::Escape($k))).Count
      if ($c -gt 0) { $n += $c; $l = $l.Replace($k, [string]$script:FleetAsciiPunctuationMap[$k]) }
    }
    $lines[$i] = $l
  }
  $nl = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
  return @{ Text = ($lines -join $nl); Changed = ($n -gt 0); Replacements = $n }
}

function Test-FleetGrammarBodyCleanForLegacyGo([string]$Body) {
  # Legacy alias is valid ONLY when the body carries no finding/negative/refusal signal.
  if ($Body -cmatch '\b(CRITICAL|HIGH|MEDIUM|LOW)\b') { return $false }
  if ($Body -match '(?m)^\s*[-*][^\r\n]*:\d+') { return $false }          # evidence-shaped bullet
  if ($Body -cmatch '\b(NO-GO|REQUEST CHANGES|REJECT|BLOCKED|BLOCK)\b') { return $false }
  if ($Body -cmatch '(?m)^\s*FINDINGS\s*:') { return $false }
  if ($Body -match '(?i)\b(required blocker|must fix before|cannot assist|can''t assist|unable to review|i refuse)\b') { return $false }
  return $true
}

function Parse-FleetReviewVerdict([string]$Text) {
  $res = [ordered]@{
    grammar_version = $script:FleetReviewGrammarVersion; parse_mode = ''
    valid = $false; verdict = ''; findings_count = 0; max_severity = ''
    no_findings = $false; errors = @()
  }
  $err = New-Object System.Collections.ArrayList
  $term = Get-FleetGrammarTerminalLines $Text
  if ($null -eq $term) {
    [void]$err.Add('no VERDICT line found')
    $res.errors = @($err); return [pscustomobject]$res
  }
  $block = @($term.Block)
  $vLine = $block[0]
  if (($block -join '') -cmatch '[^\x00-\x7F]') { [void]$err.Add('terminal block not ASCII') }
  if (([regex]::Matches([string]$term.Before, '(?m)^\s*VERDICT:')).Count -gt 0) { [void]$err.Add('duplicate VERDICT line') }
  if ($vLine -ceq 'VERDICT: GO' -and $block.Count -eq 1) {
    # Deterministic legacy compatibility (Sol D3): bare terminal GO, body provably clean.
    if ((Test-FleetGrammarBodyCleanForLegacyGo ([string]$term.Before)) -and $err.Count -eq 0) {
      $res.parse_mode = 'legacy-go-alias-v1'; $res.valid = $true; $res.verdict = 'GO'; $res.no_findings = $true
      $res.errors = @(); return [pscustomobject]$res
    }
    [void]$err.Add('bare VERDICT: GO with findings-like/negative/refusal body content')
    $res.parse_mode = 'legacy-go-alias-v1'; $res.errors = @($err); return [pscustomobject]$res
  }
  $res.parse_mode = 'canonical-v1'
  if ($vLine -cnotmatch '^VERDICT: (GO|NO-GO)$') {
    [void]$err.Add("malformed verdict line: $vLine")
    $res.errors = @($err); return [pscustomobject]$res
  }
  $verdict = $Matches[1]
  if ($block.Count -lt 2) { [void]$err.Add('missing FINDINGS section') }
  else {
    $fLine = $block[1]
    $findings = @()
    if ($fLine -ceq 'FINDINGS: none') {
      if ($block.Count -gt 2) { [void]$err.Add('text after FINDINGS: none') }
      if ($verdict -cne 'GO') { [void]$err.Add('FINDINGS: none requires VERDICT: GO') }
      # A no-findings claim must not contradict the body (Terra H1 2026-08-11): prose that
      # carries severity tokens, evidence bullets, negative verdicts, or refusal markers
      # cannot be laundered by a clean terminal block. Fails closed to full redispatch.
      if (-not (Test-FleetGrammarBodyCleanForLegacyGo ([string]$term.Before))) {
        [void]$err.Add('FINDINGS: none contradicts findings-like/negative/refusal body content')
      }
      $res.no_findings = $true
    } elseif ($fLine -ceq 'FINDINGS:') {
      if ($block.Count -lt 3) { [void]$err.Add('FINDINGS: with no finding lines') }
      for ($i = 2; $i -lt $block.Count; $i++) {
        $ln = $block[$i]
        # Path must be normalized repo-relative (no roots, no traversal), line >= 1 (Sol M4).
        if ($ln -cmatch '^- (CRITICAL|HIGH|MEDIUM|LOW) \| [A-Za-z0-9._-]+ \| (?![A-Za-z]:)(?!/)(?!\\)(?![^|\s]*\.\.)[^|\s]+:[1-9]\d* \| .+$') { $findings += $Matches[1] }
        else { [void]$err.Add("malformed finding line: $ln") }
      }
    } else { [void]$err.Add("malformed FINDINGS line: $fLine") }
    $res.findings_count = $findings.Count
    if ($findings.Count -gt 0) {
      foreach ($s in $script:FleetReviewSeverities) { if ($findings -ccontains $s) { $res.max_severity = $s; break } }
      if (($findings -ccontains 'CRITICAL' -or $findings -ccontains 'HIGH') -and $verdict -cne 'NO-GO') {
        [void]$err.Add('CRITICAL/HIGH finding requires VERDICT: NO-GO')
      }
    }
    if ($verdict -ceq 'NO-GO' -and $findings.Count -eq 0) { [void]$err.Add('NO-GO requires at least one finding') }
  }
  $res.verdict = $verdict
  $res.valid = ($err.Count -eq 0)
  $res.errors = @($err)
  return [pscustomobject]$res
}

function Test-FleetReviewVerdict([string]$Text) {
  return [bool](Parse-FleetReviewVerdict $Text).valid
}
