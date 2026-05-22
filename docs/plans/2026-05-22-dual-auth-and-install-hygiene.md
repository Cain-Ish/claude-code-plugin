# Dual-auth & install-hygiene Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Make the extractor work cleanly on both auth modes (Claude subscription / OAuth and Anthropic API key) and close the install-hygiene gaps that cause silent capability loss across upgrades.

**Architecture:** Three small, independent changes wired together. (1) Add a `CLAUDECODE` detection at the top of `sb_invoke_extractor` so we never burn a 40s timeout on a recursive-claude attempt we know will fail. (2) Make the upgrade skill run `install-vector-deps.sh` when the runtime smoke-import of `@huggingface/transformers` fails — closes the bundle-vs-node_modules gap that left 175/254 episodic exchanges un-embedded. (3) Add an `sb auth` CLI surface so the user can verify and switch modes without reading the source.

**Tech Stack:** Bash (lib.sh, session-load.sh, install-vector-deps.sh, sb CLI), Node.js (smoke imports), shellcheck-clean.

**Non-goals (explicitly out of scope of this plan):**
- Building an out-of-process extractor queue for OAuth-only users. Deferred — flagged as a separate plan if needed after T1 ships and we see how often the queued-warn banner fires.
- Rewriting the pty-retry path. The existing Backend 1b is left alone; the recursive-CLI fix is upstream of it.
- Removing `--bare` mode usage. `--bare` is still the right call when `ANTHROPIC_API_KEY` is set outside Claude Code.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `scripts/lib.sh` | `sb_invoke_extractor` backend selection | Add a recursive-claude short-circuit at the start; document the auth matrix |
| `bin/sb` (`bin/sb-entry`) | User-facing CLI | Add `sb auth status` and `sb auth doctor` subcommands |
| `skills/upgrade/SKILL.md` | Migration table | Add 2.9.0–2.10.3 rows; add a "vector-deps health" idempotent step that runs `install-vector-deps.sh` whenever the transformers import fails |
| `skills/setup/SKILL.md` | One-time setup | Add the auth-mode question (subscription vs API key) to the seed flow |
| `tests/test-lib-extractor-backend.sh` | New regression test | Verify backend selection given the four (CLAUDECODE × ANTHROPIC_API_KEY) cases |
| `tests/test-upgrade-vector-deps.sh` | New regression test | Verify upgrade skill triggers vector-deps install on missing import |

---

## Task 1: Add recursive-claude short-circuit to `sb_invoke_extractor`

**Why:** Today, when we are inside Claude Code (`CLAUDECODE=1`) and only OAuth is configured, every Stop/PreCompact cycle spends ~40s in Backend 1 waiting for `claude -p` to hang, then ~40s more in the pty retry, then either falls back to API-key curl or fails. That's 80s of wasted timeout per session exit (and ec=124 every time, polluting the error log). Detect the condition once up front and either route straight to Backend 2 (API key) or fail fast with a `health=queued` record so the banner is accurate.

**Files:**
- Modify: `scripts/lib.sh:562-720` (the `sb_invoke_extractor` function body, between the `caller_script` line and `# Backend 1: claude CLI`)
- Test: `tests/test-lib-extractor-backend.sh` (new)

- [ ] **Step 1: Write the failing test**

Create `tests/test-lib-extractor-backend.sh`:

```bash
#!/usr/bin/env bash
# Verify sb_invoke_extractor backend selection.
# We stub `claude` and `curl` and observe which backend was chosen via the
# health-marker file.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stub the second-brain dir
export BRAIN_DIR="$TMP/.sb"
mkdir -p "$BRAIN_DIR"

# Stub claude CLI that always hangs (simulates recursive-claude)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
chmod +x "$TMP/bin/claude"

# Stub curl that returns a canned valid response
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"content":[{"text":"{\"decisions\":[],\"blockers\":[]}"}]}'
EOF
chmod +x "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH"
source "$SCRIPT_DIR/scripts/lib.sh"

# Case A: inside Claude Code + API key set → must pick anthropic-api (NOT claude-cli)
export CLAUDECODE=1
export ANTHROPIC_API_KEY="sk-ant-test"
INPUT=$(mktemp); printf "hello" > "$INPUT"
OUT=$(mktemp); ERR=$(mktemp)
SB_EXTRACT_TIMEOUT=2 sb_invoke_extractor "claude-sonnet-4-6" "test-system" "$INPUT" "$OUT" "$ERR" 2 || true
BACKEND=$(jq -r '.backend // "unknown"' "$BRAIN_DIR/extractor-health.json" 2>/dev/null || echo missing)
[ "$BACKEND" = "anthropic-api" ] || { echo "FAIL A: backend=$BACKEND (expected anthropic-api)"; exit 1; }
echo "PASS A: in-CC + API key → anthropic-api"

# Case B: inside Claude Code + no API key → must record health=queued, not burn 40s on CLI
unset ANTHROPIC_API_KEY
rm -f "$BRAIN_DIR/extractor-health.json"
START=$(date +%s)
SB_EXTRACT_TIMEOUT=2 sb_invoke_extractor "claude-sonnet-4-6" "test-system" "$INPUT" "$OUT" "$ERR" 2 || true
ELAPSED=$(( $(date +%s) - START ))
HEALTH=$(jq -r '.status // "unknown"' "$BRAIN_DIR/extractor-health.json" 2>/dev/null || echo missing)
[ "$ELAPSED" -lt 5 ] || { echo "FAIL B: elapsed=${ELAPSED}s (expected <5s, no CLI hang)"; exit 1; }
[ "$HEALTH" = "queued" ] || { echo "FAIL B: status=$HEALTH (expected queued)"; exit 1; }
echo "PASS B: in-CC + no API key → fast-fail with queued"

echo "ALL PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test-lib-extractor-backend.sh
```
Expected: `FAIL A` (the current code burns the timeout instead of picking anthropic-api).

- [ ] **Step 3: Add the short-circuit at the top of `sb_invoke_extractor`**

In `scripts/lib.sh`, immediately after the `caller_script=...` line (around L562), insert:

```bash
  # --- Backend pre-selection (recursive-claude guard) ----------------------
  # When invoked from inside a Claude Code session (Stop / PreCompact hooks),
  # spawning `claude -p` re-enters the same OAuth-locked process and reliably
  # hangs to the timeout. Two safe paths from here:
  #   (a) ANTHROPIC_API_KEY set → jump straight to Backend 2 (direct curl).
  #   (b) only OAuth available → record health=queued and exit non-fatal so the
  #       SessionStart banner can surface the configuration accurately. Real-
  #       time extraction in this mode is structurally impossible; users on a
  #       Claude subscription need either an API key or an out-of-band runner.
  if [ "${CLAUDECODE:-}" = "1" ] && [ "${SB_FORCE_CLI:-0}" != "1" ]; then
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      sb_write_extractor_health "queued" "queued" \
        "in-session OAuth only — recursive-claude would hang; set ANTHROPIC_API_KEY or run \`sb auth doctor\`"
      return 0
    fi
    # else: API key is set; fall through to Backend 2 below by skipping Backend 1.
    SB_SKIP_CLI=1
  fi
```

Then guard the existing `if command -v claude >/dev/null 2>&1; then` (currently L570) with:

```bash
  if [ "${SB_SKIP_CLI:-0}" != "1" ] && command -v claude >/dev/null 2>&1; then
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test-lib-extractor-backend.sh
```
Expected: `PASS A`, `PASS B`, `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/test-lib-extractor-backend.sh
git commit -m "fix(extractor): skip CLI under CLAUDECODE; queued-health when OAuth-only"
```

---

## Task 2: Wire `install-vector-deps.sh` into the upgrade migration

**Why:** The mcp bundle marks `@huggingface/transformers` as `--external` because its native binaries can't be statically packed. On a fresh install or cache wipe, `node_modules/@huggingface/transformers` is missing and the bundle silently fails to load it at runtime — that's the bug that left 175/254 episodic exchanges with empty embeddings until we ran the script manually today. The upgrade skill is the right place to gate this: its job is to run idempotent migrations between installed and current version.

**Files:**
- Modify: `skills/upgrade/SKILL.md` (migration table — backfill 2.9.0–2.10.3 rows; add vector-deps health step)
- Test: `tests/test-upgrade-vector-deps.sh` (new)

- [ ] **Step 1: Write the failing test**

Create `tests/test-upgrade-vector-deps.sh`:

```bash
#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build a fake plugin root with mcp/ + bin/
mkdir -p "$TMP/plugin/mcp/dist" "$TMP/plugin/bin"
cp "$SCRIPT_DIR/bin/install-vector-deps.sh" "$TMP/plugin/bin/"

cat > "$TMP/plugin/mcp/package.json" <<'EOF'
{ "name": "fake-mcp", "version": "1.0.0", "type": "module",
  "dependencies": { "@huggingface/transformers": "*" } }
EOF

# Stub npm so we don't actually pull 70MB; just create the marker file.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
# Pretend to install: create the marker.
MARKER="$(pwd)/node_modules/@huggingface/transformers/package.json"
mkdir -p "$(dirname "$MARKER")"
echo '{"name":"@huggingface/transformers","version":"4.2.0"}' > "$MARKER"
EOF
chmod +x "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH"
export CLAUDE_PLUGIN_ROOT="$TMP/plugin"

# Test 1: marker missing → installer runs, marker now present
bash "$TMP/plugin/bin/install-vector-deps.sh" >/dev/null
[ -f "$TMP/plugin/mcp/node_modules/@huggingface/transformers/package.json" ] \
  || { echo "FAIL: marker not created"; exit 1; }
echo "PASS: install-vector-deps creates marker"

# Test 2: re-run is idempotent
bash "$TMP/plugin/bin/install-vector-deps.sh" >/dev/null
echo "PASS: idempotent re-run"

echo "ALL PASS"
```

Note: this test exercises `install-vector-deps.sh` independently. The upgrade-skill change itself is content-only (markdown table rows) and is verified by reading.

- [ ] **Step 2: Run the test to verify the installer works**

```bash
bash tests/test-upgrade-vector-deps.sh
```
Expected: `ALL PASS`. (This should already pass because the script exists; we're locking in the contract.)

- [ ] **Step 3: Add migration rows to `skills/upgrade/SKILL.md`**

After the `**2.8.0**` row, append:

```markdown
| **2.9.0–2.10.3** | Catch-up bundle. (2.9.0) HarnessAudit Layer 3 — resource-scope guard + injection scanner + audit log. (2.10.0) HarnessAudit Layer 1 — tool-scope + flow-guard + SAR summary. (2.10.1) persona structure + wiki slug-only + hash-suppress fix + GC + rules-gap banner. (2.10.2) lint regex + auto-generated-orphan filter. (2.10.3) episodic index empty-embedding repair + observability + tests. | No precondition — all changes are additive code/data. Bumping the marker is sufficient. |
| **vector-deps health** (re-runs every upgrade) | Smoke-import `@huggingface/transformers` from `$CLAUDE_PLUGIN_ROOT/mcp`. On failure, run `bash $CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh`. Required because mcp bundles mark transformers `--external`, so a cache refresh ships dist/ without node_modules. Idempotent. | `cd "$CLAUDE_PLUGIN_ROOT/mcp" && node --input-type=module -e 'await import("@huggingface/transformers"); console.log("ok")' >/dev/null 2>&1` — if exit 0, skip. Otherwise run the installer; report network requirement explicitly. |
```

- [ ] **Step 4: Verify the rendered markdown is correct**

```bash
grep -c "vector-deps health" skills/upgrade/SKILL.md
grep -c "2.9.0–2.10.3" skills/upgrade/SKILL.md
```
Expected: `1` and `1`.

- [ ] **Step 5: Commit**

```bash
git add skills/upgrade/SKILL.md tests/test-upgrade-vector-deps.sh
git commit -m "fix(upgrade): catch-up 2.9.0-2.10.3 rows + vector-deps health migration"
```

---

## Task 3: Add `sb auth` CLI surface

**Why:** Users need a single command to see "which auth mode am I in?" and "how do I switch?" without grepping lib.sh. `sb auth status` prints the active mode and the four-cell matrix. `sb auth doctor` walks through both setup paths (subscription / API key) and validates the result.

**Files:**
- Modify: `bin/sb` (top-level dispatcher) — add `auth` subcommand
- Modify: `mcp/src/cli/sb-entry.ts` (if `sb` routes through it) — same
- Test: `tests/test-sb-auth-cli.sh` (new)

- [ ] **Step 1: Locate the sb CLI dispatcher**

```bash
head -40 bin/sb
file bin/sb
```

If `bin/sb` is a thin bash wrapper that delegates to `mcp/dist/cli/sb-entry.bundle.js`, the auth subcommand goes in the TS source. If it's a pure bash dispatcher, it stays in bash. Confirm before writing code.

- [ ] **Step 2: Write the failing test**

```bash
cat > tests/test-sb-auth-cli.sh <<'EOF'
#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Case: API key set → reports api-key mode
ANTHROPIC_API_KEY="sk-ant-x" "$SCRIPT_DIR/bin/sb" auth status 2>&1 | grep -q "mode: api-key" \
  || { echo "FAIL: expected mode: api-key"; exit 1; }
echo "PASS: api-key mode"

# Case: no key + claude on PATH → reports subscription mode (OAuth)
unset ANTHROPIC_API_KEY
"$SCRIPT_DIR/bin/sb" auth status 2>&1 | grep -qE "mode: (subscription|oauth)" \
  || { echo "FAIL: expected mode: subscription"; exit 1; }
echo "PASS: subscription mode"

echo "ALL PASS"
EOF
chmod +x tests/test-sb-auth-cli.sh
bash tests/test-sb-auth-cli.sh
```
Expected: FAIL (subcommand doesn't exist yet).

- [ ] **Step 3: Implement `sb auth status` and `sb auth doctor`**

Add to the sb dispatcher (path determined in Step 1):

```bash
cmd_auth() {
  case "${1:-status}" in
    status)
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        printf 'mode: api-key\nkey: %s… (len=%s)\nbackend: anthropic-api (direct curl)\n' \
          "$(printf '%s' "$ANTHROPIC_API_KEY" | head -c 10)" "${#ANTHROPIC_API_KEY}"
      elif command -v claude >/dev/null 2>&1; then
        printf 'mode: subscription\nbackend: claude CLI (OAuth via `claude /login`)\n'
        printf 'note: real-time extraction inside a Claude Code session is not possible in this mode\n'
        printf '      because of the recursive-claude OAuth lock. Set ANTHROPIC_API_KEY or rely on\n'
        printf '      the out-of-band extractor (not yet shipped — see docs/plans/ for design).\n'
      else
        printf 'mode: none\nbackend: none — set ANTHROPIC_API_KEY or run `claude /login`\n'
      fi ;;
    doctor)
      echo "Auth doctor — two supported modes:"
      echo
      echo "1. Anthropic API key (token plan)"
      echo "   export ANTHROPIC_API_KEY=sk-ant-..."
      echo "   Works in all contexts (Stop hooks, cron, CI). Recommended for daily driver."
      echo
      echo "2. Claude subscription (OAuth)"
      echo "   claude /login   # interactive browser flow"
      echo "   Works outside Claude Code. Inside Claude Code sessions the Stop/PreCompact"
      echo "   extractors will queue (see \`sb auth status\` for the recursive-claude note)."
      echo
      echo "After either, verify with: sb auth status" ;;
    *) echo "usage: sb auth {status|doctor}"; return 2 ;;
  esac
}
```

Then register `auth)` in the main case statement.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test-sb-auth-cli.sh
```
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add bin/sb tests/test-sb-auth-cli.sh   # adjust if also editing TS
git commit -m "feat(sb): add \`sb auth\` (status + doctor) for dual-auth UX"
```

---

## Task 4: Update SessionStart banner to display the active auth mode

**Why:** Today the banner only fires when the extractor *failed*. A user on a healthy API-key setup gets no signal that they're in api-key mode vs subscription mode. One quiet line at session start ("auth: api-key" or "auth: subscription (in-session extraction queued)") removes the surprise the next time the user wonders why extraction works on some machines and not others.

**Files:**
- Modify: `scripts/session-load.sh` (after the extractor-health banner block, before `0b. Episodic embeddings banner`)

- [ ] **Step 1: Add the auth-mode line**

In `scripts/session-load.sh`, after the closing `fi` of the extractor-health banner block (around L212), insert:

```bash
# 0a-bis. Auth-mode line — one quiet line so the user always knows which credential
# path is active. Suppress: SB_AUTH_LINE=off
if [ "${SB_AUTH_LINE:-on}" = "on" ]; then
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    sb_append "auth: api-key (direct anthropic-api)" "auth-mode-line" 120
  elif command -v claude >/dev/null 2>&1; then
    sb_append "auth: subscription (OAuth) — in-session extraction queued; run \`sb auth doctor\` to switch" "auth-mode-line" 200
  fi
fi
```

- [ ] **Step 2: Smoke-test by running session-load.sh manually**

```bash
ANTHROPIC_API_KEY=sk-ant-x bash scripts/session-load.sh 2>&1 | grep "auth:"
```
Expected: prints `auth: api-key …`.

```bash
unset ANTHROPIC_API_KEY; bash scripts/session-load.sh 2>&1 | grep "auth:"
```
Expected: prints `auth: subscription …`.

- [ ] **Step 3: Commit**

```bash
git add scripts/session-load.sh
git commit -m "feat(session-load): one-line auth-mode banner"
```

---

## Task 5: Run the one-shot operational fixes

These have no code; they're cleanup after the code changes are in.

- [ ] **Step 1: Re-index episodic embeddings**

```bash
rm ~/.second-brain/episodic-index.json
node ~/.claude/plugins/cache/second-brain/second-brain/2.10.3/mcp/dist/tools/episodic-index-cli.bundle.js
jq '.exchanges | map(select((.embedding|length)==0)) | length' \
  ~/.second-brain/episodic-index.json
```
Expected: final number is `0` (all exchanges embedded). Warn — this re-embeds 254 exchanges, takes a minute on Pi.

- [ ] **Step 2: Wiki cleanup — broken link**

`/home/cainish/.claude/projects/-home-cainish-Projects-claude-code-plugin/memory/feedback_source-over-symptom.md` references `[[source-over-symptom]]` which doesn't exist. Either create a placeholder wiki page or remove the wiki-link wrapper from the memory file (turn `[[source-over-symptom]]` into plain text). User-facing decision.

- [ ] **Step 3: Wiki cleanup — date-prefixed filenames**

7 pages have `YYYY-MM-DD-*.md` filenames. Rename to topic-only slugs and add the date to frontmatter `created:` (most already have it). Two-step per file: `git mv` then update any inbound `[[link]]`s. Defer if not appetised — these are warnings, not errors.

- [ ] **Step 4: Bump version + tag**

```bash
# Edit .claude-plugin/plugin.json: 2.10.3 → 2.11.0
git add .claude-plugin/plugin.json
git commit -m "release(v2.11.0): dual-auth UX + install hygiene"
git tag v2.11.0
```

---

## Verification

After all five tasks, run the full local smoke set:

```bash
bash tests/test-lib-extractor-backend.sh
bash tests/test-upgrade-vector-deps.sh
bash tests/test-sb-auth-cli.sh
bash tests/test-hooks-regression.sh
bash tests/test-episodic-index.sh
```
Expected: all `PASS` / `ALL PASS`.

Then trigger a real Stop hook by exiting and re-entering Claude Code and confirm:
- `~/.second-brain/error-log.jsonl` has *no* `ec=124` entries from `stop-extract.sh` (Task 1 worked).
- `~/.second-brain/extractor-health.json` shows `backend: anthropic-api` (or `queued`, depending on which mode you're testing).
- SessionStart banner shows the auth-mode line.

---

## Self-review

- Spec coverage: Task 1 = recursive-claude fix; Task 2 = upgrade migration gap + 2.9–2.10.3 backfill; Task 3 = `sb auth` UX; Task 4 = always-on auth banner; Task 5 = operational cleanup. The user's two asks ("fix all of it" + "make it work with both subscription and token plan") are both covered.
- Placeholders: none — every step has concrete code or commands.
- Type consistency: `sb_write_extractor_health "queued" "queued" …` — verify the existing signature accepts `queued` as both backend and status. Confirm in Task 1 Step 3 before writing.
