// read-only: counts Skill and Agent calls and failed tool calls per project folder; prints counts only
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import readline from 'node:readline';
const root = path.join(os.homedir(), '.claude', 'projects');
const want = process.argv.slice(2);
for (const [label, dir] of want.map((w, i) => [`repo ${String.fromCharCode(65 + i)}`, w])) {
  const d = path.join(root, dir); if (!fs.existsSync(d)) { console.log(label, 'missing'); continue; }
  const files = fs.readdirSync(d).filter((f) => f.endsWith('.jsonl'));
  const skills = new Map(), agents = new Map(), fails = new Map(); let sessions = 0, withSkill = 0, withAgent = 0, failTotal = 0, toolTotal = 0, first = null, last = null;
  for (const f of files) {
    const names = new Map(); const sk = new Set(), ag = new Set(), fl = new Set(); let any = false;
    const rl = readline.createInterface({ input: fs.createReadStream(path.join(d, f), 'utf8'), crlfDelay: Infinity });
    for await (const l of rl) { let r; try { r = JSON.parse(l); } catch { continue; } if (r.isSidechain) continue;
      if (r.timestamp) { first = !first || r.timestamp < first ? r.timestamp : first; last = !last || r.timestamp > last ? r.timestamp : last; }
      const c = r.message?.content; if (!Array.isArray(c)) continue;
      for (const x of c) {
        if (x?.type === 'tool_use') { any = true; toolTotal++; names.set(x.id, x.name);
          if (x.name === 'Skill') sk.add(String(x.input?.skill ?? x.input?.command ?? '?'));
          if (x.name === 'Agent' || x.name === 'Task') ag.add(String(x.input?.subagent_type ?? 'general'));
        }
        if (x?.type === 'tool_result' && x.is_error) { failTotal++; const t = names.get(x.tool_use_id) ?? '?'; const txt = (typeof x.content === 'string' ? x.content : JSON.stringify(x.content ?? '')).replace(/\s+/g, ' ');
          const kind = /denied|rejected|permission/i.test(txt) ? 'denied' : /not found|no such|ENOENT|does not exist/i.test(txt) ? 'not-found' : /modified since|has been modified|read it first|must read/i.test(txt) ? 'stale-edit' : /timed? ?out/i.test(txt) ? 'timeout' : /exit code [1-9]|Exit code [1-9]/.test(txt) ? 'nonzero-exit' : 'other';
          fl.add(`${t}:${kind}`); }
      }
    }
    if (!any) continue; sessions++; if (sk.size) withSkill++; if (ag.size) withAgent++;
    for (const s of sk) skills.set(s, (skills.get(s) ?? 0) + 1); for (const a of ag) agents.set(a, (agents.get(a) ?? 0) + 1); for (const k of fl) fails.set(k, (fails.get(k) ?? 0) + 1);
  }
  const top = (m, n) => [...m].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, v]) => `${k}=${v}`).join(', ');
  console.log(`${label}: ${sessions} sessions with tool use (${first?.slice(0,10)}..${last?.slice(0,10)}), ${toolTotal} tool calls, ${failTotal} failed`);
  console.log(`  sessions using a skill: ${withSkill}; skills (sessions): ${top(skills, 12)}`);
  console.log(`  sessions using an agent: ${withAgent}; agents (sessions): ${top(agents, 12)}`);
  console.log(`  failure kinds in 2+ sessions: ${top(new Map([...fails].filter(([, v]) => v >= 2)), 12)}`);
}
