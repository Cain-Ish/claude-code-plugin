# C — Headless-LLM Maintainer (design)

- **Date:** 2026-06-05
- **Status:** spec → built (0.24.25). The autonomy capstone — the deferred "C" of the roadmap.
- **Consent:** explicit (user: "build C — the headless-LLM maintainer"); containment chosen: **airtight bwrap (staging-only)**.

## Goal

The AI **auto-authors knowledge unattended** (dedup / relate / enrich / summarize / forget) so the wiki self-improves — but **nothing reaches the live wiki without a human `dream_accept`**, and that guarantee is enforced by the **kernel**, not a prompt.

## How it reuses the dream loop

A dream already: stages a wiki snapshot → runs the LLM consolidation on *staging* → requires `dream_accept` (rsync staging→live). So C is **auto-triggering a dream out-of-band**:
1. `dream-snapshot.sh` stages (runs *outside* the jail — it must read live + write the new dream dir).
2. The dream-runner consolidation runs **headless + jailed** via `claude -p`.
3. The dream is left **completed-unaccepted**; the SP-C nudge surfaces it; the user reviews via `/second-brain:dream` + `dream_accept`. **Never auto-accepted.**

## The containment (the crux — why bypassPermissions is safe here)

An *unattended* agentic run needs `--permission-mode bypassPermissions` (no approval prompts). That is safe **only** because the run executes inside **bubblewrap** with:
- `--bind "$DREAM_DIR"` — ONLY this one dream's dir (staging + status.json) writable;
- `--ro-bind / /` — **everything else read-only**, the live wiki especially;
- `--bind ~/.claude` — OAuth creds/session; `--tmpfs /tmp`; `--unshare-pid --new-session --die-with-parent`.

So the headless agent **physically cannot write the live wiki** — `dream_accept` is the only path there, enforced by the kernel. **bwrap is required: if it's absent the run is SKIPPED, never executed unconfined** (a silent downgrade would defeat the user's choice). This makes airtight C **Linux-only**; macOS/Windows would need a different kernel sandbox (deferred — those users stay on explicit `/second-brain:maintain`).

## Gating (capture ≠ consolidation ≠ LLM-authoring consent)

`maintain-llm-drain.sh`, called as a final step of `extract-drain.sh`, runs **only** when ALL hold:
1. `config.json` **`auto_maintain: true`** — the C opt-in (default false; distinct from SP-B's `auto_improve`).
2. The drainer's CLAUDECODE-refuse / interactive-defer / single-flight guards (inherited) + a defense-in-depth CLAUDECODE refuse in the script itself.
3. `claude` **and** `bwrap` both present.
4. **No unreviewed dream already pending** (don't stack work the user hasn't seen).
Self-throttled to `SB_MAINTAIN_LLM_INTERVAL` (default 7d — a full consolidation costs Claude tokens). `SB_MAINTAIN_LLM_MODEL` (default `claude-sonnet-4-6`), `SB_MAINTAIN_LLM_TIMEOUT` (default 1800s).

## Operator-verified (the honest caveat)

The actual headless OAuth consolidation **cannot run from inside a Claude session** (the recursive-claude lock — the exact thing the whole drainer architecture dodges). So CI tests the **gating + the containment structure** (a `SB_MAINTAIN_LLM_DRYRUN=1` hook proves the gate reaches the jailed command after staging); the **real run is operator-verified** in an idle window — same pattern as the cross-OS schedulers. To verify on the Pi: `auto_maintain:true` + the OAuth drainer installed, then `SB_MAINTAIN_LLM_FORCE=1 bash …/maintain-llm-drain.sh` while not in a session → a dream completes in staging → review with `/second-brain:dream`.

## Verification

- **Linux-CI:** `test-maintain-llm-drain.sh` — containment structure (bwrap · bypassPermissions · dream-dir-only bind · ro-bind · bwrap-absent→skip · no-unconfined-claude); gating (off→no-run, throttle→skip, pending-dream→no-stack, proceeds→stages+reaches-the-jailed-run via DRYRUN). `test-config-reader.sh` — the `auto_maintain` seed.
- **Operator (Pi):** the real consolidation writes only staging; `dream_accept` applies it; nothing touched live before that.

## Rollout

Additive; gated; version bump + migration row. No MCP change. With `auto_maintain:false` (the seed) C never runs — behaviour is unchanged. Reuses dream-snapshot/dream-accept/the SP-C nudge entirely; the new surface is one gated script + one config flag.
