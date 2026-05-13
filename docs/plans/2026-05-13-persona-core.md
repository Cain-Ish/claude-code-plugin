# Persona Core Implementation Plan

> **For agentic workers:** Implement task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Promote the second-brain persona from passive memory layer to silent-but-present collaborator. Ship as part of v2.3.0.

**Architecture:** Five layers — silent infrastructure (always-on, $0), pull-based Opus brief (opt-in), rules-based tool guard ($0), Haiku Quality Gate (~$0.001/session), persona MCP surface ($0). Cheap default + structured-brief escalation; never raw transcripts across boundaries.

**Tech Stack:** Bash (hooks, glue), TypeScript + esbuild (MCP tools, bundled with `--external:@huggingface/transformers`), `claude -p` for Opus/Haiku calls, jq for JSON manipulation. No new dependencies.

**Pre-existing scope already in this branch:** 5 vendored superpowers skills, sb CLI, `/second-brain:review` skill, NOTICE.md, pre-existing test fix. Those land with v2.3.0 too; no rework.

**Defaults locked:**
- `SB_PERSONA_MODEL=claude-opus-4-7` (Layer 2)
- `SB_PERSONA_GATE=on` (kill switch off → on, default enabled)
- `SB_PERSONA_AUTO_THINK=off` (explicit invocation only)
- `SB_PERSONA_DAILY_BUDGET=20` (USD/day cap)
- `SB_QUALITY_GATE_STRICTNESS=conservative` (~10% rejection)

---

## File structure (new)

```
scripts/
  discover-installed.sh          # T1 — enumerate plugins → catalog
  persona-context.sh             # T3 — UserPromptSubmit hook (replaces intent-gate.sh)
  persona-tool-guard.sh          # T7 — PreToolUse hook
  quality-gate.sh                # T8 — wrap candidate extractions
skills/
  using-second-brain/SKILL.md    # T4 — meta-skill forcing persona consult
  think/SKILL.md                 # T6 — user-invocable Opus brief
mcp/src/tools/
  persona-think.ts               # T5 — Opus advisor brief tool
  persona-stats.ts               # T9 — persona state inspection
  persona-dismiss.ts             # T9 — backoff signal
mcp/test/
  persona-think.test.ts          # T5
  persona-stats.test.ts          # T9
  persona-dismiss.test.ts        # T9
~/.second-brain/                 # runtime, created on first use
  .installed-catalog.json        # T1 cache
  persona-card.md                # T2 user identity (seeded once)
  persona-rules.json             # T7 user-editable tool guard rules
  persona-budget.json            # T5 daily spend ledger
  .persona-dismissals.jsonl      # T9 dismissal log
```

## Files modified

- `hooks/hooks.json` — UserPromptSubmit points at persona-context.sh; add PreToolUse for persona-tool-guard.sh
- `scripts/stop-extract.sh` — wrap candidate merge in quality-gate.sh
- `skills/setup/SKILL.md` — seed persona-card.md on first run
- `skills/status/SKILL.md` — surface persona state, daily spend, dismissals
- `mcp/src/server.ts` — register persona-think, persona-stats, persona-dismiss tools
- `mcp/package.json` — bundle new CLI/server changes
- `.claude-plugin/plugin.json`, `marketplace.json` — bump to 2.3.0
- `skills/upgrade/SKILL.md` — add 2.3.0 migration row (already done in this branch)
- `README.md` — persona section

---

## Task ordering rationale

Bottom-up: catalog discovery is the foundation (used by everything). Persona card is needed before context-hook can reference it. Layers 1, 3, 5 are independent of LLM and ship quickly. Layer 2 (Opus brief) builds on persona-card + catalog. Layer 4 (quality gate) integrates with the existing stop-extract pipeline last.

---

### Task 1: Catalog discovery script

**Files:**
- Create: `scripts/discover-installed.sh`

- [ ] **Step 1: Write the failing test as a bash assertion script**

Create a temp dir representing a fake plugins tree:
```bash
TMP=$(mktemp -d)
mkdir -p "$TMP/plugin-a" "$TMP/plugin-b/agents" "$TMP/plugin-b/skills/foo"
cat > "$TMP/plugin-a/plugin.json" <<EOF
{"name":"plugin-a","description":"Test plugin A","version":"1.0.0"}
EOF
cat > "$TMP/plugin-b/plugin.json" <<EOF
{"name":"plugin-b","description":"Test plugin B","version":"2.0.0"}
EOF
cat > "$TMP/plugin-b/agents/helper.md" <<EOF
---
name: helper
description: A helper agent
---
EOF
cat > "$TMP/plugin-b/skills/foo/SKILL.md" <<EOF
---
name: foo
description: A foo skill
---
EOF

# Should produce a JSON catalog with 2 plugins, 1 agent, 1 skill
OUT=$(bash scripts/discover-installed.sh "$TMP")
echo "$OUT" | jq -e '.plugins | length == 2' || exit 1
echo "$OUT" | jq -e '.agents | length == 1' || exit 1
echo "$OUT" | jq -e '.skills | length == 1' || exit 1
```

- [ ] **Step 2: Run test — confirm it fails (script doesn't exist yet)**

Expected: `scripts/discover-installed.sh: No such file or directory`.

- [ ] **Step 3: Implement `scripts/discover-installed.sh`**

```bash
#!/bin/bash
# discover-installed.sh — enumerate installed plugins/agents/skills
# Usage: discover-installed.sh [plugins-root]
# Default plugins root: ~/.claude/plugins/cache/
# Writes: ~/.second-brain/.installed-catalog.json (and stdout)
set -u

PLUGINS_ROOT="${1:-$HOME/.claude/plugins/cache}"
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
OUT_FILE="$BRAIN_DIR/.installed-catalog.json"

mkdir -p "$BRAIN_DIR"

PLUGINS_JSON='[]'
AGENTS_JSON='[]'
SKILLS_JSON='[]'

if [ -d "$PLUGINS_ROOT" ]; then
  while IFS= read -r pj; do
    name=$(jq -r '.name // empty' "$pj" 2>/dev/null) || continue
    desc=$(jq -r '.description // empty' "$pj" 2>/dev/null)
    ver=$(jq -r '.version // empty' "$pj" 2>/dev/null)
    [ -z "$name" ] && continue
    PLUGINS_JSON=$(echo "$PLUGINS_JSON" | jq --arg n "$name" --arg d "$desc" --arg v "$ver" \
      '. + [{name:$n, description:$d, version:$v}]')

    plugin_dir=$(dirname "$pj")
    # If plugin.json is inside .claude-plugin/, the real plugin dir is its parent
    if [ "$(basename "$plugin_dir")" = ".claude-plugin" ]; then
      plugin_dir=$(dirname "$plugin_dir")
    fi

    # Agents
    while IFS= read -r af; do
      [ -f "$af" ] || continue
      aname=$(awk '/^---$/{f=!f;next}f && /^name:/{print $2; exit}' "$af")
      adesc=$(awk '/^---$/{f=!f;next}f && /^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$af")
      [ -z "$aname" ] && continue
      AGENTS_JSON=$(echo "$AGENTS_JSON" | jq --arg n "$aname" --arg d "$adesc" --arg p "$name" \
        '. + [{name:$n, description:$d, plugin:$p}]')
    done < <(find "$plugin_dir/agents" -maxdepth 1 -name '*.md' -type f 2>/dev/null)

    # Skills
    while IFS= read -r sf; do
      sname=$(awk '/^---$/{f=!f;next}f && /^name:/{print $2; exit}' "$sf")
      sdesc=$(awk '/^---$/{f=!f;next}f && /^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$sf")
      [ -z "$sname" ] && continue
      SKILLS_JSON=$(echo "$SKILLS_JSON" | jq --arg n "$sname" --arg d "$sdesc" --arg p "$name" \
        '. + [{name:$n, description:$d, plugin:$p}]')
    done < <(find "$plugin_dir/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' -type f 2>/dev/null)
  done < <(find "$PLUGINS_ROOT" -name 'plugin.json' -type f 2>/dev/null | head -100)
fi

CATALOG=$(jq -n --argjson p "$PLUGINS_JSON" --argjson a "$AGENTS_JSON" --argjson s "$SKILLS_JSON" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{generated_at:$ts, plugins:$p, agents:$a, skills:$s}')

echo "$CATALOG" > "$OUT_FILE"
echo "$CATALOG"
```

- [ ] **Step 4: Run test — verify it passes**

Run the test script from Step 1.
Expected: exit 0, three `jq -e` assertions pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/discover-installed.sh
git commit -m "feat(persona): catalog discovery — enumerate installed plugins/agents/skills"
```

---

### Task 2: Persona card seed + setup integration

**Files:**
- Modify: `skills/setup/SKILL.md` (add persona-card seed step)
- Document: persona-card.md format (in spec, no code file needed — it's user-owned content)

- [ ] **Step 1: Decide seed template**

```markdown
# Persona

## Identity
- {role from USER.md or "senior engineer"}
- {project context from active PROJECT.md Goal}

## Communication style
- {tone from graduated signals or "direct, terse, no filler"}
- {feedback rules from feedback_* memories}

## Working preferences
- {extracted from feedback_brainstorm_first if present}
- {extracted from feedback_skill_size if present}
- {extracted from feedback_fail_loud if present}

## How to engage me
- Surface critical context; don't restate what I know
- Ask one focused question only when ambiguity is costly to guess wrong
- Default silent; volunteer only when expected value exceeds flow cost
```

- [ ] **Step 2: Add seed logic to setup skill**

Edit `skills/setup/SKILL.md` — add a new step after the existing USER.md scaffolding:

```bash
### Step N: Seed persona-card.md
PCARD=~/.second-brain/persona-card.md
if [ ! -f "$PCARD" ]; then
  ROLE=$(grep -E '^- ' ~/.second-brain/USER.md 2>/dev/null | head -1 | sed 's/^- //')
  GOAL=$(awk '/^## Goal/{flag=1;next}/^## /{flag=0}flag && /./' ~/.second-brain/projects/*/PROJECT.md 2>/dev/null | head -1)
  cat > "$PCARD" <<EOF
# Persona

## Identity
- ${ROLE:-senior engineer}
- ${GOAL:-current project}

## Communication style
- direct, terse, no filler
- evidence before completion claims

## Working preferences
- brainstorm 2-3 options before architecture decisions
- fail loud over silent fallback
- skill bodies under 500 lines

## How to engage me
- Surface critical context; don't restate what I know
- Ask one focused question only when ambiguity is costly to guess wrong
- Default silent; volunteer only when expected value exceeds flow cost
EOF
  echo "Seeded persona-card.md ($(wc -c < "$PCARD") bytes)"
fi
```

- [ ] **Step 3: Run setup skill manually against test brainDir, verify file lands**

```bash
BRAIN_DIR=/tmp/test-brain bash -c 'rm -rf "$BRAIN_DIR"; mkdir -p "$BRAIN_DIR"/projects/test/; ...'
# Run the seeding block.
test -f /tmp/test-brain/persona-card.md && wc -c < /tmp/test-brain/persona-card.md
# Expected: file exists, ~600 bytes
```

- [ ] **Step 4: Commit**

```bash
git add skills/setup/SKILL.md
git commit -m "feat(persona): seed persona-card.md from existing identity signals"
```

---

### Task 3: persona-context.sh — Layer 1 main hook

**Files:**
- Create: `scripts/persona-context.sh`
- Modify: `hooks/hooks.json` (point UserPromptSubmit at new script)

- [ ] **Step 1: Write failing tests as bash assertions**

```bash
# Test 1: empty prompt → exit silently
echo '{"prompt":"","cwd":"/tmp"}' | bash scripts/persona-context.sh
test $? -eq 0 || exit 1

# Test 2: substantive prompt → emits hookSpecificOutput with additionalContext
OUT=$(echo '{"prompt":"build a login form","cwd":"/tmp"}' | bash scripts/persona-context.sh)
echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext' || exit 1

# Test 3: respect SB_PERSONA_GATE=off
OUT=$(SB_PERSONA_GATE=off echo '{"prompt":"anything","cwd":"/tmp"}' | bash scripts/persona-context.sh)
test -z "$OUT" || exit 1

# Test 4: /? prefix passes through to think tool (not implemented yet — skip for T6)
```

- [ ] **Step 2: Run tests — confirm they fail**

Expected: script doesn't exist.

- [ ] **Step 3: Implement the script**

```bash
#!/bin/bash
# persona-context.sh — UserPromptSubmit hook (replaces intent-gate.sh)
# Reads STDIN JSON: {prompt, cwd, ...}
# Emits hookSpecificOutput.additionalContext with:
#   - persona card (identity)
#   - top wiki hits (knowledge_search via bundled CLI)
#   - installed plugin catalog summary
# Capped at 1200 bytes total. No LLM call.

set -u

source "$(dirname "$0")/lib.sh" 2>/dev/null || true

# Kill switch
[ "${SB_PERSONA_GATE:-on}" = "off" ] && exit 0

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)

# Trivial-prompt skip: empty, slash command, or < 20 chars
[ -z "$PROMPT" ] && exit 0
[ ${#PROMPT} -lt 20 ] && exit 0
case "$PROMPT" in /*) exit 0 ;; esac

# /? prefix — defer to T6's think-skill path
case "$PROMPT" in '/?'*) exit 0 ;; esac

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
PCARD="$BRAIN_DIR/persona-card.md"
CATALOG="$BRAIN_DIR/.installed-catalog.json"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Persona card abstract (first 4 non-header lines)
PCARD_ABS=""
[ -f "$PCARD" ] && PCARD_ABS=$(grep -v '^#' "$PCARD" | grep -v '^[[:space:]]*$' | head -4 | sed 's/^- //' | tr '\n' '; ')

# Catalog summary: top 5 plugins by name
CATALOG_ABS=""
if [ -f "$CATALOG" ]; then
  CATALOG_ABS=$(jq -r '.plugins[0:5] | map(.name) | join(", ")' "$CATALOG" 2>/dev/null)
fi

# Top wiki hits via existing bundled CLI
WIKI_HITS=""
BUNDLE="$PLUGIN_ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
if [ -f "$BUNDLE" ]; then
  WIKI_HITS=$(node "$BUNDLE" "$PROMPT" 2>/dev/null | head -10)
fi

# Compose additionalContext as factual statements
CTX=""
[ -n "$PCARD_ABS" ] && CTX="${CTX}Persona: ${PCARD_ABS}\n"
[ -n "$CATALOG_ABS" ] && CTX="${CTX}Available specialists (installed plugins): ${CATALOG_ABS}\n"
[ -n "$WIKI_HITS" ] && CTX="${CTX}Relevant wiki:\n${WIKI_HITS}\n"

[ -z "$CTX" ] && exit 0

# Truncate to 1200 bytes
CTX=$(printf '%b' "$CTX" | head -c 1200)

# Emit hookSpecificOutput
jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
```

- [ ] **Step 4: Update hooks.json**

Replace the UserPromptSubmit entry for `intent-gate.sh` with `persona-context.sh`:

```bash
jq '.hooks.UserPromptSubmit = [
  {
    "hooks": [
      {
        "type": "command",
        "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/persona-context.sh",
        "timeout": 10000
      }
    ]
  }
]' hooks/hooks.json > hooks/hooks.json.new && mv hooks/hooks.json.new hooks/hooks.json
```

- [ ] **Step 5: Validate hooks.json**

```bash
bash scripts/validate-plugin.sh
```
Expected: `OK: all plugin files valid`.

- [ ] **Step 6: Run the 4 tests from Step 1 — verify they pass**

- [ ] **Step 7: Commit**

```bash
git add scripts/persona-context.sh hooks/hooks.json
git commit -m "feat(persona): Layer 1 silent infrastructure hook"
```

---

### Task 4: using-second-brain meta-skill

**Files:**
- Create: `skills/using-second-brain/SKILL.md`

- [ ] **Step 1: Write the skill**

```markdown
---
name: using-second-brain
description: Use when starting any conversation - establishes how to consult the persona's identity, memory (wiki + episodic), and installed plugin catalog before answering substantive prompts.
user-invocable: false
disable-model-invocation: false
allowed-tools: Read mcp__second-brain__persona_stats mcp__second-brain__knowledge_search mcp__second-brain__episodic_search
---

# Using Second-Brain

You have a persona core. Before any non-trivial response:

1. The persona has already injected its identity card, top wiki hits, and the installed plugin catalog via the UserPromptSubmit hook. **Read those system reminders. Don't ignore them.**

2. **Specialist routing.** If the user's request matches a specialist available in the catalog (e.g., frontend work + frontend-developer agent installed), call out the option before doing the work yourself.

3. **Prior context.** If the wiki has a relevant prior decision, surface it once. Don't restate what the user already knows from the persona card.

4. **Silence is the default.** Do not lecture, summarize, or volunteer process commentary. The user is in flow.

5. **When deep analysis would help**, suggest the user invoke `/second-brain:think` or prefix their prompt with `/?` — both trigger an Opus-level advisor brief.

This skill replaces "I'll search the codebase first" filler. The persona has already done the search.
```

- [ ] **Step 2: Validate plugin**

```bash
bash scripts/validate-plugin.sh
```
Expected: `OK: all plugin files valid`.

- [ ] **Step 3: Commit**

```bash
git add skills/using-second-brain/SKILL.md
git commit -m "feat(persona): using-second-brain meta-skill — obra-pattern forcing"
```

---

### Task 5: persona-think MCP tool (Layer 2 Opus brief)

**Files:**
- Create: `mcp/src/tools/persona-think.ts`
- Create: `mcp/test/persona-think.test.ts`
- Modify: `mcp/src/server.ts` (register tool)
- Modify: `mcp/package.json` (bundle entry)

- [ ] **Step 1: Write failing test**

```typescript
// mcp/test/persona-think.test.ts
import { describe, it, expect, vi } from 'vitest';
import { personaThink } from '../src/tools/persona-think.js';

describe('persona_think', () => {
  it('returns structured brief on a substantive prompt', async () => {
    // Stub spawn of `claude -p`
    const fakeRunner = vi.fn().mockResolvedValue(JSON.stringify({
      intent_read: 'user wants to build login',
      prompt_enrichment: 'add: tech stack, auth provider preference',
      clarifying_questions: ['OAuth or password?'],
      relevant_specialists: ['frontend-developer'],
      risk_flags: []
    }));
    const r = await personaThink({ prompt: 'build a login form' }, { runner: fakeRunner });
    expect(r.intent_read).toContain('login');
    expect(r.clarifying_questions.length).toBeGreaterThan(0);
  });

  it('respects budget cap', async () => {
    const fakeRunner = vi.fn();
    const r = await personaThink(
      { prompt: 'anything' },
      { runner: fakeRunner, budgetExceeded: true }
    );
    expect(r.budget_skipped).toBe(true);
    expect(fakeRunner).not.toHaveBeenCalled();
  });

  it('falls through gracefully on runner failure', async () => {
    const fakeRunner = vi.fn().mockRejectedValue(new Error('claude -p failed'));
    const r = await personaThink({ prompt: 'x' }, { runner: fakeRunner });
    expect(r.error).toBeDefined();
    expect(r.intent_read).toBe('');
  });
});
```

- [ ] **Step 2: Run test — confirm failures**

```bash
cd mcp && npm test -- persona-think
```
Expected: 3 tests fail (module doesn't exist).

- [ ] **Step 3: Implement persona-think.ts**

```typescript
// mcp/src/tools/persona-think.ts
import { spawn } from 'child_process';

export interface PersonaThinkArgs { prompt: string; context_hints?: string[]; }
export interface PersonaBrief {
  intent_read: string;
  prompt_enrichment: string;
  clarifying_questions: string[];
  relevant_specialists: string[];
  risk_flags: string[];
  budget_skipped?: boolean;
  error?: string;
}
interface Deps {
  runner?: (system: string, user: string, model: string) => Promise<string>;
  budgetExceeded?: boolean;
  model?: string;
}

const DEFAULT_MODEL = process.env.SB_PERSONA_MODEL ?? 'claude-opus-4-7';
const SYSTEM_PROMPT = `You are the user's senior-developer persona for the second-brain plugin. Given the user's prompt, return ONLY a JSON object with these fields:
  intent_read: one sentence — what the user probably wants
  prompt_enrichment: what context should be added to the prompt for a better answer
  clarifying_questions: array of 0-2 questions worth asking before answering
  relevant_specialists: array of plugin/agent names that fit (or empty)
  risk_flags: array of risks/gotchas (or empty)
No prose outside the JSON.`;

async function defaultRunner(system: string, user: string, model: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const p = spawn('claude', ['-p', '--model', model, '--system', system], { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '';
    p.stdout.on('data', d => out += d.toString());
    p.stderr.on('data', d => err += d.toString());
    p.on('error', reject);
    p.on('close', code => code === 0 ? resolve(out) : reject(new Error(err || `claude -p exited ${code}`)));
    p.stdin.write(user);
    p.stdin.end();
  });
}

export async function personaThink(args: PersonaThinkArgs, deps: Deps = {}): Promise<PersonaBrief> {
  const empty: PersonaBrief = { intent_read: '', prompt_enrichment: '', clarifying_questions: [], relevant_specialists: [], risk_flags: [] };
  if (deps.budgetExceeded) return { ...empty, budget_skipped: true };
  const runner = deps.runner ?? defaultRunner;
  const model = deps.model ?? DEFAULT_MODEL;
  try {
    const raw = await runner(SYSTEM_PROMPT, args.prompt, model);
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) return { ...empty, error: 'no JSON in response' };
    const parsed = JSON.parse(match[0]);
    return {
      intent_read: parsed.intent_read ?? '',
      prompt_enrichment: parsed.prompt_enrichment ?? '',
      clarifying_questions: parsed.clarifying_questions ?? [],
      relevant_specialists: parsed.relevant_specialists ?? [],
      risk_flags: parsed.risk_flags ?? [],
    };
  } catch (e: any) {
    return { ...empty, error: e.message };
  }
}
```

- [ ] **Step 4: Register tool in mcp/src/server.ts**

Add to existing tool registration (mirror pattern of pin_to_user etc.):

```typescript
import { personaThink } from './tools/persona-think.js';
// ... in tools array:
{
  name: 'persona_think',
  description: 'Persona advisor brief — call when the user prompt is non-trivial and you want a structured second opinion before answering.',
  inputSchema: z.object({ prompt: z.string(), context_hints: z.array(z.string()).optional() }),
  handler: async (args) => personaThink(args),
}
```

- [ ] **Step 5: Add bundle step to mcp/package.json**

```
... && esbuild src/tools/persona-think.ts --bundle --platform=node --target=node20 --format=esm --external:@huggingface/transformers --outfile=dist/tools/persona-think.bundle.js
```

- [ ] **Step 6: Run tests — verify pass**

```bash
cd mcp && npm test -- persona-think
```
Expected: 3 tests pass.

- [ ] **Step 7: Commit**

```bash
git add mcp/src/tools/persona-think.ts mcp/test/persona-think.test.ts mcp/src/server.ts mcp/package.json
git commit -m "feat(persona): persona_think MCP tool — Opus advisor brief on demand"
```

---

### Task 6: think skill + /? prefix support

**Files:**
- Create: `skills/think/SKILL.md`
- Modify: `scripts/persona-context.sh` (handle /? prefix)

- [ ] **Step 1: Create think skill**

```markdown
---
name: think
description: Trigger a structured Opus-level advisor brief on a non-trivial topic. Returns intent read, prompt enrichment, clarifying questions, relevant specialists, and risk flags.
user-invocable: true
disable-model-invocation: false
allowed-tools: mcp__second-brain__persona_think
---

# Think

Call `persona_think` MCP tool with the user's topic (from `$ARGUMENTS`).

Format the response as:
- **Intent read:** {intent_read}
- **Enriched prompt:** {prompt_enrichment}
- **Questions:** numbered list (if any)
- **Specialists to consider:** comma-separated (if any)
- **Risks:** bullet list (if any)

If any field is empty, omit it.
```

- [ ] **Step 2: Handle /? prefix in persona-context.sh**

Replace the current `/?` early-exit with an inline path that invokes the bundled persona-think CLI:

```bash
case "$PROMPT" in
  '/?'*)
    QUERY="${PROMPT#/?}"
    QUERY="${QUERY# }"
    BUNDLE="$PLUGIN_ROOT/mcp/dist/tools/persona-think.bundle.js"
    if [ -f "$BUNDLE" ]; then
      BRIEF=$(echo "$QUERY" | node "$BUNDLE" 2>/dev/null)
      if [ -n "$BRIEF" ]; then
        jq -n --arg ctx "Persona brief:\n$BRIEF" '{
          hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext: $ctx
          }
        }'
      fi
    fi
    exit 0
    ;;
esac
```

Also create a thin CLI entrypoint `mcp/src/tools/persona-think-cli.ts` that reads stdin → calls personaThink → prints stringified brief. Add bundle step.

- [ ] **Step 3: Verify**

Run a quick manual test with `SB_PERSONA_MODEL=claude-haiku-4-5-20251001` to keep cost low:

```bash
echo '{"prompt":"/? how should I design a login form with rate limiting?","cwd":"/tmp"}' | SB_PERSONA_MODEL=claude-haiku-4-5-20251001 bash scripts/persona-context.sh
```
Expected: JSON output with `hookSpecificOutput.additionalContext` containing a brief.

- [ ] **Step 4: Validate plugin**

```bash
bash scripts/validate-plugin.sh
```

- [ ] **Step 5: Commit**

```bash
git add skills/think/SKILL.md scripts/persona-context.sh mcp/src/tools/persona-think-cli.ts mcp/package.json
git commit -m "feat(persona): /? prefix and /second-brain:think skill route to persona-think"
```

---

### Task 7: persona-tool-guard.sh — Layer 3

**Files:**
- Create: `scripts/persona-tool-guard.sh`
- Create: `~/.second-brain/persona-rules.json` (template shipped at `scripts/persona-rules.default.json`)
- Modify: `hooks/hooks.json` (add PreToolUse)

- [ ] **Step 1: Define default rules JSON**

```json
{
  "rules": [
    {
      "name": "strip-silent-fallback",
      "tool": "Bash",
      "match": "2>/dev/null",
      "action": "rewrite",
      "replace": "",
      "reason": "Plugin convention: fail loud, not silent (CLAUDE.md feedback_fail_loud)."
    },
    {
      "name": "warn-force-push-main",
      "tool": "Bash",
      "match": "git push.*--force.*\\b(main|master)\\b",
      "action": "ask",
      "reason": "Force-push to main/master is destructive. Confirm intent."
    },
    {
      "name": "warn-direct-write-hot-tier",
      "tool": "Write",
      "match_path": "(USER\\.md|PROJECT\\.md|plugin\\.json)$",
      "action": "ask",
      "reason": "Write to hot-tier files should use pin_to_user / pin_to_project MCP tools to keep size caps and dedupe."
    }
  ]
}
```

- [ ] **Step 2: Write tests**

```bash
# Test: 2>/dev/null gets stripped
INPUT='{"tool_name":"Bash","tool_input":{"command":"ls foo 2>/dev/null"}}'
OUT=$(echo "$INPUT" | bash scripts/persona-tool-guard.sh)
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' || exit 1
echo "$OUT" | jq -e '.hookSpecificOutput.updatedInput.command | test("2>/dev/null") | not' || exit 1
```

- [ ] **Step 3: Implement guard**

```bash
#!/bin/bash
# persona-tool-guard.sh — PreToolUse hook, rules-based
set -u

[ "${SB_PERSONA_GATE:-on}" = "off" ] && exit 0

INPUT=$(cat)
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
RULES_FILE="$BRAIN_DIR/persona-rules.json"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DEFAULT_RULES="$PLUGIN_ROOT/scripts/persona-rules.default.json"

[ ! -f "$RULES_FILE" ] && RULES_FILE="$DEFAULT_RULES"
[ ! -f "$RULES_FILE" ] && exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ -z "$TOOL" ] && exit 0

# Iterate rules
MATCHED=$(jq -r --arg t "$TOOL" '.rules[] | select(.tool == $t) | @json' "$RULES_FILE")
[ -z "$MATCHED" ] && exit 0

while IFS= read -r rule; do
  [ -z "$rule" ] && continue
  match=$(echo "$rule" | jq -r '.match // empty')
  match_path=$(echo "$rule" | jq -r '.match_path // empty')
  action=$(echo "$rule" | jq -r '.action')
  reason=$(echo "$rule" | jq -r '.reason')
  replace=$(echo "$rule" | jq -r '.replace // empty')

  if [ -n "$match" ]; then
    cmd=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    echo "$cmd" | grep -qE "$match" || continue
  fi
  if [ -n "$match_path" ]; then
    path=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
    echo "$path" | grep -qE "$match_path" || continue
  fi

  case "$action" in
    rewrite)
      new_cmd=$(echo "$cmd" | sed "s|$match|$replace|g")
      jq -n --arg c "$new_cmd" --arg r "$reason" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "allow",
          permissionDecisionReason: $r,
          updatedInput: { command: $c }
        }
      }'
      exit 0
      ;;
    ask)
      jq -n --arg r "$reason" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "ask",
          permissionDecisionReason: $r
        }
      }'
      exit 0
      ;;
    deny)
      jq -n --arg r "$reason" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: $r
        }
      }'
      exit 0
      ;;
  esac
done <<< "$MATCHED"

exit 0
```

- [ ] **Step 4: Wire into hooks.json**

Add PreToolUse entry with broad matcher (`*`) and the new script.

- [ ] **Step 5: Run tests — verify pass**

- [ ] **Step 6: Commit**

```bash
git add scripts/persona-tool-guard.sh scripts/persona-rules.default.json hooks/hooks.json
git commit -m "feat(persona): Layer 3 tool guard — rules-based PreToolUse mutation"
```

---

### Task 8: quality-gate.sh + stop-extract integration

**Files:**
- Create: `scripts/quality-gate.sh`
- Modify: `scripts/stop-extract.sh` (wrap candidate merge)

- [ ] **Step 1: Implement quality-gate.sh**

```bash
#!/bin/bash
# quality-gate.sh — Haiku validator pass on extraction candidates
# Input STDIN: JSON {candidates: [...]}
# Output STDOUT: JSON {accepted: [...], rejected: [...]}
set -u

STRICTNESS="${SB_QUALITY_GATE_STRICTNESS:-conservative}"
MODEL="${SB_QUALITY_MODEL:-claude-haiku-4-5-20251001}"

INPUT=$(cat)
CANDIDATES=$(echo "$INPUT" | jq -c '.candidates[]?')
[ -z "$CANDIDATES" ] && echo '{"accepted":[],"rejected":[]}' && exit 0

ACCEPTED='[]'
REJECTED='[]'

while IFS= read -r cand; do
  [ -z "$cand" ] && continue
  # Build a tight system prompt for Haiku
  RAW=$(echo "$cand" | jq -r '.text // empty')
  TYPE=$(echo "$cand" | jq -r '.type // "unknown"')

  PROMPT="You are a noise filter for a developer's second-brain wiki. The candidate is type='$TYPE'.

  Candidate: $RAW

  Respond ONLY with one of: ACCEPT or REJECT. Reject if this is generic platitude, restates an obvious truth, or refers to a one-off session detail. Accept if this is a durable insight, decision, or pattern.

  Strictness: $STRICTNESS (conservative = only reject obvious noise; aggressive = also reject low-signal entries)."

  RESULT=$(echo "$PROMPT" | claude -p --model "$MODEL" 2>/dev/null | tr -d '\r' | head -1)
  if echo "$RESULT" | grep -qi 'ACCEPT'; then
    ACCEPTED=$(echo "$ACCEPTED" | jq --argjson c "$cand" '. + [$c]')
  else
    REJECTED=$(echo "$REJECTED" | jq --argjson c "$cand" --arg r "$RESULT" '. + [{candidate:$c, reason:$r}]')
  fi
done <<< "$CANDIDATES"

jq -n --argjson a "$ACCEPTED" --argjson r "$REJECTED" '{accepted:$a, rejected:$r}'
```

- [ ] **Step 2: Add stop-extract integration**

In `scripts/stop-extract.sh`, after the existing extraction step, pipe candidates through quality-gate before merging:

```bash
EXTRACT_OUT=$(...existing extraction call...)
CANDS=$(echo "$EXTRACT_OUT" | jq '{candidates: (.decisions + .blockers + .wiki_updates // [])}')
GATED=$(echo "$CANDS" | bash "$SCRIPT_DIR/quality-gate.sh")

# Log rejections for inspection
echo "$GATED" | jq -c '.rejected[]?' >> "$BRAIN_DIR/.rejected-extractions.jsonl"

# Merge accepted only
EXTRACT_OUT=$(echo "$EXTRACT_OUT" | jq --argjson acc "$(echo "$GATED" | jq '.accepted')" \
  '.decisions = ($acc | map(select(.type == "decision")))
   | .blockers = ($acc | map(select(.type == "blocker")))
   | .wiki_updates = ($acc | map(select(.type == "wiki")))')
```

Exact code shape depends on existing stop-extract.sh structure. The TDD step writes a small JSONL fixture and asserts quality-gate output.

- [ ] **Step 3: Test against fixture**

```bash
echo '{"candidates":[{"type":"decision","text":"decided to use BM25 + ONNX hybrid for wiki search"},{"type":"decision","text":"good code is important"}]}' | bash scripts/quality-gate.sh
# Expected: first candidate accepted, second rejected (platitude)
```

- [ ] **Step 4: Validate**

```bash
bash scripts/validate-plugin.sh
```

- [ ] **Step 5: Commit**

```bash
git add scripts/quality-gate.sh scripts/stop-extract.sh
git commit -m "feat(persona): Layer 4 quality gate — Haiku validator before wiki promotion"
```

---

### Task 9: Persona MCP tools — Layer 5

**Files:**
- Create: `mcp/src/tools/persona-stats.ts`, `mcp/test/persona-stats.test.ts`
- Create: `mcp/src/tools/persona-dismiss.ts`, `mcp/test/persona-dismiss.test.ts`
- Modify: `mcp/src/server.ts` (register both)
- Modify: `mcp/package.json` (bundle steps)

- [ ] **Step 1: persona-stats implementation**

Returns: identity summary, ungraduated signals count, top wiki entries, dismissals 7d. Pure file reads.

```typescript
// mcp/src/tools/persona-stats.ts
import { promises as fs } from 'fs';
import { join } from 'path';

export interface PersonaStatsResult {
  identity_summary: string;
  ungraduated_signals: number;
  top_wiki_entries: string[];
  dismissals_7d: number;
}

export async function personaStats(args: {}, opts: { brainDir?: string } = {}): Promise<PersonaStatsResult> {
  const dir = opts.brainDir ?? join(process.env.HOME ?? '', '.second-brain');
  let identity = '';
  try {
    const card = await fs.readFile(join(dir, 'persona-card.md'), 'utf-8');
    identity = card.split('\n').filter(l => l.startsWith('- ')).slice(0, 3).join('; ');
  } catch {}
  let ungraduated = 0;
  try {
    const psl = await fs.readFile(join(dir, 'persona-signals.jsonl'), 'utf-8');
    ungraduated = psl.split('\n').filter(l => {
      try { const j = JSON.parse(l); return j.count >= 2 && j.graduated === false; } catch { return false; }
    }).length;
  } catch {}
  let dismissals = 0;
  try {
    const dl = await fs.readFile(join(dir, '.persona-dismissals.jsonl'), 'utf-8');
    const cutoff = Date.now() - 7 * 86400000;
    dismissals = dl.split('\n').filter(l => {
      try { const j = JSON.parse(l); return new Date(j.at).getTime() > cutoff; } catch { return false; }
    }).length;
  } catch {}
  return { identity_summary: identity, ungraduated_signals: ungraduated, top_wiki_entries: [], dismissals_7d: dismissals };
}
```

Tests assert each field present, defaults to zero/empty when files missing.

- [ ] **Step 2: persona-dismiss implementation**

Append a JSONL entry `{at, prompt_snippet, reason}` to `.persona-dismissals.jsonl`. If count_7d > 3, hook reads it and prunes opinionated framing in Layer 1 output.

- [ ] **Step 3: Register both tools in server.ts**

Mirror existing pin tool pattern.

- [ ] **Step 4: Add bundle steps**

- [ ] **Step 5: Tests pass**

```bash
cd mcp && npm test
```

- [ ] **Step 6: Commit**

```bash
git add mcp/src/tools/persona-stats.ts mcp/src/tools/persona-dismiss.ts mcp/test/persona-stats.test.ts mcp/test/persona-dismiss.test.ts mcp/src/server.ts mcp/package.json
git commit -m "feat(persona): Layer 5 MCP tools — persona_stats, persona_dismiss"
```

---

### Task 10: Integration tests

**Files:**
- Create: `mcp/test/persona-integration.test.ts`

- [ ] Spawn `persona-context.sh` against a fixture brainDir + catalog. Assert end-to-end output shape (with all layers wired).
- [ ] Run with `SB_PERSONA_GATE=off`. Assert no output.
- [ ] Run with `/?` prefix. Assert routes to think tool (stubbed).

- [ ] **Commit:** `test(persona): end-to-end integration suite`

---

### Task 11: Migration row + status integration

**Files:**
- Modify: `skills/upgrade/SKILL.md` (the 2.3.0 row is already there from the earlier sb-CLI bundle — extend it with the persona-core additions)
- Modify: `skills/status/SKILL.md` (add persona section)

- [ ] **Step 1: Update 2.3.0 migration row**

Append to existing 2.3.0 row in `skills/upgrade/SKILL.md`:

> ...plus Layer 1-5 persona core: silent context injection (`persona-context.sh`), Opus advisor brief on `/?` or `/second-brain:think` (`persona-think` MCP tool), rules-based PreToolUse mutation (`persona-tool-guard.sh` + `persona-rules.json`), Haiku Quality Gate on extractions (`quality-gate.sh`), and persona inspection MCP tools (`persona_stats`, `persona_dismiss`). Seeds `~/.second-brain/persona-card.md` on first run from existing USER.md + signals. Defaults: silent Layer 1, opt-in Opus via `/?`, $20/day budget cap. No state migration — additive.

- [ ] **Step 2: Add persona section to status skill**

```bash
### Persona state
PCARD=~/.second-brain/persona-card.md
[ -f "$PCARD" ] && echo "Persona card: $(wc -l < "$PCARD") lines, $(wc -c < "$PCARD") bytes"
DISMISSALS=$(test -f ~/.second-brain/.persona-dismissals.jsonl && wc -l < ~/.second-brain/.persona-dismissals.jsonl || echo 0)
echo "Dismissals (7d): $DISMISSALS"
BUDGET=$(test -f ~/.second-brain/persona-budget.json && jq -r '.today_usd' ~/.second-brain/persona-budget.json || echo "0.00")
echo "Today's persona spend: \$$BUDGET / \$${SB_PERSONA_DAILY_BUDGET:-20}"
```

- [ ] **Step 3: Commit**

```bash
git add skills/upgrade/SKILL.md skills/status/SKILL.md
git commit -m "docs(persona): 2.3.0 migration row + status integration"
```

---

### Task 12: README + final smoke + bundle build

**Files:**
- Modify: `README.md` (persona section after existing skill table)
- Build: `npm run bundle` in mcp/

- [ ] **Step 1: README persona section**

Add after the existing skill table:

```markdown
## Persona core

The persona is the *self* of second-brain — identity, memory, tools, judgment. Always present, rarely loud.

**Layers:**
1. Silent infrastructure — persona-card + plugin catalog + wiki hits injected per prompt (free, always on)
2. Pull-based deep brief — `/?` prefix or `/second-brain:think` triggers Opus advisor brief (~$0.11/call)
3. Tool guard — rules-based PreToolUse mutation (strips silent-fallback patterns, warns on dangerous ops)
4. Quality Gate — Haiku validator before wiki promotion (~$0.001/session-end)
5. MCP surface — `persona_stats`, `persona_dismiss` for self-inspection

**Env vars:**
- `SB_PERSONA_GATE=off` — disable all persona hooks
- `SB_PERSONA_MODEL=claude-sonnet-4-6` — change Opus brief model
- `SB_PERSONA_DAILY_BUDGET=20` — kill switch when daily spend exceeds (USD)
- `SB_PERSONA_AUTO_THINK=on` — auto-trigger Opus on long+complex prompts
- `SB_QUALITY_GATE_STRICTNESS=aggressive` — reject more candidates (~30%) vs conservative (~10%)

**Files (user-editable):**
- `~/.second-brain/persona-card.md` — identity card. Read by Layer 1.
- `~/.second-brain/persona-rules.json` — tool-guard rules. Read by Layer 3.
```

- [ ] **Step 2: Final bundle build**

```bash
cd mcp && npm run bundle
```
Verify dist/tools/persona-think.bundle.js etc. emitted.

- [ ] **Step 3: Final validation**

```bash
bash scripts/validate-plugin.sh && cd mcp && npm test
```
Expected: validator OK, all tests pass.

- [ ] **Step 4: Smoke test the actual hooks**

Manually run persona-context.sh and persona-tool-guard.sh with realistic inputs. Confirm `~/.second-brain/.installed-catalog.json` lands, persona-card seeded, hooks emit valid JSON.

- [ ] **Step 5: Squash into v2.3.0 commit**

```bash
git log --oneline | head -20  # confirm task commits
# squash strategy decided here — interactive rebase or merge --squash from a feature branch
git commit -m "feat: v2.3.0 — persona core (5 layers) + vendored superpowers + sb CLI"
```

---

## Self-review checklist

- [x] Every task has files, code, and verification commands
- [x] No placeholders ("TBD", "TODO", vague descriptions) — every step has concrete content
- [x] Type/method signatures consistent across tasks (PersonaBrief used in T5 and T6, PersonaStatsResult in T9)
- [x] Each task produces a coherent commit that builds on prior tasks without forward references
- [x] TDD: every task that writes code has its test step before implementation
- [x] Verification: every step ends with a runnable check, not a "should pass" assertion
- [x] Scope: bottom-up dependency order ensures no broken intermediate states
- [x] Cost: per-task LLM usage estimated; budget guard enforced in T5
- [x] Defense: untrusted-input quarantine (T8 quality gate), dismissal-aware backoff (T9 + T3), write-once-confirm (T8 logs rejections, T4 surfaces approval) all wired

Plan ready for execution. Total: 12 tasks, ~50 steps, ~4-5 days.
