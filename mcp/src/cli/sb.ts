import { promises as fs, constants as fsConstants } from 'fs';
import { join, delimiter as pathDelimiter } from 'path';
import { knowledgeSearch } from '../tools/knowledge-search.js';
import { episodicSearch } from '../tools/episodic-search.js';
import { pinToUser } from '../tools/pin-to-user.js';
import { pinToProject, type PinSection } from '../tools/pin-to-project.js';

export interface SbDeps {
  brainDir: string;
  knowledgeDir: string;
}

export interface SbResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

const HELP = `Usage: sb <command> [args]

Commands:
  query <text>                                 Search the wiki (BM25 + vector hybrid)
  recall <text>                                Search past conversation transcripts
  pin user <text>                              Append a preference line to USER.md
  pin project <slug> <blockers|decisions> <text>
                                               Append an entry to a project's PROJECT.md
  status                                       Show hot-tier and wiki sizes
  auth [status|doctor]                         Show or fix the extractor auth mode
  help                                         Show this message

Environment:
  BRAIN_DIR        Override second-brain dir (default: ~/.second-brain)
  KNOWLEDGE_DIR    Override knowledge dir    (default: ~/knowledge)
`;

// Probe whether `claude` is reachable on the current PATH without spawning
// a child process — checks each PATH entry for an executable file.
async function hasClaudeOnPath(): Promise<boolean> {
  const path = process.env.PATH ?? '';
  for (const dir of path.split(pathDelimiter)) {
    if (!dir) continue;
    try {
      await fs.access(join(dir, 'claude'), fsConstants.X_OK);
      return true;
    } catch {
      // try next dir
    }
  }
  return false;
}

export async function runSb(args: string[], deps: SbDeps): Promise<SbResult> {
  const out: string[] = [];
  const err: string[] = [];
  const push = (s: string) => out.push(s);
  const errpush = (s: string) => err.push(s);

  if (args.length === 0 || args[0] === 'help' || args[0] === '--help' || args[0] === '-h') {
    push(HELP);
    return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
  }

  const cmd = args[0];

  if (cmd === 'query') {
    const q = args.slice(1).join(' ').trim();
    if (!q) { errpush('query: missing search text'); return { stdout: '', stderr: err.join('\n'), exitCode: 2 }; }
    const r = await knowledgeSearch({ query: q, knowledgeDir: deps.knowledgeDir });
    if (r.candidates.length === 0) { push('(no results)'); }
    for (const c of r.candidates.slice(0, 5)) {
      const slug = c.path.replace(/.*[\\/]/, '').replace(/\.md$/, '');
      const score = (c.score * 100).toFixed(0);
      push(`${score.padStart(3)}%  [[${slug}]]${c.description ? '  — ' + c.description : ''}`);
      push(`       ${c.path}`);
    }
    return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
  }

  if (cmd === 'recall') {
    const q = args.slice(1).join(' ').trim();
    if (!q) { errpush('recall: missing search text'); return { stdout: '', stderr: err.join('\n'), exitCode: 2 }; }
    const r = await episodicSearch({ query: q, limit: 5 }, deps.brainDir);
    if (r.results.length === 0) { push('(no results — only sessions with substantive tool use are archived)'); }
    for (const x of r.results) {
      const sim = Math.round(x.similarity * 100);
      push(`${String(sim).padStart(3)}%  [${x.date} ${x.project}]  ${x.userSnippet.slice(0, 100)}`);
      push(`       ${x.archivePath}:${x.lineStart}-${x.lineEnd}`);
    }
    return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
  }

  if (cmd === 'pin') {
    const sub = args[1];
    if (sub === 'user') {
      const text = args.slice(2).join(' ').trim();
      if (!text) { errpush('pin user: missing text'); return { stdout: '', stderr: err.join('\n'), exitCode: 2 }; }
      const r = await pinToUser({ text, brainDir: deps.brainDir });
      if (!r.ok) { errpush(`pin user: ${r.reason ?? 'failed'}`); return { stdout: '', stderr: err.join('\n'), exitCode: 1 }; }
      push(`+ ${r.line_added}${r.reason ? '  (' + r.reason + ')' : ''}`);
      return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
    }
    if (sub === 'project') {
      const slug = args[2];
      const section = args[3] as PinSection;
      const text = args.slice(4).join(' ').trim();
      if (!slug || !section || !text) { errpush('pin project: usage: sb pin project <slug> <blockers|decisions> <text>'); return { stdout: '', stderr: err.join('\n'), exitCode: 2 }; }
      const r = await pinToProject({ text, slug, section, brainDir: deps.brainDir });
      if (!r.ok) { errpush(`pin project: ${r.reason ?? 'failed'}`); return { stdout: '', stderr: err.join('\n'), exitCode: 1 }; }
      push(`+ ${r.line_added}  (${slug}/${section})${r.reason ? '  ' + r.reason : ''}`);
      return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
    }
    errpush(`pin: unknown subcommand '${sub ?? ''}'`);
    return { stdout: '', stderr: err.join('\n'), exitCode: 2 };
  }

  if (cmd === 'status') {
    const userFile = join(deps.brainDir, 'USER.md');
    const projectsFile = join(deps.brainDir, 'projects.jsonl');
    let userBytes = 0, projectsCount = 0;
    try { userBytes = (await fs.stat(userFile)).size; } catch {}
    try {
      const txt = await fs.readFile(projectsFile, 'utf-8');
      projectsCount = txt.split('\n').filter(l => l.includes('"slug"')).length;
    } catch {}
    push(`USER.md:             ${userBytes} bytes`);
    push(`Registered projects: ${projectsCount}`);
    try {
      const projectDirs = await fs.readdir(join(deps.brainDir, 'projects'), { withFileTypes: true });
      for (const d of projectDirs) {
        if (!d.isDirectory()) continue;
        const pf = join(deps.brainDir, 'projects', d.name, 'PROJECT.md');
        try {
          const size = (await fs.stat(pf)).size;
          push(`  ${d.name}/PROJECT.md: ${size} bytes`);
        } catch {}
      }
    } catch {}
    try {
      const wikiDirs = await fs.readdir(join(deps.knowledgeDir, 'wiki'), { withFileTypes: true });
      push('Wiki pages:');
      for (const d of wikiDirs) {
        if (!d.isDirectory()) continue;
        const files = await fs.readdir(join(deps.knowledgeDir, 'wiki', d.name));
        const count = files.filter(f => f.endsWith('.md') && f !== 'index.md').length;
        push(`  ${d.name}: ${count}`);
      }
    } catch {}
    return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
  }

  if (cmd === 'auth') {
    const sub = args[1] ?? 'status';
    if (sub === 'status') {
      const key = process.env.ANTHROPIC_API_KEY;
      if (key && key.length > 0) {
        push('mode: api-key');
        push(`key:  ${key.slice(0, 10)}… (len=${key.length})`);
        push('backend: anthropic-api (direct curl)');
        push('note: works in all contexts (Stop hooks, cron, CI)');
        return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
      }
      if (await hasClaudeOnPath()) {
        push('mode: subscription');
        push('backend: claude CLI (OAuth via `claude /login`)');
        push('note: real-time extraction inside a Claude Code session is NOT possible in this mode');
        push('      due to the recursive-claude OAuth lock. Set ANTHROPIC_API_KEY for in-session extraction,');
        push('      or rely on out-of-band extraction (see `sb auth doctor`).');
        return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
      }
      push('mode: none');
      push('backend: none — neither ANTHROPIC_API_KEY nor `claude` CLI is available');
      push('run: sb auth doctor');
      return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
    }
    if (sub === 'doctor') {
      push('Auth doctor — two supported modes:');
      push('');
      push('1. Anthropic API key (token plan)');
      push('   export ANTHROPIC_API_KEY=sk-ant-...');
      push('   Works in all contexts (Stop hooks, cron, CI).');
      push('   Recommended for in-session extraction.');
      push('');
      push('2. Claude subscription (OAuth)');
      push('   claude /login   # interactive browser flow');
      push('   Works outside Claude Code (cron, CI). Inside a Claude Code session,');
      push('   Stop/PreCompact extractors will queue (recursive-claude OAuth lock).');
      push('');
      push('After either, verify with: sb auth status');
      return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
    }
    errpush(`auth: unknown subcommand '${sub}'  — usage: sb auth {status|doctor}`);
    return { stdout: '', stderr: err.join('\n'), exitCode: 2 };
  }

  errpush(`unknown command: ${cmd}`);
  errpush('run: sb help');
  return { stdout: '', stderr: err.join('\n'), exitCode: 2 };
}
