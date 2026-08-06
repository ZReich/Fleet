# PowerShell 5.1 footguns — MANDATORY checklist for every Grok/worker PS deliverable

Grok cannot run pwsh (no isolated worktree), so these bugs PARSE CLEAN and only crash when the
orchestrator runs `-SelfTest`. Every one below cost repair rounds on 2026-08-05/06. Any charter
that produces a `.ps1` MUST paste this list and require the worker to self-check against it.

## Variable collisions (case-INSENSITIVE — `$s` IS `$S`)
- NEVER name a loop var the lowercase of a counter: `$n`/`$N`, `$s`/`$S`, `$m`/`$M`, `$v`/`$V`,
  `$u`/`$U`. A `foreach ($s in …)` silently clobbers a `$S` counter → wrong output or a string
  where an int is expected. Use distinct names (`$rn`, `$sn`, `$fx`, `$mx`).
- `$home`/`$HOME`, `$host`, `$pid`, `$error`, `$input`, `$pwd`, `$args` are READ-ONLY automatics —
  assigning to them throws "Cannot overwrite variable HOME because it is read-only." Use `$lhome`,
  `$env:USERPROFILE`, etc.

## String interpolation
- `"$var:..."` is a DRIVE reference and fails to parse ("':' was not followed by a valid variable
  name"). Use `"${var}:..."`.

## null vs empty-string coercion (the #1 fixture bug — hit 3× today)
- A `[string]$Param = $null` parameter COERCES `$null` to `""`. If a test needs a genuine null
  (null vs empty distinction, `error.type:null`, `refusal_reason:null`), the param must be UNTYPED
  (`$Param = $null`) or `[object]`/`[AllowNull()]`. `[string]$x = $null` → `$x -eq ''`.
- `,$v` (unary comma) on an EMPTY array yields a 1-element array whose element is the empty array →
  a phantom `foreach` iteration. Iterate the object field directly, or guard on `.Count`.

## Arrays / JSON (PS 5.1)
- `ConvertTo-Json` unrolls a 1-element array to a scalar; `ConvertFrom-Json` keeps the LAST duplicate
  key and drops the rest. Force real JSON arrays when writing fixtures; reject duplicate/escaped keys
  when reading (a `\`-containing depth-1 key is never legitimate).
- `-replace 'FOO','bar'` is CASE-INSENSITIVE and matches SUBSTRINGS — `-replace 'STAGE',$s` also
  rewrites the lowercase `"stage"` KEY. Use `-creplace` for placeholder substitution, and require a
  space/`:` boundary so `HIGH-risk` doesn't match a `HIGH:` finding.
- `grep -E '[ \t]'` treats `\t` as the literal letter `t`, not a tab (a diagnostics-only gotcha).

## EOL / encoding
- Write UTF-8 **without BOM** (`New-Object System.Text.UTF8Encoding $false`). Match the file's
  existing LF/CRLF — a full-file EOL flip makes git see every line changed and can trip
  `git diff --check`. On this Windows box Grok tends to write CRLF; normalize touched files.

## Process / redirection
- `codex exec` and PS wrappers hang without null stdin. From the Bash tool, `-Prompt (Get-Content …)`
  is invalid POSIX sh — dispatch PS wrappers through the PowerShell tool or pass `-PromptFile`.

## The rule
Orchestrator MUST run the deliverable's `-SelfTest` (and a `Parser::ParseFile` check) BEFORE accepting
a PS lane as done. A "parses clean" self-report is not proof — Grok literally cannot execute it.
