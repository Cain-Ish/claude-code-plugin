import { describe, it, expect } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';

// repo-root/agents/ resolved from mcp/src/
const agentsDir = fileURLToPath(new URL('../../agents/', import.meta.url));
const read = (f: string) => readFileSync(agentsDir + f, 'utf-8');

// Consolidation agents read untrusted transcript content; an unscoped Bash(node *)
// grant is arbitrary-Node execution (RCE/exfil). They invoke Node only as bundled
// CLIs under mcp/dist/, so the grant must be scoped to that path. (Spec P6 / P6a.)
const NODE_USERS = ['raw-drainer.md', 'knowledge-maintainer.md'];
const ALL = [...NODE_USERS, 'dream-runner.md'];

describe('consolidation agent grants (P6a least-privilege)', () => {
  it('no consolidation agent grants unscoped Bash(node *)', () => {
    const offenders = ALL.filter(f => read(f).includes('Bash(node *)'));
    expect(offenders, `unscoped node grant in: ${offenders.join(', ')}`).toEqual([]);
  });

  it('Node-using agents grant only the scoped bundled-CLI form', () => {
    for (const f of NODE_USERS) {
      expect(read(f), `${f} missing scoped node grant`)
        .toContain('Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)');
    }
  });
});
