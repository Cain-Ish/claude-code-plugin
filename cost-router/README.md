# cost-router

A Claude Code plugin that routes work across model tiers to cut Opus token spend:

| Tier | Model | Use when |
|------|-------|----------|
| THINK | Opus (`cr-planner`) | Architecture, design, ambiguous requirements, decomposition |
| DO | Sonnet (`cr-implementer`) | Code implementation — the ~80% default |
| SCOUT | Haiku (`cr-scout`) | File reads, grep/search, test runs, mechanical enumeration |

## Install / Uninstall

```
# Install
claude plugin install ./cost-router

# Uninstall (restores prior routing behaviour)
claude plugin uninstall cost-router
```

Installing enables the `/cost-router:orchestrate` skill, three model-pinned agents, the `/cost-router:model-route` advisor, and the consent-based `/cost-router:setup`. Uninstalling removes all of these.

## Skills & Commands

| Name | Invocation | Summary |
|------|-----------|---------|
| orchestrate | `/cost-router:orchestrate <task>` | Classify → plan (Opus?) → execute (Sonnet/Haiku) → verify |
| setup | `/cost-router:setup` | Consent-based opusplan + second-brain-aware floor config |
| model-route | `/cost-router:model-route <task>` | Advisory tier recommendation + rationale (no dispatch) |

## No blanket `CLAUDE_CODE_SUBAGENT_MODEL`

This plugin deliberately does **not** set a blanket `CLAUDE_CODE_SUBAGENT_MODEL` floor. That env var is highest-precedence and would silently clobber per-agent model pins set by other plugins (e.g. second-brain pins Haiku for search and Sonnet for its workers). Instead routing is done **per-dispatch** via the `model:` key on each Task tool call — empirically proven to work (verified session transcripts).

The `/cost-router:setup` skill will warn you explicitly if second-brain is detected and you attempt to set a blanket floor.

## Contract A — Shared Opus-budget ledger

**Path:** `${COST_ROUTER_LEDGER:-${SB_BRAIN_DIR:-$HOME/.second-brain}/opus-budget.json}`

Defaults into second-brain's brain dir so both plugins share the same daily cap. Overridable via `COST_ROUTER_LEDGER`.

**Schema:**
```json
{
  "date": "2026-06-09",
  "opus_cost_usd": 0.42,
  "opus_calls": 7,
  "cap_usd": 5.0
}
```

**Semantics:** Before any Opus dispatch, check `opus_cost_usd < cap_usd` (cap from `COST_ROUTER_OPUS_CAP_USD`, default `5.0`). After the call, add the call's cost. If `date` differs from today, reset to today with zeroed counters. Over budget → fall back to Sonnet.

## Contract B — Routing events (learning loop)

**Path:** `${COST_ROUTER_EVENTS:-${SB_BRAIN_DIR:-$HOME/.second-brain}/cost-router-events.jsonl}`

Append-only JSONL. One object per routed task:

```json
{"ts":"2026-06-09T18:00:00Z","task":"add retry to uploader","tier":"DO","models":["sonnet"],"units":3,"escalated":false,"outcome":"ok","committed":true}
```

**Producer:** cost-router `/orchestrate` (via `scripts/route-log.sh`).

**Consumer:** second-brain's `cost-router-capture.sh` (Stop hook) aggregates recent events into a `cost-routing-patterns.md` wiki page. The `/orchestrate` and `/model-route` classifiers read that page (if present) to bias future tier decisions. Absent file → no-op, no error.

## Pricing reference (2026-06-09)

| Model | Input $/Mtok | Output $/Mtok | vs Sonnet |
|-------|-------------|--------------|-----------|
| Opus 4.8 | $5 | $25 | 1.67× |
| Sonnet 4.6 | $3 | $15 | 1× |
| Haiku 4.5 | $1 | $5 | 0.33× |

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `COST_ROUTER_LEDGER` | `$SB_BRAIN_DIR/opus-budget.json` | Path to shared Opus budget ledger |
| `COST_ROUTER_EVENTS` | `$SB_BRAIN_DIR/cost-router-events.jsonl` | Path to routing events JSONL |
| `COST_ROUTER_OPUS_CAP_USD` | `5.0` | Daily Opus spend cap in USD |
| `COST_ROUTER_BANNER` | `on` | Set to `off` to suppress SessionStart budget banner |
