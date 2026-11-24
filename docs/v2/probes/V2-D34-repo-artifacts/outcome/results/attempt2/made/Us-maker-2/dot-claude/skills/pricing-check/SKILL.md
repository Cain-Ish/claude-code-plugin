---
name: pricing-check
description: Run this repo's pricing check after any change under src/pricing/ — runs scripts/golden.js, saves reports/pricing-<YYYY-MM-DD>.txt, and adds a line to PRICING-LOG.md with the date, what changed, and how many golden cases changed since the last report. Use whenever src/pricing/ has been edited, or when asked for the pricing check / golden report.
---

# Pricing check

Run from the repo root. `<date>` is today's date as YYYY-MM-DD.

1. **Find the previous report** — the newest `reports/pricing-*.txt` that is not today's
   (file names sort by date). Note its path; it may not exist.

2. **Run the golden cases and save the report:**
   ```
   node scripts/golden.js > reports/pricing-<date>.txt
   ```
   If the command fails, stop and report the error. Do not write a log line.

3. **Count changed golden cases** against the previous report:
   ```
   node .claude/skills/pricing-check/count-changed.js <previous-report> reports/pricing-<date>.txt
   ```
   It prints one number: cases whose line differs, plus cases added or removed.
   If there is no previous report, every case is new.

4. **Say what changed** in one short clause, from `git diff` (and staged/committed changes)
   under `src/pricing/` plus what the user said in this session. If it isn't clear, ask the user.

5. **Append a line to `PRICING-LOG.md`**, matching the existing entries:
   ```
   - <date>: <what changed>; <N> golden case(s) changed.
   ```
   Use `no golden case changed` when N is 0, and `all golden cases new` when there was no
   previous report. If today already has a line, update that line instead of adding a second.

6. Report the file written, the count, and the log line. Don't commit unless asked.
