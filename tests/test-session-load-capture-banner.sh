#!/bin/bash
# Auth-aware SessionStart capture self-check (U5 0.24.18 + SP-1 0.24.19).
#  - API key  → extraction runs IN-SESSION at every Stop (Backend 2 curl); the
#    out-of-band drainer is NOT needed → no "install the bridge" nag.
#  - OAuth    → in-session is recursive-locked → needs drainer/local/key → nag WITH all 3 options.
#  - none     → the auth-mode-line already covers it → no double-nag here.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
# $1 = brain dir, $2 = ANTHROPIC_API_KEY value ("" = OAuth). A stub `claude`
# goes on PATH so the OAuth premise holds on hosts WITHOUT the real CLI (CI
# runners) — the auth probe otherwise resolves "none" and the auth banner
# displaces the capture banner this test asserts.
STUB_BIN=$(mktemp -d); printf '#!/bin/bash\nexit 0\n' > "$STUB_BIN/claude"; chmod +x "$STUB_BIN/claude"
emit(){ printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' | env PATH="$STUB_BIN:$PATH" ANTHROPIC_API_KEY="$2" BRAIN_DIR="$1" bash "$SL" 2>/dev/null; }

B=$(mktemp -d); mkdir -p "$B/transcripts"; : > "$B/transcripts/s1.txt"; : > "$B/USER.md"; touch -t 202001010000 "$B/USER.md"   # transcripts, none drained, no timer

# 1. OAuth (no key) → SHOUT + offer all three paths
oauth=$(emit "$B" "")
echo "$oauth" | grep -qi 'capture not running' || fail "OAuth: no capture-not-running banner (got: $(echo "$oauth" | head -c 200))"
pass "OAuth: shouts capture not running"
# anchor to a banner-UNIQUE string (the auth-mode-line also mentions ANTHROPIC_API_KEY)
echo "$oauth" | grep -q 'instant in-session capture' || fail "OAuth capture banner must offer the API-key path (unique string)"
echo "$oauth" | grep -q 'install-extract-timer.sh' || fail "OAuth banner must offer the drainer path"
pass "OAuth banner offers API-key + drainer (+ local) options"

# 2. API key set → NEVER the drainer-install nag (in-session needs no drainer)
apikey=$(emit "$B" "sk-ant-test")
echo "$apikey" | grep -q 'install-extract-timer' && fail "API-key user wrongly told to install the drainer (in-session capture needs none)" || pass "API-key: no drainer-install nag"
# 2b. but a genuine silent failure (transcripts piling up, nothing extracted) is still surfaced
echo "$apikey" | grep -qiE 'no extraction recorded|extraction failing' || fail "API-key with 0 extraction should still warn (the silent-failure gap)"
pass "API-key: surfaces a real silent failure (without the drainer nag)"

# 3. kill switch
SB_CAPTURE_HEALTH_BANNER=off emit "$B" "" | grep -qi 'capture not running' && fail "kill switch did not suppress" || pass "SB_CAPTURE_HEALTH_BANNER=off suppresses"

# 4. no transcripts → silent (fresh install isn't nagged)
B2=$(mktemp -d); : > "$B2/USER.md"; touch -t 202001010000 "$B2/USER.md"
emit "$B2" "" | grep -qi 'capture not running' && fail "nagged a fresh install (no transcripts)" || pass "silent on fresh install"

# --- Task 5: self-healing capture banner. OAuth + no timer + CLAUDE_PLUGIN_ROOT set →
# session-load runs `install-extract-timer.sh --ensure` ONCE and reports the outcome, instead
# of only nagging. We point CLAUDE_PLUGIN_ROOT at a sandbox with a STUB install script so the
# self-heal is exercised without touching the real host scheduler.
heal_emit(){ printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' \
  | env PATH="$STUB_BIN:$PATH" ANTHROPIC_API_KEY="" CLAUDE_PLUGIN_ROOT="$1" ${2:+SB_DISABLE_AUTO_TIMER=$2} BRAIN_DIR="$B" bash "$SL" 2>/dev/null; }

# 5a. success stub (prints 'applied' + exit 0) → installs + reports healed, suppresses the nag
PR_OK=$(mktemp -d); mkdir -p "$PR_OK/scripts"
printf '#!/bin/bash\necho "applied: test scheduler installed."\nexit 0\n' > "$PR_OK/scripts/install-extract-timer.sh"
chmod +x "$PR_OK/scripts/install-extract-timer.sh"
heal_ok=$(heal_emit "$PR_OK")
echo "$heal_ok" | grep -qi 'self-installed' || fail "self-heal: success path must report the scheduler was self-installed (got: $(echo "$heal_ok" | head -c 200))"
echo "$heal_ok" | grep -qi 'capture not running' && fail "self-heal: must NOT show the install-the-drainer nag once healed" || pass "self-heal: installs + reports healed, suppresses the nag"

# 5b. failure stub (error + exit 1) → fall back to the nag, never falsely claim healed
PR_FAIL=$(mktemp -d); mkdir -p "$PR_FAIL/scripts"
printf '#!/bin/bash\necho "error: boom" >&2\nexit 1\n' > "$PR_FAIL/scripts/install-extract-timer.sh"
chmod +x "$PR_FAIL/scripts/install-extract-timer.sh"
heal_fail=$(heal_emit "$PR_FAIL")
echo "$heal_fail" | grep -qi 'capture not running' || fail "self-heal: a failed install must fall back to the nag"
echo "$heal_fail" | grep -qi 'self-installed' && fail "self-heal: must NOT claim healed when the install failed" || pass "self-heal: failed install falls back to the nag (no false healed claim)"

# 5c. opt-out: SB_DISABLE_AUTO_TIMER=1 → never attempt self-heal, show the nag
heal_off=$(heal_emit "$PR_OK" 1)
echo "$heal_off" | grep -qi 'capture not running' || fail "self-heal opt-out: SB_DISABLE_AUTO_TIMER=1 must skip the heal and show the nag"
echo "$heal_off" | grep -qi 'self-installed' && fail "self-heal opt-out: must not install when opted out" || pass "self-heal: SB_DISABLE_AUTO_TIMER=1 opts out (nag, no install)"
rm -rf "$PR_OK" "$PR_FAIL"

# --- 6. P8 (0.48.0): healthy line surfaces the drainer's reconcile backlog. ---
# The suffix is read from the LAST gate=drain-tick verdict=reconcile audit row
# (whole-file grep — a fixed tail window was rejected in review: busy sessions
# push the row out). pending>0 → '· N pending (oldest Hh)'; pending=0 → no suffix.
B3=$(mktemp -d); mkdir -p "$B3/transcripts"; : > "$B3/transcripts/s1.txt"
printf '{"basename":"s1.txt","ts":"x","outcome":"ok","latency_s":5}\n' > "$B3/.extraction-state.jsonl"
: > "$B3/USER.md"; touch -t 202001010000 "$B3/USER.md"
# uname stub → CAP_TIMER=unknown (≠ "no"), so the healthy line renders deterministically
# on any host without touching the real scheduler probe.
UN=$(mktemp -d); printf '#!/bin/bash\necho OtherOS\n' > "$UN/uname"; chmod +x "$UN/uname"
recon_emit(){ printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' \
  | env PATH="$UN:$STUB_BIN:$PATH" ANTHROPIC_API_KEY="" BRAIN_DIR="$B3" bash "$SL" 2>/dev/null; }
printf '{"hook":"extract-drain.sh","rule":"drain-tick","verdict":"reconcile","reason":"declared=5 observed=2 pending=3 oldest_pending_s=7200 max_latency_s=9 p50_latency_s=5 sampled_n=2"}\n' > "$B3/audit-log.jsonl"
r_out=$(recon_emit)
echo "$r_out" | grep -q '3 pending (oldest 2h)' \
  || fail "reconcile suffix: expected '· 3 pending (oldest 2h)' on the healthy line (got: $(echo "$r_out" | grep -i 'second-brain capture' | head -c 200))"
pass "reconcile backlog surfaces as pending suffix on the capture-health line"
printf '{"hook":"extract-drain.sh","rule":"drain-tick","verdict":"reconcile","reason":"declared=2 observed=2 pending=0 oldest_pending_s=0 max_latency_s=9 p50_latency_s=5 sampled_n=2"}\n' >> "$B3/audit-log.jsonl"
r_out=$(recon_emit)
echo "$r_out" | grep -q 'pending (oldest' \
  && fail "reconcile suffix: pending=0 must render NO suffix (got: $(echo "$r_out" | grep -i 'second-brain capture' | head -c 200))"
pass "pending=0 reconcile row renders no suffix (newest row wins)"
rm -rf "$B3" "$UN"

rm -rf "$B" "$B2"; echo; echo "ALL PASS"
