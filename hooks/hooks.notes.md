# hooks.json wiring notes

Rationale for every entry in `hooks/hooks.json`. These notes used to live as
`_comment` keys inside the JSON itself; Claude Code's hook-config schema rejects
unknown keys and warned on all 13 of them, so the prose moved here.

**Key format:** `### <Event> — <script.sh>`. The anchor is the *script*, never an
array index, so reordering `hooks.json` cannot silently misalign a note.
`tests/test-guard-wiring.sh` enforces both directions: every heading here must
resolve to a live command under that event, and every hook group in `hooks.json`
must be named by at least one heading. A note for a deleted hook, or a hook added
without a note, fails the suite.

---

## SessionStart

### SessionStart — ensure-dirs.sh

matcher EXCLUDES `compact` — upstream anthropics/claude-code#15174: SessionStart
hook output is silently dropped after compaction (v2.0.72+), so running
session-load.sh on the compact event was pure waste. Removing it stops the
post-compact context-bloat loop reported by users on long sessions. NOTE: the
entries below run in PARALLEL, not top-to-bottom — Claude Code gives no
ordering guarantee within one event, so session-load.sh must not assume
ensure-dirs.sh's config.json/projects.jsonl scaffolding has already landed.

### SessionStart — dream-autostage.sh

dream-autostage — NEVER stages and never spawns agents: when >=
SB_DREAM_NEW_THRESHOLD (default 10) new transcripts accumulated since the last
terminal dream, it emits a banner SUGGESTING /second-brain:dream (explicit
invocation only). It also reclaims stale pendings (runner never started >24h)
into failed, and banners failed dreams + the maintainer quarantine file. Kill
switch SB_DREAM_AUTOSTAGE=off. Timeout 20s.

### SessionStart — protocol-guard.sh

class-5 working agreement (CONSTITUTION.md, docs/plans/2026-09-24-repo-brain.md)
— `card` mode prints the protocol card (tier table + behavioral reminders,
<=1200 B plain stdout, same delivery path as session-load.sh) directly to
SessionStart. Fail-open: any internal error emits nothing. Kill switches
SB_PROTOCOL_GUARD=off (all modes) and SB_PROTOCOL_CARD=off (this mode only).

## UserPromptSubmit

### UserPromptSubmit — persona-context.sh

Layer 1 persona infrastructure. Reads the prompt from STDIN and emits
`hookSpecificOutput.additionalContext` composed from persona-card.md identity,
the installed-plugin catalog summary, BM25 wiki hits, and an episodic search
hint. Each section is hard-capped. Always exits 0 — must never block a prompt.
EXCEPTION — the `/?` prefix routes to persona-think (Layer 2), which spawns a
paid Opus advisor call; that is the one path where this hook is not free (D145).

## Stop

### Stop — stop-verify-gate.sh

Blocks completion when code was modified but no verification evidence exists,
returning `{"decision":"block"}` to force Claude to run checks. Safety valve:
blocks at most twice per session (marker file). Always fails open — parse errors
or missing data approve. Includes the anti-game sub-check for test-file deletion:
verification evidence in a transcript window (lines since the last Stop's scan)
that also ran `rm`/`git rm` on a test-shaped path blocks UNCONDITIONALLY — there is no HEAD/index/transcript suppression (four
review rounds found a bypass in every such predicate; the full list is the
HISTORY block in tests/test-stop-verify-gate.sh). A scratch test file the session
created and deleted is a known, accepted false positive. Kill switches
SB_VERIFY_GATE=off, SB_VERIFY_ANTIGAME=off.

### Stop — sar-summary.sh

SAR summary — aggregates this session's audit-log verdicts into a one-line Safety
Adherence Rate banner via systemMessage. Read-only. NOTE: Claude Code runs all
matching hooks of one event in PARALLEL, not in array order — this entry is
listed last but is NOT guaranteed to execute after
stop-verify-gate.sh/stop-extract.sh; its audit-log rotation
(sb_rotate_audit_log) can race their concurrent appends to the same file. Kill
switch SB_SAR_SUMMARY=off.

## SubagentStop

### SubagentStop — subagent-capture.sh

subagent capture — archive a substantive, non-self subagent's FINAL result (not
its full transcript) into ~/.second-brain/transcripts/ so it becomes
dream-minable + episodic-searchable. matcher `*` = all subagents; self-exclusion
+ the substantive gate live in-script (a select-only matcher can't express "not
these"). MUST always exit 0 (a blocking SubagentStop wedges the parent fan-out).
OAuth-safe (file ops only). Kill switch SB_SUBAGENT_CAPTURE=off.

## PreCompact

### PreCompact — pre-compact.sh

Runs LLM extraction on the unprocessed transcript window BEFORE compaction
discards context, so decisions and patterns from early in a long session survive
compaction cycles. Works in tandem with stop-extract.sh: both advance a shared
line-marker file so each processes a disjoint window. With SB_EXTRACT=off the
LLM call is skipped but the window is still archived and the marker still
advances — a deterministic files-touched delta merges instead, exactly as an LLM
failure would produce. Timeout 45s.

## PreToolUse

### PreToolUse — persona-tool-guard.sh

matcher covers the file (Read/Write/Edit/MultiEdit), shell (Bash), network
(WebFetch/WebSearch), and subagent-spawn surface where tool_scope and sar_tool
apply. Both Task and Agent match — both agent-spawn tool names exist across CLI
versions and both must be guarded. MCP tools and read-only
Glob/Grep/TodoWrite/BashOutput omitted to keep hook cost low. That exclusion is a
recorded decision, pinned by the out-of-scope contract in
tests/test-guard-wiring.sh.

### PreToolUse — wiki-write-guard.sh

Denies writes to `~/knowledge/wiki/**/*.md` (excluding index.md) when the
resulting content lacks YAML frontmatter, forcing every new wiki page to ship
with the schema (title, description, type, created, updated, tags, related) so
BM25 retrieval works and knowledge_validate stays clean. Always exits 0; the
decision travels in hookSpecificOutput JSON on stdout. Kill switch
SB_PERSONA_GATE=off (shared with other persona-layer hooks).

### PreToolUse — symlink-guard.sh

symlink-guard (G-HOOK-2) — resolves file_path through symlinks FIRST, then denies
writes whose resolved path lands inside ~/.ssh, ~/.gnupg, ~/.aws,
~/.config/claude, ~/.config/gh, ~/.password-store, /etc, ~/.netrc, or
~/.claude/.credentials.json (the OAuth token — an explicit extra deny, not just a
~/.config/claude prefix match). Kill switch SB_SYMLINK_GUARD=off.

### PreToolUse — flow-guard.sh

outbound info-flow guard (sar_flow channel) — asks when an egress tool call (Bash
with network tool, or WebFetch/WebSearch) carries credential-shaped content.
Defense-in-depth against the agent helpfully pasting session secrets into a curl
request. Kill switch SB_FLOW_GUARD=off.

### PreToolUse — plan-first-nudge.sh

plan-first gate — intent-spine Gates A (plan-before-implement, deny-once with
auto-pass retry) and B (drift re-ground, warn once then deny once) on multi-file
substantive code work (>=SB_PLAN_FIRST_FILES files, default 2; drift at
>=SB_DRIFT_FILES zero-goal-overlap files, default 4), plus the plan->implement
phase flip. Fail-open; every verdict audit-logged. With SB_INTENT_SPINE=off it
degrades to the original soft once-per-session advisory (allow — never blocks).
Silent on single-file work and one-line diffs. Kill switches
SB_PLAN_FIRST_NUDGE=off, SB_INTENT_SPINE=off.

### PreToolUse — protocol-guard.sh

class-5 working agreement — `pre` mode on Task|Agent|Read|Edit|Write|MultiEdit:
Task/Agent gets a tier-mismatch delegation check (warn-only unless
SB_DELEGATION_REWRITE=1 rewrites `tool_input.model`); Read/Edit/Write/MultiEdit
gets path-triggered repo memory (Slice 2) and Write of a new path gets a
search-before-create nudge (Slice 3). At most one `hookSpecificOutput` envelope
per call. Never `deny`/`ask`, never blocks. Kill switches SB_PROTOCOL_GUARD=off,
SB_DELEGATION_CHECK=off, SB_DELEGATION_REWRITE (default off), SB_JIT=off,
SB_SEARCH_FIRST=off.

## SubagentStart

### SubagentStart — protocol-guard.sh

class-5 working agreement — `subagent` mode delivers a role card (<=900 B)
scoped to `agent_type`, skipping `second-brain:*` and `Plan` agents (they already
carry role-appropriate instructions). Fires on SubagentStart, ahead of the
subagent's first tool call. Fail-open: any internal error emits nothing. Kill
switches SB_PROTOCOL_GUARD=off, SB_ROLE_CARDS=off.

## ConfigChange

### ConfigChange — config-change-guard.sh

config-change audit (G-HOOK-3) — records every ConfigChange event to
audit-log.jsonl. Audit-only; never blocks. Matchers:
user_settings|project_settings|local_settings|policy_settings|skills. Kill switch
SB_CONFIG_CHANGE_AUDIT=off.

## PostToolUseFailure

### PostToolUseFailure — observe-tool-use.sh

observation ledger, failure side (0.40.1) — PostToolUse fires ONLY on successful
tool completion (code.claude.com/docs/en/hooks), so without this entry every
FAILED tool call — the exact error->fix class the ledger exists to mine — left no
line (live-reproduced on 0.40.0 ship day: exit-42 Bash, no record). Same script;
the event name alone forces ok:false. Kill switch SB_OBSERVATION_LEDGER=off.

## PostToolUse

### PostToolUse — quality-gate.sh

Quality-gate instruction injected after every Write/Edit via a PostToolUse
`hookSpecificOutput.additionalContext` envelope (D158 — plain stdout from a
PostToolUse hook is only ever shown in transcript mode; additionalContext JSON is
the only PostToolUse path into model context, the pattern simplicity-gate.sh
already uses). A jq-less host must still emit the envelope: falling through to
nothing silently drops the reminder from every edit. Kill switch
SB_QUALITY_GATE=off (D077).

### PostToolUse — tool-return-scanner.sh

HarnessAudit Layer 3 — scans Read/WebFetch/Bash/Grep/Glob output for
indirect-prompt-injection patterns. Flags via additionalContext; never blocks.
Kill switch SB_INJECTION_SCAN=off.

### PostToolUse — observe-tool-use.sh

observation ledger (P0 capture widening, 0.39.0) — appends one deterministic
JSONL line {ts, tool, target, ok, err} per tool use to
~/.second-brain/observations/<session>.jsonl. Survives Stop/PreCompact extraction
loss (the single-LLM-call SPOF) and records the ok|error dimension the
preprocessed transcript lacks; mined by the out-of-band drainer as extraction
input, swept by its 7-day GC. Grep/Glob deliberately excluded (high volume, low
mining value). Pure jq/bash, no output, never blocks. Kill switch
SB_OBSERVATION_LEDGER=off; per-session cap SB_OBSERVATION_MAX_BYTES (default
1 MiB).

### PostToolUse — simplicity-gate.sh

Persona Principle 2 (Simplicity First) — advisory nudge on a large single change.
Never blocks. Kill switch SB_SIMPLICITY_GATE=off; threshold
SB_SIMPLICITY_GATE_LINES (default 150).
