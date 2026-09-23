---
name: audit
description: Show what the second-brain safety layer did this session — every PreToolUse guard verdict, every tool-return injection flag, every wiki-write decision. Reads ~/.second-brain/audit-log.jsonl produced by hooks. Read-only.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Bash(jq *) Bash(tail *) Bash(wc *) Bash(cat *) Bash(test *) Bash(grep *) Bash(sort *) Bash(uniq *) Bash(head *) Bash(printf *) Bash(date *) Bash(find *) Bash(sed *) Bash(tr *) Bash(bash *) Bash(cut *)
---

# Audit

Surface the trajectory the safety layer recorded — what hooks asked, denied, rewrote, or flagged. Inspired by HarnessAudit's principle that evidence must come from a channel the agent can't manipulate; this skill is the human-readable view of `~/.second-brain/audit-log.jsonl`.

## Argument parsing

The user can pass:

- `--session <id>` — filter to a specific session (default: current session, derived from `$CLAUDE_CODE_SESSION_ID` if set)
- `--all` — show across all sessions
- `--last <N>` — show only the last N entries (default 100)
- `--verdict <ask|deny|allow|flag|rewrite>` — filter by verdict type
- `--hook <name>` — filter by hook name (e.g. `persona-tool-guard.sh`, `tool-return-scanner.sh`)

When no flags are passed, default to: current session if known, else `--all`, with `--last 100`.

## Steps

### 1. Resolve the audit file

```bash
AUDIT="${BRAIN_DIR:-$HOME/.second-brain}/audit-log.jsonl"
test -f "$AUDIT" || { echo "No audit-log.jsonl yet — no guard activity recorded."; exit 0; }
```

If the file doesn't exist, say so plainly and stop. Don't fabricate a report.

### 2. Filter

Apply the user's filters via `jq` over JSONL. Skeleton:

```bash
jq -c '.' "$AUDIT" \
  | { [ -n "$SESSION" ] && jq -c "select(.session_id == \"$SESSION\")" || cat; } \
  | { [ -n "$VERDICT" ] && jq -c "select(.verdict == \"$VERDICT\")" || cat; } \
  | { [ -n "$HOOK" ]    && jq -c "select(.hook == \"$HOOK\")"       || cat; } \
  | tail -n "${LAST:-100}"
```

### 3. Report

Print a four-section dashboard. Keep it tight — this is a quick read, not an essay.

**Section A — Verdict counts**
```
ask:     12
flag:     3
deny:     0
rewrite:  4
allow:    0     (allow is only logged when explicit; absence = no allow events)
```

**Section B — Top rules triggered (top 5)**
```
1. resource-scope-out-of-scope     (8 events)
2. warn-rm-rf                       (3 events)
3. injection:ignore-previous-instructions  (2 events)
...
```

**Section C — Top targets (top 5)**
- For path targets, group by directory (first 3 segments).
- For Bash commands, group by leading verb.
- For URLs, group by host.

**Section D — Anomalies / things worth a look**
- Any `deny` verdict in the filtered range → list verbatim. A deny is rare and worth visibility.
- Any `flag` from `tool-return-scanner.sh` → list verbatim. These are *the* injection signals.
- Any rule that triggered ≥ 5 times in one session → list (likely either a real issue or a noisy rule that needs tuning).
- If the audit log has been rotated recently (file size near `SB_AUDIT_MAX_BYTES`), note it — pre-rotation events are lost.

### 3b. Native auto-memory state (the OTHER memory writer)

The safety layer governs the second-brain's own writes — but Claude Code's
built-in auto-memory is a SECOND writer the audit should make visible, so the
trajectory shows both. One line, read-only, via the shared detector:

```bash
AM=$(bash -c 'source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/scripts/lib.sh"; sb_auto_memory_state' 2>/dev/null)
am() { printf '%s\n' "$AM" | grep -E "^$1=" | head -1 | cut -d= -f2-; }
printf 'native auto-memory: %s  store=%s (%s files)\n' "$(am state)" "$(am path)" "$(am files)"
```

Parse the detector's `key=value` output with `grep`/`cut` — **never `eval`** it:
the `path` field is derived from `settings.json` (a trust boundary), and `eval`
on settings-derived data is a code-injection vector. See `sb_auto_memory_state`
in `scripts/lib.sh` (which also sanitizes the value defensively). This line is
informational — the audit never toggles auto-memory; `/second-brain:status`
carries the disable-offer details.

### 4. Interpretation hints

End with a one-line hint that points to action, not just data:

- If `ask` count is dominated by `resource-scope-out-of-scope` → suggest adding the recurring path to `SB_RESOURCE_SCOPE_EXTRA` in shell rc.
- If any `flag` from `tool-return-scanner.sh` appears → suggest treating the source URL/file as untrusted in future sessions, and document it in `[[trusted-sources]]`.
- If `deny` count > 0 → suggest reviewing the denied actions to confirm the rule was correct.
- If zero entries → say so plainly: "no safety-layer activity this filter; either no guards fired or the audit-log was rotated."

## What NOT to do

- Don't write to the audit log. This skill is read-only.
- Don't summarize *intent* (you don't know it). Summarize *what the guards recorded*.
- Don't infer "Claude was attacked" from a single `flag`. Many `<system>` or `ignore previous` strings appear in legitimate docs (including this very plugin's wiki on prompt injection). Flag → review the source, not panic.

## Output ergonomics

- Default to plain text with section headers. No emoji unless the user already uses them in their USER.md.
- Each section ≤ 10 lines. Truncate with "... and N more" when needed.
- End with the exact filter used so it's reproducible: `(filter: session=<id>, last=100, verdict=*, hook=*)`.
