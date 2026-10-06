import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, utimesSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { runSb } from './sb.js';

// Loop liveness: `sb status` must answer "did the loops run?" in one read.
// Fallback branches are first-class here: every state file ABSENT must render a
// loud "never/ABSENT/none", not a blank — silence is exactly the failure mode
// this section exists to end.

let brain: string;
let knowledge: string;

beforeEach(() => {
  brain = mkdtempSync(join(tmpdir(), 'sb-live-'));
  knowledge = mkdtempSync(join(tmpdir(), 'sb-know-'));
});
afterEach(() => {
  rmSync(brain, { recursive: true, force: true });
  rmSync(knowledge, { recursive: true, force: true });
});

const status = async () => (await runSb(['status'], { brainDir: brain, knowledgeDir: knowledge })).stdout;

// A row with transcripts spawns bash for lib.sh sb_drain_cursor_map: 1.5-2.5 s alone on Git-Bash,
// past vitest's 5 s default when the whole suite (or a peer bash run) loads the box. The bound
// sits above the map's own 20 s SIGKILL so a slow map reports as itself, not as a test timeout.
describe('sb status — Loop liveness (P1.1)', { timeout: 30_000 }, () => {
  it('cold brain: every liveness row renders loud absence, exit 0', async () => {
    const out = await status();
    expect(out).toContain('Loop liveness:');
    expect(out).toContain('drainer last ran:    never');
    expect(out).toContain('last extraction:     never');
    expect(out).toContain('scheduler shim:      ABSENT');
    expect(out).toContain('newest dream:        none');
    expect(out).toContain('raw-inbox depth:     0 unprocessed');
  });

  it('stamped state renders ages, status, backlog and depth', async () => {
    // drainer health marker, 2h old
    const health = join(brain, '.extractor-health.json');
    writeFileSync(health, JSON.stringify({ status: 'ok', reason: 'drained 3 this run (0 failed)' }));
    const twoHoursAgo = new Date(Date.now() - 2 * 3600_000);
    utimesSync(health, twoHoursAgo, twoHoursAgo);
    // done-set: one ok covering a.txt's 2 lines, one corrupt line (must not blind the read), one
    // retry (never advances a cursor)
    writeFileSync(join(brain, '.extraction-state.jsonl'), [
      JSON.stringify({ basename: 'a.txt', ts: '2026-07-12T10:00:00Z', outcome: 'ok', from: 0, lines: 2 }),
      'NOT-JSON{{{',
      JSON.stringify({ basename: 'b.txt', ts: '2026-07-12T11:00:00Z', outcome: 'retry', from: 0, lines: 2 }),
    ].join('\n'));
    // transcripts: a.txt done, b.txt + c.txt pending → backlog 2 of 3
    mkdirSync(join(brain, 'transcripts'));
    for (const f of ['a.txt', 'b.txt', 'c.txt']) writeFileSync(join(brain, 'transcripts', f), 'l1\nl2\n');
    // shim present
    mkdirSync(join(brain, 'bin'));
    writeFileSync(join(brain, 'bin', 'sb-extract-drain.sh'), '#!/bin/bash\n');
    // one dream, completed
    mkdirSync(join(brain, 'dreams', 'drm_20260712T000000Z'), { recursive: true });
    writeFileSync(join(brain, 'dreams', 'drm_20260712T000000Z', 'status.json'), JSON.stringify({ status: 'completed' }));

    const out = await status();
    expect(out).toMatch(/drainer last ran: {4}\d+h ago \(ok: drained 3 this run/);
    expect(out).toContain('last extraction:     2026-07-12T11:00:00Z');
    expect(out).toContain('transcript backlog:  2 of 3 archived');
    expect(out).toContain('scheduler shim:      present');
    expect(out).toContain('newest dream:        drm_20260712T000000Z completed');
  });

  // R2 (0.56.0): the backlog comes from lib.sh sb_drain_cursor_map (line cursors). An archive
  // that GREW after its extraction holds unextracted lines; the old ok|error basename set called
  // it done forever.
  it('transcript backlog counts an archive that grew past its cursor', async () => {
    mkdirSync(join(brain, 'transcripts'));
    writeFileSync(join(brain, 'transcripts', 'grown.txt'), 'l1\nl2\nl3\nl4\n');
    writeFileSync(join(brain, 'transcripts', 'done.txt'), 'l1\nl2\n');
    writeFileSync(join(brain, '.extraction-state.jsonl'), [
      JSON.stringify({ basename: 'grown.txt', ts: '2026-07-12T10:00:00Z', outcome: 'ok', from: 0, lines: 2 }),
      JSON.stringify({ basename: 'done.txt', ts: '2026-07-12T10:00:00Z', outcome: 'ok', from: 0, lines: 2 }),
    ].join('\n') + '\n');
    const out = await status();
    expect(out).toContain('transcript backlog:  1 of 2 archived');
  });

  it('transcript backlog fails loud when the cursor map cannot run', async () => {
    mkdirSync(join(brain, 'transcripts'));
    writeFileSync(join(brain, 'transcripts', 'a.txt'), 'l1\n');
    const noRoot = mkdtempSync(join(tmpdir(), 'sb-noroot-'));
    try {
      const r = await runSb(['status'], { brainDir: brain, knowledgeDir: knowledge, pluginRoot: noRoot });
      expect(r.exitCode).toBe(0);
      // The whole reason, not its first 40 characters: the temp path alone is longer than that on
      // every OS, so a short cap hid which file was missing.
      expect(r.stdout).toMatch(
        /transcript backlog: {2}unknown \(drain cursor map unavailable: exit 1: .*scripts\/lib\.sh: No such file or directory\)/);
    } finally {
      rmSync(noRoot, { recursive: true, force: true });
    }
  });

  // R2 fix round: the failure reason must say what happened. A stub lib.sh stands in for the real
  // one (pluginRoot), so each failure mode is produced for real by bash.
  describe('cursor map failure reasons', () => {
    let stubRoot: string;
    beforeEach(() => {
      mkdirSync(join(brain, 'transcripts'));
      writeFileSync(join(brain, 'transcripts', 'a.txt'), 'l1\n');
      stubRoot = mkdtempSync(join(tmpdir(), 'sb-stubroot-'));
      mkdirSync(join(stubRoot, 'scripts'));
    });
    afterEach(() => rmSync(stubRoot, { recursive: true, force: true }));
    const stub = (body: string) => writeFileSync(join(stubRoot, 'scripts', 'lib.sh'), `sb_drain_cursor_map() {\n${body}\n}\n`);
    const reasonOf = (stdout: string) =>
      stdout.split('\n').find(l => l.includes('transcript backlog:'))?.match(/drain cursor map unavailable: (.*)\)$/)?.[1];

    it('a timeout says so, even when bash had already written to stderr', async () => {
      stub("  echo 'reading the done-set' >&2\n  sleep 10");
      const t0 = Date.now();
      const r = await runSb(['status'], { brainDir: brain, knowledgeDir: knowledge, pluginRoot: stubRoot, drainMapTimeoutMs: 1000 });
      expect(Date.now() - t0).toBeLessThan(8000);
      expect(r.exitCode).toBe(0);
      expect(reasonOf(r.stdout)).toBe('timed out after 1 s');
    }, 15000);

    it('output over the buffer cap is named, not reported as a timeout', async () => {
      stub(`  awk 'BEGIN { s = sprintf("%1000s", ""); for (i = 0; i < 9000; i++) print s }'`);
      const r = await runSb(['status'], { brainDir: brain, knowledgeDir: knowledge, pluginRoot: stubRoot });
      expect(reasonOf(r.stdout)).toBe('output over 8 MB');
    }, 15000);

    it('a long multi-line stderr becomes one printable line, capped', async () => {
      stub(`  printf '%s\\n' '\x1b[31mfirst line' 'second line ${'E'.repeat(300)}' >&2\n  return 3`);
      const r = await runSb(['status'], { brainDir: brain, knowledgeDir: knowledge, pluginRoot: stubRoot });
      const reason = reasonOf(r.stdout);
      expect(reason).toMatch(/^exit 3: \[31mfirst line second line E{20,}\.\.\.$/);
      expect(reason!.length).toBeLessThanOrEqual(160);
      expect(reason).not.toMatch(/[^\x20-\x7e]/);
    });
  });

  it('utilization renders top counts + the dormant-capability report (P1.3)', async () => {
    writeFileSync(join(brain, 'utilization-counts.json'), JSON.stringify({
      'skill:second-brain:query': { count: 7, last_used: '2026-07-13T00:00:00Z' },
      'agent:second-brain:raw-drainer': { count: 2, last_used: '2026-07-13T00:00:00Z' },
    }));
    const out = await status();
    expect(out).toContain('Utilization:');
    expect(out).toContain('skill:second-brain:query: 7');
    // dev run resolves the real repo root → real skills/agents catalog: the used
    // pair must NOT be dormant, everything else is.
    expect(out).toMatch(/dormant: \d+ of \d+ shipped capabilities/);
    expect(out).not.toMatch(/dormant: .*second-brain:query/);
  });

  it('corrupt counts store renders empty (loud fallback), dormant report survives', async () => {
    writeFileSync(join(brain, 'utilization-counts.json'), 'NOT-JSON{{{');
    const out = await status();
    expect(out).toContain('(no invocations recorded yet)');
    expect(out).toMatch(/dormant: \d+ of \d+ shipped capabilities/);
  });

  it('raw-inbox depth sums unprocessed items across projects', async () => {
    // one .md per item (raw-inbox.ts layout): r1 unprocessed + r2 processed → depth 1
    const raw = join(brain, 'projects', 'demo', 'raw');
    mkdirSync(raw, { recursive: true });
    // content_type is REQUIRED for well-formed (missing → malformed → counts as
    // unprocessed by design); r2 must be fully well-formed to be excluded.
    writeFileSync(join(raw, 'r1.md'), '---\nsource: t\ncaptured_at: 2026-07-12\ncontent_type: note\nstatus: unprocessed\n---\nbody\n');
    writeFileSync(join(raw, 'r2.md'), '---\nsource: t\ncaptured_at: 2026-07-12\ncontent_type: note\nstatus: processed\n---\nbody\n');
    const out = await status();
    expect(out).toContain('raw-inbox depth:     1 unprocessed');
  });
});
