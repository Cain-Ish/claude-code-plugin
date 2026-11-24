// 8e's probe: one headless session runs the skill; the session must end long before the child writes its marker.
// Prints whether the session ended first and whether the marker appeared 150 s after the start, from start to check.
//   node run.mjs <scratch folder>      then, 3 minutes later:   node run.mjs <scratch folder> check
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const [scratch, mode] = process.argv.slice(2).map((a, i) => (i ? a : path.resolve(a)));
const marker = path.join(scratch, 'marker');
const out = path.join(HERE, 'result.json');
if (mode === 'check') {
  const r = JSON.parse(fs.readFileSync(out, 'utf8'));
  Object.assign(r, { childStarted: fs.existsSync(`${marker}.start`), markerAfterSession: fs.existsSync(marker), checkedAt: new Date().toISOString() });
  r.pass = r.sessionEnded && r.childStarted && r.markerAfterSession;
  fs.writeFileSync(out, `${JSON.stringify(r, null, 1)}\n`);
  console.log(JSON.stringify(r));
} else {
  fs.rmSync(scratch, { recursive: true, force: true });
  fs.mkdirSync(scratch, { recursive: true });
  spawnSync('git', ['init', '-q'], { cwd: scratch });
  const env = { ...process.env, SB_PROBE_MARKER: marker };
  for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
  const t0 = Date.now();
  const r = spawnSync('claude', ['-p', '/sbprobe:go', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--plugin-dir', path.join(HERE, 'plugin'), '--output-format', 'json'], { cwd: scratch, env, encoding: 'utf8', timeout: 300_000 });
  const res = JSON.parse(r.stdout || '{}');
  const result = { date: new Date().toISOString().slice(0, 10), sessionEnded: r.status === 0 && !res.is_error, sessionSeconds: Math.round((Date.now() - t0) / 1000), markerBeforeEnd: fs.existsSync(marker) };
  fs.writeFileSync(out, `${JSON.stringify(result, null, 1)}\n`);
  console.log(JSON.stringify(result));
}
