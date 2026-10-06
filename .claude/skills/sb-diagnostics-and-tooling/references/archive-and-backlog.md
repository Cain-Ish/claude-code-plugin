# Archive writes, eviction and the scrub migration (0.56.0)

Detail behind SKILL.md section 5. Every number below was read from `scripts/lib.sh`,
`scripts/extract-drain.sh` and `mcp/src/` at the 0.56.0 tree; re-verify with the greps in the last
section.

## Secret scrub (`sb_scrub_secrets`, `lib.sh`)

A stdin-to-stdout filter. Zero-width characters (U+200B-200D, U+2060, U+FEFF) are deleted first,
then each match becomes `[redacted:<kind>]`. Line count never changes (the archive cursors count
lines). Redacted kinds:

- `private-key`: PEM and PGP `...PRIVATE KEY...-----` blocks, per line. The BEGIN line keeps its
  prefix (a `USER:` line stays one), body and END lines become a marker. A quote or comment prefix
  (`> `, `# `, `// `, ` * `) is kept, so quoted subagent results are covered. A line that does not
  look like key material ends the block.
- `anthropic` (`sk-ant-`), `openrouter` (`sk-or-v1-`), `openai` (`sk-proj-`, `sk-svcacct-`,
  `sk-admin-`, and plain `sk-` + 20 alphanumerics with a left boundary, so `task-`/`disk-` ids
  survive), `stripe` (`sk_live_`, `rk_live_`)
- `github` (`github_pat_`, `gh[opsur]_`), `gitlab` (`glpat-`), `npm` (`npm_`), `huggingface`
  (`hf_`), `google` (`AIza`), `slack` (`xox[abpr]-`, `xapp-`)
- `aws`: `AKIA`/`ASIA` access key ids; a secret access key only after its `aws_secret_access_key`
  keyword (keyword stays, value goes)
- `jwt` (`eyJ.eyJ.` three-part), `bearer` (any case), `basic-auth` (`Authorization: Basic <base64>`,
  keyword-gated, any case)

NOT matched, by design: OTP-like short codes, passwords in prose, generic hex/base64/high-entropy
blobs with no known prefix, a bare 40-character AWS secret without its keyword, `Basic` without
`Authorization`, runs below each format's minimum length.

Where it runs: every archived window (`sb_preprocess_transcript`); subagent results, before they
are quoted into `sub-*` (a repeat stop for the same agent appends a block); the observations
ledger, at write time (`observe-tool-use.sh`, a failed scrub drops the observation, logged) and
again before the ledger slice is sent to the extractor; the transcript copies `dream-snapshot.sh`
stages (fail closed: a copy that cannot be scrubbed is left out of the dream); and every
extraction: the drainer greps an archive for credential literals right before extracting it and
scrubs it in place first, which covers archives appended by still-running 0.55 hooks.

## `sb status` and the health snapshot

`mcp/src/cli/sb.ts` runs `sb_drain_cursor_map` through bash (`drainCursorMap`, SIGKILL-bounded,
never throws) and prints `transcript backlog:  N of M archived (K dead-lettered)`: N = rows in state
`pending`, M = all archives, K = rows in state `dead` (omitted when 0). When some archive carries a
dead-lettered window (map column 8 `dead_windows` > 0, whatever its state, even mid-archive) the
row ends in `; dead windows: W in A archives, L lines` (W, L = sums of columns 8 and 9). A map that
cannot be read prints `unknown (drain cursor map unavailable: <reason>)`; no `transcripts/` dir
prints `no transcripts dir`. `last extraction:` is only the newest `ts` in the done-set.

The `archive scrub:` row has four states: `done` (marker `.archive-scrub-v1` exists);
`N to scrub (K with failed attempts >= 3)` (from the to-do list); `no to-do list yet (no ...todo,
no ...marker)`; `unknown (cannot read ...)`.

Same facts, other wording. `sb-health-snapshot.sh` prints `backlog: P pending of T archived
transcripts (... dead-lettered=D)`, `dead-lettered windows: W (L lines) in A archive(s)`, and
`archive scrub:` as `done (.archive-scrub-v1)`, `N file(s) still to scrub (K failed 3+ attempts;
their archives are not extracted until scrubbed)`, or `not started (the drainer's first tick lists
the archives to scrub)`. The SessionStart drain-health banner counts archives holding dead windows
(threshold `SB_DRAIN_DEADLETTER_THRESHOLD`) and names the window and line totals; it also fires
when an archive's scrub failed 3+ times. The reconcile tick row carries
`dead_archives= dead_windows= dead_lines=`.

A window that failed `SB_DRAIN_MAX_FAILS` times is dead-lettered. It is counted as dead wherever
it sits, including under a cursor that a later window advanced past.

## Per-archive lock

`transcripts/.<archive>.lock` (so `.<sid>_<slug>_<date>.txt.lock`) is created with a noclobber
redirect and holds the owner token `<pid>.<nonce>`. `sb_archive_transcript` (Stop/PreCompact append),
`sb_archive_subagent_result` and the in-place scrub (`sb_scrub_archive_file`) take it through
`sb_archive_lock`; release (`sb_archive_unlock`) removes it only while it still holds our token.
`sb_archive_raw_window` also locks its raw-line cursor, a pseudo archive named
`transcripts/cursor-<key>.txt`, so its file is `transcripts/.cursor-<key>.txt.lock`. That lock is
taken before the archive lock, never inside it.

| Constant | Value | Effect |
|---|---|---|
| `_SB_ARCHIVE_LOCK_WAIT_S` | 5 | contended: poll every 0.1 s, then log and return 1 |
| `_SB_ARCHIVE_LOCK_STALE_S` | 60 | older than this AND the holder pid is gone: stolen (logged) |
| `_SB_ARCHIVE_LOCK_HUNG_S` | 600 | older than this: stolen whatever the pid says |

A steal renames the lock and verifies it took the token it judged stale; a fresh lock that replaced
it is put back. A failed append does not advance the cursor, so the next hook retries it; a failed
scrub stays on the to-do list. The drainer sweeps `.*.txt.lock` and `.*.txt.evicted` older than a
day. Sessions still running 0.55 code do not take the lock; the scrub re-checks the file size right
before its rename and leaves the file for a retry when it grew.

## Eviction (`sb_prune_transcripts`)

- Cheap gate first: file count from a glob, bytes from one `wc -c`. Under every cap it returns and
  never touches the cursor map.
- Over a cap it classifies archives with one `sb_drain_cursor_map`. States `done` and `dead` are
  evictable, oldest mtime first, down to the soft caps (400 files / 25 MB). Only `pending` is
  protected, and only up to the hard ceilings (1200 files / 75 MB); past them pending archives are
  evicted too and each is named in the error log ("evicting N UN-EXTRACTED archive(s)").
- The `sub-*` sub-cap (`SB_SUBAGENT_ARCHIVE_CAP`, 200) follows the same rule: extracted subagent
  archives go first; pending ones only past 3x the cap, logged in that same row.
- Map unavailable (empty output while archives exist): logged, every archive is treated as
  `pending`, so only the hard ceilings evict.
- Each victim is locked (tried, never waited on: a held lock skips it this round), its line count
  re-checked under the lock (changed = it grew: kept), and a tombstone `.<archive>.evicted` is
  written before the `rm` (no tombstone, no removal). The tombstone makes the cursor map ignore
  done-set rows written before it, so a basename the same session re-creates the same day does
  not inherit the old cursor. The drainer's compaction consumes tombstones; older than a day they
  are swept.
- An evicted archive that held dead-lettered windows is logged (windows and lines lost).

## One-time scrub migration (`drain_scrub_migrate`, `extract-drain.sh`)

Called from `sb_drain_migrate`, under the drain lock, before the defer gate; makes no LLM call.

1. First tick: one `grep -lF` (`_SB_SCRUB_LITERALS`, `lib.sh`) over every archive and every dream
   copy lists the files holding a credential literal into `.archive-scrub-v1.todo`, one
   `<path relative to BRAIN_DIR>\t<failed attempts>` line each (`transcripts/<name>.txt` or
   `dreams/<id>/transcripts/<name>.txt`).
2. Each tick scrubs at most `SB_DRAIN_BATCH` (5): fewest failed attempts first (a scrub that keeps
   failing rotates to the back), then archives with lines still to extract. A scrubbed or vanished
   entry leaves the list; a failed one gets its attempt count bumped. A file with nothing the scrub
   would change (a `task-`/`disk-` id matches the `sk-` prefilter) is a no-op and leaves the list.
3. While an archive is on the list the batch loop skips it (`DRAIN_SCRUB_TODO`). A list that cannot
   be read is rebuilt (attempt counts restart).
4. The episodic index drops and skips archives on the list (0.55 already indexed their text), so
   recall of those sessions pauses until the scrub reaches them. Rows whose text did not change
   come back from the embedding cache with no model call.
5. When the list is empty `.archive-scrub-v1` is written and the migration never runs again.

Each tick writes a `drain-tick` row with verdict `archive-scrub` to `audit-log.jsonl`: `N file(s)
still to scrub (K failed 3+ attempts); those archives are not extracted until then`, then `done:
every archive and dream copy written before 0.56.0 is secret-scrubbed`.

## Ledger compaction and reconcile stats

`sb_compact_done_set` runs every tick under the drain lock. It drops rows of vanished archives,
rows older than an eviction tombstone, and unparseable rows, and keeps per archive only the rows the
cursor map reads: the cursor row, the highest-line row, every dead-letter (`error`) row (also those
under the cursor) with the `ok` rows overlapping them, the trailing `retry` run plus the row before
it, and the last `ok`/`error` row. The map before and after is identical (lossless).

## Observation ledger markers

`observations/<sid>.jsonl` is the tool ledger. `observations/<sid>.sent` holds how many of its lines
the extractor already got: each extraction sends only the lines after it (scrubbed again first), a
failed call sends them again, a ledger shorter than the marker is sent whole. Both age out after
7 days.

## Re-verify

```bash
grep -n 'sb_archive_lock()\|_SB_ARCHIVE_LOCK_\(WAIT\|STALE\|HUNG\)_S=\|^sb_prune_transcripts\|^sb_compact_done_set\|_SB_SCRUB_LITERALS=' scripts/lib.sh
grep -n 'drain_scrub_migrate\|SCRUB_MARK=\|txt.lock\|txt.evicted' scripts/extract-drain.sh
grep -n 'scrubPendingArchives\|SCRUB_TODO' mcp/src/tools/episodic-search.ts mcp/src/cli/sb.ts
```
