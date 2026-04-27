---
name: drift-check
description: Inspect accumulated persona-drift signals and report which persona.md rules are being violated in recent sessions. Surfaces filler phrases, AI-attribution markers, and narration patterns the assistant slipped into despite explicit prohibitions. Optionally proposes persona.md strengthening (gated by an adversarial critic).
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Write Edit Agent Bash(cat *) Bash(jq *) Bash(wc *) Bash(sort *) Bash(uniq *) Bash(head *) Bash(tail *) Bash(test *) Bash(date *)
argument-hint: "[--days N | --since YYYY-MM-DD]"
---

# Persona Drift Check

Analyze persona-drift signals captured by the `drift-detect.sh` hook and decide whether the persona is silently regressing.

## Background

`drift-detect.sh` runs on every `Stop` event and greps recent assistant turns for high-precision phrases that `~/.second-brain/persona.md` explicitly forbids: filler ("Certainly!", "Great question"), AI attribution ("Co-Authored-By: Claude"), narration ("Let me explain"). Hits land in `~/.second-brain/drift-log.jsonl`.

This skill reads that log and reports drift trends. It is the persona-side counterpart to `/second-brain:improve` (which reads the *user-side* friction log).

## Steps

### 1. Confirm the inputs exist

```bash
test -f ~/.second-brain/drift-log.jsonl && wc -l ~/.second-brain/drift-log.jsonl
test -f ~/.second-brain/persona.md && wc -l ~/.second-brain/persona.md
```

If `drift-log.jsonl` is missing or empty, report "no drift signals captured yet" and exit. The hook may not have run yet on a fresh install.

### 2. Resolve the time window

Default: last 7 days. If the user passed `--days N` or `--since YYYY-MM-DD`, honor that.

```bash
# Last 7 days, ISO timestamp cutoff (GNU date or BSD date)
CUTOFF=$(date -u -d '7 days ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
      || date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ")
```

### 3. Aggregate by signal_id

```bash
jq -r --arg c "$CUTOFF" '
  select(.timestamp >= $c)
  | "\(.signal_id)\t\(.claim)"
' ~/.second-brain/drift-log.jsonl \
  | sort | uniq -c | sort -rn
```

Surface a table:

```
HITS  SIGNAL_ID                 CLAIM                                EXAMPLE EXCERPT
  12  filler-certainly          No filler 'Certainly!'               "...Certainly! I'll fix..."
   4  ai-attribution-coauthor   No Co-Authored-By markers            "...Co-Authored-By: Claude..."
```

### 4. Per-signal session breakdown

For any signal with hits >= 3, show how many distinct sessions it appeared in. A signal hitting 12 times in 1 session is a single bad turn (cheap fix); a signal hitting 12 times across 8 sessions is real persona drift (warrants a persona.md change).

### 5. Diagnose root cause (no writes yet)

For each high-frequency signal:
- Read the relevant section of `persona.md` (Communication Style, Anti-Patterns to Avoid, etc.)
- Decide: is the rule already there but being ignored? Or is it missing entirely?
- Report this assessment to the user — do not write yet.

### 6. Adversarial critic gate (REQUIRED before any persona.md write)

Same-context judge-and-author causes drift in the drift-detector itself. Before writing any persona.md change, dispatch a fresh-context subagent:

```
Use the Agent tool with subagent_type: "second-brain:quality-reviewer"
Prompt with ONLY:
- The proposed persona.md addition/edit
- The current persona.md section text
- The 3 most representative drift excerpts (anonymized)

Ask:
1. Does the proposed change actually address the observed drift? (yes/no)
2. Does it conflict with anything else in persona.md? (yes/no)
3. Is the wording specific enough that a future grep can detect a violation? (yes/no)
4. Final verdict: ACCEPT / REJECT / REVISE
```

Only write changes the critic returns ACCEPT for. Log every verdict to `~/.second-brain/critic-log.jsonl` using the same schema as `/second-brain:improve`.

### 7. Apply approved changes

For approved changes only:
- Edit `~/.second-brain/persona.md` — append or strengthen the relevant rule
- Optionally update `~/.second-brain/persona.signals.json` to add a more specific regex if the critic suggested one
- Append a `## History` line at the bottom of `persona.md`: `- [YYYY-MM-DD] strengthened rule "<id>"; source: drift-log.jsonl (N hits across M sessions)`

### 8. Report and offer cleanup

Summarize what changed. Offer to archive processed drift entries:

```bash
# Only archive entries older than 30 days to keep recent context for next run
ARCH_CUTOFF=$(date -u -d '30 days ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
           || date -u -v-30d +"%Y-%m-%dT%H:%M:%SZ")
jq -c --arg c "$ARCH_CUTOFF" 'select(.timestamp < $c)' \
  ~/.second-brain/drift-log.jsonl >> ~/.second-brain/drift-log.jsonl.archive
jq -c --arg c "$ARCH_CUTOFF" 'select(.timestamp >= $c)' \
  ~/.second-brain/drift-log.jsonl > ~/.second-brain/drift-log.jsonl.tmp \
  && mv ~/.second-brain/drift-log.jsonl.tmp ~/.second-brain/drift-log.jsonl
```

Only do this with explicit user confirmation.

## Notes

- This skill is **diagnostic + proposal**. It does not silently mutate persona.md.
- The critic gate is mandatory. ICRH applies here too.
- If a signal repeatedly fires across many sessions despite persona.md updates, propose adding it to `persona.signals.json` with a tighter regex — the rule is fine, the detector just needs sharper enforcement.
