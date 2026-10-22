// V2-D15 re-decision count: for the documents the main thread of the given sessions read, raw bytes against their
// D15 branches (each entry's context and quote, plus one heading line per section). Counts only, to stdout.
//   node branchcount.mjs <raw dir> <repo label> <repo path> <commit> <session dir>...
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const [raw, label, repo, commit, ...sessions] = process.argv.slice(2);
const dir = path.join(raw, 'd15', 'full', label);
const all = JSON.parse(fs.readFileSync(path.join(raw, 'd13', 'maps', `${label}.json`), 'utf8')).all;
const branch = new Map(); // source file -> branch bytes
for (const f of fs.readdirSync(dir)) {
  const r = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
  const heads = new Set(r.entries.map((e) => all[e.blocks[0]].heads.join(' › ')));
  const bytes = r.entries.reduce((a, e) => a + Buffer.byteLength(`${e.context ? `${e.context}\n` : ''}${e.quote}\n`), 0)
    + [...heads].reduce((a, h) => a + Buffer.byteLength(`## ${h}\n`), 0);
  branch.set(r.file, (branch.get(r.file) ?? 0) + bytes);
}
const median = (a) => [...a].sort((x, y) => x - y)[(a.length - 1) >> 1];
const shares = [];
for (const s of sessions) {
  const ev = fs.readFileSync(path.join(s, 'stream.jsonl'), 'utf8').split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
  const docs = [...new Set(ev.filter((e) => e.type === 'assistant' && !e.parent_tool_use_id).flatMap((e) => e.message?.content ?? [])
    .filter((c) => c.type === 'tool_use' && c.name === 'Read').map((c) => String(c.input?.file_path ?? '').replace(/\\/g, '/').match(/\/wt-[^/]+\/(.+)$/)?.[1])
    .filter((p) => p && /\.(md|mdx|markdown|txt|rst)$/i.test(p)))];
  const rawBytes = docs.reduce((a, p) => { try { return a + Buffer.byteLength(execFileSync('git', ['-C', repo, 'show', `${commit}:${p}`], { encoding: 'utf8', maxBuffer: 1 << 28 })); } catch { return a; } }, 0);
  const brBytes = docs.reduce((a, p) => a + (branch.get(p) ?? 0), 0);
  shares.push(brBytes / rawBytes);
  console.log(`${path.basename(path.dirname(s))}/${path.basename(s)}: ${docs.length} documents, raw ${(rawBytes / 1024).toFixed(0)} KB, branches ${(brBytes / 1024).toFixed(0)} KB, share ${(brBytes / rawBytes).toFixed(2)}, without a branch ${docs.filter((p) => !branch.has(p)).length}`);
}
console.log(`median share ${median(shares).toFixed(2)}; bar: at most 0.50`);
