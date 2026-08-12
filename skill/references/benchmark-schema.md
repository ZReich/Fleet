# Grok benchmark record v7

## Worktree-pool lifecycle telemetry

`%USERPROFILE%\.codex\fleet\worktree-pool.jsonl` emits one schema-versioned JSON object per
pool lifecycle event. `acquire_complete` and `release_complete` are mandatory; an append
failure is visible to the caller and makes its lifecycle command nonzero. Pool rows use
`event`, `outcome`, `reason`, `repo_key`, `slot_id`, `run_id`, `branch`, `base_sha`,
`ownership`, `wait_ms`, `duration_ms`, `registered_worker_count`, and `quarantine_reason`.
They must not contain `lease_id`, environment contents, prompts, tokens, command output, or secrets.

Use one JSON object per primary/shadow task. Keep exclusions and no-contests;
never count them as losses. `result` compares worker-final candidates before the
five-voice integration review. The selected pre/post fields measure that later
review's value. `selected_candidate` records the gate-passing candidate and may
differ from the score winner when the higher-scoring candidate fails a hard gate.

## Required v7 fields extending the v4 record

```json
{
  "grok_first_pass_session_id": "019f... or empty for exclusions",
  "grok_review_session_id": "different 019f... or empty for exclusions",
  "grok_config_sha256": "64 hex characters from grok inspect --json",
  "grok_review_effort": "high",
  "effort_experiment_id": "",
  "effort_variant": "none",
  "effort_escalation_reason": "",
  "primary_first_pass_components": {"correctness": 36, "spec": 24, "tests": 13, "maintainability": 9, "scope": 8},
  "grok_first_pass_components": {"correctness": 35, "spec": 22, "tests": 13, "maintainability": 7, "scope": 7},
  "primary_diff_lines": 120,
  "grok_diff_lines": 180,
  "primary_scope_violations": 0,
  "grok_scope_violations": 0,
  "primary_new_dependencies": 0,
  "grok_new_dependencies": 0,
  "primary_fallow_new_findings": 0,
  "grok_fallow_new_findings": 0,
  "primary_test_failures": 0,
  "grok_test_failures": 0,
  "changed_files_budget": 12,
  "diff_line_budget": 500,
  "max_source_file_lines_budget": 300,
  "primary_largest_source_file_lines": 220,
  "grok_largest_source_file_lines": 280,
  "primary_budget_violations": 0,
  "grok_budget_violations": 0,
  "selected_candidate": "primary",
  "selected_pre_final_review_score": 90,
  "selected_post_final_review_score": 96,
  "selected_post_review_components": {
    "correctness": 39,
    "spec": 25,
    "tests": 14,
    "maintainability": 9,
    "scope": 9
  },
  "final_review_seconds": 240,
  "final_review_catches_total": 2,
  "final_review_catches_by_model": {
    "sol": 0,
    "terra": 1,
    "glm": 1,
    "grok": 0,
    "opus": 0
  },
  "final_review_execution_status_by_model": {
    "sol": "complete", "terra": "complete", "glm": "outage",
    "grok": "complete", "opus": "complete"
  },
  "final_review_exclusion_reason_by_model": {
    "sol": "", "terra": "", "glm": "Pi transport stalled",
    "grok": "", "opus": ""
  },
  "final_review_wall_seconds_by_model": {
    "sol": 120, "terra": 90, "glm": 510, "grok": 75, "opus": 183
  },
  "final_review_unique_catches_by_model": {
    "sol": 1, "terra": 0, "glm": 0, "grok": 1, "opus": 0
  },
  "final_review_false_positives_by_model": {
    "sol": 0, "terra": 0, "glm": 0, "grok": 1, "opus": 0
  },
  "final_review_adopted_findings_by_model": {
    "sol": 1, "terra": 1, "glm": 0, "grok": 1, "opus": 1
  },
  "selected_post_review_gate_passed": true,
  "primary_first_pass_telemetry": {
    "status": "complete",
    "source": "worker_session_log",
    "session_id": "019f...",
    "parse_errors": 0,
    "input_tokens": 12000,
    "cached_input_tokens": 8000,
    "output_tokens": 1500,
    "reasoning_tokens": 600,
    "total_tokens": 13500,
    "inference_ms": 42000,
    "ttft_ms_p50": 1800,
    "output_tokens_per_second": 35.7,
    "attempts": 1,
    "tool_calls": 12,
    "tool_failures": 0,
    "actual_cost_usd": null,
    "actual_cost_source": "not_exposed",
    "api_equivalent_cost_usd_upper_bound": null,
    "api_rate_card": "",
    "energy_kwh": null,
    "energy_source": "provider_not_exposed",
    "energy_method": "unavailable",
    "hardware": null,
    "provider_region": null,
    "pue": null,
    "measurement_window_start_utc": null,
    "measurement_window_end_utc": null,
    "measured_at_utc": null,
    "carbon_gco2e": null,
    "carbon_source": "requires measured energy plus grid-intensity provenance",
    "carbon_method": "unavailable",
    "grid_intensity_gco2e_per_kwh": null,
    "grid_intensity_source": null
  }
}
```

Also require `primary_review_telemetry` and `final_review_telemetry_by_model`
(`sol`, `terra`, `glm`, `grok`, `opus`). Every one repeats the complete telemetry
shape above. Use that full shape with `status/source=unavailable` and null core
metrics when a phase exposes no trustworthy usage data.

Reviewer execution status is separate from usage telemetry. Allowed values are
`complete`, `outage`, `excluded`, `no_contest`, and `invalid`. Non-complete voices
require an exclusion reason. A complete review may still have unavailable usage.

Current Grok CLI `0.2.99` maps requested `xhigh`/`max` to effective `high`.
Use `effort_variant=none` for normal records and do not create high/xhigh trial
pairs until version-keyed live proof shows distinct effective effort. Record or
chart unsupported variants only as excluded capability, never as completed
comparisons. For exclusions/no-contests, use `selected_candidate` =
`none`, null selected scores, zero final-review seconds/catches, and a false
post-review gate.

Select the highest-scoring hard-gate-clean candidate. If neither completed
candidate is clean, retain the score result but use `selected_candidate=none`
with the same null/zero review fields. A selected candidate may finish five-voice
review with `selected_post_review_gate_passed=false`; Grok counts as adopted only
when it is selected and that final gate passes.

Grok first pass and self-review currently use effective `high`; requested aliases
must not be treated as distinct benchmark variants.

## Phase telemetry

Run first-pass and self-review as separate Grok sessions. The recorder reads both
from `~/.grok/logs/unified.jsonl`. Output nests primary first-pass/review, Grok
first-pass/review, and Sol/Terra/GLM/Grok/Opus final-review telemetry under
`phase_telemetry`, with observed input, cached-input, completion, separate reasoning,
observed total-token, inference-time, TTFT, throughput, attempts, and tool-success
fields. `total_tokens` is input plus completion; reasoning remains separate because
the local log does not prove whether provider completion usage already includes it.

The recorder leaves actual OAuth/subscription cost null. It calculates an API
list-price upper bound using the July 8, 2026 Grok 4.5 rates of USD 2/M input and
USD 6/M output, charging cached input at the full input rate and adding reasoning
tokens again when provider inclusion semantics are unavailable. This is a
deliberate upper bound, not the user's subscription cost.

Do not estimate energy from tokens. Populate energy/carbon only from a provider
measurement or controlled infrastructure telemetry with model hardware, region,
PUE, energy window, grid-intensity source, and timestamp. Keep null otherwise.

## Derived reporting metrics

Compute downstream rather than duplicating them in each row: cache-hit rate,
score gain per review minute, score per million tokens, API-equivalent dollars
per passing candidate, scope violations per 1,000 diff lines, review catch yield
by model, adoption rate, retry rate, and final-review score lift.

---

# v8 additions — candidate-neutral, provenance, estimand, TCO

v8 keeps every honest v7 bone (no_contest != loss, null unproven costs, config SHA)
and closes the gaps that made v7 unable to support honest cross-model rankings. v7
rows stay readable; new rows SHOULD emit v8. `Record-GrokBenchmark.ps1` accepts both.

1. **Candidate-neutral records.** Replace Grok-centric required fields with
   `candidate_a` / `candidate_b` objects, each: `model`, `provider`, `version`,
   `transport` (wrapper + hash), `effort`, and capability flags
   (`web`, `subagents`, `memory`). Grok-specific `grok_*` fields become nullable and
   are populated only when a candidate IS Grok.
2. **Estimand — never mix.** `estimand`: `standardized_model` | `optimized_system`.
   `standardized_model` requires identical prompt, context, effort, tools, retries,
   and review budget on both sides; only these rows may feed model rankings or routing.
   `optimized_system` runs each model in its strongest native harness (e.g. the
   asymmetric `grok_review_only`); operationally useful, **banned from the leaderboard**.
   Relabel existing asymmetric rows `optimized_system`.

   **Declared-treatment exception (added 2026-08-10, run `fleet-grok-effort-ab-20260810`).**
   A controlled A/B whose ENTIRE purpose is to vary one harness dimension is still
   `standardized_model`, provided the varied dimension is declared up front and every other
   dimension in the list above is held identical. Such a row MUST carry:
   `treatment_variable` (exactly one of `effort` | `model` | `tools` | `context` | `harness`),
   `control` (the value the current default uses), and `treatment` (the value under test).
   Rows with a `treatment_variable` are comparable only to rows sharing the SAME
   `treatment_variable`; they never pool with unrestricted `standardized_model` rows and
   never feed a cross-model leaderboard — an effort A/B measures a knob, not a model.
   Two or more varied dimensions is NOT this exception: that is `optimized_system`.
   Omitting `treatment_variable` while arms differ is a mislabeled row, not a shortcut.
3. **Sampling provenance.** `sampling_policy` (`auto|explicit|none`), `sample_seed`,
   `selection_probability`, `task_stratum` (`mechanical|standard|hard|review`),
   `shadow_origin`, `shadow_mode` (`post_hoc_async|in_band_explicit`),
   `slot_pressure_skip`, `shadow_overrun`, `base_drift`, `adopted_into_run`,
   `critical_path_delay_seconds` (MUST be 0 for auto rows — enforced, not hoped).
4. **Grader provenance.** `graders[]` = `{model, family, version, prompt_hash}`;
   `position_swap`, `position_consistent`, `grader_agreement`, `grader_score_stddev`,
   `score_ci_low` / `score_ci_high` (Wilson), `self_family_excluded` (bool). No grader
   scores its own output; no row is decided solely by a candidate's own family.
5. **Coverage honesty.** `coverage_scope` on every row AND every aggregate (e.g.
   "grok-eligible, no design decision"); a blended cross-stratum rate WITHOUT
   `coverage_scope` is invalid by rule, so a Grok-eligible win-rate is never read as a
   global verdict. Aggregates also carry `scoring_window_id` and `n_in_window`.
6. **Tier-aware review map.** `final_review_*_by_model` is keyed by the actually
   selected tier voices; `not_selected_by_mode` retained; add `voice_substituted`
   (degraded-mode substitution, e.g. Opus pin-drift -> GLM).
7. **TCO honesty.** `total_wall_seconds`, `orchestration_overhead_seconds`, and
   `incident_recovery` so "quality per total cost including orchestration and
   incidents" is computable — the one metric that can prove or refute Fleet itself.
8. Effort example fixed to `high` (CLI `0.2.99` maps xhigh/max -> effective high).
9. **New ledger** `BENCH-shadow.jsonl` beside `BENCH-grok45.jsonl` for post-hoc async
   shadow rows; quarterly rollup of win-rate by model x stratum x coverage_scope with
   Wilson CIs. Strata reach decision-grade at >=30 pairs; no promotion/demotion until a
   CI excludes parity; no rubric re-tuning mid-window.

Blind rubric (unchanged core): correctness 40, spec 25, tests/evidence 15,
maintainability 10, scope 10 — ~80% is mechanically measurable from gate output
(tests, typecheck, Fallow new findings, diff/scope/do-not-touch violations); only
maintainability and spec-nuance need LLM judgment, and that slice runs two fast
graders with mandatory position swap.

---

# v4 benchmark methodology (decision-grade upgrades)

Applies to every scored round from 2026-07-18-v4 on. Fixes the stated v3 weaknesses
(n=1 topic, single-pass grading, set-composition variance, no human anchor).

1. **n >= 3 topics.** A round reviews >=3 distinct artifacts (e.g. the Fleet contract,
   a real frozen code-review packet, a research-synthesis task). Per-model score = mean
   across topics; report per-topic spread. Kills single-topic genre bias (the exact thing
   that misread Kimi at 71.0 on a review-only rubric).
2. **Two grading passes per grader per artifact,** independent sessions, averaged;
   populate `grader_score_stddev`. A grader whose two passes differ >10 points on the
   same artifact gets a third pass; persist all passes.
3. **Fixed-set grading (RULE).** Never compare scores across different anonymization
   sets (the 5-set vs 6-set lesson: it moved Sol/GLM several points). Adding a reviewer
   re-grades the WHOLE set and supersedes the old table.
4. **Human-anchored calibration slice.** The owner (or Fable as a family-caveated proxy
   anchor) blind-grades 2 randomly drawn reviews per round with the same rubric. Report
   LLM-vs-anchor agreement per grader; a grader persistently >10 points off anchor is
   down-weighted in synthesis. Fable is Anthropic-family like Opus and must never be the
   sole grader on a pair involving Opus.
5. **Deterministic hallucination column.** With `citation_evidence` attached (Kimi
   wrapper: `citation_verified`, `cited_but_unfetched[]`, `fetched_url_count`), the
   halluc flag = `cited_but_unfetched.Count > 0` PLUS grader judgment only on
   claim-vs-source fidelity. Applies to every web-enabled lane.
6. **Tie discipline.** Deltas <5 points are ties; no routing/lane-ownership change on a
   tie. Rankings publish grader-spread error bars (min/max across graders) next to means.
7. **`harness_variant` field** (`native_kimi_code | claude_code_proxy | ...`): harness
   A/B rows are `estimand=optimized_system` and NEVER pool with model-ranking rows.
8. **`citation_evidence` object** on any web-lane candidate: `{citation_verified,
   cited_url_count, fetched_url_count, cited_but_unfetched[]}`.
