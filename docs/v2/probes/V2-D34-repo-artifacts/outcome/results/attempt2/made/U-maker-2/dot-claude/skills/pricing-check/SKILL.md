---
name: pricing-check
description: Run the pricing golden check after any change under src/pricing/. Saves node scripts/golden.js output to reports/pricing-<YYYY-MM-DD>.txt and appends a line to PRICING-LOG.md with the date, what changed, and how many golden cases changed since the last report. Use whenever a file in src/pricing/ was edited, or when asked for the pricing check.
---

# Pricing check

Run from the repo root, after the src/pricing/ change is made.

1. **Find the previous report.** List `reports/pricing-*.txt` and take the newest one dated
   *before* today (filenames sort by date). If none exists, every case counts as new.

2. **Generate today's report.**
   ```
   node scripts/golden.js > reports/pricing-<YYYY-MM-DD>.txt
   ```
   Use today's date. If the script fails, stop and report the error; don't write a report or log line.

3. **Count changed golden cases.** Match lines between the previous and new report by case id
   (`case <N>` at the start of each line). A case counts as changed if its line differs, or if
   it was added or removed. Print the changed cases (old line vs new line) so the user can see them.

4. **Describe what changed.** Read `git diff` (plus untracked files) for `src/pricing/` and
   summarise the behaviour change in one short clause, written like the existing log entries.

5. **Append to PRICING-LOG.md**, matching the existing style:
   ```
   - <YYYY-MM-DD>: <what changed>; <N> golden case(s) changed.
   ```
   Write "no golden case changed" when N is 0, and "all golden cases new" when there was no previous report.

6. **Report back** with the report path, the log line, and the changed cases. If any case changed
   that the change wasn't meant to affect, say so plainly.
