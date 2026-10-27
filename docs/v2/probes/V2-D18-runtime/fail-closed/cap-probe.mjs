// V2-D18 reopened (2026-10-27, 06 step 2g attempt 3), the live half of the cap check: a Haiku session in a repo whose
// session-start text passes Claude Code's 10,000-character cap, with the 61964f9bbb40 hooks (old/) and the fixed ones.
// Each is asked for D23's line and the index's last listed directory. Prints counts and replies only.
//   node cap-probe.mjs <new plugin dir> [claude binary] [directories, default 350] [old|new|both, default both]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [newDir, claude = 'claude', count = '350', which = 'both'] = process.argv.slice(2);
const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-cap-'));
const git = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'core.autocrlf=false', ...a], { cwd: repo });
for (let i = 0; i < Number(count); i++) {
  const d = path.join(repo, 'packages', `package-${String(i).padStart(3, '0')}`);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, 'README.md'), '# p\n');
}
git('init', '-q');
git('add', '-A');
git('commit', '-q', '-m', 'init');
const env = { ...process.env, MSYS_NO_PATHCONV: '1', DISABLE_AUTOUPDATER: '1' };
for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
const prompt = 'Do two things, then reply with only the two results, numbered. (1) Quote word for word the sentence in your '
  + 'context that begins "When you finish, name each". If there is no such sentence, write: none. (2) Name the last directory '
  + "listed in this project's document index as it appears in your context, and quote any line in your context that begins "
  + 'with "(" and mentions "more directories". If there is none, write: none.';
const out = {};
for (const [k, dir] of [['old', path.join(HERE, 'old')], ['new', path.resolve(newDir)]].filter(([k]) => which === 'both' || which === k)) {
  const r = spawnSync(claude, ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--plugin-dir', dir,
    '--disallowedTools', 'Bash,Grep,Glob,WebFetch,WebSearch', '--output-format', 'stream-json', '--verbose', '--include-hook-events'],
  { cwd: repo, input: prompt, encoding: 'utf8', env, timeout: 600_000, maxBuffer: 64 << 20 });
  const ev = r.stdout.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
  const start = ev.filter((e) => e.subtype === 'hook_response' && e.hook_event === 'SessionStart').map((e) => String(e.output ?? ''));
  out[k] = { cli: ev.find((e) => e.subtype === 'init')?.claude_code_version, loaded: ev.find((e) => e.subtype === 'init')?.plugins?.some((p) => p.name === 'second-brain'),
    sessionStartChars: start.map((s) => s.length), reply: ev.findLast((e) => e.type === 'result')?.result ?? '' };
}
fs.rmSync(repo, { recursive: true, force: true });
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', `cap-probe-${count}-${which}.json`), `${JSON.stringify({ directories: Number(count), ...out }, null, 1)}\n`);
console.log(JSON.stringify(out, null, 1));
