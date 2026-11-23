// 06, section 4, 4a: the bytes probe, registered in 06 before it ran. A child reads its input in 64 KiB chunks and
// logs its running count after each one, synchronously; on a timeout the parent compares the last count with the bytes
// it sent: all read (only the end of input missing) or partway.   node chunks.mjs <calls> <out dir>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const N = Number(process.argv[2] ?? 300);
const out = process.argv[3] ?? fs.mkdtempSync(path.join(os.tmpdir(), 'chunks-out-'));
fs.mkdirSync(out, { recursive: true });
const READER = `/*PROBE_READER*/ const fs = require('fs'); const b = Buffer.alloc(65536); let n = 0, k;
while ((k = fs.readSync(0, b, 0, b.length, null)) > 0) { n += k; fs.appendFileSync(process.env.PROGRESS, n + '\\n'); }
process.stdout.write(JSON.stringify({ n }));`;
const lines80 = (n) => { let s = ''; while (s.length < n) s += `${'x'.repeat(79)}\n`; return s.slice(0, n); };
// H25n's input: the hook's JSON with a 25,000-character output in lines of 80
const input = JSON.stringify({ cwd: '/r', tool_input: { command: 'cat .project-map/captured.md' }, tool_response: { stdout: lines80(25_000), stderr: '', interrupted: false, isImage: false } });
const sent = Buffer.byteLength(input);
const res = { calls: 0, ok: 0, failed: 0, sent, hangs: [] };
for (let i = 0; i < N; i++) {
  const progress = path.join(out, `p${i}.txt`);
  const r = spawnSync(process.execPath, ['-e', READER], { input, encoding: 'utf8', timeout: 15_000, killSignal: 'SIGKILL', env: { ...process.env, PROGRESS: progress } });
  res.calls++;
  if (r.error?.code === 'ETIMEDOUT') {
    let counts = [];
    try { counts = fs.readFileSync(progress, 'utf8').trim().split('\n').filter(Boolean).map(Number); } catch {}
    const last = counts.at(-1) ?? 0;
    res.hangs.push({ call: i, chunks: counts, read: last, kind: last === sent ? 'end missing' : 'partway' });
  } else if (r.status === 0 && JSON.parse(r.stdout).n === sent) res.ok++;
  else res.failed++;
  fs.rmSync(progress, { force: true });
}
fs.writeFileSync(path.join(out, 'chunks.json'), `${JSON.stringify(res, null, 1)}\n`);
console.log(JSON.stringify({ ...res, hangs: res.hangs.length }), '\n', res.hangs.map((h) => `call ${h.call}: read ${h.read} of ${sent} in chunks ${h.chunks.join(',')}: ${h.kind}`).join('\n'));
