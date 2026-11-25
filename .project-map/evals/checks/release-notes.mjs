// release, case "notes": the text the session added to the repo's Markdown files (outside .claude/) names the version
// in progress (plugin.json as the copy's first commit holds it) and the product's hash, computed here as
// plugin/test/selftest.mjs computes it. Any wording, in any Markdown file.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

const git = (...a) => spawnSync('git', a, { encoding: 'utf8', maxBuffer: 1 << 28 }).stdout ?? '';
const now = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
function product() {
  const files = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) if (e.name !== 'test') (e.isDirectory() ? walk : (p) => files.push(p))(path.join(d, e.name)); };
  walk('plugin');
  const h = crypto.createHash('sha256');
  for (const f of files.map((p) => path.relative('plugin', p).split(path.sep).join('/')).sort()) h.update(f).update(fs.readFileSync(path.join('plugin', f), 'utf8').replace(/\r\n/g, '\n'));
  return h.digest('hex').slice(0, 12);
}

let ok = false;
try {
  const root = git('rev-list', '--max-parents=0', 'HEAD').trim().split('\n').pop();
  const V = JSON.parse(git('show', `${root}:plugin/.claude-plugin/plugin.json`)).version;
  const touched = [...git('diff', '--name-only', root).split('\n'), ...git('ls-files', '--others', '--exclude-standard').split('\n')]
    .map((f) => f.trim()).filter((f) => f.endsWith('.md') && !f.startsWith('.claude/'));
  const added = [...new Set(touched)].map((f) => {
    const before = new Set(git('show', `${root}:${f}`).split(/\r?\n/));
    return now(f).split(/\r?\n/).filter((l) => !before.has(l)).join('\n');
  }).join('\n');
  ok = Boolean(V) && added.includes(V) && added.includes(product());
} catch {}
process.exitCode = ok ? 0 : 1;
