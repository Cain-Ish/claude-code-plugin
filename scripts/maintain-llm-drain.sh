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
#   1. config.json `auto_maintain: true`   — the C-specific opt-in (default false; ≠ auto_improve)
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

[ "$(sb_config_bool .auto_maintain off)" = "on" ] || exit 0      # the C opt-in (default off)
# Defense in depth: never spawn `claude -p` from inside a live session (the recursive-claude
# OAuth lock → hang). extract-drain.sh already refuses on CLAUDECODE, but guard here too in case
# this is ever run standalone. SB_MAINTAIN_LLM_FORCE=1 bypasses for tests.
[ "${CLAUDECODE:-}" = "1" ] && [ "${SB_MAINTAIN_LLM_FORCE:-0}" != "1" ] && exit 0
command -v claude >/dev/null 2>&1 || exit 0                        # needs the CLI (OAuth)
if ! command -v bwrap >/dev/null 2>&1; then
  sb_log_error "maintain-llm-drain" "auto_maintain on but bwrap absent — airtight C needs bubblewrap (e.g. apt install bubblewrap); skipping rather than running unconfined" 0
  exit 0
fi

# Weekly throttle. SB_MAINTAIN_LLM_FORCE=1 bypasses (tests / manual).
MARK="$BRAIN_DIR/.last-llm-maintain"
INT="${SB_MAINTAIN_LLM_INTERVAL:-604800}"; case "$INT" in ''|*[!0-9]*) INT=604800 ;; esac
if [ "${SB_MAINTAIN_LLM_FORCE:-0}" != "1" ]; then
  mt=$(stat -c %Y "$MARK" 2>/dev/null || stat -f %m "$MARK" 2>/dev/null || echo 0)
  [ "$(( $(date +%s) - ${mt:-0} ))" -ge "$INT" ] || exit 0
fi

# Don't stack: if a completed-but-unreviewed (archived_at unset) dream already exists, skip until
# the user accepts/discards it (the SP-C terminal predicate).
for sf in "$BRAIN_DIR"/dreams/drm_*/status.json; do
  [ -f "$sf" ] || continue
  [ "$(jq -r '.status // ""' "$sf" 2>/dev/null)" = "completed" ] || continue
  a=$(jq -r '.archived_at // ""' "$sf" 2>/dev/null)
  { [ -z "$a" ] || [ "$a" = "null" ]; } && exit 0
done

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
MODEL="${SB_MAINTAIN_LLM_MODEL:-claude-sonnet-4-6}"
TO="${SB_MAINTAIN_LLM_TIMEOUT:-1800}"; case "$TO" in ''|*[!0-9]*) TO=1800 ;; esac
TBIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)

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
[ -f "$HOME/.claude/.credentials.json" ] && BWRAP_ARGS+=(--bind "$HOME/.claude/.credentials.json" "$HOME/.claude/.credentials.json")

# Test-only: prove the gate reached the contained run without invoking claude (the real headless
# run is operator-verified — it can't run from inside a Claude session).
if [ "${SB_MAINTAIN_LLM_DRYRUN:-0}" = "1" ]; then
  printf 'DRYRUN dream=%s prompt_bytes=%s contained: bwrap --ro-bind / / --bind %s (creds-only ~/.claude) ; claude -p --permission-mode bypassPermissions\n' "$DREAM_ID" "${#PROMPT}" "$DREAM_DIR"
  exit 0
fi
rc=0
${TBIN:+$TBIN "$TO"} bwrap "${BWRAP_ARGS[@]}" \
  -- claude -p --permission-mode bypassPermissions --model "$MODEL" "$PROMPT" >/dev/null 2>&1 || rc=$?
# Observable, not silent: a broken jail / auth / timeout leaves a completed-empty dream otherwise.
[ "$rc" -ne 0 ] && sb_log_error "maintain-llm-drain" "headless consolidation exited $rc for $DREAM_ID (left for review; check bwrap/auth/timeout)" 0

# 3. The dream is now completed-unaccepted (or failed). NEVER auto-accept — the SP-C nudge surfaces
#    it and the user reviews via /second-brain:dream + dream_accept.
exit 0
