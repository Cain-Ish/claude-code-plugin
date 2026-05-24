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

## 3. Trigger signal — newest-dream-dir as reference

No dedicated marker file. The reference point is **the most recently modified dream directory** under `~/.second-brain/dreams/drm_*/`. This is source-agnostic: it advances whether a dream was created by the CLI (`dream-snapshot.sh`), the MCP `dream_create` tool, or autostage itself — so we never re-mine transcripts a manual dream already covered. It also needs **zero change to `dream-snapshot.sh`** (which already creates the dir at stage time and echoes the id on stdout, line 133).

- **New-transcript count:** `find "$BRAIN_DIR/transcripts" -maxdepth 1 -name '*.txt' -newer "$NEWEST_DREAM_DIR" | wc -l`. Uses mtime; no date parsing.
- **`$NEWEST_DREAM_DIR`:** `ls -1dt "$DREAMS_DIR"/drm_*/ | head -1` — newest by mtime, regardless of status. A dream dir's top-level mtime is set at create (the runner writes only into `staging/`, not the top dir), so it reliably reflects creation time.
- **No dream exists yet (first run ever):** treat all transcripts as new — fire once; the new dream dir then becomes the reference.
- **Global, not per-project:** transcript selection is global unless `--slug` is passed, so the reference is global.

Rationale: reusing the dream dir as the watermark removes a piece of state to maintain, and closes the gap where an MCP- or CLI-created dream wouldn't have advanced a hook-owned marker file.

## 4. Hook — new script `scripts/dream-autostage.sh`

A dedicated SessionStart hook script, matching the existing pattern of one script per concern (`ensure-dirs.sh`, `discover-*.sh`). Registered in `hooks.json` under the existing `startup|resume|clear` matcher, *after* `session-load.sh` (compact already excluded). Its stdout becomes SessionStart `additionalContext`.

```
AUTOSTAGE  = ${SB_DREAM_AUTOSTAGE:-on}
THRESHOLD  = ${SB_DREAM_NEW_THRESHOLD:-10}
DREAMS_DIR = $BRAIN_DIR/dreams
TX_DIR     = $BRAIN_DIR/transcripts

[ "$AUTOSTAGE" = off ] && exit 0          # legacy nag handled in session-load.sh
[ -d "$TX_DIR" ] || exit 0

NEWEST_DREAM = $(ls -1dt "$DREAMS_DIR"/drm_*/ 2>/dev/null | head -1)

# one-at-a-time guard: don't stack on an in-flight dream
if [ -n "$NEWEST_DREAM" ]; then
    s = jq -r .status "$NEWEST_DREAM/status.json"
    [ "$s" = pending ] || [ "$s" = running ] && exit 0   # silent; in-flight banner is session-load's job
    NEW = find "$TX_DIR" -maxdepth 1 -name '*.txt' -newer "$NEWEST_DREAM" | wc -l
else
    NEW = find "$TX_DIR" -maxdepth 1 -name '*.txt' | wc -l   # no dream yet → all new
fi

[ "$NEW" -ge "$THRESHOLD" ] || exit 0      # below threshold → silent

DID = $(bash "$(dirname "$0")/dream-snapshot.sh" --max-count 100)
if [ $? -ne 0 ] || [ -z "$DID" ]; then
    sb_log_error "dream-autostage.sh" "stage failed" 0
    exit 0                                  # fail open, no banner
fi

# instruction banner → Claude spawns the runner on its next turn
printf '## ⓘ second-brain — dream auto-staged\n%s new transcripts since last dream. Dream %s staged (pending).\n**Spawn the `second-brain:dream-runner` agent now (run_in_background: true, dream_id=%s) before responding to the user.** Acceptance of its diff stays manual.\n\n' "$NEW" "$DID" "$DID"
```

Notes:
- `dream-snapshot.sh` already echoes the id (line 133) and already guards one-at-a-time internally (lines 46-54), so the hook's guard is belt-and-suspenders — the script also exits non-zero if a dream is in flight, which the `[ -z "$DID" ]` check absorbs.
- No marker file and no `dream-snapshot.sh` change: the newly-created dream dir *is* the next run's reference point.

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

- **0 / below-threshold new transcripts** → no stage, no banner (silent).
- **Dream already pending/running** → hook exits silently; the "in flight" nudge is session-load's existing completed/review banner, not this script's job.
- **Discarded dream** → its dir normally persists (prune only removes archived dirs when >5), so it stays the reference and those transcripts won't re-trigger. If the dir is fully removed, the prior dream dir becomes the reference; the 10-transcript threshold makes immediate re-stage unlikely. User can always `/second-brain:dream` manually.
- **No dream dir at all (first ever)** → all transcripts counted new; fires once; the new dir becomes the reference.
- **`dream-snapshot.sh` fails / no transcripts dir** → hook logs to error-log, exits 0, no banner.

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

New `tests/test-dream-autostage.sh` (auto-discovered by `run-all.sh`), sandboxed `BRAIN_DIR` per the existing test convention:
- **Below threshold:** seed a reference dream dir + K<threshold newer transcripts → no banner (empty stdout).
- **At/above threshold:** seed K≥threshold newer transcripts, a real wiki dir → banner emitted naming a `drm_*` id; a pending dream dir now exists.
- **In-flight guard:** newest dream `status: running` → no stage, empty stdout.
- **No dream yet:** no `drm_*` dirs, K≥threshold transcripts → fires.
- **Kill switch:** `SB_DREAM_AUTOSTAGE=off` → empty stdout (exit 0).

Extend `tests/test-stop-verify-gate.sh`:
- **Doc-only Write** (`.md` file_path) + no verification → **approve** (the bug fix).
- **Code Write** (`.sh`/`.ts`) + no verification → still **block**.
- **Mixed** (`.sh` + `.md`) + no verification → **block** (code present).

Smoke: run a real session with autostage on, confirm `~/.second-brain/error-log.jsonl` stays clean and the banner appears once.

<!-- version target: 0.12.0 -->
