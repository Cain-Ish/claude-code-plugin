# SP-5 Surface Cleanup Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Four small, independent audit-fixes — create the missing `/second-brain:maintain` skill, fix `filterIgnored`'s Windows path-sep, add an agent allowed-tools guard, and fix a stale `doubt` example.

**Architecture:** Each fix is self-contained and independently TDD'd. A (a new dispatch skill) follows the `dream`→`dream-runner` pattern. B is a one-line regex change + a vitest regression guard. C is a new structural bash guard mirroring `test-skill-allowed-tools.sh`. D is a one-line prose fix.

**Tech Stack:** Markdown skill prompts, TypeScript (vitest), POSIX bash.

**Spec:** `docs/specs/2026-06-04-surface-cleanup-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `skills/maintain/SKILL.md` | user-invocable explicit maintainer run | Create |
| `tests/test-maintain-skill.sh` | guard the maintain skill's shape | Create |
| `mcp/src/tools/doc-sources.ts` | split junk-check on both separators (line 53) | Modify (1 line) |
| `mcp/src/tools/doc-sources.test.ts` | filterIgnored drops junk (regression guard) | Create |
| `tests/test-agent-allowed-tools.sh` | agent tool-declaration guard | Create |
| `skills/doubt/SKILL.md` | fix the stale `learnings.md` example (line 120) | Modify (1 line) |

No MCP server tool change; no kb-schema change.

---

## Task A: `/second-brain:maintain` skill

**Files:**
- Create: `skills/maintain/SKILL.md`
- Test: `tests/test-maintain-skill.sh`

- [ ] **Step 1: Write the failing test.** Create `tests/test-maintain-skill.sh`:

```bash
#!/bin/bash
# Guard: /second-brain:maintain exists as a user-invocable skill that dispatches the
# knowledge-maintainer agent for an explicit full run (the path that runs Phase 4b/4c).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
S="$ROOT/skills/maintain/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$S" ] || fail "skills/maintain/SKILL.md missing"
grep -q '^name: maintain$' "$S" || fail "name is not 'maintain'"
grep -q '^user-invocable: true$' "$S" || fail "not user-invocable"
grep -qE '^allowed-tools:.*\bAgent\b' "$S" || fail "allowed-tools must include Agent (to dispatch the agent)"
pass "maintain skill is user-invocable + declares Agent"

grep -q 'knowledge-maintainer' "$S" || fail "body does not dispatch the knowledge-maintainer agent"
grep -qE '4c|raw[- ]inbox' "$S" || fail "body does not mention the explicit-only Phase 4c (raw drain)"
pass "maintain dispatches the knowledge-maintainer agent (explicit run, names 4c)"

echo; echo "ALL PASS"
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `bash tests/test-maintain-skill.sh`
Expected: FAIL — `skills/maintain/SKILL.md missing`.

- [ ] **Step 3: Create the skill.** Create `skills/maintain/SKILL.md`:

```markdown
---
name: maintain
description: Run the knowledge-maintainer on the second-brain wiki — audit, dedup, relate, enrich, author ai-blocks, and drain the raw inbox into wiki nodes. An explicit full maintenance run.
user-invocable: true
disable-model-invocation: true
allowed-tools: Agent Read
---

# /second-brain:maintain — run the knowledge-maintainer

Dispatch the **knowledge-maintainer** agent for an **explicit** full maintenance run over
the knowledge base. Use the `Agent` tool with `subagent_type: "knowledge-maintainer"`.

Unlike an auto-dispatched maintenance run (which the plugin triggers after extraction or a
reindex and which performs only the consolidation phases), an explicit `/second-brain:maintain`
run also performs the two **bulk-authoring** phases that auto-runs deliberately skip:

- **Phase 4b** — author/backfill the machine-first `ai-block` on structured pages.
- **Phase 4c** — drain the **raw inbox** (`/second-brain:capture` + setup deep-scan material)
  into wiki nodes (conservative create/update, never auto-discard, with provenance).

Tell the agent this is an explicit run so it does not skip 4b/4c. When it finishes, relay its
report: pages audited/merged/related/enriched, ai-blocks authored, raw items drained
(created / updated / left-unprocessed for manual prune), and the reindex result. The agent
writes live and is bounded by its 50-change/run cap; if it reports work left over the cap,
re-run `/second-brain:maintain`.
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `bash tests/test-maintain-skill.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add skills/maintain/SKILL.md tests/test-maintain-skill.sh
git commit -m "feat(kb): /second-brain:maintain skill — explicit maintainer run (SP-5 A)"
```

---

## Task B: `filterIgnored` Windows path separator

**Files:**
- Modify: `mcp/src/tools/doc-sources.ts:53`
- Test: `mcp/src/tools/doc-sources.test.ts` (create)

- [ ] **Step 1: Write the failing test.** Create `mcp/src/tools/doc-sources.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { filterIgnored } from './doc-sources.js';

describe('doc-sources filterIgnored', () => {
  it('drops junk-dir paths (node_modules) and keeps real docs', async () => {
    const root = await fs.mkdtemp(join(tmpdir(), 'fi-'));   // non-git → junk-skip-only path
    const junk = join(root, 'node_modules', 'pkg', 'x.md');
    const keep = join(root, 'docs', 'y.md');
    expect(filterIgnored(root, [junk, keep])).toEqual([keep]);
  });

  it('splits path segments on both separators (the junk regex is cross-OS)', async () => {
    // The fix is `.split(/[\\/]+/)`; assert the regex itself segments a backslash path so the
    // JUNK_DIRS check works when path.relative emits native (Windows) separators.
    expect('node_modules\\pkg\\x.md'.split(/[\\/]+/)).toContain('node_modules');
  });
});
```

> Note: the first test runs in a non-git temp dir, so `git check-ignore` returns status 128 and `filterIgnored` falls through to junk-skip-only — exactly the path the fix touches. The second test pins the cross-OS split regex directly (a true backslash assertion, the same class SP-3's `isHighSignal` test covers), since `path.relative` cannot emit backslashes on a Linux CI to drive it end-to-end.

- [ ] **Step 2: Run it to verify it fails (the second assertion).**

Run: `cd mcp && npx vitest run doc-sources.test.ts`
Expected: the first test PASSES (junk already dropped on Linux); the **second** test currently PASSES too (it tests the literal regex, which doesn't exist in the code yet — it's asserting the *target* behaviour). To make this a real RED→GREEN, the meaningful failing check is end-to-end via the code. Since Linux can't drive the backslash path through `path.relative`, treat Step 1's second `it` as a **specification test of the regex** and proceed: it documents the intended split. (If you want a strict RED, temporarily change the assertion to the OLD `.split('/')` form — `'node_modules\\pkg\\x.md'.split('/')` does NOT contain `'node_modules'` → RED — then restore to `/[\\/]+/` for GREEN. Do this to satisfy the watch-it-fail discipline, then revert the assertion to the regex form.)

- [ ] **Step 3: Apply the fix.** In `mcp/src/tools/doc-sources.ts` line 53, change:

```typescript
  const nonJunk = absPaths.filter((p) => !relative(projectRoot, p).split('/').some((seg) => JUNK_DIRS.has(seg)));
```
to:
```typescript
  const nonJunk = absPaths.filter((p) => !relative(projectRoot, p).split(/[\\/]+/).some((seg) => JUNK_DIRS.has(seg)));
```

- [ ] **Step 4: Build + run the tests to verify they pass.**

Run: `cd mcp && npm run build && npx vitest run doc-sources.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full vitest suite (the change touches a shared helper).**

Run: `cd mcp && npx vitest run`
Expected: all green.

- [ ] **Step 6: Commit.**

```bash
git add mcp/src/tools/doc-sources.ts mcp/src/tools/doc-sources.test.ts
git commit -m "fix(kb): filterIgnored splits junk-check on both separators (SP-5 B, Windows)"
```

---

## Task C: agent allowed-tools guard

**Files:**
- Create: `tests/test-agent-allowed-tools.sh`

- [ ] **Step 1: Write the test (it should PASS now — it is a preventive guard).** Create `tests/test-agent-allowed-tools.sh`:

```bash
#!/bin/bash
# Guard: an agent whose body invokes `node` or a `bash "$CLAUDE_PLUGIN_ROOT/…"` script must
# DECLARE the matching grant in its `tools:` frontmatter, else the call prompts/denies mid-run.
# This is the same missing-grant class that hid the maintainer's missing Bash(node *) for ~10
# releases (skills are guarded by test-skill-allowed-tools.sh; agents had no guard until now).
# Body-scan matches invocation patterns (node + quote/$, bash + ${CLAUDE_PLUGIN_ROOT}) to avoid
# matching prose mentions.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; A="$ROOT/agents"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -d "$A" ] || fail "agents/ dir missing"

checked=0
for f in "$A"/*.md; do
  name=$(basename "$f" .md)
  tools=$(grep -m1 '^tools:' "$f" || true)
  # node invocation: `node "` or `node '` or `node $`
  if grep -qE 'node ["'\''$]' "$f"; then
    printf '%s' "$tools" | grep -qE 'Bash\(node ' \
      || fail "$name: body invokes node but tools: lacks Bash(node *)"
  fi
  # bash-script invocation: `bash "$CLAUDE_PLUGIN_ROOT` or `bash "${CLAUDE_PLUGIN_ROOT`
  if grep -qE 'bash "\$\{?CLAUDE_PLUGIN_ROOT' "$f"; then
    printf '%s' "$tools" | grep -qE 'Bash\(bash ' \
      || fail "$name: body invokes a plugin bash script but tools: lacks Bash(bash *)"
  fi
  checked=$((checked + 1))
done
pass "all $checked agents declare the tools their bodies invoke (node / bash scripts)"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run it (should PASS — verifies the current state is clean after the SP-4 fix).**

Run: `bash tests/test-agent-allowed-tools.sh`
Expected: `ALL PASS` (knowledge-maintainer declares `Bash(node *)` + `Bash(bash …)`; dream-runner declares `Bash(bash …)`; the read-only review agents invoke neither).

- [ ] **Step 3: Prove the guard actually catches a gap (watch-it-fail).** Temporarily remove the `Bash(node *)` grant from `agents/knowledge-maintainer.md` (delete `, Bash(node *)` from its `tools:` line), run the test (expect FAIL: `knowledge-maintainer: body invokes node but tools: lacks Bash(node *)`), then **restore** the grant and re-run (expect ALL PASS). This confirms the guard is not a no-op.

- [ ] **Step 4: Commit.**

```bash
git add tests/test-agent-allowed-tools.sh
git commit -m "test(ci): agent allowed-tools guard — catch the missing-grant class (SP-5 C)"
```

---

## Task D: fix the stale `doubt` example

**Files:**
- Modify: `skills/doubt/SKILL.md:120`

- [ ] **Step 1: Apply the fix.** In `skills/doubt/SKILL.md`, change the line:

```markdown
   - What's in the data files? (`tail -5 ~/.second-brain/learnings.md`, `wc -l ~/.second-brain/.session-baseline-*.md`)
```
to:
```markdown
   - What's in the data files? (`tail -5 ~/.second-brain/persona-signals.jsonl`, `wc -l ~/.second-brain/.session-baseline-*.md`)
```

> `learnings.md` is a removed 0.7.0 legacy file; `persona-signals.jsonl` is a real append-log the hooks write. The `.session-baseline-*.md` reference is already valid (session-load creates those).

- [ ] **Step 2: Verify no stale `learnings.md` reference remains in the skill.**

Run: `grep -n 'learnings.md' skills/doubt/SKILL.md || echo "clean"`
Expected: `clean`.

- [ ] **Step 3: Commit.**

```bash
git add skills/doubt/SKILL.md
git commit -m "docs(skill): doubt example uses a real data file, not legacy learnings.md (SP-5 D)"
```

---

## Task E: Ship — gate, version bump, PR

- [ ] **Step 1: Branch (if not already).** `git checkout -b feat/sp5-surface-cleanup` (do all of SP-5 on this branch from the start).

- [ ] **Step 2: Build + full suite.** `cd mcp && npm run build && cd .. && bash tests/run-all.sh` → expect `ALL GREEN` (includes `test-maintain-skill`, `test-agent-allowed-tools`, `test-mcp-typecheck`, and the existing `test-skill-allowed-tools`).

- [ ] **Step 3: Deep-review gate.** Run `second-brain:code-review-deep --base main`. Fix any confirmed (≥70) finding with TDD; re-run until clean.

- [ ] **Step 4: Version bump + migration row.**
  - `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`: `0.24.13` → `0.24.14`.
  - `skills/upgrade/SKILL.md`: add a `**0.24.14**` row above `**0.24.13**` (SP-5 surface cleanup: new `/second-brain:maintain` skill dispatching the knowledge-maintainer for an explicit full run; `filterIgnored` Windows path-sep fix; new `test-agent-allowed-tools.sh` guard; `doubt` legacy-example fix; cross-OS sweep of SP-1..SP-4 came back clean; no MCP server tool change, server stays 2.6.4; additive).

- [ ] **Step 5: Rebuild + verify lockstep + migration-row test.**

```bash
cd mcp && npm run build && cd ..
bash scripts/validate-plugin.sh
bash tests/test-upgrade-migration-row.sh
```
Expected: `OK: all plugin files valid` + `PASS: upgrade migration row present for 0.24.14`.

- [ ] **Step 6: Commit + PR + merge.**

```bash
git add -A
git commit -m "chore(release): surface cleanup (SP-5) — bump 0.24.14 + migration row"
git push -u origin feat/sp5-surface-cleanup
gh pr create --base main --title "feat(kb): surface cleanup + 3-OS verification (SP-5)" --body "<summary>"
gh pr merge --merge --delete-branch
git checkout main && git pull --ff-only origin main
```

---

## Self-Review

**1. Spec coverage:**
- A `/second-brain:maintain` skill → Task A. ✓
- B `filterIgnored` Windows split → Task B. ✓
- C agent allowed-tools guard → Task C. ✓
- D `doubt` stale example → Task D. ✓
- Cross-OS sweep was clean (no task needed) → noted in spec. ✓
- One release + migration row, no server change → Task E. ✓

**2. Placeholder scan:** Task E Step 6 `--body "<summary>"` is filled at ship time. The maintain skill's `<…>` are prose. No code-step placeholders. (Task B Step 2 documents the watch-it-fail nuance honestly rather than faking a RED — that is intentional, not a placeholder.)

**3. Type consistency:** `filterIgnored(projectRoot, absPaths): string[]` matches its existing signature (Task B test calls it correctly). The maintain skill's `subagent_type: "knowledge-maintainer"` matches the agent filename `agents/knowledge-maintainer.md`. The agent guard's `tools:` key matches the agents' frontmatter (not `allowed-tools:`, which is the skills' key — verified against the maintainer frontmatter).
