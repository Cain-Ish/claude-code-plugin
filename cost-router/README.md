# cost-router

**Use the expensive model only for thinking.** Opus is great at planning and hard problems — and it costs ~1.7× a Sonnet and ~5× a Haiku. `cost-router` keeps Opus for the *thinking* and quietly hands the *doing* (writing code, reading files, running tests) to cheaper models, so your Opus budget stretches much further without you losing quality.

It's a separate plugin you turn on or off by installing/uninstalling it. Install it when you want to save; remove it and everything goes back to normal.

---

## The idea in one table

| You're doing… | cost-router uses… | Why |
|---|---|---|
| 🧠 **Thinking** — design, architecture, fuzzy requirements, hard debugging | **Opus** | Worth the money; this is where the big model earns its keep |
| 🔨 **Doing** — writing/editing code, refactors, the everyday ~80% | **Sonnet** | Nearly as good for coding, ~40% cheaper |
| 🔍 **Looking** — reading files, searching, running tests/lint | **Haiku** | Mechanical work with a right answer; ~5× cheaper than Opus |

Typical effect: **Opus spend drops ~70–85%** on implementation-heavy work, because planning is the only thing still on Opus.

---

## Quick start

```bash
# 1. Install
claude plugin install ./cost-router

# 2. One-time setup (asks before changing anything)
/cost-router:setup

# 3. Use it on a task
/cost-router:orchestrate add a retry with backoff to the uploader
```

`/cost-router:setup` offers to switch your session to **`opusplan`** (Claude Code plans on Opus, then automatically drops to Sonnet to execute) and checks whether you also run second-brain. It never edits your settings without showing you the change first.

To remove it later: `claude plugin uninstall cost-router` (and undo the `opusplan` setting if you added it).

---

## How you'll actually use it

- **Let it route a whole task:** `/cost-router:orchestrate <task>` — it figures out the plan (Opus, only if the task really needs design), then has Sonnet write the code and Haiku run the checks, and tells you what it spent.
- **Just ask for advice:** `/cost-router:model-route <task>` — tells you which model *would* fit, and why, without doing anything.
- **Every prompt gets a gentle nudge:** once installed, a tiny hook tags each prompt (`THINK → Opus`, `DO → Sonnet`, `SCOUT → Haiku`) so the right tier is top-of-mind. It's a free, instant keyword check — no extra model calls.
- **See your budget:** at session start you get a one-line banner showing how much of today's Opus budget is left.

---

## "Is it fully automatic?" — the honest answer

**Mostly, with one limit worth knowing.** A plugin *cannot* silently swap the model on every prompt for you — Claude Code doesn't expose that to plugins (it's an [open feature request](https://github.com/anthropics/claude-code/issues/44976)). So cost-router gives you the next best thing:

- **`opusplan`** (from setup) — automatic, coarse: Opus while planning, Sonnet while executing.
- **The per-prompt nudge** — automatic and visible, but it *advises*; it can't force the switch.
- **`/orchestrate`** — full Opus→Sonnet→Haiku routing, when you invoke it on a task.
- **Anything cost-router hands to a sub-agent** *does* run on the cheap tier automatically (this part is verified working).

Bottom line: planning stays on Opus, the heavy lifting moves to Sonnet/Haiku — you just occasionally type `/cost-router:orchestrate` for the deepest savings.

---

## Works with second-brain (better together, fine apart)

If you also run the **second-brain** plugin, the two cooperate automatically — and neither needs the other:

- **One shared Opus budget.** second-brain's `think` feature and cost-router draw from the *same* daily Opus meter, so they can't accidentally double-spend.
- **It learns.** cost-router records how each routing decision turned out; second-brain folds that into a `cost-routing-patterns` note, which the router reads next time to make smarter calls.

Don't run second-brain? cost-router works standalone and just keeps its budget file under `~/.second-brain/`.

> **Note:** cost-router never sets a blanket `CLAUDE_CODE_SUBAGENT_MODEL` override. That switch is heavy-handed — it would stomp on the careful per-agent model choices other plugins (like second-brain) make. Routing is done per-task instead, which is safer and more precise.

---

## Settings (all optional)

| Variable | Default | What it does |
|---|---|---|
| `COST_ROUTER_OPUS_CAP_USD` | `5.0` | Daily Opus spend cap (USD). Over it → planning falls back to Sonnet. |
| `COST_ROUTER_AUTOROUTE` | `on` | Set to `off` to silence the per-prompt routing nudge. |
| `COST_ROUTER_BANNER` | `on` | Set to `off` to hide the session-start budget banner. |
| `COST_ROUTER_LEDGER` | `~/.second-brain/opus-budget.json` | Where the shared Opus budget is tracked. |
| `COST_ROUTER_EVENTS` | `~/.second-brain/cost-router-events.jsonl` | Where routing decisions are logged. |

---

<details>
<summary><strong>Reference: commands, pricing, and the cross-plugin contracts</strong></summary>

### Commands & agents

| Name | Invocation | Summary |
|---|---|---|
| orchestrate | `/cost-router:orchestrate <task>` | Classify → plan (Opus, if needed) → execute (Sonnet/Haiku) → verify → log |
| model-route | `/cost-router:model-route <task>` | Advisory tier recommendation + rationale (no dispatch) |
| setup | `/cost-router:setup` | Consent-based `opusplan` + second-brain-aware configuration |

Agents: `cr-planner` (Opus), `cr-implementer` (Sonnet), `cr-scout` (Haiku).

### Pricing reference (2026-06-09)

| Model | Input $/Mtok | Output $/Mtok | vs Sonnet |
|---|---|---|---|
| Opus 4.8 | $5 | $25 | 1.67× |
| Sonnet 4.6 | $3 | $15 | 1× |
| Haiku 4.5 | $1 | $5 | 0.33× |

### Contract A — shared Opus-budget ledger
Path: `${COST_ROUTER_LEDGER:-${SB_BRAIN_DIR:-$HOME/.second-brain}/opus-budget.json}`
```json
{ "date": "2026-06-09", "opus_cost_usd": 0.42, "opus_calls": 7, "cap_usd": 5.0 }
```
Before an Opus call, check `opus_cost_usd < cap_usd`; after, add the call's cost; reset daily when `date` changes. Over budget → fall back to Sonnet.

### Contract B — routing events (the learning loop)
Path: `${COST_ROUTER_EVENTS:-${SB_BRAIN_DIR:-$HOME/.second-brain}/cost-router-events.jsonl}` (append-only JSONL)
```json
{"ts":"2026-06-09T18:00:00Z","task":"add retry to uploader","tier":"DO","models":["sonnet"],"units":3,"escalated":false,"outcome":"ok","committed":true}
```
**Producer:** `/orchestrate` (and the per-prompt hook) via `scripts/route-log.sh`. **Consumer:** second-brain's `cost-router-capture.sh` (Stop hook) → `cost-routing-patterns.md` wiki page, read back by `/orchestrate` and `/model-route`. Missing file → no-op, no error.

</details>
