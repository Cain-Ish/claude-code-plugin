#!/bin/bash
# Backend 0: local OpenAI-compatible (/v1/chat/completions) extraction.
# A python one-shot HTTP responder fakes ollama's /v1 — no real model needed.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
export BRAIN_DIR="$(mktemp -d)"
source "$ROOT/scripts/lib.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 absent"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl absent"; exit 0; }

# Poll until a listener holds $1, probing every 50ms up to a 5s cap. Replaces a
# fixed `sleep 0.6` readiness race. NOTE: the stubs below are one-shot servers
# (handle_request() serves exactly ONE connection) — a bare TCP connect probe would
# be ACCEPTED and consume that one shot, breaking the test. So we probe by trying to
# BIND the port: once the stub is listening a fresh bind fails with EADDRINUSE, and
# a bind attempt never touches the server's accept queue.
wait_port() {
  local port="$1" i=0
  while [ "$i" -lt 100 ]; do
    if python3 -c 'import socket,sys
s=socket.socket()
try:
    s.bind(("127.0.0.1",int(sys.argv[1])))
    s.close()
    sys.exit(1)
except OSError:
    sys.exit(0)' "$port" 2>/dev/null; then
      return 0
    fi
    i=$((i+1)); sleep 0.05
  done
  return 1
}

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 - "$PORT" <<'PY' & SRV=$!
import sys,http.server,json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length",0)))
        body=json.dumps({"choices":[{"message":{"content":'{"wiki_updates":[{"slug":"x","action":"create"}]}'}}]}).encode()
        self.send_response(200); self.send_header("content-type","application/json")
        self.send_header("content-length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).handle_request()
PY
wait_port "$PORT"
IN=$(mktemp); printf 'a real transcript body\n' > "$IN"; OUT=$(mktemp)

SB_EXTRACTOR_LOCAL_URL="http://127.0.0.1:$PORT" \
  sb_call_extractor "$IN" "$OUT" "qwen2.5:3b" "extract json" 10 || fail "local backend returned non-zero"
jq -e '.wiki_updates[0].slug=="x"' "$OUT" >/dev/null 2>&1 \
  || fail "local backend did not write the parsed JSON object (got: $(cat "$OUT"))"
pass "local backend parses /v1 response into the JSON object"
jq -e '.backend=="local" and .status=="ok"' "$BRAIN_DIR/.extractor-health.json" >/dev/null 2>&1 \
  || fail "health marker not backend=local ok (got: $(cat "$BRAIN_DIR/.extractor-health.json" 2>/dev/null))"
pass "health marker records backend=local"
kill $SRV 2>/dev/null

# Budgeting: a large input is capped to the most-recent SB_EXTRACTOR_LOCAL_MAX_BYTES
PORT2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
REQ=$(mktemp)
python3 - "$PORT2" "$REQ" <<'PY' & SRV2=$!
import sys,http.server,json
req=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get("content-length",0)))
        open(req,"wb").write(body)
        out=json.dumps({"choices":[{"message":{"content":'{"ok":1}'}}]}).encode()
        self.send_response(200); self.send_header("content-length",str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).handle_request()
PY
wait_port "$PORT2"
export BRAIN_DIR2=$(mktemp -d); BIG=$(mktemp); head -c 20000 /dev/zero | tr '\0' 'A' > "$BIG"; OUT2=$(mktemp)
BRAIN_DIR="$BRAIN_DIR2" SB_EXTRACTOR_LOCAL_URL="http://127.0.0.1:$PORT2" SB_EXTRACTOR_LOCAL_MAX_BYTES=500 \
  sb_call_extractor "$BIG" "$OUT2" qwen2.5:3b "p" 10 >/dev/null 2>&1
ULEN=$(jq -r '.messages[-1].content | length' "$REQ" 2>/dev/null)
{ [ -n "$ULEN" ] && [ "$ULEN" -le 500 ]; } && pass "input budgeted to cap (user content ${ULEN}B <= 500)" || fail "input NOT capped (user content '${ULEN}'B)"
kill $SRV2 2>/dev/null

# Fallback policy: `auto` (default) tries local FIRST then falls through to the
# Claude/API backend when local can't deliver; `local` pins (no fallthrough).
# Probe with an unreachable local URL (connection refused → fast fail).
IN3=$(mktemp); printf 'x\n' > "$IN3"; O3=$(mktemp)
BD_PIN=$(mktemp -d)
( export SB_HEALTH_FILE="$BD_PIN/.extractor-health.json" BRAIN_DIR="$BD_PIN" \
    SB_EXTRACTOR_ENGINE=local SB_EXTRACTOR_LOCAL_URL=http://127.0.0.1:1
  sb_call_extractor "$IN3" "$O3" m p 3 ) >/dev/null 2>&1
jq -e '.backend=="local" and .status=="fail"' "$BD_PIN/.extractor-health.json" >/dev/null 2>&1 \
  && pass "engine=local pins (bad url → local/fail, no fallthrough)" || fail "pinned local wrong health ($(cat "$BD_PIN/.extractor-health.json" 2>/dev/null))"
BD_AUTO=$(mktemp -d)
( export SB_HEALTH_FILE="$BD_AUTO/.extractor-health.json" BRAIN_DIR="$BD_AUTO" \
    SB_EXTRACTOR_ENGINE=auto SB_EXTRACTOR_LOCAL_URL=http://127.0.0.1:1
  sb_call_extractor "$IN3" "$O3" m p 3 ) >/dev/null 2>&1
jq -e '.backend=="local" and .status=="ok"' "$BD_AUTO/.extractor-health.json" >/dev/null 2>&1 \
  && fail "auto wrongly reported local-ok on a bad url (did not fall through)" || pass "auto falls through a failed local (to the Claude path)"

# HIGH-fix guard: a non-OBJECT local response (valid JSON array) must NOT leave any
# content in out_file — validate-in-staging-then-mv, so a failed local in auto can't
# ship stale garbage as a "successful" extraction.
PORT3=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 - "$PORT3" <<'PY' & SRV3=$!
import sys,http.server,json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length",0)))
        out=json.dumps({"choices":[{"message":{"content":'[1,2,3]'}}]}).encode()  # valid JSON, NOT an object
        self.send_response(200); self.send_header("content-length",str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).handle_request()
PY
wait_port "$PORT3"
BD_NOBJ=$(mktemp -d); ON=$(mktemp)   # fresh + empty
( export SB_HEALTH_FILE="$BD_NOBJ/.extractor-health.json" BRAIN_DIR="$BD_NOBJ" \
    SB_EXTRACTOR_ENGINE=local SB_EXTRACTOR_LOCAL_URL="http://127.0.0.1:$PORT3"
  sb_call_extractor "$IN3" "$ON" m p 10 ) >/dev/null 2>&1
[ -s "$ON" ] && fail "non-object local response left content in out_file (HIGH leak): $(cat "$ON")" || pass "non-object local leaves out_file empty (no garbage shipped)"
kill $SRV3 2>/dev/null; rm -rf "$BD_NOBJ" "$ON"

kill $SRV2 2>/dev/null; rm -rf "$BRAIN_DIR" "$BRAIN_DIR2" "$BD_PIN" "$BD_AUTO" "$IN" "$OUT" "$BIG" "$OUT2" "$REQ" "$IN3" "$O3"

# --- E2E (HIGH): extractor prompt -> delta -> gate -> merge -> wiki page -------
# Stand up a fake local /v1 backend returning a realistic wiki_updates delta, then
# run the WHOLE drainer extraction path (sb_extract_transcript) against a fixture
# archived transcript. This exercises the real chain end to end — the extractor
# backend, the quality gate, AND merge-project-update.sh authoring a page — and
# asserts the durable EFFECT (the learnings page exists on disk with its body),
# not just that the backend returned JSON.
PORTE=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 - "$PORTE" <<'PY' & SRVE=$!
import sys,http.server,json
DELTA='{"wiki_updates":[{"category":"learnings","slug":"e2e-local-insight","action":"create","title":"E2E Local Insight","description":"d","content":"DURABLE E2E EXTRACTED INSIGHT BODY"}],"recent_decisions":["files this session: noise.ts"]}'
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length",0)))
        body=json.dumps({"choices":[{"message":{"content":DELTA}}]}).encode()
        self.send_response(200); self.send_header("content-type","application/json")
        self.send_header("content-length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).handle_request()
PY
wait_port "$PORTE"
E2E_HOME=$(mktemp -d)
E2E_BRAIN="$E2E_HOME/.second-brain"; mkdir -p "$E2E_BRAIN/transcripts"
E2E_KDIR="$E2E_HOME/knowledge"; mkdir -p "$E2E_KDIR/wiki"
E2E_TX="$E2E_BRAIN/transcripts/e2e_localproj_2026-06-22.txt"
cat > "$E2E_TX" <<'TXEOF'
session_id: e2e
project_slug: localproj
date: 2026-06-22
---
USER: how should we link the vector deps across plugin versions?
ASSISTANT: use a node junction (fs.symlinkSync junction) for cross-OS dir links.
TXEOF
E2E_PAGE="$E2E_KDIR/wiki/learnings/e2e-local-insight.md"
( export HOME="$E2E_HOME" BRAIN_DIR="$E2E_BRAIN" \
    CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$E2E_KDIR" \
    SB_EXTRACTOR_ENGINE=local SB_EXTRACTOR_LOCAL_URL="http://127.0.0.1:$PORTE"
  sb_extract_transcript "$E2E_TX" "localproj" ) >/dev/null 2>&1
kill $SRVE 2>/dev/null
[ -f "$E2E_PAGE" ] || fail "E2E: extractor->gate->merge did not author the wiki page ($E2E_PAGE)"
grep -qF 'DURABLE E2E EXTRACTED INSIGHT BODY' "$E2E_PAGE" \
  || fail "E2E: page exists but is missing the extracted content body (got: $(cat "$E2E_PAGE"))"
grep -q '^type: learnings$' "$E2E_PAGE" \
  || fail "E2E: page missing 'type: learnings' frontmatter (got: $(cat "$E2E_PAGE"))"
pass "E2E local backend: extractor delta flows through gate+merge to a real wiki page"
rm -rf "$E2E_HOME"

echo; echo "ALL PASS"
