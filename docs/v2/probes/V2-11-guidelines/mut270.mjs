// 06, section 11: each mutation of G-1, G-2 and G-4 must fail its check. Usage: node mut270.mjs <build plugin folder>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
const SRC = path.resolve(process.argv[2]);
const MUTS = [
  ['G-1 no copy', 'scripts/dream.mjs', /^\s*fs\.copyFileSync\(new URL\('\.\.\/skills\/tailor\/guidelines\.md'.*\n/m, '', 'test/dream8c.mjs'],
  ['G-1 no line', 'scripts/dream.mjs', /^\s*`Guidelines: .*\n/m, '', 'test/dream8c.mjs'],
  ['G-2 no sentence', 'skills/dream/SKILL.md', / Before you write a rule, skill, agent or change draft, read the guidelines file the report names, and write\n   the draft by it; the formats below still hold, since finish checks them, and a draft's cases are tailor's, not the\n   dream's:/, ':', 'test/selftest.mjs'],
  ['G-4 a repo path in a skill', 'skills/status/SKILL.md', /\n$/, '\nSee docs/v2/06-first-slice.md for more.\n', 'test/selftest.mjs'],
  ['G-2 no cases clause', 'skills/dream/SKILL.md', /, and a draft's cases are tailor's, not the\n   dream's:/, ':', 'test/selftest.mjs'],
  ['G-4 a repo path a script prints', 'scripts/status.mjs', /\n$/, '\nconsole.log("see docs/v2/DECISIONS.md");\n', 'test/selftest.mjs'],
  ['G-4 a research note in an agent', 'agents/dream-analyzer.md', /\n$/, '\nRead research/2026-11-24-repo-agents-and-skills.md first.\n', 'test/selftest.mjs'],
];
let killed = 0;
for (const [id, file, re, to, test] of MUTS) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mut270-'));
  fs.cpSync(SRC, dir, { recursive: true });
  const f = path.join(dir, file);
  const t = fs.readFileSync(f, 'utf8');
  if (!re.test(t)) { console.log(`ANCHOR MISSING  ${id}`); fs.rmSync(dir, { recursive: true, force: true }); continue; }
  fs.writeFileSync(f, t.replace(re, to));
  const r = spawnSync('node', [path.join(dir, test)], { cwd: dir, encoding: 'utf8', timeout: 900_000 });
  const dead = r.status !== 0;
  if (dead) killed++;
  console.log(`${dead ? 'killed' : 'SURVIVED'}  ${id}`);
  fs.rmSync(dir, { recursive: true, force: true });
}
console.log(`${killed} of ${MUTS.length} killed`);
process.exitCode = killed === MUTS.length ? 0 : 1;
