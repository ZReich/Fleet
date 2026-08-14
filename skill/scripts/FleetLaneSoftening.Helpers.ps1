# Dot-sourceable security-softening detector for Fleet security-review lanes.
# NO top-level side effects. Loaded by FleetLaneRefusal.Helpers.ps1 (which owns the
# HasNoFindings / HasFindingWithEvidence helpers these call at runtime).
# Purpose: a hosted security lane (Sol especially) often does NOT hard-refuse — it
# SOFTENS: returns a completed-review SHAPE (verdict + a generic finding) with generic
# SECURITY advice and zero exploit-path depth (no taint->sink, no attacker+verb chain, no
# vuln-class+mechanism, no file:line+vuln). Detect it so the slice re-dispatches
# (reason = hosted_refusal_soft). Synthesized from a 3-model spec-off (Grok 4.6 spine +
# GLM 5.3 / Kimi K3 grafts) and hardened by a Grok-4.6-xhigh adversarial review that
# found the two ship-killers this version fixes: (1) softening must be scoped to REAL
# security reviews (the caller owns that via -DetectSoftening; a general review in the
# canonical VERDICT/FINDINGS grammar must never be flagged), and (2) a security hedge is
# NECESSARY — a real finding with no generic-advice language is never soft, even if its
# vuln class is outside the depth lexicon. Lexical, deterministic, PS 5.1. 2026-08-14.

# Exploit-depth oracle: ANY match => real exploit-path finding, never soft. Every
# positive requires a MECHANISM — bare CWE id / bare "payload" / bare "source" / bare
# severity / bare file:line are NOT depth (that is exactly the hollow-review shape).
function Test-FleetLaneHasExploitDepth {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  $pats = @(
    '(?i)\b((attacker|user|caller|client|request)[- ]controlled|untrusted\s+(input|data|value|source))\b[\s\S]{0,100}?\b(sink|eval|invoke-expression|\biex\b|deseriali[sz]e|innerHTML|document\.write|os\.system|exec\s*\(|child_process|Invoke-Sqlcmd|ExecuteNonQuery)\b'
    '(?i)\b(attacker[- ]controlled|untrusted|taint(ed)?)\b[\s\S]{0,80}?\b(flows?\s+(in)?to|reaches|propagat\w+\s+to)\b[\s\S]{0,40}?\b(sink|eval|exec|query|deseriali[sz]e|command|template)\b'
    '(?i)\ban?\s+attacker\s+(can|could|is\s+able\s+to|may|would\s+be\s+able\s+to)\s+(read|write|inject|forge|bypass|execute|run|steal|exfiltrat\w+|escalat\w+|impersonat\w+|hijack|overwrite|delete|leak|invoke|call|reach|pivot|take\s*over|dump|enumerate)\b'
    '(?i)\b(CWE-\d{1,5}|CVE-\d{4}-\d{4,}|GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4})\b[\s\S]{0,120}?\b(via|through|because|allow\w*|enabl\w*|attacker|inject\w*|deseriali[sz]\w*|traversal|bypass|payload|gadget|unsanitiz\w*)\b'
    '(?i)\b(sql\s*inject|sqli|xss|cross-site\s+script|csrf|ssrf|xxe|rce|remote\s+code\s+exec|path\s*traversal|directory\s+traversal|lfi|rfi|deseriali[sz]e|insecure\s+deser\w*|prototype\s+pollut\w*|command\s+inject|code\s+inject|ssti|open\s+redirect|authz[- ]bypass|idor|request\s+smuggl\w*|ldap\s+inject|header\s+inject)\b[\s\S]{0,80}?\b(via|through|because|when|by\s+(sending|passing|injecting|crafting)|payload|gadget|unsanitiz\w*|unescaped|string[- ]concat|format[- ]string|user[- ]controlled|attacker[- ]controlled)\b'
    '(?i)\b(via|through|by\s+(sending|passing|injecting|crafting)|payload|gadget|unsanitiz\w*|unescaped|string[- ]concat)\b[\s\S]{0,80}?\b(sql\s*inject|sqli|xss|csrf|ssrf|xxe|rce|path\s*traversal|deseriali[sz]e|command\s+inject|ssti|authz[- ]bypass|idor)\b'
    '(?i)(?<![A-Za-z0-9])[\w./\\-]+\.(ps1|psm1|py|js|jsx|ts|tsx|java|go|cs|rb|php|pl|rs|c|cpp|sh):[1-9]\d*[^\r\n]{0,160}?\b(inject(?:ion)?|xss|csrf|ssrf|xxe|rce|sqli|gadget|payload|taint|deseriali[sz]|traversal|unauth(?:enticated)?|authz[- ]bypass|missing\s+auth|attacker[- ]controlled)\b'
    '(?i)\b(inject(?:ion)?|xss|csrf|ssrf|xxe|rce|sqli|gadget|deseriali[sz]|traversal|authz[- ]bypass|missing\s+auth)\b[^\r\n]{0,160}?(?<![A-Za-z0-9])[\w./\\-]+\.(ps1|psm1|py|js|jsx|ts|tsx|java|go|cs|rb|php|pl|rs|c|cpp|sh):[1-9]\d*'
    '(?i)\b(missing|broken|absent|bypass(?:es|ed|ing)?|skip(?:s|ped|ping)?|no)\s+(the\s+)?(authz|authn|auth(?:entication|orization)?(\s+check)?|access[- ]control|permission\s+check|csrf\s+(token|check)|ownership\s+check)\b'
    '(?i)\b(gadget\s+chain|ysoserial|objectinputstream|__reduce__|pickle\.loads|union\s+select|\bor\s+1=1\b|\.\./\.\./|<script\b|javascript:\w|document\.cookie)\b'
    '(?i)\b(unauthenticated\s+(endpoint|route|access|caller|request|admin|api)|without\s+(a\s+)?(login|session|auth(?:entication)?|token|csrf\s+token)|auth(?:entication|orization)?\s+(is\s+)?(missing|open|absent|not\s+enforced))\b'
  )
  foreach ($p in $pats) { if ($Text -match $p) { return $true } }
  return $false
}

# Terminal clean-review recognizer (local to softening so shared consumers are untouched):
# the review declares nothing to fix. Covers the fixture dialect AND production grammar
# (FINDINGS: none), so a clean GO/NO-GO with an earlier prose bullet is never soft.
function Test-FleetLaneReviewIsClean {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
  if (Test-FleetLaneHasNoFindings -Text $Text) { return $true }
  if ($Text -match '(?im)^\s*#{0,3}\s*FINDINGS?\s*[:：]?\s*(none|n/?a|nothing|no\s+issues)\b') { return $true }
  # Only a LINE-ANCHORED clean declaration counts (adversarial WATCH: an unanchored
  # "...no issues with the limiter" mid-review must not launder a softened body clean).
  if ($Text -match '(?im)^\s*(there\s+(are|were)\s+)?(no|zero)\s+(security\s+)?(findings|issues|vulnerabilit\w+|weaknesses|concerns|exploitable\s+\w+)\s*(found|identified|detected|present)?\s*[.;:]?\s*$') { return $true }
  if (($Text -match '(?i)\bVERDICT:\s*(CLEAR|PASS|CLEAN|SAFE|SECURE|APPROVE|GO)\b') -and -not (Test-FleetLaneHasFindingWithEvidence -Text $Text)) { return $true }
  return $false
}

# Softening: completed security-review SHAPE, generic SECURITY hedge present, zero exploit
# depth. The hedge is NECESSARY (Grok-xhigh review): a real finding with no generic-advice
# language is never soft, even if its vuln class is outside the depth lexicon. Markers are
# security-shaped; scope to real security reviews is the CALLER's job (-DetectSoftening).
# Returns $true = IS softened.
function Test-FleetLaneSecuritySoftening {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  if (Test-FleetLaneReviewIsClean -Text $Text) { return $false }
  if (Test-FleetLaneHasExploitDepth -Text $Text) { return $false }
  $soft = @(
    '(?i)\b(validate|saniti[sz]e|escape|encode)\s+(and\s+\w+\s+)?(all\s+)?(user\s+|client\s+|untrusted\s+)?(inputs?|parameters?|user\s+data)\b'
    '(?i)\bconsider\s+(validating|saniti[sz]ing|escaping|encoding|parameteri[sz]ing|adding\s+(input\s+)?validation|using\s+(parameteri[sz]ed|prepared|an?\s+allowlist|input\s+validation))'
    '(?i)\bensure\s+(proper|adequate|appropriate|correct)\s+(auth\w*|input\s+validation|validat\w*|saniti\w*|access\s+control|encoding|escaping)'
    '(?i)\b(should|must|needs?\s+to)\s+(be\s+)?(validated|saniti[sz]ed|escaped|encoded)\b'
    '(?i)\bfollow\s+(security\s+|secure[- ]coding\s+)?best\s+practices\b'
    '(?i)\b(apply|adopt|enforce|implement)\s+(the\s+)?(principle\s+of\s+least\s+privilege|least[- ]privilege|defense[- ]in[- ]depth|input\s+validation|output\s+encoding|proper\s+auth\w*)\b'
    '(?i)\b(improve|strengthen|harden)\s+(the\s+|your\s+)?(input\s+validation|auth\w*|access\s+control|security\s+controls|validation)\b'
    '(?i)\breview\s+(your\s+|the\s+)?(auth\w*|security|access[- ]control)\s+(controls|logic|configuration|posture)\b'
    '(?i)\bpotentially\s+(unsafe|insecure|vulnerable|exploitable)\b'
    '(?i)\b(recommend|suggest)\s+(a\s+)?(closer\s+look|further\s+review|manual\s+review|additional\s+(review|scrutiny))\b'
    '(?i)\b(add|apply)\s+(stronger|tighter|additional)\s+(checks|validation|controls|guards)\b'
  )
  foreach ($s in $soft) { if ($Text -match $s) { return $true } }
  return $false
}
