import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync, chmodSync } from 'fs';
import { join, delimiter as pathDelimiter } from 'path';
import { tmpdir } from 'os';
import { runSb } from '../src/cli/sb.js';

describe('sb CLI', () => {
  let brainDir: string;
  let knowledgeDir: string;

  beforeEach(() => {
    brainDir = mkdtempSync(join(tmpdir(), 'sb-cli-brain-'));
    knowledgeDir = mkdtempSync(join(tmpdir(), 'sb-cli-know-'));
    mkdirSync(join(knowledgeDir, 'wiki', 'entities'), { recursive: true });
    writeFileSync(join(knowledgeDir, 'wiki', 'entities', 'foo.md'),
      '---\ntitle: "Foo entity"\ntype: entities\ndescription: "About foo widget"\ntags: [foo, widget]\ncreated: 2026-01-01\nupdated: 2026-01-01\n---\n\nFoo is a thing for widget processing.\n',
      'utf-8');
    mkdirSync(join(brainDir, 'projects', 'test-project'), { recursive: true });
    writeFileSync(join(brainDir, 'projects', 'test-project', 'PROJECT.md'),
      '# PROJECT: test-project\n\n## Goal\nA test\n\n## Open blockers\n\n## Recent decisions\n', 'utf-8');
    writeFileSync(join(brainDir, 'projects.jsonl'),
      '{"slug":"test-project","name":"test-project"}\n', 'utf-8');
  });

  afterEach(() => {
    rmSync(brainDir, { recursive: true, force: true });
    rmSync(knowledgeDir, { recursive: true, force: true });
  });

  it('shows help with no args', async () => {
    const r = await runSb([], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('Usage:');
    expect(r.stdout).toContain('query');
    expect(r.stdout).toContain('recall');
    expect(r.stdout).toContain('pin');
    expect(r.stdout).toContain('status');
  });

  it('shows help on `help` subcommand', async () => {
    const r = await runSb(['help'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('Usage:');
  });

  it('query returns wiki results', async () => {
    const r = await runSb(['query', 'foo widget'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toMatch(/foo/);
  });

  it('query surfaces the frontmatter description in output', async () => {
    // The fixture page has description: "About foo widget" — assert that exact
    // curated description appears (not just a token that also happens to be in
    // the slug or body). This would fail if description rendering were removed.
    const r = await runSb(['query', 'foo widget'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('About foo widget');
  });

  it('query with no text errors', async () => {
    const r = await runSb(['query'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('missing search text');
  });

  it('pin user appends to USER.md', async () => {
    const r = await runSb(['pin', 'user', 'prefer', 'terse', 'responses'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    const userMd = readFileSync(join(brainDir, 'USER.md'), 'utf-8');
    expect(userMd).toContain('prefer terse responses');
    expect(r.stdout).toContain('prefer terse responses');
  });

  it('pin project appends to a section', async () => {
    const r = await runSb(['pin', 'project', 'test-project', 'blockers', 'blocked', 'on', 'X'],
      { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    const pf = readFileSync(join(brainDir, 'projects', 'test-project', 'PROJECT.md'), 'utf-8');
    expect(pf).toContain('blocked on X');
  });

  it('pin project with missing args errors', async () => {
    const r = await runSb(['pin', 'project'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('usage');
  });

  it('pin user with no text errors', async () => {
    const r = await runSb(['pin', 'user'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('missing text');
  });

  it('pin with unknown sub errors', async () => {
    const r = await runSb(['pin', 'whatever'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('unknown subcommand');
  });

  it('status reports project counts and PROJECT.md size', async () => {
    const r = await runSb(['status'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('USER.md');
    expect(r.stdout).toContain('Registered projects: 1');
    expect(r.stdout).toContain('test-project/PROJECT.md');
    expect(r.stdout).toContain('Wiki pages');
    expect(r.stdout).toContain('entities: 1');
  });

  it('unknown command exits non-zero', async () => {
    const r = await runSb(['nonsense'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain('unknown command');
  });

  it('recall returns empty gracefully when no transcripts exist', async () => {
    const r = await runSb(['recall', 'anything'], { brainDir, knowledgeDir });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain('no results');
  });

  describe('auth subcommand', () => {
    const originalKey = process.env.ANTHROPIC_API_KEY;
    const originalPath = process.env.PATH;
    const originalProbeTimeout = process.env.SB_AUTH_PROBE_TIMEOUT_MS;
    let pathDir: string;

    // Write an executable fake `claude` into pathDir whose `auth status`
    // prints `body` and exits with `exitCode`. Real-code testing: runSb
    // actually execs it (no mocks). Uses `printf` (a /bin/sh builtin) so it
    // works even though PATH is the temp dir only — no external `cat`/`echo`
    // binary to resolve. The body is single-quoted in the script, so it must
    // not itself contain a single quote. The exitCode matters: the real
    // `claude auth status` exits 1 when logged out while still printing JSON.
    function fakeClaude(body: string, exitCode = 0): void {
      const script = `#!/bin/sh\nprintf '%s' '${body}'\nexit ${exitCode}\n`;
      writeFileSync(join(pathDir, 'claude'), script);
      chmodSync(join(pathDir, 'claude'), 0o755);
      if (process.platform === 'win32') {
        writeFileSync(join(pathDir, 'claude.cmd'), `@echo off\r\necho ${body}\r\nexit /b ${exitCode}\r\n`);
      }
    }

    beforeEach(() => {
      pathDir = mkdtempSync(join(tmpdir(), 'sb-cli-path-'));
      delete process.env.ANTHROPIC_API_KEY;
      process.env.PATH = pathDir;
    });

    afterEach(() => {
      if (originalKey !== undefined) process.env.ANTHROPIC_API_KEY = originalKey;
      else delete process.env.ANTHROPIC_API_KEY;
      process.env.PATH = originalPath;
      if (originalProbeTimeout !== undefined) process.env.SB_AUTH_PROBE_TIMEOUT_MS = originalProbeTimeout;
      else delete process.env.SB_AUTH_PROBE_TIMEOUT_MS;
      rmSync(pathDir, { recursive: true, force: true });
    });

    it('auth status reports api-key mode when ANTHROPIC_API_KEY is set', async () => {
      process.env.ANTHROPIC_API_KEY = 'sk-ant-test-1234567890abcdef';
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: api-key/);
      expect(r.stdout).toContain('anthropic-api');
      expect(r.stdout).not.toContain('sk-ant-test-1234567890abcdef');
    });

    it('auth status does NOT exec claude when ANTHROPIC_API_KEY is set (env wins, short-circuit)', async () => {
      // A fake claude that would crash if invoked — proves the env-key branch
      // returns before probing `claude auth status`.
      writeFileSync(join(pathDir, 'claude'), '#!/bin/sh\nexit 1\n');
      chmodSync(join(pathDir, 'claude'), 0o755);
      process.env.ANTHROPIC_API_KEY = 'sk-ant-env-key-abcdef';
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: api-key/);
      expect(r.stdout).not.toMatch(/claude auth status/);
    });

    it('auth status reports subscription when claude auth status returns oauth_token', async () => {
      fakeClaude('{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}');
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: subscription/);
      expect(r.stdout).toContain('authMethod=oauth_token');
      expect(r.stdout).toMatch(/recursive-claude|OAuth/);
    });

    it('auth status reports logged-out as none when claude auth status returns loggedIn:false', async () => {
      // The regression the heuristic missed: claude on PATH but NOT logged in.
      fakeClaude('{"loggedIn":false}');
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: none/);
      expect(r.stdout).toMatch(/logged out/i);
      expect(r.stdout).not.toMatch(/mode: subscription/);
    });

    it('auth status reads JSON from a logged-out claude that exits non-zero (the real CLI does)', async () => {
      // Verified against real claude CLI v2.1.158: logged-out exits 1 but still
      // prints {"loggedIn":false,...}. The probe must honour that stdout, not
      // discard it and fall through to "unknown".
      fakeClaude('{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}', 1);
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: none/);
      expect(r.stdout).toMatch(/logged out/i);
      expect(r.stdout).not.toMatch(/mode: unknown/);
    });

    it('auth status reads subscription JSON even if claude exits non-zero', async () => {
      // Defence in depth: whatever exit code the CLI uses, a parseable
      // loggedIn:true body must classify correctly.
      fakeClaude('{"loggedIn":true,"authMethod":"oauth_token"}', 3);
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: subscription/);
      expect(r.stdout).not.toMatch(/mode: unknown/);
    });

    it('auth status reports unknown for malformed JSON (non-boolean loggedIn)', async () => {
      // Load-bearing guard: a spoofed/garbled response must NOT be read as
      // authenticated. `{"loggedIn":"yes"}` is valid JSON but loggedIn isn't a bool.
      fakeClaude('{"loggedIn":"yes"}');
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: unknown/);
      expect(r.stdout).not.toMatch(/mode: subscription/);
      expect(r.stdout).not.toMatch(/logged out/i);
    });

    it('auth status reports unknown for non-object JSON (array / number)', async () => {
      // Arrays pass `typeof === "object"`; numbers don't. Both must be rejected.
      fakeClaude('[1,2,3]');
      const arr = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(arr.stdout).toMatch(/mode: unknown/);
      expect(arr.stdout).not.toMatch(/mode: subscription/);
      fakeClaude('42');
      const num = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(num.stdout).toMatch(/mode: unknown/);
      expect(num.stdout).not.toMatch(/mode: subscription/);
    });

    it('auth status does not fabricate an authMethod value it never received', async () => {
      // loggedIn:true with no authMethod is still subscription, but the output
      // must not claim a concrete "authMethod=oauth_token" under a "verified" label.
      fakeClaude('{"loggedIn":true}');
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: subscription/);
      expect(r.stdout).not.toMatch(/authMethod=oauth_token/);
    });

    it('auth status strips control bytes from an attacker-controlled authMethod', async () => {
      // Supply-chain (P0): a PATH-hijacked claude controls authMethod. The JSON
      // \\u001b decodes to a real ESC byte; it must not reach the terminal raw.
      fakeClaude('{"loggedIn":true,"authMethod":"oauth_token\\u001b[2Jpwned"}');
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).not.toContain(String.fromCharCode(0x1b)); // no raw ESC byte reaches the terminal
    });

    it('auth status reports claude-managed api-key when authMethod is api_key', async () => {
      fakeClaude('{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}');
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: api-key \(claude-managed\)/);
      expect(r.stdout).toContain('authMethod=api_key');
      // It still uses the recursive CLI path, so warn it queues in-session.
      expect(r.stdout).toMatch(/queue/i);
    });

    it('auth status reports unknown when claude is present but status is unparseable', async () => {
      fakeClaude('this is not json');
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: unknown/);
      expect(r.stdout).toMatch(/claude auth status/);
    });

    it.skipIf(process.platform === 'win32')('auth status hard-kills a claude that ignores SIGTERM and does not hang', async () => {
      // A hijacked/hung claude that TRAPS SIGTERM must not block the caller.
      // The probe has to escalate to SIGKILL (untrappable). `sleep` runs as a
      // child of the trapping shell (NOT exec'd) so the trap stays installed.
      writeFileSync(join(pathDir, 'claude'), "#!/bin/sh\ntrap '' TERM\nsleep 3\n");
      chmodSync(join(pathDir, 'claude'), 0o755);
      // Widen PATH so the script can resolve `sleep`, keeping fake claude first.
      process.env.PATH = pathDir + pathDelimiter + (originalPath ?? '');
      process.env.SB_AUTH_PROBE_TIMEOUT_MS = '300';
      const t0 = Date.now();
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      const elapsed = Date.now() - t0;
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: unknown/);
      // >=250ms proves the timeout actually fired (not a spurious fast exit like
      // a missing `sleep`); <2000ms proves it was killed long before the 3s
      // sleep — i.e. SIGTERM-resistance was overcome by SIGKILL.
      expect(elapsed).toBeGreaterThanOrEqual(250);
      expect(elapsed).toBeLessThan(2000);
    });

    it('auth status reports none when neither key nor claude is available', async () => {
      const r = await runSb(['auth', 'status'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: none/);
      // Distinct from the logged-out case — there is no claude at all here.
      expect(r.stdout).not.toMatch(/logged out/i);
    });

    it('auth (no sub) defaults to status', async () => {
      process.env.ANTHROPIC_API_KEY = 'sk-ant-z';
      const r = await runSb(['auth'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/mode: api-key/);
    });

    it('auth doctor shows both setup paths', async () => {
      const r = await runSb(['auth', 'doctor'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(0);
      expect(r.stdout).toMatch(/ANTHROPIC_API_KEY/);
      expect(r.stdout).toMatch(/claude \/login/);
      expect(r.stdout).toMatch(/subscription/);
    });

    it('auth with unknown sub errors out', async () => {
      const r = await runSb(['auth', 'bogus'], { brainDir, knowledgeDir });
      expect(r.exitCode).toBe(2);
      expect(r.stderr).toMatch(/usage|unknown/);
    });

    it('help mentions auth', async () => {
      const r = await runSb(['help'], { brainDir, knowledgeDir });
      expect(r.stdout).toContain('auth');
    });
  });
});
