import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'fs';
import { fileURLToPath } from 'url';
import { stripFrontmatter } from './tools/frontmatter.js';

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

  // Finding B: the maintainer/drainer protocols CALL knowledge_* MCP tools
  // (Phase 1 validate, Phase 2 search, Phase 3 relate/neighbors, Phase 5
  // reindex; drain steps search+validate). With `tools:` specified, unlisted
  // tools are unavailable at runtime, so the agent silently skips the step or
  // improvises. Lock the required grants so the gap can't reopen.
  const MCP = (t: string) => `mcp__plugin_second-brain_knowledge-base__${t}`;
  const REQUIRED_MCP: Record<string, string[]> = {
    'knowledge-maintainer.md': ['knowledge_validate', 'knowledge_search', 'knowledge_relate', 'knowledge_neighbors', 'knowledge_reindex'],
    'raw-drainer.md': ['knowledge_search', 'knowledge_validate'],
  };
  it('maintainer/drainer grant every knowledge_* MCP tool their protocol calls', () => {
    const missing: string[] = [];
    for (const [f, tools] of Object.entries(REQUIRED_MCP)) {
      const line = toolsLine(read(f));
      for (const t of tools) if (!line.includes(MCP(t))) missing.push(`${f}: ${MCP(t)}`);
    }
    expect(missing, `agent protocol calls an MCP tool it does not grant: ${missing.join(' | ')}`).toEqual([]);
  });

  // Security commitment (P6 data-never-instructions): the three consolidation
  // agents ingest untrusted transcript/captured/wiki content on every run and
  // must carry the explicit "DATA, not instructions" framing so a poisoned
  // memory cannot hijack consolidation via an embedded imperative.
  const UNTRUSTED_CONSUMERS = ['knowledge-maintainer.md', 'raw-drainer.md', 'dream-runner.md'];
  it('consolidation agents carry the data-not-instructions framing', () => {
    const missing = UNTRUSTED_CONSUMERS.filter(f => !/DATA, not instructions/i.test(read(f)));
    expect(missing, `untrusted-content consumer lacks the data-not-instructions line: ${missing.join(', ')}`).toEqual([]);
  });

  // Surface lock: the consolidation agents' unused git grants were dropped (git
  // appeared only in their tools line, never in a protocol step). Keep them out.
  // Scoped to the three consolidation agents ONLY — the code-review family
  // (history-reviewer, scorer, unit-reviewer, quality-reviewer, premise) grants
  // Bash(git *) legitimately (they blame/diff/log the change under review).
  it('consolidation agents carry no Bash(git *) grant (unused there)', () => {
    const offenders: string[] = [];
    for (const f of UNTRUSTED_CONSUMERS) {
      for (const g of bashGrants(read(f))) if (/^Bash\(git\b/.test(g)) offenders.push(`${f}: ${g}`);
    }
    expect(offenders, `consolidation agent has an unused git grant: ${offenders.join(' | ')}`).toEqual([]);
  });

  // The two code-review agents whose LENS uses code
  // structure — the per-unit reviewer follows cross-file imports (its "highest
  // value" §3), the quality reviewer judges coupling/architecture — carry the
  // read-only code_map + code_neighbors grants so they query blast radius instead
  // of re-deriving structure by hand. Scoped to these two ON PURPOSE: the
  // history reviewer (git-blame lens) and premise reviewer (runtime-env lens) are
  // orthogonal to the import graph, and the wiki drainer never reads code — a
  // code-structure grant there would be an UNUSED grant against P6a least-privilege.
  const REQUIRED_CODEMAP = ['code-review-unit-reviewer.md', 'quality-reviewer.md'];
  it('code-structure reviewers grant read-only code_map + code_neighbors', () => {
    const missing: string[] = [];
    for (const f of REQUIRED_CODEMAP) {
      const line = toolsLine(read(f));
      for (const t of ['code_map', 'code_neighbors']) if (!line.includes(MCP(t))) missing.push(`${f}: ${MCP(t)}`);
    }
    expect(missing, `orient-rung reviewer missing a code-map grant: ${missing.join(' | ')}`).toEqual([]);
  });
  it('granted reviewers actually USE the code map in their protocol (effect, not presence)', () => {
    // The grant is worthless if the body never calls it (the 0.33.9/0.33.11
    // presence-vs-effect audit class). Test the BODY with the frontmatter stripped —
    // the tools: grant itself contains the substring, so matching the whole file
    // would be a tautology that can never fail while the parity test passes
    // (review finding, 0.33.35).
    const body = (f: string) => stripFrontmatter(read(f));
    const missing = REQUIRED_CODEMAP.filter(f => !/code_neighbors/.test(body(f)));
    expect(missing, `agent grants code_neighbors but its protocol never uses it: ${missing.join(', ')}`).toEqual([]);
  });

  // No agent may grant a sub-agent DISPATCH tool. Subagents cannot nest (platform
  // dispatch-depth cap = 1) and a reviewer/consolidation agent that could spawn more
  // agents breaks both that cap and the fresh-context/independent-critique guarantee.
  // Empty whitelist, directory-walked — a future agent added with such a grant fails here.
  it('every agent declares an explicit tools: line (omitting it inherits ALL tools, incl. Task)', () => {
    // Without this, the dispatch lock below passes VACUOUSLY for an agent with no
    // tools: line — which is the WORST case: default-inherit grants everything
    // (review finding, 0.33.35).
    const missing = agentFiles.filter(f => toolsLine(read(f)).trim() === '');
    expect(missing, `agent file missing a tools: line (inherits all tools): ${missing.join(', ')}`).toEqual([]);
  });
  it('no agent grants Agent/Task/Skill (no recursive dispatch)', () => {
    const offenders: string[] = [];
    for (const f of agentFiles) {
      const line = toolsLine(read(f));
      for (const t of ['Agent', 'Task', 'Skill']) {
        // comma/start-bounded token match; `(\\(|,|$)` also catches the scoped form
        // `Skill(foo)` / `Task(...)` — the same specifier syntax as Bash(git *) —
        // which a bare `(,|$)` boundary let through (review finding, 0.33.35).
        // Substrings inside longer tool names (or prose) still don't match.
        if (new RegExp(`(^|,)\\s*${t}\\s*(\\(|,|$)`).test(line)) offenders.push(`${f}: ${t}`);
      }
    }
    expect(offenders, `agent grants a recursive-dispatch tool: ${offenders.join(' | ')}`).toEqual([]);
  });
});
