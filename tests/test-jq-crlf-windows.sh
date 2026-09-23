#!/bin/bash
# 0.30.0: the Windows (Git-Bash) jq build emits CRLF in -r output even when the input is clean LF.
# So every `$(jq -r …)` value, every `jq -r … | grep`, and every config read is \r-contaminated on
# Windows — silently breaking comparisons, arithmetic, grep patterns, and path building. We can't run
# Windows here, so this test STUBS jq to reproduce the exact CRLF behavior on Linux, then runs the real
# scripts and asserts they survive. ORACLE: real script behavior under the faulty jq, not a re-impl.
# pins: SB_BUDDY_COLS — width fixture so the buddy renderer draws the sprite row the mood check reads
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; echo; echo "ALL PASS"; exit 0; }

REALJQ=$(command -v jq)
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
# Faithful Windows-jq stub: append \r to every line of -r/-j (raw) output, like the CRLF build.
cat > "$STUB/jq" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in -r|--raw-output|-j|-rs|-rc|-rn|-nr) raw=1;; esac; done
if [ "\${raw:-0}" = 1 ]; then "$REALJQ" "\$@" | sed 's/\$/\r/'; else "$REALJQ" "\$@"; fi
EOF
chmod +x "$STUB/jq"
RUN(){ PATH="$STUB:$PATH" "$@"; }

# Sanity: the stub really emits CRLF (a CR byte in -r output of a CR-free input).
# Use od-based detection: Git-Bash grep reads pipes in text mode and strips \r from CRLF pairs,
# so `grep -q $'\r'` always exits 1 even when \r is present. od is binary-safe.
printf '{"a":"x"}' | "$STUB/jq" -r '.a' | od -An -tx1 | grep -q ' 0d' \
  || fail "stub jq does not emit CRLF — test would be vacuous"
pass "stub reproduces Windows jq CRLF (-r output carries \\r)"

# 1. The validator's version-drift loop builds cache paths from @tsv jq output — a \r turned
#    them into "…/\r/.claude-plugin/plugin.json" → spurious FAIL (the user's reported 0.30 error).
RUN bash "$ROOT/scripts/validate-plugin.sh" >/tmp/_jqcrlf_val.out 2>&1
ec=$?
grep -qiE 'invalid arithmetic|syntax error' /tmp/_jqcrlf_val.out && fail "validator hit a CRLF arithmetic/syntax error under Windows jq"
[ "$ec" -eq 0 ] || fail "validate-plugin.sh FAILED under Windows jq (exit $ec) — drift/hook CRLF not handled: $(grep -i fail /tmp/_jqcrlf_val.out | head -1)"
pass "validate-plugin.sh passes under Windows jq (drift loop + hook counts CR-safe)"
rm -f /tmp/_jqcrlf_val.out

# 2. The config reader is the highest-leverage jq site: `auto_improve: true` must read 'on', not
#    fall through to the default because the value came back "true\r".
T=$(mktemp -d); printf '{"auto_improve": true}\n' > "$T/config.json"
r=$(RUN bash -c "source '$ROOT/scripts/lib.sh'; BRAIN_DIR='$T' sb_config_bool .auto_improve off")
[ "$r" = "on" ] || fail "config reader mis-read true as '$r' under Windows jq (whole automation-config system would break)"
pass "sb_config_bool reads true→on under Windows jq (config system CR-safe)"
r=$(RUN bash -c "source '$ROOT/scripts/lib.sh'; printf '{\"auto_accept\":\"safe\"}\n' > '$T/config.json'; BRAIN_DIR='$T' sb_config_get .auto_accept off")
[ "$r" = "safe" ] || fail "sb_config_get returned '$r' (CR leaked into a string value)"
pass "sb_config_get returns a clean string under Windows jq"
rm -rf "$T"

# 3. 0.51.0: the buddy renderer reads 14 US-joined fields from ONE `jq -rn` line; the CR lands in
#    the last field (mood), so "alert\r" matched no mood case and Windows never showed mood eyes.
T=$(mktemp -d); mkdir -p "$T/.buddy"
printf '{"identity":{"species":"dragon","eye":"@","hat":"none"}}\n' > "$T/buddy.json"
printf '{"ts":%s,"kind":"gate","mood":"alert","line":"Verify gate fired","ttl_s":900}\n' "$(date +%s)" > "$T/.buddy/s1.json"
out=$(printf '{"session_id":"s1"}' | RUN env BRAIN_DIR="$T" SB_BUDDY_COLS=120 NO_COLOR=1 bash "$ROOT/scripts/buddy-statusline.sh")
printf '%s' "$out" | grep -q 'Verify gate fired' || fail "buddy renderer lost the event under Windows jq: $out"
printf '%s' "$out" | grep -q 'ò  ó' || fail "buddy mood eyes lost under Windows jq (CR in the last read field): $out"
pass "buddy-statusline.sh mood survives Windows jq (last US field CR-stripped)"
rm -rf "$T"

echo; echo "ALL PASS"
