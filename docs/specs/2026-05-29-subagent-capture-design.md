# Design: SubagentStop capture

**Date:** 2026-05-29
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Target release:** 0.22.0 (additive; new hook, no migration)
**Roadmap item:** #2 (docs/specs/2026-05-29-cc-feature-adoption-roadmap.md)

## Summary

The plugin is already multi-agent (code-review-deep fans out unit-reviewers + scorer +
history + architectural reviewers; dream-runner consolidates) but extraction only reads
the **main-session** transcript (`stop-extract.sh` reads `payload.transcript_path`). Every
subagent's work is invisible.

Measured on this box: **199 per-subagent transcripts** exist under
`~/.claude/projects/<project>/<session-id>/subagents/agent-<id>.jsonl` — entirely separate
files from the top-level main-session transcript, never seen by the Stop extractor. A
sampled one was 190KB / 118 lines of real investigative work. That is the gap.

Claude Code's `SubagentStop` hook fires when any subagent completes, with `agent_id`,
`agent_type`, `transcript_path`, `session_id`, `cwd` on stdin. This design adds a
`SubagentStop` hook that captures the **subagent's final result message** (not its full
transcript) into the EXISTING archive → dream → episodic pipeline, gated to substantive
non-self subagents. No new LLM call, no recursive `claude` (OAuth-safe — pure file ops).

## Goals

- **Capture** each substantive subagent's conclusion so it becomes dream-minable and
  episodic-searchable, closing the multi-agent extraction blind spot.
- **Final-result only** (decision (b)): archive the subagent's last assistant text block +
  a one-line meta — the durable conclusion, not the verbose step-by-step process (which is
  exactly the session-narrative the extractor already strips). Far smaller; friendly to the
  existing 100-file / 5MB archive cap and the Pi's disk.
- **Substantive, minus self**: skip the plugin's own consolidation/review agents (archiving
  them = the consolidation process mining itself) and skip mechanical/empty subagents.
- **OAuth-safe + offline-first**: file operations only; never invokes `claude`.
- **Never block**: a SubagentStop that exits non-zero would prevent the subagent from
  stopping and wedge fan-outs. Always exit 0.
- **Reuse, don't rebuild**: land results in `~/.second-brain/transcripts/` so the existing
  episodic indexer + dream selection pick them up with no change to those subsystems.

## Non-goals (YAGNI)

- **No per-subagent LLM extraction.** Results flow through the same archive→dream path as
  main sessions; the dream's consolidation is where LLM synthesis happens (out of session,
  drain-timer safe).
- **No full-transcript archive.** Decided against (option a): 199×~190KB would churn the cap
  and re-introduce process-narrative noise. Final result only.
- **No SubagentStart hook.** Not needed for capture; would only add per-spawn overhead.
- **No new MCP tool, no settings.** Hook + one bash script.
- **No blocking / gating of subagents.** Capture is passive.

## Background (verified, not assumed)

| Fact | Evidence |
|---|---|
| Subagent transcripts are separate files | 199 found under `<session>/subagents/agent-<id>.jsonl`, distinct from top-level `<session>.jsonl` |
| Final result = last `assistant` record's `text` block | All 5 sampled transcripts end with `type:assistant`; content `type:text` present |
| Some results are near-empty | `agent-ae8289…` last assistant text = 4 bytes → gate must drop near-empty, not just zero-tool |
| SubagentStop payload | `agent_id`, `agent_type`, `transcript_path`, `session_id`, `cwd` (CC docs; agent_id/agent_type "present only inside a subagent call") |
| SubagentStop can block on exit 2 | CC docs — so we MUST always exit 0 |
| Matcher selects (not excludes) by agent_type | CC docs — self-exclusion must happen in-script, not via matcher |
| Existing archive keys on `${session_id}_${slug}_${date}.txt` | `sb_archive_transcript` in lib.sh:299 |
| Existing 100-file / 5MB prune cap | `sb_prune_transcripts` in lib.sh |

## Architecture

```
  Claude Code SubagentStop event (per finished subagent)
        │  stdin: agent_id, agent_type, transcript_path, session_id, cwd
        ▼
  hooks.json SubagentStop[]  matcher "*"  →  scripts/subagent-capture.sh
        │  1. self-exclude (agent_type in second-brain agent set?) → exit 0
        │  2. substantive gate (tool_count >= 1 AND final-result length >= MIN) → else exit 0
        │  3. extract final assistant text (jq) + build meta
        ▼
  sb_archive_subagent_result()  (new, lib.sh) → ~/.second-brain/transcripts/sub-<agent_id>_<slug>_<date>.txt
        │  (keyed on agent_id; respects the existing prune cap)
        ▼
  EXISTING episodic indexer (globs transcripts/*.txt) + dream transcript selection — no change
```

## 1. `scripts/subagent-capture.sh` (the hook target)

Reads stdin JSON; pure bash + jq; always exits 0.

1. Parse `transcript_path`, `agent_id`, `agent_type`, `session_id`, `cwd`. Missing
   `transcript_path` or unreadable file → exit 0.
2. **Self-exclude**: if `agent_type` is one of the plugin's own agents → exit 0 silently:
   `dream-runner`, `knowledge-maintainer`, `code-review-unit-reviewer`, `code-review-scorer`,
   `code-review-history-reviewer`, `quality-reviewer`, `search-conversations`. (Matched on the
   bare name and any `plugin:...:name` suffix form, since plugin agents register namespaced.)
3. **Substantive gate**:
   - `tool_count` = count of `tool_use` blocks in the transcript (reuse the Stop extractor's
     jq counter). `< 1` → exit 0 (mechanical/no-work).
   - `result` = last `assistant` record's concatenated `text` blocks. If trimmed length
     `< SB_SUBAGENT_MIN_RESULT` (default 80 chars) → exit 0 (near-empty, e.g. the 4-byte case).
4. **Archive** the result via `sb_archive_subagent_result` (below). Exit 0.
- Kill switch: `SB_SUBAGENT_CAPTURE=off` → exit 0 immediately (parity with other hooks).
- Resolve slug the same way the rest of the plugin does (`sb_resolve_slug` / basename cwd).

## 2. `sb_archive_subagent_result()` in `scripts/lib.sh`

A sibling to `sb_archive_transcript`, keyed on `agent_id` so subagent archives never collide
with main-session ones and de-dupe per agent:

```
archive_file = $BRAIN_DIR/transcripts/sub-${agent_id}_${slug}_${date}.txt
```

Writes a meta header (`--- subagent-result ---`, agent_type, agent_id, session_id, slug,
date, tool_count) then the final result text **written plain** — it is already prose
(the last assistant text block), NOT raw JSONL, so `sb_preprocess_transcript` (which parses
transcript-line JSON) must NOT be applied to it. Calls `sb_prune_transcripts` so the existing
100-file / 5MB cap governs total growth. Returns 0 on success, non-fatal on failure.

## 3. Episodic + dream integration (no change required — verify)

The episodic indexer globs `~/.second-brain/transcripts/*.txt`; `sub-*.txt` files match, so
subagent results become episodic-searchable automatically. Dream transcript selection reads
the same dir. The implementation plan MUST verify both globs include the new prefix (read the
indexer + dream selection code) rather than assume — if either filters by the
`<session>_<slug>_` name shape, adjust the glob.

## 4. hooks.json wiring

Add a `SubagentStop` event, matcher `"*"` (self-exclusion is in-script for robustness), one
command hook: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/subagent-capture.sh`, short timeout (5s),
fail-open. Keep `Bash(bash *)`-style allowlisting consistent with sibling hooks.

## Error handling

| Case | Behaviour |
|---|---|
| `SB_SUBAGENT_CAPTURE=off` | exit 0 immediately |
| Missing/empty `transcript_path` | exit 0 |
| Transcript unreadable / malformed JSONL | exit 0 (jq tolerant; skip) |
| `agent_type` absent | treat as non-self; still apply the substantive gate |
| Self agent | exit 0 silently |
| Below tool-count or near-empty result | exit 0 (not archived) |
| Archive write fails | log via existing error path, exit 0 (never block the subagent) |
| Any unexpected error | exit 0 — a blocking SubagentStop would wedge fan-outs |

## Testing — `tests/test-subagent-capture.sh`

Per [[validate-the-real-capability]], drive the script with realistic SubagentStop stdin +
a fixture subagent transcript; assert the archive (or its absence):

1. **substantive non-self** (e.g. agent_type `general-purpose`, transcript with tool_use +
   a real final result) → `sub-<agent_id>_*.txt` created, contains the final result text +
   meta, NOT the full transcript.
2. **self agent** (`dream-runner`) → no archive (exit 0).
3. **namespaced self** (`plugin:second-brain:knowledge-maintainer`) → no archive.
4. **below tool-gate** (transcript with 0 tool_use) → no archive.
5. **near-empty result** (final assistant text < 80 chars, the real 4-byte case) → no archive.
6. **missing transcript_path** → exit 0, no archive, no crash.
7. **malformed stdin** → exit 0.
8. **filename keys on agent_id** → two different agents in one session produce two files; a
   subagent archive never overwrites the main-session `<session>_<slug>_<date>.txt`.
9. **kill switch** `SB_SUBAGENT_CAPTURE=off` → no archive.
10. **prune cap respected** → after archive, `sb_prune_transcripts` keeps ≤100 files.

Plus: confirm (read, don't assume) the episodic indexer glob matches `sub-*.txt`.

## File-change inventory

**New:**
- `scripts/subagent-capture.sh`
- `tests/test-subagent-capture.sh`

**Modified:**
- `scripts/lib.sh` — add `sb_archive_subagent_result()`.
- `hooks/hooks.json` — add `SubagentStop` event.
- `skills/upgrade/SKILL.md` — migration row (additive; no precondition).
- (only if the verify step shows a name-shape filter) episodic indexer / dream selection glob.

## Rollout

Additive — no migration, no behavior change to existing extraction. Ships in 0.22.0. On the
next session that runs substantive non-self subagents, their conclusions start landing in the
transcript archive → dream/episodic. Kill switch `SB_SUBAGENT_CAPTURE=off`. Gated by the full
test suite + an adversarial review before merge (the auto-memory review just proved that pass
catches real bugs).
