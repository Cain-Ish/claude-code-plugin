import { promises as fs, constants as fsConstants } from 'fs';
import { join, delimiter as pathDelimiter } from 'path';
import { execFile } from 'child_process';
import { cleanEnvPath } from '../path-guard.js';
import { knowledgeSearch } from '../tools/knowledge-search.js';
import { episodicSearch } from '../tools/episodic-search.js';
import { pinToUser } from '../tools/pin-to-user.js';
import { pinToProject, type PinSection } from '../tools/pin-to-project.js';
import { unprocessedCount } from '../tools/raw-inbox.js';

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
  // On Windows, `claude` ships as claude.exe or claude.cmd; probe all variants.
  const names = process.platform === 'win32'
    ? ['claude', 'claude.exe', 'claude.cmd']
    : ['claude'];
  for (const rawDir of path.split(pathDelimiter)) {
    // cleanEnvPath per-segment: on Windows the LAST entry of a CRLF-tainted PATH carries a
    // trailing \r, so a genuinely-installed `claude` on that final dir is missed and auth
    // status mis-reports "mode: none". Strip CR before the fs.access probe.
    const dir = cleanEnvPath(rawDir);
    if (!dir) continue;
    for (const name of names) {
      try {
        await fs.access(join(dir, name), fsConstants.X_OK);
        return true;
      } catch {
        // try next name / dir
      }
    }
  }
  return false;
}

// The authoritative auth state, as reported by the `claude` CLI itself.
// Mirrors the JSON shape of `claude auth status`.
interface ClaudeAuthStatus {
  loggedIn?: boolean;
  authMethod?: string;   // 'oauth_token' | 'api_key' | ...
  apiProvider?: string;
  apiKeySource?: string;
}

// Ask the `claude` CLI for the authoritative auth state instead of guessing
// from PATH presence. Returns the parsed JSON, or null if claude is
// unavailable / produced no usable output. Robustness details that matter:
//   - `claude auth status` exits NON-ZERO when logged out (verified: exit 1)
//     but still prints the JSON, so we read stdout regardless of exit code.
//   - The probe is bounded by a hard timeout sent as SIGKILL (untrappable), so
//     a hung or hostile `claude` on PATH can never block the caller past the
//     budget — SIGTERM alone can be trapped and ignored.
//   - maxBuffer caps output so a flood cannot exhaust memory.
function claudeAuthStatus(): Promise<ClaudeAuthStatus | null> {
  const timeout = Math.min(Math.max(Number(process.env.SB_AUTH_PROBE_TIMEOUT_MS) || 3000, 100), 30000);
  return new Promise((resolve) => {
    try {
      execFile(
        'claude', ['auth', 'status'],
        { timeout, killSignal: 'SIGKILL', maxBuffer: 256 * 1024, shell: process.platform === 'win32' },
        (_err, stdout) => {
          // stdout is populated even when the child exited non-zero or was killed.
          const text = typeof stdout === 'string' ? stdout.trim() : '';
          if (!text) { resolve(null); return; }
          try {
            const parsed = JSON.parse(text);
            if (parsed && typeof parsed === 'object') { resolve(parsed as ClaudeAuthStatus); return; }
          } catch {
            // not JSON
          }
          resolve(null);
        },
      );
    } catch {
      // execFile can throw synchronously on bad arguments — never let it escape.
      resolve(null);
    }
  });
}

// Strip control / non-printable bytes and cap length before echoing a value
// that originates from the PATH-resolved (possibly hostile) `claude` CLI to the
// terminal — prevents escape-sequence injection via a spoofed JSON field.
function sanitizeField(v: unknown): string {
  // eslint-disable-next-line no-control-regex
  return String(v).replace(/[^\x20-\x7e]/g, '').slice(0, 40);
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

    // P1.1 loop liveness (docs/plans/2026-07-13-p1-observability.md Task 1): the
    // autonomous loops fail SILENTLY — a drainer dead on this OS produces no errors.
    // Every value below reads an EXISTING state file the loops already stamp; a
    // missing file renders "never" — loud, not blank. Observation only (P1 firewall).
    push('Loop liveness:');
    const age = (ms: number): string => {
      const h = (Date.now() - ms) / 3600000;
      if (h < 1) return `${Math.max(1, Math.round(h * 60))}m ago`;
      if (h < 48) return `${Math.round(h)}h ago`;
      return `${Math.round(h / 24)}d ago`;
    };
    // Drainer: .extractor-health.json is rewritten at the end of EVERY run — its
    // mtime IS the last tick; status/reason describe how that run went.
    try {
      const hf = join(deps.brainDir, '.extractor-health.json');
      const st = await fs.stat(hf);
      const h = JSON.parse(await fs.readFile(hf, 'utf-8')) as { status?: string; reason?: string };
      push(`  drainer last ran:    ${age(st.mtimeMs)} (${sanitizeField(h.status ?? '?')}: ${sanitizeField(h.reason ?? '?')})`);
    } catch { push('  drainer last ran:    never (no .extractor-health.json)'); }
    // Extraction done-set recency + transcript backlog (archived but not terminal).
    // The backlog row must render even when the done-set file is ABSENT — that is
    // the archived-but-never-drained state (a dead drainer), the exact case this
    // section exists to expose; an absent done-set just means an empty done set.
    const done = new Set<string>();
    try {
      const stateRaw = await fs.readFile(join(deps.brainDir, '.extraction-state.jsonl'), 'utf-8');
      let newestTs = '';
      for (const l of stateRaw.split('\n').filter(Boolean)) {
        try {
          const r = JSON.parse(l) as { basename?: string; ts?: string; outcome?: string };
          if (r.ts && r.ts > newestTs) newestTs = r.ts;
          if (r.basename && (r.outcome === 'ok' || r.outcome === 'error')) done.add(r.basename);
        } catch { /* one corrupt line must not blind the whole read */ }
      }
      push(`  last extraction:     ${newestTs ? sanitizeField(newestTs) : 'never'}`);
    } catch { push('  last extraction:     never (no .extraction-state.jsonl)'); }
    try {
      const archived = (await fs.readdir(join(deps.brainDir, 'transcripts'))).filter(f => f.endsWith('.txt'));
      const backlog = archived.filter(f => !done.has(f)).length;
      push(`  transcript backlog:  ${backlog} of ${archived.length} archived`);
    } catch { push('  transcript backlog:  no transcripts dir'); }
    // Scheduler shim — the universal registration signal (the per-OS timer check
    // lives in bash lib.sh; a missing shim means every fire fails silently).
    try {
      await fs.access(join(deps.brainDir, 'bin', 'sb-extract-drain.sh'));
      push('  scheduler shim:      present');
    } catch { push('  scheduler shim:      ABSENT (out-of-band drain cannot run)'); }
    // Newest dream: status + heartbeat age (status.json mtime is re-stamped
    // between phases; stale pending/running = a wedged run).
    try {
      const dreamsDir = join(deps.brainDir, 'dreams');
      const ids = (await fs.readdir(dreamsDir)).filter(d => d.startsWith('drm_')).sort();
      if (ids.length === 0) { push('  newest dream:        none'); }
      else {
        const id = ids[ids.length - 1];
        const sf = join(dreamsDir, id, 'status.json');
        const st = await fs.stat(sf);
        const s = JSON.parse(await fs.readFile(sf, 'utf-8')) as { status?: string };
        push(`  newest dream:        ${sanitizeField(id)} ${sanitizeField(s.status ?? '?')} (heartbeat ${age(st.mtimeMs)})`);
      }
    } catch { push('  newest dream:        none'); }
    // Raw-inbox depth across all registered projects (malformed counts as unprocessed).
    try {
      const projectDirs = await fs.readdir(join(deps.brainDir, 'projects'), { withFileTypes: true });
      let raw = 0;
      for (const d of projectDirs) {
        if (!d.isDirectory()) continue;
        try { raw += await unprocessedCount(deps.brainDir, d.name); } catch { /* non-slug dir */ }
      }
      push(`  raw-inbox depth:     ${raw} unprocessed`);
    } catch { push('  raw-inbox depth:     0 unprocessed (no projects dir)'); }

    // P1.3 utilization + dormant-capability report (observation-only — the P1
    // firewall forbids any ranking use). Counts come from stop-extract's per-session
    // fold of Skill/Task tool_use into utilization-counts.json. Dormant = THIS
    // plugin's own installed skills/agents never seen in the counts — the direct
    // answer to "which of the capabilities we ship are actually used?".
    push('Utilization:');
    let util: Record<string, { count?: number; last_used?: string }> = {};
    try {
      util = JSON.parse(await fs.readFile(join(deps.brainDir, 'utilization-counts.json'), 'utf-8'));
      if (util === null || typeof util !== 'object' || Array.isArray(util)) util = {};
    } catch { /* absent or corrupt → render as empty, dormant report still runs */ }
    const entries = Object.entries(util).filter(([, v]) => v && typeof v.count === 'number');
    if (entries.length === 0) push('  (no invocations recorded yet)');
    else {
      entries.sort((a, b) => (b[1].count ?? 0) - (a[1].count ?? 0));
      for (const [name, v] of entries.slice(0, 5)) {
        push(`  ${sanitizeField(name)}: ${v.count} (last ${sanitizeField(v.last_used ?? '?')})`);
      }
    }
    try {
      // 3 levels up = plugin root from BOTH mcp/src/cli (dev) and mcp/dist/cli (bundle).
      const pluginRoot = new URL('../../../', import.meta.url);
      const { fileURLToPath } = await import('url');
      const root = fileURLToPath(pluginRoot);
      const skills = (await fs.readdir(join(root, 'skills'), { withFileTypes: true }))
        .filter(d => d.isDirectory()).map(d => `skill!${d.name}`);
      const agents = (await fs.readdir(join(root, 'agents')))
        .filter(f => f.endsWith('.md')).map(f => `agent!${f.replace(/\.md$/, '')}`);
      const used = new Set(Object.keys(util));
      const isUsed = (kind: string, name: string): boolean => {
        for (const k of used) {
          if (!k.startsWith(kind + ':')) continue;
          if (k === `${kind}:${name}` || k.endsWith(`:${name}`)) return true;
        }
        return false;
      };
      const dormant = [...skills, ...agents]
        .map(t => t.split('!') as [string, string])
        .filter(([kind, name]) => !isUsed(kind, name))
        .map(([kind, name]) => `${kind}:${name}`);
      const total = skills.length + agents.length;
      if (dormant.length === 0) push(`  dormant: none of ${total} shipped capabilities`);
      else push(`  dormant: ${dormant.length} of ${total} shipped capabilities (${dormant.slice(0, 6).map(sanitizeField).join(', ')}${dormant.length > 6 ? ', …' : ''})`);
    } catch { /* not running from a plugin checkout — skip the dormant report */ }
    return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
  }

  if (cmd === 'auth') {
    const sub = args[1] ?? 'status';
    if (sub === 'status') {
      // 1. An explicit ANTHROPIC_API_KEY short-circuits everything: it IS the
      //    extractor's backend (direct curl) AND it overrides claude's stored
      //    credentials at call time, so it's authoritative without a probe.
      const key = process.env.ANTHROPIC_API_KEY;
      if (key && key.length > 0) {
        push('mode: api-key');
        push(`key:  ${key.slice(0, 10)}… (len=${key.length})`);
        push('backend: anthropic-api (direct curl)');
        push('note: works in all contexts (Stop hooks, cron, CI)');
        return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
      }
      // 2. No env key. Don't guess from PATH presence — ask the `claude` CLI
      //    for the authoritative auth state.
      if (!(await hasClaudeOnPath())) {
        push('mode: none');
        push('backend: none — neither ANTHROPIC_API_KEY nor `claude` CLI is available');
        push('run: sb auth doctor');
        return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
      }
      const st = await claudeAuthStatus();
      if (!st || typeof st.loggedIn !== 'boolean') {
        // claude is present but couldn't be confirmed — be honest, don't guess.
        push('mode: unknown');
        push('backend: claude CLI present, but `claude auth status` did not return parseable JSON (timeout or old CLI)');
        push('run: claude auth status   # inspect the raw auth state yourself');
        return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
      }
      if (!st.loggedIn) {
        push('mode: none (logged out)');
        push('backend: none — `claude auth status` reports loggedIn=false');
        push('fix: run `claude /login` (OAuth) or `export ANTHROPIC_API_KEY=sk-ant-...`');
        return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
      }
      if (st.authMethod === 'api_key') {
        // Logged in via claude's own key (apiKeyHelper / setup-token), NOT a
        // shell ANTHROPIC_API_KEY. Extraction still shells out to `claude`, so
        // the recursive-claude lock still applies in-session.
        push('mode: api-key (claude-managed)');
        push('backend: claude CLI (api_key via apiKeyHelper / setup-token)');
        push('auth: verified via `claude auth status` (authMethod=api_key)');
        push('note: extraction still uses the recursive `claude` CLI path, so in-session Stop/PreCompact');
        push('      extraction queues (recursive-claude lock). Set ANTHROPIC_API_KEY for the direct-curl backend.');
        return { stdout: out.join('\n'), stderr: err.join('\n'), exitCode: 0 };
      }
      // loggedIn === true, OAuth subscription (authMethod oauth_token or similar).
      push('mode: subscription');
      push('backend: claude CLI (OAuth via `claude /login`)');
      // Report the real authMethod (sanitized) — never fabricate one under a
      // "verified" label when the CLI didn't return it.
      if (typeof st.authMethod === 'string' && st.authMethod.length > 0) {
        push(`auth: verified via \`claude auth status\` (authMethod=${sanitizeField(st.authMethod)})`);
      } else {
        push('auth: verified via `claude auth status` (loggedIn=true, authMethod unspecified)');
      }
      push('note: real-time extraction inside a Claude Code session is NOT possible in this mode');
      push('      due to the recursive-claude OAuth lock. Set ANTHROPIC_API_KEY for in-session extraction,');
      push('      or rely on out-of-band extraction (see `sb auth doctor`).');
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
