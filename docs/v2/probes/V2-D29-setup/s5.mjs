// 06, section 3, S5, checks 2 and 3: the smoke after setup, and each project agent's outcome (registered before code).
//   D17_CLAUDE=<pinned CLI 2.1.305> node s5.mjs <scratch> <plugin dir> [smoke,checker,guide,curator] [runs]
// Writes results/s5-<check>.json: flags and counts only.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const OPUS = 'claude-opus-5-5';
const HAIKU = 'claude-haiku-5-5';
const [scratchArg, pluginArg, which = 'smoke,checker,guide,curator', runsArg = '5'] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const PLUGIN = path.resolve(pluginArg);
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });

const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY']) delete e[k]; return e; };
const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout; };
const put = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
function session(cwd, prompt, { model = OPUS, plugins = [PLUGIN] } = {}) {
  const args = ['-p', '--model', model, '--setting-sources', 'project,local', '--strict-mcp-config', '--permission-mode', 'acceptEdits',
    '--disallowedTools', 'WebFetch,WebSearch', '--output-format', 'stream-json', '--verbose', ...plugins.flatMap((p) => ['--plugin-dir', p])];
  const r = spawnSync(CLAUDE, args, { cwd, input: prompt, encoding: 'utf8', env: env(), timeout: 1_200_000, maxBuffer: 256 << 20 });
  const ev = parse(r.stdout ?? '');
  const res = ev.find((e) => e.type === 'result') ?? {};
  const init = ev.find((e) => e.type === 'system' && e.subtype === 'init') ?? {};
  const subUses = ev.filter((e) => e.type === 'assistant' && e.parent_tool_use_id).flatMap((e) => e.message?.content ?? []).filter((c) => c.type === 'tool_use');
  const agentCalls = ev.filter((e) => e.type === 'assistant' && !e.parent_tool_use_id).flatMap((e) => e.message?.content ?? []).filter((c) => c.type === 'tool_use' && /^(Agent|Task)$/.test(c.name)).map((c) => c.input?.subagent_type);
  return { ok: res.subtype === 'success' && !res.is_error, text: String(res.result ?? ''), init, subUses, agentCalls, cost: res.total_cost_usd ?? 0 };
}
// a small app, set up by the plugin's own setup handler, then committed: the state a user reaches after /setup
function app(name, extra = {}) {
  const dir = path.join(scratch, name);
  fs.rmSync(dir, { recursive: true, force: true });
  const files = {
    'package.json': '{ "name": "shop", "version": "1.0.0", "scripts": { "test": "node --test", "build": "tsc" } }\n',
    'src/components/Avatar.tsx': "export function Avatar({ user }: { user: { avatarUrl: string } }) {\n  return <img src={user.avatarUrl} alt=\"\" />;\n}\n",
    'src/components/Button.tsx': "export function Button({ label }: { label: string }) {\n  return <button>{label}</button>;\n}\n",
    'src/lib/money.ts': "export function formatPrice(cents: number, currency = 'EUR') {\n  return new Intl.NumberFormat('de-DE', { style: 'currency', currency }).format(cents / 100);\n}\n",
    'src/pages/Checkout.tsx': "import { formatPrice } from '../lib/money';\nexport const total = (c: number) => formatPrice(c);\n",
    ...extra,
  };
  for (const [p, s] of Object.entries(files)) put(path.join(dir, p), s);
  git(dir, 'init', '-q');
  const s = spawnSync('node', [path.join(PLUGIN, 'scripts', 'hook.mjs'), 'setup'], { cwd: dir, encoding: 'utf8', env: { ...env(), CLAUDE_PROJECT_DIR: dir } });
  if (s.status) throw new Error(s.stderr);
  git(dir, 'add', '-A');
  git(dir, 'commit', '-q', '-m', 'app after setup');
  return dir;
}
const status = (dir) => git(dir, 'status', '--porcelain', '-uall').split('\n').filter(Boolean).map((l) => l.slice(3));
const save = (name, obj) => { fs.writeFileSync(path.join(HERE, 'results', `s5-${name}.json`), `${JSON.stringify(obj, null, 1)}\n`); console.log(name, JSON.stringify(obj).slice(0, 500)); };
const N = Number(runsArg);
const E = (h, q, extra) => `### ${h}\n> ${q}\n\n${extra}`;

const checks = {
  // the starter rule loads only when a map file is touched; the skill stays out of the model's listing; the three
  // agents are listed. A probe plugin's InstructionsLoaded hook records each rule load
  smoke() {
    const dumpDir = path.join(scratch, 'il-dump');
    const probe = path.join(scratch, 'il-plugin');
    put(path.join(probe, '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'il', version: '0.0.0' }));
    put(path.join(probe, 'dump.mjs'), `import fs from 'node:fs';\nconst i = fs.readFileSync(0, 'utf8');\nfs.mkdirSync(${JSON.stringify(dumpDir)}, { recursive: true });\nfs.appendFileSync(${JSON.stringify(dumpDir)} + '/loads.jsonl', i.replace(/\\n/g, ' ') + '\\n');\n`);
    put(path.join(probe, 'hooks', 'hooks.json'), JSON.stringify({ hooks: { InstructionsLoaded: [{ hooks: [{ type: 'command', command: 'node', args: ['${CLAUDE_PLUGIN_ROOT}/dump.mjs'] }] }] } }));
    const rows = [];
    for (const [label, prompt] of [['untouched', 'Reply with the single word ok.'], ['touched', 'Read .project-map/decisions.md and reply with its name field.']]) {
      fs.rmSync(dumpDir, { recursive: true, force: true });
      const dir = app(`smoke-${label}`);
      const s = session(dir, prompt, { model: HAIKU, plugins: [PLUGIN, probe] });
      const loads = fs.existsSync(path.join(dumpDir, 'loads.jsonl')) ? parse(fs.readFileSync(path.join(dumpDir, 'loads.jsonl'), 'utf8')) : [];
      const ruleLoads = loads.filter((l) => String(l.file_path ?? '').replace(/\\/g, '/').endsWith('.claude/rules/project-map.md'));
      rows.push({ label, sessionOk: s.ok, hookFired: loads.length > 0, ruleLoaded: ruleLoads.length > 0, reasons: [...new Set(ruleLoads.map((l) => l.load_reason))],
        agentsListed: ['decision-checker', 'codebase-guide', 'memory-curator'].filter((a) => JSON.stringify(s.init.agents ?? []).includes(a)),
        skillInInit: JSON.stringify(s.init.skills ?? s.init.slash_commands ?? []).includes('map-review'), initKeys: Object.keys(s.init) });
    }
    save('smoke', { rows, pass: rows[0].ruleLoaded === false && rows[1].ruleLoaded === true && rows.every((r) => r.agentsListed.length === 3) });
  },
  // decision-checker flags a change that breaks a committed entry, and calls a proposed entry a proposal
  checker() {
    const rows = [];
    for (let i = 1; i <= N; i++) {
      const dir = app(`checker-${i}`, {
        '.project-map/avatars.md': `---\nname: avatars\ndescription: How avatars load and look. Read before changing any avatar or user image.\n---\n${E('avatar loading', 'Avatars always load from /static/avatars/, never from the CDN, even when a CDN address exists.', '- id: avatars-local-only\n- source: the PM, 2026-11-02\n- when: ["showing an avatar"]\n- verified: 2026-11-02 stated by the PM\n')}`,
        '.project-map/buttons.md': `---\nname: buttons\ndescription: Button rules. Read before changing a button.\n---\n${E('button labels', 'Button labels are always uppercase.', '- id: buttons-uppercase\n- source: the designer, 2026-11-10\n- when: ["writing a button"]\n- proposed: dream 2026-11-19\n')}`,
      });
      put(path.join(dir, 'src/components/Avatar.tsx'), "export function Avatar({ user }: { user: { cdnUrl: string } }) {\n  return <img src={user.cdnUrl} alt=\"\" />;\n}\n");
      put(path.join(dir, 'src/components/Button.tsx'), "export function Button({ label }: { label: string }) {\n  return <button>{label.toLowerCase()}</button>;\n}\n");
      const s = session(dir, 'Use the decision-checker agent to check my uncommitted changes to src/components/Avatar.tsx and src/components/Button.tsx against this project\'s recorded decisions. Then give me its verdicts.');
      const t = s.text;
      const changed = status(dir).filter((p) => !p.startsWith('src/components/') && !p.startsWith('.claude/agent-memory/decision-checker/'));
      rows.push({ run: i, sessionOk: s.ok, used: s.agentCalls.includes('decision-checker'),
        flagsCdn: /avatar/i.test(t) && /cdn/i.test(t) && /(break|violat|does not follow|doesn't follow|fails?)/i.test(t),
        proposedAsProposal: /uppercase|buttons?-uppercase/i.test(t) && /(proposed|proposal|unreviewed|not (yet )?(accepted|reviewed|binding))/i.test(t),
        writesOutside: changed.length, cost: s.cost });
    }
    save('checker', { rows, flags: rows.filter((r) => r.flagsCdn).length, proposal: rows.filter((r) => r.proposedAsProposal).length, writesOutsideRuns: rows.filter((r) => r.writesOutside).length,
      pass: rows.filter((r) => r.flagsCdn).length >= 4 && rows.filter((r) => r.proposedAsProposal).length === N && rows.every((r) => !r.writesOutside) });
  },
  // codebase-guide: the same where-is question twice, in two sessions; the second answer needs fewer tool calls
  guide() {
    const rows = [];
    for (let i = 1; i <= N; i++) {
      const dir = app(`guide-${i}`, Object.fromEntries(Array.from({ length: 12 }, (_, k) => [`src/feature${k}/index.ts`, `export const f${k} = ${k};\n`])));
      const q = 'Use the codebase-guide agent to answer: where is a price formatted for display, and which pages use that? Give me its answer.';
      const a = session(dir, q);
      const b = session(dir, q);
      const outside = status(dir).filter((p) => !p.startsWith('.claude/agent-memory/codebase-guide/'));
      rows.push({ run: i, ok: a.ok && b.ok, used: a.agentCalls.includes('codebase-guide') && b.agentCalls.includes('codebase-guide'),
        first: a.subUses.length, second: b.subUses.length, notes: fs.existsSync(path.join(dir, '.claude/agent-memory/codebase-guide')), writesOutside: outside.length,
        answered: /money\.ts/.test(a.text) && /money\.ts/.test(b.text) });
    }
    save('guide', { rows, fewer: rows.filter((r) => r.second < r.first).length, writesOutsideRuns: rows.filter((r) => r.writesOutside).length,
      pass: rows.filter((r) => r.second < r.first).length >= 3 && rows.every((r) => !r.writesOutside) });
  },
  // memory-curator: flags the due entry and the duplicate; never changes a committed claim; edits only the map
  curator() {
    const rows = [];
    const committed = E('checkout totals', 'Totals always show the currency symbol.', '- id: totals-currency\n- source: the PM, 2026-10-01\n- when: ["showing a price"]\n- verified: 2026-10-01 stated by the PM\n');
    for (let i = 1; i <= N; i++) {
      const dir = app(`curator-${i}`, {
        '.project-map/prices.md': `---\nname: prices\ndescription: How prices show. Read before showing a price.\n---\n${[
          committed,
          E('price format', 'Prices use formatPrice from src/lib/money.ts.', '- id: price-format\n- source: the lead developer, 2026-10-03\n- when: ["showing a price"]\n- verified: 2026-10-03 stated by the lead developer\n'),
          E('price formatting', 'Every price goes through formatPrice in src/lib/money.ts.', '- id: price-formatting\n- source: the lead developer, 2026-10-20\n- when: ["showing a price"]\n- verified: 2026-10-20 restated by the lead developer\n'),
          E('black friday banner', 'The checkout shows the Black Friday banner.', '- id: black-friday-banner\n- source: the PM, 2026-11-01\n- when: ["changing the checkout"]\n- verified: 2026-11-01 stated by the PM\n- review: 2000-01-01\n'),
        ].join('\n')}`,
      });
      const s = session(dir, 'Use the memory-curator agent to tidy the team memory, then report what it changed.');
      const now = fs.readFileSync(path.join(dir, '.project-map/prices.md'), 'utf8').replace(/\r/g, '');
      const t = `${s.text}\n${now}`;
      const outside = status(dir).filter((p) => !p.startsWith('.project-map/') && !p.startsWith('.claude/agent-memory/memory-curator/'));
      rows.push({ run: i, sessionOk: s.ok, used: s.agentCalls.includes('memory-curator'),
        flagsDue: /black.?friday/i.test(s.text) && /(review|due|expired|stale|past)/i.test(s.text),
        flagsDuplicate: /price-format(ting)?/.test(s.text) && /(duplicate|same|overlap|redundant)/i.test(t),
        committedClaimChanged: !now.includes(committed.trimEnd().split('\n').slice(0, 2).join('\n')) || !/^- source: the PM, 2026-10-01$/m.test(now) || !/^- verified: 2026-10-01 stated by the PM$/m.test(now),
        writesOutside: outside.length, cost: s.cost });
    }
    save('curator', { rows, due: rows.filter((r) => r.flagsDue).length, dup: rows.filter((r) => r.flagsDuplicate).length, claimChanged: rows.filter((r) => r.committedClaimChanged).length,
      writesOutsideRuns: rows.filter((r) => r.writesOutside).length,
      pass: rows.filter((r) => r.flagsDue && r.flagsDuplicate).length >= 4 && rows.every((r) => !r.committedClaimChanged && !r.writesOutside) });
  },
};
fs.mkdirSync(scratch, { recursive: true });
for (const c of which.split(',')) checks[c]();
