// 06, 4i, A-4 "the second run" (D14): does a correction in one session reach the next, fresh session?
//   D17_CLAUDE=<pinned CLI 2.1.305> node a4.mjs <scratch> floor <scenario> <runs>
//   D17_CLAUDE=<pinned CLI 2.1.305> node a4.mjs <scratch> <arm> <plugin copy> <first> <last> <scenario>
// floor: session 2 alone, no plugin, auto memory off, the tree as session 1 left it corrected: can the code alone teach it?
// arm: session 1 (the task, then the correction, resumed), then a fresh session 2 in the same tree, no commit between.
// Scenarios: price-F0 and price-F1 (as first registered; their floor saturated) and tokens (a generated file).
// Results: results/<floor|a4>-<scenario><A4_TAG>.json beside this file, counts and flags only, no transcript text.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(HERE, '..', 'V2-D17-eval', 'fixture');
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const MODEL = 'claude-opus-5-5';

const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
const CARD = 'src/components/ProductCard.tsx';
// the code lines a session added, comments removed so a comment such as "never toFixed" is not scored
const added = (before, after) => Object.entries(after).filter(([f, t]) => /^src\/.*\.tsx?$/.test(f) && before[f] !== t).flatMap(([f, t]) => {
  const old = new Set(strip(before[f] ?? '').split('\n'));
  return strip(t).split('\n').filter((l) => l.trim() && !old.has(l));
}).join('\n');
const usesFormat = (t) => /\bformatPrice\b/.test(t) && !/\.toFixed\(/.test(t);
const price = (legacy) => ({
  files: {
    'src/utils/money.ts': "export function formatPrice(amount: number, locale: string = navigator.language): string {\n  return new Intl.NumberFormat(locale, { style: 'currency', currency: 'EUR' }).format(amount);\n}\n",
    // F1: prices are still shown with toFixed elsewhere, as in a repo mid-migration
    ...(legacy ? {
      'src/components/CartSummary.tsx': "import { tokens } from '../theme/tokens';\n\nexport interface CartSummaryProps {\n  items: number;\n  total: number;\n}\n\nexport function CartSummary({ items, total }: CartSummaryProps) {\n  return (\n    <div style={{ padding: tokens.space.md }}>\n      <span style={{ color: tokens.color.textMuted }}>{items} items</span>\n      <strong style={{ fontSize: tokens.font.lg }}>{total.toFixed(2)}</strong>\n    </div>\n  );\n}\n",
      'src/widgets/DealBanner.tsx': "import { tokens } from '../theme/tokens';\n\nexport interface DealBannerProps {\n  title: string;\n  price: number;\n}\n\nexport function DealBanner({ title, price }: DealBannerProps) {\n  return (\n    <div style={{ padding: tokens.space.lg, background: tokens.color.surfaceRaised }}>\n      <span style={{ fontSize: tokens.font.lg }}>{title}</span>\n      <span style={{ color: tokens.color.accent }}>{price.toFixed(2)}</span>\n    </div>\n  );\n}\n",
    } : {}),
  },
  task1: 'Add a price label to ProductCard.',
  fix: "That's wrong: toFixed breaks the price for our German and French shoppers. Use formatPrice() from src/utils/money.ts instead.",
  task2: 'Add a price to StatTile.',
  corrected: (f) => ({ [CARD]: f[CARD].replace("import { Img } from './Img';", "import { Img } from './Img';\nimport { formatPrice } from '../utils/money';").replace('{product.price.toFixed(2)}', '{formatPrice(product.price)}') }),
  mistake: (base, t1) => /\.toFixed\(/.test(strip(t1[CARD] ?? '')),
  learned: (t1) => usesFormat(strip(t1[CARD] ?? '')),
  pass: (b, a) => usesFormat(added(b, a)),
  acted: (b, a) => !!added(b, a),
  marker: /formatPrice/,
  demo: { wrong: () => ({}), s2: (f) => ({ 'src/widgets/StatTile.tsx': `import { formatPrice } from '../utils/money';\n${f['src/widgets/StatTile.tsx']}` }) },
});

// tokens: src/theme/tokens.ts is generated from design/tokens.json, and nothing in tokens.ts says so
const TOKENS = JSON.parse(fs.readFileSync(path.join(FIXTURE, 'src', 'theme', 'tokens.ts'), 'utf8')
  .replace(/^export const tokens = /, '').replace(/ as const;\s*$/, '').replace(/'/g, '"').replace(/(\w+):/g, '"$1":').replace(/,(\s*[}\]])/g, '$1'));
const gen = (t) => `export const tokens = ${JSON.stringify(t, null, 2)} as const;\n`;
const JSONF = 'design/tokens.json', TS = 'src/theme/tokens.ts';
const colour = (s, k) => { try { return JSON.parse(s[JSONF]).color[k]; } catch { return undefined; } };
const tokens = {
  files: {
    [JSONF]: `${JSON.stringify(TOKENS, null, 2)}\n`,
    [TS]: gen(TOKENS),
    'scripts/build-tokens.mjs': "import fs from 'node:fs';\n\nconst t = JSON.parse(fs.readFileSync('design/tokens.json', 'utf8'));\nfs.writeFileSync('src/theme/tokens.ts', `export const tokens = ${JSON.stringify(t, null, 2)} as const;\\n`);\n",
    'package.json': (p) => p.replace('"build": "tsc && vite build"', '"tokens": "node scripts/build-tokens.mjs",\n    "build": "npm run tokens && tsc && vite build"'),
  },
  task1: 'Make the accent colour a bit darker.',
  fix: "That's wrong: src/theme/tokens.ts is generated from design/tokens.json, so your edit is lost on the next build. Change design/tokens.json instead.",
  task2: 'Make the danger colour a bit lighter.',
  corrected: () => { const t = structuredClone(TOKENS); t.color.accent = '#095c42'; return { [JSONF]: `${JSON.stringify(t, null, 2)}\n`, [TS]: gen(t) }; },
  mistake: (base, t1) => colour(t1, 'accent') === colour(base, 'accent') && t1[TS] !== base[TS],
  learned: (t1, base) => colour(t1, 'accent') !== colour(base, 'accent'),
  pass: (b, a) => colour(a, 'danger') !== colour(b, 'danger'),
  acted: (b, a) => colour(a, 'danger') !== colour(b, 'danger') || a[TS] !== b[TS],
  marker: /tokens\.json/,
  demo: { wrong: (f) => ({ [TS]: f[TS].replace(TOKENS.color.accent, '#085a40') }), s2: (f) => ({ [JSONF]: f[JSONF].replace(TOKENS.color.danger, '#e04848') }) },
};

// frozen: a rule the code cannot show once it is followed; src/legacy/ must not change, so restyle where it is used
const LEGACY_PART = (name) => `import type { CSSProperties } from 'react';\nimport { tokens } from '../theme/tokens';\n\nexport interface ${name}Props {\n  text: string;\n  style?: CSSProperties;\n}\n\nexport function ${name}({ text, style }: ${name}Props) {\n  return <span style={{ color: tokens.color.textMuted, fontSize: tokens.font.sm, ...style }}>{text}</span>;\n}\n`;
const legacyChanged = (b, a) => Object.keys({ ...b, ...a }).some((f) => f.startsWith('src/legacy/') && b[f] !== a[f]);
const frozen = {
  files: {
    'src/legacy/SaleBadge.tsx': LEGACY_PART('SaleBadge'),
    'src/legacy/StockLabel.tsx': LEGACY_PART('StockLabel'),
    [CARD]: (s) => s.replace("import { Img } from './Img';", "import { Img } from './Img';\nimport { SaleBadge } from '../legacy/SaleBadge';\nimport { StockLabel } from '../legacy/StockLabel';")
      .replace(/(<Img [^\n]*\/>\n)/, '$1      <SaleBadge text="Sale" />\n      <StockLabel text="In stock" />\n'),
  },
  task1: 'Make the sale badge red.',
  fix: "That's wrong: src/legacy/ is frozen until the payment audit is over, so nothing in it may change. Undo that and restyle it where it is used.",
  task2: 'Make the stock label bold.',
  corrected: (f) => ({ [CARD]: f[CARD].replace('<SaleBadge text="Sale" />', '<SaleBadge text="Sale" style={{ color: tokens.color.danger }} />') }),
  mistake: (base, t1) => legacyChanged(base, t1),
  learned: (t1, base) => !legacyChanged(base, t1),
  pass: (b, a) => !legacyChanged(b, a),
  acted: (b, a) => Object.keys(a).some((f) => a[f] !== b[f]),
  marker: /legacy/,
  demo: { wrong: (f) => ({ 'src/legacy/SaleBadge.tsx': f['src/legacy/SaleBadge.tsx'].replace('textMuted', 'danger') }), s2: (f) => ({ [CARD]: f[CARD].replace('<StockLabel text="In stock" />', '<StockLabel text="In stock" style={{ fontWeight: 700 }} />') }) },
};
const SCENARIOS = { 'price-F0': price(false), 'price-F1': price(true), tokens, frozen };

const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY']) delete e[k]; return e; };
const git = (cwd, ...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' });
const put = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const walk = (dir, skip = [], base = dir, out = {}) => {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (skip.includes(e.name)) continue;
    const f = path.join(dir, e.name);
    if (e.isDirectory()) walk(f, skip, base, out);
    else out[path.relative(base, f).replace(/\\/g, '/')] = fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
  }
  return out;
};
const tree = (repo) => walk(repo, ['.git', '.claude', '.project-map']);
const productHash = (dir) => {
  const files = walk(dir, ['test']); const h = crypto.createHash('sha256');
  for (const f of Object.keys(files).sort()) h.update(`${f}\0${files[f]}\0`);
  return h.digest('hex').slice(0, 12);
};

function session(cwd, prompt, { plugin, mem, resume } = {}) {
  const args = ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config',
    '--disallowedTools', 'Bash,WebFetch,WebSearch,Skill', '--permission-mode', 'acceptEdits',
    '--output-format', 'stream-json', '--verbose', ...(mem ? ['--add-dir', mem] : []),
    ...(plugin ? ['--plugin-dir', plugin, '--include-hook-events'] : []), ...(resume ? ['--resume', resume] : [])];
  const r = spawnSync(CLAUDE, args, { cwd, input: prompt, encoding: 'utf8', env: env(), timeout: 1_200_000, maxBuffer: 256 << 20 });
  const ev = parse(r.stdout ?? '');
  const res = ev.find((e) => e.type === 'result') ?? {};
  const init = ev.find((e) => e.subtype === 'init') ?? {};
  const bad = [];
  if (res.subtype !== 'success' || res.is_error) bad.push('no success result');
  if (!String(init.model ?? '').startsWith(MODEL)) bad.push(`model ${init.model}`);
  if (plugin && !init.plugins?.some((p) => p.name === 'second-brain')) bad.push('plugin not loaded');
  const touched = ev.filter((e) => e.type === 'assistant').flatMap((e) => e.message?.content ?? []).filter((c) => c.type === 'tool_use')
    .map((c) => String(c.input?.file_path ?? c.input?.path ?? c.input?.pattern ?? '').replace(/\\/g, '/'));
  return { sid: res.session_id ?? init.session_id, bad, touched, cost: res.total_cost_usd ?? 0 };
}

function makeRepo(repo, sc, mem) {
  fs.rmSync(repo, { recursive: true, force: true });
  fs.cpSync(FIXTURE, repo, { recursive: true });
  for (const [p, s] of Object.entries(sc.files)) put(path.join(repo, p), typeof s === 'function' ? s(fs.readFileSync(path.join(repo, p), 'utf8')) : s);
  put(path.join(repo, '.claude', 'settings.local.json'), `${JSON.stringify(mem ? { autoMemoryEnabled: true, autoMemoryDirectory: mem } : { autoMemoryEnabled: false }, null, 2)}\n`);
  git(repo, 'init', '-q'); git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'base');
}

function save(name, key, rec, head) {
  const file = path.join(HERE, 'results', `${name}${process.env.A4_TAG ?? ''}.json`);
  const all = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { ...head, runs: {} };
  all.runs[key] = rec;
  put(file, `${JSON.stringify(all, null, 1)}\n`);
  console.log(`${key}: ${JSON.stringify(rec)}`);
}

const [scratchArg, mode, a, b, c, scArg] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const head = { model: MODEL, cli: spawnSync(CLAUDE, ['--version'], { encoding: 'utf8', env: env() }).stdout.trim() };
const round = (n) => Math.round(n * 100) / 100;

if (mode === 'check') { // the scorers on hand-made trees, no CLI: node a4.mjs <scratch> check
  for (const [name, sc] of Object.entries(SCENARIOS)) {
    const repo = path.join(scratch, `check-${name}`);
    makeRepo(repo, sc, null);
    const base = tree(repo), fixed = { ...base, ...sc.corrected(base) };
    const wrong = { ...base, ...sc.demo.wrong(base) }, s2 = { ...fixed, ...sc.demo.s2(fixed) };
    const ok = sc.mistake(base, wrong) && !sc.mistake(base, fixed) && sc.learned(fixed, base) && !sc.learned(wrong, base)
      && sc.pass(fixed, s2) && sc.acted(fixed, s2) && !sc.pass(fixed, { ...fixed, ...sc.demo.wrong(fixed) }) && !sc.acted(fixed, fixed);
    console.log(`${name}: ${ok ? 'ok' : 'FAIL'}`);
    if (!ok) process.exitCode = 1;
  }
} else if (mode === 'floor') {
  const sc = SCENARIOS[a];
  for (let i = 1; i <= Number(b); i++) {
    const repo = path.join(scratch, `floor-${a}-${i}`);
    makeRepo(repo, sc, null);
    for (const [p, s] of Object.entries(sc.corrected(tree(repo)))) put(path.join(repo, p), s);
    const before = tree(repo);
    const s = session(repo, sc.task2);
    const after = tree(repo);
    save(`floor-${a}`, String(i), { valid: !s.bad.length && sc.acted(before, after), pass: sc.pass(before, after), bad: s.bad, cost: round(s.cost) }, head);
  }
} else {
  const arm = mode, plugin = path.resolve(a), sc = SCENARIOS[scArg];
  head.plugin = { [arm]: productHash(plugin) };
  for (let i = Number(b); i <= Number(c); i++) {
    const dir = path.join(scratch, `${scArg}-${arm}-${i}`);
    const repo = path.join(dir, 'repo'), mem = path.join(dir, 'mem');
    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(mem, { recursive: true });
    makeRepo(repo, sc, mem);
    const base = tree(repo);
    const s1 = session(repo, sc.task1, { plugin, mem });
    const mistake = sc.mistake(base, tree(repo));
    const fix = mistake ? session(repo, sc.fix, { plugin, mem, resume: s1.sid }) : { bad: [], cost: 0 };
    const before = tree(repo);
    const mapText = Object.values(walk(path.join(repo, '.project-map'))).join('\n');
    const memText = Object.values(walk(mem)).join('\n');
    const s2 = session(repo, sc.task2, { plugin, mem });
    const after = tree(repo);
    const bad = [...s1.bad.map((x) => `s1: ${x}`), ...fix.bad.map((x) => `fix: ${x}`), ...s2.bad.map((x) => `s2: ${x}`), ...(sc.acted(before, after) ? [] : ['s2: did not do the task'])];
    save(`a4-${scArg}`, `${arm}-${i}`, {
      arm, plugin: head.plugin[arm], mistake, counted: mistake && !bad.length, pass: sc.pass(before, after),
      learnedInS1: sc.learned(before, base), mapHolds: sc.marker.test(mapText), memHolds: sc.marker.test(memText),
      s2ReadMap: s2.touched.some((p) => p.includes('.project-map')), bad, cost: round(s1.cost + fix.cost + s2.cost),
    }, head);
  }
}
