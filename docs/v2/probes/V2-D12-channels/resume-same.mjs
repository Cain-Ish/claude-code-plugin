// C1's resume miss (06, registered 2026-11-12): does Claude Code attach a resume's SessionStart context when it is
// identical to context already in the restored conversation? Arms SAME (startup and resume print one nonce) and DIFF
// (resume prints its own nonce, D12's RE cell). D12's method: fresh repo and plugin per run, Haiku, user settings out.
//   node resume-same.mjs <scratch-dir> [runs]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
if (!process.argv[2]) throw new Error('usage: node resume-same.mjs <scratch-dir> [runs]');
const scratch = path.resolve(process.argv[2]);
const RUNS = Number(process.argv[3] ?? 3);
const LIST = 'every token in your context that begins with "PRB-", one per line, copied exactly, or "none"';
const nonce = (code) => `PRB-${code}-${crypto.randomBytes(3).toString('hex')}`;
const put = (f, text) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); };
const HOOK = `const N = require('./nonces.json');
process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: 'Marker: ' + N[process.argv[2]] } }));
`;
const ARGS = (plugin, extra = []) => ['-p', '--model', 'haiku', '--setting-sources', 'project,local', '--plugin-dir', plugin,
  '--disallowedTools', 'Bash,Grep,Glob,WebFetch,WebSearch', '--permission-mode', 'acceptEdits', '--output-format', 'stream-json', '--verbose', ...extra];
const ENV = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; delete e.CLAUDECODE; delete e.CLAUDE_CODE_ENTRYPOINT; return e; };
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const claude = (repo, plugin, prompt, raw, extra) => {
  const r = spawnSync('claude', ARGS(plugin, extra), { cwd: repo, input: prompt, encoding: 'utf8', env: ENV(), timeout: 600_000, maxBuffer: 256 << 20 });
  fs.writeFileSync(raw, (r.stdout ?? '') + (r.stderr ? `\n#stderr ${r.stderr}` : ''));
  return parse(r.stdout ?? '');
};
const said = (ev) => ev.filter((e) => e.type === 'assistant' && !e.parent_tool_use_id)
  .flatMap((e) => e.message?.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
const transcript = (id) => {
  const root = path.join(os.homedir(), '.claude', 'projects');
  for (const d of fs.readdirSync(root)) { const f = path.join(root, d, `${id}.jsonl`); if (fs.existsSync(f)) return f; }
  return null;
};

const results = { date: new Date().toISOString().slice(0, 10), cli: spawnSync('claude', ['--version'], { encoding: 'utf8' }).stdout.trim(), runs: RUNS, arms: { SAME: [], DIFF: [] } };
for (let run = 1; run <= RUNS; run++) {
  for (const arm of ['SAME', 'DIFF']) {
    const dir = path.join(scratch, `${arm}-${run}`);
    fs.rmSync(dir, { recursive: true, force: true });
    const ss = nonce('SS');
    const N = { SS: ss, RE: arm === 'SAME' ? ss : nonce('RE') };
    const repo = path.join(dir, 'repo'); const plugin = path.join(dir, 'plugin');
    put(path.join(repo, 'CLAUDE.md'), '# Project notes\n');
    spawnSync('git', ['init', '-q'], { cwd: repo });
    const hook = (k) => ({ type: 'command', command: `node "\${CLAUDE_PLUGIN_ROOT}/hook.cjs" ${k}` });
    put(path.join(plugin, '.claude-plugin/plugin.json'), JSON.stringify({ name: 'prb', version: '0.0.1', description: 'Resume probe' }));
    put(path.join(plugin, 'nonces.json'), JSON.stringify(N));
    put(path.join(plugin, 'hook.cjs'), HOOK);
    put(path.join(plugin, 'hooks/hooks.json'), JSON.stringify({ hooks: { SessionStart: [
      { matcher: 'startup', hooks: [hook('SS')] }, { matcher: 'resume', hooks: [hook('RE')] }] } }));

    const a = claude(repo, plugin, 'Reply with the single word OK.', path.join(dir, 'p1.jsonl'), []);
    const id = a.find((e) => e.session_id)?.session_id;
    const b = id ? claude(repo, plugin, `Without using any tool, list ${LIST}.`, path.join(dir, 'p2.jsonl'), ['--resume', id]) : [];
    const t = id && transcript(id);
    // attachments of the hook's text, before and after the resume's hook ran
    const recs = t ? parse(fs.readFileSync(t, 'utf8')) : [];
    const reHook = recs.findIndex((r) => r.attachment?.type === 'hook_success' && r.attachment.hookName === 'SessionStart:resume');
    const ctxAt = recs.map((r, i) => (r.attachment?.type === 'hook_additional_context' && [].concat(r.attachment.content).join('').includes(N.RE) ? i : -1)).filter((i) => i >= 0);
    const row = { run, sessionId: !!id, transcript: !!t, resumeHookRan: reHook >= 0,
      attachedAtResume: reHook >= 0 && ctxAt.some((i) => i > reHook), deliveries: ctxAt.length, quoted: said(b).includes(N.RE) };
    results.arms[arm].push(row);
    console.log(arm, JSON.stringify(row));
  }
}
const n = (arm, k) => results.arms[arm].filter((r) => r[k]).length;
results.summary = { DIFF_attached: n('DIFF', 'attachedAtResume'), SAME_attached: n('SAME', 'attachedAtResume'), SAME_quoted: n('SAME', 'quoted'), DIFF_quoted: n('DIFF', 'quoted') };
results.hypothesis = results.summary.DIFF_attached === RUNS && results.summary.SAME_attached === 0 && results.summary.SAME_quoted === RUNS ? 'pass'
  : results.summary.SAME_attached === RUNS ? 'falls' : 'unreliable';
fs.writeFileSync(path.join(HERE, 'results-resume-same.json'), `${JSON.stringify(results, null, 1)}\n`);
console.log(JSON.stringify(results.summary), results.hypothesis);
