#!/bin/bash
# extract-drain.sh — out-of-band extraction drainer. Processes archived
# transcripts that were skipped by the in-session extractor (OAuth recursive
# lock). Run by a systemd user timer, OUTSIDE any Claude session.
#
#   SB_DRAIN_BATCH      transcripts per run (default 5)
#   SB_DRAIN_MAX_FAILS  retries before giving up on a transcript (default 3)
#   SB_EXTRACT_STUB     test-only: path to a stub called instead of the real
#                       extractor, as `$SB_EXTRACT_STUB <txt> <slug>`.
# Always exits 0 (fail-soft).
set -u
source "$(dirname "$0")/lib.sh"

# Defer if an interactive claude session is active for this uid. The recursive-
# claude OAuth lock is GLOBAL (held by any live interactive session), so a
# `claude -p` extraction would hang on the timeout — and worse, spawn a full
# recursive claude per attempt and bump the poison-pill counter on a transcript
# that is actually fine. So we skip cleanly (no attempt, no retry, no spawn) and
# let the next timer fire retry during an idle window. Detection: a `claude`
# process (this uid) whose args lack `-p` (the -p ones are our own extractor /
# other print-mode calls). SB_INTERACTIVE_OVERRIDE forces the verdict for tests.
sb_drain_should_defer() {
  case "${SB_INTERACTIVE_OVERRIDE:-}" in
    active)   return 0 ;;
    inactive) return 1 ;;
  esac
  local p args
  for p in $(pgrep -u "$(id -u)" -x claude 2>/dev/null); do
    args=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case " $args " in
      *" -p "*) : ;;   # print-mode (our extractor or similar) — ignore
      *) return 0 ;;   # interactive session present → defer
    esac
  done
  return 1
}

# The whole point is to run outside a session — refuse the recursive-lock context.
if [ "${CLAUDECODE:-}" = "1" ]; then
  echo "extract-drain: refusing to run inside a Claude Code session" >&2
  exit 0
fi

# Defer (don't fail) while an interactive session holds the global OAuth lock.
if sb_drain_should_defer; then
  echo "extract-drain: interactive claude session active — deferring (OAuth lock held)" >&2
  exit 0
fi

BATCH="${SB_DRAIN_BATCH:-5}"
case "$BATCH" in ''|*[!0-9]*) BATCH=5 ;; esac
MAX_FAILS="${SB_DRAIN_MAX_FAILS:-3}"
case "$MAX_FAILS" in ''|*[!0-9]*) MAX_FAILS=3 ;; esac

TX_DIR="$BRAIN_DIR/transcripts"
STATE="$BRAIN_DIR/.extraction-state.jsonl"
[ -d "$TX_DIR" ] || exit 0

# Single-flight: a slow run must not overlap the next timer fire.
exec 9>"$BRAIN_DIR/.extract-drain.lock" || exit 0
flock -n 9 || exit 0

do_extract() {  # $1 = txt, $2 = slug ; honors the test stub
  if [ -n "${SB_EXTRACT_STUB:-}" ]; then
    "$SB_EXTRACT_STUB" "$1" "$2"
  else
    sb_extract_transcript "$1" "$2"
  fi
}

now() { date -u +%FT%TZ; }

processed=0
failed=0
# oldest-first by mtime (least-recently-modified). Sufficient for a drainer —
# everything pending is processed within a few batches regardless of order.
while IFS= read -r tf; do
  [ -n "$tf" ] || continue
  [ "$processed" -ge "$BATCH" ] && break
  base=$(basename "$tf")
  sb_extraction_done "$base" "$STATE" && continue
  slug=$(sb_slug_from_archived_transcript "$tf")
  [ -n "$slug" ] || slug="unknown"
  if do_extract "$tf" "$slug"; then
    printf '{"basename":%s,"ts":"%s","outcome":"ok"}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" >> "$STATE"
    processed=$((processed+1))
  else
    failed=$((failed+1))
    fails=$(sb_extraction_fails "$base" "$STATE"); fails=$((fails+1))
    if [ "$fails" -ge "$MAX_FAILS" ]; then
      printf '{"basename":%s,"ts":"%s","outcome":"error","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" "$fails" >> "$STATE"
    else
      printf '{"basename":%s,"ts":"%s","outcome":"retry","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" "$fails" >> "$STATE"
    fi
  fi
done < <(ls -1tr "$TX_DIR"/*.txt 2>/dev/null)

# Don't clobber a real failure marker: only report ok if anything succeeded.
# A run where every extraction failed must surface status=fail so the
# SessionStart banner alerts the user (otherwise a broken drainer looks healthy).
# Report the REAL backend the per-transcript extractor recorded (local | claude-cli |
# anthropic-api), not a hardcoded label; default to "drainer" if none was written.
DRAIN_BACKEND=$(jq -r '.backend // "drainer"' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null); : "${DRAIN_BACKEND:=drainer}"
if [ "$processed" -eq 0 ] && [ "$failed" -gt 0 ]; then
  sb_write_extractor_health "$DRAIN_BACKEND" "fail" "drained 0, $failed failed this run"
else
  sb_write_extractor_health "$DRAIN_BACKEND" "ok" "drained $processed this run ($failed failed)"
fi
exit 0
