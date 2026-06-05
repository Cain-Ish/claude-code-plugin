#!/bin/bash
# SP-2: Backend 2 (ANTHROPIC_API_KEY curl) honors ANTHROPIC_BASE_URL so enterprise /
# proxied / air-gapped users hitting an Anthropic-compatible gateway work. Default
# stays the public host. (The SP-A spec wrongly claimed this override already existed.)
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
export BRAIN_DIR="$(mktemp -d)"
source "$ROOT/scripts/lib.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 absent"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl absent"; exit 0; }

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
HIT=$(mktemp)
python3 - "$PORT" "$HIT" <<'PY' & SRV=$!
import sys,http.server,json
hit=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length",0)))
        open(hit,"w").write(self.path)                                   # record the override was hit
        out=json.dumps({"content":[{"text":'{"ok":1}'}]}).encode()       # Anthropic /v1/messages shape
        self.send_response(200); self.send_header("content-length",str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).handle_request()
PY
sleep 0.6
IN=$(mktemp); printf 'x\n' > "$IN"; OUT=$(mktemp)
# CLAUDECODE=1 + API key → recursive guard sets SB_SKIP_CLI=1 → straight to Backend 2 curl.
( export CLAUDECODE=1 ANTHROPIC_API_KEY=sk-test ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
  sb_call_extractor "$IN" "$OUT" claude-x "p" 10 ) >/dev/null 2>&1
[ -s "$HIT" ] && pass "Backend 2 honored ANTHROPIC_BASE_URL (hit $(cat "$HIT"))" || fail "ANTHROPIC_BASE_URL ignored — curl did not reach the override host"
jq -e '.ok==1' "$OUT" >/dev/null 2>&1 && pass "parsed the Anthropic-shaped response from the override" || fail "did not parse override response (got: $(cat "$OUT"))"
kill $SRV 2>/dev/null; rm -rf "$BRAIN_DIR" "$HIT" "$IN" "$OUT"
echo; echo "ALL PASS"
