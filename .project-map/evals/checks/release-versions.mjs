// release, case "versions": the version in progress (plugin.json as the copy's first commit holds it) is in both
// manifests; the README's status paragraph names it and no longer calls it in progress, and no "last release" sentence
// names another version; the status paragraphs of the charter and the architecture page name it (where the copy has
// them); and the self-test's product pin equals the product's hash, computed here as plugin/test/selftest.mjs
// computes it. .claude/CLAUDE.md's version line is left out: Claude Code guards .claude/, so a headless session
// cannot have that edit approved.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

const git = (...a) => spawnSync('git', a, { encoding: 'utf8', maxBuffer: 1 << 28 }).stdout ?? '';
const now = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
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
  const manifests = JSON.parse(now('plugin/.claude-plugin/plugin.json')).version === V
    && JSON.parse(now('.claude-plugin/marketplace.json')).plugins?.find((p) => p.source === './plugin')?.version === V;
  // the paragraph that starts with **Status:**, up to a blank line or a list
  const statusOf = (text) => { const ls = text.split(/\r?\n/); const i = ls.findIndex((l) => /^\*\*Status:\*\*/.test(l)); if (i < 0) return null; let j = i + 1; while (j < ls.length && ls[j].trim() && !/^\s*- /.test(ls[j])) j++; return ls.slice(i, j).join(' '); };
  const readme = now('README.md');
  const status = statusOf(readme);
  const inProgress = new RegExp(`${esc(V)}\`?,?\\s+(is\\s+)?(still\\s+)?in progress`, 'i');
  const released = status !== null && status.includes(V) && !inProgress.test(status)
    && readme.split(/\r?\n/).filter((l) => /last release is/i.test(l)).every((l) => l.includes(V))
    && ['docs/v2/00-charter.md', 'docs/v2/04-architecture.md'].every((f) => { const s = statusOf(now(f)); return s === null || s.includes(V); });
  const pin = now('plugin/test/selftest.mjs').match(/product\.digest\('hex'\)\.slice\(0, 12\), '([0-9a-f]{12})'/)?.[1];
  ok = Boolean(V) && manifests && released && pin === product();
} catch {}
process.exitCode = ok ? 0 : 1;
