---
name: pricing-check
description: Run the pricing golden check and log it. Use after ANY change under src/pricing/ (before reporting the work as done), or when asked to "run the pricing check". Runs scripts/golden.js, saves reports/pricing-<YYYY-MM-DD>.txt, and appends a line to PRICING-LOG.md with the date, what changed, and how many golden cases changed since the last report.
---

# Pricing check

Run this after every change under `src/pricing/`. All paths are relative to the repo root.

## 1. Find the previous report

The previous report is the newest `reports/pricing-*.txt` whose date is **before today**
(names sort by date). Note its path. If today's report already exists (a second check today),
it gets overwritten; still compare against the newest report before today.

## 2. Run golden and save today's report

```bash
node scripts/golden.js > reports/pricing-$(date +%F).txt
```

If the script fails (non-zero exit or error output), stop and report the error. Do not write
the report or the log line.

## 3. Count changed golden cases

A case counts as changed if its line differs from the previous report, or if it was added or
removed. Lines are keyed by case id (`case <id> ...`). Use:

```bash
node -e "
const fs=require('fs');
const read=f=>new Map(fs.readFileSync(f,'utf8').split(/\r?\n/).filter(Boolean).map(l=>[l.split(/\s+/)[1],l.trim()]));
const [a,b]=[read(process.argv[1]),read(process.argv[2])];
const ids=new Set([...a.keys(),...b.keys()]);
const changed=[...ids].filter(id=>a.get(id)!==b.get(id));
console.log(changed.length+' changed'+(changed.length?': cases '+changed.join(', '):''));
" reports/pricing-<previous-date>.txt reports/pricing-<today>.txt
```

If there is no previous report, every case is new: say "all golden cases new".

## 4. Append to PRICING-LOG.md

Append one line, matching the existing style:

```
- <YYYY-MM-DD>: <what changed in src/pricing/, one short clause>; <N golden cases changed | no golden case changed | all golden cases new>.
```

Describe what changed from the actual diff (`git diff -- src/pricing/` plus any staged changes),
in plain words about behaviour (e.g. "free orders no longer get a discount"), not file names.
If a line for today already exists from an earlier check, replace it rather than adding a second.

## 5. Report back

Tell the user the report path, the count, which case ids changed, and the log line. If cases
changed that the change was not meant to affect, say so plainly.
