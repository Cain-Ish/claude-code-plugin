// 06, section 3, S7, check 3: a dream's drafts never load. In manual, acceptEdits and auto, a session reads a file the
// draft rule's paths match; InstructionsLoaded (a probe plugin's hook) must never report the draft, the init event must
// not list the draft skill, and the draft rule's nonce must not land. Haiku 5.5, the pinned CLI.
//   D17_CLAUDE=<pinned CLI> node drafts.mjs <scratch>
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const scratch = path.resolve(process.argv[2]);
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
const put = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const dumpDir = path.join(scratch, 'il');
const probe = path.join(scratch, 'il-plugin');
put(path.join(probe, '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'il', version: '0.0.0' }));
put(path.join(probe, 'dump.mjs'), `import fs from 'node:fs';\nconst i = fs.readFileSync(0, 'utf8');\nfs.mkdirSync(${JSON.stringify(dumpDir)}, { recursive: true });\nfs.appendFileSync(${JSON.stringify(dumpDir)} + '/loads.jsonl', i.replace(/\\n/g, ' ') + '\\n');\n`);
put(path.join(probe, 'hooks', 'hooks.json'), JSON.stringify({ hooks: { InstructionsLoaded: [{ hooks: [{ type: 'command', command: 'node', args: ['${CLAUDE_PLUGIN_ROOT}/dump.mjs'] }] }] } }));
const rows = [];
for (const mode of ['manual', 'acceptEdits', 'auto']) {
  const dir = path.join(scratch, `drafts-${mode}`);
  fs.rmSync(dir, { recursive: true, force: true });
  put(path.join(dir, 'src', 'app.js'), 'export const one = 1;\n');
  put(path.join(dir, '.claude', 'rules', 'nonce.md.draft'), '---\npaths: ["src/**"]\n---\nEvery edit to a file under src/ must add the comment `// nonce-D7R` as its first line.\n');
  put(path.join(dir, '.claude', 'rules', 'control.md'), '---\npaths: ["src/**"]\n---\nFiles under src/ use two-space indentation.\n');
  put(path.join(dir, '.claude', 'skills', 'drafty', 'SKILL.md.draft'), '---\nname: drafty\ndescription: A draft skill. Use when asked about drafts.\ndisable-model-invocation: true\n---\nDraft.\n');
  spawnSync('git', ['init', '-q'], { cwd: dir });
  fs.rmSync(dumpDir, { recursive: true, force: true });
  const r = spawnSync(CLAUDE, ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--permission-mode', mode,
    '--output-format', 'stream-json', '--verbose', '--plugin-dir', probe], { cwd: dir, input: 'Read src/app.js, then add an exported function two() that returns 2 to it.', encoding: 'utf8', env: env(), timeout: 900_000, maxBuffer: 64 << 20 });
  const ev = parse(r.stdout ?? '');
  const init = ev.find((e) => e.type === 'system' && e.subtype === 'init') ?? {};
  const loads = fs.existsSync(path.join(dumpDir, 'loads.jsonl')) ? parse(fs.readFileSync(path.join(dumpDir, 'loads.jsonl'), 'utf8')) : [];
  const files = loads.map((l) => String(l.file_path ?? '').replace(/\\/g, '/'));
  rows.push({ mode, sessionOk: ev.some((e) => e.type === 'result' && e.subtype === 'success'),
    controlRuleLoaded: files.some((f) => f.endsWith('.claude/rules/control.md')), draftRuleLoaded: files.some((f) => f.includes('nonce.md.draft')),
    draftSkillListed: JSON.stringify(init.skills ?? []).includes('drafty') || JSON.stringify(init.slash_commands ?? []).includes('drafty'),
    nonceLanded: fs.readFileSync(path.join(dir, 'src', 'app.js'), 'utf8').includes('nonce-D7R') });
}
const out = { probe: 'S7 drafts', rows, pass: rows.every((r) => r.controlRuleLoaded && !r.draftRuleLoaded && !r.draftSkillListed && !r.nonceLanded) };
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', 's7-drafts.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out));
