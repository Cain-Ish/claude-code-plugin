// The self-test's stand-in for claude in a trial (8e): it records its arguments, its environment and what the copy
// holds, then writes out.txt: "pass" when the artifact is at its live path, or when the prompt is one where it should
// not be used; "fail" otherwise. A check script reads out.txt. It ends as claude -p --output-format json does: one
// result record. STUB_FAIL=1 makes it a failed session (an error result)
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const live = process.env.STUB_LIVE;
const prompt = process.argv[process.argv.indexOf('-p') + 1] ?? '';
fs.appendFileSync(process.env.STUB_LOG, `${JSON.stringify({
  args: process.argv.slice(2),
  env: { CLAUDECODE: process.env.CLAUDECODE ?? null, CLAUDE_CODE_ENTRYPOINT: process.env.CLAUDE_CODE_ENTRYPOINT ?? null },
  has: fs.existsSync(live),
  helper: process.env.STUB_HELPER ? fs.existsSync(process.env.STUB_HELPER) : null,
  evals: fs.existsSync('.project-map/evals'),
  untracked: fs.existsSync('untracked.txt'),
  commits: spawnSync('git', ['rev-list', '--count', 'HEAD'], { encoding: 'utf8', windowsHide: true }).stdout.trim(),
  message: spawnSync('git', ['log', '-1', '--format=%s'], { encoding: 'utf8', windowsHide: true }).stdout.trim(),
})}\n`);
// a session that tries to change what judges it or another session's work: every check script it can find in the
// temp folder now passes, and every other copy's out.txt says "pass" (06, 8e, attempt 3: run one at a time, with the
// check on stdin, neither reaches anything)
if (process.env.STUB_TOUCH_CHECKS) {
  const here = fs.realpathSync.native(process.cwd());
  for (const d of fs.readdirSync(os.tmpdir()).filter((f) => f.startsWith('second-brain-'))) {
    const dir = path.join(os.tmpdir(), d);
    try {
      for (const f of fs.readdirSync(dir, { recursive: true })) if (String(f).endsWith('.mjs')) fs.writeFileSync(path.join(dir, String(f)), 'process.exit(0);\n');
      if (fs.realpathSync.native(dir) !== here) fs.writeFileSync(path.join(dir, 'out.txt'), 'pass\n');
    } catch {}
  }
}
fs.writeFileSync('out.txt', fs.existsSync(live) || /unrelated/.test(prompt) ? 'pass\n' : 'fail\n');
process.stdout.write(JSON.stringify({ type: 'result', is_error: Boolean(process.env.STUB_FAIL), result: 'done' }));
