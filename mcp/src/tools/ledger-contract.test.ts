import { describe, it, expect } from 'vitest';
import { execFileSync } from 'child_process';
import { mkdtempSync, readFileSync, rmSync } from 'fs';
import { join, dirname } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';
import { recordOpusLedger } from './persona-think.js';

// CROSS-WRITER CONTRACT (Contract A — the shared premium-spend ledger).
// Two INDEPENDENT writers append to the same `opus-budget.json`:
//   - second-brain: recordOpusLedger() in persona-think.ts (TypeScript)
//   - cost-router:  ob_record in cost-router/scripts/opus-budget.sh (bash/jq)
// Nothing enforced that they emit the same fields, so a field added to one
// would be silently dropped by the other's reader (deep-dive D3 finding). This
// test runs BOTH real writers and asserts their on-disk key sets are identical —
// the oracle is the actual JSON each produces, not a re-read through either's
// own code. Drift now fails CI instead of degrading the banner silently.

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const OPUS_BUDGET_SH = join(REPO_ROOT, 'cost-router', 'scripts', 'opus-budget.sh');

function sortedKeys(path: string): string[] {
  return Object.keys(JSON.parse(readFileSync(path, 'utf-8'))).sort();
}

describe('premium-spend ledger — cross-writer field contract', () => {
  it('the TS and bash writers emit the IDENTICAL key set', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'ledger-contract-'));
    try {
      // --- TS writer (second-brain) ---
      const tsLedger = join(dir, 'ts-budget.json');
      await recordOpusLedger(tsLedger, 1000, 2000);
      const tsKeys = sortedKeys(tsLedger);

      // --- bash writer (cost-router) ---
      const bashLedger = join(dir, 'bash-budget.json');
      execFileSync('bash', [OPUS_BUDGET_SH, 'record', '1.5'], {
        env: { ...process.env, COST_ROUTER_LEDGER: bashLedger },
      });
      const bashKeys = sortedKeys(bashLedger);

      const CANON = ['date', 'opus_calls', 'opus_cost_usd'];
      expect(tsKeys).toEqual(CANON);        // absolute floor, not just "they match each other"
      expect(bashKeys).toEqual(CANON);
      expect(tsKeys).toEqual(bashKeys);     // and they agree
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
