# Design: native auto-memory coordination

**Date:** 2026-05-29
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Target release:** 0.22.0 (additive; the only user action — disabling native memory — is opt-in)
**Roadmap item:** #1 (docs/specs/2026-05-29-cc-feature-adoption-roadmap.md)

## Summary

Claude Code ships **auto-memory** (GA, ON by default since CC v2.1.59): it autonomously
extracts learnings/preferences from sessions and writes per-repo markdown to
`~/.claude/projects/<project>/memory/MEMORY.md`. This is *exactly* what the second-brain's
Stop/PreCompact extractor (`stop-extract.sh` → `merge-project-update.sh`) and `pin_to_user`/
`pin_to_project` do — into a **different** store (`~/.second-brain/` + `~/knowledge/wiki/`).

Verified on this box: native auto-memory is **ON and unconfigured** (no `autoMemoryEnabled`
in any settings.json, no `CLAUDE_CODE_DISABLE_AUTO_MEMORY`), actively writing to
`~/.claude/projects/-home-cainish-Projects-claude-code-plugin/memory/` (the `MEMORY.md`
the harness injects at session start IS native auto-memory, not the plugin). Two memory
systems run uncoordinated; the user reconciles two stores by hand.

The plugin is **not** fully blind: `pin_to_user`'s tool description already routes plain
"remember this" to native auto-memory rather than the plugin. What's missing is **visibility**
(no skill surfaces the native store) and a **coordination posture** (no detection, no opt-out
offer). This design adds exactly that — the plugin becomes the explicit single source of
truth, surfacing the native store and offering (never forcing) to disable it.

## Goals

- **Detect** native auto-memory state (on/off + store path + store size) deterministically,
  offline, with no `claude` subprocess — one shared bash helper.
- **Surface** it always (on or off) in `second-brain:status`, and as one line in `second-brain:audit`.
- **Offer** the disable command (`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` / `autoMemoryEnabled:false`)
  as text — never auto-toggle settings or env (matches the user's "never auto-mutate
  hard-to-reverse config" stance and the plugin's "USER.md rules are advisory" posture).
- **No data migration, no behavior change to native** — fully reversible, additive.

## Non-goals (YAGNI)

- **No ingest of native memory into the wiki/graph.** That was the "coexist + ingest"
  alternative; rejected for this cycle (dual-store dedup is real ongoing complexity). Can be
  a later spec if the user keeps native on.
- **No auto-disable / no settings writes.** The plugin reports + offers; the user acts.
- **No new MCP tool.** Detection is a bash helper consumed by skills; MCP isn't needed and
  would add an always-loaded tool.
- **No change to `pin_to_user`/`pin_to_project`** — the existing handoff note stays correct.

## Background: how native auto-memory behaves (verified vs CC 2.1.156 docs + this box)

| Fact | Value |
|---|---|
| Enabled by default | Yes, since CC v2.1.59 |
| Disable via env | `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` |
| Disable via settings | `autoMemoryEnabled: false` (project or user `settings.json`; toggle in `/memory`) |
| Store path | `~/.claude/projects/<project>/memory/` |
| `<project>` derivation | **Observed on disk:** the working-directory path with `/`→`-` (e.g. `/home/cainish/Projects/claude-code-plugin` → `-home-cainish-Projects-claude-code-plugin`). Docs say "derived from the git repository, shared across worktrees" — the dasherized-path form is what CC actually writes and is the authoritative scheme to match. |
| Relocate store | `autoMemoryDirectory` in **user** settings only (absolute or `~/`-prefixed); rejected from project/local for security |
| Entrypoint | `MEMORY.md` (first 200 lines / 25KB loaded every session); topic files loaded on demand |

## Architecture

```
  scripts/lib.sh
    └── sb_auto_memory_state()   ← single detector (pure bash, offline)
            │  prints 3 lines: STATE / PATH / SIZE
            ├──────────────► skills/status/SKILL.md  §4e "Native auto-memory" (always shown)
            └──────────────► skills/audit/SKILL.md    one-line report
```

One detector, two thin display consumers. The detector is the only new logic and the only
thing under test.

## 1. Detector — `sb_auto_memory_state()` in `scripts/lib.sh`

Contract: reads only the environment + settings files + the store dir. No network, no
`claude` call, never errors out (fail-soft to "unknown" rather than non-zero). Emits three
`key=value` lines on stdout so callers can parse without re-deriving:

```
state=on|off|unknown
reason=env-disabled|setting-disabled|default-on|unknown
path=/home/<u>/.claude/projects/<dashed-cwd>/memory
files=<int>            # .md files in the store, 0 if absent
memory_lines=<int>     # MEMORY.md line count, 0 if absent
```

**State precedence (matches CC's own resolution):**
1. `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` → `state=off reason=env-disabled`.
2. else `autoMemoryEnabled == false` in EITHER `.claude/settings.json` (project) OR
   `~/.claude/settings.json` (user) → `state=off reason=setting-disabled`.
   Disable is OR across layers (either layer saying `false` means native won't write,
   so the plugin should report off) — this avoids a precedence-direction guess and is
   the conservative reading: we only claim "on" when nothing anywhere disables it.
3. else → `state=on reason=default-on`.

**Path derivation:** `autoMemoryDirectory` from `~/.claude/settings.json` (user) if set
(expand leading `~/`); else `~/.claude/projects/<dashed>/memory` where `<dashed>` is the
current working directory absolute path with every `/` replaced by `-` (the observed CC
scheme). Helper stays cwd-relative — the skills resolve cwd before calling.

**Size:** if `path` exists, `files` = count of `*.md`; `memory_lines` = `wc -l` of
`MEMORY.md` (0 if absent). Missing dir → `files=0 memory_lines=0` (not an error — native may
be on but not yet have written anything).

## 2. `status` skill — new §4e "Native auto-memory" (always shown)

Inserted after §4c persona stats / §4d dream. Calls the detector, renders a fixed block
**whether on or off** (per user decision — "off" is a confirmed state worth seeing):

```
## Native auto-memory (Claude Code built-in)
- state: ON (default — not configured)        # or: OFF (CLAUDE_CODE_DISABLE_AUTO_MEMORY) / OFF (autoMemoryEnabled:false)
- store: ~/.claude/projects/<dashed>/memory/ (5 files, MEMORY.md 38 lines)
- note: Two memory systems are active. second-brain is the structured layer
  (graph + wiki + episodic recall); native is a flat per-repo MEMORY.md.
  To make second-brain the single source of truth, disable native:
    export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1     # env, per-shell/session
    # or add to settings.json:  "autoMemoryEnabled": false
  Leave both on to keep native's scratchpad alongside.
```

When `state=off`, the `note` collapses to a one-line confirmation (`native disabled —
second-brain is the sole memory writer`). `allowed-tools` gains the Bash globs the detector
needs (already mostly present: `cat`, `jq`, `wc`, `find`, `test`, `tr`, `printf`, `bash`).

## 3. `audit` skill — one-line native-memory state

`audit` reports the session's safety-layer activity. Add one line so the audit shows BOTH
memory writers were considered:

```
native auto-memory: ON  store=~/.claude/projects/<dashed>/memory (5 files)
```

Read-only; no new tool. Reuses the same `sb_auto_memory_state()` helper.

## 4. The offer is informational — never automatic

Neither skill writes settings, exports env, or runs `/memory`. They print the exact disable
command and stop. Rationale: disabling a Claude Code built-in is a hard-to-reverse-ish,
per-machine choice the user owns (consistent with step-by-step-for-destructive + the
advisory-not-enforced posture). This is the "surface + offer" posture chosen in design, not
"detect + auto-fix".

## Error handling

| Case | Behaviour |
|---|---|
| No settings.json anywhere | `state=on reason=default-on` (the real default) |
| Malformed settings.json | jq fails → treat that layer as "unset", fall through precedence; never crash |
| Store dir absent | `files=0 memory_lines=0`, `state` still computed (on/off is independent of whether native has written yet) |
| `autoMemoryDirectory` set to a weird value | Expand `~/` and absolute paths only; if neither, ignore and use the default path (don't fabricate) |
| Detector called outside any project | cwd-dashed path still computes; harmless |

## Testing — `tests/test-auto-memory-detect.sh`

Per [[validate-the-real-capability]], assert the detector's REAL output across the precedence
matrix (each case sets up an isolated `HOME`/cwd sandbox so the real `~/.claude` is untouched):

1. **default-on**: no env, no setting → `state=on reason=default-on`.
2. **env-disabled**: `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` → `state=off reason=env-disabled` (env beats setting).
3. **setting-disabled (project)**: `.claude/settings.json` `autoMemoryEnabled:false` → `state=off reason=setting-disabled`.
4. **setting-disabled (user)**: `~/.claude/settings.json` `autoMemoryEnabled:false`, no project setting → off.
4b. **either-layer-false**: project says `false`, user says `true` (and vice versa) → off (OR semantics).
5. **precedence**: env-disable set AND setting says true → still `off` (env wins).
6. **custom dir**: `autoMemoryDirectory:"~/x"` in user settings → `path` resolves to `~/x` expanded.
7. **store size**: seed a fake store with 3 `.md` + a 10-line MEMORY.md → `files=3 memory_lines=10`.
8. **missing store**: path absent → `files=0 memory_lines=0`, exit 0.
9. **malformed settings**: garbage json → no crash, falls through to default-on.

Skill-side (`status`/`audit`) changes are prompt/bash display; covered by the existing
`test-validate-plugin` frontmatter/allowed-tools checks + a manual render. No false
executable test for the prose.

## File-change inventory

**Modified:**
- `scripts/lib.sh` — add `sb_auto_memory_state()`.
- `skills/status/SKILL.md` — new §4e + dashboard example line + `allowed-tools` (if any glob missing).
- `skills/audit/SKILL.md` — one-line native-memory report + `allowed-tools` if needed.

**New:**
- `tests/test-auto-memory-detect.sh`.

## Rollout

Additive — no migration. Ships in 0.22.0. The user sees the native-memory section on the
next `/second-brain:status`; disabling native is their explicit opt-in. Upgrade-skill row
notes the new visibility (no precondition).
