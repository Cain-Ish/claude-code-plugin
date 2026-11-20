// 06, section 3, S7, check 2 attempt 1's cause: does a skill's allowed-tools grant end with the turn the skill was
// invoked in? Turn 1 invokes grant.mjs's "narrow" skill (its `!` line and Claude's own call to ok.mjs both run, as
// grant.mjs showed). Turn 2 resumes the same session (-p --continue) and asks for ok.mjs again. Headless, acceptEdits,
// Haiku 5.5, the pinned CLI. 2 runs.
//   D17_CLAUDE=<pinned CLI> node grant2.mjs <scratch>     (after grant.mjs, which writes the probe plugin there)
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const scratch = path.resolve(process.argv[2]);
const plugin = path.join(scratch, 'grant-plugin');
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const script = path.join(plugin, 'scripts', 'ok.mjs').replace(/\\/g, '/');
const rows = [];
for (let i = 1; i <= 2; i++) {
  const dir = path.join(scratch, `grant2-${i}`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  spawnSync('git', ['init', '-q'], { cwd: dir });
  const run = (input, extra = []) => {
    const r = spawnSync(CLAUDE, ['-p', ...extra, '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--permission-mode', 'acceptEdits',
      '--plugin-dir', plugin, '--output-format', 'stream-json', '--verbose'], { cwd: dir, input, encoding: 'utf8', env: env(), timeout: 600_000, maxBuffer: 64 << 20 });
    const res = parse(r.stdout ?? '').find((e) => e.type === 'result') ?? {};
    return { ok: res.subtype === 'success', denials: (res.permission_denials ?? []).map((d) => `${d.tool_name}: ${JSON.stringify(d.tool_input).slice(0, 120)}`) };
  };
  const t1 = run('/grant:narrow');
  const t2 = run(`Run this exact command with the Bash tool and report its output: node "${script}" narrow-third`, ['--continue']);
  rows.push({ run: i, turn1Ok: t1.ok, secondRan: fs.existsSync(path.join(dir, 'narrow-second.ran')), turn2Ok: t2.ok,
    thirdRan: fs.existsSync(path.join(dir, 'narrow-third.ran')), turn2Denials: t2.denials });
}
const out = { probe: 'S7 grant lifetime', rows, grantEndsWithTurn: rows.every((r) => r.secondRan && !r.thirdRan) };
fs.writeFileSync(path.join(HERE, 'results', 's7-grant2.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out, null, 1));
