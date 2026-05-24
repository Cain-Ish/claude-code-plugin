# Out-of-Band Extraction Drainer — Design Spec

**Date:** 2026-05-24
**Status:** Draft for review
**Author:** second-brain — extraction resilience pass
**Scope:** Make session→wiki extraction actually happen for subscription (OAuth) users, by running the extractor **outside** any Claude Code session on a systemd user timer. Single plugin, bash + systemd user units. No API key, no stored credential.

---

## 1. Goal & background

In-session Stop/PreCompact extraction is **structurally impossible** on OAuth: spawning `claude -p` from inside an active session (`CLAUDECODE=1`) re-enters the OAuth-locked process and hangs (`lib.sh:562-581`). Today the in-session path writes `health=queued` and returns — but **"queued" is cosmetic: there is no queue and no drainer**, so the per-session LLM extraction is simply skipped. Transcripts are still archived to `~/.second-brain/transcripts/*.txt` (archival is independent of extraction), so the data isn't lost — but it's never turned into wiki learnings except via dreams.

`claude -p` (non-bare) reads OAuth creds and works fine **outside** a session — there is no recursive lock there. This feature adds a drainer that processes archived-but-unextracted transcripts out-of-band, on the user's subscription (no per-token API cost, no `ANTHROPIC_API_KEY` to store — aligns with the P0 credential threat model and offline-first posture).

Decision (user, 2026-05-24): **backfill the existing backlog gradually + keep up with new transcripts**, rate-limited per run.

## 2. Constraints / findings

- **Must run outside a session.** The drainer refuses to run when `CLAUDECODE=1`.
- **No per-transcript extraction state exists today.** This feature introduces it.
- **pty / PrivateDevices gotcha** ([[pty-openpty-privatedevices-quirk]]): the systemd unit must NOT enable `PrivateDevices=` or aggressive sandboxing — it breaks `claude`'s pty allocation. Unit stays minimal.
- **Headless Pi:** a systemd *user* timer only runs while the user has a session unless `loginctl enable-linger <user>` is set. Install must enable linger.
- **Dream overlap:** the most-recently accepted dream already mined these 28 transcripts. Backfill will re-extract them; overlap is mitigated by the existing quality-gate + `merge-project-update.sh` dedup, and by gradual draining (user can eyeball the first run).
- **Security posture:** installing systemd units + enabling linger are system-state changes. Install is reviewable and explicit (`sb extract install-timer` prints first, writes only on `--apply`). No auto-install, no curl|bash.

## 3. State — the done-set

- **File:** `~/.second-brain/.extraction-state.jsonl`, append-only, one JSON line per attempt: `{"basename": "<file>.txt", "ts": "<iso>", "outcome": "ok|error|retry", "fails": N}`. `ok` and `error` are **terminal**; `retry` is a non-terminal failed attempt that will be retried.
- **"Needs extraction":** a file in `~/.second-brain/transcripts/*.txt` whose basename has **no terminal** (`ok`/`error`) line in the done-set.
- **Ordering:** oldest-first by mtime, so the backlog drains chronologically.
- **Poison-pill guard:** `sb_extraction_fails` returns the count of prior `retry` lines for the basename; after `SB_DRAIN_MAX_FAILS` (default 3) the drainer writes a terminal `outcome:"error"` line so a malformed transcript can't wedge the queue.

Rationale for a single JSONL over per-file sidecars: greppable, one fsync target, matches the existing `error-log.jsonl` / `.rejected-extractions.jsonl` convention.

## 4. The drainer — `scripts/extract-drain.sh`

```
set -u; source lib.sh

# 1. Refuse to run inside a session (recursive-claude lock).
[ "${CLAUDECODE:-}" = "1" ] && { echo "extract-drain: refusing to run inside a Claude session" >&2; exit 0; }

# 2. Single-flight lock.
exec 9>"$BRAIN_DIR/.extract-drain.lock"
flock -n 9 || exit 0

BATCH="${SB_DRAIN_BATCH:-5}"
MAX_FAILS="${SB_DRAIN_MAX_FAILS:-3}"
TX_DIR="$BRAIN_DIR/transcripts"
STATE="$BRAIN_DIR/.extraction-state.jsonl"
[ -d "$TX_DIR" ] || exit 0

processed=0
# oldest-first
for tf in $(ls -1tr "$TX_DIR"/*.txt 2>/dev/null); do
  [ "$processed" -ge "$BATCH" ] && break
  base=$(basename "$tf")
  # skip if terminal (ok or error) in done-set
  sb_extraction_done "$base" "$STATE" && continue
  slug=$(sb_slug_from_archived_transcript "$tf")   # read project_slug: from meta header
  if sb_extract_transcript "$tf" "$slug"; then    # shared core: extractor → merge
    printf '{"basename":%s,"ts":"%s","outcome":"ok"}\n' "$(jq -Rn --arg b "$base" '$b')" "$(date -u +%FT%TZ)" >> "$STATE"
    processed=$((processed+1))
  else
    fails=$(sb_extraction_fails "$base" "$STATE")
    fails=$((fails+1))
    if [ "$fails" -ge "$MAX_FAILS" ]; then
      printf '{"basename":%s,"ts":"%s","outcome":"error","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(date -u +%FT%TZ)" "$fails" >> "$STATE"
    else
      printf '{"basename":%s,"ts":"%s","outcome":"retry","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(date -u +%FT%TZ)" "$fails" >> "$STATE"
    fi
  fi
done

sb_write_extractor_health "cli-oauth" "ok" "drained $processed this run"
exit 0
```

- `ls -1tr` (oldest-first) on `drm`-free `*.txt`; the unquoted `$(ls ...)` is acceptable because archived transcript names are controlled (`<uuid>_<slug>_<date>.txt`, no spaces) — matches the existing `dream-snapshot.sh:83` pattern.
- Always exits 0 (fail-soft); per-transcript failure is recorded, not fatal.

## 5. Shared extraction core (DRY)

The archived `.txt` (written by `sb_archive_transcript`) has a meta header then the preprocessed body:
```
--- session-meta ---
session_id: <id>
project_slug: <slug>
date: <date>
tool_count: <n>
line_count: <n>
---

<preprocessed transcript body>
```

New helpers in `lib.sh`:

- `sb_slug_from_archived_transcript <txt_file>` — read `project_slug:` from the meta header (robust vs. filename parsing, which breaks if a slug ever contains `_`).
- `sb_extract_transcript <txt_file> <slug>` — build the extractor input (`=== PROJECT.md === … === TRANSCRIPT (preprocessed) ===` + the body after the meta header), call `sb_call_extractor` with `extract-prompt.txt` + `SB_EXTRACTOR_MODEL`, run the result through `extraction-quality-gate.sh`, pipe the gated delta to `merge-project-update.sh --project-md … --knowledge-dir …`, and route `persona_signals` through `merge-persona-signals.sh` (mirroring `stop-extract.sh:200-227`). Auto-scaffolds `PROJECT.md` if missing (same template as `stop-extract.sh:65-86`). Returns 0 on a successful merge.
- `sb_extraction_done <base> <state_file>` — true if a terminal (`ok`/`error`) line exists.
- `sb_extraction_fails <base> <state_file>` — count of prior `retry` lines for the basename (0 if none).

**Decision (deviation from earlier draft):** `stop-extract.sh` is **left untouched** — the user flagged risk to the working Stop path, and `stop-extract.sh` operates on raw JSONL with line-windowing/markers (a different input shape) so it can't cleanly share the whole helper anyway. The shared boundary is the "build input → extractor → gate → merge → persona" tail, encapsulated in `sb_extract_transcript` and used only by the drainer for now. `stop-extract.sh` adopting it later is out of scope.

## 6. Scheduling — systemd user timer

Ship templates in the repo under `systemd/`:

`systemd/sb-extract-drain.service`:
```ini
[Unit]
Description=second-brain out-of-band extraction drainer
After=default.target

[Service]
Type=oneshot
# NOTE: do NOT add PrivateDevices / ProtectSystem sandboxing — breaks claude's pty.
ExecStart=%h/.claude/plugins/.../scripts/extract-drain.sh
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
```
`systemd/sb-extract-drain.timer`:
```ini
[Unit]
Description=run second-brain extraction drainer periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
```

- Cadence default **30 min** (`OnUnitActiveSec`). `Persistent=true` catches up a missed run after downtime.
- `ExecStart` path is resolved at install time (the plugin cache path is version-stamped, so the installer renders the actual absolute path — see §7).

## 7. Install — reviewable bash script

`bin/sb` is a thin wrapper that `exec node`s a bundled TypeScript CLI, so adding an `sb extract` subcommand would mean editing TS source + rebuilding the vitest-tested bundle — unnecessary, since the drainer must be bash anyway (it calls `sb_call_extractor`/`merge`). Instead:

- **`scripts/extract-drain.sh`** — the drainer (called directly by the systemd `ExecStart`, and runnable by hand for a smoke test).
- **`scripts/install-extract-timer.sh [--apply] [--uninstall]`** — reviewable installer:
  - no flag: **print** the rendered `.service` + `.timer` (with the absolute `ExecStart` path resolved) and the exact commands, touching nothing.
  - `--apply`: write the units to `~/.config/systemd/user/`, `systemctl --user daemon-reload`, `systemctl --user enable --now sb-extract-drain.timer`. It then **prints** the `loginctl enable-linger "$USER"` command for the user to run themselves (linger is a host-state change surfaced explicitly, not run silently — per the user's preference).
  - `--uninstall`: `systemctl --user disable --now` + remove the unit files (clean reversal).
- A TS `sb extract status` subcommand is **out of scope** (would touch the bundle); `systemctl --user status sb-extract-drain.timer` + `cat ~/.second-brain/.extractor-health.json` cover it.

## 8. Error handling

- Drainer always exits 0; failures recorded in the done-set + `error-log.jsonl`.
- No auth / extractor returns empty → per-transcript retry (up to MAX_FAILS), health marker reflects it.
- Lock contention → second instance exits 0 silently.
- Missing transcripts dir / empty backlog → exit 0, nothing to do.

## 9. Testing

New `tests/test-extract-drain.sh` (sandboxed `BRAIN_DIR`, stubbed extractor via a fake `claude` on PATH or an `SB_EXTRACT_STUB` hook):
- Refuses to run under `CLAUDECODE=1` (exit 0, no processing).
- Processes exactly `SB_DRAIN_BATCH` oldest-first; leaves the rest pending.
- Appends `outcome:"ok"` to done-set; a done transcript is skipped next run.
- Failing extractor → `retry` then terminal `error` after MAX_FAILS; never reprocessed after terminal.
- Lock held → second invocation is a no-op.
- `sb_slug_from_archived_transcript` reads `project_slug:` from the meta header.

`scripts/install-extract-timer.sh` (no `--apply`) prints valid unit text and touches nothing (assert `~/.config/systemd/user/` unchanged). If `systemd-analyze` is available, `systemd-analyze verify` the rendered units.

Smoke (manual, in the plan): `bash scripts/extract-drain.sh` by hand outside a session → confirm it authenticates via OAuth and writes a wiki delta; confirm `~/.second-brain/error-log.jsonl` clean.

## 10. Out of scope

- Real-time extraction (inotify daemon) — YAGNI; the timer + dreams cover it.
- Seeding the done-set from prior dream coverage to skip re-extraction — rely on downstream dedup instead.
- cron fallback — can be added later for non-systemd hosts (the VPS); the Pi has systemd.
- Changing the in-session skip behavior — it already archives correctly; no change needed.

<!-- version target: 0.13.0 -->
