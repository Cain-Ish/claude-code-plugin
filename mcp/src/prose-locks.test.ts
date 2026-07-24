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
