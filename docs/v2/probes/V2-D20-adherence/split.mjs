// V2-D22, forced route across a compaction: for each rule an arm missed in a session, was its source read in the main
// thread before the compaction (compaction loss), only after it, or never (the forced decision did not reach it)?
// Counts only, to stdout (DECISIONS.md, pre-registered split).
//   node split.mjs <config> <arm>...
import fs from 'node:fs';
import path from 'node:path';

const [cfgPath, ...arms] = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
const S = path.join(path.dirname(path.resolve(cfgPath)), cfg.outDir ?? 'd20-stage2');
const slash = (p) => String(p ?? '').replace(/\\/g, '/').toLowerCase();
for (const t of cfg.tasks) for (const arm of arms) {
  const f = path.join(S, arm, `${t.id}.json`);
  if (!fs.existsSync(f)) continue;
  const out = {};
  for (const rec of JSON.parse(fs.readFileSync(f, 'utf8')).runs.filter((r) => r.valid)) {
    const ev = fs.readFileSync(path.join(S, arm, t.id, `run${rec.run}`, 'stream.jsonl'), 'utf8').split('\n')
      .flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
    const cut = ev.findIndex((e) => e.type === 'system' && e.subtype === 'compact_boundary');
    const reads = ev.flatMap((e, i) => (e.type === 'assistant' && !e.parent_tool_use_id ? (e.message?.content ?? [])
      .filter((c) => c.type === 'tool_use' && c.name === 'Read').map((c) => [i, slash(c.input?.file_path)]) : []));
    for (const rule of t.rules) {
      if (rec.rules[rule.id].final) continue;
      const src = `/${slash(rule.source)}`;
      const at = reads.filter(([, p]) => p.endsWith(src)).map(([i]) => i);
      // a source Claude Code loads itself (an instruction or rule file) is in context without a Read
      const loaded = (rec.instructionsLoaded ?? []).some((l) => `/${slash(l.file)}`.endsWith(src));
      const kind = !rec.changed?.length ? 'stopped' : at.some((i) => cut < 0 || i < cut) ? 'read before the compaction'
        : at.length ? 'read after it only' : loaded ? 'loaded by Claude Code' : 'never read in the main thread';
      ((out[rule.id] ??= {})[kind] ??= 0);
      out[rule.id][kind]++;
    }
  }
  console.log(t.id, arm, JSON.stringify(out));
}
