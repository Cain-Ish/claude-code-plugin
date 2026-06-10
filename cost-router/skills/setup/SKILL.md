---
name: setup
description: Consent-based cost-router configuration. Detects second-brain, offers opusplan alias, warns about blanket floor risks, and smoke-tests after writing. Never modifies settings without showing a diff and receiving explicit confirmation.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Write Edit Bash(test *) Bash(ls *) Bash(find *) Bash(jq *) Bash(cat *) Bash(grep *) Bash(mkdir *) Bash(mktemp *) Bash(mv *) Bash(basename *) Bash(dirname *) Bash(date *)
argument-hint: "[--dry-run]"
---

# Cost-Router Setup

Configure cost-routing for this installation. This skill is consent-based: it shows you exactly what it will write and waits for your confirmation before touching any file.

## Step 1 — Detect second-brain

Check whether second-brain is installed:

```bash
# Look for second-brain agent dir or plugin cache
sb_present=false
if [ -d "$HOME/.claude/plugins/cache/second-brain" ] || \
   [ -f "$HOME/.claude/plugins/cache/second-brain/.claude-plugin/plugin.json" ] || \
   find "$HOME/.claude" -name "dream-runner.md" -maxdepth 5 2>/dev/null | grep -q .; then
  sb_present=true
fi
```

Report the result: "second-brain detected" or "second-brain not detected".

If second-brain is present, also note:
> second-brain pins its own agents to specific model tiers (Haiku for search, Sonnet for knowledge workers, Opus for persona-think). Any blanket model floor you set here will override those pins.

## Step 2 — Check current settings

Read `~/.claude/settings.json` (or note it is absent). Extract the current `model` field (if any). Report:
- Current model setting (e.g. `"sonnet"`, `"opus"`, or "not set")
- Whether `CLAUDE_CODE_SUBAGENT_MODEL` is set in the environment

## Step 3 — Offer `opusplan` (main session model)

Offer to configure the user's session model to `opusplan`:

> **opusplan** sets the main conversation model to Opus (for planning/design in the outer loop) while subagents dispatched with `model: 'sonnet'` or `model: 'haiku'` still run at those tiers. This is the recommended cost-router configuration when you want Opus-level planning at the top level.
>
> The change writes `"model": "opusplan"` to `~/.claude/settings.json`.
>
> **Current value:** `<current>` → **Proposed:** `"opusplan"`
>
> Confirm? (yes/no)

If the user says no: skip to Step 4. If yes: proceed to write (Step 3a).

### Step 3a — Show diff and write with confirmation

Show the before/after diff of `~/.claude/settings.json`. Require explicit "yes" before writing.

Read existing `~/.claude/settings.json` (create `{}` if absent). Use `jq` to set `.model = "opusplan"`. Write atomically via temp+mv:

```bash
SETTINGS="$HOME/.claude/settings.json"
TMP=$(mktemp "$SETTINGS.XXXXXX")
jq '.model = "opusplan"' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
```

Confirm write succeeded.

## Step 4 — Blanket floor warning (re `CLAUDE_CODE_SUBAGENT_MODEL`)

> **`CLAUDE_CODE_SUBAGENT_MODEL` is highest-precedence** and overrides ALL per-agent `model:` pins — including cost-router's own DO/SCOUT agents and second-brain's Haiku/Sonnet workers. Setting it to `sonnet` would silently upgrade second-brain's Haiku agents (more cost) and could downgrade its Sonnet workers if set to `haiku` (capability loss).

Decision tree:

- **second-brain detected:** Recommend **against** setting `CLAUDE_CODE_SUBAGENT_MODEL`. Say: "Because second-brain is installed and pins its own agents, a blanket floor would override those pins. We recommend NOT setting this variable. Use per-dispatch `model:` routing via `/cost-router:orchestrate` instead."
- **No tiering plugin detected:** Offer as an option with a clear warning that it affects all subagents. Show the diff (add `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` to shell profile) and require confirmation. Default recommendation: skip it (per-dispatch routing is cleaner).

Do not set `CLAUDE_CODE_SUBAGENT_MODEL` without explicit consent, and never set it when second-brain is present.

## Step 5 — Smoke test

After any settings write, run a quick sanity check:

1. Re-read `~/.claude/settings.json` and confirm the `model` field is as written.
2. Remind the user: "Per-dispatch routing (`model: 'sonnet'` in Task calls) is verified to work in this environment — dispatched agents run at the specified tier."

Report effective state:
```
Effective state:
  Session model:     opusplan (or whatever was set)
  Per-dispatch:      model: 'sonnet' / model: 'haiku' work as expected
  CLAUDE_CODE_SUBAGENT_MODEL: not set (recommended)
  second-brain:      detected / not detected
  Opus daily cap:    $5.00 (COST_ROUTER_OPUS_CAP_USD)
```

## Step 6 — Summary

Print a brief summary of what was changed (or "no changes made" if the user declined everything).

Remind the user:
- Use `/cost-router:orchestrate <task>` to route work across tiers automatically.
- Use `/cost-router:model-route <task>` for an advisory tier recommendation.
- The Opus budget ledger lives at `${COST_ROUTER_LEDGER:-~/.second-brain/opus-budget.json}`.
- To undo: run `claude plugin uninstall cost-router` and manually revert `~/.claude/settings.json` if you changed it.
