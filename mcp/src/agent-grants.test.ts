import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'fs';
import { fileURLToPath } from 'url';

// repo-root/agents/ resolved from mcp/src/ — directory-walked, not a hardcoded list,
// so a NEW agent added later with an over-broad grant is caught too. (Spec P6 / P6a.)
const agentsDir = fileURLToPath(new URL('../../agents/', import.meta.url));
const agentFiles = readdirSync(agentsDir).filter(f => f.endsWith('.md'));
const read = (f: string) => readFileSync(agentsDir + f, 'utf-8');

// The ONLY node grant any agent may hold: the plugin's own bundled CLIs under mcp/dist.
const SCOPED_NODE = 'Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)';

const toolsLine = (src: string): string => (src.match(/^tools:[ \t]*(.*)$/m) ?? ['', ''])[1];
const bashGrants = (src: string): string[] =>
  [...toolsLine(src).matchAll(/Bash\([^)]*\)/g)].map(x => x[0]);

describe('agent tool grants (P6a least-privilege, directory-walked)', () => {
  it('sanity: found the agent definitions', () => {
    expect(agentFiles.length).toBeGreaterThan(0);
  });

  it('no agent grants node execution outside the scoped bundled-CLI path', () => {
    // Catches Bash(node *), Bash(node ${CLAUDE_PLUGIN_ROOT}/*) (whole plugin), or any other
    // node grant that is not exactly the mcp/dist scope — plus blanket Bash(*) / bare Bash,
    // which would re-open arbitrary node/shell execution.
    const offenders: string[] = [];
    for (const f of agentFiles) {
      for (const g of bashGrants(read(f))) {
        if (/^Bash\(node\b/.test(g) && g !== SCOPED_NODE) offenders.push(`${f}: ${g}`);
        if (g === 'Bash(*)') offenders.push(`${f}: ${g}`);
      }
      if (/(^|,)[ \t]*Bash[ \t]*(,|$)/.test(toolsLine(read(f)))) offenders.push(`${f}: bare Bash`);
    }
    expect(offenders, `over-broad node/shell grants: ${offenders.join(' | ')}`).toEqual([]);
  });

  it('every node command in an agent body targets ${CLAUDE_PLUGIN_ROOT}/mcp/dist/', () => {
    // Command-form only (`node "$CLAUDE_PLUGIN_ROOT/<path>` or `node ${CLAUDE_PLUGIN_ROOT}/<path>`),
    // so prose like "wiki node" is not matched. Guards drift where a body adds an in-scope-granted
    // node call that points outside mcp/dist.
    const re = /\bnode[ \t]+"?\$\{?CLAUDE_PLUGIN_ROOT\}?\/([^"\s`]+)/g;
    const offenders: string[] = [];
    for (const f of agentFiles) {
      for (const m of read(f).matchAll(re)) {
        if (!m[1].startsWith('mcp/dist/')) offenders.push(`${f}: node …/${m[1]}`);
      }
    }
    expect(offenders, `node calls outside mcp/dist: ${offenders.join(' | ')}`).toEqual([]);
  });

  it('agents that run node in their body carry the scoped grant', () => {
    for (const f of agentFiles) {
      const src = read(f);
      const runsNode = /\bnode[ \t]+"?\$\{?CLAUDE_PLUGIN_ROOT\}?\/mcp\/dist\//.test(src);
      if (runsNode) {
        expect(src, `${f} runs node in body but lacks the scoped grant`).toContain(SCOPED_NODE);
      }
    }
  });
});
