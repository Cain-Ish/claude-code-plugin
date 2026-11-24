---
name: pricing-check
description: Run the pricing golden check after any change under src/pricing/. Saves the golden output to reports/pricing-<YYYY-MM-DD>.txt and adds a line to PRICING-LOG.md with the date, what changed, and how many golden cases changed since the last report. Use whenever a file in src/pricing/ was edited, or when asked for the pricing check.
---

# Pricing check

Run this after any change under `src/pricing/`.

1. From the repo root run:

   ```
   node scripts/pricing-check.js
   ```

   It runs `node scripts/golden.js`, writes the output to `reports/pricing-<today>.txt`, and prints
   `changed: N`, the number of golden cases that differ from the most recent earlier report (added
   or removed cases count as changed). If it fails, stop and report the error. Don't write a log line.

2. Work out what changed under `src/pricing/` (`git diff HEAD -- src/pricing/`, plus untracked files
   there). Summarise it in one short clause, in the style of the existing log lines.

3. Append one line to the end of `PRICING-LOG.md` in the existing format:

   ```
   - <YYYY-MM-DD>: <what changed>; <count> golden case(s) changed.
   ```

   Write `no golden case changed` for 0, `1 golden case changed`, or `N golden cases changed`.
   If there was no previous report, write `all golden cases new`.
   If today already has a log line (the check was re-run the same day), update that line rather
   than adding a second one.

4. Tell the user the report path, the count, and the log line you wrote.
