// 06, section 3, S2 and S3: run two plugin builds' hooks over generated repos and compare their outputs.
//   node diff.mjs <old plugin dir> <new plugin dir> <repos> [seed]
// Prints each difference (hook, input, both outputs) and a count. Exit 1 on any difference.
// A repo: tracked documents, a map of 1-3 files with 1-40 entries each (person and file sources, sources in
// parentheses, status lines, a byte-order mark, UTF-16), some committed, some edited after the commit.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const [oldArg, newArg, reposArg = '30', seedArg = '1'] = process.argv.slice(2);
const [oldDir, newDir] = [oldArg, newArg].map((p) => path.resolve(p));
let seed = Number(seedArg);
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const pick = (a) => a[Math.floor(rnd() * a.length)];
const git = (cwd, ...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'core.autocrlf=false', ...a], { cwd, encoding: 'utf8' });
const put = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };

const WORDS = 'avatar load local cdn component folder style guide token colour grid spacing page header release notes past tense api error wrap date format user card order list member sort'.split(' ');
const phrase = (n) => Array.from({ length: n }, () => pick(WORDS)).join(' ');
const DOCS = ['docs/style.md', 'docs/grid.md', 'README.md', 'docs/api/errors.md'];
function entry(i, docText) {
  const doc = pick(DOCS);
  const quote = rnd() < 0.4 && docText[doc] ? docText[doc].split('\n').filter((l) => l.split(' ').length > 4)[0] ?? phrase(6) : `${phrase(5 + Math.floor(rnd() * 6))}.`;
  const date = `2026-1${Math.floor(rnd() * 2)}-${String(1 + Math.floor(rnd() * 28)).padStart(2, '0')}`;
  const src = pick([`the lead developer, ${date}`, `${doc}, ${date}`, `the PM (after ${doc}), ${date}`, `the designer, via ${doc}, ${date}`, `${doc} (section 2), ${date}`, date]);
  const status = rnd() < 0.15 ? `- status: ${pick(['superseded', 'narrowed', 'expired', 'done'])} ${date} by "${phrase(2)}": ${phrase(4)}\n` : '';
  return `### ${phrase(2)} ${i}\n> ${quote}\n\n- source: ${src}\n- when: ["${phrase(2)}"]\n${status}`;
}
function makeRepo(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  git(dir, 'init', '-q');
  const docText = {};
  for (const d of DOCS) { docText[d] = `# ${phrase(2)}\n\n${phrase(8)}.\n${phrase(7)}.\n`; put(path.join(dir, d), docText[d]); }
  put(path.join(dir, 'src', 'a.ts'), 'export const a = 1;\n');
  const files = Array.from({ length: 1 + Math.floor(rnd() * 3) }, (_, k) => `.project-map/${pick(['captured', 'decisions', 'ui', 'api'])}${k}.md`);
  const maps = {};
  for (const f of files) {
    const n = 1 + Math.floor(rnd() * (rnd() < 0.2 ? 160 : 40));
    maps[f] = Array.from({ length: n }, (_, i) => entry(i, docText)).join('\n');
  }
  const write = (f, s) => {
    const kind = rnd();
    put(path.join(dir, f), kind < 0.08 ? `﻿${s}` : s);
    if (kind > 0.95) fs.writeFileSync(path.join(dir, f), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(s, 'utf16le')]));
  };
  for (const [f, s] of Object.entries(maps)) write(f, s);
  git(dir, 'add', '-A');
  git(dir, 'commit', '-q', '-m', 'base');
  for (const f of files) if (rnd() < 0.6) write(f, `${maps[f]}\n${entry(999, docText)}`); // an uncommitted entry
  if (rnd() < 0.3) put(path.join(dir, DOCS[0]), `# changed\n\n${phrase(8)}.\n`); // a cited document drifts
  return files;
}
function hook(plugin, which, input, dir) {
  const env = { ...process.env, CLAUDE_PROJECT_DIR: dir, CLAUDE_PLUGIN_ROOT: plugin };
  const r = spawnSync('node', [path.join(plugin, 'scripts', 'hook.mjs'), which], { input: which === 'onboard' ? '' : JSON.stringify(input), encoding: 'utf8', env, cwd: dir });
  return `${r.status}|${r.stdout}|${r.stderr}`;
}

const base = fs.mkdtempSync(path.join(os.tmpdir(), 'sb-diff-'));
let diffs = 0;
let calls = 0;
for (let k = 0; k < Number(reposArg); k++) {
  const dir = path.join(base, `r${k}`);
  const files = makeRepo(dir);
  const sid = `diff-${k}`;
  const cases = [
    ['session-start', { session_id: sid, cwd: dir, source: 'startup', transcript_path: path.join(base, 't.jsonl') }],
    ['prompt', { session_id: sid, prompt: 'Create a UserAvatar component.' }],
    ['onboard', {}],
  ];
  for (const f of files) {
    cases.push(['read', { tool_input: { file_path: path.join(dir, f) } }]);
    const out = fs.readFileSync(path.join(dir, f)).toString('utf8');
    const cut = out.split('\n').slice(0, Math.floor(rnd() * 30)).join('\n');
    cases.push(['bash', { tool_input: { command: `cat ${f}` }, tool_response: { stdout: rnd() < 0.5 ? out : cut, stderr: '' } }]);
    cases.push(['bash-failure', { tool_input: { command: `grep -n x ${f}` }, error: `Exit code 1\n${cut}` }]);
  }
  for (const [which, input] of cases) {
    // the prompt hook consumes the epoch marker, so each build gets its own session-start first
    if (which === 'prompt') { hook(oldDir, 'session-start', cases[0][1], dir); }
    const a = hook(oldDir, which, input, dir);
    if (which === 'prompt') { hook(newDir, 'session-start', cases[0][1], dir); }
    const b = hook(newDir, which, input, dir);
    calls++;
    if (a !== b) { diffs++; if (diffs <= 5) console.log(`DIFF ${which} r${k}\n--- old\n${a.slice(0, 1500)}\n--- new\n${b.slice(0, 1500)}`); }
  }
}
fs.rmSync(base, { recursive: true, force: true });
console.log(`${calls} hook calls, ${diffs} differences`);
process.exit(diffs ? 1 : 0);
