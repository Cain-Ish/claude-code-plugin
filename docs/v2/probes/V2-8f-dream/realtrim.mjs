// 06, section 8, 8f, check 3: on the transcripts this repo's dream of 2026-11-25 read, the trimmed digests hold at
// least 60% fewer lines in all, and exactly as many U and Q lines as the full ones. Counts only: no session id, no
// line, no path is written. The sessions are taken from that dream's run record (its manifest's digested sessions).
//   node realtrim.mjs <plugin folder> <run.json> <Claude Code's projects folder>
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const [plugin, runJson, projects] = process.argv.slice(2).map((p) => path.resolve(p));
const D = await import(pathToFileURL(path.join(plugin, 'scripts', 'dream.mjs')).href);
const job = JSON.parse(fs.readFileSync(runJson, 'utf8'));
const where = (f) => fs.readdirSync(projects).map((d) => path.join(projects, d, f)).find((p) => fs.existsSync(p));
const rows = [];
for (const m of job.manifest.filter((x) => x.digest)) {
  const p = where(m.f);
  if (!p) { rows.push({ digest: m.digest, missing: true }); continue; }
  const dg = await D.digestFrom(p, 0, () => true, new Set());
  const { out } = D.trim(dg.lines, new Set(dg.mapAt.map((x) => x.idx)));
  const uq = (ls) => ls.filter((l) => /^(U|Q): /.test(l)).length;
  rows.push({ digest: m.digest, full: dg.lines.length, trimmed: out.length, uqFull: uq(dg.lines), uqTrimmed: uq(out), mapReads: dg.mapAt.length });
}
const full = rows.reduce((s, r) => s + (r.full ?? 0), 0), trimmed = rows.reduce((s, r) => s + (r.trimmed ?? 0), 0);
const res = { sessions: rows.length, missing: rows.filter((r) => r.missing).length, full, trimmed, cut: Math.round((1 - trimmed / full) * 1000) / 10, rows };
// 06, 8f, check 3's bars, fixed before any run
res.pass = { cut: trimmed <= 0.4 * full, typedKept: rows.every((r) => r.missing || r.uqFull === r.uqTrimmed), none_missing: res.missing === 0 };
res.pass.all = Object.values(res.pass).every(Boolean);
fs.mkdirSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'results'), { recursive: true });
fs.writeFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', process.env.RT_RESULT ?? 'realtrim.json'), `${JSON.stringify(res, null, 1)}\n`);
console.log(JSON.stringify({ ...res, rows: undefined }));
