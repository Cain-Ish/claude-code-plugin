// V2-D27 check 2: does session start's systemMessage reach the stream, beside an unchanged additionalContext?
// Two Haiku sessions load the plugin copy with --plugin-dir: BRAIN_DIR with a v1 shim, and an empty one.
// Usage: node deliver.mjs <plugin dir> <claude binary> <out dir>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const [plugin, claude = 'claude', out] = process.argv.slice(2);
const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'd27-'));
spawnSync('git', ['init', '-q'], { cwd: repo });
fs.writeFileSync(path.join(repo, 'README.md'), '# r\n');
spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'add', '-A'], { cwd: repo });
spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '-m', 'init'], { cwd: repo });

const run = (arm, brain) => {
  const env = { ...process.env, BRAIN_DIR: brain, MSYS_NO_PATHCONV: '1', DISABLE_AUTOUPDATER: '1' };
  for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
  const r = spawnSync(claude, ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config',
    '--plugin-dir', plugin, '--output-format', 'stream-json', '--verbose', '--include-hook-events'],
  { cwd: repo, input: 'Reply with only the word ok.', encoding: 'utf8', env, timeout: 300_000, maxBuffer: 64 << 20 });
  fs.writeFileSync(path.join(out, `${arm}.jsonl`), r.stdout);
  const ev = r.stdout.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
  const hooks = ev.filter((e) => /hook/.test(e.subtype ?? '') && /SessionStart/.test(JSON.stringify(e)));
  const raw = hooks.map((e) => e.output ?? e.stdout ?? '').join('');
  let parsed = {};
  try { parsed = JSON.parse(raw); } catch {}
  const shown = ev.filter((e) => JSON.stringify(e).includes('second-brain v1 left')).map((e) => `${e.type}/${e.subtype ?? ''}`);
  return { arm, exit: r.status, hookEvents: hooks.map((e) => e.subtype), systemMessage: parsed.systemMessage ?? null,
    context: parsed.hookSpecificOutput?.additionalContext ?? null, eventsWithLine: shown,
    reply: ev.find((e) => e.type === 'result')?.result ?? null };
};

const v1 = fs.mkdtempSync(path.join(os.tmpdir(), 'd27-v1-'));
fs.mkdirSync(path.join(v1, 'bin'));
fs.writeFileSync(path.join(v1, 'bin', 'sb-extract-drain.sh'), '');
const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'd27-empty-'));
const a = run('with-v1', v1);
const b = run('without', empty);
console.log(JSON.stringify([a, b].map(({ context, ...r }) => ({ ...r, contextBytes: Buffer.byteLength(context ?? '') })), null, 1));
console.log('additionalContext identical:', a.context !== null && a.context === b.context);
