// release, case "which-version" (where it should not be used): answer.md names the version plugin.json holds in the
// copy's first commit, and the release files (both manifests, the README, the plan, the self-test) are unchanged.
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const git = (...a) => spawnSync('git', a, { encoding: 'utf8', maxBuffer: 1 << 28 });
let ok = false;
try {
  const root = git('rev-list', '--max-parents=0', 'HEAD').stdout.trim().split('\n').pop();
  const V = JSON.parse(git('show', `${root}:plugin/.claude-plugin/plugin.json`).stdout).version;
  const answer = fs.readFileSync('answer.md', 'utf8');
  const untouched = git('diff', '--quiet', root, '--', 'plugin/.claude-plugin/plugin.json', '.claude-plugin/marketplace.json',
    'README.md', 'docs/v2/06-first-slice.md', 'plugin/test/selftest.mjs').status === 0;
  ok = Boolean(V) && answer.includes(V) && untouched;
} catch {}
process.exitCode = ok ? 0 : 1;
