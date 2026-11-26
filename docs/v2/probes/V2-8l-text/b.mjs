// 06, section 8, 8l, the added check (b): with each skill allowed in the run repo's local settings
// (Skill(second-brain:status), Skill(second-brain:dream)), a request in plain words starts status, and starts the
// dream's prepare, 3 of 3 each. It reuses c.mjs's repos (the brief allows it): status runs in runs 1-3 after c's
// dreams there, and the dream half reads c's runs 1-3, the same plain-words dreams. Counts and flags only.
//   D17_CLAUDE=<cli> C_PLUGIN=<plugin> node b.mjs <c's scratch> status <first> <last>
//   B_RESULT=<name>.json node b.mjs <c's scratch> summary
// The bar, fixed before any run (the brief of 2026-11-26):
//   - status: in 3 of 3 runs Claude called the Skill tool for second-brain:status itself and its report came back
//     ("second-brain status, " in the session), and no file changed;
//   - dream: in 3 of 3 of c's runs 1-3 Claude called the Skill tool for second-brain:dream itself and prepare ran
//     ("Dream prepared: " in the session).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { session, git } from './c.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATUS_PROMPT = "Is this repo's team memory up to date?";
const [scratchArg, mode, firstArg = '1', lastArg = '3'] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const read = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };

function status(i) {
  const repo = path.join(scratch, `run-${i}`, 'repo');
  const plugin = path.resolve(process.env.C_PLUGIN);
  const tree = () => git(repo, 'status', '--porcelain', '--untracked-files=all') + git(repo, 'rev-parse', 'HEAD');
  const before = tree();
  const s = session(repo, plugin, STATUS_PROMPT);
  const out = { run: i, ok: s.ok, exit: s.exit, costUsd: s.costUsd, skillCalled: s.skills.some((k) => /^(second-brain:)?status$/.test(k)),
    reported: s.all.includes('second-brain status, '), nothingChanged: tree() === before, denials: s.denials };
  fs.writeFileSync(path.join(scratch, `run-${i}`, 'b-status.json'), JSON.stringify(out, null, 1));
  console.log(`status ${i}: ${JSON.stringify(out)}`);
}

function summary() {
  const st = [1, 2, 3].map((i) => JSON.parse(read(path.join(scratch, `run-${i}`, 'b-status.json')) || 'null')).filter(Boolean);
  const dr = [1, 2, 3].map((i) => JSON.parse(read(path.join(scratch, `run-${i}`, 'c.json')) || 'null')).filter(Boolean)
    .map((r) => ({ run: r.run, ok: r.ok, skillCalled: r.skillCalled, prepared: r.prepared, denials: r.denials }));
  const out = { statusPrompt: STATUS_PROMPT, status: st, dream: dr,
    costUsd: Math.round(st.reduce((a, r) => a + r.costUsd, 0) * 100) / 100 };
  out.pass = { status: st.length === 3 && st.every((r) => r.skillCalled && r.reported && r.nothingChanged), dream: dr.length === 3 && dr.every((r) => r.skillCalled && r.prepared) };
  out.pass.all = out.pass.status && out.pass.dream;
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', process.env.B_RESULT ?? 'b.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
}

if (mode === 'status') for (let i = Number(firstArg); i <= Number(lastArg); i++) status(i);
else if (mode === 'summary') summary();
else throw new Error('usage: node b.mjs <scratch> status <first> <last>, or summary');
