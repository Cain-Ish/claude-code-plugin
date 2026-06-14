# cost-router

**Use the expensive model only for thinking.** Opus is great at planning and hard problems — and per output token it's the priciest tier (exact ratios below). `cost-router` keeps Opus for the *thinking* and hands the *doing* (writing code, reading files, running tests) to cheaper models, so your Opus budget stretches much further.

It's a separate plugin you toggle by installing/uninstalling — on to save, off to go back to normal.

| You're doing… | it uses… | |
|---|---|---|
| 🧠 Thinking — design, architecture, hard debugging | **Opus** | worth it |
| 🔨 Doing — writing/editing code, the everyday ~80% | **Sonnet** | nearly as good for code, cheaper |
| 🔍 Looking — reading, searching, running tests | **Haiku** | mechanical, ~5× cheaper |

Pricing ratio: **Sonnet costs 60% of Opus per token, Haiku 20%** ($3/$15 and $1/$5 vs $5/$25) — savings scale with how much work routes down-tier. Measure your own delta after a week of route-log data.

## Install

```bash
claude plugin install ./cost-router
/cost-router:setup        # one-time; asks before changing anything
```

Uninstall: `claude plugin uninstall cost-router`.

## Use it

```bash
/cost-router:orchestrate add a retry with backoff to the uploader
```

- **`/cost-router:orchestrate <task>`** — routes a whole task: Opus plans (only if needed), Sonnet implements, Haiku checks.
- **`/cost-router:model-route <task>`** — just tells you which model fits, and why.
- **`/cost-router:setup`** — offers `opusplan` (plan on Opus, execute on Sonnet) and tunes things for your setup.
- Once installed you also get a advisory tier nudge on substantive THINK/SCOUT prompts and a session-start budget banner.

## Is it fully automatic?

Mostly. A plugin can't silently swap the model on every prompt — Claude Code doesn't allow that ([feature request](https://github.com/anthropics/claude-code/issues/44976)). So you get `opusplan` (automatic, coarse), a per-prompt advisory nudge, and `/orchestrate` for full routing on demand. Work cost-router hands to sub-agents *does* run on the cheap tier automatically.

## With second-brain

If you also run second-brain, they share one Opus budget (no double-spending) and cost-router accumulates the routing log it needs to learn which choices paid off. Neither plugin needs the other.

## Settings

| Variable | Default | Does |
|---|---|---|
| `COST_ROUTER_LEDGER` | brain-dir default | Premium-spend ledger path (informational — the cap was removed in 0.24.45; premium-tier models change, Opus today, Fable next) |
| `COST_ROUTER_AUTOROUTE` | `on` | `off` silences the advisory nudge (THINK/SCOUT prompts ≥25 chars; DO is always silent) |
| `COST_ROUTER_BANNER` | `on` | `off` hides the budget banner |

## Details

Cross-plugin data contracts, full env-var list, and the pricing table live in **[docs/reference.md](docs/reference.md)**.
