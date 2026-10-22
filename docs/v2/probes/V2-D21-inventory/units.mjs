// What each logged build run added, per task, shuffled and without arm or run labels: the judge's input (V2-D21).
// Usage: node units.mjs <raw-dir> <out-dir>. Reads D20's private configs and run logs; writes private files only.
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const [raw, out] = process.argv.slice(2);
const SETS = [['d20-stage1.json', 'd20-stage1', 'native'], ['d20-stage2.json', 'd20-stage2/b', 'b'],
  ['d20-stage2.json', 'd20-stage2/d', 'd']];
const TASKS = ['P1-build', 'P2-build', 'R0-build'];

const atCommit = (t, rel) => {
  try { return execFileSync('git', ['-C', t.repo, 'show', `${t.commit}:${rel}`], { encoding: 'utf8', maxBuffer: 64 << 20, stdio: ['ignore', 'pipe', 'ignore'] }); }
  catch { return null; }
};

// Successful Write and Edit calls in order; a call whose result is an error (a deny, a failed match) changed nothing.
function opsOf(stream) {
  let cwd = null;
  const calls = [], failed = new Set();
  for (const l of fs.readFileSync(stream, 'utf8').split('\n')) {
    let m; try { m = JSON.parse(l); } catch { continue; }
    if (m.type === 'system' && m.cwd) cwd = m.cwd.replace(/\\/g, '/').replace(/\/$/, '') + '/';
    for (const b of Array.isArray(m.message?.content) ? m.message.content : []) {
      if (b.type === 'tool_result' && b.is_error) failed.add(b.tool_use_id);
      if (b.type === 'tool_use' && ['Write', 'Edit', 'MultiEdit'].includes(b.name)) calls.push(b);
    }
  }
  const rel = (fp) => {
    const n = fp.replace(/\\/g, '/');
    if (!cwd || !n.toLowerCase().startsWith(cwd.toLowerCase())) throw new Error(`write outside the run's tree in ${stream}`);
    return n.slice(cwd.length);
  };
  return calls.filter((b) => !failed.has(b.id)).map((b) => ({ name: b.name, path: rel(b.input.file_path), input: b.input }));
}

// A file's state after the run: new files as their final text, edited files as their successful hunks.
function additionsOf(t, ops) {
  const files = new Map();
  for (const op of ops) {
    if (!files.has(op.path)) {
      const base = atCommit(t, op.path);
      files.set(op.path, { path: op.path, existed: base !== null, text: base ?? '', hunks: [] });
    }
    const f = files.get(op.path);
    const edits = op.name === 'Write' ? null : op.name === 'Edit' ? [op.input] : op.input.edits;
    if (!edits) { f.text = op.input.content; f.rewritten = true; continue; }
    for (const e of edits) {
      f.text = e.replace_all ? f.text.split(e.old_string).join(e.new_string) : f.text.replace(e.old_string, () => e.new_string);
      f.hunks.push({ old: e.old_string, new: e.new_string });
    }
  }
  return [...files.values()].map((f) => f.existed && !f.rewritten
    ? { path: f.path, kind: 'edited', hunks: f.hunks }
    : { path: f.path, kind: f.existed ? 'rewritten' : 'new', text: f.text });
}

// Deterministic shuffle (mulberry32), so the labels are reproducible and carry no order.
const rng = (seed) => () => { seed = (seed + 0x6d2b79f5) | 0; let x = Math.imul(seed ^ (seed >>> 15), 1 | seed); x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x; return ((x ^ (x >>> 14)) >>> 0) / 2 ** 32; };

fs.mkdirSync(out, { recursive: true });
for (const task of TASKS) {
  const runs = [];
  let t;
  for (const [cf, dir, arm] of SETS) {
    t = JSON.parse(fs.readFileSync(`${raw}/${cf}`, 'utf8')).tasks.find((x) => x.id === task);
    const p = `${raw}/${dir}/${task}`;
    if (!fs.existsSync(`${p}.json`)) continue;
    for (const r of JSON.parse(fs.readFileSync(`${p}.json`, 'utf8')).runs) {
      if (r.invalid?.length) continue;
      runs.push({ source: `${arm}/run${r.run}`, additions: additionsOf(t, opsOf(`${p}/run${r.run}/stream.jsonl`)) });
    }
  }
  const next = rng(21);
  for (let i = runs.length - 1; i > 0; i--) { const j = Math.floor(next() * (i + 1)); [runs[i], runs[j]] = [runs[j], runs[i]]; }
  runs.forEach((r, i) => { r.label = `r${String(i + 1).padStart(2, '0')}`; });
  fs.writeFileSync(`${out}/units-${task}.json`, JSON.stringify({ task, prompt: t.prompt,
    runs: runs.map(({ label, additions }) => ({ label, additions })) }, null, 1));
  fs.writeFileSync(`${out}/key-${task}.json`, JSON.stringify(Object.fromEntries(runs.map((r) => [r.label, r.source])), null, 1));
  const size = fs.statSync(`${out}/units-${task}.json`).size;
  console.log(task, `${runs.length} runs`, `${runs.reduce((n, r) => n + r.additions.length, 0)} files`, `${Math.round(size / 1024)} KB`);
}
