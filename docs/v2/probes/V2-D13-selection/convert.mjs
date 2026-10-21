// V2-D13 attempt 2, and D15's prototype bootstrap: a blind converter. Each doc file's map blocks go, numbered, to
// a fresh Sonnet call with no tools and no settings, which returns the file's rules as entries with an area and
// applies-when terms. It reads only the maps (built by `select.mjs map`), never the tasks or the cards. Output goes
// next to the private config (d13/entries/); select.mjs score2 scores it.
//   node convert.mjs selftest
//   node convert.mjs pilot <config>          one file per repo (its median-sized doc), cost projected from bytes
//   node convert.mjs run   <config> [jobs]   every doc file; resumes, skipping parts already converted
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

const MODEL = 'claude-sonnet-5-5';
const PART_MAX = 40 * 1024;
const SYS = `You turn one documentation file of a software project into rule entries for a project map. The map later
shows a coding assistant the rules that bind its current task, so each entry must say when it applies.

Input: the file's path, then its blocks, each numbered [n] with its heading path.

Output: only a JSON array, no prose, no code fence. One object per rule:
{"blocks":[n,...],"quote":"...","area":"...","when":["...","..."]}
- A rule is anything that tells someone working on this project what to do, not do, or stay consistent with:
  conventions, constraints, decisions, requirements, design or content rules, and facts the work must not
  contradict. Skip history, narrative and explanation that binds nothing.
- quote: the rule in the file's own words, trimmed to what binds. Mark each cut with "…". Never reword. At most
  300 characters.
- blocks: the numbers of the blocks the quote comes from.
- area: a short name for the part of the project the rule governs, in the project's own terms.
- when: 3 to 8 short terms or phrases for the tasks or files the rule applies to (kinds of work, things being made
  or changed, paths or file types).
- A file with no rules gives [].`;

export function parts(blocks) {
  const out = [];
  let cur = [];
  let size = 0;
  for (const b of blocks) {
    const n = Buffer.byteLength(b.e.text);
    if (cur.length && size + n > PART_MAX) { out.push(cur); cur = []; size = 0; }
    cur.push(b);
    size += n;
  }
  return cur.length ? [...out, cur] : out;
}

export const message = (file, part) => `File: ${file}\n\n${part.map((b, k) => `[${k + 1}] ${b.e.heads.join(' › ') || '(top)'}\n${b.e.text}`).join('\n\n')}`;

// Keeps only well-formed entries, with block numbers mapped back to the map's indexes.
export function parse(text, part) {
  const s = String(text).trim().replace(/^```(?:json)?\s*|\s*```$/g, '');
  const arr = JSON.parse(s.slice(s.indexOf('['), s.lastIndexOf(']') + 1));
  const ok = arr.filter((x) => x && typeof x.quote === 'string' && x.quote.trim() && typeof x.area === 'string'
    && Array.isArray(x.when) && Array.isArray(x.blocks) && x.blocks.length
    && x.blocks.every((n) => Number.isInteger(n) && n >= 1 && n <= part.length));
  return {
    entries: ok.map((x) => ({ blocks: x.blocks.map((n) => part[n - 1].i), quote: x.quote, area: x.area, when: x.when.map(String) })),
    dropped: arr.length - ok.length,
  };
}

const claude = (input, cwd) => new Promise((resolve) => {
  const env = { ...process.env, MSYS_NO_PATHCONV: '1', DISABLE_AUTOUPDATER: '1' };
  for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
  const p = spawn('claude', ['-p', '--model', MODEL, '--output-format', 'json', '--system-prompt', SYS, '--tools', '',
    '--setting-sources', 'project', '--strict-mcp-config', '--no-session-persistence'], { cwd, env, shell: false });
  let out = '';
  let err = '';
  p.stdout.on('data', (d) => { out += d; });
  p.stderr.on('data', (d) => { err += d; });
  p.on('close', (code) => resolve({ code, out, err }));
  p.stdin.end(input);
});

async function convert(job, cwd) {
  for (let attempt = 1; attempt <= 2; attempt++) {
    const r = await claude(message(job.file, job.part), cwd);
    try {
      const o = JSON.parse(r.out);
      const { entries, dropped } = parse(o.result, job.part);
      return { file: job.file, cost: o.total_cost_usd, bytes: job.bytes, entries, dropped, attempt };
    } catch (e) {
      if (attempt === 2) return { file: job.file, cost: null, bytes: job.bytes, entries: [], dropped: 0, attempt, error: String(e).slice(0, 200), code: r.code };
    }
  }
}

const [mode, cfgArg, jobsArg = '6'] = process.argv.slice(2);

if (mode === 'selftest') {
  const blocks = [0, 1, 2].map((i) => ({ i: i + 10, e: { heads: ['H'], text: 'x'.repeat(30 * 1024) } }));
  assert.equal(parts(blocks).length, 3);
  assert.match(message('a.md', blocks.slice(0, 1)), /^File: a\.md\n\n\[1\] H\n/);
  const r = parse('```json\n[{"blocks":[2],"quote":"q","area":"a","when":["w"]},{"blocks":[9],"quote":"q","area":"a","when":[]}]\n```', blocks);
  assert.deepEqual(r.entries, [{ blocks: [11], quote: 'q', area: 'a', when: ['w'] }]);
  assert.equal(r.dropped, 1);
  console.log('selftest ok');
} else if (mode === 'pilot' || mode === 'run') {
  const cfg = JSON.parse(fs.readFileSync(cfgArg, 'utf8'));
  const dir = path.join(path.dirname(path.resolve(cfgArg)), 'd13');
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'd13-convert-'));
  const labels = [...new Set(cfg.tasks.map((t) => t.id.split('-')[0]))];
  for (const label of labels) {
    const map = JSON.parse(fs.readFileSync(path.join(dir, 'maps', `${label}.json`), 'utf8'));
    const byFile = new Map();
    map.all.forEach((e, i) => { if (!byFile.has(e.file)) byFile.set(e.file, []); byFile.get(e.file).push({ i, e }); });
    let jobs = [...byFile].flatMap(([file, blocks]) => parts(blocks).map((part, k) => ({
      file, part, k, bytes: part.reduce((s, b) => s + Buffer.byteLength(b.e.text), 0),
    })));
    const total = jobs.reduce((s, j) => s + j.bytes, 0);
    if (mode === 'pilot') {
      const sizes = [...byFile].map(([file, blocks]) => [file, blocks.reduce((s, b) => s + Buffer.byteLength(b.e.text), 0)]).sort((a, b) => a[1] - b[1]);
      const pick = sizes[(sizes.length - 1) >> 1][0];
      jobs = jobs.filter((j) => j.file === pick);
    }
    const out = path.join(dir, 'entries', label);
    fs.mkdirSync(out, { recursive: true });
    const key = (j) => crypto.createHash('sha256').update(`${j.file}#${j.k}`).digest('hex').slice(0, 16);
    const todo = jobs.filter((j) => !fs.existsSync(path.join(out, `${key(j)}.json`)));
    let next = 0;
    let done = 0;
    await Promise.all(Array.from({ length: Number(jobsArg) }, async () => {
      while (next < todo.length) {
        const j = todo[next++];
        const r = await convert(j, cwd);
        fs.writeFileSync(path.join(out, `${key(j)}.json`), JSON.stringify(r));
        if (++done % 20 === 0) console.log(`${label}: ${done}/${todo.length}`);
      }
    }));
    const res = jobs.map((j) => JSON.parse(fs.readFileSync(path.join(out, `${key(j)}.json`), 'utf8')));
    const cost = res.reduce((s, r) => s + (r.cost ?? 0), 0);
    const bytes = res.reduce((s, r) => s + r.bytes, 0);
    console.log(`${label}: ${res.length} parts, ${res.reduce((s, r) => s + r.entries.length, 0)} entries, ` +
      `${res.reduce((s, r) => s + r.dropped, 0)} dropped, ${res.filter((r) => r.error).length} failed, ${cost.toFixed(2)} USD` +
      (mode === 'pilot' ? ` for ${Math.round(bytes / 1024)} KB; projected ${(cost * total / bytes).toFixed(2)} USD for ${Math.round(total / 1024)} KB` : ''));
  }
} else {
  console.error('usage: node convert.mjs selftest | pilot <config> | run <config> [jobs]');
  process.exit(2);
}
