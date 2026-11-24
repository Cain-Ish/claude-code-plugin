---
name: pricing-check
description: Run the pricing golden check after any change under src/pricing/ — save node scripts/golden.js output to reports/pricing-<YYYY-MM-DD>.txt and add a line to PRICING-LOG.md with the date, what changed, and how many golden cases changed since the last report. Use whenever a file in src/pricing/ has been edited, or when asked to "do the pricing check".
---

# Pricing check

Run this after any change under `src/pricing/`. Do the steps in order, from the repo root.

1. **Find the previous report.** The newest `reports/pricing-*.txt` by date in the file name,
   excluding today's. Note its path (it may not exist).

2. **Generate today's report.** Use today's date as `YYYY-MM-DD`:
   ```
   node scripts/golden.js > reports/pricing-YYYY-MM-DD.txt
   ```
   If the script fails, stop and report the error. Don't write a log line.
   If today's report already exists, overwrite it (step 1 already picked the earlier report).

3. **Count changed golden cases** against the previous report:
   ```
   node .claude/skills/pricing-check/count-changed.mjs <previous-report> reports/pricing-YYYY-MM-DD.txt
   ```
   It prints the number of cases whose line differs, including added or removed cases.
   If there was no previous report, every case is new.

4. **Describe what changed.** Write one short phrase from the actual diff under `src/pricing/`
   (`git diff -- src/pricing/`, plus staged/committed changes since the previous report if the
   working tree is clean). Describe the behaviour change, not the code edit, e.g. "free orders no
   longer get a discount". If it isn't clear what the change was meant to do, ask the user.

5. **Append a line to `PRICING-LOG.md`**, matching the existing style:
   ```
   - YYYY-MM-DD: <what changed>; <N golden cases changed | 1 golden case changed | no golden case changed | all golden cases new>.
   ```
   If today already has a line, update that line instead of adding a second one.

6. **Report back:** the report path, the count, and the log line. If any cases changed, list
   them (old line → new line) so the user can check that each change was intended.
