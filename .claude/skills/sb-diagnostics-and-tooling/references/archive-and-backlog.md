# Archive writes, eviction and the scrub migration (0.56.0)

Detail behind SKILL.md section 5. Every number below was read from `scripts/lib.sh` and
`scripts/extract-drain.sh` at the 0.56.0 tree; re-verify with the greps in the last section.

## `sb status` backlog row

`mcp/src/cli/sb.ts` runs `sb_drain_cursor_map` through bash (`drainCursorMap`, SIGKILL-bounded,
never throws) and prints `transcript backlog:  N of M archived (K dead-lettered)`: N = rows in state
`pending`, M = all archives, K = rows in state `dead` (omitted when 0). When some archive carries a
dead-lettered window (map column 8 `dead_windows` > 0, whatever its state) the row ends in
`; dead windows: W in A archives, L lines` (W, L = sums of columns 8 and 9). If the map cannot be
read it prints `unknown (drain cursor map unavailable: <reason>)`; with no `transcripts/` dir, `no
transcripts dir`. The `last extraction:` row beside it is only the newest `ts` in
`.extraction-state.jsonl`. So `sb status` and the SessionStart banners now agree: both read the one
cursor map. The `archive scrub:` row below it reads `done` (marker `.archive-scrub-v1`), else
`N to scrub (K with failed attempts >= 3)` from `.archive-scrub-v1.todo`, `no to-do list yet (...)`
when neither file exists, or `unknown (cannot read ...)`.

## Per-archive lock

`transcripts/.<archive>.lock` (so `.<sid>_<slug>_<date>.txt.lock`) is created with a noclobber
redirect and holds the owner pid. Both the Stop/PreCompact append (`sb_archive_transcript`) and the
in-place scrub (`sb_scrub_archive_file`) take it (`sb_archive_lock`, `lib.sh:1624`).

| Constant | Value | Effect |
|---|---|---|
| `_SB_ARCHIVE_LOCK_WAIT_S` | 5 | contended: poll every 0.1 s, then log and return 1 |
| `_SB_ARCHIVE_LOCK_STALE_S` | 60 | a lock older than this is stolen (logged); checked on first contention, then about once a second |

A failed append does not advance the `.last-archived-line` cursor, so the next hook retries it; a
failed scrub stays in `.archive-scrub-v1.todo`. The drainer sweeps `transcripts/.*.txt.lock` older
than a day (`extract-drain.sh:557`), for an archive nobody writes again after a crash. Sessions
still running 0.55 code do not take the lock; the scrub re-checks the file size right before its
rename and leaves the file for a retry when it grew.

## Eviction (`sb_prune_transcripts`, `lib.sh:2247`)

- Cheap gate first: file count from a glob, bytes from one `wc -c`. Under every cap it returns and
  never touches the cursor map.
- Over a cap it classifies archives with one `sb_drain_cursor_map`. States `done` and `dead` are
  evictable, oldest mtime first, down to the soft caps (400 files / 25 MB). Only `pending` is
  protected, and only up to the hard ceilings (1200 files / 75 MB), past which pending archives are
  evicted too and each is named in the error log ("evicting N UN-EXTRACTED archive(s)").
- Map unavailable (empty output while archives exist): logged, every archive is treated as
  `pending`, so only the hard ceilings evict.
- Subagent `sub-*` archives have their own cap (`SB_SUBAGENT_ARCHIVE_CAP`, 200).

## One-time scrub migration (`drain_scrub_migrate`, `extract-drain.sh:311`)

Called from `sb_drain_migrate`, under the drain lock, before the defer gate; makes no LLM call.

1. First tick: one grep (`_SB_SCRUB_LITERALS`, `lib.sh:1749`) lists the archives holding a
   credential literal into `.archive-scrub-v1.todo`.
2. Each tick scrubs at most `SB_DRAIN_BATCH` (5) of them in place (`sb_scrub_archive_file`: atomic
   rename, mtime and line count preserved, files with nothing to redact are not rewritten), pending
   archives first. Scrubbed and vanished names leave the list; a failed one stays listed.
3. While an archive is on the list the batch loop skips it (`DRAIN_SCRUB_TODO`), and if the list
   cannot be read or built nothing is extracted that tick (`DRAIN_SCRUB_HOLD`).
4. When the list is empty `.archive-scrub-v1` is written and the migration never runs again.

Each tick writes a `drain-tick` row with verdict `archive-scrub` to `audit-log.jsonl`:
`N archive(s) still to scrub; they are not extracted until then`, then `done: every archive written
before 0.56.0 is secret-scrubbed`.

## Ledger compaction and reconcile stats

`sb_compact_done_set` (`lib.sh:3251`) runs every tick under the drain lock. It drops rows of
vanished archives and unparseable rows and keeps, per archive, only the rows the cursor map reads:
the row holding the cursor, the row holding the highest line count, the dead-letter (`error`) rows
past the cursor, the trailing `retry` run plus the row before it, and the last `ok`/`error` row.
The cursor map before and after is identical (lossless). The reconcile tick reads latency from the
ledger after this compaction, so it sees about one `ok` row per archive instead of every window.

## Re-verify

```bash
grep -n 'sb_archive_lock()\|_SB_ARCHIVE_LOCK_\(WAIT\|STALE\)_S=\|^sb_prune_transcripts\|^sb_compact_done_set\|_SB_SCRUB_LITERALS=' scripts/lib.sh
grep -n 'drain_scrub_migrate\|SCRUB_MARK=\|txt.lock' scripts/extract-drain.sh
```
