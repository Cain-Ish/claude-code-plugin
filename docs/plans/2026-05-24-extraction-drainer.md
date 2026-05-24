# Out-of-Band Extraction Drainer Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Process archived-but-unextracted transcripts out-of-band on a systemd user timer, so subscription (OAuth) users get session→wiki extraction without an API key.

**Architecture:** New `lib.sh` helpers (done-set state + a shared "build input → extractor → quality-gate → merge → persona" core), a `scripts/extract-drain.sh` drainer (refuses to run in-session, single-flight lock, oldest-first batch, poison-pill guard), reviewable systemd unit templates + `scripts/install-extract-timer.sh`. `stop-extract.sh` and the TS `sb` bundle are untouched.

**Tech Stack:** Bash, `jq`, `flock`, systemd user units, the existing `tests/test-*.sh` harness (auto-discovered by `tests/run-all.sh`), `shellcheck`.

**Spec:** `docs/specs/2026-05-24-extraction-drainer-design.md`

---

## File Structure

- **Modify** `scripts/lib.sh` — add `sb_extraction_done`, `sb_extraction_fails`, `sb_slug_from_archived_transcript`, `sb_extract_transcript`.
- **Create** `scripts/extract-drain.sh` — the drainer (called by the timer; runnable by hand).
- **Create** `scripts/install-extract-timer.sh` — reviewable installer (print / `--apply` / `--uninstall`).
- **Create** `systemd/sb-extract-drain.service`, `systemd/sb-extract-drain.timer` — unit templates.
- **Create** `tests/test-extraction-helpers.sh`, `tests/test-extract-drain.sh`, `tests/test-install-extract-timer.sh`.
- **Modify** `.claude-plugin/plugin.json` — version `0.12.0` → `0.13.0`.

---

## Task 1: lib.sh extraction helpers

**Files:**
- Modify: `scripts/lib.sh` (append the four functions)
- Test: `tests/test-extraction-helpers.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-extraction-helpers.sh`:

```bash
#!/bin/bash
# Tests for the lib.sh extraction helpers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export BRAIN_DIR="$SANDBOX/brain"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$SANDBOX/knowledge"
mkdir -p "$BRAIN_DIR/projects" "$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR/wiki"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
no()   { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || no "$1 — '$2' != '$3'"; }

STATE="$BRAIN_DIR/.extraction-state.jsonl"

echo "=== extraction helpers ==="

# --- done-set ---
: > "$STATE"
printf '{"basename":"a.txt","ts":"t","outcome":"ok"}\n'    >> "$STATE"
printf '{"basename":"b.txt","ts":"t","outcome":"retry"}\n' >> "$STATE"
printf '{"basename":"c.txt","ts":"t","outcome":"error"}\n' >> "$STATE"
sb_extraction_done "a.txt" "$STATE" && ok "done: ok is terminal"   || no "done: ok is terminal"
sb_extraction_done "c.txt" "$STATE" && ok "done: error is terminal" || no "done: error is terminal"
sb_extraction_done "b.txt" "$STATE" && no "done: retry NOT terminal" || ok "done: retry NOT terminal"
sb_extraction_done "z.txt" "$STATE" && no "done: unknown NOT terminal" || ok "done: unknown NOT terminal"

# --- fails count ---
printf '{"basename":"b.txt","ts":"t","outcome":"retry"}\n' >> "$STATE"
eq "fails: two retries for b" "$(sb_extraction_fails b.txt "$STATE")" "2"
eq "fails: none for a"        "$(sb_extraction_fails a.txt "$STATE")" "0"

# --- slug from header ---
TX="$BRAIN_DIR/transcripts/sess1_my-proj_2026-05-24.txt"
mkdir -p "$BRAIN_DIR/transcripts"
cat > "$TX" <<'EOF'
--- session-meta ---
session_id: sess1
project_slug: my-proj
date: 2026-05-24
tool_count: 3
line_count: 10
---

USER: hello
ASSISTANT: hi
EOF
eq "slug from header" "$(sb_slug_from_archived_transcript "$TX")" "my-proj"

# --- extract one transcript (stub the LLM, run real merge) ---
sb_call_extractor() {  # stub: write a canned delta, succeed
  local out="$2"
  printf '{"recent_decisions":["drained test decision"],"open_blockers":[],"cross_refs":[],"files_touched":[],"persona_signals":[]}' > "$out"
  return 0
}
sb_extract_transcript "$TX" "my-proj" && ok "extract returns 0" || no "extract returns 0"
grep -q "drained test decision" "$BRAIN_DIR/projects/my-proj/PROJECT.md" \
  && ok "extract merged the delta into PROJECT.md" || no "extract merged the delta into PROJECT.md"

# --- extract returns non-zero when the LLM yields nothing ---
sb_call_extractor() { : > "$2"; return 1; }
sb_extract_transcript "$TX" "my-proj" && no "extract fails on empty LLM" || ok "extract fails on empty LLM"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-extraction-helpers.sh`
Expected: FAIL — functions not defined (`sb_extraction_done: command not found`).

- [ ] **Step 3: Implement the helpers**

Append to `scripts/lib.sh` (before any trailing guard; end of file is fine):

```bash
# --- Out-of-band extraction helpers (v0.13.0) ----------------------------
# A transcript is "done" once a terminal (ok|error) line exists in the
# append-only done-set ~/.second-brain/.extraction-state.jsonl.
sb_extraction_done() {
  local base="$1" state="$2"
  [ -f "$state" ] || return 1
  local hit
  hit=$(jq -r --arg b "$base" \
    'select(.basename == $b and (.outcome == "ok" or .outcome == "error")) | .basename' \
    "$state" 2>/dev/null | head -1)
  [ -n "$hit" ]
}

# Count prior non-terminal retry attempts for a basename.
sb_extraction_fails() {
  local base="$1" state="$2"
  [ -f "$state" ] || { echo 0; return; }
  jq -r --arg b "$base" 'select(.basename == $b and .outcome == "retry") | .basename' \
    "$state" 2>/dev/null | wc -l | tr -d ' '
}

# Read project_slug: from the archived transcript's meta header.
sb_slug_from_archived_transcript() {
  local txt="$1"
  [ -f "$txt" ] || return 1
  awk -F': ' '/^project_slug:/ {print $2; exit}' "$txt" 2>/dev/null | tr -d '\r'
}

# Build the extractor input from a preprocessed archived transcript + PROJECT.md,
# call the extractor, quality-gate the delta, merge it, route persona signals.
# Returns 0 only on a successful merge. Used by the out-of-band drainer.
sb_extract_transcript() {
  local txt="$1" slug="$2"
  [ -f "$txt" ] || return 1
  local sdir; sdir="$(dirname "${BASH_SOURCE[0]}")"
  local model="${SB_EXTRACTOR_MODEL:-claude-sonnet-4-6}"
  local timeout_s="${SB_EXTRACT_TIMEOUT:-25}"
  local prompt_file="$sdir/extract-prompt.txt"
  [ -f "$prompt_file" ] || return 1
  local prompt; prompt=$(cat "$prompt_file")

  local kdir="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"; kdir="${kdir/#\~/$HOME}"
  local project_md="$BRAIN_DIR/projects/$slug/PROJECT.md"
  if [ ! -f "$project_md" ]; then
    mkdir -p "$(dirname "$project_md")"
    cat > "$project_md" <<TMPL
# PROJECT: $slug

## Goal
(auto-scaffolded — describe this project's goal)

## State

## Conventions

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ) -->
<!-- last_queried_wiki: -->
TMPL
  fi
  mkdir -p "$kdir/wiki" 2>/dev/null || true

  local in_f out_f; in_f=$(mktemp); out_f=$(mktemp)
  {
    echo "=== PROJECT.md ==="
    cat "$project_md"
    echo; echo "---SEPARATOR---"; echo
    echo "=== TRANSCRIPT (preprocessed) ==="
    sed '1,/^---$/d' "$txt"   # drop the meta header, keep the body
  } > "$in_f"

  local delta=""
  if sb_call_extractor "$in_f" "$out_f" "$model" "$prompt" "$timeout_s"; then
    delta=$(cat "$out_f")
  fi
  rm -f "$in_f" "$out_f"
  [ -n "$delta" ] || return 1

  local gated; gated=$(printf '%s' "$delta" | bash "$sdir/extraction-quality-gate.sh" 2>/dev/null)
  if [ -n "$gated" ] && printf '%s' "$gated" | jq empty 2>/dev/null; then delta="$gated"; fi

  printf '%s' "$delta" \
    | bash "$sdir/merge-project-update.sh" --project-md "$project_md" --knowledge-dir "$kdir" \
      >/dev/null 2>&1 || return 1

  local sigs; sigs=$(printf '%s' "$delta" | jq -c '.persona_signals // []' 2>/dev/null)
  if [ -n "$sigs" ] && printf '%s' "$sigs" | jq -e 'length > 0' >/dev/null 2>&1; then
    printf '%s' "$sigs" | bash "$sdir/merge-persona-signals.sh" 2>/dev/null || true
  fi
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-extraction-helpers.sh`
Expected: `Results: 11 passed, 0 failed`

- [ ] **Step 5: shellcheck**

Run: `shellcheck scripts/lib.sh 2>&1 | grep -oE 'SC[0-9]+' | sort -u`
Expected: no NEW codes beyond the file's existing baseline (compare to `git stash && shellcheck` if unsure). The `${BASH_SOURCE[0]}`/`source` infos are pre-existing.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib.sh tests/test-extraction-helpers.sh
git commit -m "feat(extract): lib.sh helpers for out-of-band extraction

sb_extraction_done/_fails (done-set state), sb_slug_from_archived_transcript
(reads project_slug header), sb_extract_transcript (build input -> extractor ->
quality-gate -> merge -> persona). Shared core for the drainer; stop-extract.sh
untouched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: the drainer `extract-drain.sh`

**Files:**
- Create: `scripts/extract-drain.sh`
- Test: `tests/test-extract-drain.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-extract-drain.sh`:

```bash
#!/bin/bash
# Tests for extract-drain.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
DRAIN="$SCRIPT_DIR/extract-drain.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export BRAIN_DIR="$SANDBOX/brain"
mkdir -p "$BRAIN_DIR/transcripts"
STATE="$BRAIN_DIR/.extraction-state.jsonl"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq() { [ "$2" = "$3" ] && ok "$1" || no "$1 — got '$2' want '$3'"; }

# A stub that "extracts" a transcript: succeeds unless the slug is 'poison'.
# The drainer calls: "$SB_EXTRACT_STUB" <txt> <slug>
STUB="$SANDBOX/stub.sh"
cat > "$STUB" <<'EOF'
#!/bin/bash
slug="$2"
[ "$slug" = "poison" ] && exit 1
exit 0
EOF
chmod +x "$STUB"
export SB_EXTRACT_STUB="$STUB"

mk_tx() {  # $1 = name, $2 = slug
  local f="$BRAIN_DIR/transcripts/$1"
  cat > "$f" <<EOF
--- session-meta ---
session_id: ${1%%_*}
project_slug: $2
date: 2026-05-24
tool_count: 2
line_count: 4
---

USER: x
ASSISTANT: y
EOF
}
done_count() { [ -f "$STATE" ] && grep -c '"outcome":"ok"' "$STATE" || echo 0; }
reset() { rm -rf "$BRAIN_DIR/transcripts" "$STATE" "$BRAIN_DIR/.extract-drain.lock"; mkdir -p "$BRAIN_DIR/transcripts"; }

echo "=== extract-drain.sh tests ==="

# Test 1: refuses to run inside a session
reset; mk_tx "s1_proj_2026-05-24.txt" proj
OUT=$(CLAUDECODE=1 bash "$DRAIN" 2>&1 || true)
eq "in-session refusal leaves state empty" "$(done_count)" "0"

# Test 2: processes up to BATCH oldest-first
reset
for i in 1 2 3 4 5 6 7; do mk_tx "s${i}_proj_2026-05-24.txt" proj; sleep 0.05; done
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "batch of 5 processed" "$(done_count)" "5"

# Test 3: a done transcript is not reprocessed; remaining 2 drain next run
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
eq "remaining 2 drained, total 7" "$(done_count)" "7"

# Test 4: poison transcript → retry then terminal error after MAX_FAILS
reset; mk_tx "p1_poison_2026-05-24.txt" poison
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # retry 1
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # retry 2
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # 3rd → terminal error
RETRIES=$(grep -c '"outcome":"retry"' "$STATE" || echo 0)
ERRORS=$(grep -c '"outcome":"error"' "$STATE" || echo 0)
eq "poison: 2 retries recorded" "$RETRIES" "2"
eq "poison: 1 terminal error" "$ERRORS" "1"
SB_DRAIN_MAX_FAILS=3 bash "$DRAIN" >/dev/null 2>&1 || true   # must NOT touch it again
eq "poison: not reprocessed after terminal" "$(grep -c '"outcome":"retry"' "$STATE" || echo 0)" "2"

# Test 5: lock held → no-op
reset; mk_tx "s1_proj_2026-05-24.txt" proj
exec 8>"$BRAIN_DIR/.extract-drain.lock"; flock -n 8
SB_DRAIN_BATCH=5 bash "$DRAIN" >/dev/null 2>&1 || true
flock -u 8; exec 8>&-
eq "lock contention is a no-op" "$(done_count)" "0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-extract-drain.sh`
Expected: FAIL — `extract-drain.sh` does not exist.

- [ ] **Step 3: Implement `scripts/extract-drain.sh`**

```bash
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

# The whole point is to run outside a session — refuse the recursive-lock context.
if [ "${CLAUDECODE:-}" = "1" ]; then
  echo "extract-drain: refusing to run inside a Claude Code session" >&2
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

processed=0
now() { date -u +%FT%TZ; }
# oldest-first
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
    fails=$(sb_extraction_fails "$base" "$STATE"); fails=$((fails+1))
    if [ "$fails" -ge "$MAX_FAILS" ]; then
      printf '{"basename":%s,"ts":"%s","outcome":"error","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" "$fails" >> "$STATE"
    else
      printf '{"basename":%s,"ts":"%s","outcome":"retry","fails":%s}\n' "$(jq -Rn --arg b "$base" '$b')" "$(now)" "$fails" >> "$STATE"
    fi
  fi
done < <(ls -1tr "$TX_DIR"/*.txt 2>/dev/null)

sb_write_extractor_health "cli-oauth" "ok" "drained $processed this run"
exit 0
```

Note the poison test: MAX_FAILS=3 means fails reaches 3 on the *third* run (retry,retry,then 3≥3→error). The test asserts 2 retries + 1 error. ✓

- [ ] **Step 4: chmod + run test to verify pass**

Run: `chmod +x scripts/extract-drain.sh && bash tests/test-extract-drain.sh`
Expected: `Results: 9 passed, 0 failed`

- [ ] **Step 5: shellcheck**

Run: `shellcheck scripts/extract-drain.sh`
Expected: only baseline infos (`SC1091` for `source`, `SC2012` for `ls` — same as `dream-snapshot.sh`). Add `# shellcheck disable=` only for false positives, with a reason.

- [ ] **Step 6: Commit**

```bash
git add scripts/extract-drain.sh tests/test-extract-drain.sh
git commit -m "feat(extract): out-of-band drainer script

Refuses to run in-session, flock single-flight, oldest-first batch of
SB_DRAIN_BATCH, poison-pill guard after SB_DRAIN_MAX_FAILS. SB_EXTRACT_STUB
test seam. Writes the extractor health marker.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: systemd units + reviewable installer

**Files:**
- Create: `systemd/sb-extract-drain.service`, `systemd/sb-extract-drain.timer`
- Create: `scripts/install-extract-timer.sh`
- Test: `tests/test-install-extract-timer.sh`

- [ ] **Step 1: Write the unit templates**

`systemd/sb-extract-drain.service` (the `@EXEC@` token is replaced at install time):

```ini
[Unit]
Description=second-brain out-of-band extraction drainer
After=default.target

[Service]
Type=oneshot
# Do NOT add PrivateDevices=/ProtectSystem= sandboxing — it breaks claude's
# pty allocation (see wiki: pty-openpty-privatedevices-quirk).
ExecStart=@EXEC@
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
```

`systemd/sb-extract-drain.timer`:

```ini
[Unit]
Description=run second-brain extraction drainer periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 2: Write the failing test**

Create `tests/test-install-extract-timer.sh`:

```bash
#!/bin/bash
# Tests for install-extract-timer.sh (print mode — never touches real systemd)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
INSTALL="$SCRIPT_DIR/install-extract-timer.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export XDG_CONFIG_HOME="$SANDBOX/config"   # redirect systemd user dir into sandbox

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== install-extract-timer.sh tests ==="

# Test 1: default (print) mode emits both units and touches nothing
OUT=$(bash "$INSTALL" 2>&1 || true)
printf '%s' "$OUT" | grep -q 'sb-extract-drain.service' && ok "prints .service" || no "prints .service"
printf '%s' "$OUT" | grep -q 'OnUnitActiveSec=30min'     && ok "prints .timer body" || no "prints .timer body"
printf '%s' "$OUT" | grep -q 'extract-drain.sh'          && ok "ExecStart resolved to drainer path" || no "ExecStart resolved"
printf '%s' "$OUT" | grep -q 'enable-linger'             && ok "surfaces linger command" || no "surfaces linger command"
[ ! -e "$XDG_CONFIG_HOME/systemd/user/sb-extract-drain.timer" ] \
  && ok "print mode writes nothing" || no "print mode writes nothing"

# Test 2: ExecStart contains NO sandboxing that breaks pty
printf '%s' "$OUT" | grep -q 'PrivateDevices' && no "must NOT set PrivateDevices" || ok "no PrivateDevices"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test-install-extract-timer.sh`
Expected: FAIL — installer does not exist.

- [ ] **Step 4: Implement `scripts/install-extract-timer.sh`**

```bash
#!/bin/bash
# install-extract-timer.sh — install/print/uninstall the systemd user timer
# that runs extract-drain.sh out-of-band.
#
#   (no flag)     print the rendered units + commands; touch nothing.
#   --apply       write units, daemon-reload, enable+start the timer.
#   --uninstall   disable+stop the timer and remove the unit files.
#
# Linger (loginctl enable-linger) is printed for the user to run, never run
# silently — it is a host-state change.
set -u

SDIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SDIR/.." && pwd)"
DRAINER="$SDIR/extract-drain.sh"
TPL_DIR="$REPO/systemd"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SVC="sb-extract-drain.service"
TIMER="sb-extract-drain.timer"

render_service() { sed "s#@EXEC@#bash $DRAINER#g" "$TPL_DIR/$SVC"; }

case "${1:-}" in
  --uninstall)
    systemctl --user disable --now "$TIMER" 2>/dev/null || true
    rm -f "$UNIT_DIR/$SVC" "$UNIT_DIR/$TIMER"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "uninstalled: removed $SVC + $TIMER"
    ;;
  --apply)
    mkdir -p "$UNIT_DIR"
    render_service > "$UNIT_DIR/$SVC"
    cp "$TPL_DIR/$TIMER" "$UNIT_DIR/$TIMER"
    systemctl --user daemon-reload
    systemctl --user enable --now "$TIMER"
    echo "applied: $SVC + $TIMER installed and timer enabled."
    echo "Run this yourself to keep the timer alive without an active login:"
    echo "    loginctl enable-linger \"$USER\""
    ;;
  *)
    echo "# === $SVC (would be written to $UNIT_DIR) ==="
    render_service
    echo
    echo "# === $TIMER ==="
    cat "$TPL_DIR/$TIMER"
    echo
    echo "# To install:   bash $0 --apply"
    echo "# Then run:     loginctl enable-linger \"$USER\""
    echo "# To remove:    bash $0 --uninstall"
    ;;
esac
```

- [ ] **Step 5: chmod + run test to verify pass**

Run: `chmod +x scripts/install-extract-timer.sh && bash tests/test-install-extract-timer.sh`
Expected: `Results: 7 passed, 0 failed`

- [ ] **Step 6: shellcheck both new shell files**

Run: `shellcheck scripts/install-extract-timer.sh`
Expected: only baseline-style infos; no errors/warnings.

- [ ] **Step 7: Commit**

```bash
git add systemd/ scripts/install-extract-timer.sh tests/test-install-extract-timer.sh
git commit -m "feat(extract): systemd user timer templates + reviewable installer

install-extract-timer.sh prints units by default, --apply installs+enables,
--uninstall reverses. Linger is surfaced for the user to run, not run silently.
Service deliberately omits PrivateDevices (breaks claude pty).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: version bump, full suite, reviews, smoke

**Files:**
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Bump version**

In `.claude-plugin/plugin.json`, change `"version": "0.12.0"` → `"version": "0.13.0"`.

- [ ] **Step 2: Full test suite**

Run: `SB_RUN_ALL_QUIET=1 bash tests/run-all.sh`
Expected: `ALL GREEN` — includes the three new tests; vitest unaffected (no TS changed).

- [ ] **Step 3: shellcheck the whole new surface**

Run: `shellcheck scripts/extract-drain.sh scripts/install-extract-timer.sh tests/test-extract-drain.sh tests/test-extraction-helpers.sh tests/test-install-extract-timer.sh`
Expected: no errors; only baseline infos.

- [ ] **Step 4: Manual smoke (real extraction, outside a session)**

Run (in a plain terminal, NOT inside Claude Code): `bash scripts/extract-drain.sh; cat ~/.second-brain/.extractor-health.json`
Expected: health `backend=cli-oauth status=ok`; one transcript moves to `outcome:"ok"` in `~/.second-brain/.extraction-state.jsonl`; `~/.second-brain/error-log.jsonl` shows no new extractor errors. (This verifies OAuth auth works from a non-interactive context — the spec §2 risk.) If it fails on auth, capture the error and stop — do not claim success.

- [ ] **Step 5: Code review + security review**

Invoke `/review` and `/security-review` on the branch diff. Focus: the drainer's `do_extract`/`SB_EXTRACT_STUB` seam (no injection from transcript content/filename), the installer's `sed @EXEC@` substitution (path quoting), and the systemd unit (no pty-breaking sandboxing). Address findings.

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "chore: bump to 0.13.0 — out-of-band extraction drainer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** §3 done-set → Task 1 (`sb_extraction_done/_fails`) + Task 2 state writes. §4 drainer → Task 2. §5 shared core → Task 1 (`sb_extract_transcript`, `sb_slug_from_archived_transcript`); stop-extract untouched as specced. §6 units → Task 3 templates. §7 installer → Task 3 `install-extract-timer.sh`. §8 error handling → drainer fail-soft + retry/terminal (Task 2). §9 testing → Tasks 1-3 tests + Task 4 smoke. No gaps.
- **Placeholder scan:** none — full code in every step; `@EXEC@` is an explicit render token, substituted in Task 3 Step 4.
- **Type/name consistency:** `sb_extraction_done`, `sb_extraction_fails`, `sb_slug_from_archived_transcript`, `sb_extract_transcript`, `SB_DRAIN_BATCH`, `SB_DRAIN_MAX_FAILS`, `SB_EXTRACT_STUB`, `.extraction-state.jsonl`, outcomes `ok|error|retry` used identically across helpers, drainer, and tests.

## Out of scope (per spec §10)
Real-time inotify daemon; seeding done-set from dream coverage; cron fallback; `stop-extract.sh` adopting the shared helper; a TS `sb extract` subcommand.
