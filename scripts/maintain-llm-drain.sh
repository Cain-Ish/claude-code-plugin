#!/bin/bash
# maintain-llm-drain.sh ("C" — the OPT-IN headless-LLM maintainer; the autonomy capstone).
# Out-of-band, it stages a wiki snapshot (reusing the dream machinery) and runs the LLM
# consolidation (dedup / relate / enrich / summarize / forget) on the STAGING copy via a headless
# `claude -p`, leaving the dream COMPLETED-UNACCEPTED for the user to review via /second-brain:dream
# + dream_accept. NOTHING reaches the live wiki without that human accept — and that guarantee is
# enforced by the KERNEL, not a prompt: the headless run executes inside bubblewrap with ONLY this
# dream's dir writable (live wiki + everything else read-only), so it physically cannot write live.
#
# Gated — airtight or not at all (capture ≠ consolidation ≠ LLM-authoring consent):
#   1. config.json `auto_maintain: true`   — default TRUE (≠ auto_improve). It still
#      only runs where guard #3 (bwrap) holds, so on macOS/Windows/bwrap-less Linux it is a no-op.
#   2. the drainer's CLAUDECODE-refuse / interactive-defer / single-flight guards (via extract-drain)
#   3. `claude` AND `bwrap` both present    — else SKIP; NEVER run the bypassPermissions agent unconfined
#   4. no unreviewed dream already pending  — don't stack work the user hasn't looked at
# Self-throttled to SB_MAINTAIN_LLM_INTERVAL (default 7d — a full consolidation costs tokens).
# Fail-soft: always exits 0; the dream is left for review and the SP-C nudge surfaces it.
#
# NOTE (Linux-only): airtight C requires bubblewrap, so it runs only where bwrap exists. macOS/
# Windows would need a different kernel sandbox — deferred (those users stay on explicit /maintain).
set -u
SDIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SDIR/lib.sh"

[ "$(sb_config_bool .auto_maintain on)" = "on" ] || exit 0      # default on; guards 2-4 + bwrap still apply
# Defense in depth: never spawn `claude -p` from inside a live session (the recursive-claude
# OAuth lock → hang). extract-drain.sh already refuses on CLAUDECODE, but guard here too in case
# this is ever run standalone. SB_MAINTAIN_LLM_FORCE=1 bypasses for tests.
[ "${CLAUDECODE:-}" = "1" ] && [ "${SB_MAINTAIN_LLM_FORCE:-0}" != "1" ] && exit 0
command -v claude >/dev/null 2>&1 || exit 0                        # needs the CLI (OAuth)
if ! command -v bwrap >/dev/null 2>&1; then
  sb_log_error "maintain-llm-drain" "auto_maintain on but bwrap absent — airtight C needs bubblewrap (e.g. apt install bubblewrap); skipping rather than running unconfined" 0
  exit 0
fi

# Failure-aware lifecycle: a structural failure must not burn
# the full weekly slot, and repeated failures must STOP retrying loudly instead
# of spinning forever. The quarantine SELF-CLEARS once the cheap preflight
# passes again (cause fixed), on a successful run, or by deleting the file
# (the autostage banner names it).
FAILS_F="$BRAIN_DIR/.llm-maintain-fails"
QUAR_F="$BRAIN_DIR/.llm-maintain-quarantine"
RETRY="${SB_MAINTAIN_LLM_RETRY:-86400}"; case "$RETRY" in ''|*[!0-9]*) RETRY=86400 ;; esac
if [ -f "$QUAR_F" ] && [ "${SB_MAINTAIN_LLM_FORCE:-0}" != "1" ]; then
  # SELF-CLEARING quarantine (deep-review): it exists to stop POINTLESS retries.
  # If the cheap preflight now passes (e.g. the unit was redeployed without
  # RestrictNamespaces), clear it and proceed; otherwise stay down silently.
  if bwrap --ro-bind / / --unshare-pid --new-session -- /bin/true >/dev/null 2>&1; then
    rm -f "$QUAR_F" "$FAILS_F" 2>/dev/null
  else
    exit 0
  fi
fi

# Weekly throttle. SB_MAINTAIN_LLM_FORCE=1 bypasses (tests / manual).
MARK="$BRAIN_DIR/.last-llm-maintain"
INT="${SB_MAINTAIN_LLM_INTERVAL:-604800}"; case "$INT" in ''|*[!0-9]*) INT=604800 ;; esac
# Never re-stamp LATER than the configured interval (deep-review: with a
# sub-daily INT, the retry target would land in the future, inverting "retry sooner").
[ "$RETRY" -gt "$INT" ] && RETRY="$INT"
if [ "${SB_MAINTAIN_LLM_FORCE:-0}" != "1" ]; then
  mt=$(sb_mtime "$MARK")
  [ "$(( $(date +%s) - ${mt:-0} ))" -ge "$INT" ] || exit 0
fi

# _fail_step <summary>: count the failure, quarantine at 3 strikes, and re-stamp
# the throttle to a ~24h retry horizon (mtime = now - INT + RETRY) instead of
# the full interval. `date -d @` (GNU) || `date -r` (BSD) pairing.
_fail_step() {
  local n; n=$(cat "$FAILS_F" 2>/dev/null || echo 0); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1)); printf '%s' "$n" > "$FAILS_F"
  if [ "$n" -ge 3 ]; then
    printf '[%s] quarantined after %s consecutive failures: %s\n' "$(date -u +%FT%TZ)" "$n" "$1" > "$QUAR_F"
  fi
  local target=$(( $(date +%s) - INT + RETRY ))
  local stamp
  # LOCAL-time render (deep-review): `touch -t` interprets its stamp as local
  # time; a UTC render skewed the retry horizon by the timezone offset.
  stamp=$(date -d "@$target" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$target" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$stamp" ] && touch -t "$stamp" "$MARK" 2>/dev/null
}

# Don't stack: if a completed-but-unreviewed (archived_at unset) dream already exists, skip until
# the user accepts/discards it (the SP-C terminal predicate).
for sf in "$BRAIN_DIR"/dreams/drm_*/status.json; do
  [ -f "$sf" ] || continue
  [ "$(jq -r '.status // ""' "$sf" 2>/dev/null)" = "completed" ] || continue
  a=$(jq -r '.archived_at // ""' "$sf" 2>/dev/null | tr -d '\r')
  { [ -z "$a" ] || [ "$a" = "null" ]; } && exit 0
done

# Preflight: prove bwrap can actually create namespaces HERE,
# BEFORE staging anything. Under systemd RestrictNamespaces=true this fails
# instantly — unchecked, that produces a stuck status=pending dream and burns
# the weekly slot, silently, every cycle.
if ! bwrap --ro-bind / / --unshare-pid --new-session -- /bin/true >/dev/null 2>&1; then
  sb_log_error "maintain-llm-drain" "bwrap preflight failed — namespace creation blocked (RestrictNamespaces in the unit? see systemd/sb-extract-drain-oauth.service); no dream staged" 0
  _fail_step "bwrap preflight failed (namespace creation blocked)"
  exit 0
fi

: > "$MARK"   # stamp the throttle even if the run below fails — don't retry every drain cycle

# 1. Stage a dream (runs OUTSIDE bwrap: it must read the live wiki + write the new dream dir).
DREAM_ID=$(bash "$SDIR/dream-snapshot.sh" 2>/dev/null) || exit 0
case "$DREAM_ID" in drm_*) : ;; *) exit 0 ;; esac
DREAM_DIR="$BRAIN_DIR/dreams/$DREAM_ID"
[ -d "$DREAM_DIR/staging/wiki" ] || exit 0

# 2. Run the consolidation HEADLESS + KERNEL-CONTAINED. Body = the dream-runner instructions
#    AFTER the agent frontmatter (delimiter-derived, not a magic line number, so a frontmatter
#    edit can't silently truncate the prompt), with {dream_id} filled in.
BODY=$(awk 'p; /^---$/{c++; if(c==2) p=1}' "$SDIR/../agents/dream-runner.md" | sed "s/{dream_id}/$DREAM_ID/g")
[ -n "$BODY" ] || { sb_log_error "maintain-llm-drain" "empty dream-runner body (frontmatter parse) — aborting headless run" 0; exit 0; }
PROMPT="You are running HEADLESS and UNATTENDED to consolidate dream $DREAM_ID. Work ONLY inside its staging/wiki — the live wiki is mounted read-only and you physically cannot write it. Follow these instructions exactly, then set the dream status to completed:

$BODY"
# Resolved once, not pinned: SB_MAINTAIN_LLM_MODEL is declared as a MID pin in model-ladder.json,
# so an operator override still lands at rung 0 of the walked ladder.
MODEL="$(sb_resolve_model mid headless)"
TO="${SB_MAINTAIN_LLM_TIMEOUT:-1800}"; case "$TO" in ''|*[!0-9]*) TO=1800 ;; esac
# Clamp the headless wall-clock cap BELOW the dream-staleness horizon so an operator override
# can never let a still-running headless dream age past SB_DREAM_RUN_TIMEOUT (6h) and get wrongly
# reclaimed + double-spawned by dream-snapshot/autostage (deep-review: THIS clamp — not a machine
# heartbeat — is what guarantees a live headless run is never judged stale; sb_dream_is_stale uses
# status.json mtime, which is fresh at spawn, so a sub-horizon cap means it can never fire here).
RUN_HORIZON="${SB_DREAM_RUN_TIMEOUT:-21600}"; case "$RUN_HORIZON" in ''|*[!0-9]*) RUN_HORIZON=21600 ;; esac
if [ "$TO" -ge "$RUN_HORIZON" ]; then
  _clamped=$(( RUN_HORIZON - 60 )); [ "$_clamped" -lt 60 ] && _clamped=60
  sb_log_error "maintain-llm-drain" "SB_MAINTAIN_LLM_TIMEOUT=$TO >= SB_DREAM_RUN_TIMEOUT=$RUN_HORIZON — clamping to ${_clamped}s so a live headless dream can't be wrongly reclaimed" 0
  TO="$_clamped"
fi
TBIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
# NEVER run the bypassPermissions agent without a wall-clock cap. A bare
# `${TBIN:+$TBIN "$TO"}` expansion SILENTLY DROPS the timeout when neither
# `timeout` (GNU/Linux) nor `gtimeout` (macOS coreutils) is on PATH, leaving an
# UNBOUNDED `bwrap ... claude -p --permission-mode bypassPermissions` that could
# hang forever (forever-pending dream + burned slot + creds readable for the hang).
# Hard-fail instead: log, mark the staged dream failed, count the strike, exit 0
# (fail-soft). DRYRUN never reaches here.
if [ "${SB_MAINTAIN_LLM_DRYRUN:-0}" != "1" ] && [ -z "$TBIN" ]; then
  sb_log_error "maintain-llm-drain" "no timeout/gtimeout on PATH — refusing to run the bypassPermissions agent UNBOUNDED (install coreutils: apt install coreutils / brew install coreutils for gtimeout); dream $DREAM_ID left for review" 0
  SF="$DREAM_DIR/status.json"
  if [ -f "$SF" ] && [ "$(jq -r '.status // ""' "$SF" 2>/dev/null | tr -d '\r')" != "completed" ]; then
    jq --arg e "$(date -u +%FT%TZ)" --arg err "refused: no timeout/gtimeout binary — would run unbounded" \
      '.status = "failed" | .ended_at = $e | .error = $err' "$SF" > "$SF.tmp.$$" 2>/dev/null \
      && mv "$SF.tmp.$$" "$SF" 2>/dev/null || rm -f "$SF.tmp.$$" 2>/dev/null
  fi
  _fail_step "no timeout/gtimeout binary (would run unbounded)"
  exit 0
fi

# The jail. Writable: ONLY this dream's dir + the OAuth credential FILE (token refresh) + ephemeral
# tmpfs for claude's own session scratch. CRITICALLY, the rest of ~/.claude — `plugins/` (the
# plugin's own code) and the settings/hooks — stays READ-ONLY (via --ro-bind / /), so a prompt-
# injected agent cannot self-modify the plugin or plant a hook that a later UNjailed run would
# execute against the live wiki. The live wiki + all else are read-only. (Residual, inherent to any
# OAuth headless run: the credential file is readable for auth; the dream content is the user's own.)
BWRAP_ARGS=(
  --ro-bind / /
  --bind "$DREAM_DIR" "$DREAM_DIR"
  --tmpfs /tmp --proc /proc --dev /dev
  --tmpfs "$HOME/.claude/projects" --tmpfs "$HOME/.claude/session-data" --tmpfs "$HOME/.claude/cache"
  --unshare-pid --new-session --die-with-parent
  --setenv HOME "$HOME" --setenv PATH "${PATH:-/usr/local/bin:/usr/bin:/bin}"
)
# READ-ONLY (deliberate, P0 over convenience): the agent only READS the token for the API. A
# writable bind would let a prompt-injected agent truncate/overwrite the user's credentials (DoS) —
# the user's threat model is credentials-at-risk, so we forbid that. TRADE-OFF: a token *refresh*
# during the run can't persist into the jail; a near-expiry token therefore fails the run, which is
# observable (the rc!=0 log below) and self-heals on the next run with a fresh token — acceptable
# for a bounded weekly consolidation. (Residual, inherent to any OAuth headless run: the token is
# readable + network is up → a prompt-injected agent could exfil it; mitigated by opt-in/default-off
# + the content being the user's own captured knowledge + the dream review gate.)
[ -f "$HOME/.claude/.credentials.json" ] && BWRAP_ARGS+=(--ro-bind "$HOME/.claude/.credentials.json" "$HOME/.claude/.credentials.json")

# Test-only: prove the gate reached the contained run without invoking claude (the real headless
# run is operator-verified — it can't run from inside a Claude session).
if [ "${SB_MAINTAIN_LLM_DRYRUN:-0}" = "1" ]; then
  printf 'DRYRUN dream=%s prompt_bytes=%s contained: bwrap --ro-bind / / --bind %s (creds-only ~/.claude) ; claude -p --permission-mode bypassPermissions\n' "$DREAM_ID" "${#PROMPT}" "$DREAM_DIR"
  # Simulate a successful consolidation so the auto-accept gate below is exercised
  # in tests (the gate keys on status=completed). DRYRUN never runs the real
  # bwrap'd agent and the auto-accept block has its own DRYRUN guard (no real
  # accept), so this stays side-effect-free beyond the staged dream's status.
  jq '.status = "completed"' "$DREAM_DIR/status.json" > "$DREAM_DIR/status.json.tmp.$$" 2>/dev/null \
    && mv "$DREAM_DIR/status.json.tmp.$$" "$DREAM_DIR/status.json" 2>/dev/null || rm -f "$DREAM_DIR/status.json.tmp.$$" 2>/dev/null
else
rc=0
ERR_F=$(mktemp)
SB_NESTED_SPAWN=1 ${TBIN:+$TBIN "$TO"} bwrap "${BWRAP_ARGS[@]}" \
  -- claude -p --permission-mode bypassPermissions --model "$MODEL" "$PROMPT" >/dev/null 2>"$ERR_F" || rc=$?
# Record a model-unavailable failure before the generic failure handling below: this run is
# self-throttled to SB_MAINTAIN_LLM_INTERVAL (7d), so without a blocklist entry the next run a
# week later would re-spawn the same dead model. stdout went to /dev/null; stderr carries it.
if sb_model_blocked_verdict "${rc:-0}" /dev/null "$ERR_F"; then
  sb_note_model_blocked headless "$MODEL" "maintain-drain rc=${rc:-0}"
fi
if [ "$rc" -ne 0 ]; then
  # A failure must be VISIBLE — capture stderr and transition
  # pending→failed atomically so dream_list/status and the autostage scan show
  # it, instead of a forever-pending mystery with error:null.
  ERR_TAIL=$(tail -c 300 "$ERR_F" 2>/dev/null | tr '\n' ' ')
  sb_log_error "maintain-llm-drain" "headless consolidation exited $rc for $DREAM_ID: ${ERR_TAIL:-no stderr} (status set to failed)" 0
  SF="$DREAM_DIR/status.json"
  if [ -f "$SF" ] && [ "$(jq -r '.status // ""' "$SF" 2>/dev/null)" != "completed" ]; then
    jq --arg e "$(date -u +%FT%TZ)" --arg err "exit $rc: ${ERR_TAIL:-no stderr}" \
      '.status = "failed" | .ended_at = $e | .error = $err' "$SF" > "$SF.tmp.$$" 2>/dev/null \
      && mv "$SF.tmp.$$" "$SF" 2>/dev/null || rm -f "$SF.tmp.$$" 2>/dev/null
  fi
  _fail_step "headless run exit $rc: ${ERR_TAIL:-no stderr}"
else
  # The spawn returned 0, but the agent may have DIED before finishing
  # (bwrap forks then the child OOMs/segfaults yet bwrap exits 0; or claude exits 0
  # without advancing the dream). status.json would then sit at pending/running with
  # error:null FOREVER — the terminal-less, deadlock-every-future-dream mystery the
  # rc!=0 branch guards against, here on the rc==0 path. A genuine success leaves status=completed
  # (the agent sets it per the prompt), so anything NOT completed after a "successful"
  # spawn is a silent death. Self-heal: force →failed (terminal, matching the rc!=0
  # branch's `!= completed` predicate and sb_dream_is_stale's pending|running=non-
  # terminal contract). Soft recovery: do NOT _fail_step / hold the quarantine — the
  # spawn itself reported ok; clear the counters ONLY on a real completion.
  SF="$DREAM_DIR/status.json"
  st=""; [ -f "$SF" ] && st=$(jq -r '.status // ""' "$SF" 2>/dev/null | tr -d '\r')
  if [ "$st" = "completed" ]; then
    rm -f "$FAILS_F" "$QUAR_F" 2>/dev/null   # genuine success → reset the failure lifecycle
  else
    # Silent death: the spawn returned 0 but the dream is pending/running/MISSING (agent
    # died, or a broken/injected agent deleted/truncated status.json). Heal what we can and
    # DO NOT clear the counters/quarantine — the run did not actually succeed (review fix: a
    # missing status.json must not read as success and wrongly reset the lifecycle).
    sb_log_error "maintain-llm-drain" "headless run for $DREAM_ID exited 0 but the dream is '${st:-missing}' — never reached completed (agent died); forcing →failed, counters retained" 0
    if [ -n "$st" ] && [ -f "$SF" ]; then
      # Valid-but-non-completed (pending/running) → in-place heal.
      jq --arg e "$(date -u +%FT%TZ)" --arg err "exit 0 but the dream never reached completed (was '$st'; agent died before finishing)" \
        '.status = "failed" | .ended_at = $e | .error = $err' "$SF" > "$SF.tmp.$$" 2>/dev/null \
        && mv "$SF.tmp.$$" "$SF" 2>/dev/null || rm -f "$SF.tmp.$$" 2>/dev/null
    else
      # Missing OR corrupt/truncated status.json (the jq read yielded empty): an in-place jq edit
      # would itself FAIL on the bad JSON and leave it unparseable forever (review fix). Mint a
      # fresh minimal terminal doc instead — the dream_id is known — so dream_list/status and
      # sb_dream_is_stale can read it.
      jq -nc --arg id "$DREAM_ID" --arg e "$(date -u +%FT%TZ)" \
        --arg err "exit 0 but status.json was missing/corrupt at completion (agent died before finishing)" \
        '{id:$id, status:"failed", ended_at:$e, error:$err}' > "$SF.tmp.$$" 2>/dev/null \
        && mv "$SF.tmp.$$" "$SF" 2>/dev/null || rm -f "$SF.tmp.$$" 2>/dev/null
    fi
  fi
fi
rm -f "$ERR_F" 2>/dev/null
fi   # close the DRYRUN-vs-real-run branch (DRYRUN simulates completion + falls through)

# 3. Auto-accept gate. DEFAULT OFF — the marketplace-safe default
#    keeps the original guarantee (nothing reaches the live wiki unattended without
#    a human accept). The operator opts in via config.json "auto_accept":
#      "safe" → apply ONLY a dream proposing no FORGET-archives and no deletions
#               (pure reversible consolidation: rsync + reindex are idempotent)
#      "all"  → apply any completed dream (full-autonomy operator choice; the
#               FORGET archive is a reversible MOVE, and we tarball the wiki first,
#               so even an archival dream is recoverable)
#    Every auto-accept BACKS UP the live wiki first, then runs dream-accept.sh
#    (out-of-tree-symlink reject + staging node-shape + rsync + reindex). On any
#    failure it logs and leaves the dream for manual review — fail-safe, never
#    fail-destructive.
AA_MODE=$(sb_config_get .auto_accept safe)
ASF="$DREAM_DIR/status.json"
AA_FORGET=0; [ -s "$DREAM_DIR/forget-manifest.tsv" ] && AA_FORGET=1
AA_DECISION=$(sb_auto_accept_decision "$AA_MODE" \
  "$(jq -r '.status // ""' "$ASF" 2>/dev/null)" \
  "$(jq -r '.archived_at // ""' "$ASF" 2>/dev/null)" "$AA_FORGET")
if [ "$AA_DECISION" = "accept" ]; then
  AA_KDIR="$(sb_knowledge_dir)"
  AA_BK=""
  AA_BACKUP_OK=1
  if [ -d "$AA_KDIR/wiki" ]; then
    AA_BK="$BRAIN_DIR/wiki-backup-pre-autoaccept-$(date -u +%Y%m%d%H%M%SZ).tgz"
    if ! tar czf "$AA_BK" -C "$AA_KDIR" wiki 2>/dev/null; then AA_BK=""; AA_BACKUP_OK=0; fi
  fi
  # Never accept UNATTENDED without a backup. A failed backup (disk full) is
  # exactly the situation that also produces a broken/empty staging — proceeding
  # would be a correlated, unrecoverable wipe. Abort to manual review instead.
  if [ "$AA_BACKUP_OK" = "0" ]; then
    sb_log_error "maintain-llm-drain" "auto_accept=$AA_MODE: pre-accept backup FAILED for $DREAM_ID — refusing unattended accept (left for manual review)" 0
  elif [ "${SB_MAINTAIN_LLM_DRYRUN:-0}" = "1" ]; then
    printf 'DRYRUN auto-accept=%s dream=%s forget=%s backup=%s\n' "$AA_MODE" "$DREAM_ID" "$AA_FORGET" "${AA_BK:-none}"
  else
    # Safe mode forbids ANY deletion (not just forget-manifest entries).
    AA_NODELETE=0; [ "$AA_MODE" = "safe" ] && AA_NODELETE=1
    # We already tarballed via AA_BACKUP above, so tell dream-accept
    # to SKIP its own backup — one pre-accept tarball, not two.
    if SB_DREAM_ACCEPT_SKIP_BACKUP=1 SB_DREAM_ACCEPT_NO_DELETE="$AA_NODELETE" bash "$SDIR/dream-accept.sh" "$DREAM_ID" >/dev/null 2>&1; then
      sb_log_error "maintain-llm-drain" "auto_accept=$AA_MODE: applied dream $DREAM_ID${AA_BK:+ (backup $AA_BK)}" 0
    else
      sb_log_error "maintain-llm-drain" "auto_accept=$AA_MODE: dream-accept refused/failed for $DREAM_ID — left for manual review (backup ${AA_BK:-none})" 0
    fi
  fi
elif [ "$AA_DECISION" = "skip:safe-refuses-forget" ]; then
  sb_log_error "maintain-llm-drain" "auto_accept=safe: dream $DREAM_ID proposes FORGET archives — left for manual review" 0
fi

exit 0
