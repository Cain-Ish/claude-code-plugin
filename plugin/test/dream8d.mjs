// 06, section 8, 8d (D35): proposals that rest on use. One case per registered item, on synthetic transcripts and
// staged proposals, run against the plugin folder given (default: this one). The exit code is the number of failures.
//   node dream8d.mjs [plugin folder]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PLUGIN = path.resolve(process.argv[2] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const D = await import(pathToFileURL(path.join(PLUGIN, 'scripts', 'dream.mjs')).href);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-dream8d-'));
let failed = 0;
const check = (id, ok, why = '') => { console.log(`${ok ? 'pass' : 'FAIL'}  ${id}${ok ? '' : `: ${why}`}`); if (!ok) failed++; };
const tryCheck = async (id, f) => { try { await f(); } catch (e) { check(id, false, e.message.split('\n')[0]); } };
const savedCfg = process.env.CLAUDE_CONFIG_DIR;

let n = 0;
function world(files) {
  const r = path.join(tmp, `r${++n}`);
  const cfg = path.join(tmp, `cfg${n}`);
  const data = path.join(tmp, `data${n}`);
  const g = (...a) => { const x = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: r, encoding: 'utf8' }); if (x.status) throw new Error(x.stderr); return x.stdout; };
  fs.mkdirSync(r, { recursive: true });
  g('init', '-q');
  for (const [f, t] of Object.entries({ '.project-map/decisions.md': '### dates\n> Dates show as DD.MM.YYYY.\n\n- id: dates\n- source: the lead developer, 2026-11-01\n- when: ["ui"]\n', '.project-map/dreams.md': '# Dream log\n\n', ...files })) {
    fs.mkdirSync(path.dirname(path.join(r, f)), { recursive: true });
    fs.writeFileSync(path.join(r, f), t);
  }
  g('add', '-A');
  g('commit', '-qm', 'base');
  const tdir = path.join(cfg, 'projects', fs.realpathSync.native(r).replace(/[^A-Za-z0-9]/g, '-'));
  fs.mkdirSync(tdir, { recursive: true });
  const J = (o) => JSON.stringify({ cwd: r, timestamp: '2026-11-20T10:00:00Z', ...o });
  const rec = {
    U: (text) => J({ type: 'user', promptSource: 'sdk', isMeta: false, message: { role: 'user', content: text } }),
    call: (id, name, input) => J({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } }),
    res: (id, text) => J({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: text }] } }),
  };
  rec.skill = (id, name) => rec.call(id, 'Skill', { skill: name });
  const session = (name, lines) => fs.writeFileSync(path.join(tdir, `${name}.jsonl`), `${lines.join('\n')}\n`);
  const run = path.join(r, '.project-map', '.dream-run');
  const stage = (p, t) => { fs.mkdirSync(path.dirname(path.join(run, 'proposals', p)), { recursive: true }); fs.writeFileSync(path.join(run, 'proposals', p), t); };
  // the digest whose text holds `marker`, and the line of its first U line holding it: evidence that does not depend on
  // the order the system lists sessions in
  const ref = (marker) => {
    for (const f of fs.readdirSync(path.join(run, 'digests'))) {
      const lines = fs.readFileSync(path.join(run, 'digests', f), 'utf8').split('\n');
      const i = lines.findIndex((l) => l.startsWith('U: ') && l.includes(marker));
      if (i >= 0) return `${f}:${i + 1}`;
    }
    throw new Error(`no digest holds ${marker}`);
  };
  return { r, cfg, data, g, rec, session, run, stage, ref, use: () => { process.env.CLAUDE_CONFIG_DIR = cfg; } };
}
const ev = (...refs) => `<!-- evidence: ${refs.join(', ')} -->\n`;
const agent = (name, extra = '') => `---\nname: ${name}\ndescription: Reviews a diff against the API conventions. Use when a change touches the API.\ntools: Read, Grep\n---\nRead the diff, list each convention it breaks.${extra}\n`;

// (1) agent drafts, and (2) change drafts, through every gate
await tryCheck('(1) agent drafts and (2) change drafts', async () => {
  const w = world({
    '.claude/skills/pricing-check/SKILL.md': '---\nname: pricing-check\ndescription: Check prices.\n---\nCheck the prices.\n',
    '.claude/skills/fmt/SKILL.md': '---\nname: fmt\ndescription: Format.\ndisable-model-invocation: true\n---\nFormat.\n',
    '.claude/skills/fmt/SKILL.md.draft': '---\nname: fmt\ndescription: Format.\n---\nAn earlier draft.\n',
    '.claude/agents/reviewer.md': '---\nname: reviewer\ndescription: Reviews.\ntools: Read\n---\nReview.\n',
    '.claude/agents/api-helper.md.draft': '---\nname: api-helper\ndescription: An earlier agent draft.\ntools: Read\n---\nHelp.\n',
    '.claude/skills/tidy/SKILL.md': '---\nname: tidy\ndescription: Tidy.\n---\nTidy.\n',
  });
  const { rec } = w;
  w.session('s1', [rec.U('Review this diff against our API conventions, marker A1.'), rec.skill('t1', 'pricing-check'), rec.res('t1', 'ok'), rec.U('No: prices round half up, marker C1.'), rec.skill('t2', 'fmt'), rec.res('t2', 'ok'), rec.skill('t3', 'ghost'), rec.res('t3', 'ok'), rec.skill('t7', 'tidy'), rec.res('t7', 'ok')]);
  w.session('s2', [rec.U('Review this diff against our API conventions, marker A2.'), rec.skill('t4', 'pricing-check'), rec.res('t4', 'ok'), rec.U('No: prices round half up again, marker C2.'), rec.skill('t5', 'fmt'), rec.res('t5', 'ok'), rec.skill('t6', 'ghost'), rec.res('t6', 'ok'), rec.skill('t8', 'tidy'), rec.res('t8', 'ok')]);
  w.session('s3', [rec.U('Something unrelated, marker N1.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const two = ev(w.ref('A1'), w.ref('A2'));
  const cor = ev(w.ref('C1'), w.ref('C2'));
  w.stage('agents/api-reviewer.md', `${agent('api-reviewer')}${two}`);
  w.stage('agents/lonely.md', `${agent('lonely')}${ev(w.ref('A1'))}`);
  w.stage('agents/reviewer.md', `${agent('reviewer')}${two}`);
  w.stage('agents/leaky.md', `${agent('leaky', ' Ask bob@example.com.')}${two}`);
  w.stage('agents/notools.md', `---\nname: notools\ndescription: No tools named.\n---\nDo the task.\n${two}`);
  w.stage('agents/api-helper.md', `${agent('api-helper')}${two}`);
  // a change keeps the live file's disable-model-invocation (pricing-check has none), whatever the staged text says
  w.stage('change/skills/pricing-check/SKILL.md', `---\nname: pricing-check\ndisable-model-invocation: true\ndescription: Check prices.\n---\nCheck the prices; round half up.\n${cor}`);
  w.stage('change/skills/fmt/SKILL.md', `---\nname: fmt\ndescription: Format.\n---\nFormat again.\n${cor}`);
  w.stage('change/skills/ghost/SKILL.md', `---\nname: ghost\ndescription: Ghost.\n---\nNo such skill here.\n${cor}`);
  w.stage('change/agents/reviewer.md', `---\nname: reviewer\ndescription: Reviews.\ntools: Read\n---\nReview harder.\n${cor}`);
  // a change the sessions used, with private data: refused for that, not for use
  w.stage('change/skills/tidy/SKILL.md', `---\nname: tidy\ndescription: Tidy.\n---\nMail bob@example.com.\n${cor}`);
  // the run folder's copy of the uses, edited to claim the reviewer was used: finish reads the data folder's copy
  const u = JSON.parse(fs.readFileSync(path.join(w.run, 'usage.json'), 'utf8'));
  for (const d of Object.values(u.digests)) d.uses.push({ kind: 'agent', name: 'reviewer' });
  fs.writeFileSync(path.join(w.run, 'usage.json'), JSON.stringify(u));
  const fin = D.finish(w.r, w.data);
  const has = (p) => fs.existsSync(path.join(w.r, p));
  const pc = has('.claude/skills/pricing-check/SKILL.md.draft') ? fs.readFileSync(path.join(w.r, '.claude/skills/pricing-check/SKILL.md.draft'), 'utf8') : '';
  check('(1) agent drafts', has('.claude/agents/api-reviewer.md.draft') && !has('.claude/agents/lonely.md.draft') && !has('.claude/agents/reviewer.md.draft') && !has('.claude/agents/leaky.md.draft') && !has('.claude/agents/notools.md.draft')
    && fs.readFileSync(path.join(w.r, '.claude/agents/api-helper.md.draft'), 'utf8').includes('An earlier agent draft')
    && /agent from fewer than two sessions/.test(fin) && /an agent the repo holds/.test(fin) && /agent with private data/.test(fin) && /agent without name, description or tools/.test(fin), fin);
  check('(2) change drafts', pc.includes('round half up') && !pc.includes('disable-model-invocation') && fs.readFileSync(path.join(w.r, '.claude/skills/fmt/SKILL.md.draft'), 'utf8').includes('An earlier draft')
    && !has('.claude/skills/ghost/SKILL.md.draft') && !has('.claude/agents/reviewer.md.draft') && !has('.claude/skills/tidy/SKILL.md.draft') && /change with private data/.test(fin)
    && /change for a file the repo lacks/.test(fin) && /change whose sessions did not use it/.test(fin),
    `${fin}\n--- ${pc}`);
});

// (1) and (2): a link on the path refuses both kinds
await tryCheck('(1) and (2) a link on the path', async () => {
  const outside = path.join(tmp, 'outside-agents');
  fs.mkdirSync(outside, { recursive: true });
  fs.writeFileSync(path.join(outside, 'reviewer.md'), '---\nname: reviewer\ndescription: Reviews.\ntools: Read\n---\nReview.\n');
  const w = world({});
  fs.rmSync(path.join(w.r, '.claude', 'agents'), { recursive: true, force: true });
  fs.mkdirSync(path.join(w.r, '.claude'), { recursive: true });
  fs.symlinkSync(outside, path.join(w.r, '.claude', 'agents'), 'junction');
  const { rec } = w;
  w.session('s1', [rec.U('Review the API diff, marker L1.'), rec.call('t1', 'Agent', { subagent_type: 'reviewer', prompt: 'x' }), rec.res('t1', 'ok'), rec.U('No, stricter please, marker K1.')]);
  w.session('s2', [rec.U('Review the API diff, marker L2.'), rec.call('t2', 'Agent', { subagent_type: 'reviewer', prompt: 'x' }), rec.res('t2', 'ok'), rec.U('No, stricter again, marker K2.')]);
  w.use();
  await D.prepare(w.r, w.data);
  w.stage('agents/api-reviewer.md', `${agent('api-reviewer')}${ev(w.ref('L1'), w.ref('L2'))}`);
  w.stage('change/agents/reviewer.md', `---\nname: reviewer\ndescription: Reviews.\ntools: Read\n---\nStricter.\n${ev(w.ref('K1'), w.ref('K2'))}`);
  const fin = D.finish(w.r, w.data);
  check('(1) and (2) a link on the path', !fs.existsSync(path.join(outside, 'api-reviewer.md.draft')) && !fs.existsSync(path.join(outside, 'reviewer.md.draft')) && /(^|\D)2 a link on its path/.test(fin), fin);
});

// (1) and (2), the review's cases: the name is the file's; an empty field; a skill a person starts stays so; every
// cited session used it; an agent's change; the files setup makes; private names
await tryCheck('(1) and (2) names, fields and use', async () => {
  const sk = (name, extra = '') => `---\nname: ${name}\ndescription: ${name}.\n${extra}---\n${name}.\n`;
  const ag = (name) => `---\nname: ${name}\ndescription: ${name}.\ntools: Read\n---\n${name}.\n`;
  const w = world({
    '.claude/skills/keep/SKILL.md': sk('keep', 'disable-model-invocation: true\n'), '.claude/skills/half/SKILL.md': sk('half'), '.claude/skills/wrongname/SKILL.md': sk('wrongname'),
    '.claude/skills/nodesc/SKILL.md': sk('nodesc'), '.claude/skills/single/SKILL.md': sk('single'),
    '.claude/agents/helper.md': ag('helper'), '.claude/agents/notools2.md': ag('notools2'), '.claude/agents/decision-checker.md': ag('decision-checker'),
  });
  const { rec } = w;
  const typed = (name) => JSON.stringify({ cwd: w.r, timestamp: '2026-11-20T10:00:00Z', type: 'user', message: { role: 'user', content: `<command-name>/${name}</command-name>` } });
  const calls = (k) => [rec.skill(`w${k}`, 'wrongname'), rec.res(`w${k}`, 'ok'), rec.skill(`n${k}`, 'nodesc'), rec.res(`n${k}`, 'ok'), rec.skill(`o${k}`, 'single'), rec.res(`o${k}`, 'ok'),
    ...['helper', 'notools2', 'decision-checker'].flatMap((a, i) => [rec.call(`a${k}${i}`, 'Agent', { subagent_type: a, prompt: 'x' }), rec.res(`a${k}${i}`, 'ok')])];
  w.session('s1', [rec.U('Start, marker S1.'), typed('keep'), rec.U('No, keep it shorter, marker K1.'), rec.skill('h1', 'half'), rec.res('h1', 'ok'), ...calls(1), rec.U('The helper must cite files, marker H1.')]);
  w.session('s2', [rec.U('Start again, marker S2.'), typed('keep'), rec.U('No, keep it shorter again, marker K2.'), ...calls(2), rec.U('The helper must cite files again, marker H2.')]);
  w.use();
  await D.prepare(w.r, w.data);
  const k = ev(w.ref('K1'), w.ref('K2')), h = ev(w.ref('H1'), w.ref('H2'));
  const uuid = 'a0b1c2d3-1111-2222-3333-444455556666';
  w.stage('change/skills/keep/SKILL.md', `---\nname: keep\ndescription: Keep.\n---\nKeep it short.\n${k}`);
  w.stage('change/skills/half/SKILL.md', `${sk('half')}${k}`);
  w.stage('change/skills/wrongname/SKILL.md', `${sk('other')}${k}`);
  w.stage('change/skills/nodesc/SKILL.md', `---\nname: nodesc\ndescription:\n---\nNo description.\n${k}`);
  w.stage('change/skills/single/SKILL.md', `${sk('single')}${ev(w.ref('K1'))}`);
  w.stage(`change/skills/${uuid}/SKILL.md`, `${sk(uuid)}${k}`);
  w.stage('change/agents/helper.md', `---\nname: helper\ndescription: Helps.\ntools: Read\n---\nCite each file.\n${h}`);
  w.stage('change/agents/notools2.md', `---\nname: notools2\ndescription: N.\n---\nN.\n${h}`);
  w.stage('change/agents/decision-checker.md', `${ag('decision-checker')}${h}`);
  w.stage('agents/misnamed.md', `${agent('reviewer2')}${h}`);
  w.stage('agents/emptytools.md', `---\nname: emptytools\ntools:\ndescription: Empty tools.\n---\nE.\n${h}`);
  w.stage(`agents/${uuid}.md`, `${agent(uuid)}${h}`);
  const fin = D.finish(w.r, w.data);
  const at = (p) => (fs.existsSync(path.join(w.r, p)) ? fs.readFileSync(path.join(w.r, p), 'utf8') : null);
  const none = ['skills/half/SKILL.md', 'skills/wrongname/SKILL.md', 'skills/nodesc/SKILL.md', 'skills/single/SKILL.md', 'agents/notools2.md', 'agents/decision-checker.md', 'agents/misnamed.md', 'agents/emptytools.md', `agents/${uuid}.md`]
    .filter((p) => at(`.claude/${p}.draft`) !== null);
  const want = ['1 change whose sessions did not use it', '2 a name that is not its file name', '2 change without name, description or tools', '1 a change to a file setup makes', '2 private data', '1 change from fewer than two sessions', '1 agent without name, description or tools'];
  check('(1) and (2) names, fields and use', /^disable-model-invocation: true$/m.test(at('.claude/skills/keep/SKILL.md.draft') ?? '') && (at('.claude/skills/keep/SKILL.md.draft') ?? '').includes('Keep it short')
    && (at('.claude/agents/helper.md.draft') ?? '').includes('Cite each file') && !none.length && want.every((x) => new RegExp(`(^|\\D)${x}`).test(fin)), `${fin}\n--- written: ${none.join(', ')}`);
});

// (3) touched files: repo-relative, none outside; counts by package in the report; a rule's paths must name folders
await tryCheck('(3) touched files and placement', async () => {
  const w = world({ 'packages/api/package.json': '{}\n', 'packages/api/src/a.ts': 'export {};\n', 'packages/web/package.json': '{}\n', 'packages/web/b.ts': 'export {};\n' });
  const { rec } = w;
  const at = (p) => path.join(w.r, p);
  w.session('s1', [rec.U('API errors carry a code, marker P1.'), rec.call('t1', 'Read', { file_path: at('packages/api/src/a.ts') }), rec.res('t1', 'x'), rec.call('t2', 'Edit', { file_path: at('packages/api/src/a.ts'), old_string: 'a', new_string: 'b' }), rec.res('t2', 'ok'), rec.call('t3', 'Read', { file_path: path.join(tmp, 'elsewhere.txt') }), rec.res('t3', 'x'),
    JSON.stringify({ cwd: w.r, timestamp: '2026-11-20T10:00:00Z', isSidechain: true, type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't9', name: 'Read', input: { file_path: at('packages/web/b.ts') } }] } })]);
  w.session('s2', [rec.U('Again: API errors carry a code, marker P2.'), rec.call('t4', 'Read', { file_path: at('packages/api/src/a.ts') }), rec.res('t4', 'x'), rec.call('t5', 'Read', { file_path: at('packages/web/b.ts') }), rec.res('t5', 'x')]);
  w.use();
  const out = await D.prepare(w.r, w.data);
  const u = JSON.parse(fs.readFileSync(path.join(w.run, 'usage.json'), 'utf8'));
  const all = Object.values(u.digests).flatMap((d) => d.touched);
  const pk = Object.values(u.digests).map((d) => d.packages.join('+')).sort();
  w.stage('rules/api-errors.md', `---\npaths: ["packages/api/**"]\n---\nAPI errors carry a code.\n${ev(w.ref('P1'), w.ref('P2'))}`);
  w.stage('rules/nowhere.md', `---\npaths: ["packages/nope/**"]\n---\nAPI errors carry a code.\n${ev(w.ref('P1'), w.ref('P2'))}`);
  const fin = D.finish(w.r, w.data);
  check('(3) touched files and placement', all.includes('packages/api/src/a.ts') && all.includes('packages/web/b.ts') && !all.some((f) => f.includes('elsewhere') || path.isAbsolute(f))
    && JSON.stringify(pk) === JSON.stringify(['packages/api', 'packages/api+packages/web']) && /Files these sessions touched, by package: packages\/api 2, packages\/web 1\./.test(out) && !/a\.ts/.test(out.split('\n').find((l) => l.startsWith('Files these')) ?? '')
    && fs.existsSync(path.join(w.r, '.claude/rules/api-errors.md.draft')) && !fs.existsSync(path.join(w.r, '.claude/rules/nowhere.md.draft')) && /rule paths naming a folder the repo lacks/.test(fin),
    JSON.stringify({ all, pk, out: out.split('\n').find((l) => l.startsWith('Files these')), fin }));
});

// (3), the review's cases: a worktree's session counts its files from its own root; an inline brace list is one glob;
// the YAML list form is checked; a NUL or a backslash is refused, never a crash
await tryCheck('(3) globs and worktrees', async () => {
  const w = world({ 'packages/api/package.json': '{}\n', 'packages/api/src/a.ts': 'export {};\n', 'packages/web/package.json': '{}\n' });
  w.g('worktree', 'add', '-q', '-b', 'feat', '.claude/worktrees/feat');
  // 8g: the session spells the repo through a link, as CI's macOS /var and Windows 8.3 temp folders do
  const alias = path.join(fs.mkdtempSync(path.join(tmp, 'alias-')), 'r');
  fs.symlinkSync(w.r, alias, 'junction');
  const wt = path.join(alias, '.claude', 'worktrees', 'feat');
  const { rec } = w;
  // the session's folder is a package inside the worktree, so a relative path resolves from there
  const inWt = (o) => JSON.stringify({ cwd: path.join(wt, 'packages', 'api'), timestamp: '2026-11-20T10:00:00Z', ...o });
  w.session('s1', [inWt({ type: 'user', promptSource: 'sdk', isMeta: false, message: { role: 'user', content: 'Errors carry a code, marker W1.' } }),
    inWt({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: 'src/a.ts' } }] } }),
    inWt({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't2', name: 'Edit', input: { file_path: path.join(wt, 'packages', 'web', 'package.json'), old_string: '{', new_string: '{ ' } }] } })]);
  w.session('s2', [rec.U('Errors carry a code again, marker W2.'), rec.call('t3', 'Read', { file_path: path.join(w.r, 'packages/api/src/a.ts') }), rec.res('t3', 'x')]);
  w.use();
  await D.prepare(w.r, w.data);
  const all = Object.values(JSON.parse(fs.readFileSync(path.join(w.run, 'usage.json'), 'utf8')).digests).flatMap((d) => d.touched);
  const e = ev(w.ref('W1'), w.ref('W2'));
  const rule = (name, paths) => w.stage(`rules/${name}.md`, `---\npaths:${paths}\n---\nErrors carry a code.\n${e}`);
  rule('brace', ' ["packages/{api,web}/**"]');
  rule('yamlgood', '\n  - packages/web/**');
  rule('yamlbad', '\n  - packages/nope/**');
  rule('nul', ' ["packages/a\u0000b/**"]');
  rule('back', ' ["packages\\api\\**"]');
  // a folder that exists, outside the repo
  rule('climb', ` ["../${path.basename(w.cfg)}/**"]`);
  const fin = D.finish(w.r, w.data);
  const has = (n) => fs.existsSync(path.join(w.r, '.claude', 'rules', `${n}.md.draft`));
  check('(3) globs and worktrees', all.includes('packages/api/src/a.ts') && all.includes('packages/web/package.json') && !all.includes('src/a.ts') && !all.some((f) => f.includes('worktrees'))
    && has('brace') && has('yamlgood') && !has('yamlbad') && !has('nul') && !has('back') && !has('climb') && /(^|\D)4 rule paths naming a folder the repo lacks/.test(fin), JSON.stringify({ all, fin }));
});

// (4) and (5): the analyzer's two new kinds; map-review lists agent and change drafts and promotes a change by
// replacing its file; the template's 2.5.1 text is listed for setup's update
await tryCheck('(4) and (5) texts', async () => {
  const an = fs.readFileSync(path.join(PLUGIN, 'agents', 'dream-analyzer.md'), 'utf8');
  const sk = fs.readFileSync(path.join(PLUGIN, 'skills', 'dream', 'SKILL.md'), 'utf8');
  const mr = fs.readFileSync(path.join(PLUGIN, 'templates', 'claude', 'skills', 'map-review', 'SKILL.md'), 'utf8');
  const { FILES } = await import(pathToFileURL(path.join(PLUGIN, 'scripts', 'setup.mjs')).href);
  const row = (FILES ?? []).find(([from]) => from === 'claude/skills/map-review/SKILL.md');
  check('(4) and (5) texts', an.includes('agent-task') && an.includes('artifact-correction') && an.includes('usage.json') && sk.includes('change/skills/<name>/SKILL.md') && sk.includes('agents/<name>.md')
    && mr.includes('.claude/agents/*.md.draft') && mr.includes('git diff --no-index') && mr.includes('which replaces the file a change draft sits beside') && !an.includes('Name the task') && (row?.[2] ?? []).includes('7ff1c09c889ebe9c'), JSON.stringify(row));
});

if (savedCfg === undefined) delete process.env.CLAUDE_CONFIG_DIR; else process.env.CLAUDE_CONFIG_DIR = savedCfg;
fs.rmSync(tmp, { recursive: true, force: true });
console.log(failed ? `${failed} case(s) failed` : 'dream8d ok');
process.exitCode = failed;
