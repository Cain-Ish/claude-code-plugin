// 06, section 4, 4a: the bytes probe, registered in 06 before each round. Round 2's arms, interleaved: F reads its
// input with readFileSync(0) as the hook does; C reads it in 64 KiB readSync chunks and logs its running count after
// each one, synchronously; C2 is C without the log. On a timeout of C, the parent compares the last count with the
// bytes it sent: all read (only the end of input missing) or partway.   node chunks.mjs <calls per arm> <out dir>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const N = Number(process.argv[2] ?? 300);
const out = process.argv[3] ?? fs.mkdtempSync(path.join(os.tmpdir(), 'chunks-out-'));
fs.mkdirSync(out, { recursive: true });
const LOOP = (log) => `/*PROBE_READER*/ const fs = require('fs'); const b = Buffer.alloc(65536); let n = 0, k;
while ((k = fs.readSync(0, b, 0, b.length, null)) > 0) { n += k;${log ? " fs.appendFileSync(process.env.PROGRESS, n + '\\n');" : ''} }
process.stdout.write(JSON.stringify({ n }));`;
const ARMS = {
  F: "/*PROBE_READER*/ const s = require('fs').readFileSync(0, 'utf8'); process.stdout.write(JSON.stringify({ n: Buffer.byteLength(s) }));",
  C: LOOP(true),
  C2: LOOP(false),
};
const lines80 = (n) => { let s = ''; while (s.length < n) s += `${'x'.repeat(79)}\n`; return s.slice(0, n); };
// H25n's input: the hook's JSON with a 25,000-character output in lines of 80
const input = JSON.stringify({ cwd: '/r', tool_input: { command: 'cat .project-map/captured.md' }, tool_response: { stdout: lines80(25_000), stderr: '', interrupted: false, isImage: false } });
const sent = Buffer.byteLength(input);
const res = Object.fromEntries(Object.keys(ARMS).map((k) => [k, { calls: 0, ok: 0, failed: 0, hangs: [] }]));
for (let i = 0; i < N; i++) {
  for (const [arm, script] of Object.entries(ARMS)) {
    const progress = path.join(out, `p-${arm}-${i}.txt`);
    const r = spawnSync(process.execPath, ['-e', script], { input, encoding: 'utf8', timeout: 15_000, killSignal: 'SIGKILL', env: { ...process.env, PROGRESS: progress } });
    const a = res[arm];
    a.calls++;
    if (r.error?.code === 'ETIMEDOUT') {
      let counts = [];
      try { counts = fs.readFileSync(progress, 'utf8').trim().split('\n').filter(Boolean).map(Number); } catch {}
      const read = counts.at(-1);
      a.hangs.push({ call: i, chunks: counts, kind: read === undefined ? 'not logged' : read === sent ? 'end missing' : 'partway' });
    } else if (r.status === 0 && JSON.parse(r.stdout).n === sent) a.ok++;
    else a.failed++;
    fs.rmSync(progress, { force: true });
  }
}
fs.writeFileSync(path.join(out, 'chunks.json'), `${JSON.stringify({ sent, ...res }, null, 1)}\n`);
for (const [arm, a] of Object.entries(res)) console.log(`${arm}: ${a.calls} calls, ${a.ok} ok, ${a.failed} failed, ${a.hangs.length} hangs${a.hangs.map((h) => `\n  call ${h.call}: chunks ${h.chunks.join(',') || '-'} of ${sent}: ${h.kind}`).join('')}`);
