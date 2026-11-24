---
name: pricing-check
description: Run the pricing golden check after any change under src/pricing/ - save scripts/golden.js output to reports/pricing-<date>.txt and add a line to PRICING-LOG.md with the date, what changed and how many golden cases changed since the last report. Use whenever src/pricing/ has been edited, or when asked to run the pricing check.
---

# Pricing check

Run from the repo root. `<today>` is today's date as YYYY-MM-DD.

1. **Find the last report**: the newest `reports/pricing-*.txt` dated *before* today
   (filenames sort by date). If today's report already exists from an earlier run, still
   compare against the one before it, so the count covers everything since the last report.

2. **Run the goldens and save the output**:
   ```bash
   node scripts/golden.js > reports/pricing-<today>.txt
   ```
   If the script fails, stop and report the error. Don't write a log line.

3. **Count the golden cases that changed.** Each line is one case, keyed by `case <id>`. A
   case counts as changed if its line differs, or if it was added or removed:
   ```bash
   node -e "const fs=require('fs');const m=f=>new Map(fs.readFileSync(f,'utf8').trim().split(/\r?\n/).map(l=>[l.split(/\s+/)[1],l]));const a=m(process.argv[1]),b=m(process.argv[2]);const ids=new Set([...a.keys(),...b.keys()]);const ch=[...ids].filter(i=>a.get(i)!==b.get(i));console.log(ch.length+' changed: '+ch.join(', '))" reports/pricing-<last>.txt reports/pricing-<today>.txt
   ```
   If there's no earlier report, every case is new.

4. **Describe what changed** in one short clause: the behaviour change, not the file names.
   Take it from the work in this session, or from `git diff` / `git log` on `src/pricing/`.
   If it's unclear, ask the user rather than guessing.

5. **Add a line to the end of `PRICING-LOG.md`**, in the existing style:
   ```
   - <today>: <what changed>; <N> golden cases changed.
   ```
   Use `no golden case changed` for 0 and `1 golden case changed` for 1. If today already
   has a line from an earlier run, update that line instead of adding a second one.

6. **Report** the count and which case ids changed, so the user can check that the changes
   were intended.
