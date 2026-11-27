// 06, section 3, S8: the report /second-brain:status shows. No model and no network; spawns only git; changes no
// file. Run as a command by the skill, never by a hook:   node status.mjs <the plugin's data folder>
// The stale conditions are the read hook's (labels() in map.mjs, through the same helpers), in its words, applied to
// every entry but one a status line ended (N8); plus a source committed after the entry's verified date, and a repo
// path the entry names that is gone (N12).
import fs from 'node:fs';
import path from 'node:path';
import { MAP, entries, sourcePath, stateDir, loadState, knownDirs, dreamDue, waiting, localDate, toplevel, dreamDate, git, quoteOf, proposedOn, reviewOn, statusOf, replacedBy, refinder, unseenIn, mapMd, mapIdsOf, readMapFile, decode, gitWhy, ended as isEnded } from './map.mjs';
import { FILES, sum } from './setup.mjs';

const count = (s) => (s ?? '').split('\n').filter(Boolean).length;
// N12 (the field report of 2026-11-23): the repo paths an entry names, each once: a slash in them and a file extension
// or a slash at the end. A URL, a glob or the folder before it, a package name, a version (release/2.3.0), "and/or" or
// a path out through .. is not one. shortcut: ASCII names only, and a path in markdown italics (_a/b.md_) is missed
const pathsIn = (b) => [...new Set([...b.matchAll(/(?<![\w.:/@-])(?:\.\/)?\.?[\w-]+(?:\/[\w.-]+)+\/?(?![\w.*{/-])/g)]
  .map((m) => m[0].replace(/^\.\/|\.+$/g, '')))].filter((p) => /\/$|\.[a-z]\w*$/i.test(p) && !p.split('/').includes('..'));
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

export function status(root, data) {
  if (!fs.existsSync(path.join(root, MAP))) return `This repo has no team memory (${MAP}/). Run /second-brain:setup to create it.`;
  // Q-11 (06, 8k): the state is kept per git repository, so with no .git there is nothing to report, said plainly
  if (!fs.existsSync(path.join(root, '.git'))) return `This folder is not in a git repository, and the team memory (${MAP}/) is kept per repository. Run /second-brain:status inside one.`;
  // AU-12 (06, 9): git that cannot run here is named, as session start names it, never read as "never committed"
  const probe = git(root, 'rev-parse', '--git-dir');
  if (probe.status !== 0) return `The team memory needs git, and ${gitWhy(probe)}, so there is nothing to report here.`;
  const today = localDate();
  const files = mapMd(root);
  // 06, 8k: map files are read as the hooks read them (readMapFile), and one that cannot be read is named
  const unread = [];
  const all = files.map((f) => { let b = null; try { b = readMapFile(root, f); } catch {} if (!b) unread.push(f); return { f, es: b ? entries(decode(b)) : [] }; });
  const ids = mapIdsOf(root);
  const refind = refinder(root);
  const commits = new Map();
  const lastCommit = (p) => { if (!commits.has(p)) commits.set(p, git(root, 'log', '-1', '--format=%cs', '--', p).stdout?.trim() ?? ''); return commits.get(p); };
  const stale = [];
  let total = 0, retired = 0, proposed = 0, current = 0;
  for (const { f, es } of all) {
    es.forEach((b, i) => {
      total++;
      const why = [];
      // every check, as the read hook gives every entry its labels: a narrowed entry still binds in part (the
      // devils-advocate review). An entry any status line ended no longer binds, so its review date and source are not
      // checked, and it cannot stay stale after its source moves on (N8, 06 section 4, 4h); a dream's status line ends
      // nothing until review accepts it (D28, D30; the decision-checker's 4h review)
      const st = statusOf(b);
      const ended = isEnded(b);
      const by = replacedBy(st);
      if (by && ids?.size && !ids.has(by)) why.push(`replaced by ${by}, which the map does not hold`);
      const review = !ended && reviewOn(b);
      if (review && review < today) why.push(`review due since ${review}`);
      const at = !ended && sourcePath(/^- source:(.*)$/m.exec(b)?.[1] ?? '');
      if (at) {
        const found = refind(at, quoteOf(b));
        if (found === null) why.push(`cannot read ${at}`);
        else if (!found) why.push(`not found word for word in ${at}`);
        else {
          const verified = /^- verified:[ \t]*(\d{4}-\d{2}-\d{2})/m.exec(b)?.[1];
          const changed = verified && lastCommit(at);
          if (changed && changed > verified) why.push(`its source ${at} changed on ${changed}, after it was verified on ${verified}`);
        }
      }
      // shortcut: a path counts as the repo's only when its first folder exists, so build output (dist/) is not flagged
      // and a removed top folder is missed, and an entry that records a removal stays flagged until it is reworded;
      // check git's tree if that misses real drift
      const gone = !ended && pathsIn(b).filter((p) => p !== at && fs.existsSync(path.join(root, p.split('/')[0])) && !fs.existsSync(path.join(root, p)));
      if (gone.length) why.push(`names ${gone.join(', ')}, which ${gone.length === 1 ? 'does' : 'do'} not exist`);
      if (why.length) stale.push(`  - ${f}, entry ${i + 1} "${b.split('\n')[0].slice(4)}": ${why.join('; ')}`);
      else if (proposedOn(b)) proposed++; // a dream's status line ends nothing until review (D28, D30)
      else if (st) retired++;
      else current++;
    });
  }
  // the sessions since the last dream, counted as session start's nudge counts them
  const dir = stateDir(root, data);
  const state = loadState(dir);
  const since = unseenIn(knownDirs(dir), state.seen).length;
  const due = dreamDue(root, data, null).replace(/^second-brain: a dream/, 'A dream');
  const wait = waiting(root).replace(/^second-brain: waiting/, 'Waiting');
  const last = lastCommit(MAP);
  // --no-optional-locks: a status refresh would rewrite .git/index, and the report changes no file
  const dirty = count(git(root, '--no-optional-locks', 'status', '--porcelain', '--', MAP).stdout);
  const agents = count(git(root, '--no-optional-locks', 'status', '--porcelain', '--untracked-files=all', '--', '.claude/agent-memory').stdout);
  // L-11 (06, 8k): a kept file whose text is an earlier release's template, by setup's own list, waits for setup
  const old = FILES.filter(([, to, earlier = []]) => { try { const b = readMapFile(root, to); return Boolean(b) && earlier.includes(sum(b.toString('utf8'))); } catch { return false; } }).map(([, to]) => to);
  return [
    `second-brain status, ${today}:`,
    `- Team memory: ${plural(total, 'entry', 'entries')} in ${plural(files.length, 'file', 'files')} under ${MAP}/; last committed ${last || 'never'}${dirty ? `; ${plural(dirty, 'uncommitted change', 'uncommitted changes')}` : ''}.`,
    unread.length ? `- Cannot read ${unread.join(', ')} (not a regular file under 4 MB inside the repo, or not readable), so ${unread.length === 1 ? 'its' : 'their'} entries are not counted.` : '',
    old.length ? `- Out of date: ${old.join(', ')}, each an earlier release's template, unchanged. Run /second-brain:setup to update ${old.length === 1 ? 'it' : 'them'}.` : '',
    `- Dreams: ${state.lastDream ? `the last on ${dreamDate(state)}` : 'none yet'}; ${plural(since, 'session', 'sessions')} since${due ? '' : '; no dream is due'}.`,
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
  // a failure exits 0, as dream prepare's refusal does: a failed ! line can abort the skill (N6; the audit, 4k)
  else { try { console.log(status(root, data)); } catch (e) { console.log(`The status report stopped: ${e.message}`); } }
}
