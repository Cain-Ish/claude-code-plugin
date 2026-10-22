// Phase-gate correction (2026-10-22): for each rule a session followed, was its source in the main thread's context
// before the first write (a main-thread Read, or loaded by Claude Code), or read only by a subagent? The harness's
// inContextBeforeFirstWrite counts any thread's Read. Counts only, to stdout.
//   node mainreads.mjs <config> <arm>...
import fs from 'node:fs';
import path from 'node:path';

const [cfgPath, ...arms] = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
const S = path.join(path.dirname(path.resolve(cfgPath)), cfg.outDir ?? 'd20-stage2');
const low = (p) => String(p ?? '').replace(/\\/g, '/').toLowerCase();
const isWrite = (c) => c.type === 'tool_use' && ['Write', 'Edit', 'MultiEdit'].includes(c.name);
for (const t of cfg.tasks) for (const arm of arms) {
  const f = path.join(S, arm, `${t.id}.json`);
  if (!fs.existsSync(f)) continue;
  const out = {};
  for (const rec of JSON.parse(fs.readFileSync(f, 'utf8')).runs.filter((r) => r.valid)) {
    const ev = fs.readFileSync(path.join(S, arm, t.id, `run${rec.run}`, 'stream.jsonl'), 'utf8').split('\n')
      .flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
    const calls = ev.flatMap((e, i) => (e.type === 'assistant' ? (e.message?.content ?? []).filter((c) => c.type === 'tool_use').map((c) => ({ i, c, main: !e.parent_tool_use_id })) : []));
    const first = calls.find(({ c }) => isWrite(c))?.i ?? Infinity;
    for (const rule of t.rules) {
      if (!rec.rules[rule.id].final) continue;
      const src = `/${low(rule.source)}`;
      const reads = calls.filter(({ i, c }) => i < first && c.name === 'Read' && low(c.input?.file_path).endsWith(src));
      const loaded = (rec.instructionsLoaded ?? []).some((l) => `/${low(l.file)}`.endsWith(src));
      const kind = loaded ? 'loaded' : reads.some((r) => r.main) ? 'main read first' : reads.length ? 'subagent read only' : 'not read first';
      ((out[rule.id] ??= {})[kind] ??= 0);
      out[rule.id][kind]++;
    }
  }
  console.log(t.id, arm, JSON.stringify(out));
}
