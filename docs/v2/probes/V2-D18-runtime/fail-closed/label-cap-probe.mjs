// V2-D18, the second release review's J3 (2026-10-27): does the read hook's label text reach Claude whole past
// Claude Code's cap? A map file of <n> committed entries plus one uncommitted entry at its end; a Haiku session reads it
// and is asked for the label of the last entry. Prints counts and the reply only.
//   node label-cap-probe.mjs <plugin dir> [entries, default 300] [claude binary]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [pluginDir, count = '300', claude = 'claude'] = process.argv.slice(2);
const n = Number(count);
const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-labelcap-'));
const git = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'core.autocrlf=false', ...a], { cwd: repo });
const entry = (i, d) => `### decision ${i}\n> Rule number ${i} applies to this part of the project.\n\n- source: the designer, ${d}\n- when: ["x"]\n`;
fs.mkdirSync(path.join(repo, '.project-map'));
fs.writeFileSync(path.join(repo, 'README.md'), '# r\n');
fs.writeFileSync(path.join(repo, '.project-map', 'captured.md'), Array.from({ length: n }, (_, i) => entry(i + 1, '2026-10-20')).join('\n'));
git('init', '-q');
git('add', '-A');
git('commit', '-q', '-m', 'init');
fs.appendFileSync(path.join(repo, '.project-map', 'captured.md'), `\n${entry(n + 1, '2026-10-27')}`);
const env = { ...process.env, MSYS_NO_PATHCONV: '1', DISABLE_AUTOUPDATER: '1' };
for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
const prompt = `Use the Read tool on .project-map/captured.md. A hook adds labels after that read. Reply with only two lines: (1) the `
  + `label the hook gave for entry number ${n + 1} ("decision ${n + 1}"), quoted word for word, or "no label seen" if none reached `
  + 'you; (2) the number of label lines you can see.';
const r = spawnSync(claude, ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--plugin-dir', path.resolve(pluginDir),
  '--disallowedTools', 'Bash,Grep,Glob,WebFetch,WebSearch', '--output-format', 'stream-json', '--verbose', '--include-hook-events'],
{ cwd: repo, input: prompt, encoding: 'utf8', env, timeout: 600_000, maxBuffer: 64 << 20 });
const ev = r.stdout.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const post = ev.filter((e) => e.subtype === 'hook_response' && e.hook_event === 'PostToolUse').map((e) => String(e.output ?? ''));
// the tools Claude called, file names only: a Read of a spilled hook output shows the preview path was followed
const tools = ev.filter((e) => e.type === 'assistant').flatMap((e) => (e.message?.content ?? []).filter((c) => c.type === 'tool_use')
  .map((c) => `${c.name} ${path.basename(String(c.input?.file_path ?? ''))}`));
const out = { entries: n + 1, labelChars: post.map((s) => s.length), tools, reply: ev.findLast((e) => e.type === 'result')?.result ?? '' };
fs.rmSync(repo, { recursive: true, force: true });
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', `label-cap-probe-${n}.json`), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out, null, 1));
