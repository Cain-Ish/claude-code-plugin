// 06, section 8, 8a, before S7's check 2: what D-3's redaction changes in the digests of S7's history sessions. Read
// only: each run repo's transcripts through the candidate's digestFrom, then the same redaction prepare applies (copied
// here, since prepare would take the lock in the counted repos). Counts only.
//   node preflight8a.mjs <candidate plugin> <S7 scratch folder>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const [plugin, scratch] = process.argv.slice(2).map((p) => path.resolve(p));
const { digestFrom, PRIVATE } = await import(pathToFileURL(path.join(plugin, 'scripts', 'dream.mjs')).href);
// as dream.mjs's redact (8a attempt 3); a mismatch with the product shows as a difference in the counts' check below
const ALL = new RegExp(`(?:${PRIVATE.source})\\S*`, 'gi');
const redact = (l) => l.replace(/begin [a-z ]*private key.*/i, '[private]').replace(ALL, '[private]');
const src = fs.readFileSync(path.join(plugin, 'scripts', 'dream.mjs'), 'utf8');
if (!src.includes("const redact = (l) => l.replace(/begin [a-z ]*private key.*/i, '[private]').replace(PRIVATE_ALL, '[private]');")) throw new Error('the product redaction differs from this copy');
const KEY = [/formatDate/i, /changelog/i, /pnpm/i];
const out = { runs: 0, transcripts: 0, lines: {}, changed: {}, keyLines: 0, keyLinesChanged: 0 };
const enc = (p) => p.replace(/[^A-Za-z0-9]/g, '-');
for (const d of fs.readdirSync(scratch).filter((x) => /^run-\d+$/.test(x))) {
  const repo = fs.realpathSync.native(path.join(scratch, d, 'repo'));
  const tdir = path.join(os.homedir(), '.claude', 'projects', enc(repo));
  if (!fs.existsSync(tdir)) continue;
  out.runs++;
  for (const f of fs.readdirSync(tdir).filter((x) => x.endsWith('.jsonl'))) {
    out.transcripts++;
    const dg = await digestFrom(path.join(tdir, f), 0, () => true);
    for (const l of dg.lines) {
      const t = l.slice(0, l.indexOf(':'));
      out.lines[t] = (out.lines[t] ?? 0) + 1;
      const r = redact(l);
      if (r !== l) out.changed[t] = (out.changed[t] ?? 0) + 1;
      if (/^(U|Q):/.test(l) && KEY.some((k) => k.test(l))) { out.keyLines++; if (r !== l) out.keyLinesChanged++; }
    }
  }
}
out.pass = out.runs === 10 && out.keyLines > 0 && out.keyLinesChanged === 0;
const res = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', 'preflight8a.json');
fs.writeFileSync(res, `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out));
