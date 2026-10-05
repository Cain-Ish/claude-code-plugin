#!/usr/bin/env node
// usage-audit.mjs: per-TURN audit of the second-brain per-prompt injection against what the
// session then read. Dev diagnostic (sb-diagnostics-and-tooling §10); the 1-week post-release
// check for 0.55.0 (machine-turn skip, headless-child gate) runs it. Node >= 18, no dependencies,
// read-only: it streams transcripts line by line and never loads a whole .jsonl.
//
// Turn classification is the PRODUCT's rule, read at runtime so the two cannot drift:
//   * the `# machine-turn:begin/end` case block in scripts/persona-context.sh (prefix -> kind);
//   * the hook's trivial-skip triage arms (ack list, thanks-prefixes, action verbs), which decide
//     whether a prompt ever reaches the exact-repeat check;
//   * the archive-only boilerplate prefixes (used only to grade "past sessions" snippets) are a
//     copy, guarded: each literal must appear in mcp/src/tools/episodic-search.ts.
// A block or arm that no longer parses is exit 2 (fail loud), never a silent fallback.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT_GUESS = path.resolve(SCRIPT_DIR, '..', '..', '..', '..');
const KB_READ_TOOLS = ['knowledge_fetch', 'knowledge_search', 'knowledge_neighbors', 'episodic_search', 'episodic_read'];
const KB_TOOL_RE = new RegExp(`^mcp__.+__(${KB_READ_TOOLS.join('|')})$`);
const KB_LINE_RE = new RegExp(`__(?:${KB_READ_TOOLS.join('|')})"`);
const PERSONA_MARK = '[Persona context';
const FETCH_LOOKAHEAD = 2; // an offer counts as fetched in its own turn or the next 2 turns (any kind)
const HEADLESS_ENTRYPOINT = 'sdk-cli'; // the hook's own test: CLAUDE_CODE_ENTRYPOINT = sdk-cli
const DAY_MS = 86400000;
// Archive-only boilerplate (episodic-search.ts MACHINE_TURN_PREFIXES / MACHINE_LINE_PREFIXES that
// never reach the hook). Guarded by guardArchiveExtras().
const ARCHIVE_TURN_PREFIXES = ['Base directory for this skill:', 'Caveat: The messages below were generated'];
const ARCHIVE_LINE_PREFIXES = ['[Image: source:', '[Image: original', '[Request interrupted by user'];

class UsageError extends Error {}

const HELP = `usage-audit.mjs: per-turn usage audit of the second-brain per-prompt injection.

  node usage-audit.mjs [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--project SUBSTR] [--json]
  node usage-audit.mjs --self-test

Options
  --since D      first UTC day counted (default: 7 days before today)
  --until D      last UTC day counted, inclusive (default: open)
  --project S    only ~/.claude/projects/<dir> whose dir name contains S (case-insensitive)
  --json         machine-readable object instead of the text table
  --root DIR     transcripts root (default ~/.claude/projects)
  --audit FILE   audit log (default $BRAIN_DIR or ~/.second-brain, /audit-log.jsonl)
  --hook FILE    persona-context.sh to read the rule from (default: this repo's scripts/)
  --self-test    run the embedded fixture, assert exact counts

Definitions
  turn       a turn-opening user record plus the attachments and assistant records after it, up
             to the next opener. Openers: when the file carries turnOrigin (CLI >= 2.1.278), only
             records with turnOrigin; before that, every non-tool-result non-meta user record
             (except a bare "[Request interrupted by user]" and a <command-name>-led local builtin)
             plus meta records with the peer prefix. <local-command-…> records are never turns.
  human      a turn the hook's rule lets through: no machine-turn prefix and not an exact repeat
             of the session's previous human prompt (after the ack triage, like the hook). A slash
             command is judged as the hook saw it: "/name args", rebuilt from the expanded tags.
  machine    kind = the block's kind, or "repeat". Cross-checked against turnOrigin, reported.
  injection  a hook_additional_context attachment containing "${PERSONA_MARK}".
  offered    distinct [[slug]] in an injection outside its [Past sessions] section.
  fetched    knowledge_fetch(slug) in the same turn or the next ${FETCH_LOOKAHEAD} turns of any kind.
  kb reads   tool_use of ${KB_READ_TOOLS.join(', ')}.
  headless   main sessions with entrypoint ${HEADLESS_ENTRYPOINT}: excluded from the human metrics.
  subagents  <proj>/<sid>/subagents/**/*.jsonl, counted separately.
  window     a turn is in the window when its opener's timestamp is; attachments and subagent
             records by their own timestamp. Dates are UTC days.

Exit: 0 ok (self-test: all assertions passed); 1 self-test failure; 2 usage error, missing input,
or the hook's rule no longer parses.`;

// ---------- rule: read from persona-context.sh ----------

/** Parse the `# machine-turn:begin/end` block into ordered [{prefix, kind}] (first match wins,
 *  as in the bash `case`). Every line must be a case header, esac, a comment, blank, or an arm
 *  whose alternatives are all single-quoted literal prefixes ('...'*). Anything else throws. */
export function parseMachineTurnBlock(src) {
  const m = /^[ \t]*# machine-turn:begin[^\n]*\n([\s\S]*?)^[ \t]*# machine-turn:end/m.exec(src);
  if (!m) throw new UsageError('no "# machine-turn:begin" ... "# machine-turn:end" block in the hook');
  const rules = [];
  for (const raw of m[1].split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#') || /^case\s.*\sin$/.test(line) || line === 'esac') continue;
    const arm = /^(.+?)\)\s*_MT_KIND=([A-Za-z0-9_-]+)\s*;;$/.exec(line);
    if (!arm) throw new UsageError(`machine-turn block: unparseable line: ${line}`);
    for (const alt of arm[1].split('|')) {
      const lit = /^'([^']+)'\*$/.exec(alt.trim());
      if (!lit) throw new UsageError(`machine-turn block: alternative is not a '<literal>'* prefix: ${alt.trim()}`);
      rules.push({ prefix: lit[1], kind: arm[2] });
    }
  }
  if (!rules.length) throw new UsageError('machine-turn block parsed to zero prefixes');
  return rules;
}

function caseArmTokens(region, re, what) {
  const m = re.exec(region);
  if (!m) throw new UsageError(`hook triage: ${what} arm not found`);
  return m[1].replace(/\\\r?\n/g, ' ').split('|').map(t => t.trim()).filter(Boolean).map(t => {
    let s = t.endsWith('*') ? t.slice(0, -1) : t;
    if (s.startsWith('"') && s.endsWith('"')) s = s.slice(1, -1);
    if (!s || /["*|()]/.test(s)) throw new UsageError(`hook triage: ${what} token not a plain literal: ${t}`);
    return { lit: s, glob: t.endsWith('*') };
  });
}

/** The trivial-skip triage arms (ack exact matches, thanks-prefixes <= 8 words, action verbs). */
export function parseTriage(src) {
  const a = src.indexOf('# --- Trivial-skip triage');
  const b = src.indexOf('# --- Exact-repeat skip', a);
  if (a < 0 || b < 0) throw new UsageError('hook triage: region markers not found');
  const region = src.slice(a, b);
  const acks = caseArmTokens(region, /case "\$P_TRIM" in\s*\n((?:(?!esac)[\s\S])*?)\)\s*\n\s*_buddy_exit ;;/, 'ack');
  const thanks = caseArmTokens(region, /case "\$P_TRIM" in\s*\n((?:(?!esac)[\s\S])*?)\)\s*\n\s*\[ "\$W_COUNT" -le 8 \] && _buddy_exit ;;/, 'thanks');
  const verbs = caseArmTokens(region, /ACTION=0\s*\ncase "\$P_TRIM" in\s*\n((?:(?!esac)[\s\S])*?)\)\s*\n\s*ACTION=1 ;;/, 'action');
  if (acks.some(t => t.glob) || thanks.some(t => !t.glob) || verbs.some(t => !t.glob)) throw new UsageError('hook triage: arm shape changed (glob/exact mix)');
  if (!region.includes('if [ "$ACTION" -eq 0 ] && [ "$W_COUNT" -lt 4 ]; then')) throw new UsageError('hook triage: ACTION=0 && W_COUNT<4 rule not found');
  return { acks: new Set(acks.map(t => t.lit)), thanks: thanks.map(t => t.lit), verbs: verbs.map(t => t.lit) };
}

function resolveHook(opt) {
  const cands = opt ? [opt] : [
    path.join(REPO_ROOT_GUESS, 'scripts', 'persona-context.sh'),
    process.env.CLAUDE_PLUGIN_ROOT ? path.join(process.env.CLAUDE_PLUGIN_ROOT, 'scripts', 'persona-context.sh') : null,
  ].filter(Boolean);
  for (const c of cands) if (fs.existsSync(c)) return c;
  throw new UsageError(`persona-context.sh not found (tried: ${cands.join(', ')}); pass --hook`);
}

/** Every archive-only literal must still be quoted in episodic-search.ts. */
function guardArchiveExtras(tsPath) {
  if (!fs.existsSync(tsPath)) return { source: tsPath, guarded: false, missing: [] };
  const ts = fs.readFileSync(tsPath, 'utf8');
  const missing = [...ARCHIVE_TURN_PREFIXES, ...ARCHIVE_LINE_PREFIXES].filter(p => !ts.includes(`'${p}'`));
  return { source: tsPath, guarded: true, missing };
}

export function loadRule(hookPath) {
  const src = fs.readFileSync(hookPath, 'utf8').replace(/\r\n/g, '\n');
  const rules = parseMachineTurnBlock(src);
  const peer = rules.find(r => r.kind === 'peer');
  if (!rules.some(r => r.prefix === '<task-notification>') || !peer) {
    throw new UsageError('machine-turn block lacks <task-notification> or the peer prefix: format drift');
  }
  const triage = parseTriage(src);
  const extras = guardArchiveExtras(path.join(path.dirname(path.dirname(hookPath)), 'mcp', 'src', 'tools', 'episodic-search.ts'));
  return { hookPath, rules, peerPrefix: peer.prefix, triage, extras };
}

// ---------- classification (mirrors persona-context.sh) ----------

/** What the machine-turn `case` sees: CR stripped (the hook's tr -d '\r'), first 4 KB, leading
 *  whitespace, then a leading BOM, then whitespace again removed. */
export function hookView(text) {
  let p = String(text).replace(/\r/g, '').slice(0, 4096).replace(/^[ \t\n\v\f]+/, '');
  if (p.startsWith('\uFEFF')) p = p.slice(1).replace(/^[ \t\n\v\f]+/, '');
  return p;
}

export function classifyMachine(text, rule) {
  const v = hookView(text);
  for (const r of rule.rules) if (v.startsWith(r.prefix)) return r.kind;
  return null;
}

/** True when the hook's trivial-skip triage lets the prompt through to the exact-repeat check. */
export function passesTriage(prompt, triage) {
  const pLower = prompt.replace(/[A-Z]/g, c => c.toLowerCase()).replace(/[ \t\n\v\f\r]+/g, ' ');
  const pTrim = pLower.replace(/^ /, '').replace(/ $/, '');
  const words = pTrim.split(' ').filter(Boolean).length;
  if (triage.acks.has(pTrim)) return false;
  if (words <= 8 && triage.thanks.some(t => pTrim.startsWith(t))) return false;
  const action = triage.verbs.some(v => pTrim.startsWith(v));
  return action || words >= 4;
}

/** A "past sessions" snippet is boilerplate when it is a machine turn by the hook rule or by the
 *  archive-only prefixes; a line-prefixed one only when nothing human remains after those lines. */
export function isBoilerplateSnippet(snippet, rule) {
  const v = hookView(snippet);
  if (!v) return false;
  if (classifyMachine(v, rule)) return true;
  if (ARCHIVE_TURN_PREFIXES.some(p => v.startsWith(p))) return true;
  if (ARCHIVE_LINE_PREFIXES.some(p => v.startsWith(p))) {
    const rest = v.split('\n').filter(l => l.trim() && !ARCHIVE_LINE_PREFIXES.some(p => l.trimStart().startsWith(p))).join('\n').trim();
    return !rest || isBoilerplateSnippet(rest, rule);
  }
  return false;
}

/** A slash command reaches the hook RAW ("/name args"; probed on CLI 2.1.289), but the transcript
 *  stores it expanded: <command-message>, <command-name>, <command-args> tags and nothing else.
 *  Returns the prompt the hook saw, or null when the text is not purely that expanded form (a
 *  hand-typed "<command-message>… more text" stays a tag). A hand-typed prompt that reproduces the
 *  expanded form exactly cannot be told apart and is treated as the command. */
export function expandedCommandPrompt(text) {
  let rest = hookView(text).trimEnd();
  if (!/^<command-(?:message|name)>/.test(rest)) return null;
  const parts = {};
  const tag = /^<(command-message|command-name|command-args)>([\s\S]*?)<\/\1>\s*/;
  while (rest) {
    const m = tag.exec(rest);
    if (!m || m[1] in parts) return null;
    parts[m[1]] = m[2];
    rest = rest.slice(m[0].length);
  }
  const name = (parts['command-name'] || '').trim().replace(/^\/+/, '');
  if (!name) return null;
  const args = (parts['command-args'] || '').trim();
  return args ? `/${name} ${args}` : `/${name}`;
}

function contentText(c) {
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) return c.map(x => (typeof x === 'string' ? x : (x && x.type === 'text' && typeof x.text === 'string') ? x.text : '')).filter(Boolean).join('\n');
  return '';
}
const attText = c => (Array.isArray(c) ? c.map(x => (typeof x === 'string' ? x : '')).join('\n') : typeof c === 'string' ? c : '');

function offeredSlugs(inj) {
  let s = inj;
  const p = s.indexOf('[Past sessions');
  if (p >= 0) {
    const e = s.indexOf('[End untrusted', p);
    s = s.slice(0, p) + (e >= 0 ? s.slice(e) : '');
  }
  return new Set([...s.matchAll(/\[\[([A-Za-z0-9][A-Za-z0-9._\/-]*)\]\]/g)].map(m => m[1]));
}

function pastSnippets(inj) {
  const p = inj.indexOf('[Past sessions');
  if (p < 0) return [];
  let sec = inj.slice(p);
  const e = sec.indexOf('[End untrusted');
  if (e >= 0) sec = sec.slice(0, e);
  const nl = sec.indexOf('\n');
  sec = nl >= 0 ? sec.slice(nl + 1) : '';
  return sec.split(/^- "/m).slice(1).map(x => x.replace(/(?:\.\.\.)?"\s*\([^()\n]*\)\s*$/, '').trimEnd());
}

function scriptOf(a) {
  const m = String(a.command || '').match(/[A-Za-z0-9_.-]+\.(?:sh|js|cjs|mjs|py|ts)\b/g);
  if (m) {
    const real = m.filter(x => x !== 'hook-timer.sh');
    return real.length ? real[real.length - 1] : m[0];
  }
  return a.hookName || a.hookEvent || '(unknown)';
}

const inc = (o, k, n = 1) => { o[k] = (o[k] || 0) + n; };

// ---------- transcript scanning ----------

function newTurn(r, kind) {
  return { ts: Date.parse(r.timestamp || ''), uuid: r.uuid || null, kind, origin: typeof r.turnOrigin === 'string' ? r.turnOrigin : null,
    dup: false, injections: 0, slugs: new Set(), snippets: 0, boiler: 0, fetched: new Set(), reads: {}, offeredFetched: 0 };
}

async function scanMainFile(fp, rule, seenUuids) {
  const s = { entrypoint: null, sid: null, turns: [], hookCancelled: [], badLines: 0, orphanInjections: 0 };
  let hasOrigin = false; let cur = null; let lastHuman = null;
  const rl = readline.createInterface({ input: fs.createReadStream(fp, { encoding: 'utf8' }), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line || line.includes('"type":"tool_result"')) continue;
    const maybe = line.includes('"type":"user"')
      || (line.includes('"type":"attachment"') && (line.includes('"hook_additional_context"') || line.includes('"hook_cancelled"')))
      || (line.includes('"type":"assistant"') && KB_LINE_RE.test(line));
    if (!maybe) continue;
    let r;
    try { r = JSON.parse(line); } catch { s.badLines++; continue; }
    if (!r || typeof r !== 'object') { s.badLines++; continue; }
    if (!s.entrypoint && typeof r.entrypoint === 'string') s.entrypoint = r.entrypoint;
    if (!s.sid && typeof r.sessionId === 'string') s.sid = r.sessionId;
    if (r.isSidechain === true) continue;
    if (r.type === 'user' && r.message) {
      if (typeof r.turnOrigin === 'string') hasOrigin = true;
      const text = contentText(r.message.content);
      const view = hookView(text);
      // Local-command output/caveat (/reload-plugins, /compact, …) never reaches the model as a prompt.
      if (view.startsWith('<local-command-')) continue;
      const command = expandedCommandPrompt(text);
      let opens;
      if (hasOrigin) opens = typeof r.turnOrigin === 'string';
      // Legacy: a <command-name>-led record is a local builtin (no UserPromptSubmit in 70 of 72 probed).
      else if (command !== null) opens = view.startsWith('<command-message>');
      else if (r.isMeta) opens = view.startsWith(rule.peerPrefix);
      else opens = !/^\[Request interrupted by user[^\n]*$/.test(view.trim());
      if (!opens) continue;
      const prompt = command !== null ? command : text;
      let kind = classifyMachine(prompt, rule);
      if (!kind) {
        const p = prompt.replace(/\r/g, '');
        if (p.startsWith('/?') || !passesTriage(p, rule.triage)) { if (p) lastHuman = p; }
        else if (lastHuman !== null && p === lastHuman) kind = 'repeat';
        else if (p) lastHuman = p;
      }
      cur = newTurn(r, kind || 'human');
      if (cur.uuid) { if (seenUuids.has(cur.uuid)) cur.dup = true; else seenUuids.add(cur.uuid); }
      s.turns.push(cur);
    } else if (r.type === 'attachment' && r.attachment) {
      const a = r.attachment;
      if (a.type === 'hook_cancelled') s.hookCancelled.push({ ts: Date.parse(r.timestamp || ''), script: scriptOf(a) });
      else if (a.type === 'hook_additional_context') {
        const c = attText(a.content);
        if (!c.includes(PERSONA_MARK)) continue;
        if (!cur) { s.orphanInjections++; continue; }
        cur.injections++;
        for (const sl of offeredSlugs(c)) cur.slugs.add(sl);
        for (const sn of pastSnippets(c)) { cur.snippets++; if (isBoilerplateSnippet(sn, rule)) cur.boiler++; }
      }
    } else if (r.type === 'assistant' && cur && r.message && Array.isArray(r.message.content)) {
      for (const b of r.message.content) {
        if (!b || b.type !== 'tool_use') continue;
        const m = KB_TOOL_RE.exec(b.name || '');
        if (!m) continue;
        inc(cur.reads, m[1]);
        if (m[1] === 'knowledge_fetch' && b.input && typeof b.input.slug === 'string') cur.fetched.add(b.input.slug.trim());
      }
    }
  }
  const T = s.turns;
  for (let i = 0; i < T.length; i++) {
    for (const sl of T[i].slugs) {
      for (let j = i; j <= Math.min(i + FETCH_LOOKAHEAD, T.length - 1); j++) if (T[j].fetched.has(sl)) { T[i].offeredFetched++; break; }
    }
  }
  return s;
}

async function scanSubagentFile(fp, inWin, agg) {
  let any = false;
  const rl = readline.createInterface({ input: fs.createReadStream(fp, { encoding: 'utf8' }), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line || line.includes('"type":"tool_result"')) continue;
    const isAtt = line.includes('"type":"attachment"') && (line.includes('"hook_additional_context"') || line.includes('"hook_cancelled"'));
    const isAsst = line.includes('"type":"assistant"') && KB_LINE_RE.test(line);
    const isUser = line.includes('"type":"user"');
    if (!isAtt && !isAsst && !isUser) continue;
    let r;
    try { r = JSON.parse(line); } catch { agg.badLines++; continue; }
    if (!r || !inWin(Date.parse(r.timestamp || ''))) continue;
    any = true;
    if (r.type === 'assistant' && r.message && Array.isArray(r.message.content)) {
      for (const b of r.message.content) {
        const m = b && b.type === 'tool_use' ? KB_TOOL_RE.exec(b.name || '') : null;
        if (m) { agg.kbReads++; inc(agg.kbReadsByTool, m[1]); }
      }
    } else if (r.type === 'attachment' && r.attachment) {
      const a = r.attachment;
      if (a.type === 'hook_cancelled') inc(agg.hookCancelled, scriptOf(a));
      else if (a.type === 'hook_additional_context' && attText(a.content).includes(PERSONA_MARK)) agg.injections++;
    }
  }
  return any;
}

function listSubagentFiles(dir, acc) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) listSubagentFiles(p, acc);
    else if (e.isFile() && e.name.endsWith('.jsonl')) acc.push(p);
  }
  return acc;
}

// ---------- aggregation ----------

function newScope() {
  return { sessions: 0, humanTurns: 0, machineTurns: 0, machineByKind: {}, injHuman: 0, injMachine: 0,
    humanTurnsInjected: 0, machineTurnsInjected: 0, slugOffers: 0, slugFetched: 0, readsHuman: 0,
    readsMachine: 0, readsHumanByTool: {}, snippets: 0, boiler: 0, snippetsHuman: 0, boilerHuman: 0,
    hookCancelled: {}, ruleVsOrigin: {} };
}

function addSession(sc, sess, inWin) {
  let counted = false;
  for (const t of sess.turns) {
    if (t.dup || !inWin(t.ts)) continue;
    counted = true;
    const human = t.kind === 'human';
    const reads = Object.values(t.reads).reduce((a, b) => a + b, 0);
    const o = (sc.ruleVsOrigin[t.kind] = sc.ruleVsOrigin[t.kind] || {});
    inc(o, t.origin || '(none)');
    sc.snippets += t.snippets; sc.boiler += t.boiler;
    if (human) {
      sc.humanTurns++; sc.injHuman += t.injections; if (t.injections) sc.humanTurnsInjected++;
      sc.slugOffers += t.slugs.size; sc.slugFetched += t.offeredFetched;
      sc.readsHuman += reads; for (const [k, v] of Object.entries(t.reads)) inc(sc.readsHumanByTool, k, v);
      sc.snippetsHuman += t.snippets; sc.boilerHuman += t.boiler;
    } else {
      sc.machineTurns++; inc(sc.machineByKind, t.kind); sc.injMachine += t.injections;
      if (t.injections) sc.machineTurnsInjected++; sc.readsMachine += reads;
    }
  }
  for (const h of sess.hookCancelled) if (inWin(h.ts)) inc(sc.hookCancelled, h.script);
  if (counted) sc.sessions++;
}

const ratio = (a, b) => (b ? Math.round((a / b) * 1000) / 1000 : null);

function finalizeScope(sc) {
  const ruleHumanOriginOther = {}; const ruleMachineOriginHuman = {};
  for (const [kind, origins] of Object.entries(sc.ruleVsOrigin)) {
    for (const [origin, n] of Object.entries(origins)) {
      if (kind === 'human' && origin !== 'human' && origin !== '(none)') inc(ruleHumanOriginOther, origin, n);
      if (kind !== 'human' && origin === 'human') inc(ruleMachineOriginHuman, kind, n);
    }
  }
  return {
    sessions: sc.sessions,
    humanTurns: sc.humanTurns,
    machineTurns: { total: sc.machineTurns, byKind: sc.machineByKind },
    injections: { onHumanTurns: sc.injHuman, onMachineTurns: sc.injMachine, humanTurnsInjected: sc.humanTurnsInjected,
      machineTurnsInjected: sc.machineTurnsInjected, machineShare: ratio(sc.injMachine, sc.injHuman + sc.injMachine) },
    wikiSlugsOffered: { onHumanTurns: sc.slugOffers, perHumanTurn: ratio(sc.slugOffers, sc.humanTurns) },
    offeredFetched: { lookaheadTurns: FETCH_LOOKAHEAD, offers: sc.slugOffers, fetched: sc.slugFetched, rate: ratio(sc.slugFetched, sc.slugOffers) },
    kbReads: { onHumanTurns: sc.readsHuman, perHumanTurn: ratio(sc.readsHuman, sc.humanTurns), onMachineTurns: sc.readsMachine, byToolOnHumanTurns: sc.readsHumanByTool },
    pastSessions: { snippets: sc.snippets, machineBoilerplate: sc.boiler, onHumanTurns: { snippets: sc.snippetsHuman, machineBoilerplate: sc.boilerHuman } },
    hookCancelled: sc.hookCancelled,
    originCrossCheck: { ruleVsOrigin: sc.ruleVsOrigin, ruleHumanOriginOther, ruleMachineOriginHuman },
  };
}

function readAudit(file, inWin, scannedSids) {
  const out = { file, missing: false, rows: 0, badLines: 0, coverageFrom: null,
    machineTurn: { total: 0, byKind: {}, forScannedSessions: 0 }, headlessChild: { total: 0, byHook: {} } };
  if (!fs.existsSync(file)) { out.missing = true; return out; }
  let min = Infinity;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    let r;
    try { r = JSON.parse(line); } catch { out.badLines++; continue; }
    if (!r || typeof r !== 'object') { out.badLines++; continue; }
    out.rows++;
    const ts = Date.parse(r.timestamp || r.ts || '');
    if (ts < min) min = ts;
    // Gate rows are sb_log_error-shaped: match the MESSAGE field's head, never a substring of the
    // line (guard rows quote commands that mention gate=... in their "target").
    const msg = typeof r.message === 'string' ? r.message : '';
    if (!inWin(ts)) continue;
    if (msg.startsWith('gate=machine-turn ')) {
      out.machineTurn.total++;
      inc(out.machineTurn.byKind, (/\bkind=(\S+)/.exec(msg) || [])[1] || '(none)');
      const sid = (/\bsid=(\S*)/.exec(msg) || [])[1];
      if (sid && scannedSids.has(sid)) out.machineTurn.forScannedSessions++;
    } else if (msg.startsWith('gate=headless-child ')) {
      out.headlessChild.total++;
      inc(out.headlessChild.byHook, (/\bhook=(\S*)/.exec(msg) || [])[1] || '(none)');
    }
  }
  out.coverageFrom = Number.isFinite(min) ? new Date(min).toISOString().replace('.000Z', 'Z') : null;
  return out;
}

function parseDay(s, flag) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s || '') || Number.isNaN(Date.parse(`${s}T00:00:00Z`))) throw new UsageError(`${flag} needs YYYY-MM-DD, got: ${s}`);
  return Date.parse(`${s}T00:00:00Z`);
}

export async function runAudit(opts) {
  const rule = opts.rule || loadRule(resolveHook(opts.hook));
  const root = opts.root || path.join(os.homedir(), '.claude', 'projects');
  if (!fs.existsSync(root)) throw new UsageError(`transcripts root not found: ${root}`);
  const sinceMs = opts.since ? parseDay(opts.since, '--since') : -Infinity;
  const untilMs = opts.until ? parseDay(opts.until, '--until') + DAY_MS : Infinity;
  if (untilMs <= sinceMs) throw new UsageError('--until is before --since');
  const inWin = t => Number.isFinite(t) && t >= sinceMs && t < untilMs;
  const filt = opts.project ? String(opts.project).toLowerCase() : null;

  const overall = newScope(); const byProject = {};
  const headless = newScope(); const headlessByProject = {};
  const sub = { files: 0, kbReads: 0, kbReadsByTool: {}, injections: 0, hookCancelled: {}, byProject: {}, badLines: 0 };
  const scan = { root, mainFiles: 0, subagentFiles: 0, skippedByMtime: 0, badLines: 0, duplicateTurns: 0, orphanInjections: 0, entrypoints: {} };
  const seenUuids = new Set(); const scannedSids = new Set();

  const projects = fs.readdirSync(root, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name).sort();
  for (const proj of projects) {
    if (filt && !proj.toLowerCase().includes(filt)) continue;
    const pdir = path.join(root, proj);
    const entries = fs.readdirSync(pdir, { withFileTypes: true });
    const mains = entries.filter(e => e.isFile() && e.name.endsWith('.jsonl')).map(e => path.join(pdir, e.name))
      .map(f => ({ f, st: fs.statSync(f) })).sort((a, b) => a.st.mtimeMs - b.st.mtimeMs);
    for (const { f, st } of mains) {
      if (st.mtimeMs < sinceMs) { scan.skippedByMtime++; continue; }
      scan.mainFiles++;
      const sess = await scanMainFile(f, rule, seenUuids);
      scan.badLines += sess.badLines; scan.orphanInjections += sess.orphanInjections;
      scan.duplicateTurns += sess.turns.filter(t => t.dup).length;
      inc(scan.entrypoints, sess.entrypoint || '(none)');
      if (sess.sid) scannedSids.add(sess.sid);
      if (sess.entrypoint === HEADLESS_ENTRYPOINT) {
        const before = headless.sessions;
        addSession(headless, sess, inWin);
        if (headless.sessions > before) inc(headlessByProject, proj);
      } else {
        addSession(overall, sess, inWin);
        addSession((byProject[proj] = byProject[proj] || newScope()), sess, inWin);
      }
    }
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      const sdir = path.join(pdir, e.name, 'subagents');
      if (!fs.existsSync(sdir)) continue;
      for (const f of listSubagentFiles(sdir, [])) {
        if (fs.statSync(f).mtimeMs < sinceMs) { scan.skippedByMtime++; continue; }
        scan.subagentFiles++;
        if (await scanSubagentFile(f, inWin, sub)) { sub.files++; inc(sub.byProject, proj); }
      }
    }
  }
  scan.badLines += sub.badLines;
  const auditFile = opts.audit || path.join(process.env.BRAIN_DIR || path.join(os.homedir(), '.second-brain'), 'audit-log.jsonl');
  const projOut = {};
  for (const [p, sc] of Object.entries(byProject)) if (sc.sessions) projOut[p] = finalizeScope(sc);
  const h = finalizeScope(headless);
  return {
    tool: 'usage-audit', version: 1, generatedAt: new Date().toISOString(),
    window: { since: opts.since || null, until: opts.until || null, project: opts.project || null, timezone: 'UTC' },
    rule: { hook: rule.hookPath, prefixes: rule.rules.length, kinds: [...new Set(rule.rules.map(r => r.kind)), 'repeat'],
      triage: { acks: rule.triage.acks.size, thanksPrefixes: rule.triage.thanks.length, actionVerbs: rule.triage.verbs.length },
      archiveExtras: rule.extras },
    interactive: { overall: finalizeScope(overall), byProject: projOut },
    headless: { sessions: h.sessions, humanTurns: h.humanTurns, machineTurns: h.machineTurns, injections: h.injections.onHumanTurns + h.injections.onMachineTurns,
      kbReads: h.kbReads.onHumanTurns + h.kbReads.onMachineTurns, hookCancelled: h.hookCancelled, byProject: headlessByProject },
    subagents: { files: sub.files, kbReads: sub.kbReads, kbReadsByTool: sub.kbReadsByTool, injections: sub.injections, hookCancelled: sub.hookCancelled, byProject: sub.byProject },
    audit: readAudit(auditFile, inWin, scannedSids),
    scan,
  };
}

// ---------- text output ----------

const fmtObj = (o, top = Infinity) => {
  const e = Object.entries(o).sort((a, b) => b[1] - a[1]);
  if (!e.length) return '-';
  const shown = e.slice(0, top).map(([k, v]) => `${k} ${v}`).join(', ');
  return e.length > top ? `${shown}, +${e.length - top} more (--json)` : shown;
};
const pct = r => (r === null ? '-' : `${Math.round(r * 100)}%`);
const num = r => (r === null ? '-' : r.toFixed(2));

export function renderText(res) {
  const L = [];
  const w = res.window;
  L.push(`usage-audit  window ${w.since || '(start)'}..${w.until || '(open)'} UTC${w.project ? `  project~${w.project}` : ''}`);
  L.push(`rule: ${res.rule.hook} (${res.rule.prefixes} prefixes; kinds ${res.rule.kinds.join(', ')})`);
  const names = Object.keys(res.interactive.byProject);
  let cp = names.length > 1 ? names.reduce((a, b) => { let i = 0; while (i < a.length && a[i] === b[i]) i++; return a.slice(0, i); }) : '';
  cp = cp.slice(0, cp.lastIndexOf('-') + 1);
  const rows = [['project', 'sess', 'human', 'mach', 'inj h/m', 'slugs/h', 'offer>fetch', 'reads/h', 'pastBP']];
  const row = (name, m) => [name, m.sessions, m.humanTurns, m.machineTurns.total, `${m.injections.onHumanTurns}/${m.injections.onMachineTurns}`,
    num(m.wikiSlugsOffered.perHumanTurn), `${m.offeredFetched.fetched}/${m.offeredFetched.offers} ${pct(m.offeredFetched.rate)}`,
    num(m.kbReads.perHumanTurn), `${m.pastSessions.machineBoilerplate}/${m.pastSessions.snippets}`].map(String);
  for (const n of names.sort((a, b) => res.interactive.byProject[b].humanTurns - res.interactive.byProject[a].humanTurns)) {
    rows.push(row((cp ? n.slice(cp.length) : n).slice(0, 34), res.interactive.byProject[n]));
  }
  const o = res.interactive.overall;
  rows.push(row('ALL', o));
  const widths = rows[0].map((_, i) => Math.max(...rows.map(r => r[i].length)));
  L.push(`INTERACTIVE main sessions (entrypoint != ${HEADLESS_ENTRYPOINT})${cp ? `  [project prefix ${cp} dropped]` : ''}`);
  for (const r of rows) L.push(r.map((c, i) => (i === 0 ? c.padEnd(widths[i]) : c.padStart(widths[i]))).join('  '));
  L.push(`machine turns by kind: ${fmtObj(o.machineTurns.byKind)}`);
  L.push(`injected turns: human ${o.injections.humanTurnsInjected}/${o.humanTurns}, machine ${o.injections.machineTurnsInjected}/${o.machineTurns.total}; machine share of injections ${pct(o.injections.machineShare)}`);
  L.push(`kb reads on human turns: ${fmtObj(o.kbReads.byToolOnHumanTurns)}; on machine turns: ${o.kbReads.onMachineTurns}`);
  L.push(`past-session snippets: ${o.pastSessions.machineBoilerplate}/${o.pastSessions.snippets} machine boilerplate (human turns ${o.pastSessions.onHumanTurns.machineBoilerplate}/${o.pastSessions.onHumanTurns.snippets})`);
  L.push(`turnOrigin cross-check: rule=human but origin ${fmtObj(o.originCrossCheck.ruleHumanOriginOther)}; rule=machine but origin=human: ${fmtObj(o.originCrossCheck.ruleMachineOriginHuman)}`);
  const hd = res.headless;
  L.push(`HEADLESS (${HEADLESS_ENTRYPOINT}): sessions ${hd.sessions}, turns ${hd.humanTurns + hd.machineTurns.total} (human-rule ${hd.humanTurns}), persona injections ${hd.injections}, kb reads ${hd.kbReads}`);
  const sb = res.subagents;
  L.push(`SUBAGENTS: files ${sb.files}, kb reads ${sb.kbReads} (${fmtObj(sb.kbReadsByTool)}), persona injections ${sb.injections}`);
  const a = res.audit;
  if (a.missing) L.push(`AUDIT: ${a.file} missing`);
  else L.push(`AUDIT (${a.file}, rows from ${a.coverageFrom || '-'}): gate=machine-turn ${a.machineTurn.total} (${fmtObj(a.machineTurn.byKind)}; ${a.machineTurn.forScannedSessions} in scanned sessions), gate=headless-child ${a.headlessChild.total} (${fmtObj(a.headlessChild.byHook)})`);
  L.push(`HOOK_CANCELLED interactive: ${fmtObj(o.hookCancelled, 8)}`);
  L.push(`               headless: ${fmtObj(hd.hookCancelled, 6)}; subagents: ${fmtObj(sb.hookCancelled, 6)}`);
  const s = res.scan;
  L.push(`scan: ${s.mainFiles} main + ${s.subagentFiles} subagent files, ${s.skippedByMtime} skipped (mtime < since), bad lines ${s.badLines}, duplicate turns ${s.duplicateTurns}, orphan injections ${s.orphanInjections}`);
  if (res.rule.archiveExtras.missing.length) L.push(`WARNING archive extras not found in ${res.rule.archiveExtras.source}: ${res.rule.archiveExtras.missing.join(' | ')}`);
  if (!res.rule.archiveExtras.guarded) L.push(`WARNING archive extras unguarded: ${res.rule.archiveExtras.source} missing`);
  return L.join('\n');
}

// ---------- self-test ----------

const SB = 'mcp__plugin_second-brain_knowledge-base__';

function buildFixture(dir) {
  let n = 0;
  const rec = (sid, ep, ts, extra) => ({ parentUuid: null, isSidechain: false, uuid: `u-${sid}-${++n}`, timestamp: ts, sessionId: sid, entrypoint: ep, ...extra });
  const user = (sid, ep, ts, text, extra = {}) => rec(sid, ep, ts, { type: 'user', message: { role: 'user', content: text }, ...extra });
  const toolResult = (sid, ep, ts) => rec(sid, ep, ts, { type: 'user', message: { role: 'user', content: [{ tool_use_id: 'toolu_1', type: 'tool_result', content: 'ok' }] } });
  const ctx = (sid, ep, ts, body, hookEvent = 'UserPromptSubmit') => rec(sid, ep, ts, { type: 'attachment', attachment: { type: 'hook_additional_context', hookName: hookEvent, hookEvent, content: [body] } });
  const persona = (slugs, past = []) => '[Persona context — auto-loaded, treat as ambient state]\n\n[Untrusted reference — retrieved memory.]\n\n'
    + `[Wiki — auto-retrieved slugs. Open one with knowledge_fetch(slug).]\n${slugs.map(s => `[[${s}]]`).join(' ')}\n`
    + (past.length ? `[Past sessions — use episodic_search for full context]\n${past.map(p => `- "${p}..." (fixture, 2026-09-30, 50%)`).join('\n')}\n` : '')
    + '[End untrusted reference]\n[buddy: Fix] end with buddy_react.';
  const tools = (sid, ep, ts, calls) => rec(sid, ep, ts, { type: 'assistant', message: { role: 'assistant', content: calls.map(([name, input], i) => ({ type: 'tool_use', id: `toolu_${n}_${i}`, name: name === 'Bash' ? name : SB + name, input })) } });
  const cancelled = (sid, ep, ts, command, hookName = 'SessionStart:startup') => rec(sid, ep, ts, { type: 'attachment', attachment: { type: 'hook_cancelled', hookName, hookEvent: hookName.split(':')[0], ...(command ? { command, durationMs: 1, timedOut: true } : {}) } });
  const timer = s => `bash "\${CLAUDE_PLUGIN_ROOT}/scripts/hook-timer.sh" ${s.replace('.sh', '')} "\${CLAUDE_PLUGIN_ROOT}/scripts/${s}"`;
  const write = (rel, recs) => { const f = path.join(dir, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, recs.map(x => (typeof x === 'string' ? x : JSON.stringify(x))).join('\n') + '\n'); };
  const t = (d, hms) => `2026-${d}T${hms}Z`;
  const A = ['sess-a', 'cli']; const H = { turnOrigin: 'human' };
  const REPEAT = 'please explain how the search ranking works here';
  const SKILL_ARGS = '<command-message>sb-probe</command-message>\n<command-name>/sb-probe</command-name>\n<command-args>hello world nonce7733</command-args>';
  write('projects/C--proj-alpha/sess-a.jsonl', [
    cancelled(...A, t('09-01', '09:59:00'), timer('session-load.sh')),
    user(...A, t('09-01', '10:00:00'), 'set up the fixture baseline before the window', H),
    ctx(...A, t('09-01', '10:00:01'), persona(['old-slug'])),
    user(...A, t('10-02', '10:00:00'), REPEAT, H), // T1 human
    ctx(...A, t('10-02', '10:00:01'), persona(['alpha-one', 'alpha-two', 'alpha-one'], ['<task-notification>\n<task-id>abc</task-id>', 'we discussed [[past-slug]] ranking weights'])),
    cancelled(...A, t('10-02', '10:00:01'), timer('session-load.sh')),
    ctx(...A, t('10-02', '10:00:02'), 'Plugin convention: fail loud, not silent.', 'PreToolUse'),
    tools(...A, t('10-02', '10:00:03'), [['knowledge_fetch', { slug: 'alpha-one', tier: 'gist' }], ['knowledge_search', { query: 'x' }], ['Bash', { command: 'ls' }], ['buddy_react', { line: 'x' }]]),
    toolResult(...A, t('10-02', '10:00:04')),
    user(...A, t('10-02', '10:00:05'), 'Base directory for this skill: C:/x/skills/foo', { isMeta: true }),
    '{"type":"user", "broken',
    user(...A, t('10-02', '10:01:00'), '<task-notification>\n<task-id>t1</task-id>', { turnOrigin: 'task_notification' }), // T2
    ctx(...A, t('10-02', '10:01:01'), persona(['alpha-three'], ['Another Claude session sent a message:\n<agent-message from="x">'])),
    user(...A, t('10-02', '10:02:00'), 'Another Claude session sent a message:\n<agent-message from="a1">\nreport\n</agent-message>', { isMeta: true, turnOrigin: 'peer' }), // T3
    ctx(...A, t('10-02', '10:02:01'), persona([])),
    tools(...A, t('10-02', '10:02:02'), [['knowledge_fetch', { slug: 'alpha-two' }]]), // T1+2: counts
    user(...A, t('10-02', '10:03:00'), `${REPEAT}\r`, H), // T4 exact repeat of T1 (CR stripped like the hook)
    tools(...A, t('10-02', '10:03:01'), [['episodic_search', { query: 'y' }]]),
    user(...A, t('10-02', '10:04:00'), 'ok', H), // T5 ack
    ctx(...A, t('10-02', '10:04:01'), '[buddy: Fix] end with buddy_react.'),
    user(...A, t('10-02', '10:05:00'), 'ok', H), // T6 ack again: human, never a repeat
    user(...A, t('10-02', '10:06:00'), 'Supervision check-in: check the agents now', { isMeta: true, turnOrigin: 'scheduled' }), // T7
    ctx(...A, t('10-02', '10:06:01'), persona(['beta-one'], ['Base directory for this skill: C:/x/skills/foo'])),
    // Slash commands: the transcript stores the expanded form, the hook got the raw `/name args`.
    user(...A, t('10-02', '10:07:00'), '<command-message>foo</command-message>\n<command-name>/foo</command-name>', H), // T8 human (/foo)
    user(...A, t('10-02', '10:07:10'), SKILL_ARGS, H), // T8a human (/sb-probe hello world nonce7733)
    user(...A, t('10-02', '10:07:20'), SKILL_ARGS, H), // T8b exact repeat of the reconstructed prompt
    user(...A, t('10-02', '10:07:30'), '<command-message>why</command-message> does this tag break my parser', H), // T8c hand-typed tag: machine
    user(...A, t('10-02', '10:08:00'), 'what does the fetch window boundary look like', H), // T9
    ctx(...A, t('10-02', '10:08:01'), persona(['gamma'])),
    tools(...A, t('10-02', '10:08:02'), [['knowledge_neighbors', { slug: 'gamma' }]]),
    user(...A, t('10-02', '10:09:00'), '<task-notification>\n<task-id>t2</task-id>', { turnOrigin: 'task_notification' }), // T10
    user(...A, t('10-02', '10:10:00'), '<task-notification>\n<task-id>t3</task-id>', { turnOrigin: 'task_notification' }), // T11
    user(...A, t('10-02', '10:11:00'), '<task-notification>\n<task-id>t4</task-id>', { turnOrigin: 'task_notification' }), // T12
    tools(...A, t('10-02', '10:11:01'), [['knowledge_fetch', { slug: 'gamma' }]]), // T9+3: does not count
  ]);
  const B = ['sess-b', 'cli']; // legacy transcript: no turnOrigin anywhere
  write('projects/C--proj-alpha/sess-b.jsonl', [
    user(...B, t('10-03', '10:00:00'), 'investigate the legacy transcript classification path'),
    ctx(...B, t('10-03', '10:00:01'), persona(['legacy-one'])),
    tools(...B, t('10-03', '10:00:02'), [['knowledge_fetch', { slug: 'legacy-one' }]]),
    user(...B, t('10-03', '10:01:00'), 'Another Claude session sent a message:\n<agent-message from="b1">x</agent-message>', { isMeta: true }),
    user(...B, t('10-03', '10:02:00'), 'Stop hook feedback:\nplease run the tests'),
    user(...B, t('10-03', '10:03:00'), 'This session is being continued from a previous conversation that ran out of context.', { isCompactSummary: true }),
    user(...B, t('10-03', '10:03:01'), 'Base directory for this skill: /y', { isMeta: true }),
    user(...B, t('10-03', '10:03:02'), '[Request interrupted by user]'),
    user(...B, t('10-03', '10:04:00'), '<bash-input>ls</bash-input>'),
    { ...user(...B, t('10-03', '10:05:00'), 'a sidechain prompt that is not a main turn'), isSidechain: true },
    // A local builtin (/reload-plugins) never reaches the model: caveat, command-name-led record, stdout.
    user(...B, t('10-03', '10:06:00'), '<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>', { isMeta: true }),
    user(...B, t('10-03', '10:06:01'), '<command-name>/reload-plugins</command-name>\n<command-message>reload-plugins</command-message>\n<command-args></command-args>'),
    user(...B, t('10-03', '10:06:02'), '<local-command-stdout>Reloaded 3 plugins</local-command-stdout>'),
    user(...B, t('10-03', '10:07:00'), '<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>the parser change please</command-args>'), // legacy skill command: human
  ]);
  const C = ['sess-c', 'sdk-cli'];
  write('projects/C--proj-beta/sess-c.jsonl', [
    user(...C, t('10-04', '10:00:00'), 'Below is a conversation log from a Claude Code coding session. Summarize it.', H),
    ctx(...C, t('10-04', '10:00:01'), persona(['h-one'])),
    tools(...C, t('10-04', '10:00:02'), [['knowledge_search', { query: 'z' }]]),
    cancelled(...C, t('10-04', '10:00:01'), timer('session-load.sh')),
  ]);
  const D = ['sess-d', 'cli'];
  write('projects/C--proj-beta/sess-d.jsonl', [
    user(...D, t('10-31', '23:59:59'), 'Fix the thing in module beta now', H),
    ctx(...D, t('10-31', '23:59:59'), persona(['delta-one', 'delta-two', 'delta-three'], ['[Image: source: C:/tmp/a.png]\nhere is the real question about it', '[Request interrupted by user]'])),
    cancelled(...D, t('10-31', '23:59:59'), timer('persona-context.sh'), 'UserPromptSubmit'),
    cancelled(...D, t('10-31', '23:59:59'), timer('persona-context.sh'), 'UserPromptSubmit'),
    cancelled(...D, t('10-31', '23:59:59'), null, 'PostToolUse:Read'),
    tools(...D, t('10-31', '23:59:59'), [['knowledge_fetch', { slug: 'delta-two' }], ['episodic_read', { path: 'p' }]]),
    user(...D, t('11-01', '00:00:01'), 'Another human prompt outside the window here', H),
    ctx(...D, t('11-01', '00:00:02'), persona(['out-slug'])),
    cancelled(...D, t('11-01', '00:00:02'), timer('persona-context.sh'), 'UserPromptSubmit'),
  ]);
  const S = ['sess-a', 'cli'];
  write('projects/C--proj-alpha/sess-a/subagents/agent-x.jsonl', [
    { ...user(...S, t('10-02', '10:05:00'), 'subagent task prompt'), isSidechain: true },
    { ...tools(...S, t('10-02', '10:06:00'), [['knowledge_fetch', { slug: 'alpha-one' }], ['knowledge_neighbors', { slug: 'alpha-one' }]]), isSidechain: true },
    { ...tools(...S, t('09-01', '11:00:00'), [['knowledge_search', { query: 'old' }]]), isSidechain: true },
    { ...cancelled(...S, t('10-02', '10:06:01'), 'bash "C:/x/scripts/guard.sh"', 'PreToolUse:Bash'), isSidechain: true },
  ]);
  write('projects/C--proj-alpha/sess-a/subagents/agent-x.meta.json', ['{"agentType":"x"}']);
  write('projects/C--proj-alpha/sess-a/tool-results/never-scanned.jsonl', [ctx(...A, t('10-02', '10:00:00'), persona(['tool-result-slug']))]);
  write('projects/stray.txt', ['not a project']);
  const gate = (ts, message, exit = 0) => ({ timestamp: ts, script: 'persona-context.sh', message, exit_code: exit });
  write('audit-log.jsonl', [
    gate('2026-09-01T00:00:00Z', 'gate=machine-turn kind=tag sid=sess-a'),
    gate('2026-10-02T10:00:01Z', 'gate=machine-turn kind=notification sid=sess-a'),
    gate('2026-10-02T10:00:02Z', 'gate=machine-turn kind=peer sid=sess-a'),
    gate('2026-10-02T10:00:03Z', 'gate=machine-turn kind=repeat sid=sess-a'),
    { timestamp: '2026-10-02T10:00:04Z', script: 'persona-context.sh', message: 'gate=headless-child hook=persona-context entrypoint=sdk-cli attended=', exit_code: 0 },
    { ts: '2026-10-02T10:00:05Z', hook: 'persona-tool-guard.sh', verdict: 'warn', rule: 'strip-silent-fallback', target: 'grep "gate=machine-turn kind=peer" audit-log.jsonl; grep gate=headless-child hook=x', session_id: 'sess-a' },
    gate('2026-10-02T10:00:06Z', 'machine-turn: cksum gave no CRC/length signature (got 0 chars)', 1),
    'not json',
  ]);
}

function canon(v) {
  if (Array.isArray(v)) return v.map(canon);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map(k => [k, canon(v[k])]));
  return v;
}

async function selfTest() {
  const fails = []; let checks = 0;
  const eq = (name, actual, expected) => {
    checks++;
    const a = JSON.stringify(canon(actual)); const e = JSON.stringify(canon(expected));
    if (a !== e) fails.push(`${name}: expected ${e}, got ${a}`);
  };
  const throwsUsage = (name, fn) => { checks++; try { fn(); fails.push(`${name}: did not throw`); } catch (e) { if (!(e instanceof UsageError)) fails.push(`${name}: threw ${e}`); } };

  const rule = loadRule(resolveHook(null));
  eq('rule: <task-notification> is notification', classifyMachine('<task-notification>x', rule), 'notification');
  eq('rule: peer prefix is peer', classifyMachine(`${rule.peerPrefix}\n<agent-message>`, rule), 'peer');
  eq('rule: whitespace + BOM stripped', classifyMachine('\n  \uFEFF <task-notification>x', rule), 'notification');
  eq('rule: a human <my-component> question is human', classifyMachine('<my-component> does not render', rule), null);
  eq('rule: kinds', [...new Set(rule.rules.map(r => r.kind))].sort(), ['continuation', 'notification', 'peer', 'stop-feedback', 'tag']);
  throwsUsage('parse: no block', () => parseMachineTurnBlock('echo hi\n'));
  throwsUsage('parse: non-literal alternative', () => parseMachineTurnBlock("# machine-turn:begin\ncase \"$x\" in\n  \"$y\"*) _MT_KIND=x ;;\nesac\n# machine-turn:end\n"));
  throwsUsage('parse: unknown line', () => parseMachineTurnBlock("# machine-turn:begin\n_MT_KIND=x\n# machine-turn:end\n"));
  eq('parse: ordered arms', parseMachineTurnBlock("# machine-turn:begin\ncase \"$x\" in\n  'a'*|'b'*) _MT_KIND=one ;;\n  'c'*) _MT_KIND=two ;;\nesac\n# machine-turn:end\n"),
    [{ prefix: 'a', kind: 'one' }, { prefix: 'b', kind: 'one' }, { prefix: 'c', kind: 'two' }]);
  eq('triage: ack', passesTriage('ok', rule.triage), false);
  eq('triage: thanks-prefix <= 8 words', passesTriage('thanks a lot for that', rule.triage), false);
  eq('triage: action verb', passesTriage('fix it', rule.triage), true);
  eq('triage: 3 words', passesTriage('how is it', rule.triage), false);
  eq('triage: 4 words', passesTriage('how is it going', rule.triage), true);
  eq('command form: skill with args', expandedCommandPrompt('<command-message>sb-probe</command-message>\n<command-name>/sb-probe</command-name>\n<command-args> hello world nonce7733 </command-args>'), '/sb-probe hello world nonce7733');
  eq('command form: no args', expandedCommandPrompt('<command-message>foo</command-message>\n<command-name>/foo</command-name>'), '/foo');
  eq('command form: empty args, name-led', expandedCommandPrompt('<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>'), '/clear');
  eq('command form: text outside the tags is not the expanded form', expandedCommandPrompt('<command-message>why</command-message> does this tag break my parser'), null);
  eq('command form: no command-name', expandedCommandPrompt('<command-message>x</command-message>'), null);
  eq('command form: text after a full command block', expandedCommandPrompt('<command-message>x</command-message><command-name>/x</command-name> and also look at the parser'), null);
  eq('command form: duplicated tag', expandedCommandPrompt('<command-name>/x</command-name><command-name>/y</command-name>'), null);
  eq('archive extras guarded', { guarded: rule.extras.guarded, missing: rule.extras.missing }, { guarded: true, missing: [] });

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-audit-'));
  try {
    buildFixture(tmp);
    const base = { rule, root: path.join(tmp, 'projects'), audit: path.join(tmp, 'audit-log.jsonl'), since: '2026-10-01', until: '2026-10-31' };
    const res = await runAudit(base);
    const o = res.interactive.overall;
    eq('sessions', o.sessions, 3);
    eq('human turns', o.humanTurns, 10);
    eq('machine turns', o.machineTurns, { total: 12, byKind: { notification: 4, peer: 2, repeat: 2, tag: 2, 'stop-feedback': 1, continuation: 1 } });
    eq('injections', [o.injections.onHumanTurns, o.injections.onMachineTurns, o.injections.humanTurnsInjected, o.injections.machineTurnsInjected], [5, 2, 5, 2]);
    eq('slugs offered', o.wikiSlugsOffered, { onHumanTurns: 8, perHumanTurn: 0.8 });
    eq('offered->fetched', o.offeredFetched, { lookaheadTurns: 2, offers: 8, fetched: 4, rate: 0.5 });
    eq('kb reads', o.kbReads, { onHumanTurns: 6, perHumanTurn: 0.6, onMachineTurns: 3, byToolOnHumanTurns: { knowledge_fetch: 3, knowledge_search: 1, knowledge_neighbors: 1, episodic_read: 1 } });
    eq('past sessions', o.pastSessions, { snippets: 6, machineBoilerplate: 4, onHumanTurns: { snippets: 5, machineBoilerplate: 3 } });
    eq('hook_cancelled interactive', o.hookCancelled, { 'session-load.sh': 1, 'persona-context.sh': 2, 'PostToolUse:Read': 1 });
    eq('origin cross-check', [o.originCrossCheck.ruleHumanOriginOther, o.originCrossCheck.ruleMachineOriginHuman], [{ scheduled: 1 }, { repeat: 2, tag: 1 }]);
    eq('by project', Object.fromEntries(Object.entries(res.interactive.byProject).map(([k, v]) => [k, [v.sessions, v.humanTurns, v.machineTurns.total]])), { 'C--proj-alpha': [2, 9, 12], 'C--proj-beta': [1, 1, 0] });
    eq('headless', [res.headless.sessions, res.headless.humanTurns, res.headless.injections, res.headless.kbReads, res.headless.hookCancelled], [1, 1, 1, 1, { 'session-load.sh': 1 }]);
    eq('subagents', [res.subagents.files, res.subagents.kbReads, res.subagents.injections, res.subagents.hookCancelled], [1, 2, 0, { 'guard.sh': 1 }]);
    eq('audit machine-turn', res.audit.machineTurn, { total: 3, byKind: { notification: 1, peer: 1, repeat: 1 }, forScannedSessions: 3 });
    eq('audit headless-child', res.audit.headlessChild, { total: 1, byHook: { 'persona-context': 1 } });
    eq('audit coverage + bad lines', [res.audit.coverageFrom, res.audit.badLines], ['2026-09-01T00:00:00Z', 1]);
    eq('scan', [res.scan.mainFiles, res.scan.subagentFiles, res.scan.badLines, res.scan.duplicateTurns], [4, 1, 1, 0]);
    const beta = await runAudit({ ...base, project: 'BETA' });
    eq('project filter', [beta.interactive.overall.sessions, beta.interactive.overall.humanTurns, beta.headless.sessions, beta.subagents.files, beta.audit.machineTurn.forScannedSessions], [1, 1, 1, 0, 0]);
    const text = renderText(res);
    checks++; if (!/^ALL\s+3\s+10\s+12\s+5\/2\s/m.test(text)) fails.push(`text table ALL row malformed:\n${text}`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  for (const f of fails) process.stdout.write(`FAIL ${f}\n`);
  process.stdout.write(`usage-audit self-test: ${checks - fails.length}/${checks} passed (rule: ${rule.hookPath})\n`);
  return fails.length ? 1 : 0;
}

// ---------- CLI ----------

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { const v = argv[++i]; if (v === undefined || v.startsWith('--')) throw new UsageError(`${a} needs a value`); return v; };
    if (a === '--since') o.since = val();
    else if (a === '--until') o.until = val();
    else if (a === '--project') o.project = val();
    else if (a === '--root') o.root = val();
    else if (a === '--audit') o.audit = val();
    else if (a === '--hook') o.hook = val();
    else if (a === '--json') o.json = true;
    else if (a === '--self-test') o.selfTest = true;
    else if (a === '-h' || a === '--help') o.help = true;
    else throw new UsageError(`unknown argument: ${a}`);
  }
  return o;
}

async function main() {
  let o;
  try { o = parseArgs(process.argv.slice(2)); } catch (e) { process.stderr.write(`usage-audit: ${e.message}\n\n${HELP}\n`); return 2; }
  if (o.help) { process.stdout.write(`${HELP}\n`); return 0; }
  try {
    if (o.selfTest) return await selfTest();
    if (!o.since) o.since = new Date(Date.now() - 7 * DAY_MS).toISOString().slice(0, 10);
    const res = await runAudit(o);
    process.stdout.write(o.json ? `${JSON.stringify(res, null, 2)}\n` : `${renderText(res)}\n`);
    return 0;
  } catch (e) {
    if (e instanceof UsageError) { process.stderr.write(`usage-audit: ${e.message}\n`); return 2; }
    throw e;
  }
}

main().then(code => { process.exitCode = code; }, e => { process.stderr.write(`usage-audit: ${e && e.stack || e}\n`); process.exitCode = 2; });
