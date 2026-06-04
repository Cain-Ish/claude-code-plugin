# SP-5 — Surface Cleanup + 3-OS Verification — Design

**Status:** approved (2026-06-04)
**Vision:** consolidation roadmap — final sub-project SP-5 of 6 (SP-0 ✓, SP-1 ✓, SP-2 ✓, SP-3 ✓, SP-4 ✓).
**Scope:** four small, independent audit-fixes surfaced by an SP-5 discovery sweep. No new feature; close gaps + add a preventive guard.

---

## Discovery summary

A discovery sweep ran across `skills/`, `agents/`, `scripts/`, and the SP-1..SP-4 additions:

- **Cross-OS portability of the SP-0..SP-4 scripts: clean.** The established conventions held — `awk -v` (no shell-var interpolation into awk source), `stat -c … || stat -f …` paired, no `mapfile`/`grep -P`/`find -printf`/`readlink -f`. No remediation needed there.
- **Agent allowed-tools:** only `knowledge-maintainer` invokes `node` (granted in SP-4); the rest are clean. But agents have **no guard** equivalent to skills' `test-skill-allowed-tools.sh`, which is why the missing `Bash(node *)` shipped undetected for ~10 versions.
- Four concrete findings remain (below).

## The four fixes

### A — `/second-brain:maintain` has no skill (the maintainer has no user entry point)

`/second-brain:maintain` is referenced as a user command throughout (the upgrade migration table, the `knowledge-maintainer` agent's Phase 4b/4c explicit-only boundary, the SP-4 0.24.13 row) and the consolidation vision names a "maintainer skill" as one of its two main skills — but there is no `skills/maintain/SKILL.md`. Today the maintainer fires only on natural-language "clean up the KB" (auto-dispatch). A user typing `/second-brain:maintain` gets nothing.

**Fix:** a thin, user-invocable `skills/maintain/SKILL.md` that dispatches the `knowledge-maintainer` agent for an **explicit** full run — modelled on the `dream` → `dream-runner` dispatch pattern (`Agent` in `allowed-tools`). The explicit path is exactly what runs Phase 4b (ai-block authoring) and **4c (raw-inbox drain)**, which auto-dispatched runs skip. This makes every existing `/second-brain:maintain` reference real and realizes the vision's maintainer skill.

Frontmatter:
```yaml
name: maintain
description: Run the knowledge-maintainer on the KB — audit, dedup, relate, enrich, author ai-blocks, and drain the raw inbox into wiki nodes. Explicit full run (incl. Phase 4b/4c).
user-invocable: true
disable-model-invocation: true
allowed-tools: Agent Read
```
Body: dispatch the `knowledge-maintainer` agent (an explicit maintenance run — all phases, including the explicit-only 4b/4c); report what it changed. No `--background` (the maintainer writes live and is bounded by its 50/run cap; background staging is `dream`'s job).

### B — `doc-sources.filterIgnored` Windows path separator

`mcp/src/tools/doc-sources.ts:53`:
```ts
const nonJunk = absPaths.filter((p) => !relative(projectRoot, p).split('/').some((seg) => JUNK_DIRS.has(seg)));
```
`path.relative` emits OS-native separators, so on Windows a path is a single segment after `split('/')` → `JUNK_DIRS` (`node_modules`, `.git`, …) never match → junk dirs are **not** filtered from the SP-1 doc-sources scan **and** the SP-3 setup deep-scan. The user runs Windows.

**Fix:** split on both separators — `.split(/[\\/]+/)` (the identical class SP-3's `isHighSignal` already fixed and tested with backslash paths). One-line change.

### C — no agent allowed-tools guard

Skills have `tests/test-skill-allowed-tools.sh`; agents have nothing, so a tool an agent invokes but doesn't declare (the `Bash(node *)` class) is caught only by chance. The sweep shows **no current gap** — this is preventive.

**Fix:** new `tests/test-agent-allowed-tools.sh` — for each `agents/*.md` with a `tools:` line, if its body invokes `node ` it must declare `Bash(node *)`; if it invokes `bash "$CLAUDE_PLUGIN_ROOT/…"` / `bash "${CLAUDE_PLUGIN_ROOT}/…"` it must declare a `Bash(bash …)` grant. (Read-only agents with no such invocations pass trivially.)

### D — stale legacy example in `doubt/SKILL.md`

`skills/doubt/SKILL.md:120` uses `tail -5 ~/.second-brain/learnings.md` as a runtime-state example — `learnings.md` is a removed 0.7.0 legacy file. Misleads a reader checking real artifacts.

**Fix:** replace with a file that exists (`~/.second-brain/persona-signals.jsonl`). Prose-only.

---

## Components

| File | Responsibility | Action |
|---|---|---|
| `skills/maintain/SKILL.md` | user-invocable explicit maintainer run | Create |
| `mcp/src/tools/doc-sources.ts` | split junk-check on both separators | Modify (1 line) |
| `mcp/src/tools/doc-sources.test.ts` | filterIgnored drops junk (regression guard) | Create or extend |
| `tests/test-agent-allowed-tools.sh` | agent tool-declaration guard | Create |
| `tests/test-maintain-skill.sh` | maintain skill present + dispatches the agent + user-invocable | Create |
| `skills/doubt/SKILL.md` | fix the stale example | Modify (1 line) |

## Testing (TDD)

| Test | Covers |
|---|---|
| `test-maintain-skill.sh` | `skills/maintain/SKILL.md` exists, is `user-invocable: true`, declares `Agent`, and its body dispatches the `knowledge-maintainer` agent + names Phase 4c |
| `doc-sources.test.ts` (vitest) | `filterIgnored(root, [<root>/node_modules/pkg/x.md, <root>/docs/y.md])` returns only the docs path (junk dropped); guards the split change |
| `test-agent-allowed-tools.sh` | every agent that invokes `node`/`bash $CLAUDE_PLUGIN_ROOT` declares the matching grant (passes now; fails if a future agent forgets) |
| `test-skill-allowed-tools.sh` (existing) | re-run — the new `maintain` skill must pass it (declares `Agent`/`Read`, the only tools it uses) |

## Versioning

One plugin patch bump `0.24.13` → `0.24.14` + a migration row covering all four. **No MCP server tool change** (B is an internal helper; server stays 2.6.4). Additive: the new `maintain` skill + guard are purely additive; B fixes a latent Windows bug; D is prose. Back-compat on Linux/macOS is unchanged (the `[\\/]` split is a no-op where there are no backslashes).

## Non-goals

- No broader refactor of skills/agents (the sweep found nothing else actionable).
- No `--background` for `maintain` (that's `dream`'s model; the live maintainer is cap-bounded).
- The vision is complete after SP-5; no SP-6.
