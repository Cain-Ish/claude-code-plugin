---
name: regress
description: Replay regression probes from ~/.second-brain/regressions/ to verify accumulated learnings still hold. Each accepted /second-brain:improve proposal can leave behind a one-line probe + expected (or forbidden) pattern; this skill runs them in fresh-context subagents and reports a pass-rate trend. Catches silent regression of past lessons.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Write Edit Agent Bash(cat *) Bash(jq *) Bash(ls *) Bash(wc *) Bash(grep *) Bash(date *) Bash(test *)
argument-hint: "[--learning <slug> | --since YYYY-MM-DD]"
---

# Regression Probe Replay

Replay one-line probes that test whether accumulated learnings still hold. Designed around Anthropic's "every learning becomes a held-at-100% regression test" pattern ([Anthropic evals guide](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).

## Background

When `/second-brain:improve` accepts a learning into `~/.second-brain/learnings.md`, it can also write a probe file to `~/.second-brain/regressions/<learning-slug>.md`:

```markdown
---
learning_slug: 2026-04-27-no-filler-phrases
probe: "Hello, how are you today?"
expected_pattern: "^(?!.*Certainly!|.*Great question)"
forbidden_pattern: "Certainly!|Great question"
---

Probe context: anything that should ground the test in a realistic scenario.
```

This skill loads each probe, runs it in a fresh-context subagent, and checks the response against the regex. Results land in `~/.second-brain/regressions/.results.jsonl` with timestamps so trend can be reported over time.

## Steps

### 1. Inventory probes

```bash
ls -la ~/.second-brain/regressions/*.md 2>/dev/null
```

If none, report "no probes registered yet — `/second-brain:improve` adds them when it accepts learnings" and exit.

### 2. Filter by argument

If `--learning <slug>`, run only that probe.
If `--since YYYY-MM-DD`, run only probes whose file mtime is newer.
Otherwise run all.

### 3. For each probe — dispatch fresh-context subagent

Use `Agent` tool with `subagent_type: "general-purpose"`. Prompt with ONLY:
- The probe text
- Context (if the probe file's body has any)
- One sentence: "Respond as Claude would respond in a normal session. Do not adopt any persona; do not load any plugin context."

This isolates the probe from the current session's persona/learnings — we want to test what the *base model* now does, not what the current loaded persona does.

### 4. Score the response

For each probe response:
- If `forbidden_pattern` matches the response -> **FAIL** (regression — the bad behavior came back)
- Else if `expected_pattern` set and does NOT match -> **FAIL** (expected behavior missing)
- Else -> **PASS**

### 5. Log results

```bash
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -nc \
  --arg t "$NOW" \
  --arg s "$LEARNING_SLUG" \
  --argjson p "$PASSED" \
  --arg ex "$RESPONSE_EXCERPT" \
  '{timestamp:$t, learning_slug:$s, passed:$p, response_excerpt:$ex}' \
  >> ~/.second-brain/regressions/.results.jsonl
```

### 6. Compute pass-rate trend per probe

For each probe, look back 30 days in `.results.jsonl` and report:
- Current run: PASS / FAIL
- 30-day pass rate: X / Y runs
- Trend: improving / stable / regressing

A probe with a 30-day trajectory of PASS PASS PASS FAIL is a regression alarm — flag it loudly.

### 7. Summary report

```
REGRESSION REPORT (YYYY-MM-DD)

Total probes: N
Passed: M (X%)
Failed: K
Regressions (was-passing, now-failing): J

Failures:
- 2026-04-27-no-filler-phrases: FAIL (forbidden "Certainly!" appeared in response)
  30-day rate: 12/14 (86%, regressing)

Recommended actions:
- For each regression: re-read the relevant ~/.second-brain/learnings.md or persona.md entry; consider whether the rule needs strengthening (route via /second-brain:drift-check or /second-brain:improve)
```

### 8. Bump hits counter for passing learnings

For each PASSING probe, increment the `hits` counter in the corresponding `~/.second-brain/learnings.md` meta line and update `last_used` to today. This protects them from `scripts/decay-learnings.sh`. Do this with a single `jq + awk` rewrite (similar pattern to decay-learnings.sh) and back up the file first.

## Notes

- This skill is **read + measure + propose**. It does not silently mutate `learnings.md` beyond the hits/last_used bump.
- Probes should be focused: one rule per probe, simple regex. Complex rubrics belong in human-judged review, not regex matching.
- A probe that consistently FAILs across 5+ runs without fix -> consider whether the rule is still valid (the world may have changed). Propose deprecation via `/second-brain:improve`.
- Critic gate from `/second-brain:improve` applies if you propose persona.md or quality-rules.md changes off the back of regression failures.
