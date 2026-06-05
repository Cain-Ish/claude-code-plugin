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
sleep 0.6
IN=$(mktemp); printf 'a real transcript body\n' > "$IN"; OUT=$(mktemp)

SB_EXTRACTOR_LOCAL_URL="http://127.0.0.1:$PORT" \
  sb_call_extractor "$IN" "$OUT" "qwen2.5:3b" "extract json" 10 || fail "local backend returned non-zero"
jq -e '.wiki_updates[0].slug=="x"' "$OUT" >/dev/null 2>&1 \
  || fail "local backend did not write the parsed JSON object (got: $(cat "$OUT"))"
pass "local backend parses /v1 response into the JSON object"
jq -e '.backend=="local" and .status=="ok"' "$BRAIN_DIR/.extractor-health.json" >/dev/null 2>&1 \
  || fail "health marker not backend=local ok (got: $(cat "$BRAIN_DIR/.extractor-health.json" 2>/dev/null))"
pass "health marker records backend=local"
kill $SRV 2>/dev/null; rm -rf "$BRAIN_DIR" "$IN" "$OUT"
echo; echo "ALL PASS"
