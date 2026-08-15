# Cache contract (prompt assembly)

Source: `.fleet/research2/R1-synthesis.md` (fleet-research2-20260729, Q1 items 1+2 ADOPT).
Baseline BEFORE: `.fleet/research2/baseline-speed.json`.

## Byte-stable prefix rule

Order what the model receives as:

1. **Stable prefix** (byte-identical across waves that share the same role/charter): system prompt + charter static body + schema.
2. **After the cache breakpoint only**: `run_id`, timestamps, per-wave deltas, UUIDs, and other per-invocation noise.

Never inject run identity or wall-clock into the system prompt or the front of the charter.

## Per-vendor mechanics

### Anthropic (Opus / Claude lanes)

- Explicit `cache_control` on the **last stable block**.
- Use **1h TTL** when the same prefix is reused across waves (plan → implement → review → arbitrate gaps exceed 5m).
- Min cacheable prefix: **512 tokens** (Opus 5).

### OpenAI GPT-5.6 (Sol / Terra / Codex lanes)

- Explicit `prompt_cache_breakpoint` + `prompt_cache_key=fleet:{role}:{charter_hash}`.
- **Honest limitation (K3 finding):** GPT-5.6 implicit breakpoint now lands on the **latest message** and can return `cached_tokens=0` on identical prefixes. Explicit breakpoint + key required for Sol/Terra cache hits.

### CLI wrapper honesty

Fleet CLI wrappers may not expose these API params today. Where a CLI cannot pass `cache_control` / `prompt_cache_breakpoint` / `prompt_cache_key`, this contract still binds:

1. **Charter authoring order** (stable prefix first; dynamics after breakpoint).
2. **Dispatch staggering** (below).

Do not claim API-level cache hits until wrapper result JSON shows them.

## Concurrent-cold-miss rule (Anthropic)

Verbatim (K3 report / Anthropic): **"a cache entry only becomes available after the first response begins."**

Simultaneous one-wave dispatch → all-cold misses (N cold writes).

**Staggered wave dispatch:**

1. Launch **slowest voice first**.
2. Launch remaining voices after that voice's first response begins, or after a **~30–60s** lag.
3. Converts **N cold cache writes → 1 write + N−1 reads**.

Metric: `first_result_s` across the wave.

## Config stability

Keep **effort / thinking** settings constant for the life of a cached prefix. Changing effort or thinking mid-prefix **invalidates** the message cache. Prefer one session per phase with a fixed effort tier.

## Measured payoff

Cite arXiv **2601.06007v2** (synthesis Q1 item 1): on cacheable turns,

- cost **−41..−80%**
- TTFT **−13..−31%**

**REJECT** naive full-context caching (all 3 research lanes): can **raise** TTFT. Cache the system/stable prefix only.

## Measurement

From wrapper result JSONs:

| Metric | Definition |
| --- | --- |
| cache hit rate | `cached_prompt_tokens / final_prompt_tokens` |
| first_result_s | time to first model output |
| duration_s | full lane wall time |

**Fail condition (honest negative):** after adoption, cache hit rate **AND** `first_result_s` both stay flat → wrapper not passing cache controls, or prefix not byte-stable.

BEFORE baseline: `.fleet/research2/baseline-speed.json`.
AFTER: next comparable fleet run; append spans to `BENCH-lanes.jsonl`; compare per-phase medians + hit rate. One AFTER run is directional only (`<30 eligible => ?` on lane-fit stats).
