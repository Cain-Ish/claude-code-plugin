// The load bench's map file (V2-D16's load shape): 30 entries, each quoting word for word a run of 8 words from a
// different document, the repo's 30 largest by bytes. Writes <repo>/.project-map/captured.md; prints counts only.
//   node plugin/test/benchmap.mjs <repo>
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { labels } from '../scripts/map.mjs';

const [repo] = process.argv.slice(2);
const DOC = /\.(md|mdx|markdown|txt|rst)$/i;
// the plugin's own tokenizer (map.mjs), so every quote is found as the read hook re-finds it
const words = (s) => String(s).toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
const docs = spawnSync('git', ['ls-files', '-z'], { cwd: repo, encoding: 'utf8', maxBuffer: 64 << 20 }).stdout.split('\0')
  .filter((f) => DOC.test(f) && /^[\w./-]+$/.test(f) && !f.startsWith('.project-map/'))
  .map((f) => ({ f, n: fs.statSync(path.join(repo, f)).size })).sort((a, b) => b.n - a.n || a.f.localeCompare(b.f)).slice(0, 30);
const entry = ({ f }, i) => {
  const w = words(fs.readFileSync(path.join(repo, f), 'utf8'));
  return `### area ${i}\n> ${w.slice(Math.floor(w.length / 2), Math.floor(w.length / 2) + 8).join(' ')}\n\n- source: ${f}, 2026-10-20\n- when: ["bench"]\n`;
};
fs.mkdirSync(path.join(repo, '.project-map'), { recursive: true });
fs.writeFileSync(path.join(repo, '.project-map', 'captured.md'), docs.map(entry).join('\n'));
const l = labels(repo, '.project-map/captured.md');
console.log(JSON.stringify({ entries: docs.length, citedBytes: docs.reduce((a, d) => a + d.n, 0), notFound: (l.match(/not found/g) ?? []).length }));
