// 06, section 3, S8: the user's end-to-end acceptance check ("installed in claude and run in a new project ... keeps
// Claude aware of the researched approach and using it"), with the install route amended in 06 before any run.
// Each run: a brand-new repo (a small app, no CLAUDE.md, no .claude/). The release candidate is installed as a user
// installs it (marketplace add, plugin install, project scope) into an isolated CLAUDE_CONFIG_DIR; that folder cannot
// log in (P4), so the sessions load the installed copy with --plugin-dir under the user's own login. Items 1-7 as
// registered. Opus 5.5, the pinned CLI, acceptEdits.
//   D17_CLAUDE=<pinned CLI> node e2e.mjs <scratch> <a clone of the candidate> <first run> <last run>
//   node e2e.mjs <scratch> summary
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const MODEL = 'claude-opus-5-5';
const [scratchArg, second, firstArg, lastArg] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const env = (extra = {}) => { const e = { ...process.env, MSYS_NO_PATHCONV: '1', ...extra }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
const put = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const enc = (p) => p.replace(/[^A-Za-z0-9]/g, '-');
const walk = (d, skip = () => false) => (fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (skip(e.name) ? [] : e.isDirectory() ? walk(path.join(d, e.name), skip).map((p) => `${e.name}/${p}`) : [e.name])) : []);
const hashes = (d, skip) => Object.fromEntries(walk(d, skip).sort().map((p) => [p, crypto.createHash('sha256').update(fs.readFileSync(path.join(d, p))).digest('hex')]));
const blocks = (t) => t.replace(/\r/g, '').split(/^(?=### )/m).filter((b) => b.startsWith('### '));
const mapText = (repo) => walk(path.join(repo, '.project-map'), (n) => n === '.dream-run').filter((p) => p.endsWith('.md') && !/^(README|dreams)\.md$/.test(p)).map((p) => fs.readFileSync(path.join(repo, '.project-map', p), 'utf8')).join('\n');

function run(i, clone) {
  const base = path.join(scratch, `e2e-${i}`);
  fs.rmSync(base, { recursive: true, force: true });
  const repo = path.join(base, 'repo');
  const cfg = path.join(base, 'cfg');
  // the brand-new repo: a small app
  put(path.join(repo, 'package.json'), '{ "name": "shop", "version": "0.1.0", "type": "module" }\n');
  put(path.join(repo, 'README.md'), '# shop\n\nA small shop front.\n');
  put(path.join(repo, 'src', 'price.js'), 'export const currency = "EUR";\n');
  put(path.join(repo, 'src', 'components', 'Button.jsx'), 'export function Button({ label }) { return <button>{label}</button>; }\n');
  const git = (...a) => spawnSync('git', ['-c', 'user.name=e2e', '-c', 'user.email=e2e@example.invalid', ...a], { cwd: repo, encoding: 'utf8' });
  git('init', '-q');
  git('add', '-A');
  git('commit', '-q', '-m', 'app');
  // check 0: the install as a user runs it, and the installed bytes equal the candidate's plugin/
  fs.mkdirSync(cfg, { recursive: true });
  const cli = (...a) => spawnSync(CLAUDE, a, { cwd: repo, encoding: 'utf8', env: env({ CLAUDE_CONFIG_DIR: cfg }), timeout: 300_000 });
  const add = cli('plugin', 'marketplace', 'add', clone, '--scope', 'project');
  const inst = cli('plugin', 'install', 'second-brain@second-brain', '--scope', 'project');
  const cache = path.join(cfg, 'plugins', 'cache', 'second-brain', 'second-brain');
  const version = fs.existsSync(cache) ? fs.readdirSync(cache)[0] : null;
  const installed = version ? path.join(cache, version) : null;
  const same = installed && JSON.stringify(hashes(installed)) === JSON.stringify(hashes(path.join(clone, 'plugin')));
  // the install's project settings name the marketplace; the user's own config holds one of the same name, so the file
  // is set aside and the sessions load the installed copy with --plugin-dir alone
  if (fs.existsSync(path.join(repo, '.claude', 'settings.json'))) fs.renameSync(path.join(repo, '.claude', 'settings.json'), path.join(base, 'install-settings.json'));
  try { fs.rmdirSync(path.join(repo, '.claude')); } catch {}
  // a probe plugin that records InstructionsLoaded
  const il = path.join(base, 'il');
  const ilPlugin = path.join(base, 'il-plugin');
  put(path.join(ilPlugin, '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'il', version: '0.0.0' }));
  put(path.join(ilPlugin, 'dump.mjs'), `import fs from 'node:fs';\nconst i = fs.readFileSync(0, 'utf8');\nfs.mkdirSync(${JSON.stringify(il)}, { recursive: true });\nfs.appendFileSync(${JSON.stringify(il)} + '/loads.jsonl', i.replace(/\\n/g, ' ') + '\\n');\n`);
  put(path.join(ilPlugin, 'hooks', 'hooks.json'), JSON.stringify({ hooks: { InstructionsLoaded: [{ hooks: [{ type: 'command', command: 'node', args: ['${CLAUDE_PLUGIN_ROOT}/dump.mjs'] }] }] } }));
  const loads = () => (fs.existsSync(path.join(il, 'loads.jsonl')) ? parse(fs.readFileSync(path.join(il, 'loads.jsonl'), 'utf8')).map((l) => String(l.file_path ?? '').replace(/\\/g, '/')) : []);
  let cost = 0;
  const session = (input, { plugin = true, probe = false } = {}) => {
    fs.rmSync(il, { recursive: true, force: true });
    const r = spawnSync(CLAUDE, ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch',
      '--permission-mode', 'acceptEdits', ...(plugin && installed ? ['--plugin-dir', installed] : []), ...(probe ? ['--plugin-dir', ilPlugin] : []),
      '--output-format', 'stream-json', '--verbose', '--include-hook-events'], { cwd: repo, input, encoding: 'utf8', env: env(), timeout: 3_600_000, maxBuffer: 256 << 20 });
    const ev = parse(r.stdout ?? '');
    const res = ev.find((e) => e.type === 'result') ?? {};
    cost += res.total_cost_usd ?? 0;
    const uses = ev.filter((e) => e.type === 'assistant' && !e.parent_tool_use_id).flatMap((e) => (e.message?.content ?? []).filter((c) => c.type === 'tool_use'));
    const hook = (event) => ev.filter((e) => e.subtype === 'hook_response' && e.hook_event === event).map((e) => String(e.output ?? ''));
    return { ok: res.subtype === 'success', text: String(res.result ?? ''), uses, hook, loads: loads() };
  };
  const out = { run: i, installOk: add.status === 0 && inst.status === 0, installedSame: Boolean(same), version };
  if (!installed) { put(path.join(base, 'e2e.json'), JSON.stringify(out, null, 1)); return; }

  // 1. layout: setup creates D29's files with Anthropic's rules met; a second run creates nothing
  const s1 = session('/second-brain:setup');
  const at = (p) => path.join(repo, p);
  const read = (p) => { try { return fs.readFileSync(at(p), 'utf8').replace(/\r/g, ''); } catch { return null; } };
  const FILES = ['CLAUDE.md', '.claude/rules/project-map.md', '.claude/skills/map-review/SKILL.md', '.claude/agents/decision-checker.md', '.claude/agents/codebase-guide.md',
    '.claude/agents/memory-curator.md', '.project-map/README.md', '.project-map/decisions.md', '.project-map/dreams.md', '.gitattributes'];
  const rules = walk(at('.claude/rules')).filter((p) => p.endsWith('.md'));
  const layout = {
    sessionOk: s1.ok, all: FILES.every((f) => read(f) !== null), claudeMdLines: (read('CLAUDE.md') ?? '').split('\n').length,
    rulesScoped: rules.length > 0 && rules.every((p) => /^---\n[\s\S]*?^paths:/m.test(read(`.claude/rules/${p}`) ?? '')),
    skillFlag: /^disable-model-invocation: true$/m.test(read('.claude/skills/map-review/SKILL.md') ?? ''),
    agentsMemory: ['decision-checker', 'codebase-guide', 'memory-curator'].every((a) => /^memory: project$/m.test(read(`.claude/agents/${a}.md`) ?? '')),
    topicFront: /^---\nname: \S[\s\S]*?^description: \S/m.test(read('.project-map/decisions.md') ?? ''),
  };
  const before = hashes(repo, (n) => n === '.git');
  session('/second-brain:setup');
  layout.secondCreatesNothing = JSON.stringify(hashes(repo, (n) => n === '.git')) === JSON.stringify(before);
  layout.pass = layout.sessionOk && layout.all && layout.claudeMdLines < 200 && layout.rulesScoped && layout.skillFlag && layout.agentsMemory && layout.topicFront && layout.secondCreatesNothing;
  out.layout = layout;
  // the user reviews and commits the setup, and the team's first decision
  fs.appendFileSync(at('.project-map/decisions.md'), '\n### components\n> New components go under src/widgets/.\n\n- id: widgets-home\n- source: the lead developer, 2026-11-20\n- when: ["ui"]\n- verified: 2026-11-20 stated by the lead developer\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'second-brain setup');

  // 2. aware: a fresh session names the folder and the entry format
  const s2 = session('Where does this project keep its decisions, and how should you record a new one?');
  const parts = [/\bsource\b/i, /\bid\b/i, /\bverified\b/i, /\bwhen\b/i, /quote|^\s*>/im].filter((re) => re.test(s2.text)).length;
  out.aware = { ok: s2.ok, folder: /\.project-map/.test(s2.text), formatParts: parts, pass: s2.ok && /\.project-map/.test(s2.text) && parts >= 3 };

  // 3. capture: a decision stated in passing lands in a topic file with id, source and verified
  session('Add a function formatPrice(cents) to src/price.js that returns the price as a string with two decimals, like "12.34". By the way, we decided that all prices are stored as integer cents, never as floats.');
  const captured = blocks(mapText(repo)).filter((b) => /integer cents/i.test(b));
  out.capture = { entries: captured.length, pass: captured.some((b) => /^- id:\s*\S/m.test(b) && /^- source:\s*\S/m.test(b) && /^- verified:\s*\S/m.test(b)) };

  // 4. rule: the starter rule loads when a map file is touched
  const s4 = session('Read .project-map/decisions.md and tell me in one line how many entries it holds.', { probe: true });
  out.rule = { pass: s4.loads.some((f) => f.endsWith('.claude/rules/project-map.md')) };

  // 5. agent: checking a change against the decisions uses decision-checker and names the entry
  const s5 = session("Before I make this change, check it against this project's recorded decisions: I want to add the new PriceTag component as src/components/PriceTag.jsx.");
  const used = s5.uses.some((u) => /^(Agent|Task)$/.test(u.name) && /decision-checker/.test(String(u.input?.subagent_type ?? '')));
  const named = /widgets-home|src\/widgets/.test(s5.text);
  out.agent = { used, named, pass: used && named };

  // 6. the dream loop: three sessions state decisions with capture off (no plugin); the dream proposes them; the draft
  // rule never loads; the next session's labels say "proposed by a dream"
  session('From now on all dates shown to users go through formatDate from src/utils/date.js, never toLocaleDateString. Create src/utils/date.js with a formatDate(d) that returns DD.MM.YYYY.', { plugin: false });
  session('Add src/components/OrderDate.jsx that shows an order date. Again: all dates shown to users go through formatDate from src/utils/date.js, never toLocaleDateString.', { plugin: false });
  session('We decided that API errors are wrapped in ApiError from src/errors.js. Create src/errors.js with that class.', { plugin: false });
  git('add', '-A', '--', 'src');
  git('commit', '-q', '-m', 'work');
  const s6 = session('/second-brain:dream');
  const proposed = blocks(mapText(repo)).filter((b) => /^- proposed: dream /m.test(b)).length;
  const drafts = walk(at('.claude/rules')).filter((p) => p.endsWith('.md.draft'));
  const s6b = session('Read each file in .project-map/ other than README.md and dreams.md, and list the heading of every entry. Then read src/components/OrderDate.jsx.', { probe: true });
  const labelled = s6b.hook('PostToolUse').some((o) => o.includes('proposed by a dream'));
  const neverLoaded = !s6b.loads.some((f) => f.endsWith('.md.draft'));
  out.dream = { sessionOk: s6.ok, logged: /^- \d{4}-\d{2}-\d{2}: \d+ session/m.test(read('.project-map/dreams.md') ?? ''), proposed, drafts: drafts.length, labelled, neverLoaded, pass: proposed > 0 && drafts.length > 0 && neverLoaded && labelled };

  // 7. the nudge: 10 synthetic sessions past the watermark; the due line is in systemMessage, not in Claude's context
  const tdir = path.join(os.homedir(), '.claude', 'projects', enc(fs.realpathSync.native(repo)));
  for (let k = 0; k < 10; k++) put(path.join(tdir, `e2e00000-0000-4000-8000-${String(i).padStart(4, '0')}${String(k).padStart(8, '0')}.jsonl`), `${JSON.stringify({ type: 'user', promptSource: 'sdk', cwd: repo, timestamp: new Date().toISOString(), message: { role: 'user', content: 'synthetic' } })}\n`);
  const s7 = session('Reply with the single word ok.');
  const start = s7.hook('SessionStart').map((o) => { try { return JSON.parse(o); } catch { return {}; } });
  const inSystem = start.some((o) => /a dream is due/.test(String(o.systemMessage ?? '')));
  const inContext = start.some((o) => /a dream is due/.test(String(o.hookSpecificOutput?.additionalContext ?? '')));
  out.nudge = { inSystem, inContext, pass: inSystem && !inContext };
  out.costUsd = Math.round(cost * 100) / 100;
  put(path.join(base, 'e2e.json'), JSON.stringify(out, null, 1));
  console.log(`run ${i}: ${JSON.stringify(out)}`);
}

function summary() {
  const runs = fs.readdirSync(scratch).filter((d) => /^e2e-\d+$/.test(d)).map((d) => path.join(scratch, d, 'e2e.json')).filter((p) => fs.existsSync(p)).map((p) => JSON.parse(fs.readFileSync(p, 'utf8'))).sort((a, b) => a.run - b.run);
  const n = (k) => runs.filter((r) => r[k]?.pass).length;
  const out = { runs: runs.length, install: runs.filter((r) => r.installOk && r.installedSame).length, layout: n('layout'), aware: n('aware'), capture: n('capture'), rule: n('rule'), agent: n('agent'), dream: n('dream'), nudge: n('nudge'), costUsd: Math.round(runs.reduce((a, r) => a + (r.costUsd ?? 0), 0) * 100) / 100, per: runs };
  out.pass = { install: out.install === 5, layout: out.layout === 5, aware: out.aware >= 4, capture: out.capture >= 4, rule: out.rule === 5, agent: out.agent >= 4, dream: out.dream >= 4, nudge: out.nudge === 5 };
  out.pass.all = runs.length === 5 && Object.values(out.pass).every(Boolean);
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', 's8-e2e.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ ...out, per: undefined }, null, 1));
}

if (second === 'summary') summary();
else for (let i = Number(firstArg); i <= Number(lastArg); i++) run(i, path.resolve(second));
