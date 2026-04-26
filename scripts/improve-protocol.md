# Plugin Self-Improvement Protocol

Read by Claude when `auto_improve: true` and the session reflection suggests
a plugin change. Run as a background subagent (`subagent_type: general-purpose`)
after responding to the user.

## Steps

1. Read `~/.second-brain/learnings.md`, `~/.second-brain/quality-rules.md`, `~/.second-brain/friction-log.jsonl`.
2. Read all skill files under `${PLUGIN_ROOT}/skills/*/SKILL.md` and `${PLUGIN_ROOT}/skills/improve/signal-patterns.md`.
3. Identify whether any friction signal or learning points to a concrete improvement in plugin source. If nothing concrete, stop here (the "On exit" section below still runs).
4. Write a structured proposal to `~/.second-brain/.improve-proposal.json`:
   ```json
   {
     "title": "...",
     "description": "...",
     "evidence": [
       {"type": "friction|learning", "timestamp": "ISO 8601 from friction-log or YYYY-MM-DD from learnings.md", "session_id": "...", "signal": "actual quoted text"}
     ],
     "changes": [
       {"file": "${PLUGIN_ROOT}/path", "action": "modify|add", "description": "..."}
     ],
     "measurable_impact": "...",
     "risk_assessment": "..."
   }
   ```
   Evidence rules: 2+ entries from distinct sessions or distinct timestamps. "Could happen" is not evidence.
5. Validate the proposal: `bash ${PLUGIN_ROOT}/scripts/validate-proposal.sh`. On failure, abandon and stop.
6. Apply the changes, then validate the plugin: `bash ${PLUGIN_ROOT}/scripts/validate-plugin.sh`. On failure, fix or abandon.
7. Branch and PR (never push to main):
   ```
   cd ${PLUGIN_ROOT}
   git checkout -b improve/$(date -u +%Y-%m-%d-%H%M%S)-auto
   git add -A
   git commit -m "improve: <short description>"
   git push -u origin HEAD
   gh pr create
   ```
   The PR body must include the evidence entries (quoted from the proposal), the change list, the measurable impact, the risk assessment, and both validation results.
8. Clean up: `rm ~/.second-brain/.improve-proposal.json`.
9. Report the PR URL.

## On exit (always)

Whether you completed all steps, abandoned at step 3, or failed validation at step 5/6, mark this attempt so the next session doesn't immediately re-trigger:

```bash
date +%Y-%m-%d > ~/.second-brain/.last-plugin-improve
```

## Hard rules

- Never modify `plugin.json`'s version field — that's a release concern.
- Never push to `main`.
- One PR per improvement area.
- If proposal validation fails, do not create a PR.
