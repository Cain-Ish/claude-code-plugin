# second-brain v1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the second-brain plugin from 0.7.0 reflection-pipeline architecture to the v1.0 hot-tier-and-pinning model defined in `docs/specs/2026-05-01-second-brain-v1-redesign.md`.

**Architecture:** Two-tier memory: a ~700-token hot tier (USER.md + per-project PROJECT.md + index.txt active line) auto-loaded at SessionStart, and a queryable cold tier (wiki/) accessed via `knowledge_search` MCP. PROJECT.md is continuously maintained by a Stop-hook subagent gated on a 4-condition boolean diff against a SessionStart baseline. Wiki writes are explicit-only via 3 new MCP pin/archive tools. The 0.x reflection→critic→learnings pipeline is removed entirely.

**Tech Stack:** Bash 4.x, TypeScript (MCP server, `@modelcontextprotocol/sdk`), `jq` for JSONL, `ripgrep` for cold-tier search, `bats` or shell-script tests for hooks, `vitest` for MCP server tests.

**Worktree note:** The brainstorming/spec phase committed directly on `main` (commits `0a050fc`, `bae259a`). For implementation, switch to a feature branch `feat/v1.0-redesign` to keep main releasable. First task below sets this up.

---

## File Structure (decomposition lock)

**New files (created during the plan):**
- `scripts/stop-hook-predicate.sh` — runs the 4-condition boolean diff
- `scripts/run-stop-predicate.sh` — Stop-hook entry that calls the predicate and flags pending updates
- `scripts/migrate-to-1.0.0.sh` — destructive 0.7→1.0 migration (called from upgrade skill)
- `tests/test-stop-hook-predicate.sh` — shell tests for the predicate
- `mcp/src/tools/pin-to-user.ts`, `mcp/src/tools/pin-to-project.ts`, `mcp/src/tools/archive-to-wiki.ts`, `mcp/src/tools/knowledge-search.ts`
- `mcp/test/pin-to-user.test.ts`, `mcp/test/pin-to-project.test.ts`, `mcp/test/archive-to-wiki.test.ts`, `mcp/test/knowledge-search.test.ts`

**Modified files:**
- `mcp/src/server.ts` — add 3 tools, rebuild knowledge_search, remove 2 tools
- `mcp/package.json` — drop sqlite-vec / better-sqlite3, bump version
- `scripts/lib.sh` — drop reflection helpers, keep utilities
- `scripts/session-load.sh` — rewrite as hot-tier reader
- `scripts/pre-compact.sh` — call predicate
- `scripts/ensure-dirs.sh` — scaffold projects/<slug>/
- `hooks/hooks.json` — 4 hooks down from 7
- `skills/setup/SKILL.md`, `skills/status/SKILL.md`, `skills/query/SKILL.md`, `skills/lint/SKILL.md`, `skills/improve/SKILL.md`, `skills/import-host/SKILL.md`, `skills/upgrade/SKILL.md`
- `.claude-plugin/plugin.json` — version bump to 1.0.0
- `CHANGELOG.md` — 1.0.0 entry

**Deleted files (mass-delete in Task 13):**
- Scripts: `extract-learnings.sh`, `log-friction.sh`, `smart-context.sh`, `drift-detect.sh`, `post-compact.sh`, `post-maintainer.sh`, `pre-clear.sh`, `budget-context.sh`, `decay-learnings.sh`, `compile-graph.sh`, `validate-proposal.sh`
- Skills: `skills/browse/`, `skills/drift-check/`, `skills/graph/`, `skills/ingest/`, `skills/regress/`, `skills/review/`
- Agents kept: `agents/quality-reviewer.md` (used by doubt), `agents/knowledge-maintainer.md`.

---

### Task 0: Branch setup

**Files:** No file changes; git operations only.

- [ ] **Step 1: Verify clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean` (modulo `.claude/settings.local.json` which is local-only).

- [ ] **Step 2: Create feature branch from main**

```bash
git checkout -b feat/v1.0-redesign
```

- [ ] **Step 3: Confirm**

Run: `git rev-parse --abbrev-ref HEAD`
Expected: `feat/v1.0-redesign`

---

### Task 1: Stop-hook predicate (TDD)

**Files:**
- Create: `scripts/stop-hook-predicate.sh`
- Create: `tests/test-stop-hook-predicate.sh`

The predicate is the heart of the new write discipline. 4 conditions, all pure structural diffs.

- [ ] **Step 1: Write the failing test scaffold**

Create `tests/test-stop-hook-predicate.sh`:

```bash
#!/bin/bash
# Tests for scripts/stop-hook-predicate.sh
# Predicate exit codes: 0 = predicate fired (write allowed), 1 = no-op (no write)
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/stop-hook-predicate.sh"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

make_pair() {
  local baseline_content="$1" current_content="$2"
  printf '%s' "$baseline_content" > "$TMP/baseline.md"
  printf '%s' "$current_content" > "$TMP/current.md"
}
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Test 1: identical files → no-op (exit 1)
make_pair "## Goal\nx" "## Goal\nx"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" && fail "identical files should not fire"
pass "identical files: no-op"

# Test 2: Goal text differs → fires (exit 0)
make_pair "## Goal\nold" "## Goal\nnew"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" || fail "goal-diff should fire"
pass "goal differs: fires"

# Test 3: State word-count delta >20% → fires
make_pair "## State\none two three four five" "## State\none two three four five six seven eight"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" || fail "state delta should fire"
pass "state +60% words: fires"

# Test 4: State word-count delta <20% → no-op
make_pair "## State\nten words here total exactly ten words here total" "## State\nten words here total exactly ten words here today"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" && fail "state minor change should not fire"
pass "state minor change: no-op"

# Test 5: Open blockers line count differs → fires
make_pair "## Open blockers\n- [active] one" "## Open blockers\n- [active] one\n- [active] two"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" || fail "new blocker should fire"
pass "new open blocker: fires"

# Test 6: [decision] marker added → fires
make_pair "## Recent decisions\n- nothing" "## Recent decisions\n- nothing\n- [decision] picked X over Y"
"$SCRIPT" "$TMP/baseline.md" "$TMP/current.md" || fail "[decision] marker should fire"
pass "[decision] marker added: fires"

echo "ALL PASS"
```

- [ ] **Step 2: Run the test, confirm it fails (script doesn't exist yet)**

Run: `bash tests/test-stop-hook-predicate.sh`
Expected: FAIL — script not found.

- [ ] **Step 3: Implement the predicate**

Create `scripts/stop-hook-predicate.sh`:

```bash
#!/bin/bash
# Stop-hook predicate: returns exit 0 if PROJECT.md should be written, 1 if no-op.
set -u
BASELINE="${1:-}"
CURRENT="${2:-}"
[ -f "$BASELINE" ] || { echo "no baseline: $BASELINE" >&2; exit 1; }
[ -f "$CURRENT" ]  || { echo "no current: $CURRENT" >&2; exit 1; }

section() {
  local file="$1" name="$2"
  awk -v sect="^## $name\$" '
    $0 ~ sect { in_section=1; next }
    /^## / && in_section { exit }
    in_section { print }
  ' "$file"
}

# 1: Goal text differs
goal_b=$(section "$BASELINE" "Goal" | tr -d '[:space:]')
goal_c=$(section "$CURRENT"  "Goal" | tr -d '[:space:]')
if [ "$goal_b" != "$goal_c" ]; then echo "predicate: goal-changed" >&2; exit 0; fi

# 2: State word-count delta >20%
state_b=$(section "$BASELINE" "State" | wc -w | tr -d ' ')
state_c=$(section "$CURRENT"  "State" | wc -w | tr -d ' ')
state_b=${state_b:-0}; state_c=${state_c:-0}
if [ "$state_b" -gt 0 ]; then
  delta=$(( (state_c - state_b) * 100 / state_b )); delta=${delta#-}
  if [ "$delta" -gt 20 ]; then echo "predicate: state-delta-${delta}pct" >&2; exit 0; fi
elif [ "$state_c" -gt 0 ]; then
  echo "predicate: state-from-empty" >&2; exit 0
fi

# 3: Open blockers line count differs
ob_b=$(section "$BASELINE" "Open blockers" | grep -c '^- ' || true)
ob_c=$(section "$CURRENT"  "Open blockers" | grep -c '^- ' || true)
if [ "$ob_b" != "$ob_c" ]; then echo "predicate: blocker-count-changed ($ob_b->$ob_c)" >&2; exit 0; fi

# 4: [decision] marker added
b_dec=$(grep -c '\[decision\]' "$BASELINE" || true)
c_dec=$(grep -c '\[decision\]' "$CURRENT" || true)
if [ "$c_dec" -gt "$b_dec" ]; then echo "predicate: decision-added" >&2; exit 0; fi

exit 1
```

Make executable:
```bash
chmod +x scripts/stop-hook-predicate.sh tests/test-stop-hook-predicate.sh
```

- [ ] **Step 4: Run the test, confirm pass**

Run: `bash tests/test-stop-hook-predicate.sh`
Expected: 6 PASS lines + `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/stop-hook-predicate.sh tests/test-stop-hook-predicate.sh
git commit -m "feat(v1.0): add stop-hook predicate with 4-condition boolean diff"
```

---

### Task 2: lib.sh trim

**Files:** Modify: `scripts/lib.sh`

**Keep:** `sb_require_jq`, `sb_safe_json_array`, `sb_log_error`, `sb_parse_input`, file-locking primitives, `BRAIN_DIR` env setup.
**Remove:** `sb_count_friction`, `sb_count_drift`, `sb_calc_priority`, `sb_check_auto_improve`, `sb_collect_session_data`, `sb_write_reflection`, `sb_write_session_meta`, `sb_snapshot_transcript`, `sb_migrate_reflection`, `sb_count_user_turns`, `sb_resolve_transcript`, `sb_context_pressure`.

- [ ] **Step 1: Read current lib.sh symbols**

```bash
wc -l scripts/lib.sh
grep -n '^sb_\|^[A-Z_]*=' scripts/lib.sh
```

- [ ] **Step 2: Write trimmed lib.sh**

Open the file, delete every function in the "Remove" list above (use `sed -i` ranges or manual edit). Keep the file header, `BRAIN_DIR` resolution, and the kept helpers verbatim. Target ~80-100 lines.

- [ ] **Step 3: Verify scripts still parse**

```bash
for s in scripts/*.sh; do bash -n "$s" || echo "PARSE ERROR: $s"; done
```
Expected: scripts slated for deletion in Task 13 may show parse errors due to missing helpers — that's fine, they're going away. Scripts that survive (`session-load.sh`, `ensure-dirs.sh`, `validate-plugin.sh`, `quality-gate.sh`, `discover-tools.sh`) must parse cleanly.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib.sh
git commit -m "refactor(v1.0): trim lib.sh — remove reflection pipeline helpers"
```

---

### Task 3: session-load.sh rewrite (hot-tier reader)

**Files:** Modify: `scripts/session-load.sh`

- [ ] **Step 1: Replace session-load.sh**

```bash
#!/bin/bash
# v1.0 hot-tier loader. Outputs USER.md + active PROJECT.md + active index line.
# Captures SessionStart baseline for Stop-hook predicate.
source "$(dirname "$0")/lib.sh"

USER_FILE="$BRAIN_DIR/USER.md"
INDEX_FILE="$BRAIN_DIR/index.txt"
PROJECTS_DIR="$BRAIN_DIR/projects"
LINE_CAP=66   # ~800 tokens / 12 tokens-per-line

slug=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")
project_file="$PROJECTS_DIR/$slug/PROJECT.md"

[ -f "$project_file" ] && cp "$project_file" "$BRAIN_DIR/.session-baseline-$slug.md"

[ -f "$USER_FILE" ] && cat "$USER_FILE"
if [ -f "$project_file" ]; then echo; cat "$project_file"; fi
if [ -f "$INDEX_FILE" ]; then
  echo
  jq --arg s "$slug" -r 'select(.slug == $s)' "$INDEX_FILE" 2>/dev/null | head -1
fi

TOTAL_LINES=$(( $(wc -l < "$USER_FILE" 2>/dev/null || echo 0) + $(wc -l < "$project_file" 2>/dev/null || echo 0) + 1 ))
if [ "$TOTAL_LINES" -gt "$LINE_CAP" ]; then
  sb_log_error "session-load.sh" "hot-tier exceeded line cap: $TOTAL_LINES > $LINE_CAP" 0
fi

exit 0
```

- [ ] **Step 2: Smoke test with fixtures**

```bash
mkdir -p ~/.second-brain/projects/test-project
cat > ~/.second-brain/projects/test-project/PROJECT.md <<'EOF'
# PROJECT: test
## Goal
test goal
## State
test state
EOF
cat > ~/.second-brain/USER.md <<'EOF'
# USER preferences
test pref
EOF
cd /tmp && mkdir -p test-project && cd test-project && git init -q
PWD=$(pwd) bash $OLDPWD/scripts/session-load.sh
```
Expected: USER.md + PROJECT.md content printed; baseline file at `~/.second-brain/.session-baseline-test-project.md` created.

- [ ] **Step 3: Cleanup fixtures**

```bash
rm -rf ~/.second-brain/projects/test-project ~/.second-brain/.session-baseline-test-project.md /tmp/test-project
```

- [ ] **Step 4: Commit**

```bash
git add scripts/session-load.sh
git commit -m "feat(v1.0): rewrite session-load.sh as hot-tier reader with baseline capture"
```

---

### Task 4: ensure-dirs.sh — v1.0 scaffold

**Files:** Modify: `scripts/ensure-dirs.sh`

- [ ] **Step 1: Replace ensure-dirs.sh**

```bash
#!/bin/bash
source "$(dirname "$0")/lib.sh"
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

mkdir -p "$BRAIN_DIR/projects"
mkdir -p "$BRAIN_DIR/regressions"
mkdir -p "$KNOWLEDGE_DIR/wiki"/{concepts,decisions,issues,entities,learnings}
exit 0
```

- [ ] **Step 2: Run idempotently**

```bash
bash scripts/ensure-dirs.sh
bash scripts/ensure-dirs.sh
ls -la ~/.second-brain/projects ~/.second-brain/regressions
ls -la ~/knowledge/wiki/
```
Expected: directories exist; second run is silent.

- [ ] **Step 3: Commit**

```bash
git add scripts/ensure-dirs.sh
git commit -m "feat(v1.0): simplify ensure-dirs.sh to v1.0 directory layout"
```

---

### Task 5: MCP `pin_to_user` (TDD)

**Files:**
- Create: `mcp/src/tools/pin-to-user.ts`
- Create: `mcp/test/pin-to-user.test.ts`
- Modify: `mcp/src/server.ts`

- [ ] **Step 1: Write failing test**

```typescript
// mcp/test/pin-to-user.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { pinToUser } from '../src/tools/pin-to-user.js';

describe('pin_to_user', () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'pin-test-')); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it('appends a line to USER.md', async () => {
    writeFileSync(join(dir, 'USER.md'), '# USER\n## Preferences\n', 'utf-8');
    const res = await pinToUser({ text: 'prefer terse responses', brainDir: dir });
    expect(res.ok).toBe(true);
    expect(res.line_added).toMatch(/prefer terse responses/);
    expect(readFileSync(join(dir, 'USER.md'), 'utf-8')).toContain('prefer terse responses');
  });

  it('creates USER.md with header if it does not exist', async () => {
    const res = await pinToUser({ text: 'first pin', brainDir: dir });
    expect(res.ok).toBe(true);
    expect(readFileSync(join(dir, 'USER.md'), 'utf-8')).toMatch(/^# USER/m);
  });

  it('rejects writes that would push USER.md over 30 lines', async () => {
    const lines = Array.from({ length: 30 }, (_, i) => `line ${i}`).join('\n');
    writeFileSync(join(dir, 'USER.md'), `# USER\n${lines}`, 'utf-8');
    const res = await pinToUser({ text: 'one too many', brainDir: dir });
    expect(res.ok).toBe(false);
  });
});
```

- [ ] **Step 2: Run test, confirm fail**

`cd mcp && npx vitest run test/pin-to-user.test.ts` → FAIL (module missing).

- [ ] **Step 3: Implement**

```typescript
// mcp/src/tools/pin-to-user.ts
import { promises as fs } from 'fs';
import { join } from 'path';

const MAX_LINES = 30;

export interface PinToUserArgs { text: string; brainDir?: string; }
export interface PinToUserResult { ok: boolean; line_added: string; reason?: string; }

export async function pinToUser(args: PinToUserArgs): Promise<PinToUserResult> {
  const dir = args.brainDir ?? join(process.env.HOME ?? '', '.second-brain');
  const file = join(dir, 'USER.md');
  const date = new Date().toISOString().slice(0, 10);
  const newLine = `- [${date}] ${args.text.trim()}`;

  let content = '';
  try { content = await fs.readFile(file, 'utf-8'); }
  catch { content = '# USER preferences\n\n## Pinned\n'; }

  const projected = content + (content.endsWith('\n') ? '' : '\n') + newLine + '\n';
  if (projected.split('\n').filter(Boolean).length > MAX_LINES) {
    return { ok: false, line_added: '', reason: `would exceed ${MAX_LINES}-line cap` };
  }
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(file, projected, 'utf-8');
  return { ok: true, line_added: newLine };
}
```

- [ ] **Step 4: Run test, confirm 3 passing**

`cd mcp && npx vitest run test/pin-to-user.test.ts` → 3 PASS.

- [ ] **Step 5: Wire into server.ts**

Add after `knowledge_search` registration:

```typescript
import { pinToUser } from './tools/pin-to-user.js';
server.registerTool(
  'pin_to_user',
  {
    description: "Pin a preference to USER.md. Use only when the user explicitly says 'pin to my second-brain' or runs /second-brain:pin. Plain 'remember this' should write to Claude Code's built-in auto-memory, not here.",
    inputSchema: { text: z.string() },
  },
  async ({ text }) => {
    const result = await pinToUser({ text });
    return { content: [{ type: 'text', text: JSON.stringify(result) }] };
  }
);
```

- [ ] **Step 6: Commit**

```bash
git add mcp/src/tools/pin-to-user.ts mcp/test/pin-to-user.test.ts mcp/src/server.ts
git commit -m "feat(mcp): add pin_to_user tool"
```

---

### Task 6: MCP `pin_to_project` (TDD)

**Files:** Create `mcp/src/tools/pin-to-project.ts` + `mcp/test/pin-to-project.test.ts`; modify `mcp/src/server.ts`.

- [ ] **Step 1: Write failing test**

```typescript
// mcp/test/pin-to-project.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { pinToProject } from '../src/tools/pin-to-project.js';

const tpl = `# PROJECT: test
## Goal
do thing
## State
in progress
## Conventions
none
## Recent decisions
- nothing
## Open blockers

## Cross-references

`;

describe('pin_to_project', () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'pin-proj-'));
    mkdirSync(join(dir, 'projects', 'test-slug'), { recursive: true });
    writeFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), tpl, 'utf-8');
  });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it('appends [active] blocker', async () => {
    const res = await pinToProject({ text: 'API rate limit', slug: 'test-slug', section: 'blockers', brainDir: dir });
    expect(res.ok).toBe(true);
    const content = readFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    expect(content).toMatch(/## Open blockers\s*\n- \[active\] API rate limit/);
  });

  it('appends [decision] entry', async () => {
    const res = await pinToProject({ text: 'picked SQLite over Postgres', slug: 'test-slug', section: 'decisions', brainDir: dir });
    expect(res.ok).toBe(true);
    const content = readFileSync(join(dir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    expect(content).toMatch(/\[decision\] picked SQLite over Postgres/);
  });

  it('rejects unknown section', async () => {
    const res = await pinToProject({ text: 'x', slug: 'test-slug', section: 'goal' as any, brainDir: dir });
    expect(res.ok).toBe(false);
  });
});
```

- [ ] **Step 2: Run test, confirm fail.**

- [ ] **Step 3: Implement**

```typescript
// mcp/src/tools/pin-to-project.ts
import { promises as fs } from 'fs';
import { join } from 'path';

export type PinSection = 'blockers' | 'decisions';
export interface PinToProjectArgs { text: string; slug: string; section: PinSection; brainDir?: string; }
export interface PinToProjectResult { ok: boolean; line_added: string; project_slug: string; reason?: string; }

const SECTION_HEADER = { blockers: '## Open blockers', decisions: '## Recent decisions' } as const;
const ENTRY_PREFIX  = { blockers: '- [active] ',       decisions: '- [decision] ' } as const;

export async function pinToProject(args: PinToProjectArgs): Promise<PinToProjectResult> {
  if (!(args.section in SECTION_HEADER)) {
    return { ok: false, line_added: '', project_slug: args.slug, reason: 'unknown section' };
  }
  const dir = args.brainDir ?? join(process.env.HOME ?? '', '.second-brain');
  const file = join(dir, 'projects', args.slug, 'PROJECT.md');
  const content = await fs.readFile(file, 'utf-8');
  const sectionHeader = SECTION_HEADER[args.section];
  const newEntry = `${ENTRY_PREFIX[args.section]}${args.text.trim()}`;
  const lines = content.split('\n');
  const idx = lines.findIndex(line => line.trim() === sectionHeader);
  if (idx < 0) {
    return { ok: false, line_added: '', project_slug: args.slug, reason: `section ${sectionHeader} not found` };
  }
  let endIdx = lines.length;
  for (let i = idx + 1; i < lines.length; i++) { if (lines[i].startsWith('## ')) { endIdx = i; break; } }
  while (endIdx > idx + 1 && lines[endIdx - 1].trim() === '') endIdx--;
  lines.splice(endIdx, 0, newEntry);
  await fs.writeFile(file, lines.join('\n'), 'utf-8');
  return { ok: true, line_added: newEntry, project_slug: args.slug };
}
```

- [ ] **Step 4: Run tests, confirm 3 pass.**

- [ ] **Step 5: Wire into server.ts**

```typescript
import { pinToProject } from './tools/pin-to-project.js';
server.registerTool(
  'pin_to_project',
  {
    description: "Append an entry to the active project's PROJECT.md. Section must be 'blockers' or 'decisions'.",
    inputSchema: {
      text: z.string(),
      slug: z.string(),
      section: z.enum(['blockers', 'decisions']),
    },
  },
  async ({ text, slug, section }) => {
    const result = await pinToProject({ text, slug, section });
    return { content: [{ type: 'text', text: JSON.stringify(result) }] };
  }
);
```

- [ ] **Step 6: Commit**

```bash
git add mcp/src/tools/pin-to-project.ts mcp/test/pin-to-project.test.ts mcp/src/server.ts
git commit -m "feat(mcp): add pin_to_project tool"
```

---

### Task 7: MCP `archive_to_wiki` (TDD)

**Files:** Create `mcp/src/tools/archive-to-wiki.ts` + `mcp/test/archive-to-wiki.test.ts`; modify `mcp/src/server.ts`.

- [ ] **Step 1: Write failing test**

```typescript
// mcp/test/archive-to-wiki.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { archiveToWiki } from '../src/tools/archive-to-wiki.js';

const tpl = `# PROJECT: test
## Open blockers
- [resolved] flaky test in module X
- [active] still working on Y
`;

describe('archive_to_wiki', () => {
  let brainDir: string, knowledgeDir: string;
  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'arch-b-'));
    knowledgeDir = mkdtempSync(join(tmpdir(), 'arch-k-'));
    mkdirSync(join(brainDir, 'projects', 'test-slug'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'test-slug', 'PROJECT.md'), tpl, 'utf-8');
  });
  afterEach(() => {
    rmSync(brainDir, { recursive: true, force: true });
    rmSync(knowledgeDir, { recursive: true, force: true });
  });

  it('moves resolved blocker to wiki/issues/<slug>/ with back-ref', async () => {
    const res = await archiveToWiki({
      slug: 'test-slug', sourceSection: 'blockers',
      entryText: 'flaky test in module X', targetCategory: 'issues',
      brainDir, knowledgeDir,
    });
    expect(res.ok).toBe(true);
    expect(existsSync(res.archived_path)).toBe(true);
    const content = readFileSync(join(brainDir, 'projects', 'test-slug', 'PROJECT.md'), 'utf-8');
    expect(content).toMatch(/→ wiki\/issues\/test-slug\//);
    expect(content).not.toContain('[resolved] flaky test in module X');
    expect(content).toContain('[active] still working on Y');
  });
});
```

- [ ] **Step 2: Run test, confirm fail.**

- [ ] **Step 3: Implement**

```typescript
// mcp/src/tools/archive-to-wiki.ts
import { promises as fs } from 'fs';
import { join } from 'path';

export type SourceSection = 'blockers' | 'decisions';
export type TargetCategory = 'issues' | 'decisions';
export interface ArchiveToWikiArgs {
  slug: string; sourceSection: SourceSection; entryText: string;
  targetCategory: TargetCategory; brainDir?: string; knowledgeDir?: string;
}
export interface ArchiveToWikiResult { ok: boolean; archived_path: string; reason?: string; }

export async function archiveToWiki(args: ArchiveToWikiArgs): Promise<ArchiveToWikiResult> {
  const brainDir = args.brainDir ?? join(process.env.HOME ?? '', '.second-brain');
  const knowledgeDir = args.knowledgeDir ?? join(process.env.HOME ?? '', 'knowledge');
  const projectFile = join(brainDir, 'projects', args.slug, 'PROJECT.md');
  const wikiDir = join(knowledgeDir, 'wiki', args.targetCategory, args.slug);
  await fs.mkdir(wikiDir, { recursive: true });

  const content = await fs.readFile(projectFile, 'utf-8');
  const lines = content.split('\n');
  const matchIdx = lines.findIndex(l => l.includes(args.entryText) && l.includes('[resolved]'));
  if (matchIdx < 0) {
    return { ok: false, archived_path: '', reason: 'no [resolved] entry matching text' };
  }
  const date = new Date().toISOString().slice(0, 10);
  const slugSafe = args.entryText.toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, 40);
  const archivePath = join(wikiDir, `${date}-${slugSafe}.md`);
  await fs.writeFile(archivePath,
    `# ${args.entryText}\n\n**Archived:** ${date}\n**From:** projects/${args.slug}/PROJECT.md (section: ${args.sourceSection})\n**Status:** resolved\n`,
    'utf-8'
  );
  lines[matchIdx] = `  → wiki/${args.targetCategory}/${args.slug}/${date}-${slugSafe}.md`;
  await fs.writeFile(projectFile, lines.join('\n'), 'utf-8');
  return { ok: true, archived_path: archivePath };
}
```

- [ ] **Step 4: Run test, confirm 1 passing.**

- [ ] **Step 5: Wire into server.ts**

```typescript
import { archiveToWiki } from './tools/archive-to-wiki.js';
server.registerTool(
  'archive_to_wiki',
  {
    description: 'Archive a [resolved] entry from PROJECT.md to ~/knowledge/wiki/<category>/<slug>/. Leaves a back-reference line in PROJECT.md.',
    inputSchema: {
      slug: z.string(),
      sourceSection: z.enum(['blockers', 'decisions']),
      entryText: z.string(),
      targetCategory: z.enum(['issues', 'decisions']),
    },
  },
  async (input) => {
    const result = await archiveToWiki(input);
    return { content: [{ type: 'text', text: JSON.stringify(result) }] };
  }
);
```

- [ ] **Step 6: Commit**

```bash
git add mcp/src/tools/archive-to-wiki.ts mcp/test/archive-to-wiki.test.ts mcp/src/server.ts
git commit -m "feat(mcp): add archive_to_wiki tool"
```

---

### Task 8: Rebuild `knowledge_search` with ripgrep backend (TDD)

**Files:** Create `mcp/src/tools/knowledge-search.ts` + `mcp/test/knowledge-search.test.ts`; modify `mcp/src/server.ts`.

- [ ] **Step 1: Write failing test**

```typescript
// mcp/test/knowledge-search.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeSearch } from '../src/tools/knowledge-search.js';

describe('knowledge_search v1', () => {
  let knowledgeDir: string;
  beforeEach(() => {
    knowledgeDir = mkdtempSync(join(tmpdir(), 'ks-'));
    mkdirSync(join(knowledgeDir, 'wiki', 'concepts'), { recursive: true });
    mkdirSync(join(knowledgeDir, 'wiki', 'learnings'), { recursive: true });
    writeFileSync(
      join(knowledgeDir, 'wiki', 'learnings', '2026-04-29-counting-pipeline.md'),
      `# Counting pipeline fallback gotcha\n\nDate: 2026-04-29\n\nUsing grep -c with || echo 0 corrupts...\n`,
      'utf-8'
    );
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'shell-patterns.md'),
      `# Shell patterns\n\nGeneral shell-script idioms.\n`,
      'utf-8'
    );
  });
  afterEach(() => { rmSync(knowledgeDir, { recursive: true, force: true }); });

  it('returns top candidates ranked by token overlap', async () => {
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
    expect(res.candidates.length).toBeGreaterThan(0);
    expect(res.candidates[0].path).toMatch(/counting-pipeline\.md$/);
  });

  it('respects scope filter', async () => {
    const res = await knowledgeSearch({ query: 'shell', scope: 'concepts', knowledgeDir });
    expect(res.candidates.every(c => c.path.includes('/concepts/'))).toBe(true);
  });

  it('returns empty candidates on no match', async () => {
    const res = await knowledgeSearch({ query: 'unrelatedstring1234', knowledgeDir });
    expect(res.candidates).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test, confirm fail.**

- [ ] **Step 3: Implement**

```typescript
// mcp/src/tools/knowledge-search.ts
import { promises as fs } from 'fs';
import { join } from 'path';

export type Scope = 'concepts' | 'issues' | 'entities' | 'learnings' | 'decisions';
export interface KnowledgeSearchArgs { query: string; scope?: Scope; knowledgeDir?: string; }
export interface KnowledgeSearchResult { candidates: { path: string; score: number; first_lines: string }[]; }

const SNIPPET_CHARS = 200;
const TOP_K = 5;
const FIRST_N_LINES = 10;

export async function knowledgeSearch(args: KnowledgeSearchArgs): Promise<KnowledgeSearchResult> {
  const knowledgeDir = args.knowledgeDir ?? join(process.env.HOME ?? '', 'knowledge');
  const wikiRoot = join(knowledgeDir, 'wiki');
  const scopeDirs = args.scope
    ? [join(wikiRoot, args.scope)]
    : (['concepts','issues','entities','learnings','decisions'] as Scope[]).map(s => join(wikiRoot, s));

  const queryTokens = tokenize(args.query);
  const candidates: KnowledgeSearchResult['candidates'] = [];

  for (const dir of scopeDirs) {
    let entries: string[] = [];
    try { entries = await collectMarkdown(dir); } catch { continue; }
    for (const path of entries) {
      const head = await firstLines(path, FIRST_N_LINES);
      const score = scoreTokens(queryTokens, head + ' ' + path);
      if (score > 0) candidates.push({ path, score, first_lines: head.slice(0, SNIPPET_CHARS) });
    }
  }
  candidates.sort((a, b) => b.score - a.score);
  return { candidates: candidates.slice(0, TOP_K) };
}

function tokenize(s: string): string[] { return s.toLowerCase().match(/[a-z0-9]+/g) ?? []; }
function scoreTokens(query: string[], text: string): number {
  const t = new Set(tokenize(text));
  return query.filter(q => t.has(q)).length;
}
async function collectMarkdown(dir: string, acc: string[] = []): Promise<string[]> {
  for (const e of await fs.readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) await collectMarkdown(p, acc);
    else if (e.isFile() && e.name.endsWith('.md')) acc.push(p);
  }
  return acc;
}
async function firstLines(path: string, n: number): Promise<string> {
  const content = await fs.readFile(path, 'utf-8');
  return content.split('\n').slice(0, n).join('\n');
}
```

- [ ] **Step 4: Run test, confirm 3 passing.**

- [ ] **Step 5: Replace existing `knowledge_search` registration in server.ts**

Find the existing `server.registerTool("knowledge_search", ...)` block at line 134. Replace its handler with a call to the new `knowledgeSearch` function. Remove sqlite-vec / better-sqlite3 imports. Keep input shape.

- [ ] **Step 6: Commit**

```bash
git add mcp/src/tools/knowledge-search.ts mcp/test/knowledge-search.test.ts mcp/src/server.ts
git commit -m "feat(mcp): rebuild knowledge_search with ripgrep backend (no embeddings)"
```

---

### Task 9: Remove `knowledge_index` and `knowledge_feedback`

**Files:** Modify `mcp/src/server.ts`, `mcp/package.json`.

- [ ] **Step 1: Delete the registrations**

In `mcp/src/server.ts`, delete the blocks at lines ~258 (`knowledge_index`) and ~363 (`knowledge_feedback`). Remove sqlite-vec / better-sqlite3 imports and any helpers used only by those tools.

- [ ] **Step 2: Update package.json**

Remove from `dependencies`: `better-sqlite3`, `sqlite-vec`, any embedding library.

```bash
cd mcp && npm install
```

- [ ] **Step 3: Verify no remaining callers**

```bash
grep -rn 'knowledge_index\|knowledge_feedback\|updateLearningFeedback' . --include='*.md' --include='*.sh' --include='*.ts' --exclude-dir=node_modules
```
Expected: only spec/CHANGELOG references. If any skill/script still calls them, update or remove.

- [ ] **Step 4: All MCP tests pass**

```bash
cd mcp && npx vitest run
```

- [ ] **Step 5: Commit**

```bash
git add mcp/src/server.ts mcp/package.json mcp/package-lock.json
git commit -m "feat(mcp): remove knowledge_index and knowledge_feedback tools (v1.0)"
```

---

### Task 10: Bump MCP server version

**Files:** Modify `mcp/src/server.ts`, `mcp/package.json`.

- [ ] **Step 1: Update version strings**

In `mcp/src/server.ts` line ~28: `version: "0.2.0"` → `version: "1.0.0"`.
In `mcp/package.json`: same bump.

- [ ] **Step 2: Rebuild**

```bash
cd mcp && npm run build
```

- [ ] **Step 3: Commit**

```bash
git add mcp/src/server.ts mcp/package.json mcp/dist/server.js
git commit -m "chore(mcp): bump server version to 1.0.0"
```

---

### Task 11: hooks.json — v1.0 layout (4 events)

**Files:** Modify `hooks/hooks.json`.

- [ ] **Step 1: Replace hooks.json**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/ensure-dirs.sh", "timeout": 5 },
          { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/discover-tools.sh", "timeout": 10 },
          { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/session-load.sh", "timeout": 15 }
        ]
      }
    ],
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-stop-predicate.sh", "timeout": 30 }
      ]}
    ],
    "PreCompact": [
      { "hooks": [
        { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/pre-compact.sh", "timeout": 30 }
      ]}
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit", "hooks": [
        { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/quality-gate.sh", "timeout": 5 }
      ]}
    ]
  }
}
```

- [ ] **Step 2: Validate JSON**

```bash
jq . hooks/hooks.json
```

- [ ] **Step 3: Run plugin validator**

```bash
bash scripts/validate-plugin.sh
```
Expected: `OK: all plugin files valid` (the two cosmetic WARNs about Stop[0]/UserPromptSubmit[0] matchers should now be gone).

- [ ] **Step 4: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat(v1.0): hooks.json — 4 events (was 7)"
```

---

### Task 12: Stop-hook wrapper

**Files:** Create `scripts/run-stop-predicate.sh`.

- [ ] **Step 1: Implement**

```bash
#!/bin/bash
# Stop-hook entry. Invokes predicate, flags pending update on fire.
source "$(dirname "$0")/lib.sh"

slug=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")
baseline="$BRAIN_DIR/.session-baseline-$slug.md"
current="$BRAIN_DIR/projects/$slug/PROJECT.md"

if [ ! -f "$baseline" ] || [ ! -f "$current" ]; then exit 0; fi

if bash "$(dirname "$0")/stop-hook-predicate.sh" "$baseline" "$current"; then
  echo "predicate-fired" > "$BRAIN_DIR/.project-update-pending-$slug"
fi
rm -f "$baseline"
exit 0
```

(Note: actual PROJECT.md update happens via Claude reading the `.project-update-pending-<slug>` flag in the next session — bash hooks can't invoke subagents directly. This is the v1.0 design's documented mechanism.)

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/run-stop-predicate.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/run-stop-predicate.sh
git commit -m "feat(v1.0): add stop-hook wrapper that invokes predicate + flags pending update"
```

---

### Task 13: Mass-delete dropped scripts and skills

**Files:**
- Delete (scripts): `extract-learnings.sh`, `log-friction.sh`, `smart-context.sh`, `drift-detect.sh`, `post-compact.sh`, `post-maintainer.sh`, `pre-clear.sh`, `budget-context.sh`, `decay-learnings.sh`, `compile-graph.sh`, `validate-proposal.sh`
- Delete (skills): `skills/browse/`, `skills/drift-check/`, `skills/graph/`, `skills/ingest/`, `skills/regress/`, `skills/review/`

- [ ] **Step 1: Remove scripts**

```bash
git rm scripts/extract-learnings.sh scripts/log-friction.sh scripts/smart-context.sh scripts/drift-detect.sh scripts/post-compact.sh scripts/post-maintainer.sh scripts/pre-clear.sh scripts/budget-context.sh scripts/decay-learnings.sh scripts/compile-graph.sh scripts/validate-proposal.sh
```

- [ ] **Step 2: Remove skills**

```bash
git rm -r skills/browse skills/drift-check skills/graph skills/ingest skills/regress skills/review
```

- [ ] **Step 3: Validator passes**

```bash
bash scripts/validate-plugin.sh
```

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(v1.0): drop reflection-pipeline scripts and 6 retired skills"
```

---

### Task 14: Rewrite `setup` skill (scaffold v1.0 hot tier)

**Files:** Modify `skills/setup/SKILL.md`.

- [ ] **Step 1: Replace SKILL.md** with the body below (≤300 lines per the user's saved skill-size feedback rule):

```markdown
---
name: setup
description: Scaffold the v1.0 hot tier — USER.md, projects/<slug>/PROJECT.md, index.txt — for the active repo. Idempotent.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Write Edit Bash(git rev-parse:*) Bash(basename *) Bash(date *) Bash(test *) Bash(jq *) Bash(mkdir *)
---

# Setup

Scaffold the second-brain v1.0 hot tier for the active repo.

## Steps

### 1. Resolve active project

```bash
SLUG=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
NAME="$SLUG"
echo "Active project: $SLUG"
```

### 2. Scaffold USER.md

If `~/.second-brain/USER.md` does not exist, prompt user for ≤15 lines of preferences. If they have an existing `persona.md`, offer to condense it interactively.

### 3. Scaffold PROJECT.md

Create `~/.second-brain/projects/$SLUG/PROJECT.md` with the 6-section template if missing. Prompt for `Goal` (≤3 lines) and `Conventions` (≤5 lines).

### 4. Update index.txt

```bash
jq -n --arg s "$SLUG" --arg n "$NAME" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}' \
  >> ~/.second-brain/index.txt
```

### 5. Confirm

Print byte counts of USER.md + PROJECT.md and verify combined < ~3200 bytes (≈ 800-token cap).
```

- [ ] **Step 2: Smoke test**

Run `/second-brain:setup` in a scratch repo. Verify files scaffolded, index.txt entry appended.

- [ ] **Step 3: Commit**

```bash
git add skills/setup/SKILL.md
git commit -m "feat(v1.0): rewrite setup skill for hot-tier scaffolding"
```

---

### Task 15: Rebuild `improve` skill (3-pin proposal flow)

**Files:** Modify `skills/improve/SKILL.md`.

- [ ] **Step 1: Replace SKILL.md** (≤300 lines):

```markdown
---
name: improve
description: Manual deep-dive on the current/most-recent session. Proposes up to 3 grounded "pin" candidates the user can accept/reject/edit. No autonomous critic.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(git log:*) Bash(jq *) Bash(date *) WebSearch mcp__knowledge-base__knowledge_search mcp__knowledge-base__pin_to_user mcp__knowledge-base__pin_to_project mcp__knowledge-base__archive_to_wiki
---

# Improve

Generate up to 3 candidate "pins" from this session and let the user accept/reject/edit each.

## Steps

### 1. Collect signals

Read session activity since SessionStart. Identify:
- Explicit user feedback ("don't do X" / "always Y") → candidate for USER.md or PROJECT.md Conventions
- Decisions explicitly stated ("we picked X over Y because...") → candidate for PROJECT.md Recent decisions
- Blockers added or resolved → candidate for PROJECT.md Open blockers or archive_to_wiki

### 2. Filter

For each candidate, ask: "Would the user want to remember this in 2 weeks?" If no, drop. Keep at most 3 candidates.

### 3. Present each candidate

For each surviving candidate, show:
- Proposed text
- Destination (USER.md / PROJECT.md:section / wiki/<category>/)
- Single Y/N/edit prompt

### 4. Apply accepted

For each accepted candidate, call the appropriate MCP tool: `pin_to_user`, `pin_to_project`, or `archive_to_wiki`. For wiki entries that don't fit the pin tools, write directly via `Write` tool.

### 5. Done

Report what was pinned. No critic-log, no decay tracking, no auto-extraction.
```

- [ ] **Step 2: Commit**

```bash
git add skills/improve/SKILL.md
git commit -m "feat(v1.0): rebuild improve skill — 3-pin proposal flow, no autonomous critic"
```

---

### Task 16: Update remaining skills (`status`, `query`, `lint`, `import-host`)

**Files:** Modify `skills/status/SKILL.md`, `skills/query/SKILL.md`, `skills/lint/SKILL.md`, `skills/import-host/SKILL.md`.

- [ ] **Step 1: Update each SKILL.md to v1.0 surface**

- **status:** report USER.md size, active PROJECT.md size, index.txt project count, wiki page counts per category. Drop reflection-pipeline metrics.
- **query:** thin wrapper invoking `knowledge_search` with optional `scope`. Returns `candidates` array; let Claude synthesize.
- **lint:** orphan check (wiki pages with no inbound link), dead wiki-link check, broken `Cross-references:` slugs in PROJECT.md files. Drop content rules.
- **import-host:** read CLAUDE.md / .cursorrules / etc. from cwd, propose USER.md and PROJECT.md content, prompt to confirm each.

Each `allowed-tools` list must be updated to drop tools that no longer exist (`knowledge_index`, `knowledge_feedback`).

- [ ] **Step 2: Commit per skill**

```bash
git add skills/status/SKILL.md && git commit -m "feat(v1.0): update status skill for hot-tier metrics"
git add skills/query/SKILL.md && git commit -m "feat(v1.0): simplify query skill as knowledge_search wrapper"
git add skills/lint/SKILL.md && git commit -m "feat(v1.0): trim lint skill to orphan + dead-link checks"
git add skills/import-host/SKILL.md && git commit -m "feat(v1.0): update import-host for USER.md/PROJECT.md targets"
```

---

### Task 17: Add 1.0.0 migration row to `upgrade` skill

**Files:** Modify `skills/upgrade/SKILL.md`; create `scripts/migrate-to-1.0.0.sh`.

- [ ] **Step 1: Append migration table row**

In `skills/upgrade/SKILL.md` migration table:

```markdown
| **1.0.0** | Wipe reflection runtime (`.pending-reflections.jsonl`, `.reflection-context/`, `.learnings-hot.md`, `.compact-count`, `friction-log.jsonl`, `drift-log.jsonl`, `error-log.jsonl`, `critic-log.jsonl`, `doubt-history.jsonl`). Backup all to `~/.second-brain/.0.7.0-backup/<ISO>/`. Reset `learnings.md` to header-only. Condense `persona.md` (90 lines) → USER.md (≤15 lines) interactively. Scaffold first PROJECT.md from current repo. Keep curated wiki pages untouched. | If `cat ~/.second-brain/.installed-version` returns `1.0.0`, no-op. Otherwise run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/migrate-to-1.0.0.sh`. |
```

- [ ] **Step 2: Implement migration script**

Create `scripts/migrate-to-1.0.0.sh`:

```bash
#!/bin/bash
set -u
BRAIN="$HOME/.second-brain"
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$BRAIN/.0.7.0-backup/$TS"

INSTALLED=$(cat "$BRAIN/.installed-version" 2>/dev/null || echo "0.0.0")
if [ "$INSTALLED" = "1.0.0" ]; then echo "already 1.0.0; no-op"; exit 0; fi

mkdir -p "$BACKUP"
for f in .pending-reflections.jsonl .learnings-hot.md .compact-count \
         friction-log.jsonl drift-log.jsonl error-log.jsonl \
         critic-log.jsonl doubt-history.jsonl; do
  [ -e "$BRAIN/$f" ] && mv "$BRAIN/$f" "$BACKUP/"
done
[ -d "$BRAIN/.reflection-context" ] && mv "$BRAIN/.reflection-context" "$BACKUP/"

cat > "$BRAIN/learnings.md" <<'EOF'
# Learned Patterns

Strategic principles distilled from coding sessions. Read at session start.
Each entry captures what worked, what failed, and actionable guidance.
EOF

echo "Backup at: $BACKUP"
echo "Persona condensation runs in upgrade skill (interactive)."
echo "1.0.0 migration runtime steps complete."
```

- [ ] **Step 3: Commit**

```bash
chmod +x scripts/migrate-to-1.0.0.sh
git add skills/upgrade/SKILL.md scripts/migrate-to-1.0.0.sh
git commit -m "feat(v1.0): add 1.0.0 migration row + migrate-to-1.0.0 script"
```

---

### Task 18: Bump plugin.json + CHANGELOG

**Files:** Modify `.claude-plugin/plugin.json`, `CHANGELOG.md`.

- [ ] **Step 1: Bump version**

In `.claude-plugin/plugin.json`: `"version": "0.7.0"` → `"version": "1.0.0"`.

- [ ] **Step 2: Add CHANGELOG entry** at top:

```markdown
## [1.0.0] - 2026-05-01

Major redesign — reflection→critic→learnings pipeline removed; replaced with hot-tier (USER.md + PROJECT.md) auto-load and explicit pin/archive MCP tools. See `docs/specs/2026-05-01-second-brain-v1-redesign.md` and `docs/plans/2026-05-01-second-brain-v1.0-implementation.md`.

### Removed
- 11 scripts: `extract-learnings.sh`, `log-friction.sh`, `smart-context.sh`, `drift-detect.sh`, `post-compact.sh`, `post-maintainer.sh`, `pre-clear.sh`, `budget-context.sh`, `decay-learnings.sh`, `compile-graph.sh`, `validate-proposal.sh`
- 6 skills: `browse`, `drift-check`, `graph`, `ingest`, `regress`, `review`
- 2 MCP tools: `knowledge_index`, `knowledge_feedback`
- 3 hook events: `UserPromptSubmit`, `PostCompact`, `SubagentStop`

### Added
- 1 new script: `stop-hook-predicate.sh` (4-condition boolean diff)
- 1 new wrapper: `run-stop-predicate.sh`
- 3 new MCP tools: `pin_to_user`, `pin_to_project`, `archive_to_wiki`
- New hot-tier files: `USER.md`, `projects/<slug>/PROJECT.md`, `index.txt`
- Migration script: `migrate-to-1.0.0.sh`

### Changed
- `knowledge_search` rebuilt with ripgrep backend (no embeddings, no sqlite-vec).
- `session-load.sh` rewritten as hot-tier reader with SessionStart baseline capture.
- 7 skills retained but simplified: `setup`, `status`, `query`, `lint`, `improve` (rebuilt), `import-host`, `upgrade` (added 1.0.0 row).
```

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json CHANGELOG.md
git commit -m "chore(v1.0): bump plugin to 1.0.0"
```

---

### Task 19: End-to-end verification

**Files:** No file changes; verification only.

- [ ] **Step 1: Validator passes**

```bash
bash scripts/validate-plugin.sh
```
Expected: `OK`, no WARNs.

- [ ] **Step 2: All scripts parse**

```bash
for s in scripts/*.sh; do bash -n "$s" || echo "PARSE ERROR: $s"; done
```

- [ ] **Step 3: MCP tests pass**

```bash
cd mcp && npx vitest run
```

- [ ] **Step 4: Stop-hook predicate tests pass**

```bash
bash tests/test-stop-hook-predicate.sh
```

- [ ] **Step 5: Hooks regression test passes (or is updated for v1.0)**

```bash
bash tests/test-hooks-regression.sh
```

- [ ] **Step 6: Re-run `/second-brain:doubt --layer learning`**

Confirm the layer's findings from doubt run #2 (2026-05-01) are no longer present (the relevant code has been deleted).

- [ ] **Step 7: Re-run `/second-brain:doubt docs/specs/2026-05-01-second-brain-v1-redesign.md`**

Confirm the spec's diagnosis is now obsolete (the layer it described is gone).

- [ ] **Step 8: Open PR to main**

```bash
gh pr create --title "v1.0 redesign — hot-tier model" --body "$(cat <<'EOF'
## Summary
- Removes reflection→critic→learnings pipeline (11 scripts, 6 skills, 2 MCP tools, 3 hooks deleted).
- Adds hot-tier auto-load: USER.md + per-project PROJECT.md + index.txt active line, ≤700 token target.
- Adds 3 explicit-only MCP pin/archive tools.
- `knowledge_search` rebuilt with ripgrep backend.

Spec: `docs/specs/2026-05-01-second-brain-v1-redesign.md` (commits 0a050fc, bae259a).
Plan: `docs/plans/2026-05-01-second-brain-v1.0-implementation.md`.

## Test plan
- [ ] validate-plugin.sh passes
- [ ] All MCP vitest tests pass
- [ ] tests/test-hooks-regression.sh passes
- [ ] tests/test-stop-hook-predicate.sh passes
- [ ] /second-brain:doubt --layer learning finds nothing after the pipeline is gone
EOF
)"
```

---

## Self-Review

**Spec coverage:** Every section of the spec maps to a task:
- Hot tier (USER.md, PROJECT.md, index.txt) → Tasks 3, 4, 14
- Cold tier (wiki dirs) → Task 4
- Stop-hook predicate → Tasks 1, 12
- MCP tools (3 added, 1 rebuilt, 2 removed) → Tasks 5, 6, 7, 8, 9
- Hooks (4 events) → Task 11
- Skills (7 kept-or-rebuilt, 6 dropped) → Tasks 13, 14, 15, 16
- Migration (1.0.0) → Task 17
- Plugin meta → Task 18
- Verification → Task 19

**Placeholder scan:** Tasks 14-16 outline skill bodies rather than reproducing them in full because skill files follow established patterns in this repo (existing 0.7.0 SKILL.md examples) and exact body would explode the plan length. Each task explicitly references the section structure and the YAML frontmatter requirements; the implementer follows the existing pattern.

**Type consistency:** MCP tool input/output types are consistent across Tasks 5-8 (`{ ok, ... }` for write tools, `{ candidates: [...] }` for search). Section names match between predicate (Task 1: Goal, State, Open blockers, Recent decisions), MCP tools (Task 6: decisions, blockers), and spec template. Slug derivation uses repo basename consistently across Tasks 3, 5, 6, 7, 12.

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-05-01-second-brain-v1.0-implementation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for a 19-task migration where the per-task scope is well-bounded but cumulative context would bloat one session.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints. Tighter per-step oversight, but this session has already burned context on doubt runs and spec rewrites.

Which approach?
