// 06, section 3, S3, check 3: maps with format 3's lines (proposed, review, id, by <id>), near and past the cap.
//   node fuzz3.mjs <2.2.0 plugin dir> <S3 plugin dir> <maps> [seed]
// For each map, labels() of both builds on the same file, committed and not:
// - uncut output: each entry shows exactly the new labels its lines call for, and the rest of its labels are 2.2.0's
//   (2.2.0's grouped "unverified quote" line expanded per entry);
// - cut output: at most CAP characters, and an entry with a new label that is missing is covered by the closing line.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const [oldArg, newArg, mapsArg = '200', seedArg = '5'] = process.argv.slice(2);
const OLD = await import(pathToFileURL(path.join(path.resolve(oldArg), 'scripts', 'map.mjs')).href);
const NEW = await import(pathToFileURL(path.join(path.resolve(newArg), 'scripts', 'map.mjs')).href);
let seed = Number(seedArg);
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const pick = (a) => a[Math.floor(rnd() * a.length)];
const git = (cwd, ...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'core.autocrlf=false', ...a], { cwd, encoding: 'utf8' });
const W = 'grid avatar local cdn token colour page header order card list sort date format'.split(' ');
const words = (n) => Array.from({ length: n }, () => pick(W)).join(' ');
const today = new Date().toISOString().slice(0, 10);

function makeMap(n) {
  const ids = [];
  const out = [];
  for (let i = 0; i < n; i++) {
    const id = `e-${i}`;
    const hasId = rnd() < 0.7;
    if (hasId) ids.push(id);
    const lines = [`### ${words(2)} ${i}`, `> ${words(6)}.`, '', `- source: the lead developer, 2026-11-${String(1 + Math.floor(rnd() * 28)).padStart(2, '0')}`, `- when: ["${words(1)}"]`];
    const want = { proposed: null, due: null, missing: null };
    if (hasId) lines.push(`- id: ${id}`);
    if (rnd() < 0.3) { const d = '2026-11-19'; lines.push(`- proposed: dream ${d}`); want.proposed = d; }
    if (rnd() < 0.3) { const d = pick(['2001-02-03', '2999-04-05']); lines.push(`- review: ${d}`); if (d < today) want.due = d; }
    if (rnd() < 0.3) { const target = rnd() < 0.5 ? `e-${Math.floor(rnd() * n)}` : `gone-${i}`; lines.push(`- status: superseded 2026-11-19 by ${target}: ${words(3)}`); want.target = target; }
    if (rnd() < 0.2) lines.push(`- verified: 2026-11-19 restated by the PM`);
    out.push({ text: `${lines.join('\n')}\n`, want });
  }
  return { out, ids };
}
// per-entry label text, from a labels() output: "N. heading: a; b" lines, and the grouped line expanded
function perEntry(text) {
  const m = new Map();
  for (const line of text.split('\n')) {
    const g = /^unverified quote, committed: entries (.*)$/.exec(line);
    if (g) {
      for (const part of g[1].split(/,\s*(?=\d)/)) {
        const r = /^(\d+)(?:-(\d+))?(?: \(captured (\d{4}-\d{2}-\d{2})\))?$/.exec(part.trim());
        if (!r) continue;
        for (let k = Number(r[1]); k <= Number(r[2] ?? r[1]); k++) m.set(k, `unverified quote${r[3] ? `, captured ${r[3]}` : ''}`);
      }
      continue;
    }
    const e = /^(\d+)\. [^:]*?: (.*)$/.exec(line);
    if (e) m.set(Number(e[1]), e[2]);
  }
  return m;
}
const tail = (text) => { const t = /\((\d+) more labels? not shown: treat every entry after entry (\d+)|\((\d+) labels? not shown: treat every entry in this file/.exec(text); return t ? Number(t[2] ?? 0) : null; };

const base = fs.mkdtempSync(path.join(os.tmpdir(), 'sb-fuzz3-'));
let checks = 0, fails = 0, cuts = 0;
const fail = (msg) => { fails++; if (fails <= 8) console.log(`FAIL ${msg}`); };
for (let k = 0; k < Number(mapsArg); k++) {
  const dir = path.join(base, `m${k}`);
  fs.mkdirSync(path.join(dir, '.project-map'), { recursive: true });
  git(dir, 'init', '-q');
  const n = rnd() < 0.25 ? 120 + Math.floor(rnd() * 120) : 1 + Math.floor(rnd() * 30);
  const { out, ids } = makeMap(n);
  const F = '.project-map/decisions.md';
  fs.writeFileSync(path.join(dir, F), out.map((e) => e.text).join('\n'));
  for (const committed of [false, true]) {
    if (committed) { git(dir, 'add', '-A'); git(dir, 'commit', '-q', '-m', 'c'); }
    const a = OLD.labels(dir, F);
    const b = NEW.labels(dir, F);
    checks++;
    if (b.length > NEW.CAP) fail(`m${k} over the cap`);
    const cut = tail(b);
    if (cut !== null) cuts++;
    const pa = perEntry(a), pb = perEntry(b);
    out.forEach((e, i) => {
      const num = i + 1;
      const wantNew = [];
      if (e.want.proposed) wantNew.push(`proposed by a dream ${e.want.proposed}, not yet accepted`);
      if (e.want.due) wantNew.push(`review due since ${e.want.due}`);
      if (e.want.target && ids.length && !ids.includes(e.want.target)) wantNew.push(`replaced by ${e.want.target}, which the map does not hold`);
      const got = pb.get(num);
      if (got === undefined) {
        // not shown: fine when the cut covers it, or when it needs no label at all
        if (wantNew.length && !(cut !== null && num > cut)) fail(`m${k} entry ${num} (${committed ? 'committed' : 'uncommitted'}) lacks ${wantNew.join(' | ')}`);
        return;
      }
      for (const w of wantNew) if (!got.includes(w)) fail(`m${k} entry ${num} lacks "${w}": ${got}`);
      const extra = got.split('; ').filter((l) => /^(proposed by a dream|review due since|replaced by .*which the map does not hold)/.test(l));
      if (extra.length !== wantNew.length) fail(`m${k} entry ${num} has unasked new labels: ${got}`);
      // the rest is 2.2.0's, where 2.2.0's output shows the entry uncut
      const rest = got.split('; ').filter((l) => !extra.includes(l)).join('; ');
      const old = pa.get(num);
      if (old !== undefined && tail(a) === null && cut === null && rest !== old) fail(`m${k} entry ${num}: rest "${rest}" vs 2.2.0 "${old}"`);
    });
  }
  fs.rmSync(dir, { recursive: true, force: true });
}
fs.rmSync(base, { recursive: true, force: true });
console.log(`${checks} label outputs checked, ${cuts} cut, ${fails} failures`);
process.exit(fails ? 1 : 0);
