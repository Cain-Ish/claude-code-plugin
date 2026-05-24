# Dream Auto-Stage at Threshold — Design Spec

**Date:** 2026-05-24
**Status:** Draft for review
**Author:** second-brain — dream automation pass
**Scope:** Make `/second-brain:dream` fire semi-automatically when enough *new* transcripts have accumulated, instead of only nagging. Single plugin, bash hooks + existing MCP/Agent seam. No new dependencies.

---

## 1. Goal

Today dream never runs itself. `session-load.sh:84-89` emits a "dream consolidation suggested" banner when a session-event counter crosses a threshold, then relies on the user to remember to run `/second-brain:dream --background`. The counter (`sb_get_session_count`) is decoupled from the actual transcript corpus — it read **127** while only **28** transcript files exist — so the nag is both noisy and misleading.

Goal: when **N genuinely-new transcripts** have accumulated since the last dream, the SessionStart hook auto-stages a pending dream and instructs Claude to spawn the background runner. Acceptance of the staged diff stays **manual** — the wiki is never auto-mutated.

This is the **template** for auto-triggering the other consolidation elements (improve, reindex, lint) later. The knowledge-maintainer already auto-dispatches (v2.8.0); this mirrors its reconciliation pattern for consistency.

## 2. Constraints / findings that shape the design

- **Hooks are bash; they cannot invoke the Agent tool.** The background dream runs via the `second-brain:dream-runner` Agent, which only Claude can spawn during a turn. A hook can stage a *pending* dream (via `dream-snapshot.sh`, the bash impl behind the `dream_create` MCP tool) but must hand the spawn to Claude via an injected instruction.
- **`claude --bare` is not an option on subscription.** It rejects OAuth tokens by design (`[[claude-cli-bare-auth-modes]]`). So the "hook shells out to a recursive claude" approach is off the table for this user; the Agent-tool seam is mandatory.
- **No "processed" marker exists.** `dream-snapshot.sh:78-99` selects the newest `MAX_COUNT` transcripts every run with no exclusion of already-dreamed ones. Frequent dreams therefore re-mine identical material. A marker fixes both the trigger signal *and* the re-mining waste.
- **Compact is excluded.** SessionStart hook output is silently dropped after compaction (upstream anthropics/claude-code#15174 — documented in `hooks.json`). A post-compact trigger would not surface. PreCompact is also latency-sensitive and already runs the light extractor. Auto-stage runs on `startup|resume|clear` only.
- **One dream at a time.** `dream_create` enforces a single pending/running dream. The hook must guard against staging a second.
- **Control principle.** `[[2026-05-20-monitoring-without-control-audit]]` — the system observes and suggests but does not auto-mutate the knowledge base. The *trigger* is automated; the *accept* stays human.

## 3. Trigger signal — the new-transcript marker

- **Marker file:** `~/.second-brain/dreams/.last-dream-at` — an ISO-8601 UTC timestamp.
- **Written:** at dream *create* time (by `dream-snapshot.sh`, so both manual and auto-staged dreams advance it).
- **New-transcript count:** number of files in `~/.second-brain/transcripts/*.txt` with **mtime newer than the marker**. Using mtime avoids parsing filenames and is robust to naming changes.
- **Missing marker (first run ever):** treat all transcripts as new — fire once, then the marker exists.
- **Global, not per-project:** transcript selection is global unless `--slug` is passed, so the marker is global.

Rationale for mtime over the filename date: filenames already carry a date, but mtime is the unambiguous "when did this land" and matches how `dream-snapshot.sh` already globs `*.txt`.

## 4. Hook logic (rewrite of `session-load.sh:84-89`)

Runs only under the existing `startup|resume|clear` matcher (compact already excluded in `hooks.json`).

```
AUTOSTAGE = ${SB_DREAM_AUTOSTAGE:-on}
THRESHOLD = ${SB_DREAM_NEW_THRESHOLD:-10}

if AUTOSTAGE == off:
    # legacy fallback: keep today's "suggested" nag banner (session-count based)
    emit suggested-nag if session_count >= SB_DREAM_CADENCE
    return

NEW = count(transcripts with mtime > marker)

# one-at-a-time guard
if any ~/.second-brain/dreams/*/status.json has status in {pending, running}:
    emit one-line note "dream <id> already in flight — review with /second-brain:dream"
    return

if NEW >= THRESHOLD:
    DID = $(bash dream-snapshot.sh --max-count 100)   # stages pending dream, advances marker
    emit instruction banner (additionalContext):
        "Dream <DID> auto-staged with <NEW> new transcripts.
         Spawn the second-brain:dream-runner agent in the background
         (run_in_background: true, dream_id=<DID>) before responding to the user."
else:
    # below threshold: silent. No banner, no count. (Avoids reintroducing nag fatigue.)
    no banner
```

Notes:
- `dream-snapshot.sh` must **print the new dream id** to stdout (or the hook reads the newest `drm_*` dir) so the injected instruction can name it. If the script doesn't already, add an id echo.
- The marker advance happens *inside* `dream-snapshot.sh` at create time, so a crash between stage and spawn still won't re-stage the same transcripts next session.

## 5. Claude's seam (the one manual-in-code step)

On the next turn Claude sees the injected instruction and spawns the runner via the Agent tool with `run_in_background: true`, exactly as a manual `/second-brain:dream --background` does. This is the same proven mechanism as the existing "dream completed — run /second-brain:dream to review" nudge. No new reliability surface.

## 6. Acceptance (unchanged, manual)

Runner finishes → existing completion banner (`session-load.sh:328`) → user runs `/second-brain:dream` → Review phase reads `diff.md` → `dream_accept` or `dream_discard`. Wiki mutated only on explicit accept.

## 7. Config / safety

| Env var | Default | Effect |
|---|---|---|
| `SB_DREAM_AUTOSTAGE` | `on` (once shipped) | Master kill switch. `off` → revert to legacy suggested-nag. |
| `SB_DREAM_NEW_THRESHOLD` | `10` | New-transcript count required to auto-stage. |
| `SB_DREAM_CADENCE` | `15` | Retained: drives the legacy nag when autostage is `off`. |

- When autostage is **on**, the legacy session-count nag is **suppressed** (no double banner).
- All banners go through `sb_append` with dedup keys, same as today.

## 8. Edge cases

- **0 new transcripts** → no stage, no banner.
- **Dream already pending/running** → skip stage, one-line note.
- **Discarded dream** → marker already advanced at create, so those transcripts won't re-trigger; user can still run `/second-brain:dream` manually to re-stage.
- **Marker missing** → all transcripts counted new; fires once; marker then exists.
- **`dream-snapshot.sh` fails** (e.g. no transcripts dir) → hook logs to error-log, no banner, marker untouched.

## 9. Accompanying fix — verify-gate ignores file type

Folded into this work (surfaced while writing this very spec). `stop-verify-gate.sh:32-38` sets `CODE_MODIFIED` on **any** `Write`/`Edit`/`MultiEdit` tool call — it extracts `.name` but never inspects `.input.file_path`. Result: editing a markdown doc (this spec) trips a gate whose remedy ("run tests, lint, type-check") is meaningless for prose, blocking completion up to the 2/session safety-valve cap.

**Fix:** in the `CODE_MODIFIED` jq (line 32), also extract `.input.file_path` and only count the modification as code when the path has a code-ish extension. Exclude `.md`, `.markdown`, `.txt`, and `docs/` paths.

```jq
select(.type == "assistant")
| .message.content[]?
| select(.type == "tool_use")
| select(.name == "Write" or .name == "Edit" or .name == "MultiEdit")
| .input.file_path // ""
| select(. != "")
| select((endswith(".md") or endswith(".markdown") or endswith(".txt") or contains("/docs/")) | not)
```

Keep it allow-by-default for unknown extensions (fail-open philosophy already in the script header) — i.e. *exclude* known-doc patterns rather than *include* a code allowlist, so a new code extension is never silently ungated.

**Test:** transcript with only a `.md` Write → gate approves (exit 0). Transcript with a `.sh` Write and no verification → gate blocks. Mixed (`.sh` + `.md`) → blocks (code present).

## 10. Out of scope (future, same template)

- Auto-triggering improve / reindex / lint on their own signals.
- Auto-accept of low-risk diffs (would cross the control line; explicitly deferred).
- Per-project dream cadence.

## 11. Testing

- Unit-ish: seed `~/.second-brain/transcripts/` with K files newer than a fixture marker; run the trigger logic; assert stage happens iff K ≥ threshold.
- Guard test: pre-create a `status.json` with `status: running`; assert no second stage.
- Off switch: `SB_DREAM_AUTOSTAGE=off`; assert legacy nag path.
- Smoke: run a real session, confirm `~/.second-brain/error-log.jsonl` is clean and the auto-staged banner appears.

<!-- version target: 0.12.0 -->
