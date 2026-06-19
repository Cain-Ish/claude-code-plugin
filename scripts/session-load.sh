#!/bin/bash
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0
# Hot-tier loader with byte-budget enforcement.
# Outputs USER.md + active PROJECT.md + persona signals + wiki enrichment,
# capped at BYTE_BUDGET to avoid overflowing Claude's context window.
# Priority: USER.md > PROJECT.md > persona signals > wiki enrichment.
source "$(dirname "$0")/lib.sh"

USER_FILE="$BRAIN_DIR/USER.md"
INDEX_FILE="$BRAIN_DIR/projects.jsonl"
PROJECTS_DIR="$BRAIN_DIR/projects"
BYTE_BUDGET=8000   # ~2000 tokens. Claude Code hard-caps hook output at 10K chars.

# Resolve THIS session's project from the per-session project dir (CLAUDE_PROJECT_DIR,
# which Claude Code sets to the project root, else cwd) — NOT from the shared
# .active-session-slug pin, which a CONCURRENT session in another project can clobber.
# sb_slug_from_dir collapses tmp/scratch-style dirs into one shared "scratch" project
# (a session from /tmp/tmp.xK3p9q would otherwise create a ghost project — 33 such
# dirs accumulated before this guard).
# Monorepo-aware: slug / parent / root_path for the active dir.
# IFS=$'\t' read collapses consecutive TABs (whitespace), so an empty parent field
# (standalone dir: "slug\t\troot_path") gets swallowed into the parent variable.
# Use read -ra to capture all fields; index explicitly to preserve the empty middle.
_det_out=$(sb_detect_project "${CLAUDE_PROJECT_DIR:-$PWD}")
IFS=$'\t' read -ra _det_fields <<< "$_det_out"
slug="${_det_fields[0]:-}"
if [ "${#_det_fields[@]}" -ge 3 ]; then
  parent="${_det_fields[1]}"
  root_path="${_det_fields[2]}"
else
  parent=""
  root_path="${_det_fields[1]:-}"
fi
git_remote=$(sb_git_remote "${CLAUDE_PROJECT_DIR:-$PWD}")
# Refresh the pin (legacy fallback for the MCP server / CLIs when no project dir is set).
echo "$slug" > "$BRAIN_DIR/.active-session-slug"
project_file="$PROJECTS_DIR/$slug/PROJECT.md"

if [ ! -f "$project_file" ]; then
  mkdir -p "$(dirname "$project_file")"
  cat > "$project_file" <<TMPL
# PROJECT: $slug

## Goal
(auto-scaffolded — describe this project's goal)

## State

## Plan

## Conventions

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ) -->
<!-- last_queried_wiki: -->
TMPL
  # Use jq to membership-check, not grep — projects.jsonl may be pretty-
  # printed (objects split across lines, `"slug": "x"` with whitespace),
  # which slips past the literal "\"slug\":\"$slug\"" pattern and causes
  # a duplicate registration on the next session that creates PROJECT.md.
  # jq --slurp parses pretty-printed and JSONL identically.
  if [ -f "$INDEX_FILE" ]; then
    if ! jq -se --arg s "$slug" 'map(select(.slug == $s)) | length > 0' \
        "$INDEX_FILE" >/dev/null 2>&1; then
      jq -nc --arg s "$slug" --arg n "$slug" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
             --arg p "$parent" --arg rp "$root_path" --arg gr "$git_remote" \
        '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}
         + (if $p  != "" then {parent:$p}      else {} end)
         + (if $rp != "" then {root_path:$rp}  else {} end)
         + (if $gr != "" then {git_remote:$gr} else {} end)' >> "$INDEX_FILE"
    fi
  fi
fi

cp "$project_file" "$BRAIN_DIR/.session-baseline-$slug.md"

# CRLF normalize ONCE for the read-only parsing below. A Windows/imported CRLF PROJECT.md
# defeats every `/^## Section$/` awk reader (header is `## Section\r`), which would zero all
# scope-banner counters AND empty the PROJ_KW wiki-enrichment harvest. Only triggers when a CR
# is actually present (the common LF case pays nothing). Safe: every use of $project_file from
# here on is READ-only (the auto-scaffold write happened earlier, before this baseline copy).
if LC_ALL=C grep -q "$(printf '\r')" "$project_file" 2>/dev/null; then
  _proj_lf=$(mktemp) && tr -d '\r' < "$project_file" > "$_proj_lf" && project_file="$_proj_lf"
fi

# --- Collect components with byte tracking ---
OUTPUT_FILE=$(mktemp)
USED=0

# RESERVE the priority-1 forced sections (USER.md ≤6000 + PROJECT.md ≤3000, emitted
# `force` at the END) from the banner budget, so conditional banners can never crowd
# them past Claude Code's 10K-char hook ceiling — which truncates from the END, i.e.
# exactly the human's Never/Always rules that `force` is meant to guarantee. Size from
# the files (cheap, bytes), capped at each section's own emit cap; HARD_CAP stays under
# 10K with margin. Banners get whatever room is left; forced always lands intact.
HARD_CAP=9500
_usz=$(wc -c < "$USER_FILE" 2>/dev/null || echo 0); [ "${_usz:-0}" -gt 6000 ] && _usz=6000
_psz=$(wc -c < "$project_file" 2>/dev/null || echo 0); [ "${_psz:-0}" -gt 3000 ] && _psz=3000
_banner_room=$(( HARD_CAP - ${_usz:-0} - ${_psz:-0} )); [ "$_banner_room" -lt 0 ] && _banner_room=0
[ "$BYTE_BUDGET" -gt "$_banner_room" ] && BYTE_BUDGET=$_banner_room

sb_append() {
  local text="$1" label="$2" max="${3:-0}" force="${4:-}"
  local size=${#text}
  [ "$size" -eq 0 ] && return 0
  if [ "$max" -gt 0 ] && [ "$size" -gt "$max" ]; then
    text=$(printf '%s' "$text" | head -c "$max")
    size=$max
  fi
  local projected=$((USED + size))
  # `force` exempts a priority-1 section (USER.md) from the budget — the human's global Never/Always
  # rules must always land, even when conditional banners have already spent the budget.
  if [ -z "$force" ] && [ "$projected" -gt "$BYTE_BUDGET" ]; then
    sb_log_error "session-load.sh" "gate=byte-budget $label skipped (${size}B would exceed ${BYTE_BUDGET}B cap, used=${USED}B)" 0
    return 1
  fi
  printf '%s' "$text" >> "$OUTPUT_FILE"
  USED=$projected
  return 0
}

# Bump per-project session counter (used by cadence banner below).
sb_increment_session_count "$slug"

# 0a. Cadence + maintenance banners — surface SB system events that would
# otherwise require the user to remember to run /second-brain:dream or
# /second-brain:improve. Threshold-gated to avoid banner fatigue.
SESSION_COUNT=$(sb_get_session_count "$slug")
DREAM_THRESHOLD="${SB_DREAM_CADENCE:-15}"
# Legacy session-count nag: only when auto-stage is disabled. When autostage is
# on (default), dream-autostage.sh owns the nudge — suppress here to avoid a
# double banner. See docs/specs/2026-05-24-dream-auto-stage-design.md §7.
if [ "${SB_DREAM_AUTOSTAGE:-on}" = "off" ] && [ "$SESSION_COUNT" -ge "$DREAM_THRESHOLD" ]; then
  sb_append "$(printf '## ⓘ second-brain — dream consolidation suggested\n%s sessions since last dream (threshold: %s).\nRun: `/second-brain:dream --background` — mines transcripts for missed learnings, stages changes for review.\n\n' \
    "$SESSION_COUNT" "$DREAM_THRESHOLD")" "dream-cadence-banner" 300
fi
# --- v2.8.0 maintainer auto-dispatch: reconcile previous + threshold -----
N=${SB_MAINTAINER_THRESHOLD:-3}
AUTO=${SB_MAINTAINER_AUTO:-on}
PROJ_DIR="$BRAIN_DIR/projects/$slug"
DISP_FILE="$PROJ_DIR/.maintainer-dispatched"
ACK_FILE="$PROJ_DIR/.maintainer-needed-last"
DISABLED_FILE="$PROJ_DIR/.maintainer-auto-disabled"

# [reconcile] If previous dispatch finished, reset state on success or bump fail-count on failure.
N_MAX_FAILS=${SB_MAINTAINER_MAX_FAILS:-3}
if [ -f "$DISP_FILE" ] && [ -f "$ACK_FILE" ]; then
  # Success.
  sb_reset_wiki_writes "$slug"
  sb_reset_maintainer_fails "$slug"
  rm -f "$DISP_FILE" "$ACK_FILE"
elif [ -f "$DISP_FILE" ] && [ ! -f "$ACK_FILE" ]; then
  # Failure: parent Claude didn't write the ack file.
  COUNT_AFTER=$(( N - 1 < 0 ? 0 : N - 1 ))
  sb_set_wiki_writes "$slug" "$COUNT_AFTER"
  sb_inc_maintainer_fails "$slug"
  rm -f "$DISP_FILE"
  sb_log_error "session-load.sh" "maintainer-auto-dispatch-failed slug=$slug" 0
  sb_append "$(printf '## ⚠ maintainer auto-dispatch failed last session — see error-log\n\n')" \
    "maintainer-fail-banner" 200
  if [ "$(sb_get_maintainer_fails "$slug")" -ge "$N_MAX_FAILS" ]; then
    touch "$DISABLED_FILE"
    sb_log_error "session-load.sh" "maintainer-auto-disabled slug=$slug fails=$N_MAX_FAILS" 0
    sb_reset_maintainer_fails "$slug"
  fi
fi

# [suggest] Emit a user-facing maintenance-suggested banner when the
# wiki-write counter crosses the threshold. Doctrinal alignment (C3-B,
# wiki/decisions/2026-05-28-plugin-architecture-rethink.md): the banner does
# NOT instruct Claude to auto-dispatch the knowledge-maintainer subagent —
# Anthropic's pattern is explicit-invocation. The user runs
# `/second-brain:dream` (whose 6-phase pipeline includes maintainer work)
# when ready, and the dream-accept path resets the counter.
#
# Reconcile state machine (DISP_FILE/ACK_FILE/fail-count) is retained for
# back-compat: a user or script may still manually create DISP_FILE before
# explicit dispatch and the reset+failure paths above will fire correctly.
# This branch no longer creates DISP_FILE itself.
if [ "$AUTO" != "off" ] && [ ! -f "$DISABLED_FILE" ]; then
  COUNT=$(sb_get_wiki_writes "$slug")
  if [ "$COUNT" -ge "$N" ]; then
    # shellcheck disable=SC2016  # single quotes intentional: literal backticks + printf %s placeholders
    BANNER=$(printf '## ⓘ second-brain — wiki maintenance suggested\n\nProject `%s` has accumulated %s wiki writes since the last consolidation.\nConsolidate the wiki with either:\n  • `/second-brain:maintain` — the knowledge-maintainer runs live (audit, dedup,\n    relate, enrich, ai-blocks, raw-inbox drain); bounded by a 50-change cap, reversible.\n  • `/second-brain:dream` — stages the changes for you to review before accepting.\n\nRe-appears next session if not run. Suppress entirely: `SB_MAINTAINER_AUTO=off`.\n\n' \
      "$slug" "$COUNT")
    sb_append "$BANNER" "maintainer-auto-banner" 400
    sb_log_error "session-load.sh" "maintainer-suggested slug=$slug count=$COUNT" 0
  fi
fi
PIN_COUNT=$(sb_count_pin_candidates "$slug")
if [ "$PIN_COUNT" -gt 0 ]; then
  sb_append "$(printf '## ⓘ second-brain — %s pin candidate(s) pending\nExtracted persona signals waiting in `~/.second-brain/projects/%s/.pin-candidates.jsonl`.\nRun: `Review pin candidates in second-brain and decide which to pin to USER.md.`\n\n' \
    "$PIN_COUNT" "$slug")" "pin-candidates-banner" 250
fi

# USER.md Never/Always rules vs persona-rules.default.json enforcement gap.
# USER.md text is advisory (injected as ambient context); only rules in
# persona-rules.default.json are HARD-ENFORCED at PreToolUse. If the user
# edits USER.md without updating the rules JSON, those edits never become
# blocking guards. Banner fires when USER.md is newer than the rules file,
# nudging the user to keep them in sync manually.
# Kill switch: SB_RULES_GAP_BANNER=off.
if [ "${SB_RULES_GAP_BANNER:-on}" != "off" ] && [ -f "$USER_FILE" ]; then
  RULES_FILE_RUNTIME="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}/scripts/persona-rules.default.json"
  if [ -f "$RULES_FILE_RUNTIME" ]; then
    UM_MT=$(stat -c %Y "$USER_FILE" 2>/dev/null || stat -f %m "$USER_FILE" 2>/dev/null || echo 0)
    PR_MT=$(stat -c %Y "$RULES_FILE_RUNTIME" 2>/dev/null || stat -f %m "$RULES_FILE_RUNTIME" 2>/dev/null | tr -d '\r' || echo 0)
    if [ "$UM_MT" -gt "$PR_MT" ]; then
      # awk range `/start/,/end/` matches the header line on both ends — so
      # `/^## Never/,/^## /` collapses to just the Never header itself and
      # never reaches the bullets. Use an explicit in-section flag instead.
      NEVER_COUNT=$(awk '
        /^## Never/ { in_s=1; next }
        /^## / && in_s { in_s=0 }
        in_s && /^- / { c++ }
        END { print c+0 }
      ' "$USER_FILE" 2>/dev/null)
      ALWAYS_COUNT=$(awk '
        /^## Always/ { in_s=1; next }
        /^## / && in_s { in_s=0 }
        in_s && /^- / { c++ }
        END { print c+0 }
      ' "$USER_FILE" 2>/dev/null)
      sb_append "$(printf '## ⓘ second-brain — USER.md rules are advisory, not enforced\nUSER.md has %s Never + %s Always bullet(s) but was modified after persona-rules.default.json. Tool-time blocking only happens for rules wired into `scripts/persona-rules.default.json` (the rules array). USER.md text reaches the model as context but does not block tool calls.\nTo make a Never rule hard-enforced, add it to the rules JSON. Suppress this banner: `SB_RULES_GAP_BANNER=off`.\n\n' \
        "$NEVER_COUNT" "$ALWAYS_COUNT")" "rules-gap-banner" 500
    fi
  fi
fi

# 0. Extractor health banner — surfaces silent LLM-extraction failures.
# Without this banner, broken `claude` CLI auth caused 113 consecutive stop-
# hook subprocess failures with zero user-visible signal — wiki/learnings
# stayed empty for days. Banner is HIGH priority so it lands first.
if [ -f "$SB_HEALTH_FILE" ] && command -v jq >/dev/null 2>&1; then
  H_STATUS=$(jq -r '.status // "unknown"' "$SB_HEALTH_FILE" 2>/dev/null)
  if [ "$H_STATUS" = "fail" ]; then
    H_BACKEND=$(jq -r '.backend // "unknown"' "$SB_HEALTH_FILE" 2>/dev/null | tr -d '\r')
    H_REASON=$(jq  -r '.reason  // ""'        "$SB_HEALTH_FILE" 2>/dev/null | tr -d '\r')
    H_AT=$(jq      -r '.checked_at // ""'     "$SB_HEALTH_FILE" 2>/dev/null | tr -d '\r')
    H_FAILS=$(sb_count_recent_extraction_failures)
    # Mode-aware hint. Previous single-template was telling users to "run
    # claude /login" on every failure — but the actual cause varies:
    #   - "auth:..." prefix (or "unauthorized"/"not logged in") → real auth fail
    #   - "non-json:..." → the LLM editorialized instead of returning JSON
    #   - "empty after pty-retry..." / ec=124 timeouts → claude CLI hanging,
    #     usually recursive-claude conflict; fix is ANTHROPIC_API_KEY backstop
    #   - "api:..." → ANTHROPIC_API_KEY call failed (rate limit / billing)
    case "$H_REASON" in
      auth:*|*unauthorized*|*"not logged in"*|*"please run /login"*|*"invalid api key"*)
        H_HINT="fix: run \`claude /login\` (OAuth) or \`export ANTHROPIC_API_KEY=sk-ant-...\` (API key)."
        ;;
      non-json:*|pty-retry-non-json:*)
        H_HINT="cause: extractor LLM returned prose instead of JSON. fix: re-run with a fresh session; persistent failures usually mean the system prompt was truncated — check scripts/extract-prompt.txt."
        ;;
      empty*|*timeout*|*ec=124*)
        H_HINT="cause: \`claude\` CLI hung past the timeout (recursive-claude / OAuth conflict). fix: \`export ANTHROPIC_API_KEY=sk-ant-...\` so lib.sh uses the direct-API backstop instead of the recursive CLI path."
        ;;
      api:*)
        H_HINT="cause: ANTHROPIC_API_KEY call failed (rate limit / billing / model name). fix: check \`echo \$ANTHROPIC_API_KEY | head -c 10\` and Anthropic console quotas."
        ;;
      *)
        H_HINT="fix: run \`claude /login\` (OAuth) or \`export ANTHROPIC_API_KEY=sk-ant-...\`; tail \`~/.second-brain/error-log.jsonl\` for the underlying diag line."
        ;;
    esac
    HEALTH_BANNER=$(printf '## ⚠ second-brain extractor: FAILED\nbackend=%s checked=%s recent_failures=%s\nreason: %s\nimpact: Stop/PreCompact hooks not writing wiki learnings — session insights are lost on exit.\n%s\n\n' \
      "$H_BACKEND" "$H_AT" "$H_FAILS" "$H_REASON" "$H_HINT")
    sb_append "$HEALTH_BANNER" "extractor-health-banner" 800
  fi
fi

# 0a-quater. Out-of-band DRAINER health banner — the silent-failure gap (root
# cause #2). The 0-block above keys on .extractor-health.json status=="fail"; but
# the common breakage is INVISIBLE to it: the in-session hook writes status==
# "queued" (correctly deferring OAuth), while the OUT-OF-BAND extract-drain.sh
# dies with ec=124 timeouts logged at exit_code:0 (TRACE) — 0 lines say
# "llm-extraction-failed", so neither the fail-banner nor sb_count_recent_extraction_failures
# fire. This banner keys on the ACTUAL signatures the drainer leaves: ec=124
# timeouts and poison-pilled (terminal-error) transcripts, and is OS-aware. The
# quarantine signal is deliberately NOT included — dream-autostage.sh already owns
# the .llm-maintain-quarantine banner; duplicating it would double-fire on the same
# SessionStart. Mutually exclusive with the FAILED banner above (suppress when
# H_STATUS==fail). Kill switch: SB_DRAIN_HEALTH_BANNER=off. Fail-open.
if [ "${SB_DRAIN_HEALTH_BANNER:-on}" != "off" ] && [ "${H_STATUS:-}" != "fail" ]; then
  DRAIN_TO_THRESH="${SB_DRAIN_TIMEOUT_BANNER_THRESHOLD:-3}"; case "$DRAIN_TO_THRESH" in ''|*[!0-9]*) DRAIN_TO_THRESH=3 ;; esac
  DEAD_THRESH="${SB_DRAIN_DEADLETTER_THRESHOLD:-5}"; case "$DEAD_THRESH" in ''|*[!0-9]*) DEAD_THRESH=5 ;; esac
  DRAIN_TO_N=$(sb_count_drain_timeouts 40)
  DEAD_N=$(sb_count_drain_dead_letters)
  # Two OR'd triggers (quarantine is owned by dream-autostage.sh, not here).
  if [ "${DRAIN_TO_N:-0}" -ge "$DRAIN_TO_THRESH" ] || [ "${DEAD_N:-0}" -ge "$DEAD_THRESH" ]; then
    DRAIN_WHY=""
    [ "${DRAIN_TO_N:-0}" -ge "$DRAIN_TO_THRESH" ] && DRAIN_WHY="${DRAIN_TO_N} recent drain timeout(s) (ec=124 — the extractor hangs past its deadline)"
    [ "${DEAD_N:-0}" -ge "$DEAD_THRESH" ] && DRAIN_WHY="${DRAIN_WHY:+$DRAIN_WHY; }${DEAD_N} transcript(s) permanently failed extraction (poison-pilled)"
    [ -n "$DRAIN_WHY" ] || DRAIN_WHY="the out-of-band extractor is not draining"
    # OS-AWARE remedy. Linux: the drainer CAN run (bwrap) — raise the timeout (or
    # install bubblewrap if missing). macOS/Windows: no bwrap-contained headless
    # path — consolidate IN-SESSION via /second-brain:maintain or /second-brain:dream.
    case "$(uname -s)" in
      Linux)
        if command -v bwrap >/dev/null 2>&1; then
          DRAIN_FIX="fix: the drainer is timing out — raise the deadline: \`export SB_DRAIN_EXTRACT_TIMEOUT=300\` (default 240s; a Pi/slow box may need more). If you have an API key, \`export ANTHROPIC_API_KEY=sk-ant-...\` removes the recursive-claude hang entirely."
        else
          DRAIN_FIX="fix: install the sandbox the headless drainer needs — \`sudo apt install bubblewrap\` — then raise the deadline if needed: \`export SB_DRAIN_EXTRACT_TIMEOUT=300\`."
        fi
        ;;
      Darwin|MINGW*|MSYS*|CYGWIN*)
        DRAIN_FIX="fix: the bubblewrap-contained out-of-band drainer does not run on this OS, so consolidate IN-SESSION: run \`/second-brain:maintain\` (live) or \`/second-brain:dream\` (staged for review). An \`export ANTHROPIC_API_KEY=sk-ant-...\` also enables in-session capture at every Stop."
        ;;
      *)
        DRAIN_FIX="fix: run \`/second-brain:maintain\` to consolidate in-session, or set \`export ANTHROPIC_API_KEY=sk-ant-...\` for in-session capture. Tail \`~/.second-brain/error-log.jsonl\` for the ec=124 diag lines."
        ;;
    esac
    sb_append "$(printf '## \xe2\x9a\xa0 second-brain — background extraction is failing silently\nsignal: %s\nimpact: session insights are NOT reaching the wiki/learnings — they are lost on exit.\n%s\nSuppress: \x60SB_DRAIN_HEALTH_BANNER=off\x60.\n\n' "$DRAIN_WHY" "$DRAIN_FIX")" "drain-health-banner" 700
    sb_log_error "session-load.sh" "drain-health: timeouts=${DRAIN_TO_N} dead=${DEAD_N} os=$(uname -s)" 0
  fi
fi

# 0a-bis. Auth-mode line — one quiet line so the user always knows which
# credential path the extractor will use this session. Critical for the dual-
# auth UX (Claude subscription vs Anthropic API key): without this banner,
# new machines silently default to OAuth-only and the user only discovers the
# in-session limitation when they notice extractor failures days later.
# Suppress: SB_AUTH_LINE=off
if [ "${SB_AUTH_LINE:-on}" = "on" ]; then
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    AUTH_PREFIX="${ANTHROPIC_API_KEY:0:10}"
    sb_append "$(printf '## ⓘ second-brain auth\nmode: api-key (key: %s…, len=%s) — direct anthropic-api, works in all contexts.\n\n' \
      "$AUTH_PREFIX" "${#ANTHROPIC_API_KEY}")" "auth-mode-line" 220
  elif command -v claude >/dev/null 2>&1; then
    sb_append "$(printf '## ⓘ second-brain auth\nmode: subscription (OAuth) — in-session Stop/PreCompact extraction will queue (recursive-claude lock).\nfix to enable in-session extraction: `export ANTHROPIC_API_KEY=sk-ant-...` or run `sb auth doctor`.\n\n')" "auth-mode-line" 350
  else
    sb_append "$(printf '## ⚠ second-brain auth\nmode: none — neither ANTHROPIC_API_KEY nor `claude` CLI is available. Run `sb auth doctor`.\n\n')" "auth-mode-line" 220
  fi
fi

# 0a-ter. Capture-health self-check — the "wired != works" guard, AUTH-AWARE.
# Claude is the universal engine. An API key extracts IN-SESSION at every Stop
# (Backend 2 curl) with no daemon — so an api-key user is NOT nagged to install the
# out-of-band bridge; we only flag a real extraction failure. OAuth is recursive-
# locked in-session, so it genuinely needs an out-of-band path — offer all three
# (api-key / drainer / local). `none` is already covered by the auth-mode-line.
# Suppress: SB_CAPTURE_HEALTH_BANNER=off.
if [ "${SB_CAPTURE_HEALTH_BANNER:-on}" = "on" ]; then
  CAP_STATE="$BRAIN_DIR/.extraction-state.jsonl"
  CAP_N=$(ls -1 "$BRAIN_DIR/transcripts"/*.txt 2>/dev/null | wc -l | tr -d ' ')
  if [ "${CAP_N:-0}" -gt 0 ]; then
    CAP_DONE=0
    [ -f "$CAP_STATE" ] && CAP_DONE=$(grep -c '"outcome":"ok"' "$CAP_STATE" 2>/dev/null)
    [ -n "$CAP_DONE" ] || CAP_DONE=0
    # Per-OS scheduler probe (else it false-alarms "no timer" off Linux).
    CAP_TIMER=no
    case "$(uname -s)" in
      Linux)               systemctl --user is-active sb-extract-drain.timer >/dev/null 2>&1 && CAP_TIMER=yes ;;
      Darwin)              launchctl print "gui/$(id -u)/sb-extract-drain" >/dev/null 2>&1 && CAP_TIMER=yes ;;
      MINGW*|MSYS*|CYGWIN*) schtasks /Query /TN sb-extract-drain >/dev/null 2>&1 && CAP_TIMER=yes ;;
      *)                   CAP_TIMER=unknown ;;   # unobservable — don't assert "no timer"
    esac
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      # API key: capture runs in-session — the drainer is unnecessary, so NEVER the
      # install-the-bridge nag. But still surface a genuine "wired != works": a failed
      # attempt, OR transcripts piling up with no extraction ever recorded (the Stop
      # hook may not be firing). Never mentions the drainer.
      CAP_HEALTH=$(jq -r '.status // ""' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null | tr -d '\r')
      if [ "$CAP_HEALTH" = "fail" ]; then
        CAP_REASON=$(jq -r '.reason // ""' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null | tr '\n' ' ' | head -c 160 | tr -d '\r')
        sb_append "$(printf '## ⚠ second-brain — extraction failing (API key)\nLast attempt failed: %s\nCheck the key/quota; tail `~/.second-brain/error-log.jsonl`.\n\n' "$CAP_REASON")" "capture-health-banner" 400
      elif [ ! -f "$BRAIN_DIR/.extractor-health.json" ]; then
        sb_append "$(printf '## ⚠ second-brain — no extraction recorded\n%s transcript(s) archived but the in-session extractor has never run — the Stop/PreCompact hook may not be firing. Tail `~/.second-brain/error-log.jsonl`.\n\n' "$CAP_N")" "capture-health-banner" 400
      fi
    elif command -v claude >/dev/null 2>&1; then
      # OAuth subscription: in-session queues (recursive-claude lock). Needs an
      # out-of-band path — present all three, API key first (zero-setup, any OS).
      if [ "$CAP_DONE" -eq 0 ] || [ "$CAP_TIMER" = "no" ]; then
        # shellcheck disable=SC2016  # literal $CLAUDE_PLUGIN_ROOT for the user to run
        sb_append "$(printf '## ⚠ second-brain — capture not running (OAuth)\n%s transcript(s) archived, %s extracted; drainer timer: %s. Subscription auth can'\''t extract in-session (recursive-claude lock), so pick one:\n  • `export ANTHROPIC_API_KEY=sk-ant-...`  — instant in-session capture, any OS, no daemon\n  • `bash $CLAUDE_PLUGIN_ROOT/scripts/install-extract-timer.sh --apply --oauth`  — out-of-band drainer via your Claude login\n  • `export SB_EXTRACTOR_LOCAL_URL=http://localhost:11434`  — a local model (offline)\nSuppress: `SB_CAPTURE_HEALTH_BANNER=off`.\n\n' "$CAP_N" "$CAP_DONE" "$CAP_TIMER")" "capture-health-banner" 700
      else
        sb_append "$(printf '## ⓘ second-brain capture: %s archived · %s extracted · timer active.\n\n' "$CAP_N" "$CAP_DONE")" "capture-health-line" 200
      fi
    fi
  fi
fi

# 0b. Episodic embeddings banner — surfaces missing native deps that prevent
# vector search over transcripts. Production bug 2026-05-22: 976/981 exchanges
# had embedding:[] because @huggingface/transformers was --external in the
# bundle but never installed under the plugin cache. A plugin cache refresh
# ships dist/ but NEVER node_modules/, so the dep goes missing on every version
# bump. Two OR'd triggers (both gated on an index already existing, so brand-new
# installs with no transcripts aren't nagged):
#   (1) deps-absent — node_modules/@huggingface/transformers missing. Fires
#       IMMEDIATELY after a cache refresh; the index-state check (2) can't catch
#       this because the old index still holds its embeddings, so it would stay
#       silent until 11+ NEW exchanges rotted with empty embeddings.
#   (2) pending — >10 already-indexed exchanges have empty embeddings.
SB_EPI_INDEX="${BRAIN_DIR:-$HOME/.second-brain}/episodic-index.json"
if [ -f "$SB_EPI_INDEX" ] && command -v jq >/dev/null 2>&1; then
  EPI_PENDING=$(jq -r '[.exchanges[]? | select((.embedding|length)==0)] | length' "$SB_EPI_INDEX" 2>/dev/null | tr -d '\r' || echo 0)
  EPI_TOTAL=$(jq -r   '.exchanges | length'                                       "$SB_EPI_INDEX" 2>/dev/null | tr -d '\r' || echo 0)
  EPI_XFMR_MISSING=0
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ ! -d "$CLAUDE_PLUGIN_ROOT/mcp/node_modules/@huggingface/transformers" ] && EPI_XFMR_MISSING=1
  # R2.4 auto-heal (MCP-DEPS-1): a fresh version dir missing the shared-deps
  # symlink is a pure LOCAL relink — no download, no consent needed. Try it
  # before bannering; the manual banner remains for the genuinely-broken cases
  # (no shared tree / key drift / import failure → installer exits 3). The
  # pending-count nag is also suppressed for this one session: empty embeddings
  # backfill on the next session-end indexer run.
  EPI_RELINKED=0
  if [ "$EPI_XFMR_MISSING" -eq 1 ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] \
     && [ -f "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh" ] \
     && bash "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh" --relink-only >/dev/null 2>&1; then
    EPI_XFMR_MISSING=0; EPI_RELINKED=1
    sb_append "$(printf '## ⓘ second-brain — embeddings auto-relinked\nThis plugin version was missing its shared vector-deps symlink (a cache refresh ships without node_modules); re-linked automatically — no download. Empty embeddings backfill on the next session-end extraction.\n\n')" "episodic-embed-relinked" 300
  fi
  if [ "${SB_EMBED_PENDING_BANNER:-on}" = "on" ] && [ "$EPI_RELINKED" -eq 0 ] \
     && { [ "$EPI_XFMR_MISSING" -eq 1 ] || { [ "${EPI_PENDING:-0}" -gt 10 ] && [ "${EPI_TOTAL:-0}" -gt 0 ]; }; }; then
    if [ "$EPI_XFMR_MISSING" -eq 1 ]; then
      EPI_REASON='`@huggingface/transformers` is not linked in this plugin cache — a version bump creates a fresh dir whose `mcp/node_modules` symlink to the shared deps is not yet created — so every NEW embedding will silently fail.'
    else
      EPI_REASON="$EPI_PENDING of $EPI_TOTAL indexed exchanges have no embedding (text search works; vector / mode=both will miss them)."
    fi
    EPI_BANNER=$(printf '## ⓘ second-brain — episodic vector search degraded\n%s\nfix: `bash $CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh` (re-links the shared deps; downloads ~70MB only on the first ever install). To re-embed existing exchanges, back up & remove `%s`, then run the episodic indexer.\nSuppress: `SB_EMBED_PENDING_BANNER=off`.\n\n' \
      "$EPI_REASON" "$SB_EPI_INDEX")
    sb_append "$EPI_BANNER" "episodic-embed-pending-banner" 800
  fi
fi

# 0c. Graph-conflict banner — structural edge contradictions flagged at write time by
# merge-edges.sh (graph/conflicts.jsonl). HIGH priority (a correctness signal): emitted
# in the early-banner region, BEFORE the uncapped USER.md/PROJECT.md draw down the budget,
# so it can never be the item silently dropped at the ceiling. Drained by the
# knowledge-maintainer Phase 3 RELATE. No file ⇒ no line (back-compat).
SL_KDIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"; SL_KDIR="${SL_KDIR/#\~/$HOME}"
CONFLICT_N=$(sb_conflicts_open_count "$SL_KDIR")
if [ "${CONFLICT_N:-0}" -gt 0 ]; then
  sb_append "$(printf '## ⚠ second-brain — %s graph conflict(s) pending\nStructural edge contradictions were detected at write time. Resolve via the knowledge-maintainer (Phase 3 RELATE) or `knowledge_relate`.\n\n' "$CONFLICT_N")" \
    "graph-conflicts-banner" 250
fi

# 1. USER.md — always included
if [ -f "$USER_FILE" ]; then
  USER_CONTENT=$(cat "$USER_FILE")
  # force = always land (priority-1 human rules), but cap at 6000B (USER.md is designed ≤~3200B)
  # so even after banners the total stays under Claude Code's ~10K hook-output ceiling.
  sb_append "$USER_CONTENT" "USER.md" 6000 force
fi

# 2. Persona signals — capped at 600 bytes
PERSONA_FILE="$BRAIN_DIR/persona-signals.jsonl"
if [ -f "$PERSONA_FILE" ] && [ -s "$PERSONA_FILE" ] && command -v jq >/dev/null 2>&1; then
  # Display window for ungraduated persona signals in the SessionStart banner.
  # Distinct from merge-persona-signals.sh's 90-day RETENTION prune: the file keeps
  # 90 days; this only chooses how recent a signal must be to be SHOWN.
  PERSONA_WINDOW_DAYS="${SB_PERSONA_SIGNAL_WINDOW_DAYS:-30}"
  case "$PERSONA_WINDOW_DAYS" in ''|*[!0-9]*) PERSONA_WINDOW_DAYS=30 ;; esac
  THIRTY_DAYS_AGO=$(date -u -v-"${PERSONA_WINDOW_DAYS}"d +%Y-%m-%d 2>/dev/null \
    || date -u -d "${PERSONA_WINDOW_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
    || echo "1970-01-01")

  SIGNALS=$(jq -rs --arg cutoff "$THIRTY_DAYS_AGO" '
    [.[] | select(
      .last_seen >= $cutoff and
      .graduated == false and
      .count >= 2
    )]
    | sort_by(-.count)
    | .[0:5]
    | .[] | "- [\(.category)] \(.signal) (seen \(.count)x)"
  ' "$PERSONA_FILE" 2>/dev/null)

  if [ -n "$SIGNALS" ]; then
    PERSONA_BLOCK=$(printf '\n## Observed patterns (from session history, not yet graduated to USER.md)\n%s\n' "$SIGNALS")
    sb_append "$PERSONA_BLOCK" "persona-signals" 600
  fi
fi

# 2b. Persona card + installed-catalog SessionStart injection REMOVED (0.32.0): USER.md
# (force-emitted above) now carries the unique identity, so the card was a redundant paraphrase
# and the catalog was per-session noise. persona-card.md is still seeded (persona-stats reads it).

# 3. PROJECT.md — always included (the project hot tier). It is priority-1 context like
# USER.md, so `force` it past the byte budget (otherwise earlier conditional banners can
# spend the budget and SILENTLY DROP the project's whole context — the sibling of the
# 0.24.16 USER.md bug). Capped at 3000B so PROJECT.md + USER.md (6000) + budget-bounded
# banners stay under Claude Code's ~10K hook-output ceiling; SP-E's [degraded] routing
# keeps it from bloating.
if [ -f "$project_file" ]; then
  PROJ_CONTENT=$(printf '\n%s' "$(cat "$project_file")")
  sb_append "$PROJ_CONTENT" "PROJECT.md" 3000 force

  # M3: a one-line, glanceable confirmation of WHICH project scope loaded — so a wrong
  # cwd→slug resolution (the root cause of cross-project leak) is caught immediately, and
  # the plan's open/total is surfaced so focus is visible. Forced (tiny, priority-1
  # transparency). Kill switch: SB_SCOPE_BANNER=off.
  if [ "${SB_SCOPE_BANNER:-on}" != "off" ]; then
    PLAN_OPEN=$(awk '/^## Plan$/{f=1;next} /^## /{f=0} f && /^- \[ \]/{c++} END{print c+0}' "$project_file")
    PLAN_TOTAL=$(awk '/^## Plan$/{f=1;next} /^## /{f=0} f && /^- / && !/\[pinned\]/{c++} END{print c+0}' "$project_file")
    DEC_N=$(awk '/^## Recent decisions$/{f=1;next} /^## /{f=0} f && /^- /{c++} END{print c+0}' "$project_file")
    BLK_N=$(awk '/^## Open blockers$/{f=1;next} /^## /{f=0} f && /^- \[active\]/{c++} END{print c+0}' "$project_file")
    sb_append "$(printf '\n✓ second-brain: project memory loaded — %s (plan %s/%s · %s decisions · %s active blockers)\n' \
      "$slug" "$PLAN_OPEN" "$PLAN_TOTAL" "$DEC_N" "$BLK_N")" "scope-banner" 200 force
  fi
fi

# 4. Index line — tiny, always fits
if [ -f "$INDEX_FILE" ]; then
  IDX_LINE=$(printf '\n%s' "$(jq --arg s "$slug" -r 'select(.slug == $s)' "$INDEX_FILE" 2>/dev/null | head -1)")
  sb_append "$IDX_LINE" "index-line" 200
fi

# 5. Wiki enrichment — fills remaining budget, capped at 1500 bytes
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SEARCH_CLI="$PLUGIN_ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"

if [ -f "$project_file" ] && [ -f "$SEARCH_CLI" ] && command -v node >/dev/null 2>&1; then
  STOP_RE='(the|a|an|is|are|was|were|will|be|have|has|had|do|does|did|can|could|should|would|to|of|in|for|on|at|by|with|from|and|but|or|not|no|this|that|auto|scaffolded|describe|active|resolved|stale|decision|pinned|project|goal|state|open|recent|cross|references|conventions)'

  # In-section FLAGS, not awk range expressions: a range `/^## X$/,/^## /` collapses to
  # the single header line because the START line ALSO matches the `^## ` END pattern —
  # so the harvest was ALWAYS empty and the whole wiki-enrichment block below never ran
  # (every session started missing its project's wiki recall). Same trap the comment at
  # ~line 188 already fixed for the Never-rules block; this one was left unfixed.
  PROJ_KW=$(awk '
    /^## (Goal|State|Conventions)$/ { f=1; next }
    /^## Recent decisions$/         { f=2; next }
    /^## Open blockers$/            { f=3; next }
    /^## Cross-references$/         { f=4; next }
    /^## /                          { f=0 }
    f==1 && NF>0 && !/^\(auto-scaffolded/   { print }
    (f==2 || f==3) && /^- /                 { print }
    f==4 && /\[\[/ { gsub(/[\[\]]/, ""); print }
  ' "$project_file" 2>/dev/null | \
    tr -cs '[:alpha:]' '\n' | \
    grep -vxiE "$STOP_RE" | \
    sort -u | head -10 | tr '\n' ' ')

  if [ -n "${PROJ_KW// /}" ]; then
    # SP-1: scope the session-start wiki enrichment to the active project, same as the
    # per-prompt path (persona-context.sh) — one chokepoint, consistent scoping both surfaces.
    WIKI_HITS=$(KNOWLEDGE_DIR="$KNOWLEDGE_DIR" BRAIN_DIR="$BRAIN_DIR" SB_ACTIVE_SLUG="$slug" node "$SEARCH_CLI" "$PROJ_KW" 2>/dev/null || true)
    if [ -n "$WIKI_HITS" ]; then
      sb_append "$(printf '\n%s' "$WIKI_HITS")" "wiki-enrichment" 1500
    fi
  fi
fi

# 5-raw. SP-2: raw-inbox backlog — surface how many unprocessed items await processing
# for this project, so the user knows there's material to refine. Kill switch SB_RAW_INBOX=off.
if [ "${SB_RAW_INBOX:-on}" != "off" ]; then
  RAW_DIR_PATH="$BRAIN_DIR/projects/$slug/raw"
  if [ -d "$RAW_DIR_PATH" ]; then
    # "open" = items not yet processed/discarded = unprocessed + malformed, matching the module's
    # unprocessedCount (which counts malformed items as backlog). total - closed; mawk-free.
    RAW_TOTAL=$(find "$RAW_DIR_PATH" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    RAW_CLOSED=$(grep -rlE '^status: (processed|discarded)$' "$RAW_DIR_PATH" 2>/dev/null | wc -l | tr -d ' ')
    RAW_N=$(( ${RAW_TOTAL:-0} - ${RAW_CLOSED:-0} ))
    if [ "${RAW_N:-0}" -gt 0 ]; then
      # B1 (SP-B): when material is genuinely piling up AND auto-consolidation is OFF,
      # show the self-install nudge instead of the plain backlog line (mutually
      # exclusive — one banner per session, no fatigue). The nudge is honest about the
      # two remedies: auto_improve auto-upkeeps STRUCTURE (validate/reindex), /maintain
      # AUTHORS the backlog (needs a Claude session). Kill switch SB_AUTOCONSOLIDATE_NUDGE=off.
      NUDGE_THRESH="${SB_NUDGE_RAW_THRESHOLD:-20}"; case "$NUDGE_THRESH" in ''|*[!0-9]*) NUDGE_THRESH=20 ;; esac
      if [ "${SB_AUTOCONSOLIDATE_NUDGE:-on}" != "off" ] \
         && [ "$(sb_config_bool .auto_improve on)" = "off" ] \
         && [ "${RAW_N:-0}" -ge "$NUDGE_THRESH" ]; then
        sb_append "$(printf '## ⓘ second-brain — auto-consolidation is off\n%s raw item(s) are piling up with nothing consolidating them automatically. Pick one:\n  • auto-upkeep:  set `auto_improve: true` in ~/.second-brain/config.json (keeps the wiki validated + reindexed on the drainer timer)\n  • author them:  /second-brain:maintain (refines raw items into wiki notes — needs a Claude session)\nSuppress: `SB_AUTOCONSOLIDATE_NUDGE=off`.\n\n' "$RAW_N")" "autoconsolidate-nudge" 450
      else
        sb_append "$(printf '## ⓘ raw inbox — %s unprocessed item(s)\nThe maintainer drains these into wiki notes automatically (auto_maintain / the drainer timer); run `/second-brain:maintain` to do it now.\n\n' "$RAW_N")" \
          "raw-inbox-banner" 250
      fi
    fi
  fi
fi

# 5a. Graph neighbourhood — current typed dependencies of the project's key
# entities (the Cross-references slugs). Surfaces "changing A affects/requires
# B,C,D" in the hot tier so a fresh session recalls the dependency web without
# re-explaining. No-op when the graph CLI or edges.jsonl is absent (back-compat).
GRAPH_CLI="$PLUGIN_ROOT/mcp/dist/tools/graph-neighbors-cli.bundle.js"
if [ -f "$project_file" ] && [ -f "$GRAPH_CLI" ] && [ -f "$KNOWLEDGE_DIR/graph/edges.jsonl" ] && command -v node >/dev/null 2>&1; then
  # Up to 4 cross-reference slugs from PROJECT.md as graph entry points.
  CR_SLUGS=$(awk '
    /^## Cross-references$/ { f=1; next }
    /^## / { f=0 }
    f && /\[\[/ {
      line=$0
      while (match(line, /\[\[[^]]+\]\]/)) {
        s=substr(line, RSTART+2, RLENGTH-4); print s
        line=substr(line, RSTART+RLENGTH)
      }
    }
  ' "$project_file" 2>/dev/null | sort -u | head -4)
  GRAPH_OUT=""
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    nbr=$(KNOWLEDGE_DIR="$KNOWLEDGE_DIR" node "$GRAPH_CLI" "$s" 1 both 2>/dev/null \
      | awk -F'\t' '{ printf "%s %s %s; ", $2, $1, $3 }')
    [ -n "$nbr" ] && GRAPH_OUT="${GRAPH_OUT}- ${s}: ${nbr}\n"
  done <<< "$CR_SLUGS"
  if [ -n "$GRAPH_OUT" ]; then
    sb_append "$(printf '\n[Dependency graph — current typed relations (as of today)]\n%b' "$GRAPH_OUT")" "graph-neighbourhood" 600
  fi
fi

# 6. Dream completion nudge (SP-C) — surface dreams AWAITING REVIEW only:
# status=="completed" AND archived_at is unset. accept/discard stamp archived_at while
# leaving status "completed", so WITHOUT the archived_at guard an already-applied dream
# re-nags every session (the reported bug — every other consumer honours archived_at).
# A genuinely-stale unaccepted dream (age > SB_DREAM_STALE_DAYS) gets a louder, distinct
# banner. Age = status.json mtime (≈ completion time until archived; portable stat, no GNU date-parsing).
DREAMS_DIR="$BRAIN_DIR/dreams"
if [ -d "$DREAMS_DIR" ] && command -v jq >/dev/null 2>&1; then
  STALE_DAYS="${SB_DREAM_STALE_DAYS:-7}"; case "$STALE_DAYS" in ''|*[!0-9]*) STALE_DAYS=7 ;; esac
  NOW_S=$(date +%s)
  PEND_N=0; PEND_ID=""; PEND_A=0; PEND_M=0
  STALE_N=0; STALE_ID=""; STALE_AGE=0; STALE_A=0; STALE_M=0; STALE_OLDEST=""
  for sf in "$DREAMS_DIR"/drm_*/status.json; do
    [ -f "$sf" ] || continue
    [ "$(jq -r '.status // ""' "$sf" 2>/dev/null)" = "completed" ] || continue
    DARCH=$(jq -r '.archived_at // ""' "$sf" 2>/dev/null | tr -d '\r')
    { [ -n "$DARCH" ] && [ "$DARCH" != "null" ]; } && continue   # terminal (accepted/discarded) → silent
    DID=$(jq -r '.id // ""' "$sf" 2>/dev/null | tr -d '\r')
    DA=$(jq -r '.outputs.pages_added // 0' "$sf" 2>/dev/null | tr -d '\r')
    DM=$(jq -r '.outputs.pages_modified // 0' "$sf" 2>/dev/null | tr -d '\r')
    SMT=$(stat -c %Y "$sf" 2>/dev/null || stat -f %m "$sf" 2>/dev/null || echo "$NOW_S")
    AGE_D=$(( (NOW_S - ${SMT:-$NOW_S}) / 86400 ))
    if [ "$AGE_D" -gt "$STALE_DAYS" ]; then
      STALE_N=$((STALE_N + 1))
      if [ -z "$STALE_OLDEST" ] || [ "${SMT:-0}" -lt "$STALE_OLDEST" ]; then
        STALE_OLDEST="$SMT"; STALE_ID="$DID"; STALE_AGE="$AGE_D"; STALE_A="$DA"; STALE_M="$DM"
      fi
    else
      PEND_N=$((PEND_N + 1))
      [ -z "$PEND_ID" ] && { PEND_ID="$DID"; PEND_A="$DA"; PEND_M="$DM"; }
    fi
  done
  if [ "$STALE_N" -gt 0 ]; then
    SX=""; [ "$STALE_N" -gt 1 ] && SX=" (+$((STALE_N - 1)) more awaiting review)"
    sb_append "$(printf '\n[⚠ Dream %s finished ~%sd ago and is still UNREVIEWED: +%s added, ~%s modified — these changes are NOT in your wiki yet. Run /second-brain:dream to accept or discard.%s]' "$STALE_ID" "$STALE_AGE" "$STALE_A" "$STALE_M" "$SX")" "dream-stale-nudge" 340
  elif [ "$PEND_N" -gt 0 ]; then
    PX=""; [ "$PEND_N" -gt 1 ] && PX=" (+$((PEND_N - 1)) more)"
    sb_append "$(printf '\n[Dream %s completed: +%s added, ~%s modified — run /second-brain:dream to review and accept/discard.%s]' "$PEND_ID" "$PEND_A" "$PEND_M" "$PX")" "dream-nudge" 300
  fi
fi

# --- Emit collected output ---
cat "$OUTPUT_FILE"
rm -f "$OUTPUT_FILE" "${_proj_lf:-}"   # _proj_lf is the CRLF-normalized PROJECT.md copy (only set when a CR was present)

# --- Bookkeeping (no output) ---
if [ "$USED" -gt "$BYTE_BUDGET" ]; then
  sb_log_error "session-load.sh" "hot-tier exceeded byte budget: $USED > $BYTE_BUDGET" 0
fi

if [ -f "$INDEX_FILE" ] && command -v jq >/dev/null 2>&1; then
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  TMP_IDX=$(mktemp)
  jq --arg s "$slug" --arg t "$TS" --arg p "$parent" --arg rp "$root_path" --arg gr "$git_remote" '
    if .slug == $s then
      .last_session_iso = $t
      | (if $rp != "" then .root_path  = $rp else . end)
      | (if $gr != "" then .git_remote = $gr else . end)
      | (if $p  != "" then .parent = $p  else del(.parent) end)
    else . end
  ' "$INDEX_FILE" > "$TMP_IDX" 2>/dev/null && mv "$TMP_IDX" "$INDEX_FILE" || rm -f "$TMP_IDX"
fi

# --- Stale wiki/index.md auto-reindex (background, no output) ---
# Decoupled from extraction success: when LLM extraction is broken for days,
# manual /pin or /archive writes still happen but reindex never fires. This
# closes that gap by triggering reindex if the index is >24h old.
WIKI_INDEX="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}/wiki/index.md"
WIKI_INDEX="${WIKI_INDEX/#\~/$HOME}"
if [ -f "$WIKI_INDEX" ]; then
  INDEX_MTIME=$(stat -c %Y "$WIKI_INDEX" 2>/dev/null || stat -f %m "$WIKI_INDEX" 2>/dev/null || echo 0)
  NOW_S=$(date +%s)
  INDEX_AGE_S=$((NOW_S - INDEX_MTIME))
  if [ "$INDEX_AGE_S" -gt 86400 ]; then
    (
      sb_reindex_wiki "${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}" >/dev/null 2>&1 || true
    ) &
    disown 2>/dev/null || true
  fi
fi

exit 0
