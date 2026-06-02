# AI-Native Representation — Phase 3 (Maintenance + Backfill) Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Close the AI-native block lifecycle — blocks now get *refreshed* (not just created), missing blocks are *surfaced* (validate + lint), and existing blockless pages get *backfilled* by the maintainer over its normal passes.

**Architecture:** Three deliverables from spec §12 P3, each honoring the automation boundary (extractor automatic; dream/maintainer explicit-invocation-only):
1. **Refresh on update** — the *automatic* half: `merge-project-update.sh` UPDATE path replaces/injects the authored block (the extractor already computes `ai_region` for updates; today only CREATE consumes it). Offline, mawk-safe, idempotent.
2. **Lint staleness** — `knowledge_validate` gains `ai_block_missing` (structured, substantive, blockless page) — spec §7 "warns on missing block"; surfaced standalone by a new bash `/second-brain:lint` Check 4. Offline, deterministic.
3. **Backfill** — a deterministic `kb-ai-block-candidates.sh` work-list + a new maintainer **Phase 4b** that authors blocks from existing prose (the `kb-project-backfill` deterministic-script + LLM-authors split). Explicit-invocation, bounded by the 50-change cap, closed-vocabulary. The dream stays **surface-only** (single authoring path = the maintainer; correct rationale — NOT "reindex overwrites", which is false: reindex never touches ai-blocks).

**Tech Stack:** bash (mawk 1.3.4 — never string-interpolate, use `-v`/`ENVIRON`), TypeScript (vitest), the existing `ai-block.ts` pure module + `ai-block-render-cli` bundle, agent/skill prompt files.

**Non-goals (deferred, with rationale):**
- **Timestamp block↔prose drift** (spec §7 "block older than body's `updated`"): the block carries no authored-time; a single-file deterministic drift check isn't computable without adding a per-block timestamp that would pollute the closed schema + the snippet. The robust offline signal is *structural* (missing block) — shipped here. A future phase could add a block-level `updated:`/content-hash facet to enable true drift detection.
- **Phase 2b** (the block's own embedding/vector) — needs embeddings; offline-first stays BM25.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `scripts/merge-project-update.sh` | capture-time page writer | Modify: UPDATE path refreshes the block (415 boundary) |
| `scripts/extract-prompt.txt` | extractor instruction | Modify: emit `ai_block` for `update` too (§65-75) |
| `mcp/src/tools/knowledge-validate.ts` | wiki health checks | Modify: `ai_block_missing` (40-48) |
| `mcp/src/tools/knowledge-validate.test.ts` | validate tests | Modify: add `ai_block_missing` cases |
| `skills/lint/SKILL.md` | standalone offline health-check | Modify: Check 4 (missing block) |
| `tests/test-lint-skill.sh` | lint guard | Modify: assert Check 4 present + mawk-safe |
| `scripts/kb-ai-block-candidates.sh` | deterministic backfill work-list | Create |
| `tests/test-kb-ai-block-candidates.sh` | candidate-script guard | Create |
| `agents/knowledge-maintainer.md` | live consolidation agent | Modify: Phase 4b authoring/backfill |
| `tests/test-maintainer-ai-block-backfill.sh` | maintainer guard | Create |
| `skills/dream/SKILL.md`, `agents/dream-runner.md` | dream consolidation | Modify: surface-only block-gap note |
| `tests/test-dream-ai-block-parity.sh` | dream guard | Create |
| `scripts/merge-project-update.sh` test | refresh guard | Create `tests/test-merge-ai-block-refresh.sh` |

---

## Task 1: Refresh the authored ai-block on UPDATE (merge-project-update.sh)

**Files:**
- Test: `tests/test-merge-ai-block-refresh.sh` (create)
- Modify: `scripts/merge-project-update.sh` (insert before the `else` create-branch at line 415)

`ai_region` is already computed at 355-359 for any update carrying `.ai_block`; only the CREATE branch (424) consumes it. Phase 3 makes the UPDATE branch (395-414) refresh the block: **replace** a complete existing region in place, **inject** after frontmatter if absent, and **leave untouched** a malformed (begin-without-end) page — never eat the body (the FORGET-bug class).

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# Phase 3: merge-project-update.sh refreshes the authored ai-block on UPDATE (not just create).
# Replace-in-place when a complete region exists; inject when absent; never corrupt a malformed page.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SCRIPT="$ROOT/scripts/merge-project-update.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"
command -v node >/dev/null 2>&1 || { echo "SKIP: node required"; exit 0; }
[ -f "$ROOT/mcp/dist/tools/ai-block-render-cli.bundle.js" ] || { echo "SKIP: render CLI not built"; exit 0; }

KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings"
PROJ="$TMP/PROJECT.md"
printf '%s\n' '# PROJECT: t' '## Goal' 'g.' '## State' 's.' '<!-- last_updated: 2026-05-01T00:00:00Z -->' > "$PROJ"
run(){ jq -nc "$1" | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$KD" >/dev/null 2>&1; }

# 1) create page WITH a block, then UPDATE with a fresh block → block REPLACED in place, one region.
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"refr",action:"create",title:"R",description:"d",
    content:"original prose body line.",ai_block:{claim:"old claim",action:"old action"}}]}' || fail "create exited nonzero"
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"refr",action:"update",title:"R",description:"d",
    content:"a brand new distinct second observation.",ai_block:{claim:"new claim",action:"new action"}}]}' || fail "update exited nonzero"
P="$KD/wiki/learnings/refr.md"
[ "$(grep -c '<!-- ai:begin' "$P")" -eq 1 ] || fail "expected exactly one ai:begin after refresh, got $(grep -c '<!-- ai:begin' "$P")"
grep -q '^claim: new claim$' "$P" || fail "block not refreshed (claim still old)"
grep -q 'old claim' "$P" && fail "stale block field 'old claim' survived the refresh"
grep -q 'original prose body line' "$P" || fail "original prose lost during refresh"
grep -q 'brand new distinct second observation' "$P" || fail "appended update content lost"
pass "UPDATE replaces an existing ai-block in place, preserving prose"

# 2) page with NO block gets one INJECTED on update (after frontmatter, before H1).
printf '%s\n' '---' 'title: Inj' 'type: learnings' 'created: 2026-05-01T00:00:00Z' 'updated: 2026-05-01T00:00:00Z' '---' '' '# Inj' '' 'long standing prose.' > "$KD/wiki/learnings/inj.md"
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"inj",action:"update",title:"Inj",description:"d",
    content:"some genuinely new appended detail here.",ai_block:{claim:"injected claim",action:"do"}}]}' || fail "inject-update nonzero"
I="$KD/wiki/learnings/inj.md"
grep -q '<!-- ai:begin' "$I" || fail "block not injected into a previously-blockless page on update"
grep -q '^claim: injected claim$' "$I" || fail "injected block missing claim"
awk 'BEGIN{fm=0} /^---[[:space:]]*$/{fm++} fm>=2 && /<!-- ai:begin/{ok=1} /^# Inj/{ if(!ok) exit 1; exit 0 } END{exit (ok?0:1)}' "$I" || fail "injected block not between frontmatter and H1"
pass "UPDATE injects a block into a previously-blockless page (after frontmatter, before H1)"

# 3) malformed page (ai:begin without ai:end) is left UNTOUCHED — never eat the body.
printf '%s\n' '---' 'title: Bad' 'type: learnings' 'updated: 2026-05-01T00:00:00Z' '---' '<!-- ai:begin -->' 'claim: dangling' '' '# Bad' 'irreplaceable prose tail.' > "$KD/wiki/learnings/bad.md"
before=$(cat "$KD/wiki/learnings/bad.md")
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"bad",action:"update",title:"Bad",description:"d",
    content:"new line for the malformed page.",ai_block:{claim:"replacement",action:"do"}}]}' || true
grep -q 'irreplaceable prose tail' "$KD/wiki/learnings/bad.md" || fail "malformed page body was eaten by the refresh"
[ "$(grep -c 'ai:begin' "$KD/wiki/learnings/bad.md")" -eq 1 ] || fail "refresh added a second begin marker to a malformed page"
pass "malformed (begin-without-end) page is not corrupted by refresh"

echo; echo "ALL PASS"
```

- [ ] **Step 2: Run it — expect FAIL** (`bash tests/test-merge-ai-block-refresh.sh`) on test 1 ("block not refreshed (claim still old)") — UPDATE discards `ai_region` today.

- [ ] **Step 3: Implement** — in `scripts/merge-project-update.sh`, insert immediately after the `updated:` bump (after line 414) and before the `else` at line 415:

```bash
      # Phase 3: refresh the authored ai-block on UPDATE (CREATE already injects it; 355-359
      # computed $ai_region for any update carrying .ai_block). Replace a COMPLETE region in
      # place; inject after frontmatter if absent; leave a malformed begin-without-end page
      # untouched (never eat the body — the FORGET-bug class). mawk-safe: $ai_region via ENVIRON.
      if [ -n "$ai_region" ]; then
        if grep -q '<!-- ai:begin' "$target_file" 2>/dev/null; then
          if grep -qE '<!--[[:space:]]*ai:end[[:space:]]*-->' "$target_file" 2>/dev/null; then
            AI_REGION="$ai_region" awk '
              BEGIN { reg = ENVIRON["AI_REGION"] }
              /<!-- ai:begin/ { print reg; drop=1; next }
              drop && /<!--[[:space:]]*ai:end[[:space:]]*-->/ { drop=0; next }
              drop { next }
              { print }
            ' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
          fi
          # else: malformed (begin without end) → no-op (safe)
        else
          AI_REGION="$ai_region" awk '
            BEGIN { reg = ENVIRON["AI_REGION"]; fm=0; done=0 }
            /^---[[:space:]]*$/ && fm<2 { print; fm++; if (fm==2 && !done) { print ""; print reg; print ""; done=1 } next }
            { print }
          ' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
        fi
      fi
```

- [ ] **Step 4: Run it — expect PASS** (all three sub-tests).
- [ ] **Step 5: Commit** (`test(ai-block): RED refresh-on-update` then `feat(ai-block): refresh authored block on UPDATE (Phase 3 Task 1)`).

## Task 2: Extractor emits ai_block for `update` actions (extract-prompt.txt)

**Files:**
- Modify: `scripts/extract-prompt.txt` (the `ai_block` rule, lines 65-75)
- Test: extend `tests/test-merge-ai-block.sh`? No — prompt-only; guard by grep in Task-1's suite is sufficient. Add a one-line assertion to `tests/test-merge-ai-block-refresh.sh`.

- [ ] **Step 1: Add the failing assertion** to `tests/test-merge-ai-block-refresh.sh` (before `echo "ALL PASS"`):

```bash
# Prompt instructs refresh on update (so the extractor actually emits a block for update actions).
grep -qiE 'ai_block.*(update|refresh)|(update|refresh).*ai.?block|refresh.*in place' "$ROOT/scripts/extract-prompt.txt" \
  || fail "extract-prompt.txt does not instruct emitting/refreshing ai_block on update"
pass "extract-prompt instructs ai_block refresh on update"
```

- [ ] **Step 2: Run — expect FAIL** (no such instruction yet).
- [ ] **Step 3: Implement** — append to the `ai_block` rule (after line 75 "Omit `ai_block` entirely if you can't summarise it."):

```
    Emit `ai_block` for `update` actions too — the page's block is refreshed in place from the
    current best understanding, not only authored on `create`. A stale block is worse than none.
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** (`feat(ai-block): extractor refreshes ai_block on update (Phase 3 Task 2)`).

## Task 3: `knowledge_validate` flags `ai_block_missing` (spec §7)

**Files:**
- Test: `mcp/src/tools/knowledge-validate.test.ts` (add cases)
- Modify: `mcp/src/tools/knowledge-validate.ts`

- [ ] **Step 1: Write failing tests** — append inside the `describe('addFrontmatter category typing', …)` block (or a new describe) in `knowledge-validate.test.ts`:

```typescript
  it('flags a structured, substantive page with NO ai-block as ai_block_missing', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-miss-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    await fs.writeFile(join(wiki, 'learnings', 'big.md'),
      '---\ntitle: Big\ntype: learnings\n---\n# Big\n' + 'substantive prose detail. '.repeat(20));
    const res = await knowledgeValidate(dir, { autofix: false });
    const w = res.issues.find(i => i.type === 'ai_block_missing' && /big/.test(i.message));
    expect(w).toBeDefined();
    expect(w!.severity).toBe('warning');
  });
  it('does NOT flag a short structured stub as ai_block_missing', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-stub-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    await fs.writeFile(join(wiki, 'learnings', 's.md'), '---\ntitle: S\ntype: learnings\n---\n# S\ntiny.');
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'ai_block_missing')).toBeUndefined();
  });
  it('does NOT flag a non-structured type (state) or a generated MOC as ai_block_missing', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-nonstruct-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'state'), { recursive: true });
    await fs.mkdir(join(wiki, 'projects'), { recursive: true });
    await fs.writeFile(join(wiki, 'state', 'st.md'), '---\ntitle: St\ntype: state\n---\n# St\n' + 'long state prose. '.repeat(20));
    await fs.writeFile(join(wiki, 'projects', 'p.md'), '---\ntitle: P\ntype: projects\ngenerated: true\n---\n# P\n' + 'long moc prose. '.repeat(20));
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'ai_block_missing')).toBeUndefined();
  });
  it('does NOT double-flag: a page WITH a block is never ai_block_missing', async () => {
    const dir = await fs.mkdtemp(join(tmpdir(), 'kv-has-'));
    const wiki = join(dir, 'wiki');
    await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
    await fs.writeFile(join(wiki, 'learnings', 'h.md'),
      '---\ntitle: H\ntype: learnings\n---\n<!-- ai:begin -->\nclaim: c\naction: a\n<!-- ai:end -->\n# H\n' + 'prose. '.repeat(20));
    const res = await knowledgeValidate(dir, { autofix: false });
    expect(res.issues.find(i => i.type === 'ai_block_missing')).toBeUndefined();
  });
```

- [ ] **Step 2: Run — expect FAIL** (`cd mcp && npx vitest run src/tools/knowledge-validate.test.ts`) — `ai_block_missing` not emitted.
- [ ] **Step 3: Implement** in `knowledge-validate.ts`:
  - Extend the import (line 4): `import { parseAiBlock, validateAiBlock, stripAiBlock, AI_BLOCK_SCHEMAS } from './ai-block.js';`
  - Add `'ai_block_missing'` to the `ValidationIssue['type']` union (line 7).
  - Add a constant near the top of the module: `const AI_BLOCK_MIN_PROSE = 200;`
  - Replace lines 40-48 with:

```typescript
    // AI-block checks (gentle, additive — spec §7). A block present but missing a required
    // field → ai_block_incomplete. A structured, SUBSTANTIVE page with NO block at all →
    // ai_block_missing (predates the feature / never authored). Stubs + non-structured types
    // + generated MOCs are exempt.
    const aiBlock = parseAiBlock(content);
    const ptype = doc.type || basename(dirname(filePath));
    if (aiBlock) {
      const missing = validateAiBlock(ptype, aiBlock);
      if (missing.length) issues.push({
        type: 'ai_block_incomplete', severity: 'warning', path: filePath,
        message: `ai-block missing required field(s) for type ${ptype}: ${missing.join(', ')}`,
      });
    } else if (AI_BLOCK_SCHEMAS[ptype] && !/[/\\](projects|themes)[/\\]/.test(filePath)) {
      const prose = stripAiBlock(content)
        .replace(/<!--\s*graph:begin[\s\S]*?graph:end\s*-->/g, '')
        .replace(/<!--\s*theme:begin[\s\S]*?theme:end\s*-->/g, '')
        .replace(/^---\n[\s\S]*?\n---\n/, '');
      if (prose.trim().length >= AI_BLOCK_MIN_PROSE) issues.push({
        type: 'ai_block_missing', severity: 'warning', path: filePath,
        message: `${ptype} page has substantive prose but no ai-block: ${slug}`,
      });
    }
```

- [ ] **Step 4: Run — expect PASS** (4 new + existing green).
- [ ] **Step 5: Commit** (`feat(ai-block): knowledge_validate flags ai_block_missing (Phase 3 Task 3)`).

## Task 4: `/second-brain:lint` Check 4 — missing ai-block (standalone, offline)

**Files:**
- Modify: `skills/lint/SKILL.md` (add Check 4 + reporting line)
- Modify: `tests/test-lint-skill.sh` (parse-check the new awk block)

The lint skill is standalone bash (no MCP). Mirror `knowledge_validate`'s structural signal in the lint idiom: scan the six structured-type dirs for pages without `<!-- ai:begin` whose prose ≥ 200 non-space chars.

- [ ] **Step 1: Add a failing assertion** to `tests/test-lint-skill.sh` (follow its existing per-block parse-check pattern — add):

```bash
grep -q 'Missing ai-block' "$SKILL" || fail "lint skill missing Check 4 (ai-block)"
```
(plus the suite already parse-checks every awk block; the new block is covered automatically.)

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** — add to `skills/lint/SKILL.md` after Check 3 (before `## Reporting`):

````markdown
### 4. Missing ai-block on structured pages

A page in one of the six structured categories (learnings, decisions, entities, issues,
concepts, security) should carry an `<!-- ai:begin … ai:end -->` block (the machine-first
shared intermediate). A *substantive* page (≥ 200 non-space prose chars) with no block
predates the feature or was never authored — surface it so the maintainer backfills it.
Stubs are exempt. (`infm`/`drop`, not the reserved `in` — see the awk header note.)

```bash
for type in learnings decisions entities issues concepts security; do
  d="$KD/wiki/$type"; [ -d "$d" ] || continue
  find "$d" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | while read -r f; do
    grep -q '<!-- ai:begin' "$f" 2>/dev/null && continue
    prose=$(awk '
      NR==1 && /^---[[:space:]]*$/ { infm=1; next }
      infm && /^---[[:space:]]*$/  { infm=0; next }
      infm { next }
      /<!--[[:space:]]*(graph|theme|ai):begin/ { drop=1 }
      drop { if (/<!--[[:space:]]*(graph|theme|ai):end[[:space:]]*-->/) drop=0; next }
      { print }
    ' "$f" | tr -d '[:space:]' | wc -c)
    [ "$prose" -ge 200 ] && echo "MISSING-BLOCK: $type/$(basename "$f" .md) ($f)"
  done
done
```

Suggest: run `/second-brain:maintain` (the knowledge-maintainer backfills blocks from the
page's prose) — do NOT hand-author here.
````

Add to `## Reporting` example a `## Missing ai-blocks (N)` section line.

- [ ] **Step 4: Run — expect PASS** (`bash tests/test-lint-skill.sh`).
- [ ] **Step 5: Commit** (`feat(ai-block): lint Check 4 surfaces missing blocks (Phase 3 Task 4)`).

## Task 5: `kb-ai-block-candidates.sh` — deterministic backfill work-list

**Files:**
- Create: `scripts/kb-ai-block-candidates.sh`
- Test: `tests/test-kb-ai-block-candidates.sh` (create)

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# kb-ai-block-candidates.sh: deterministic, read-only enumeration of blockless structured
# pages with substantive prose. One TSV row per candidate: <type>\t<slug>\t<path>.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SC="$ROOT/scripts/kb-ai-block-candidates.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$SC" ] || fail "script missing"
W="$TMP/knowledge/wiki"; mkdir -p "$W"/{learnings,state,projects}
# candidate: structured, no block, long prose
printf '%s\n' '---' 'title: A' 'type: learnings' '---' '# A' "$(printf 'real prose detail. %.0s' $(seq 1 20))" > "$W/learnings/cand.md"
# NOT: has a block
printf '%s\n' '---' 'title: B' 'type: learnings' '---' '<!-- ai:begin -->' 'claim: c' '<!-- ai:end -->' '# B' "$(printf 'prose. %.0s' $(seq 1 20))" > "$W/learnings/hasblock.md"
# NOT: stub (short)
printf '%s\n' '---' 'title: C' 'type: learnings' '---' '# C' 'tiny.' > "$W/learnings/stub.md"
# NOT: non-structured type
printf '%s\n' '---' 'title: D' 'type: state' '---' '# D' "$(printf 'long state prose. %.0s' $(seq 1 20))" > "$W/state/st.md"
# NOT: generated MOC dir
printf '%s\n' '---' 'title: P' 'type: projects' '---' '# P' "$(printf 'long moc prose. %.0s' $(seq 1 20))" > "$W/projects/p.md"

OUT=$(bash "$SC" --knowledge-dir "$TMP/knowledge")
echo "$OUT" | grep -q $'^learnings\tcand\t' || fail "candidate not listed"
echo "$OUT" | grep -q 'hasblock' && fail "page WITH a block listed"
echo "$OUT" | grep -q 'stub' && fail "stub listed"
echo "$OUT" | grep -q $'^state\t' && fail "non-structured type listed"
echo "$OUT" | grep -q 'projects' && fail "generated MOC listed"
[ "$(echo "$OUT" | grep -c .)" -eq 1 ] || fail "expected exactly 1 candidate, got $(echo "$OUT" | grep -c .)"
pass "enumerates only blockless, substantive, structured pages"

# idempotent / read-only: running twice yields identical output, mutates nothing
H1=$(md5sum "$W/learnings/cand.md"); bash "$SC" --knowledge-dir "$TMP/knowledge" >/dev/null; H2=$(md5sum "$W/learnings/cand.md")
[ "$H1" = "$H2" ] || fail "script mutated a page (must be read-only)"
pass "read-only + deterministic"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run — expect FAIL** ("script missing").
- [ ] **Step 3: Implement** `scripts/kb-ai-block-candidates.sh`:

```bash
#!/bin/bash
# Deterministic, read-only backfill work-list (AI-native Phase 3). One TSV row per blockless
# structured wiki page with substantive prose: <type>\t<slug>\t<path>. The knowledge-maintainer
# (Phase 4b) authors an ai-block for each. Idempotent (pure read; a page with <!-- ai:begin -->
# is skipped). No mutation. Mirrors kb-project-* tooling. mawk-safe.
#
# Usage: bash kb-ai-block-candidates.sh --knowledge-dir <dir>
set -u
KDIR=""; MINPROSE="${SB_AI_BLOCK_MIN_PROSE:-200}"
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KDIR="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$KDIR" ] || KDIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"
KDIR="${KDIR/#\~/$HOME}"
WIKI="$KDIR/wiki"; [ -d "$WIKI" ] || exit 0

for type in learnings decisions entities issues concepts security; do
  dir="$WIKI/$type"; [ -d "$dir" ] || continue
  find "$dir" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | sort | while IFS= read -r f; do
    grep -q '<!-- ai:begin' "$f" 2>/dev/null && continue   # idempotent: already authored
    prose=$(awk '
      NR==1 && /^---[[:space:]]*$/ { infm=1; next }
      infm && /^---[[:space:]]*$/  { infm=0; next }
      infm { next }
      /<!--[[:space:]]*(graph|theme|ai):begin/ { drop=1 }
      drop { if (/<!--[[:space:]]*(graph|theme|ai):end[[:space:]]*-->/) drop=0; next }
      { print }
    ' "$f" | tr -d '[:space:]' | wc -c)
    [ "$prose" -ge "$MINPROSE" ] || continue
    printf '%s\t%s\t%s\n' "$type" "$(basename "$f" .md)" "$f"
  done
done
```

- [ ] **Step 4: Run — expect PASS.** Then `chmod +x scripts/kb-ai-block-candidates.sh`.
- [ ] **Step 5: Commit** (`feat(ai-block): deterministic backfill candidate script (Phase 3 Task 5)`).

## Task 6: knowledge-maintainer Phase 4b — author/refresh blocks (backfill)

**Files:**
- Modify: `agents/knowledge-maintainer.md` (insert Phase 4b after Phase 4 ENRICH, before Phase 5, ~line 222)
- Test: `tests/test-maintainer-ai-block-backfill.sh` (create)

- [ ] **Step 1: Write the failing guard test**

```bash
#!/bin/bash
# Guard: the knowledge-maintainer knows how to backfill ai-blocks (Phase 4b), uses the
# deterministic candidate script + render path, and inherits the closed-vocab / cap /
# explicit-invocation boundary. Prompt-only guard (greps the agent contract).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; M="$ROOT/agents/knowledge-maintainer.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
grep -qiE 'Phase 4b|ai-block authoring|backfill' "$M" || fail "no Phase 4b / backfill section"
grep -q 'kb-ai-block-candidates.sh' "$M" || fail "does not reference the candidate work-list script"
grep -qiE 'renderAiBlock|ai-block-render-cli|render CLI' "$M" || fail "no render path referenced"
grep -qiE 'validateAiBlock|knowledge_validate' "$M" || fail "no self-validation referenced"
grep -qiE 'six (structured|known) types|closed[- ]vocab' "$M" || fail "closed-vocabulary boundary not stated"
grep -qiE 'never invent|extract.*from.*(prose|existing)|do not hallucinate' "$M" || fail "never-invent-values rule absent"
grep -qiE '50.*change|counted against|cap' "$M" || fail "cap inheritance not stated"
pass "maintainer Phase 4b contract present (candidate script + render + validate + closed-vocab + cap + never-invent)"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** — insert after Phase 4 ENRICH (after line 221, before `## Phase 5: REINDEX`):

````markdown
## Phase 4b: AI-block authoring / backfill (machine-first shared intermediate)

Each structured page should carry an `<!-- ai:begin … ai:end -->` block — the schema'd,
machine-first summary an AI reads instead of re-deriving from prose. The extractor authors it
at capture; you **backfill** the pages that predate the feature and **refresh** stale ones.
This is the same per-category understanding Phase 4 just applied, emitted as the closed schema.

1. **Get the deterministic work-list** (blockless, substantive, structured pages):
   ```bash
   bash "$CLAUDE_PLUGIN_ROOT/scripts/kb-ai-block-candidates.sh" --knowledge-dir "$KD"
   ```
   Each TSV row is `<type>\t<slug>\t<path>`. (A page that already has a block is skipped —
   idempotent. The script never mutates.)

2. **For each candidate** (closed vocabulary — only `learnings, decisions, entities, issues,
   concepts, security`; the schema fields per type are below — same source of truth as §4 of
   the design spec and your ENRICH guidance above):
   - Read the page body. **Extract** field values from the EXISTING prose + frontmatter only.
     **Never invent / hallucinate** a value — a field you can't ground in the page is left
     unset (the block is gentle/optional). Values are SHORT plain-text propositions, never
     `[[wiki-links]]`.
   - Schemas: `learnings`: claim, trigger, action, scope, evidence, supersedes · `decisions`:
     context, choice, alternatives, rationale, status, supersedes · `entities`: identity,
     current_state, depends_on, owns, status · `issues`: symptom, cause, fix, severity, status
     · `concepts`: problem, solution, where_applied, tradeoffs · `security`: threat,
     mitigation, scope, status.
   - **Render** the region deterministically (closed-vocab post-filter, marker-token
     neutralization — do not hand-format):
     ```bash
     jq -nc --arg t "<type>" --argjson b '<block-json>' '{type:$t,block:$b}' \
       | node "$CLAUDE_PLUGIN_ROOT/mcp/dist/tools/ai-block-render-cli.bundle.js"
     ```
   - **Inject** the rendered region with `Edit`: between the frontmatter close (`---`) and the
     first `# Heading`. Replace an existing region in place (refresh); never add a second.
   - **Self-check**: a follow-up `knowledge_validate` run must report no `ai_block_incomplete`
     /`ai_block_missing` for the page (required fields you couldn't ground stay a gentle
     warning — that's fine, don't fabricate to silence it).

3. **Budget**: each block authored counts as **one change against the 50/run cap** (unlike the
   Phase 1 autofix sweep, which is uncounted). If candidates exceed the remaining budget,
   author the highest-value first and **report the rest for the next run** — never exceed the cap.

**Boundary:** this runs only when you (the maintainer) are **explicitly invoked** — never
auto-dispatched on extraction or dream output (that would revert the 0.21.0 hardening). Never
author blocks for non-structured types or generated `projects/`/`themes/` pages.
````

- [ ] **Step 4: Run — expect PASS** (`bash tests/test-maintainer-ai-block-backfill.sh`).
- [ ] **Step 5: Commit** (`feat(ai-block): maintainer Phase 4b authors/backfills blocks (Phase 3 Task 6)`).

## Task 7: Dream parity — surface-only block-gap note

**Files:**
- Modify: `skills/dream/SKILL.md` (2d ENRICH), `agents/dream-runner.md` (Phase 4 ENRICH)
- Test: `tests/test-dream-ai-block-parity.sh` (create)

Dream is **surface-only** for blocks. Rationale (corrected): authoring stays a **single path
through the maintainer** — the dream already defers relationship/edge curation to the
maintainer, and authoring a block in staging would re-derive from prose the dream just rewrote.
(NOT because "reindex overwrites blocks" — reindex never touches ai-blocks; they are authored
content, unlike `related:`/`graph:begin`.) Gated `SB_DREAM_AI_BLOCKS=off`.

- [ ] **Step 1: Write the failing guard test**

```bash
#!/bin/bash
# Guard: dream is ai-block AWARE but surface-only (never authors blocks in staging), and gates
# behind SB_DREAM_AI_BLOCKS. Both the skill and the runner agent must agree (inline/background parity).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
S="$ROOT/skills/dream/SKILL.md"; R="$ROOT/agents/dream-runner.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
for f in "$S" "$R"; do
  grep -qiE 'ai-block|ai:begin' "$f" || fail "$(basename "$f"): no ai-block awareness"
  grep -qiE 'surface|suggest|recommend|report' "$f" || fail "$(basename "$f"): no surface-only language"
  grep -q 'SB_DREAM_AI_BLOCKS' "$f" || fail "$(basename "$f"): missing SB_DREAM_AI_BLOCKS kill switch"
  grep -qiE 'do not author|never author|not.*hand-author|maintainer' "$f" || fail "$(basename "$f"): does not defer authoring to the maintainer"
done
pass "dream skill + runner: ai-block surface-only, defers to maintainer, kill-switch present"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** — add to `skills/dream/SKILL.md` at the end of **2d. ENRICH** (after its existing bullets):

```markdown
- **AI-blocks (surface-only; skip if `SB_DREAM_AI_BLOCKS=off`)** — scan staging for structured
  pages (learnings/decisions/entities/issues/concepts/security) lacking an `<!-- ai:begin -->`
  block and count them. **Do NOT author blocks in staging** — block authoring stays a single
  path through the live **knowledge-maintainer** (it grounds the block in the page's current
  prose; the dream would re-derive from prose it is still rewriting). Surface the count in the
  dream report: "N structured pages have no ai-block — run `/second-brain:maintain` to backfill."
```

Add the mirrored bullet to `agents/dream-runner.md` Phase 4 ENRICH (after its `related:` deferral note), same wording.

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** (`feat(ai-block): dream surfaces block gaps, defers authoring (Phase 3 Task 7)`).

## Task 8: Build + release (0.24.3) + gate

**Files:** `mcp/` (build), `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `mcp/src/server.ts`, `skills/upgrade/SKILL.md`.

- [ ] **Step 1:** Build bundles — `cd mcp && npm run build` (recompiles validate + bundles; render CLI unchanged but rebuild is safe). Verify `dist/` updated.
- [ ] **Step 2:** Version lockstep → **0.24.3**: bump `version` in `.claude-plugin/plugin.json` and the matching entry in `.claude-plugin/marketplace.json`; bump the knowledge-base server version string in `mcp/src/server.ts` (validate gained an issue type — additive; patch the version, no MCP tool-signature change → protocol version unchanged unless the repo convention bumps it).
- [ ] **Step 3:** Add a `0.24.3` migration row to `skills/upgrade/SKILL.md` (target version, summary: refresh-on-update + ai_block_missing validate/lint + maintainer Phase 4b backfill + candidate script + dream surface-only; idempotent check: "no precondition — bumping the marker is sufficient; optional: run `/second-brain:maintain` once to backfill existing pages, bounded 50/run").
- [ ] **Step 4:** Full suite — `bash tests/run-all.sh` (or the repo's runner): all shell + `cd mcp && npx vitest run` green. Read the output.
- [ ] **Step 5:** Deep-review gate — `/second-brain:code-review-deep` on the branch; fix every confirmed finding + regression-test; re-run suite green. (Release gate per the deep-review-release-gate preference.)
- [ ] **Step 6:** Commit + open PR `feat(kb): AI-native representation Phase 3 — maintenance + backfill — 0.24.3`.

---

## Self-Review

- **Spec coverage (§12 P3):** refresh (Task 1+2), lint staleness (Task 3 validate "warns on missing block" §7 + Task 4 lint), backfill (Task 5 candidates + Task 6 maintainer); dream parity (Task 7). Timestamp-drift (§7 second bullet) explicitly deferred with rationale. ✔
- **Automation boundary (§5b):** Task 1/2 = automatic (extractor); Task 6/7 = explicit-invocation-only; no auto-dispatch added. ✔
- **mawk-safety:** every awk uses `ENVIRON`/`-v` or literal programs — no shell interpolation into awk source. ✔
- **Offline-first:** every Phase-3 path is BM25/bash; no embeddings introduced. ✔
- **Type consistency:** `ai_block_missing` issue type used identically in validate code + tests; `kb-ai-block-candidates.sh` TSV `<type>\t<slug>\t<path>` consumed verbatim by maintainer Phase 4b. ✔
- **Reversibility:** blocks are additive marked regions (delete to revert); candidate script + lint are read-only. ✔
