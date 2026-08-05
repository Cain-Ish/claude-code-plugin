import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'fs';
import { fileURLToPath } from 'url';

// Prose promises need machine locks. Locked here: every agent states its model
// explicitly (silent inherit is invisible drift); disallowedTools stays a plain
// whole-tool list (the harness collapses a pattern-scoped disallow into removing
// the ENTIRE tool); the maintain skill keeps its touch-set postflight and
// refused-not-repaired delegation packet; the raw-drainer keeps its
// packet-verification + blame-class contract.

const repoRoot = fileURLToPath(new URL('../../', import.meta.url));
const agentsDir = repoRoot + 'agents/';
const agentFiles = readdirSync(agentsDir).filter(f => f.endsWith('.md'));
const read = (p: string) => readFileSync(p, 'utf-8');
const frontmatter = (src: string): string =>
  (src.match(/^---\r?\n([\s\S]*?)\r?\n---/) ?? ['', ''])[1];

describe('agent frontmatter lints (directory-walked)', () => {
  it('sanity: found the agent definitions', () => {
    expect(agentFiles.length).toBeGreaterThan(0);
  });

  it('every agent frontmatter declares an explicit model: line', () => {
    // `inherit` is a valid explicit value — the lint forbids SILENCE, not inheritance.
    const missing = agentFiles.filter(
      f => !/^model:[ \t]*\S/m.test(frontmatter(read(agentsDir + f)))
    );
    expect(missing, `agent frontmatter missing an explicit model: line: ${missing.join(', ')}`).toEqual([]);
  });

  it('no disallowedTools: entry uses a pattern-scoped form (whole-tool names only)', () => {
    // `disallowedTools: Bash(curl *)` does NOT deny just curl — the harness collapses a
    // pattern-scoped disallow into removing the ENTIRE tool. Only plain comma-separated
    // whole-tool names are allowed, so what the line says is what the agent loses.
    const offenders: string[] = [];
    for (const f of agentFiles) {
      const m = frontmatter(read(agentsDir + f)).match(/^disallowedTools:[ \t]*(.*)$/m);
      if (!m) continue;
      const value = m[1].trim();
      if (/\(/.test(value)) offenders.push(`${f}: ${value}`);
      expect(
        value,
        `${f}: disallowedTools must be a plain comma-separated tool list, got: ${value}`
      ).toMatch(/^[A-Za-z_]\w*([ \t]*,[ \t]*[A-Za-z_]\w*)*$/);
    }
    expect(offenders, `pattern-scoped disallow (collapses to whole-tool removal): ${offenders.join(' | ')}`).toEqual([]);
  });
});

describe('SB_HOOK_PROFILE reaches every mapped kill switch (shim-or-source ordering)', () => {
  // lib.sh's minimal-profile block only maps flags read AFTER sourcing. A kill-switch
  // check that runs pre-source (or in a lib-less script) silently ignores the profile
  // unless the check site carries its own one-line SB_HOOK_PROFILE shim. Lock: for each
  // mapped (flag, script) pair, the first ${FLAG...} expansion must be preceded — by
  // character offset — by either a SB_HOOK_PROFILE shim or a `source ...lib.sh` line.
  const scriptsDir = repoRoot + 'scripts/';
  const pairs: Array<[flag: string, script: string]> = [
    ['SB_SAR_SUMMARY', 'sar-summary.sh'],
    ['SB_PLAN_FIRST_NUDGE', 'plan-first-nudge.sh'],
    ['SB_CRITIC_OFFER', 'stop-verify-gate.sh'],
    ['SB_INJECTION_SCAN', 'tool-return-scanner.sh'],
    ['SB_CONFIG_CHANGE_AUDIT', 'config-change-guard.sh'],
    ['SB_DREAM_AUTOSTAGE', 'dream-autostage.sh'],
    ['SB_LOOP_DEAD_BANNER', 'session-load.sh'],
    ['SB_CODEMAP_ORIENT', 'session-load.sh'],
    ['SB_INTENT_SPINE', 'persona-context.sh'],
    ['SB_INTENT_SPINE', 'plan-first-nudge.sh'],
    ['SB_INTENT_SPINE', 'persona-tool-guard.sh'],
    ['SB_INTENT_SPINE', 'stop-verify-gate.sh'],
    ['SB_OBSERVATION_LEDGER', 'observe-tool-use.sh'],
  ];

  for (const [flag, script] of pairs) {
    it(`${script}: ${flag} check sees the profile (shim or prior lib.sh source)`, () => {
      const src = read(scriptsDir + script);
      // First real usage = first parameter expansion of the flag ("${FLAG" — bare
      // comment mentions like "Kill switch: FLAG=off" don't count).
      const usage = src.indexOf('${' + flag);
      expect(usage, `${script} never expands \${${flag}} — pair stale?`).toBeGreaterThan(-1);
      const shim = src.indexOf('SB_HOOK_PROFILE');
      // Source forms in the tree: `source "$(dirname "$0")/lib.sh"` and
      // `if ! source "$PLUGIN_ROOT/scripts/lib.sh"` — nested quotes, so match
      // any same-line `source …lib.sh` rather than a quoted-path shape.
      const lib = src.search(/source [^\n]*lib\.sh/);
      const shimOk = shim !== -1 && shim < usage;
      const libOk = lib !== -1 && lib < usage;
      expect(
        shimOk || libOk,
        `${script}: first \${${flag}} use at offset ${usage} is reached before any ` +
          `SB_HOOK_PROFILE shim (${shim}) or lib.sh source (${lib}) — the minimal profile is dead for it`
      ).toBe(true);
    });
  }
});

describe('prose-contract locks (drain-loop delegation discipline)', () => {
  const skillSrc = () => read(repoRoot + 'skills/maintain/SKILL.md');
  const drainerSrc = () => read(agentsDir + 'raw-drainer.md');

  it('maintain skill carries the touch-set postflight contract', () => {
    // A drainer writing via Bash redirection bypasses the wiki-write PreToolUse guard;
    // the postflight is the only detector for a legacy-wiki misroute — losing the
    // prose loses the check.
    const src = skillSrc();
    expect(src).toContain('Touch-set postflight (REQUIRED after every batch)');
    expect(src).toContain('BLAME: child-under-delivered');
  });

  it('maintain skill carries the refused-not-repaired delegation packet', () => {
    // A dispatch missing a packet field must be REFUSED, never repaired by guessing —
    // guessed destinations are how pages land in the wrong wiki.
    expect(skillSrc()).toContain('REQUIRED delegation packet — refuse, never repair');
  });

  it('raw-drainer carries the packet-verification + blame-class contract', () => {
    const src = drainerSrc();
    expect(src).toContain('delegation packet');
    expect(src).toContain('BLAME: caller-under-supplied');
  });
});

describe('session intent spine locks', () => {
  const scriptsDir = repoRoot + 'scripts/';
  const pctx = () => read(scriptsDir + 'persona-context.sh');
  const nudge = () => read(scriptsDir + 'plan-first-nudge.sh');
  const guard = () => read(scriptsDir + 'persona-tool-guard.sh');
  const stopGate = () => read(scriptsDir + 'stop-verify-gate.sh');

  it('goal line is always-emit: present and never gated on a memo hash', () => {
    // The [Goal: …] line must re-inject VERBATIM every prompt (compaction survival);
    // routing it through the SHOW_* hash-dedup or memoizing a goal hash would
    // silently drop it exactly when it matters (unchanged goal = every turn).
    const src = pctx();
    expect(src).toContain('[Goal: ');
    expect(src).not.toMatch(/SHOW_\w+[^\n]*GOAL_LINE|GOAL_LINE[^\n]*SHOW_\w+/);
    expect(src).not.toMatch(/H_GOAL|goal_hash/i);
  });

  it('SB_INTENT_SPINE kill switch precedes the first spine action in every spine script', () => {
    // The switch must be checked BEFORE any spine work, per code path — offset
    // ordering against each script's distinctive spine marker.
    const cases: Array<[src: string, file: string, marker: string]> = [
      [pctx(), 'persona-context.sh', '[Goal: '],
      [nudge(), 'plan-first-nudge.sh', '.phase'],
      [guard(), 'persona-tool-guard.sh', '.phase'],
      [stopGate(), 'stop-verify-gate.sh', 'phase reached'],
    ];
    for (const [src, file, marker] of cases) {
      const kill = src.indexOf('${SB_INTENT_SPINE');
      const action = src.indexOf(marker);
      expect(kill, `${file}: no \${SB_INTENT_SPINE} check found`).toBeGreaterThan(-1);
      expect(action, `${file}: spine marker '${marker}' not found — lock stale?`).toBeGreaterThan(-1);
      expect(kill, `${file}: spine action at ${action} runs before the SB_INTENT_SPINE check at ${kill}`).toBeLessThan(action);
    }
  });

  it('gate literals: each deny names its exact retry path', () => {
    const src = nudge();
    expect(src).toContain('state the plan: goal, files in scope, verify command — then retry');
    expect(src).toContain('confirm scope change or return to goal — then retry');
    expect(stopGate()).toContain('phase reached');
  });

  it('spine emits permissionDecision only at the two defined deny points', () => {
    // Gate A + Gate B are the ONLY spine denies; the drift warn is additionalContext
    // only (an advisory must never widen permissions), the legacy advisory keeps its
    // single "allow", and nothing spine-side ever emits "ask".
    const src = nudge();
    expect((src.match(/permissionDecision: "deny"/g) ?? []).length).toBe(2);
    expect((src.match(/permissionDecision: "allow"/g) ?? []).length).toBe(1);
    expect(src).not.toMatch(/permissionDecision: "ask"/);
    // The other two spine touchpoints add no permission surface at all.
    expect(pctx()).not.toContain('permissionDecision');
    expect(stopGate()).not.toContain('permissionDecision');
    // persona-tool-guard: the phase-transition block (kill-switch check → closing
    // fi) must stay emission-free — it may never alter a guard verdict — and must
    // carry BOTH transitions (implement→verify flip, verify→implement revert).
    const g = guard();
    const flipStart = g.indexOf('${SB_INTENT_SPINE');
    expect(flipStart).toBeGreaterThan(-1);
    const flip = g.slice(flipStart, g.indexOf('\nfi\n', flipStart));
    expect(flip).not.toContain('permissionDecision');
    expect(flip).not.toContain('hookSpecificOutput');
    expect(flip).toContain("printf 'verify'");
    expect(flip).toContain("printf 'implement'");
  });

  it('slice-2 persistence: extractor field, merge consumer, and GC sweep stay paired', () => {
    // session_goal flows extract-prompt.txt → merge-project-update.sh → the
    // "## State" one-liner; a rename on either side silently kills the resume.
    expect(read(scriptsDir + 'extract-prompt.txt')).toContain('session_goal');
    const merge = read(scriptsDir + 'merge-project-update.sh');
    expect(merge).toContain('session_goal');
    expect(merge).toContain('last session goal: ');
    // The verify-gate anti-game marker must stay in the Stop-hook GC sweep.
    expect(read(scriptsDir + 'stop-extract.sh')).toContain(".verify-gate-agseen-*'");
  });
});

describe('project-first retrieval stays wired (prose + writer locks)', () => {
  // The 2026-08-05 audit found the project-first machinery disconnected at both ends:
  // no writer stamped project:, no skill instructed starting retrieval from the project
  // node. These locks keep both ends attached.
  const scriptsDir = repoRoot + 'scripts/';
  const skillsDir = repoRoot + 'skills/';

  it('retrieval skills instruct the project-first entry point', () => {
    expect(read(skillsDir + 'using-second-brain/SKILL.md')).toContain('## Project-first rule');
    expect(read(skillsDir + 'query/SKILL.md')).toContain('Project questions → start from the project node');
    // The Intent template scaffolded into USER.md carries the project-first step + axis.
    const setup = read(skillsDir + 'setup/SKILL.md');
    expect(setup).toContain('Start from the project, not the topic');
    expect(setup).toContain('plus the project axis');
  });

  it('write-time project: stamping stays in the extractor merge writer', () => {
    const merge = read(scriptsDir + 'merge-project-update.sh');
    // New wiki pages + the per-project decisions log both emit the facet.
    expect((merge.match(/printf 'project: %s\\n'/g) ?? []).length).toBeGreaterThanOrEqual(2);
    // Per-update override contract: explicit "project" key (incl. "" = global) wins.
    expect(merge).toContain(`jq -e 'has("project")'`);
    // Per-project decisions log (not the one shared global file).
    expect(merge).toContain('${PROJECT_SLUG}-decisions-log.md');
  });

  it('session-load seeds the graph brief from the project slug (CLI resolver, no bash twin)', () => {
    const sl = read(scriptsDir + 'session-load.sh');
    // The project slug must be the FIRST graph seed; registry→anchor resolution belongs
    // to the hardened TS resolver inside graph-neighbors-cli, never a jq reimplementation
    // in this script (one malformed registry line would silently kill later projects).
    expect(sl).toContain('GRAPH_SEEDS=$(printf \'%s\\n%s\\n\' "$slug" "$CR_SLUGS"');
    expect(sl).not.toMatch(/jq[^\n]*project-registry\.jsonl/);
  });
});
