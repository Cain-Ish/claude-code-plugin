# cost-router — reference

Deep reference for cost-router. The [README](../README.md) covers what it is and how to use it; this file holds the details (contracts, pricing, full settings) that don't belong on the landing page.

## Commands & agents

| Name | Invocation | Summary |
|---|---|---|
| orchestrate | `/cost-router:orchestrate <task>` | Classify → plan (Opus, if needed) → execute (Sonnet/Haiku) → verify → log |
| model-route | `/cost-router:model-route <task>` | Advisory tier recommendation + rationale (no dispatch) |
| setup | `/cost-router:setup` | Consent-based `opusplan` + second-brain-aware configuration |

Agents: `cr-planner` (Opus), `cr-implementer` (Sonnet), `cr-scout` (Haiku).

## Why no blanket `CLAUDE_CODE_SUBAGENT_MODEL`

That env var is highest-precedence — it overrides every per-agent `model:` pin, including the careful tiering other plugins set (e.g. second-brain pins Haiku for search, Sonnet for its workers). Setting it would silently make those agents more expensive (or less capable). cost-router routes **per-dispatch** instead (the `model:` key on each Task call — verified working on this gateway), and `/cost-router:setup` warns if you try to set a blanket floor while second-brain is installed.

## Full settings

| Variable | Default | Purpose |
|---|---|---|
| `COST_ROUTER_OPUS_CAP_USD` | `5.0` | Daily Opus spend cap (USD) |
| `COST_ROUTER_AUTOROUTE` | `on` | `off` disables the per-prompt classifier nudge |
| `COST_ROUTER_BANNER` | `on` | `off` suppresses the SessionStart budget banner |
| `COST_ROUTER_LEDGER` | `${SB_BRAIN_DIR:-~/.second-brain}/opus-budget.json` | Path to the shared Opus-budget ledger |
| `COST_ROUTER_EVENTS` | `${SB_BRAIN_DIR:-~/.second-brain}/cost-router-events.jsonl` | Path to the routing-events log |

## Pricing reference (2026-06-09)

| Model | Input $/Mtok | Output $/Mtok | vs Sonnet |
|---|---|---|---|
| Opus 4.8 | $5 | $25 | 1.67× |
| Sonnet 4.6 | $3 | $15 | 1× |
| Haiku 4.5 | $1 | $5 | 0.33× |

## Cross-plugin contracts

cost-router and second-brain integrate by **shared file formats**, not code — each ships its own reader/writer and degrades gracefully when the other is absent.

### Contract A — shared Opus-budget ledger
**Path:** `${COST_ROUTER_LEDGER:-${SB_BRAIN_DIR:-$HOME/.second-brain}/opus-budget.json}`
```json
{ "date": "2026-06-09", "opus_cost_usd": 0.42, "opus_calls": 7, "cap_usd": 5.0 }
```
Before an Opus call, check `opus_cost_usd < cap_usd` (cap from `COST_ROUTER_OPUS_CAP_USD`). After the call, add its cost (`in/1e6×$5 + out/1e6×$25`). When `date` differs from today, reset to today with zeroed counters. Over budget → fall back to Sonnet. Producers/consumers: `cost-router/scripts/opus-budget.sh`, second-brain `mcp/src/tools/persona-think.ts`.

### Contract B — routing events (the learning loop)
**Path:** `${COST_ROUTER_EVENTS:-${SB_BRAIN_DIR:-$HOME/.second-brain}/cost-router-events.jsonl}` (append-only JSONL)
```json
{"ts":"2026-06-09T18:00:00Z","task":"add retry to uploader","tier":"DO","models":["sonnet"],"units":3,"escalated":false,"outcome":"ok","committed":true}
```
**Producer:** `/orchestrate` and the per-prompt hook, via `cost-router/scripts/route-log.sh`. **Consumer:** second-brain's `scripts/cost-router-capture.sh` (Stop hook) aggregates events into a `cost-routing-patterns.md` wiki page, which `/orchestrate` and `/model-route` read to bias future tiering. Missing file → no-op, no error.
