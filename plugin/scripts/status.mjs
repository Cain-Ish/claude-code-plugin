// 06, section 3, S8: the report /second-brain:status shows. No model and no network; spawns only git; changes no
// file. Run as a command by the skill, never by a hook:   node status.mjs <the plugin's data folder>
// The stale conditions are the read hook's (labels() in map.mjs), in its words, applied to every entry; plus a source
// committed after the entry's verified date.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { MAP, entries, foundIn, sourcePath, under, stateDir, loadState, knownDirs, dreamDue, waiting, localDate, toplevel } from './map.mjs';

const git = (root, ...a) => spawnSync('git', a, { cwd: root, encoding: 'utf8', maxBuffer: 64 << 20 });
const count = (s) => (s ?? '').split('\n').filter(Boolean).length;
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

export function status(root, data) {
  if (!fs.existsSync(path.join(root, MAP))) return `This repo has no team memory (${MAP}/). Run /second-brain:setup to create it.`;
  const today = localDate();
  const files = under(root, MAP).filter((p) => p.endsWith('.md') && !p.startsWith(`${MAP}/.dream-run/`));
  const all = files.map((f) => { try { return { f, es: entries(fs.readFileSync(path.join(root, f), 'utf8')) }; } catch { return { f, es: [] }; } });
  const ids = new Set(all.flatMap(({ es }) => es.flatMap((b) => [...b.matchAll(/^- id:[ \t]*(\S+)[ \t]*$/gm)].map((m) => m[1]))));
  const docs = new Map();
  const doc = (p) => { if (!docs.has(p)) docs.set(p, fs.readFileSync(path.join(root, p), 'utf8').toLowerCase()); return docs.get(p); };
  const commits = new Map();
  const lastCommit = (p) => { if (!commits.has(p)) commits.set(p, git(root, 'log', '-1', '--format=%cs', '--', p).stdout?.trim() ?? ''); return commits.get(p); };
  const stale = [];
  let total = 0, retired = 0, proposed = 0, current = 0;
  for (const { f, es } of all) {
    es.forEach((b, i) => {
      total++;
      const why = [];
      const st = /^- status:[ \t]*(\S.*)$/m.exec(b)?.[1].trim();
      if (st) {
        // a retired entry is history; it is listed only when the id that replaced it is not in the map
        const by = /^\S+[ \t]+\d{4}-\d{2}-\d{2}[ \t]+by[ \t]+((?=[\w.-]*[\d-])[A-Za-z0-9][\w.-]*)[ \t]*(?::|$)/.exec(st)?.[1];
        if (by && ids.size && !ids.has(by)) why.push(`replaced by ${by}, which the map does not hold`);
      } else {
        const review = /^- review:[ \t]*(\d{4}-\d{2}-\d{2})[ \t]*$/m.exec(b)?.[1];
        if (review && review < today) why.push(`review due since ${review}`);
        const at = sourcePath(/^- source:(.*)$/m.exec(b)?.[1] ?? '');
        if (at) {
          const quote = b.split('\n').filter((l) => l.startsWith('>')).map((l) => l.replace(/^> ?/, '')).join('\n');
          let found;
          try { found = Boolean(fs.statSync(path.join(root, at), { throwIfNoEntry: false })?.isFile() && foundIn(quote, doc(at))); } catch { found = null; }
          if (found === null) why.push(`cannot read ${at}`);
          else if (!found) why.push(`not found word for word in ${at}`);
          else {
            const verified = /^- verified:[ \t]*(\d{4}-\d{2}-\d{2})/m.exec(b)?.[1];
            const changed = verified && lastCommit(at);
            if (changed && changed > verified) why.push(`its source ${at} changed on ${changed}, after it was verified on ${verified}`);
          }
        }
      }
      if (why.length) stale.push(`  - ${f}, entry ${i + 1} "${b.split('\n')[0].slice(4)}": ${why.join('; ')}`);
      else if (st) retired++;
      else if (/^- proposed:[ \t]*dream/m.test(b)) proposed++;
      else current++;
    });
  }
  // the sessions since the last dream, counted as session start's nudge counts them
  const dir = stateDir(root, data);
  const state = loadState(dir);
  let since = 0;
  for (const d of knownDirs(dir)) { let names = []; try { names = fs.readdirSync(d); } catch {} since += names.filter((n) => n.endsWith('.jsonl') && !Object.hasOwn(state.seen, n)).length; }
  const due = dreamDue(root, data, null).replace(/^second-brain: a dream/, 'A dream');
  const wait = waiting(root).replace(/^second-brain: waiting/, 'Waiting');
  const last = git(root, 'log', '-1', '--format=%cs', '--', MAP).stdout?.trim();
  const dirty = count(git(root, 'status', '--porcelain', '--', MAP).stdout);
  const agents = count(git(root, 'status', '--porcelain', '--untracked-files=all', '--', '.claude/agent-memory').stdout);
  return [
    `second-brain status, ${today}:`,
    `- Team memory: ${plural(total, 'entry', 'entries')} in ${plural(files.length, 'file', 'files')} under ${MAP}/; last committed ${last || 'never'}${dirty ? `; ${plural(dirty, 'uncommitted change', 'uncommitted changes')}` : ''}.`,
    `- Dreams: ${state.lastDream ? `the last on ${state.lastDream.slice(0, 10)}` : 'none yet'}; ${plural(since, 'session', 'sessions')} since${due ? '' : '; no dream is due'}.`,
    due ? `- ${due}` : '',
    `- ${wait || 'Nothing waits for review.'}`,
    agents ? `- Agent memory: ${plural(agents, 'uncommitted change', 'uncommitted changes')} under .claude/agent-memory/; review them as you review the map.` : '',
    stale.length ? `- Stale: ${plural(stale.length, 'entry', 'entries')} to verify, update or retire with /map-review:\n${stale.join('\n')}` : '- Stale: none.',
    `- Retired (with a status line): ${retired}. Proposed by a dream: ${proposed}. Current: ${current}.`,
  ].filter(Boolean).join('\n');
}

// the command: the repo is the git top level of where Claude Code runs it
if (path.basename(process.argv[1] ?? '') === 'status.mjs') {
  const data = process.argv[2];
  const root = toplevel(process.env.CLAUDE_PROJECT_DIR ?? process.cwd());
  if (!data) { console.log('usage: node status.mjs <the plugin data folder>; run it as /second-brain:status'); process.exitCode = 1; }
  else { try { console.log(status(root, data)); } catch (e) { console.log(`The status report stopped: ${e.message}`); process.exitCode = 1; } }
}
