# Autonomous Capture Bridge (SP-A) — Implementation Plan

> **For agentic workers:** Implement task-by-task following TDD. Steps use `- [ ]` checkboxes. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`. Spec: `docs/specs/2026-06-05-autonomous-capture-bridge-design.md`.

**Goal:** Make autonomous capture actually run — an archived transcript becomes a real wiki/PROJECT/graph delta with no live session — via a local-LLM-preferred engine, with a loud capture-health self-check.

**Architecture:** Add a **Backend 0 (local ollama `/v1`)** to `sb_call_extractor` that runs *before* the recursive-claude guard (so it works in-session, offline, credential-free). The drainer (`extract-drain.sh`) and per-transcript extractor are already correct; fix the drainer's hardcoded backend label. Ship a **hardened-default** systemd unit (grants `~/.second-brain` **and** `~/knowledge`; no `~/.claude`) with an `--oauth` opt-in variant. Add a SessionStart capture-health banner. Verify with a **real** in-session extraction through `qwen2.5:3b`.

**Tech Stack:** bash (mawk-safe), `curl` + `jq` (OpenAI `/v1/chat/completions`), systemd user units, ollama 0.23.4 on `localhost:11434`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `scripts/lib.sh` | extractor engine | **add** `sb_extractor_local_call()`; **add** Backend 0 to `sb_call_extractor()` (before the recursive guard) |
| `scripts/extract-drain.sh` | out-of-band drain loop | **fix** summary health to use the real backend (not hardcoded `cli-oauth`) |
| `systemd/sb-extract-drain.service` | hardened drainer unit | **add** `ReadWritePaths=%h/knowledge`; this stays the **hardened (no `~/.claude`)** default |
| `systemd/sb-extract-drain-oauth.service` | OAuth variant | **new** — hardened + `ReadWritePaths=%h/.claude` |
| `scripts/install-extract-timer.sh` | installer | **default** renders hardened; **`--oauth`** renders the OAuth variant + prints the `~/.claude` grant |
| `scripts/session-load.sh` | SessionStart context | **add** capture-health banner (U5); update the OAuth auth-line to mention the local engine |
| `tests/test-extractor-local-backend.sh` | U1 test | **new** |
| `tests/test-extract-drain.sh` | U2 test | **extend** (backend label) |
| `tests/test-install-extract-timer.sh` | U3/U4 test | **extend** (knowledge grant, hardened default, --oauth) |
| `tests/test-session-load-capture-banner.sh` | U5 test | **new** |

---

## Task 1: U1 — local ollama backend (`sb_extractor_local_call` + Backend 0)

**Files:**
- Modify: `scripts/lib.sh` (add helper near `sb_call_extractor` ~line 658; add Backend 0 at the top of `sb_call_extractor`)
- Test: `tests/test-extractor-local-backend.sh` (new)

- [ ] **Step 1: Write the failing test** (a python one-shot responder fakes ollama `/v1`; no real model needed)

```bash
cat > tests/test-extractor-local-backend.sh <<'EOF'
#!/bin/bash
# Backend 0: local OpenAI-compatible (/v1/chat/completions) extraction.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
export BRAIN_DIR="$(mktemp -d)"
source "$ROOT/scripts/lib.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 absent"; exit 0; }

# one-shot HTTP responder returning an OpenAI-shaped reply whose content is a JSON object
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
sleep 0.5
IN=$(mktemp); printf 'a real transcript body\n' > "$IN"; OUT=$(mktemp)

SB_EXTRACTOR_LOCAL_URL="http://127.0.0.1:$PORT" \
  sb_call_extractor "$IN" "$OUT" "qwen2.5:3b" "extract json" 10 || fail "local backend returned non-zero"
jq -e '.wiki_updates[0].slug=="x"' "$OUT" >/dev/null 2>&1 || fail "local backend did not write the parsed JSON object (got: $(cat "$OUT"))"
pass "local backend parses /v1 response into the JSON object"
jq -e '.backend=="local" and .status=="ok"' "$BRAIN_DIR/.extractor-health.json" >/dev/null 2>&1 \
  || fail "health marker not backend=local ok (got: $(cat "$BRAIN_DIR/.extractor-health.json"))"
pass "health marker records backend=local"
kill $SRV 2>/dev/null; rm -rf "$BRAIN_DIR" "$IN" "$OUT"
echo; echo "ALL PASS"
EOF
chmod +x tests/test-extractor-local-backend.sh
```

- [ ] **Step 2: Run it — expect FAIL** (`sb_call_extractor` has no local backend yet; in-session-OAuth path or no-op)

Run: `bash tests/test-extractor-local-backend.sh`
Expected: `FAIL: local backend did not write the parsed JSON object` (the local URL is ignored).

- [ ] **Step 3: Add the helper** — insert immediately *before* `sb_call_extractor() {` in `scripts/lib.sh`:

```bash
# Backend 0 helper: call a local OpenAI-compatible chat endpoint (ollama /v1).
# $1 url, $2 model, $3 system-prompt, $4 input-file, $5 out-file, $6 timeout.
# Returns 0 and writes a JSON object to $5 on success; 1 otherwise. No creds.
sb_extractor_local_call() {
  local url="$1" model="$2" prompt="$3" input_file="$4" out_file="$5" timeout_s="${6:-60}"
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  local payload
  payload=$(jq -n --arg m "$model" --arg s "$prompt" --rawfile u "$input_file" \
    '{model:$m, stream:false, messages:[{role:"system",content:$s},{role:"user",content:$u}]}' 2>/dev/null) || return 1
  [ -n "$payload" ] || return 1
  local TBIN resp; TBIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
  resp=$( ${TBIN:+"$TBIN" "$timeout_s"} curl -sS "${url%/}/v1/chat/completions" \
    -H 'content-type: application/json' --data-binary @<(printf '%s' "$payload") 2>/dev/null ) || return 1
  local text
  text=$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  [ -n "$text" ] || return 1
  printf '%s' "$text" | sb_strip_code_fences > "$out_file"
  jq -e 'type == "object"' "$out_file" >/dev/null 2>&1 || return 1
  return 0
}
```

- [ ] **Step 4: Add Backend 0** — insert at the **top** of `sb_call_extractor`, right after `caller_script="${SB_SCRIPT_NAME:-${0##*/}}"`:

```bash
  # --- Backend 0: local LLM (OpenAI-compatible /v1) ------------------------
  # Tried FIRST when SB_EXTRACTOR_LOCAL_URL is set and the engine isn't pinned
  # to a remote backend. No recursive-claude lock (not claude), no Anthropic
  # creds → works in-session AND offline. ENGINE=local pins it (no fallback).
  local _engine="${SB_EXTRACTOR_ENGINE:-auto}"
  if [ -n "${SB_EXTRACTOR_LOCAL_URL:-}" ] && [ "$_engine" != "cli" ] && [ "$_engine" != "bare" ]; then
    if sb_extractor_local_call "$SB_EXTRACTOR_LOCAL_URL" \
         "${SB_EXTRACTOR_LOCAL_MODEL:-qwen2.5:3b}" "$prompt" "$input_file" "$out_file" "$timeout_s"; then
      sb_write_extractor_health "local" "ok" ""
      rm -f "$err_file"; return 0
    fi
    if [ "$_engine" = "local" ]; then
      sb_write_extractor_health "local" "fail" "local endpoint ${SB_EXTRACTOR_LOCAL_URL} unreachable or non-JSON"
      rm -f "$err_file"; return 1
    fi
    # else fall through to the existing backends
  fi
```

- [ ] **Step 5: Run it — expect PASS**

Run: `bash tests/test-extractor-local-backend.sh`
Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib.sh tests/test-extractor-local-backend.sh
git commit -m "feat(extractor): Backend 0 — local ollama /v1, tried first, in-session+offline"
```

---

## Task 2: U2 — drainer reports the real backend (not hardcoded `cli-oauth`)

**Files:**
- Modify: `scripts/extract-drain.sh:98-105`
- Test: `tests/test-extract-drain.sh` (extend)

- [ ] **Step 1: Write the failing assertion** — append to `tests/test-extract-drain.sh` a case that drains with a stub and asserts the summary health backend is **not** hardcoded `cli-oauth` when the per-extraction backend differs. (The stub writes its own health.) Concretely, after a successful stubbed drain, assert the summary reuses whatever `.extractor-health.json` backend the extraction set, e.g.:

```bash
# the drainer summary must not overwrite the real backend with a hardcoded label
grep -q '"backend":"cli-oauth"' "$BRAIN_DIR/.extractor-health.json" \
  && [ "$EXPECTED_BACKEND" != "cli-oauth" ] && fail "drainer hardcoded backend=cli-oauth over the real one"
```

- [ ] **Step 2: Run it — expect FAIL** (`extract-drain.sh:102/104` hardcode `cli-oauth`).

Run: `bash tests/test-extract-drain.sh`
Expected: FAIL on the hardcoded-backend assertion.

- [ ] **Step 3: Fix the summary** — replace `extract-drain.sh:98-105` so the backend comes from the last health write (the per-transcript extractor already records the true backend):

```bash
# Don't clobber the real backend the per-transcript extractor recorded. Read it
# back; default to "drainer" if absent. Only assert ok if anything succeeded.
DRAIN_BACKEND=$(jq -r '.backend // "drainer"' "$BRAIN_DIR/.extractor-health.json" 2>/dev/null); : "${DRAIN_BACKEND:=drainer}"
if [ "$processed" -eq 0 ] && [ "$failed" -gt 0 ]; then
  sb_write_extractor_health "$DRAIN_BACKEND" "fail" "drained 0, $failed failed this run"
else
  sb_write_extractor_health "$DRAIN_BACKEND" "ok" "drained $processed this run ($failed failed)"
fi
```

- [ ] **Step 4: Run it — expect PASS**

Run: `bash tests/test-extract-drain.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/extract-drain.sh tests/test-extract-drain.sh
git commit -m "fix(drainer): report the real extraction backend, not hardcoded cli-oauth"
```

---

## Task 3: U3 — systemd units (hardened default + OAuth variant; grant ~/knowledge)

**Files:**
- Modify: `systemd/sb-extract-drain.service` (add `ReadWritePaths=%h/knowledge`)
- Create: `systemd/sb-extract-drain-oauth.service`
- Test: `tests/test-install-extract-timer.sh` (extend)

- [ ] **Step 1: Write the failing test** — append assertions that the **hardened** unit grants write to BOTH `~/.second-brain` and `~/knowledge` and does **not** grant `~/.claude`, and that an OAuth unit exists that adds `~/.claude`:

```bash
HARD="$ROOT/systemd/sb-extract-drain.service"
grep -q 'ReadWritePaths=%h/.second-brain' "$HARD" || fail "hardened unit missing .second-brain write"
grep -q 'ReadWritePaths=%h/knowledge' "$HARD"    || fail "hardened unit cannot write the wiki (~/knowledge)"
grep -q '%h/.claude' "$HARD" && fail "hardened unit must NOT grant ~/.claude"
pass "hardened unit: writes brain+knowledge, no creds"
OAUTH="$ROOT/systemd/sb-extract-drain-oauth.service"
[ -f "$OAUTH" ] && grep -q 'ReadWritePaths=%h/.claude' "$OAUTH" || fail "OAuth unit missing or no ~/.claude grant"
pass "OAuth variant grants ~/.claude"
```

- [ ] **Step 2: Run it — expect FAIL** (no `~/knowledge` grant; no OAuth unit).

Run: `bash tests/test-install-extract-timer.sh`
Expected: FAIL `hardened unit cannot write the wiki (~/knowledge)`.

- [ ] **Step 3a: Fix the hardened unit** — in `systemd/sb-extract-drain.service`, change the `ReadWritePaths` line to include knowledge (the extractor writes wiki + graph there):

```ini
ReadWritePaths=%h/.second-brain %h/knowledge
```

- [ ] **Step 3b: Create the OAuth variant** `systemd/sb-extract-drain-oauth.service` (hardened + `~/.claude`):

```ini
[Unit]
Description=second-brain out-of-band extraction drainer (OAuth-capable)
After=default.target

[Service]
Type=oneshot
# OAuth variant: same hardening as the default unit PLUS read/write of ~/.claude
# so `claude -p` can read OAuth creds and write its session/cache. Opt-in only.
NoNewPrivileges=true
RestrictNamespaces=true
ProtectHome=read-only
ReadWritePaths=%h/.second-brain %h/knowledge %h/.claude
ExecStart=@EXEC@
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
```

- [ ] **Step 4: Run it — expect PASS**

Run: `bash tests/test-install-extract-timer.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add systemd/sb-extract-drain.service systemd/sb-extract-drain-oauth.service tests/test-install-extract-timer.sh
git commit -m "feat(systemd): grant ~/knowledge; hardened default + OAuth-opt-in variant"
```

---

## Task 4: U4 — installer defaults hardened, `--oauth` opt-in

**Files:**
- Modify: `scripts/install-extract-timer.sh`
- Test: `tests/test-install-extract-timer.sh` (extend)

- [ ] **Step 1: Write the failing test** — print-mode renders the hardened unit by default; `--oauth` print-mode renders the `~/.claude` grant + a visible notice:

```bash
out=$(bash "$ROOT/scripts/install-extract-timer.sh"); echo "$out" | grep -q '%h/.claude' && fail "default print leaked the creds grant"
echo "$out" | grep -q 'ReadWritePaths=%h/.second-brain %h/knowledge' || fail "default print not the hardened unit"
pass "installer default = hardened unit"
oout=$(bash "$ROOT/scripts/install-extract-timer.sh" --oauth)
echo "$oout" | grep -q '%h/.claude' || fail "--oauth print did not render the creds grant"
echo "$oout" | grep -qi 'grant' || fail "--oauth must visibly announce the ~/.claude grant"
pass "installer --oauth = OAuth unit + announced grant"
```

- [ ] **Step 2: Run it — expect FAIL** (installer only knows one unit).

Run: `bash tests/test-install-extract-timer.sh`
Expected: FAIL `--oauth print did not render the creds grant`.

- [ ] **Step 3: Teach the installer the variant** — in `scripts/install-extract-timer.sh`, after the `SVC`/`TIMER` vars, add variant selection and route `--oauth`:

```bash
# Default = hardened local-only unit; --oauth opts into the creds-granting one.
VARIANT_SVC="$SVC"
for a in "$@"; do [ "$a" = "--oauth" ] && VARIANT_SVC="sb-extract-drain-oauth.service"; done
render_service() {
  if [ "$VARIANT_SVC" = "sb-extract-drain-oauth.service" ]; then
    echo "# NOTE: --oauth grants this background service read/write of ~/.claude (OAuth creds)." >&2
  fi
  sed "s#@EXEC@#bash $DRAINER#g" "$TPL_DIR/$VARIANT_SVC"
}
```

(Both `--apply` and print-mode call `render_service`; the installed file is always written to `$UNIT_DIR/$SVC` so the timer's `ExecStart`/`Wants` resolve regardless of variant — keep the write target as `$SVC`.)

- [ ] **Step 4: Run it — expect PASS**

Run: `bash tests/test-install-extract-timer.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/install-extract-timer.sh tests/test-install-extract-timer.sh
git commit -m "feat(installer): hardened default, --oauth opt-in with announced creds grant"
```

---

## Task 5: U5 — SessionStart capture-health banner

**Files:**
- Modify: `scripts/session-load.sh` (after the auth-mode-line block, ~line 252)
- Test: `tests/test-session-load-capture-banner.sh` (new)

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/test-session-load-capture-banner.sh <<'EOF'
#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
emit(){ printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' | BRAIN_DIR="$1" bash "$SL" 2>/dev/null; }
# A: transcripts exist but never drained → must SHOUT
B=$(mktemp -d); mkdir -p "$B/transcripts"; : > "$B/transcripts/s1.txt"; : > "$B/USER.md"
emit "$B" | grep -qi 'capture not running\|capture: ' || fail "no capture-health line when transcripts undrained"
pass "capture-health banner appears"
# B: kill switch
SB_CAPTURE_HEALTH_BANNER=off emit "$B" | grep -qi 'capture not running' && fail "kill switch did not suppress"
pass "SB_CAPTURE_HEALTH_BANNER=off suppresses"
rm -rf "$B"; echo; echo "ALL PASS"
EOF
chmod +x tests/test-session-load-capture-banner.sh
```

- [ ] **Step 2: Run it — expect FAIL** (no banner yet).

Run: `bash tests/test-session-load-capture-banner.sh`
Expected: FAIL `no capture-health line when transcripts undrained`.

- [ ] **Step 3: Add the banner** — after the auth-mode-line `fi` (~`session-load.sh:252`), insert:

```bash
# 0a-ter. Capture-health self-check — the "wired != works" guard. Surfaces
# whether the out-of-band drainer is actually turning transcripts into deltas.
# Shouts when transcripts exist but the drainer never ran / is stale / made 0
# deltas. Suppress: SB_CAPTURE_HEALTH_BANNER=off.
if [ "${SB_CAPTURE_HEALTH_BANNER:-on}" = "on" ]; then
  CAP_TX="$BRAIN_DIR/transcripts"; CAP_STATE="$BRAIN_DIR/.extraction-state.jsonl"
  CAP_N=$(ls -1 "$CAP_TX"/*.txt 2>/dev/null | wc -l | tr -d ' ')
  if [ "${CAP_N:-0}" -gt 0 ]; then
    CAP_DONE=0; [ -f "$CAP_STATE" ] && CAP_DONE=$(grep -c '"outcome":"ok"' "$CAP_STATE" 2>/dev/null || echo 0)
    CAP_TIMER=no; systemctl --user is-active sb-extract-drain.timer >/dev/null 2>&1 && CAP_TIMER=yes
    if [ "$CAP_DONE" -eq 0 ] || [ "$CAP_TIMER" = "no" ]; then
      sb_append "$(printf '## ⚠ second-brain — capture not running\n%s transcript(s) archived, %s extracted; drainer timer: %s.\nNothing is turning sessions into knowledge automatically. Install the bridge:\n  `bash $CLAUDE_PLUGIN_ROOT/scripts/install-extract-timer.sh --apply`  (local-engine, hardened; add `--oauth` to use your Claude login instead)\nSuppress: `SB_CAPTURE_HEALTH_BANNER=off`.\n\n' "$CAP_N" "$CAP_DONE" "$CAP_TIMER")" "capture-health-banner" 600
    else
      sb_append "$(printf '## ⓘ second-brain capture\n%s archived · %s extracted · timer active.\n\n' "$CAP_N" "$CAP_DONE")" "capture-health-line" 200
    fi
  fi
fi
```

- [ ] **Step 4: Run it — expect PASS**

Run: `bash tests/test-session-load-capture-banner.sh && bash -n scripts/session-load.sh`
Expected: `ALL PASS` + clean syntax.

- [ ] **Step 5: Commit**

```bash
git add scripts/session-load.sh tests/test-session-load-capture-banner.sh
git commit -m "feat(session-load): loud capture-health self-check (wired != works guard)"
```

---

## Task 6: Full suite + the REAL-run verification (the crux — no stub)

- [ ] **Step 1: Full suite green**

Run: `bash tests/run-all.sh`
Expected: `ALL GREEN`, fail: 0.

- [ ] **Step 2: REAL in-session extraction through ollama `qwen2.5:3b`** (no stub, no recursive lock — the local engine bypasses it). Pick one real archived transcript into a sandbox brain, run the real extractor against the live model, and confirm a real delta + `backend=local ok`:

```bash
SB=$(mktemp -d); mkdir -p "$SB/transcripts"
cp "$(ls -1t ~/.second-brain/transcripts/*.txt | head -1)" "$SB/transcripts/real.txt"
BRAIN_DIR="$SB" KNOWLEDGE_DIR="$SB/knowledge" \
  SB_EXTRACTOR_ENGINE=local SB_EXTRACTOR_LOCAL_URL=http://localhost:11434 SB_EXTRACTOR_LOCAL_MODEL=qwen2.5:3b \
  bash scripts/extract-drain.sh
echo "--- health ---"; jq . "$SB/.extractor-health.json"
echo "--- state ---";  cat "$SB/.extraction-state.jsonl"
echo "--- delta written? ---"; find "$SB/knowledge" "$SB" -newer "$SB/transcripts/real.txt" -name '*.md' 2>/dev/null | head
```

Expected: `.extractor-health.json` shows `backend":"local","status":"ok"`; `.extraction-state.jsonl` has `"outcome":"ok"`; at least one wiki/PROJECT `.md` delta is produced. **If no delta: NOT done** — diagnose (model output not a JSON object → tighten the prompt / model; this is the real-capability gate the spec demands).

- [ ] **Step 3: Commit any prompt/robustness fix the real run forced**, then re-run Step 2 to green.

---

## Task 7: Gated release (0.24.18)

- [ ] **Step 1: Deep-review gate** — `/second-brain:code-review-deep --base main` (or dispatch the unit/history reviewers). Fix confirmed findings.
- [ ] **Step 2: Version bump (lockstep)** — `plugin.json` + `.claude-plugin/marketplace.json` → next patch. No MCP server change (stays 2.6.4).
- [ ] **Step 3: Migration row** in `skills/upgrade/SKILL.md` — describes SP-A; **offers** (never forces) `install-extract-timer.sh --apply`; notes the local-engine + hardened-default + `--oauth` opt-in; notes `SB_EXTRACTOR_ENGINE/LOCAL_URL/LOCAL_MODEL`, `SB_CAPTURE_HEALTH_BANNER`. Additive: defaults inert (no timer, no `SB_EXTRACTOR_LOCAL_URL`) → behaviour unchanged.
- [ ] **Step 4: Lockstep + suite guards** — `test-upgrade-migration-row`, `test-validate-plugin`, full suite.
- [ ] **Step 5: Branch → PR → merge.**

---

## Self-Review (run before executing)

- **Spec coverage:** U1 (Task 1) · U2 (Task 2) · U3 (Task 3) · U4 (Task 4) · U5 (Task 5) · real-run verification (Task 6) · gated release (Task 7). The spec's `ANTHROPIC_BASE_URL` secondary path is preserved (existing Backend 2 untouched). ✓
- **Placeholder scan:** every code step shows real code; no TBD. ✓
- **Type/name consistency:** `sb_extractor_local_call` (5/6 args) used identically in Task 1 helper + Backend 0; `SB_EXTRACTOR_ENGINE|LOCAL_URL|LOCAL_MODEL` consistent across Tasks 1/6/7; health backend label `local` consistent (Task 1 writes it, Task 2 reads it, Task 5 displays it). ✓
- **Extra gap found during planning (folded in):** the hardened unit must grant `~/knowledge`, not just `~/.second-brain` (Task 3 Step 3a) — otherwise an installed drainer still couldn't write the wiki.
