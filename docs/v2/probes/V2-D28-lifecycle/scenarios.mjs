// 06, 2s: scenarios S1 (a decision replaced, D28's I), S2 (the date last, B2) and S3 (naming across turns, D23's d),
// each run on a fresh copy of A1's fixture with a committed map, a candidate and a control plugin interleaved per run.
//   D17_CLAUDE=<pinned CLI> node scenarios.mjs <scratch> <candidate plugin> <control plugin> <runs> [S1,S2,S3]
// Writes results/<scenario>.json beside this file: counts per arm and run, no transcript text.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(HERE, '..', 'V2-D17-eval', 'fixture');
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const MODEL = 'claude-opus-5-5';
const [scratch, candidate, control, runsArg = '5', which = 'S1,S2,S3'] = process.argv.slice(2);
const ARMS = { candidate: path.resolve(candidate), control: path.resolve(control) };

const ENTRY = (area, quote, src, when) => `### ${area}\n> ${quote}\n\n- source: ${src}\n- when: ${JSON.stringify(when)}\n`;
const MAP = [
  ENTRY('components', 'Each component keeps all its files in its own folder.', 'the lead developer, 2026-10-20', ['creating or moving a component']),
  ENTRY('avatars', 'Avatars always load locally, never from the CDN, even when a CDN address exists.', 'the PM, 2026-10-24', ['showing an avatar or profile image']),
  ENTRY('release notes', 'Release notes are written in the past tense.', 'the lead developer, 2026-10-22', ['writing release notes']),
].join('\n');
const PROMPTS = {
  S1: ['A message from the PM: we have changed our mind about avatars. From today avatars load from the CDN whenever a CDN '
    + 'address exists; the local file is only the fallback. Nothing to build yet.'],
  S2: ['Earlier you asked me whether product photos should also load locally, like avatars. My answer: no. Product photos '
    + 'keep loading from the CDN, at least until our CDN contract ends next March; then we decide again.'],
  S3: ['Create a UserAvatar component.',
    "Now create a TeamAvatars component that shows up to five team members' avatars in a row, using UserAvatar."],
};
// A1's role patterns (V2-D17-eval/eval.mjs), for the two roles this map holds
const ROLES = { 'lead developer': /lead developer|\bdeveloper\b|\bthe lead\b/i, PM: /\bPM\b|product manager/i };

const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); };
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
function session(cwd, plugin, prompt, resume) {
  const args = ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config',
    '--disallowedTools', 'Bash,WebFetch,WebSearch,Skill', '--permission-mode', 'acceptEdits', '--output-format', 'json',
    '--plugin-dir', plugin, ...(resume ? ['--resume', resume] : [])];
  const r = spawnSync(CLAUDE, args, { cwd, input: prompt, encoding: 'utf8', env: env(), timeout: 1_200_000, maxBuffer: 64 << 20 });
  try { return JSON.parse(r.stdout); } catch { return { is_error: true, result: '', session_id: null, stderr: (r.stderr ?? '').slice(0, 300) }; }
}
const blocks = (t) => t.replace(/\r/g, '').split(/^(?=#{1,3} )/m).filter((b) => b.startsWith('### ') && /^>/m.test(b));
const STATUS = /^- status:[ \t]*(superseded|narrowed|expired|done)[ \t]+\d{4}-\d{2}-\d{2}/m;

function score(id, dir, replies) {
  const now = blocks(fs.readFileSync(path.join(dir, '.project-map', 'captured.md'), 'utf8'));
  const original = (area) => now.find((b) => b.startsWith(`### ${area}\n`));
  const added = now.filter((b) => !['components', 'avatars', 'release notes'].some((a) => b.startsWith(`### ${a}\n`)));
  const dateLast = (b) => /^- source:.*\d{4}-\d{2}-\d{2}\s*$/m.test(b);
  if (id === 'S1') {
    const avatar = original('avatars') ?? '';
    const others = [original('components'), original('release notes'), ...added].filter(Boolean);
    const anyStatus = (b) => /^- status:/m.test(b);
    return { pass: STATUS.test(avatar) && !others.some(anyStatus), avatarStatus: STATUS.test(avatar), avatarAnyStatus: anyStatus(avatar),
      otherStatus: others.filter(anyStatus).length, added: added.length, addedDateLast: added.filter(dateLast).length };
  }
  if (id === 'S2') return { pass: added.length > 0 && added.every(dateLast), added: added.length, addedDateLast: added.filter(dateLast).length, anyStatus: now.filter((b) => /^- status:/m.test(b)).length };
  const named = (t) => Object.keys(ROLES).filter((k) => ROLES[k].test(t ?? ''));
  const [r1, r2] = replies.map((r) => r?.result ?? '');
  const first = named(r1), repeats = named(r2).filter((k) => first.includes(k));
  return { pass: first.length > 0 && repeats.length === 0, turn1Named: first.length, turn2Repeats: repeats.length, turn2Named: named(r2).length };
}

fs.mkdirSync(scratch, { recursive: true });
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
for (const id of which.split(',')) {
  const out = { scenario: id, model: MODEL, cli: spawnSync(CLAUDE, ['--version'], { encoding: 'utf8', env: env() }).stdout.trim(), runs: [] };
  for (let i = 1; i <= Number(runsArg); i++) {
    for (const [arm, plugin] of Object.entries(ARMS)) {
      const dir = path.join(scratch, `${id}-${arm}-${i}`);
      fs.rmSync(dir, { recursive: true, force: true });
      fs.cpSync(FIXTURE, dir, { recursive: true });
      fs.mkdirSync(path.join(dir, '.project-map'));
      fs.writeFileSync(path.join(dir, '.project-map', 'captured.md'), MAP);
      git(dir, 'init', '-q');
      git(dir, 'add', '-A');
      git(dir, 'commit', '-q', '-m', 'base');
      const replies = [];
      let sid = null;
      for (const p of PROMPTS[id]) { const r = session(dir, plugin, p, sid); replies.push(r); sid = r.session_id ?? sid; }
      const valid = replies.every((r) => !r.is_error && r.result !== undefined);
      const s = valid ? score(id, dir, replies) : { pass: false };
      out.runs.push({ arm, run: i, valid, ...s });
      console.log(`${id} ${arm} ${i}: ${valid ? JSON.stringify(s) : `invalid ${replies.map((r) => r.stderr ?? '').join(' ')}`}`);
    }
  }
  for (const arm of Object.keys(ARMS)) {
    const rs = out.runs.filter((r) => r.arm === arm && r.valid);
    out[arm] = { valid: rs.length, pass: rs.filter((r) => r.pass).length };
  }
  fs.writeFileSync(path.join(HERE, 'results', `${id}.json`), `${JSON.stringify(out, null, 1)}\n`);
  console.log(`${id}: candidate ${out.candidate.pass} of ${out.candidate.valid}, control ${out.control.pass} of ${out.control.valid}`);
}
