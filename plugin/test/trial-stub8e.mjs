// The self-test's stand-in for claude in a trial (8e): it records its arguments, its environment and what the copy
// holds, then writes out.txt: "pass" when the artifact is at its live path, or when the prompt is one where it should
// not be used; "fail" otherwise. A check script reads out.txt. It ends as claude -p --output-format json does: one
// result record. STUB_FAIL=1 makes it a failed session (an error result). 8i: STUB_EDIT (paths, by the system's
// delimiter) appends a line to each, as a person editing during a run; STUB_REPO records whether git sees the repo's
// trial folder; STUB_HOLD (a file) makes the first session leave a program running in its copy, its id in that file;
// STUB_PROJECT leaves the copy's project folder under CLAUDE_CONFIG_DIR, as Claude Code does, with a subagent's
// transcript in it on the unrelated prompt. 8k: it records its folder, so a case can check that each copy is gone, and
// whether a user's token reached it (X-3); with the session's environment an allowlist, trial8e passes the STUB_
// variables through a file that loads this one
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';

const live = process.env.STUB_LIVE;
const prompt = process.argv[process.argv.indexOf('-p') + 1] ?? '';
fs.appendFileSync(process.env.STUB_LOG, `${JSON.stringify({
  args: process.argv.slice(2),
  cwd: process.cwd(),
  env: { CLAUDECODE: process.env.CLAUDECODE ?? null, CLAUDE_CODE_ENTRYPOINT: process.env.CLAUDE_CODE_ENTRYPOINT ?? null, GITHUB_TOKEN: process.env.GITHUB_TOKEN ?? null },
  has: fs.existsSync(live),
  helper: process.env.STUB_HELPER ? fs.existsSync(process.env.STUB_HELPER) : null,
  evals: fs.existsSync('.project-map/evals'),
  untracked: fs.existsSync('untracked.txt'),
  commits: spawnSync('git', ['rev-list', '--count', 'HEAD'], { encoding: 'utf8', windowsHide: true }).stdout.trim(),
  message: spawnSync('git', ['log', '-1', '--format=%s'], { encoding: 'utf8', windowsHide: true }).stdout.trim(),
  trialSeen: process.env.STUB_REPO ? spawnSync('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: process.env.STUB_REPO, encoding: 'utf8', windowsHide: true }).stdout.includes('.trial') : null,
})}\n`);
for (const f of process.env.STUB_EDIT ? process.env.STUB_EDIT.split(path.delimiter) : []) fs.appendFileSync(f, 'Edited during the run.\n');
if (process.env.STUB_HOLD && !fs.existsSync(process.env.STUB_HOLD)) {
  // stdio ignored, so the session's end does not wait for it
  const h = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], { cwd: process.cwd(), detached: true, stdio: 'ignore', windowsHide: true });
  fs.writeFileSync(process.env.STUB_HOLD, String(h.pid));
  h.unref();
}
if (process.env.STUB_PROJECT) {
  const sub = path.join(process.env.CLAUDE_CONFIG_DIR, 'projects', fs.realpathSync.native(process.cwd()).replace(/[^A-Za-z0-9]/g, '-'), 's1', 'subagents');
  fs.mkdirSync(path.join(sub, '..', '..', 'memory'), { recursive: true });
  fs.mkdirSync(sub, { recursive: true });
  fs.writeFileSync(path.join(sub, 'agent-1.meta.json'), '{}\n');
  if (/unrelated/.test(prompt)) fs.writeFileSync(path.join(sub, 'agent-1.jsonl'), '{}\n');
}
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
