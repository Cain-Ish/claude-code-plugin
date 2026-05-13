import { promises as fs } from 'fs';
import { join } from 'path';
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
  help                                         Show this message

Environment:
  BRAIN_DIR        Override second-brain dir (default: ~/.second-brain)
  KNOWLEDGE_DIR    Override knowledge dir    (default: ~/knowledge)
`;

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
      const firstLine = c.first_lines.split('\n').find((l: string) => /^description:/.test(l))?.replace(/^description:\s*['"]?/, '').replace(/['"]?\s*$/, '') ?? '';
      push(`${score.padStart(3)}%  [[${slug}]]${firstLine ? '  — ' + firstLine : ''}`);
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

  errpush(`unknown command: ${cmd}`);
  errpush('run: sb help');
  return { stdout: '', stderr: err.join('\n'), exitCode: 2 };
}
