// 06, section 4, 4a: the hang's watcher (macOS). Every second it lists the processes. A hook or probe reader alive
// for 5 seconds gets, once: ps (state, wait channel) of it, its parent and its children; lsof of it and its parent;
// sample of both. It runs until it is killed.   node watch.mjs <out dir>
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const out = process.argv[2];
fs.mkdirSync(out, { recursive: true });
const seen = new Map();
const done = new Set();
const sh = (cmd, args) => {
  const r = spawnSync(cmd, args, { encoding: 'utf8', timeout: 20_000 });
  return `$ ${cmd} ${args.join(' ')}\n${r.stdout ?? ''}${r.stderr ?? ''}${r.error ? `error: ${r.error.message}\n` : ''}\n`;
};
setInterval(() => {
  const ps = spawnSync('ps', ['-axo', 'pid=,ppid=,command='], { encoding: 'utf8' }).stdout ?? '';
  const now = Date.now();
  const live = new Set();
  for (const row of ps.split('\n')) {
    const m = row.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (!m || !/hook\.mjs|PROBE_READER/.test(m[3])) continue;
    const [, pid, ppid, command] = m;
    live.add(pid);
    if (!seen.has(pid)) seen.set(pid, now);
    if (done.has(pid) || now - seen.get(pid) < 5000) continue;
    done.add(pid);
    const kids = (spawnSync('pgrep', ['-P', pid], { encoding: 'utf8' }).stdout ?? '').trim().split('\n').filter(Boolean);
    let text = `hang seen ${new Date().toISOString()}: pid ${pid}, parent ${ppid}, children ${kids.join(',') || 'none'}\n${command}\n\n`;
    text += sh('ps', ['-o', 'pid,ppid,stat,wchan,etime,command', '-p', [pid, ppid, ...kids].join(',')]);
    for (const p of [pid, ppid]) text += sh('lsof', ['-p', p]);
    fs.writeFileSync(path.join(out, `hang-${pid}.txt`), text);
    for (const [p, who] of [[pid, 'child'], [ppid, 'parent']]) spawnSync('sample', [p, '2', '-mayDie', '-file', path.join(out, `sample-${pid}-${who}.txt`)], { timeout: 20_000 });
  }
  for (const pid of [...seen.keys()]) if (!live.has(pid)) seen.delete(pid);
}, 1000);
