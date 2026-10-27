// A synthetic repo of P2's shape for the load bench's Windows lane (06, step 2g). The counts are P2's at its pinned
// commit, and the git index is at least P2's size (1.02 MB); the content is generated. benchmap.mjs then writes the map.
//   node plugin/test/fixture.mjs <dir>
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { index } from '../scripts/map.mjs';

const [repo] = process.argv.slice(2);
const FILES = 8057, DIRS = 768, DOCS = 189, DOC_DIRS = 45, LARGEST = 30;
// shortcut: two document sizes that keep P2's total (about 2.4 MB) and its 30 largest (about 1.26 MB); P2's own size
// list if the bench ever needs more fidelity
const size = (i) => (i < LARGEST ? 42_000 : 7_360);
const dir = (k) => (k === 0 ? '.' : `src/feature-area-${k % 12}/shared-module-${k % 97}/component-part-${k}`);
const docName = (i) => (i === 0 ? 'README.md' : `design-notes-section-${i}.md`);
const words = ['the', 'project', 'keeps', 'each', 'part', 'in', 'its', 'own', 'place', 'and', 'names', 'it', 'once'];
// seeded, not periodic: a run of words from the middle of a document first occurs there, as in P2 (calibration, 2g)
const text = (i) => {
  let seed = 0x9e3779b9 ^ i;
  const rand = () => { seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t ^= t + Math.imul(t ^ (t >>> 7), 61 | t); return ((t ^ (t >>> 14)) >>> 0) / 2 ** 32; };
  let s = `# Section ${i}\n\n`;
  for (let w = 0; s.length < size(i); w++) s += words[Math.floor(rand() * words.length)] + ((w % 12 === 11) ? '.\n' : ' ');
  return s;
};
const put = (f, s) => { fs.mkdirSync(path.dirname(path.join(repo, f)), { recursive: true }); fs.writeFileSync(path.join(repo, f), s); };
const git = (...a) => { const r = spawnSync('git', ['-c', 'user.name=bench', '-c', 'user.email=bench@example.invalid', ...a], { cwd: repo, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); };

fs.rmSync(repo, { recursive: true, force: true });
fs.mkdirSync(repo, { recursive: true });
git('init', '-q');
for (let i = 0; i < DOCS; i++) put(path.posix.join(dir(i % DOC_DIRS), docName(i)), text(i));
for (let i = DOCS; i < FILES; i++) put(path.posix.join(dir(i % DIRS), `file-${i}.cs`), `// ${i}\n`);
git('add', '-A');
git('commit', '-q', '-m', 'fixture');

const tracked = spawnSync('git', ['ls-files'], { cwd: repo, encoding: 'utf8' }).stdout.split('\n').filter(Boolean);
const idx = index(repo);
console.log(JSON.stringify({ tracked: tracked.length, dirs: new Set(tracked.map((f) => path.posix.dirname(f))).size,
  indexDirs: idx.split('\n').length - 2, indexBytes: Buffer.byteLength(idx), gitIndexBytes: fs.statSync(path.join(repo, '.git', 'index')).size }));
