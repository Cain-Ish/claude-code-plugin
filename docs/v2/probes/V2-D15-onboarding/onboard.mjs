// V2-D15: is the blind converter's output (D13 attempt 2, unchanged) faithful, binding and complete enough to build
// on? Entries, sections, Gemini's answers and planted rules stay next to the private config (d15/); only counts come
// back here (results/).
//   node onboard.mjs selftest
//   node onboard.mjs fidelity <config>             every entry's quote against the blocks it cites (no model)
//   node onboard.mjs a1       <config>             converts the A1 fixture's two docs (public)
//   node onboard.mjs sample   <config>             seeded sections; writes the Gemini pastes, pass A and pass B
//   node onboard.mjs plant    <config> <planted>   planted rules as their own blocks, converted again, found or lost
//   node onboard.mjs pm4      <config>             R0's entries as Markdown, one plain text edit, parsed back
//   node onboard.mjs score    <config>             Gemini's saved answers -> results/review.json
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { chunk } from '../V2-D13-selection/select.mjs';
import { convert, parts } from '../V2-D13-selection/convert.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SEED = 'd15-2026-10-21';
const SECTION_MAX = 6 * 1024;
const STRATA = [['pointed', 9], ['unpointed', 6], ['none', 5]];
const A1 = path.join(HERE, '..', 'V2-D17-eval', 'fixture');
const RULE = 'A rule is anything that tells someone working on this project what to do, not do, or stay consistent '
  + 'with: conventions, constraints, decisions, requirements, design or content rules, and facts the work must not '
  + 'contradict. Skip history, narrative and explanation that binds nothing.';

const words = (s) => String(s).toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
const order = (k) => crypto.createHash('sha256').update(SEED + k).digest('hex');

// The cited blocks in source order, each heading path written once, as the converter saw them.
const sourceText = (all, ids) => {
  let last = null;
  return [...ids].sort((a, b) => a - b).map((i) => {
    const h = all[i].heads.join(' › ');
    const t = h !== last ? `${h}\n${all[i].text}` : all[i].text;
    last = h;
    return t;
  }).join('\n');
};

// Every stretch of 3+ words between cut marks occurs as a contiguous word sequence in the cited source.
export function verbatim(quote, source) {
  const hay = ` ${words(source).join(' ')} `;
  const st = quote.split(/…|\.\.\./).map(words).filter((w) => w.length >= 3);
  return { checkable: st.length > 0, ok: st.every((w) => hay.includes(` ${w.join(' ')} `)) };
}

// A section is a file's blocks under one h1/h2 pair; one over the cap is cut at block ends into windows (key #n).
export function sections(all) {
  const m = new Map();
  all.forEach((e, i) => {
    const key = [e.file, ...e.heads.slice(0, 2)].join(' › ');
    if (!m.has(key)) m.set(key, { key, file: e.file, blocks: [] });
    m.get(key).blocks.push(i);
  });
  const size = (i) => Buffer.byteLength(all[i].text);
  return [...m.values()].flatMap((s) => {
    const wins = [[]];
    let used = 0;
    for (const i of s.blocks) {
      if (wins.at(-1).length && used + size(i) > SECTION_MAX) { wins.push([]); used = 0; }
      wins.at(-1).push(i);
      used += size(i);
    }
    return wins.map((b, n) => ({ key: wins.length > 1 ? `${s.key} #${n + 1}` : s.key, file: s.file, blocks: b, bytes: b.reduce((t, i) => t + size(i), 0) }));
  });
}

// Seeded strata; a short stratum passes its remainder to the next, and the last one's to any eligible section.
export function pick(secs, stratumOf) {
  const left = secs.filter((s) => s.bytes <= SECTION_MAX).sort((a, b) => order(a.key).localeCompare(order(b.key)));
  const out = [];
  let carry = 0;
  for (const [name, n] of STRATA) {
    const got = left.filter((s) => stratumOf(s) === name && !out.includes(s)).slice(0, n + carry);
    out.push(...got);
    carry = n + carry - got.length;
  }
  return [...out, ...left.filter((s) => !out.includes(s)).slice(0, carry)];
}

export const render = (file, es) => {
  let out = `# Map entries from ${file}\n`;
  let last = null;
  for (const e of es) {
    const h = e.heads.join(' › ') || '(top)';
    if (h !== last) { out += `\n## ${h}\n`; last = h; }
    out += `\n### ${e.area}\n${e.quote.split('\n').map((l) => `> ${l}`).join('\n')}\n\n- when: ${JSON.stringify(e.when)}\n- blocks: ${e.blocks.join(', ')}\n`;
  }
  return out;
};

export function parseMap(file, text) {
  const out = [];
  let heads = [];
  let cur = null;
  for (const l of text.replace(/\r/g, '').split('\n')) {
    if (l.startsWith('## ')) heads = l.slice(3) === '(top)' ? [] : l.slice(3).split(' › ');
    else if (l.startsWith('### ')) out.push(cur = { file, heads, area: l.slice(4), quote: null, when: [], blocks: [] });
    else if (cur && /^> ?/.test(l)) cur.quote = cur.quote === null ? l.replace(/^> ?/, '') : `${cur.quote}\n${l.replace(/^> ?/, '')}`;
    else if (cur && l.startsWith('- when: ')) cur.when = JSON.parse(l.slice(8));
    else if (cur && l.startsWith('- blocks: ')) cur.blocks = l.slice(10).split(', ').map(Number);
  }
  return out;
}

function load(raw, label) {
  const map = JSON.parse(fs.readFileSync(path.join(raw, 'd13', 'maps', `${label}.json`), 'utf8'));
  const dir = path.join(raw, 'd13', 'entries', label);
  const runs = fs.readdirSync(dir).sort().map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')));
  const entries = runs.flatMap((r) => r.entries.map((x) => ({ ...x, file: r.file, heads: map.all[x.blocks[0]].heads })));
  return { all: map.all, pointedFiles: new Set(map.pointed.map((e) => e.file)), entries };
}

async function convertBlocks(file, blocks, cwd) {
  const res = [];
  for (const [k, part] of parts(blocks).entries()) res.push(await convert({ file, part, k, bytes: part.reduce((s, b) => s + Buffer.byteLength(b.e.text), 0) }, cwd));
  return res;
}

const lastJson = (s) => {
  const t = String(s).trim().replace(/^```(?:json)?\s*|\s*```$/g, '');
  return JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1));
};

const [mode, cfgArg, extra] = process.argv.slice(2);
const cfg = cfgArg ? JSON.parse(fs.readFileSync(cfgArg, 'utf8')) : null;
const RAW = cfgArg ? path.dirname(path.resolve(cfgArg)) : null;
const OUT = RAW ? path.join(RAW, 'd15') : null;
const LABELS = cfg ? [...new Set(cfg.tasks.map((t) => t.id.split('-')[0]))] : [];
const writeResult = (name, obj) => {
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', name), `${JSON.stringify(obj, null, 1)}\n`);
};
if (OUT) fs.mkdirSync(OUT, { recursive: true });

if (mode === 'selftest') {
  const all = [{ file: 'a.md', heads: ['A'], text: 'Use the **shared** helper\nfor every path.' }, { file: 'a.md', heads: ['A'], text: 'Never write to home.' }];
  assert.deepEqual(verbatim('use the shared helper for every path', sourceText(all, [0])), { checkable: true, ok: true });
  assert.equal(verbatim('use the shared helper … never write to home', sourceText(all, [1, 0])).ok, true);
  assert.equal(verbatim('use a shared helper', sourceText(all, [0])).ok, false);
  assert.equal(verbatim('do it', sourceText(all, [0])).checkable, false);
  const secs = sections([...all, { file: 'b.md', heads: ['B', 'C', 'D'], text: 'x' }]);
  assert.deepEqual(secs.map((s) => s.key), ['a.md › A', 'b.md › B › C']);
  assert.equal(pick(secs, () => 'none').length, 2);
  const es = [{ file: 'a.md', heads: ['A', 'B'], area: 'paths', quote: 'line one\nline two', when: ['x', 'y; z'], blocks: [3, 4] },
    { file: 'a.md', heads: [], area: 'top', quote: 'q', when: [], blocks: [0] }];
  assert.deepEqual(parseMap('a.md', render('a.md', es)), es);
  console.log('selftest ok');
} else if (mode === 'fidelity') {
  const res = {};
  for (const label of LABELS) {
    const { all, entries } = load(RAW, label);
    const v = entries.map((e) => verbatim(e.quote, sourceText(all, e.blocks)));
    const ok = v.filter((x) => x.ok).length;
    res[label] = { entries: entries.length, verbatim: ok, share: +(ok / entries.length).toFixed(3), uncheckable: v.filter((x) => !x.checkable).length,
      over300: entries.filter((e) => e.quote.length > 300).length };
    fs.writeFileSync(path.join(OUT, `fidelity-${label}.json`), JSON.stringify(entries.map((e, k) => ({ k, ok: v[k].ok, file: e.file, quote: e.quote })).filter((x) => !x.ok)));
  }
  const pass = Object.values(res).every((r) => r.share >= 0.95);
  writeResult('fidelity.json', { date: new Date().toISOString().slice(0, 10), bar: 0.95, pass, repos: res });
  console.log(JSON.stringify(res), 'pass', pass);
} else if (mode === 'a1') {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'd15-a1-'));
  const all = ['docs/style-guide.md', 'README.md'].flatMap((f) => chunk(f, fs.readFileSync(path.join(A1, f), 'utf8')));
  const byFile = Map.groupBy(all.map((e, i) => ({ i, e })), (b) => b.e.file);
  const runs = [];
  for (const [file, blocks] of byFile) runs.push(...await convertBlocks(file, blocks, cwd));
  fs.writeFileSync(path.join(OUT, 'a1.json'), JSON.stringify({ all, runs }));
  console.log(`A1: ${all.length} blocks, ${runs.reduce((s, r) => s + r.entries.length, 0)} entries, ${runs.reduce((s, r) => s + (r.cost ?? 0), 0).toFixed(2)} USD, failed ${runs.filter((r) => r.error).length}`);
} else if (mode === 'sample') {
  const meta = {};
  for (const label of LABELS) {
    const { all, pointedFiles, entries } = load(RAW, label);
    const secs = sections(all);
    const cites = new Map();
    entries.forEach((e, k) => e.blocks.forEach((b) => { if (!cites.has(b)) cites.set(b, new Set()); cites.get(b).add(k); }));
    const of = (s) => [...new Set(s.blocks.flatMap((b) => [...(cites.get(b) ?? [])]))];
    const stratumOf = (s) => (!of(s).length ? 'none' : pointedFiles.has(s.file) ? 'pointed' : 'unpointed');
    const chosen = pick(secs, stratumOf).map((s) => ({ s, all, entries, ids: of(s), stratum: stratumOf(s) }));
    if (label === 'R0') {
      const a1 = JSON.parse(fs.readFileSync(path.join(OUT, 'a1.json'), 'utf8'));
      const a1Entries = a1.runs.flatMap((r) => r.entries.map((x) => ({ ...x, file: r.file, heads: a1.all[x.blocks[0]].heads })));
      for (const s of sections(a1.all)) chosen.push({ s, all: a1.all, entries: a1Entries, ids: a1Entries.flatMap((e, k) => (e.blocks.some((b) => s.blocks.includes(b)) ? [k] : [])), stratum: 'A1' });
    }
    const seen = new Set();
    let A = `You are reviewing documentation from one software project. Below are ${chosen.length} sections, each with an id like S1. For each section, list every rule in it.\n\n${RULE}\n\nWrite each rule as one short line in your own words, in the order it appears. Reply with only one JSON object and no prose: {"S1": ["...", "..."], "S2": [], ...}. Keep this list: my next message asks about it.\n`;
    let B = `Now the same sections, with the entries an automatic converter wrote from them. Each entry has an id like E1: a quote (the rule in the source's own words, trimmed, cuts marked with …), an area label and applies-when terms.\n\n1. For each entry: "binds": is it a rule by the definition above? "faithful": does the trimmed quote still say what the source says in its context? Answer false if the trimming dropped a condition, an exception or a scope, or changed the meaning. "area": does the area label fit the entry?\n2. For each section, for each rule you listed for it in your previous answer, in the same order: the id of the entry that covers it, or null.\n\nReply with only one JSON object and no prose: {"entries": {"E1": {"binds": true, "faithful": true, "area": true}, ...}, "covered": {"S1": ["E3", null, ...], ...}}\n`;
    const m = { sections: [], entries: {} };
    let eid = 0;
    chosen.forEach(({ s, all: blocks, entries: es, ids, stratum }, k) => {
      const sid = `S${k + 1}`;
      let last = s.key;
      A += `\n=== ${sid}: ${s.key}\n`;
      for (const i of s.blocks) {
        const h = [blocks[i].file, ...blocks[i].heads].join(' › ');
        if (h !== last && blocks[i].heads.length > 2) A += `#### ${blocks[i].heads.slice(2).join(' › ')}\n`;
        last = h;
        A += `${blocks[i].text}\n\n`;
      }
      B += `\n=== ${sid}\n`;
      const mine = [];
      for (const x of ids) {
        const key = `${stratum === 'A1' ? 'A1' : label}:${x}`;
        if (seen.has(key)) continue;
        seen.add(key);
        const id = `E${++eid}`;
        mine.push(id);
        m.entries[id] = { stratum, k: x };
        B += `${id} | area: ${es[x].area} | when: ${es[x].when.join('; ')}\nquote: ${es[x].quote}\n\n`;
      }
      m.sections.push({ sid, stratum, bytes: s.bytes, entries: mine });
    });
    fs.writeFileSync(path.join(OUT, `${label}-A.txt`), A);
    fs.writeFileSync(path.join(OUT, `${label}-B.txt`), B);
    fs.writeFileSync(path.join(OUT, `${label}-meta.json`), JSON.stringify(m));
    const over = secs.filter((s) => s.bytes > SECTION_MAX);
    meta[label] = { sections: secs.length, overCap: over.length, entriesInOverCap: entries.filter((e) => e.blocks.some((b) => over.some((s) => s.blocks.includes(b)))).length,
      sampled: Object.fromEntries(['pointed', 'unpointed', 'none', 'A1'].map((n) => [n, m.sections.filter((x) => x.stratum === n).length])), entriesSampled: eid,
      pasteKb: [Math.round(Buffer.byteLength(A) / 1024), Math.round(Buffer.byteLength(B) / 1024)] };
  }
  writeResult('sample.json', { seed: SEED, sectionMaxBytes: SECTION_MAX, repos: meta });
  console.log(JSON.stringify(meta));
} else if (mode === 'plant') {
  // planted: [{ label, file, rules: [8 strings] }]; each rule becomes its own block after a seeded block
  const planted = JSON.parse(fs.readFileSync(extra, 'utf8'));
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'd15-plant-'));
  const res = {};
  for (const p of planted) {
    const t = cfg.tasks.find((x) => x.id.startsWith(`${p.label}-`));
    const text = spawnSync('git', ['-C', t.repo, 'show', `${t.commit}:${p.file}`], { maxBuffer: 1 << 28 }).stdout.toString('utf8');
    const orig = chunk(p.file, text);
    const after = new Set(orig.map((_, i) => i).sort((a, b) => order(`plant ${p.file} ${a}`).localeCompare(order(`plant ${p.file} ${b}`))).slice(0, p.rules.length));
    const blocks = [];
    const plantedAt = [];
    let r = 0;
    orig.forEach((e, i) => {
      blocks.push(e);
      if (after.has(i)) {
        plantedAt.push(blocks.length);
        blocks.push({ ...e, text: /^([-*+]|\d+[.)])\s/.test(e.text) ? `- ${p.rules[r++]}` : p.rules[r++] });
      }
    });
    const runs = await convertBlocks(p.file, blocks.map((e, i) => ({ i, e })), cwd);
    const cited = new Set(runs.flatMap((x) => x.entries.flatMap((e) => e.blocks)));
    const found = plantedAt.filter((i) => cited.has(i)).length;
    fs.writeFileSync(path.join(OUT, `plant-${p.label}.json`), JSON.stringify({ file: p.file, plantedAt, runs }));
    res[p.label] = { docKb: Math.round(Buffer.byteLength(text) / 1024), planted: plantedAt.length, found, lost: plantedAt.length - found,
      calls: runs.length, failed: runs.filter((x) => x.error).length, costUsd: +runs.reduce((s, x) => s + (x.cost ?? 0), 0).toFixed(2) };
  }
  const pass = Object.values(res).every((x) => x.lost === 0 && !x.failed);
  writeResult('planted.json', { date: new Date().toISOString().slice(0, 10), pass, docs: res });
  console.log(JSON.stringify(res), 'pass', pass);
} else if (mode === 'pm4') {
  const { entries } = load(RAW, 'R0');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'd15-pm4-'));
  const byFile = Map.groupBy(entries, (e) => e.file);
  const name = (f) => path.join(dir, `${f.replace(/[\\/]/g, '__')}.md`);
  for (const [f, es] of byFile) fs.writeFileSync(name(f), render(f, es));
  const back = () => [...byFile.keys()].flatMap((f) => parseMap(f, fs.readFileSync(name(f), 'utf8')));
  const canon = (e) => JSON.stringify([e.file, e.heads, e.area, e.quote, e.when, e.blocks]);
  const same = back().map(canon).join('\n') === [...byFile.values()].flat().map(canon).join('\n');
  // a person's correction: one quote line changed with a plain text edit, no plugin code
  const target = [...byFile.values()].flat().sort((a, b) => order(a.quote).localeCompare(order(b.quote)))[0];
  const file = name(target.file);
  const firstLine = `> ${target.quote.split('\n')[0]}`;
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace(firstLine, `${firstLine} (corrected by hand)`));
  const after = back();
  const before = [...byFile.values()].flat();
  const changed = after.filter((e, i) => canon(e) !== canon(before[i]));
  const pass = same && after.length === before.length && changed.length === 1 && changed[0].quote.includes('(corrected by hand)');
  const kb = Math.round([...byFile.keys()].reduce((s, f) => s + fs.statSync(name(f)).size, 0) / 1024);
  writeResult('pm4.json', { date: new Date().toISOString().slice(0, 10), pass, files: byFile.size, entries: before.length, kb, roundTrip: same, changedAfterEdit: changed.length });
  console.log({ pass, files: byFile.size, entries: before.length, kb, roundTrip: same, changed: changed.length });
} else if (mode === 'score') {
  const res = {};
  for (const label of LABELS) {
    const m = JSON.parse(fs.readFileSync(path.join(OUT, `${label}-meta.json`), 'utf8'));
    const A = lastJson(fs.readFileSync(path.join(OUT, `${label}-A.json`), 'utf8'));
    const B = lastJson(fs.readFileSync(path.join(OUT, `${label}-B.json`), 'utf8'));
    for (const group of label === 'R0' ? ['R0', 'A1'] : [label]) {
      const secs = m.sections.filter((s) => (group === 'A1') === (s.stratum === 'A1'));
      const ids = secs.flatMap((s) => s.entries);
      const v = ids.map((id) => B.entries?.[id]).filter(Boolean);
      const rules = secs.flatMap((s) => (A[s.sid] ?? []).map((_, j) => B.covered?.[s.sid]?.[j] ?? null));
      res[group] = {
        sections: secs.length, entries: ids.length, judged: v.length,
        precision: v.length ? +(v.filter((x) => x.binds && x.faithful).length / v.length).toFixed(2) : null,
        binds: v.filter((x) => x.binds).length, faithful: v.filter((x) => x.faithful).length, areaFits: v.filter((x) => x.area).length,
        rulesListed: rules.length, covered: rules.filter(Boolean).length, recall: rules.length ? +(rules.filter(Boolean).length / rules.length).toFixed(2) : null,
      };
    }
  }
  const pass = ['P1', 'P2', 'R0'].every((l) => res[l].precision >= 0.8 && res[l].recall >= 0.8 && res[l].judged === res[l].entries);
  writeResult('review.json', { date: new Date().toISOString().slice(0, 10), reviewer: 'Gemini Pro (browser)', bars: { precision: 0.8, recall: 0.8 }, pass, groups: res });
  console.log(JSON.stringify(res, null, 1), '\npass', pass);
} else {
  console.error('usage: node onboard.mjs selftest | fidelity|a1|sample|pm4|score <config> | plant <config> <planted>');
  process.exit(2);
}
