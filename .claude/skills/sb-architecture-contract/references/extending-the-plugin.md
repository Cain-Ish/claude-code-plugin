# Extending the plugin — add-a-hook and add-an-MCP-tool recipes

Sibling of sb-architecture-contract. The parent SKILL.md owns the WHY (wiring table §2, tool
catalog §5, invariants §7); this file is the end-to-end HOW for the two extension tasks that
previously had no single home: wiring a NEW hook and registering a NEW MCP tool. Every step
was verified against the working tree at 0.33.31 (2026-07-05). Depth stays with the owners:
flags → sb-config-and-flags §9; tests → sb-validation-and-qa; shipping → sb-change-control;
skills/agents markdown authoring → sb-docs-and-writing §5-6; bundle mechanics → sb-build-and-env §4.

Before either recipe: the surface budget is AT CAP (skills 18 / agents 9 / scripts 52 /
tests 153) — any new top-level `scripts/*.sh` or `tests/test-*.sh` fails `validate-plugin.sh`
unless `docs/surface-budget.json` is bumped in the SAME commit. Prefer folding into an existing
script; growth must be a deliberate, git-blameable choice (sb-change-control §2). A new hook is
classified "new feature" → plan doc expected (sb-change-control §1).

---

## Recipe A — add a hook

### A1. Write the hooks.json entry

Hooks live ONLY in `hooks/hooks.json` (not plugin.json). Entry shape, observable throughout the
file:

```json
{
  "_comment": "vX.Y.Z <name> — <semantics + the failure mode it closes>. Kill switch SB_<X>=off.",
  "matcher": "Write|Edit|MultiEdit",
  "hooks": [
    {
      "type": "command",
      "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh",
      "timeout": 5
    }
  ]
}
```

The `_comment` is a house convention every behavior hook follows: version or workstream id, what
it does, the kill switch, and any threshold with its default (see the plan-first-nudge and
sar-summary comments in `hooks/hooks.json`).

Validator rules (`scripts/validate-plugin.sh:9-68`) — what FAILS vs WARNs:

| Check | Verdict |
|---|---|
| hooks.json not valid JSON | FAIL |
| Missing `matcher` on a matcher-honoring event | FAIL |
| Empty `hooks` array, or an entry missing `command` | FAIL |
| A `matcher` declared on an event that IGNORES matchers — the set is `UserPromptSubmit Notification SessionEnd Stop PostToolBatch TeammateIdle TaskCreated TaskCompleted WorktreeCreate WorktreeRemove CwdChanged` (validate-plugin.sh:21) | WARN (it would be silently ignored at runtime — remove it) |
| SessionStart matcher outside `startup\|resume\|clear\|compact` (validate-plugin.sh:22) | WARN |

NEVER re-add `compact` to the live SessionStart matcher — upstream drops SessionStart output
after compaction (anthropics/claude-code#15174; parent SKILL.md §2 and weak point 8).

### A2. Choose the posture — the fork that decides everything else

Three postures exist in-tree; pick ONE and follow its contract (the fail-loud/fail-safe split is
non-negotiable 1 in sb-change-control §9):

| Posture | Contract | Exemplars |
|---|---|---|
| Capture/context (SessionStart, UserPromptSubmit, Stop, SubagentStop, PreCompact) | Fail-SOFT: always `exit 0` (a blocking SubagentStop wedges the parent fan-out — hooks.json comment); FIRST line of behavior honors the nested-spawn breaker `[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0` (persona-context.sh:14-15, ensure-dirs.sh:3); errors go through `sb_log_error`, never silent `2>/dev/null` exits | `stop-extract.sh`, `persona-context.sh` |
| Security guard (PreToolUse) | Fail-SAFE: always exit 0, verdict via hookSpecificOutput JSON; must STAY ARMED when lib.sh is unsourceable — define a minimal inline fallback (`persona-tool-guard.sh:26-30` stubs `sb_log_audit(){ :; }`; symlink-guard keeps an inline fallback normalizer, locked by `tests/test-symlink-guard.sh:249-264`); deliberately does NOT honor `SB_NESTED_SPAWN` (lib.sh:1255 comment: tool-safety stays active inside headless children); EVERY path comparison goes through `sb_normalize_path` or all three guards' Windows fail-open history repeats (invariant 12) | `symlink-guard.sh`, `wiki-write-guard.sh` |
| Advisory nudge (PreToolUse/PostToolUse) | Never blocks: `permissionDecision: "allow"` + `additionalContext`, or additionalContext alone; once-per-session marker if it could nag | `plan-first-nudge.sh:7`, `simplicity-gate.sh` |

### A3. Script skeleton (conventions observable in `wiki-write-guard.sh:1-24`)

```bash
#!/bin/bash
# <name>.sh — <Event> hook for <matcher>. <What it does + the failure mode it closes.>
# Kill switch: SB_<X>=off
# Always exits 0. Decision is conveyed via hookSpecificOutput JSON on stdout.
set -u

[ "${SB_<X>:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0

TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null | tr -d '\r')
```

Hard rules: `set -u`, never `set -e`; kill switch before any work; `| tr -d '\r'` after EVERY
`jq -r` capture (jq 1.8.1 emits CRLF on Windows); bash-3.2/BSD-safe — the 11 portability guards
scan `scripts/` statically (sb-validation-and-qa); no `awk`; sanitize any session_id used in a
path (`tr -dc 'A-Za-z0-9_-' | cut -c1-64` — sb-config-and-flags §9 step 1); the war-story header
comment names the incident, not just the what.

### A4. The stdin payload — fields that actually arrive, per event

| Event | Fields read by in-tree consumers | Evidence |
|---|---|---|
| PreToolUse / PostToolUse | `.tool_name`, `.tool_input.<field>` (`file_path`, `content`, `new_string`, `.tool_input.edits[]?.new_string` for MultiEdit), `.session_id`, `.hook_event_name` | `wiki-write-guard.sh:17-23,99-130` |
| UserPromptSubmit | `.prompt`, `.session_id` | `persona-context.sh:23-27` |
| Stop / PreCompact | `.transcript_path`, `.cwd`, `.session_id` | `stop-extract.sh:52-54` |

Treat empty/absent stdin as a no-op `exit 0` — never crash on a malformed payload.

### A5. The output contract — what to emit, per event

This is the part that was previously written down nowhere as a recipe. All shapes verified:

| Event | Emit | Effect | Evidence |
|---|---|---|---|
| SessionStart | PLAIN stdout markdown | injected as session context | `session-load.sh:683` (`cat "$OUTPUT_FILE"`) |
| UserPromptSubmit | `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"…"}}` | context added to the prompt | `persona-context.sh:44-48` |
| PreToolUse | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"\|"ask"\|"allow","permissionDecisionReason":"…"}}`; advisory form adds `additionalContext` beside `permissionDecision:"allow"` | gate the tool call | `wiki-write-guard.sh:46-56`; `plan-first-nudge.sh:76` |
| PostToolUse | `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"…"}}` | context after the tool result | `simplicity-gate.sh:20` |
| Stop | `{"decision":"block","reason":"…"}` forces Claude to keep working; `{"systemMessage":"…"}` renders a user-visible banner | `stop-verify-gate.sh:4,90`; `sar-summary.sh:87` |

Build the JSON with `jq -nc --arg … || true` so a jq failure cannot break the exit-0 contract
(the `deny()` helper in `wiki-write-guard.sh:46-56` is the copyable pattern).

SILENCE = allow. A PreToolUse guard that prints nothing has allowed the call — indistinguishable
from a guard that is not running. That is why liveness is proven by injecting a violation
(sb-debugging-playbook D1), and why your deny message should be actionable prose: it is the only
thing the blocked model sees.

### A6. Audit every verdict

Guards and gates log through `sb_log_audit <hook> <verdict> <rule> <target> <reason>
<session_id> [extra_json]` — verdict vocabulary `allow | ask | deny | flag` (persona-tool-guard
also logs `rewrite`); appends are fail-soft; rotation is handled for you (`scripts/lib.sh:251-306`).
An audit log with zero deny/ask ever is itself a symptom — write verdicts so the record exists.

### A7. Heavy hook? Wrap it in the timer

`bash ${CLAUDE_PLUGIN_ROOT}/scripts/hook-timer.sh <budget_s> ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh`
with `<budget_s>` mirroring the entry's `timeout`. The wrapper is TRANSPARENT telemetry only —
it never kills or gates the child; it appends `{kind:"latency",…,budget_warn}` to audit-log at
>70% of budget (`hook-timer.sh:2-17,45-54`). Wrapped today: session-load (15), dream-autostage
(20), persona-context (10), stop-extract (45), pre-compact (45). 5-second advisory hooks are not
wrapped.

### A8. Kill switch and knobs

Every behavior hook ships a documented env kill switch, tested BOTH ways, named in the header,
the hooks.json `_comment`, and any banner text it emits. Follow the full 8-step add-a-flag
checklist in sb-config-and-flags §9 (its worked example, `plan-first-nudge.sh`, IS a hook).

### A9. Tests

Guard tests use the `assert_allow`/`assert_deny` jq-decoding helpers
(`tests/test-symlink-guard.sh:39-56`), PATH-stubbed `cygpath`/`realpath` so Windows branches run
on Linux/BSD CI, the fallback-branch rule (tool ABSENT, lib.sh unsourceable, kill switch both
ways), an independent oracle, the regression-lock comment, and test-the-test. Recipes R1-R6 +
the add-a-test checklist: sb-validation-and-qa. Prove the hook is ARMED post-merge with the
one-shot probe in sb-debugging-playbook D1.

### A10. The same-commit ship set

New `scripts/*.sh` → `docs/surface-budget.json` `scripts` +1. `scripts/` and `hooks/` are both
version-tripwire trigger paths → version bump in `plugin.json` + `marketplace.json`. CHANGELOG
bullet naming the default, the kill switch, and the regression lock. All gates green locally.
Sequence and gate list: sb-change-control §§2-4.

---

## Recipe B — add an MCP tool

### B1. The tool module — `mcp/src/tools/<name>.ts`

Module conventions (all verified against `mcp/src` on 2026-07-05):

- **Named exports only.** Zero `export default` exists in `mcp/src` — keep it that way.
- **`.js` suffix on every relative import**, even under bundler resolution
  (`import { pinToUser } from "./tools/pin-to-user.js"` — the pattern of all ~20 relative
  imports in `mcp/src/server.ts:8-28`).
- **zod never enters a tool module.** `server.ts` is the ONLY file importing zod (verified
  grep); tool modules export plain typed functions, the server boundary owns schema validation.
- **Pure-function surface**: decision logic in exported pure functions with unit tests; a CLI
  `main()` only wires them.

### B2. Path resolution — use the funnels, never roll your own

`resolveBrainDir` from `./brain-paths.js` is the ONLY sanctioned brain-dir source; the
source-scan test (`mcp/src/brain-paths.test.ts:90-114`) FAILS the build on `process.env.HOME`
or a `.second-brain` string literal anywhere else. For the knowledge dir, know the OPEN
two-wikis split (parent SKILL.md §6): three divergent `resolveKnowledgeDir` copies already
exist with conflicting precedence and NO scan lock — do not add a fourth; import an existing
one and note which precedence you inherit.

### B3. Register in `mcp/src/server.ts`

```ts
server.registerTool(
  "<tool_name>",
  {
    description: "<what + when-to-use, written for the calling model>",
    inputSchema: { field: z.string().describe("…"), mode: z.enum(["a", "b"]) },
  },
  guardDestructive("<tool_name>", async ({ field, mode }) => {
    const result = await myTool({ field, mode });
    return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
  })
);
```

(Exemplar: `pin_to_user`, `mcp/src/server.ts:115-125`.) Wrap EVERY tool that writes or mutates
in `guardDestructive` — it refuses under `SB_NESTED_SPAWN=1`, because a headless spawn over
untrusted transcript content once had reachability to all write tools (fixed 0.32.0; parent
SKILL.md §5). Read-only tools take the bare handler.

### B4. Needs a standalone CLI?

Append an esbuild invocation to `scripts.bundle` in `mcp/package.json` — keep the ` && `
separator exactly (test-bundle-current splits on it) — then `cd mcp && npm run build` and
commit the new `mcp/dist/**` file. Mechanics and flags: sb-build-and-env §4. Bash callers reach
bundles only via `sb_plugin_root` (lib.sh:311); agents only via the scoped grant
`Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)` (agent-grants lock).

### B5. Tests

Colocated `<name>.test.ts` in `mcp/src/**` or tool-level in `mcp/test/`; hermetic (mkdtemp,
save/restore mutated env); must pass OFFLINE (`SECOND_BRAIN_DISABLE_EMBEDDINGS=1 HF_HUB_OFFLINE=1
TRANSFORMERS_OFFLINE=1 npm test`); `npx tsc --noEmit` separately — vitest never typechecks. No
surface-budget key counts `.test.ts` files. Checklist: sb-validation-and-qa.

### B6. The same-commit ship set

`mcp/src` + `mcp/dist` are tripwire trigger paths → version bump; rebuilt bundles committed
(bundle-current byte-compares); CHANGELOG bullet; update the parent SKILL.md §5 tool table and
its re-verify count (was 21 — `grep -c 'registerTool(' mcp/src/server.ts`); README if
user-facing ("README matches what ships"). If a consolidation agent's protocol must call the
new tool, add the MCP grant to that agent's frontmatter AND extend `mcp/src/agent-grants.test.ts`
in the same commit — a prose promise without a machine lock is a future defect
(sb-change-control §9 rule 7).

---

## Provenance and maintenance

Authored 2026-07-05 against the 0.33.31 working tree (HEAD `6fba312` + uncommitted batch),
entirely from repo evidence: `hooks/hooks.json`, `scripts/validate-plugin.sh:9-68`,
`scripts/wiki-write-guard.sh`, `scripts/persona-context.sh:1-60`, `scripts/persona-tool-guard.sh:26-30`,
`scripts/stop-extract.sh:52-54`, `scripts/stop-verify-gate.sh`, `scripts/sar-summary.sh:87`,
`scripts/simplicity-gate.sh:20`, `scripts/plan-first-nudge.sh`, `scripts/session-load.sh:683`,
`scripts/hook-timer.sh`, `scripts/lib.sh:251-306,1255`, `scripts/ensure-dirs.sh:3`,
`mcp/src/server.ts` (imports :1-28, resolveKnowledgeDir :29-43, pin_to_user :115-125),
`mcp/src/brain-paths.test.ts`, `mcp/package.json`. Convention greps run 2026-07-05: zod imports
→ only server.ts; `export default` in mcp/src → 0; `registerTool(` → 21.

Re-verify before trusting:

```bash
jq -r '.hooks | keys[]' hooks/hooks.json                        # events (was 8)
sed -n '21,22p' scripts/validate-plugin.sh                      # NO_MATCHER_EVENTS + SessionStart matcher set
grep -rln 'from "zod"' mcp/src --include='*.ts'                 # zod confinement (was: server.ts only)
grep -rln 'export default' mcp/src --include='*.ts' | wc -l     # named-exports rule (was 0)
grep -c 'registerTool(' mcp/src/server.ts                       # tool count (was 21)
grep -n 'guardDestructive' mcp/src/server.ts | head -3          # destructive wrap in use
grep -n 'hook-timer.sh' hooks/hooks.json                        # which hooks are timer-wrapped (was 5)
```
