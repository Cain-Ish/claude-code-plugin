// 06, section 3, S8: the acceptance check's item 5 failed at attempt 1 (decision-checker used in 2 of 5). Its focused
// probe: does a fix make Claude hand a decision check to decision-checker reliably? Three arms, each a plugin build:
//   control: the attempt-1 candidate;
//   C:       CLAUDE.md's pointer says why to delegate even after reading the map;
//   AC:      C, and the index leaves out .claude/agents, skills, commands and output styles (Claude Code loads them
//            itself, as it does .claude/rules, already left out).
// Each arm: a repo set up as attempt 1's was at item 5 (the app, setup run by its hook command, the team's widgets
// decision and a captured prices entry, committed), copied fresh per run. Two prompts, 5 runs each, so 10 per arm.
// Opus 5.5, the pinned CLI, acceptEdits. Delegated: an Agent call with subagent type decision-checker. Named: the reply
// names widgets-home or src/widgets. The decision rule is registered in 06 before this runs.
//   D17_CLAUDE=<pinned CLI> node agent-probe.mjs <scratch> <arm>=<plugin dir> [...]
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const [scratchArg, ...armArgs] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const arms = armArgs.map((a) => { const [name, dir] = a.split('='); return { name, dir: path.resolve(dir) }; });
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
const put = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const PROMPTS = {
  P1: "Before I make this change, check it against this project's recorded decisions: I want to add the new PriceTag component as src/components/PriceTag.jsx.",
  P2: 'Does putting a new Avatar component in src/components/Avatar.jsx fit what this project has decided? Check it before I write anything.',
};
const entry = (h, q, id, src) => `\n### ${h}\n> ${q}\n\n- id: ${id}\n- source: ${src}\n- when: ["ui"]\n- verified: 2026-11-20 stated by the lead developer\n`;

function base(arm) {
  const repo = path.join(scratch, `base-${arm.name}`);
  fs.rmSync(repo, { recursive: true, force: true });
  put(path.join(repo, 'package.json'), '{ "name": "shop", "version": "0.1.0", "type": "module" }\n');
  put(path.join(repo, 'README.md'), '# shop\n\nA small shop front.\n');
  put(path.join(repo, 'src', 'utils', 'date.js'), 'export function formatDate(d) { return [d.getDate(), d.getMonth() + 1, d.getFullYear()].join("."); }\n');
  put(path.join(repo, 'src', 'components', 'Button.jsx'), 'export function Button({ label }) { return <button>{label}</button>; }\n');
  put(path.join(repo, 'src', 'price.js'), 'export const formatPrice = (cents) => (cents / 100).toFixed(2);\n');
  const git = (...a) => spawnSync('git', ['-c', 'user.name=p', '-c', 'user.email=p@example.invalid', ...a], { cwd: repo, encoding: 'utf8' });
  git('init', '-q');
  const s = spawnSync('node', [path.join(arm.dir, 'scripts', 'hook.mjs'), 'setup'], { cwd: repo, encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: repo } });
  if (s.status !== 0) throw new Error(`setup failed for ${arm.name}: ${s.stderr}`);
  fs.appendFileSync(path.join(repo, '.project-map', 'decisions.md'), entry('components', 'New components go under src/widgets/.', 'widgets-home', 'the lead developer, 2026-11-20'));
  put(path.join(repo, '.project-map', 'prices.md'), `---\nname: prices\ndescription: How prices are stored and shown. Read before touching prices.\n---\n${entry('price storage', 'all prices are stored as integer cents, never as floats.', 'prices-integer-cents', 'the lead developer, 2026-11-20')}`);
  git('add', '-A');
  git('commit', '-q', '-m', 'setup and decisions');
  return repo;
}

const rows = [];
for (const arm of arms) {
  const b = base(arm);
  for (const [pid, prompt] of Object.entries(PROMPTS)) {
    for (let k = 1; k <= 5; k++) {
      const repo = path.join(scratch, `${arm.name}-${pid}-${k}`);
      fs.rmSync(repo, { recursive: true, force: true });
      fs.cpSync(b, repo, { recursive: true });
      const r = spawnSync(CLAUDE, ['-p', '--model', 'claude-opus-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch',
        '--permission-mode', 'acceptEdits', '--plugin-dir', arm.dir, '--output-format', 'stream-json', '--verbose'], { cwd: repo, input: prompt, encoding: 'utf8', env: env(), timeout: 1_800_000, maxBuffer: 128 << 20 });
      const ev = parse(r.stdout ?? '');
      const res = ev.find((e) => e.type === 'result') ?? {};
      const uses = ev.filter((e) => e.type === 'assistant' && !e.parent_tool_use_id).flatMap((e) => (e.message?.content ?? []).filter((c) => c.type === 'tool_use'));
      const delegated = uses.some((u) => /^(Agent|Task)$/.test(u.name) && /decision-checker/.test(String(u.input?.subagent_type ?? '')));
      const named = /widgets-home|src\/widgets/.test(String(res.result ?? ''));
      const readsBefore = uses.findIndex((u) => /^(Agent|Task)$/.test(u.name));
      rows.push({ arm: arm.name, prompt: pid, run: k, ok: res.subtype === 'success', delegated, named, toolsBeforeAgent: readsBefore < 0 ? uses.length : readsBefore, costUsd: Math.round((res.total_cost_usd ?? 0) * 100) / 100 });
      console.log(JSON.stringify(rows.at(-1)));
    }
  }
}
const by = (a) => rows.filter((r) => r.arm === a);
const out = { probe: 'S8 item 5, focused', rule: 'an arm qualifies with delegated and named in at least 9 of its 10 runs; the smaller change wins (C before AC); none qualifying goes to the user',
  arms: Object.fromEntries(arms.map((a) => [a.name, { delegated: by(a.name).filter((r) => r.delegated).length, named: by(a.name).filter((r) => r.named).length, runs: by(a.name).length }])),
  costUsd: Math.round(rows.reduce((s, r) => s + r.costUsd, 0) * 100) / 100, rows };
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', process.env.S8_PROBE_OUT ?? 's8-agent-probe.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify({ ...out, rows: undefined }, null, 1));
