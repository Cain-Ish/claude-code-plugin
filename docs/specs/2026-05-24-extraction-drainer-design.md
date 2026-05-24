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
  slug=$(sb_slug_from_transcript_name "$base")   # parse <uuid>_<slug>_<date>.txt
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

Factor a helper into `lib.sh`:

- `sb_extract_transcript <transcript_file> <slug>` — reads the formatted transcript text, calls `sb_call_extractor` with the extraction system prompt + model (`SB_EXTRACTOR_MODEL`), pipes the JSON delta to `merge-project-update.sh`. Returns 0 on a successful merge, non-zero otherwise. Used by the drainer; `stop-extract.sh` is refactored to call it for the (rare) API-key in-session path so the two never diverge.
- `sb_extraction_done <base> <state_file>` — true if a terminal (`ok`/`error`) line exists.
- `sb_extraction_fails <base> <state_file>` — count of prior `retry` lines for the basename (0 if none).
- `sb_slug_from_transcript_name <base>` — parse the `<uuid>_<slug>_<date>.txt` convention.

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

## 7. Install — `sb extract` subcommand (reviewable)

Extend the `sb` CLI:
- `sb extract` — run one drain pass now (manual / smoke test).
- `sb extract install-timer [--apply]` — without `--apply`: print the rendered `.service` + `.timer` content and the exact commands (`systemctl --user enable --now sb-extract-drain.timer`, `loginctl enable-linger $USER`). With `--apply`: write the units to `~/.config/systemd/user/`, reload, enable+start the timer, and print the linger command for the user to run (linger may need the user's own invocation). 
- `sb extract status` — show timer state + last health marker + pending-transcript count.
- `sb extract uninstall-timer` — disable + remove units (clean reversal).

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
- `sb_slug_from_transcript_name` parses the naming convention correctly.

`sb extract install-timer` (no `--apply`) prints valid unit text and touches nothing (assert `~/.config/systemd/user/` unchanged). If `systemd-analyze` is available, `systemd-analyze verify` the rendered units.

Smoke (manual, in the plan): `sb extract` by hand outside a session → confirm it authenticates via OAuth and writes a wiki delta; confirm `~/.second-brain/error-log.jsonl` clean.

## 10. Out of scope

- Real-time extraction (inotify daemon) — YAGNI; the timer + dreams cover it.
- Seeding the done-set from prior dream coverage to skip re-extraction — rely on downstream dedup instead.
- cron fallback — can be added later for non-systemd hosts (the VPS); the Pi has systemd.
- Changing the in-session skip behavior — it already archives correctly; no change needed.

<!-- version target: 0.13.0 -->
