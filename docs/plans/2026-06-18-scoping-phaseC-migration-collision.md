# Phase C — Migration, Setup-Collision & Final Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the project-scoping model: deterministic data migration (Layer 1), opt-in semantic re-attribution (Layer 2), setup collision-detection with `git_remote` identity (Layer 3) — and finish *all* outstanding fixes: the two pre-existing Windows bugs and the deferred Phase B Minor cleanups.

**Architecture:** Three loosely-coupled parts. **Part A (scoping completion)** adds `git_remote` to the project identity, a testable `projects.jsonl` hardening function invoked by a new `0.33.0` upgrade migration, a setup collision-detection helper that prompts on identity mismatch, and an opt-in maintainer backfill mode. **Part B (cross-OS bugs)** fixes a Windows path-separator bug in the raw-capture TSV and makes the dream-lifecycle symlink security test robust on filesystems without symlink support (the guard itself is correct and untouched). **Part C (cleanups)** clears the deferred Phase B Minor findings. Parts B and C are independent of A and may be executed in any order.

**Tech Stack:** bash, `jq`, git; TypeScript (ESM, `node>=22`), vitest (`npm test` = `vitest run`), esbuild bundles (`npm run build`).

## Global Constraints

- **Read-tolerant, additive, backup-before-any-rewrite, fail-loud, never destructive without confirmation.** Every new field is OPTIONAL; absent = today's behavior. The only file rewrite (`projects.jsonl` hardening) backs up first and leaves the file intact + warns if it cannot parse.
- **Layer 2 is OPT-IN.** `/upgrade` finishes Layer 1 then **PRINTS** "run `/second-brain:maintain`…"; it MUST NOT auto-dispatch the maintainer (the user rejected auto-dispatch twice). Respects the maintainer's 50-change cap.
- **Collision = prompt, never silent.** Setup never merges or clobbers two different repos sharing a slug; on identity mismatch it prompts (path-qualified slug / rename / use-existing-abort).
- **`git_remote` is read** via `git -C <dir> remote get-url origin 2>/dev/null` (empty string if no remote / not a repo). It is persisted in `projects.jsonl` (so a later setup can compare identity) and CR-stripped.
- **Identity/parent fields fill LAZILY** — populated on the next `session-load`/`setup` per repo, never invented at upgrade time. Old records work as standalone until re-touched.
- **`origin:` on raw items is ALREADY DONE** (Phase A added it to `RawItem`, additive + read-tolerant). Layer 1 needs no further action for it. Do not re-add it.
- **Migration fires only when `installed < 0.33.0 <= current`.** The plan creates `skills/upgrade/migrations/0.33.0.md` AND bumps `.claude-plugin/plugin.json` `version` to `0.33.0`, or the migration never runs.
- **Bash↔TS slug parity is sacred; cross-OS path forms are canonicalized** (the `fix/0.30.2` Windows theme) — bash writes MSYS `/c/…`, node reads Windows `C:\…`; normalize before comparing (Phase B's `resolveSlugByPath` + `toBashPath` precedent).
- **jq stdout on Windows is CRLF** — any jq output written back to a data file MUST be `tr -d '\r'`-stripped to keep files LF-only.
- **Working dir for `npm`/`vitest`/`build`:** `mcp/`. Rebuild bundles (`npm run build`) after editing any bundled TS (`raw-capture-cli.ts` → `raw-capture-cli.bundle.js`) and stage `mcp/dist` (git-tracked).
- **Pre-existing failure gate:** the branch base has 14 pre-existing unit failures (in `path-guard`, `sb-cli`, `knowledge-search`, `knowledge-validate`) plus two pre-existing e2e failures THIS PLAN FIXES (`test-raw-capture` pending-path; `test-dream-lifecycle` symlink-escape on Windows). The gate is "no NEW failure," and Part B should turn those two e2e failures green on Windows.

---

## Part A — Scoping completion (migration + collision + git_remote)

### Task A1: `sb_git_remote` helper + session-load writes `git_remote`, clears stale `parent`

**Files:**
- Modify: `scripts/lib.sh` (add `sb_git_remote` after `sb_detect_project`)
- Modify: `scripts/session-load.sh` (capture `git_remote` ~line 21-22; APPEND block ~55-64; UPDATE block ~648-658)
- Test: `tests/test-session-load-jsonl-membership.sh` (extend)

**Interfaces:**
- Consumes: `sb_detect_project` (Phase B), the existing `slug parent root_path` read.
- Produces: `sb_git_remote <dir>` → echoes the origin remote URL (CR-stripped, empty if none). `projects.jsonl` records now also carry optional `git_remote`; the UPDATE block clears a stale `parent` when a repo is no longer a sub-project (de-parenting; resolves the Phase B T4 finding).

- [ ] **Step 1: Write the failing test**

Add to `tests/test-session-load-jsonl-membership.sh` (this harness uses `fail "msg"`/`pass "msg"` — match it; reuse `init_sandbox`/`run`/`count_entries_for`). Append before the final tally:

```bash
# --- Phase C: session-load records git_remote, and clears a stale parent on de-parenting ---
. "$PLUGIN_ROOT/scripts/lib.sh"   # for sb_git_remote in this test
GR=$(sb_git_remote "$PLUGIN_ROOT")   # this repo HAS an origin remote
[ -n "$GR" ] && pass "sb_git_remote reads origin" || fail "sb_git_remote returned empty for a repo with a remote"
[ -z "$(sb_git_remote "$TMP")" ] && pass "sb_git_remote empty for non-repo" || fail "sb_git_remote should be empty for a non-repo dir"

# de-parenting: a record that WAS a sub-project, re-registered from a dir with no parent → parent removed
init_sandbox "deparent"
printf '%s\n' '{"slug":"test-project","name":"test-project","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0,"parent":"oldroot","root_path":"/old/path"}' > "$BRAIN_DIR/projects.jsonl"
run   # run() drives session-load with cwd = test-project (a plain dir, no workspace manifest → no parent)
PARENT_AFTER=$(jq -r --arg s test-project 'select(.slug==$s)|.parent // "ABSENT"' "$BRAIN_DIR/projects.jsonl" | head -1)
[ "$PARENT_AFTER" = "ABSENT" ] && pass "stale parent cleared on de-parenting" || fail "stale parent not cleared (got: $PARENT_AFTER)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-session-load-jsonl-membership.sh`
Expected: `sb_git_remote` asserts FAIL (function undefined / empty), and "stale parent cleared" FAILS (the UPDATE block currently only sets, never clears, `parent`).

- [ ] **Step 3: Add `sb_git_remote` to `scripts/lib.sh`**

Add after the `sb_detect_project` function:

```bash
# Echo the origin remote URL of a dir's git repo (empty if no remote / not a repo). CR-stripped.
# Phase C: doubles as collision identity (compared against an existing project's stored git_remote).
sb_git_remote() {
  local dir; dir=$(printf '%s' "${1:-$PWD}" | tr -d '\r')
  git -C "$dir" remote get-url origin 2>/dev/null | tr -d '\r' | head -1
}
```

- [ ] **Step 4: Capture + write `git_remote` in `session-load.sh`; clear stale `parent`**

After the slug/parent/root_path read (~line 22), add:

```bash
git_remote=$(sb_git_remote "${CLAUDE_PROJECT_DIR:-$PWD}")
```

In the APPEND block, add the `--arg gr "$git_remote"` and the conditional merge (keep the existing parent/root_path merges):

```bash
      jq -nc --arg s "$slug" --arg n "$slug" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
             --arg p "$parent" --arg rp "$root_path" --arg gr "$git_remote" \
        '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}
         + (if $p  != "" then {parent:$p}      else {} end)
         + (if $rp != "" then {root_path:$rp}  else {} end)
         + (if $gr != "" then {git_remote:$gr} else {} end)' >> "$INDEX_FILE"
```

In the UPDATE block, add `--arg gr "$git_remote"`, refresh `git_remote`, and CLEAR a stale `parent` when detection found none (de-parenting):

```bash
  jq --arg s "$slug" --arg t "$TS" --arg p "$parent" --arg rp "$root_path" --arg gr "$git_remote" '
    if .slug == $s then
      .last_session_iso = $t
      | (if $rp != "" then .root_path  = $rp else . end)
      | (if $gr != "" then .git_remote = $gr else . end)
      | (if $p  != "" then .parent = $p  else del(.parent) end)
    else . end
  ' "$INDEX_FILE" > "$TMP_IDX" 2>/dev/null && mv "$TMP_IDX" "$INDEX_FILE" || rm -f "$TMP_IDX"
```

(Note: `root_path` is always non-empty from `sb_detect_project`, so it is only ever refreshed, never cleared. `parent` is empty for a root/standalone, so `del(.parent)` on empty correctly de-parents.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-session-load-jsonl-membership.sh`
Expected: all PASS — the `sb_git_remote` asserts, "stale parent cleared", and all pre-existing membership/monorepo assertions.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib.sh scripts/session-load.sh tests/test-session-load-jsonl-membership.sh
git commit -m "feat(identity): sb_git_remote + session-load records git_remote, clears stale parent (Phase C)"
```

---

### Task A2: `sb_harden_projects_jsonl` — testable Layer-1 hardening

**Files:**
- Modify: `scripts/lib.sh` (add `sb_harden_projects_jsonl`)
- Test: `tests/test-harden-projects-jsonl.sh` (new)

**Interfaces:**
- Produces: `sb_harden_projects_jsonl <path>` — backs up then rewrites a pretty-printed / duplicated / CRLF `projects.jsonl` to canonical one-record-per-line (dedup by slug, keep newest `last_session_iso`); idempotent (a clean file is left untouched, no backup); fail-loud (a truly unparseable file is left intact + a backup-free warning, return 1). Consumed by the `0.33.0` migration (Task A3).

- [ ] **Step 1: Write the failing test**

Create `tests/test-harden-projects-jsonl.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/lib.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fail=1; fi; }
TMP=$(mktemp -d)

# 1. pretty-printed multi-line single record → one compact line
P="$TMP/pretty.jsonl"
printf '{\n  "slug": "alpha",\n  "name": "alpha",\n  "last_session_iso": "2026-05-01T00:00:00Z",\n  "hot_byte_count": 0\n}\n' > "$P"
sb_harden_projects_jsonl "$P"
check "pretty → 1 line" "1" "$(grep -c . "$P")"
check "pretty slug kept" "alpha" "$(jq -r .slug "$P")"

# 2. duplicate slug → deduped to the NEWEST last_session_iso
D="$TMP/dup.jsonl"
printf '%s\n%s\n' \
  '{"slug":"beta","name":"beta","last_session_iso":"2026-01-01T00:00:00Z","hot_byte_count":0}' \
  '{"slug":"beta","name":"beta","last_session_iso":"2026-09-09T00:00:00Z","hot_byte_count":9}' > "$D"
sb_harden_projects_jsonl "$D"
check "dup → 1 record" "1" "$(grep -c . "$D")"
check "dup kept newest" "9" "$(jq -r .hot_byte_count "$D")"

# 3. already-canonical clean file → UNCHANGED, no backup created
C="$TMP/clean.jsonl"
printf '%s\n' '{"slug":"gamma","name":"gamma","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0}' > "$C"
BEFORE=$(cat "$C")
sb_harden_projects_jsonl "$C"
check "clean unchanged" "$BEFORE" "$(cat "$C")"
check "clean no backup" "0" "$(ls "$TMP"/clean.jsonl.bak.* 2>/dev/null | wc -l | tr -d ' ')"

# 4. truly malformed (non-JSON line) → left INTACT, returns 1
M="$TMP/bad.jsonl"
printf '%s\n' 'this is not json at all {{{' > "$M"
BEFORE_M=$(cat "$M")
sb_harden_projects_jsonl "$M"; rc=$?
check "malformed returns 1" "1" "$rc"
check "malformed left intact" "$BEFORE_M" "$(cat "$M")"

rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-harden-projects-jsonl.sh`
Expected: FAIL — `sb_harden_projects_jsonl: command not found`.

- [ ] **Step 3: Implement `sb_harden_projects_jsonl` in `scripts/lib.sh`**

Add after `sb_git_remote`:

```bash
# Layer-1 migration: canonicalize projects.jsonl. Tolerates pretty-printed / JSON-array /
# CRLF / duplicate-slug input; rewrites to one compact record per line (LF), dedup by slug
# keeping the newest last_session_iso. Idempotent: a clean file is left untouched (no backup,
# no churn). Fail-loud: a file jq cannot parse at all is left INTACT (return 1), no silent loss.
sb_harden_projects_jsonl() {
  local f="${1:?projects.jsonl path required}"
  [ -f "$f" ] && [ -s "$f" ] || return 0          # absent / empty = nothing to harden
  command -v jq >/dev/null 2>&1 || { echo "harden: jq required" >&2; return 0; }
  local tmp; tmp=$(mktemp)
  # -s slurps the whole file (handles pretty-print + JSON-array); flatten unwraps an array;
  # drop non-objects/slug-less; dedup by slug keeping newest; -c one compact object per value;
  # tr -d '\r' keeps the file LF-only despite jq's CRLF stdout on Windows.
  if ! jq -sc 'flatten | map(select(type=="object" and (.slug|type=="string") and .slug!=""))
               | group_by(.slug) | map(max_by(.last_session_iso // "")) | .[]' \
        "$f" 2>/dev/null | tr -d '\r' > "$tmp" || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "harden: could not parse $f — left intact (manual review)" >&2
    return 1
  fi
  if cmp -s "$f" "$tmp"; then rm -f "$tmp"; return 0; fi   # already canonical → no churn, no backup
  local bak; bak="$f.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$f" "$bak" && mv "$tmp" "$f" \
    && echo "harden: canonicalized $f (backup: $bak)" \
    || { rm -f "$tmp"; echo "harden: rewrite failed for $f" >&2; return 1; }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-harden-projects-jsonl.sh`
Expected: `ALL PASS` (pretty→1 line, dup→newest, clean unchanged + no backup, malformed intact + rc 1).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/test-harden-projects-jsonl.sh
git commit -m "feat(migration): sb_harden_projects_jsonl — backup+canonicalize+dedup, fail-loud (Phase C Layer 1)"
```

---

### Task A3: `0.33.0` upgrade migration + version bump

**Files:**
- Create: `skills/upgrade/migrations/0.33.0.md`
- Modify: `.claude-plugin/plugin.json` (`version`: `0.32.0` → `0.33.0`)

**Interfaces:**
- Consumes: `sb_harden_projects_jsonl` (Task A2). Read by the `/upgrade` skill's migration runner (selects `migrations/<ver>.md` where `installed < ver <= current` via `sort -V`).
- Produces: the Layer-1 deterministic migration (projects.jsonl hardening + flagged-dir report) and the Layer-2 opt-in PRINT pointing to `/second-brain:maintain`.

- [ ] **Step 1: Bump the plugin version**

In `.claude-plugin/plugin.json`, change the version line:

```json
  "version": "0.33.0",
```

- [ ] **Step 2: Verify the migration runner would select 0.33.0**

Run: `printf '%s\n' 0.32.0 0.33.0 | sort -V | tail -1`
Expected: `0.33.0` (confirms `0.33.0 > 0.32.0`, so an install at ≤ 0.32.0 upgrading to 0.33.0 fires this migration).

- [ ] **Step 3: Write the migration file**

Create `skills/upgrade/migrations/0.33.0.md`:

````markdown
# 0.33.0 — migration notes (M3 project-scoping model)

Ships the monorepo-aware project-scoping model. Most of M3 is **additive** (optional
`parent`/`root_path`/`git_remote` on `projects.jsonl`, `origin:` on raw items) and needs no
migration — old records work as standalone and fill their new identity fields LAZILY on the next
`session-load`/`setup`. One deterministic structural pass runs here; the semantic pass is opt-in.

## What changed

- **`projects.jsonl` hardening (Layer 1, deterministic, backup-first).** Older installs may have a
  hand-pretty-printed, CRLF-tainted, or duplicate-slug registry (two different repos named the same
  basename clobbering each other was the motivating bug). This pass canonicalizes it to one compact
  record per line, deduplicated by slug keeping the newest `last_session_iso`.
- **Lazy identity fill.** `root_path` / `git_remote` / `parent` populate per repo on the next
  `session-load`/`setup`; nothing is invented here.
- **`origin:` on raw items** is additive + read-tolerant (already shipped). Legacy items without it
  drain under the conservative active-slug default; the drain-guard flags rather than re-attributes.
- **Semantic re-attribution (Layer 2) is OPT-IN** and is the maintainer's job — see the action note.

## Action / idempotent check

Backup-first, idempotent (a clean registry is left untouched). Run:

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
sb_harden_projects_jsonl "$HOME/.second-brain/projects.jsonl"
```

Idempotent check: after the run, `grep -c . "$HOME/.second-brain/projects.jsonl"` equals the number
of distinct slugs, and `jq -s 'length' "$HOME/.second-brain/projects.jsonl"` parses without error.

**Flagged-dir reconciliation (report + confirm — never auto-delete).** If a top-level `scratch/` or
`~/knowledge/raw` exists and is non-empty, REPORT it for the operator to confirm cleanup; do not
delete. `.graph` is a non-issue (`graph/` is canonical); `regressions/` is harmless and left as-is.

```bash
for d in "$HOME/knowledge/raw" "$PWD/scratch"; do
  [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ] && echo "REVIEW: non-empty stray dir $d — confirm cleanup manually"
done
```

**Layer 2 — semantic re-attribution is OPT-IN (NOT run here).** PRINT this and stop:

```
M3 structural migration done. To attribute untagged wiki nodes to projects and build
part_of families, run /second-brain:maintain (explicit, LLM pass, 50-change cap). /upgrade
does NOT do this automatically.
```
````

- [ ] **Step 4: Verify the migration action on a fixture**

Run (simulates a pretty-printed legacy registry being hardened):

```bash
SB=$(mktemp -d); printf '{\n  "slug": "x",\n  "name": "x",\n  "last_session_iso": "2026-01-01T00:00:00Z",\n  "hot_byte_count": 0\n}\n' > "$SB/projects.jsonl"
( . scripts/lib.sh; sb_harden_projects_jsonl "$SB/projects.jsonl" ); grep -c . "$SB/projects.jsonl"; rm -rf "$SB"
```
Expected: prints `harden: canonicalized …` and `1` (one compact line).

- [ ] **Step 5: Commit**

```bash
git add skills/upgrade/migrations/0.33.0.md .claude-plugin/plugin.json
git commit -m "feat(upgrade): 0.33.0 migration — Layer-1 projects.jsonl hardening + Layer-2 opt-in print (Phase C)"
```

---

### Task A4: `setup` collision detection (= prompt) + writes `git_remote`

**Files:**
- Modify: `scripts/lib.sh` (add `sb_project_identity`)
- Modify: `skills/setup/SKILL.md` (Step 1 collision detection; Step 4 jq append gains `git_remote`)
- Test: `tests/test-setup-collision.sh` (new)

**Interfaces:**
- Consumes: `sb_git_remote` (A1), `sb_detect_project` (Phase B), the existing `projects.jsonl`.
- Produces: `sb_project_identity <projects.jsonl> <slug> <root_path> <git_remote>` → echoes one of `new` (slug not registered), `same` (registered + identity matches), or `collision` (registered + identity differs). The setup skill calls it and, on `collision`, PROMPTS (path-qualified slug / rename / use-existing-abort). Setup persists `git_remote`.

- [ ] **Step 1: Write the failing test**

Create `tests/test-setup-collision.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/lib.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fail=1; fi; }
TMP=$(mktemp -d); REG="$TMP/projects.jsonl"
printf '%s\n' '{"slug":"utils","name":"utils","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0,"root_path":"/repos/a/utils","git_remote":"git@github.com:me/a-utils.git"}' > "$REG"

# unregistered slug → new
check "new slug" "new" "$(sb_project_identity "$REG" "fresh" "/repos/fresh" "")"
# same slug + same remote → same project
check "same remote" "same" "$(sb_project_identity "$REG" "utils" "/anywhere" "git@github.com:me/a-utils.git")"
# same slug + DIFFERENT remote → collision
check "diff remote" "collision" "$(sb_project_identity "$REG" "utils" "/repos/b/utils" "git@github.com:me/b-utils.git")"
# same slug + both-empty remote + same root_path → same project
printf '%s\n' '{"slug":"local","name":"local","last_session_iso":"2026-05-01T00:00:00Z","hot_byte_count":0,"root_path":"/repos/local","git_remote":""}' >> "$REG"
check "no-remote same path" "same" "$(sb_project_identity "$REG" "local" "/repos/local" "")"
# same slug + both-empty remote + DIFFERENT root_path → collision
check "no-remote diff path" "collision" "$(sb_project_identity "$REG" "local" "/elsewhere/local" "")"

rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-setup-collision.sh`
Expected: FAIL — `sb_project_identity: command not found`.

- [ ] **Step 3: Implement `sb_project_identity` in `scripts/lib.sh`**

Add after `sb_harden_projects_jsonl`:

```bash
# Setup collision identity. Given the registry, a candidate slug and its dir identity, classify:
#   new       — no record with this slug
#   same      — record exists AND identity matches (same git_remote; or both empty + same root_path)
#   collision — record exists AND identity differs (two different repos sharing a slug)
# Path compare is form-canonicalized (MSYS /c vs Windows C:\, like resolveSlugByPath/toBashPath).
sb_project_identity() {
  local reg="$1" slug="$2" rp="$3" gr="$4"
  [ -f "$reg" ] || { echo "new"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "new"; return 0; }
  local rec; rec=$(jq -c --arg s "$slug" 'select(.slug==$s)' "$reg" 2>/dev/null | head -1)
  [ -n "$rec" ] || { echo "new"; return 0; }
  local ex_rp ex_gr
  ex_rp=$(printf '%s' "$rec" | jq -r '.root_path // ""')
  ex_gr=$(printf '%s' "$rec" | jq -r '.git_remote // ""')
  _norm() { printf '%s' "${1:-}" | tr -d '\r' | sed -E 's#\\#/#g; s#^([A-Za-z]):/#/\L\1/#; s#/+$##'; }
  if [ -n "$gr" ] || [ -n "$ex_gr" ]; then
    [ "$gr" = "$ex_gr" ] && echo "same" || echo "collision"
  else
    [ "$(_norm "$rp")" = "$(_norm "$ex_rp")" ] && echo "same" || echo "collision"
  fi
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-setup-collision.sh`
Expected: `ALL PASS` (new / same-remote / diff-remote collision / no-remote same-path / no-remote diff-path collision).

- [ ] **Step 5: Wire collision detection + `git_remote` into `setup/SKILL.md`**

In Step 1, after `sb_detect_project` sets `SLUG`/`PARENT`/`ROOT_PATH`, capture the remote and classify identity:

```bash
GIT_REMOTE=$(sb_git_remote "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
IDENT=$(sb_project_identity ~/.second-brain/projects.jsonl "$SLUG" "$ROOT_PATH" "$GIT_REMOTE")
echo "Identity check for slug=$SLUG: $IDENT"
```

Then, in PROSE (not a bash literal), instruct: **if `$IDENT` is `collision`, STOP and prompt the operator** — a different repo already owns this slug. Offer: (i) use the path-qualified slug `<root>__<leaf>` (the monorepo sub-project case — re-run detection treating the parent as the monorepo root), (ii) rename to a user-chosen unique slug (standalone collision — no auto-hashing), or (iii) use the existing project / abort. **Never merge or clobber.** Only proceed to scaffold/write once the operator resolves the collision (or `$IDENT` is `new`/`same`).

In Step 4's jq append, add `git_remote` (mirror the session-load APPEND merge):

```bash
  jq -nc --arg s "$SLUG" --arg n "$NAME" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg p "$PARENT" --arg rp "$ROOT_PATH" --arg gr "$GIT_REMOTE" \
    '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}
     + (if $p  != "" then {parent:$p}      else {} end)
     + (if $rp != "" then {root_path:$rp}  else {} end)
     + (if $gr != "" then {git_remote:$gr} else {} end)' \
    >> ~/.second-brain/projects.jsonl
```

While here, fix the deferred Phase B T7 setup nit: move the "skip if `$PARENT` empty" note in the reconciliation step (the Phase B Task-7 projection block) to BEFORE its bash block so it reads as a precondition.

- [ ] **Step 6: Run the test + commit**

Run: `bash tests/test-setup-collision.sh`
Expected: `ALL PASS`.

```bash
git add scripts/lib.sh skills/setup/SKILL.md tests/test-setup-collision.sh
git commit -m "feat(setup): collision detection via {root_path,git_remote} identity = prompt; persist git_remote (Phase C Layer 3)"
```

---

### Task A5: maintainer Layer-2 backfill mode (opt-in, documented)

**Files:**
- Modify: `agents/knowledge-maintainer.md` (add the opt-in backfill phase)
- Modify: `skills/maintain/SKILL.md` (note the backfill phase on an explicit run)
- Test: `tests/test-kb-project-suggest.sh` (new — smoke the existing suggest script the phase relies on)

**Interfaces:**
- Consumes: `kb-project-suggest.sh` (`--knowledge-dir <dir> --slug <slug>` → plurality `project:` facet of edge-neighbors) and `kb-project-backfill.sh` (part_of walk, never-overwrite facet set). Both already exist and are deterministic.
- Produces: a documented, OPT-IN maintainer phase that attributes untagged wiki nodes (staged, capped, reported) — invoked only by an explicit `/second-brain:maintain` run, never auto-dispatched.

- [ ] **Step 1: Write the failing test (smoke the suggest script the phase depends on)**

Create `tests/test-kb-project-suggest.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fail=1; fi; }
TMP=$(mktemp -d); KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings" "$KD/graph"
# two neighbors of "target" both carry project: acme → plurality suggests acme
printf -- '---\ntitle: A\nproject: acme\n---\n' > "$KD/wiki/learnings/a.md"
printf -- '---\ntitle: B\nproject: acme\n---\n' > "$KD/wiki/learnings/b.md"
printf -- '---\ntitle: T\n---\n'               > "$KD/wiki/learnings/target.md"
printf '%s\n%s\n' \
  '{"op":"assert","from":"target","to":"a","type":"relates","recorded_at":"2026-06-18T00:00:00Z"}' \
  '{"op":"assert","from":"target","to":"b","type":"relates","recorded_at":"2026-06-18T00:00:00Z"}' > "$KD/graph/edges.jsonl"
OUT=$(bash "$HERE/scripts/kb-project-suggest.sh" --knowledge-dir "$KD" --slug target)
check "plurality suggests acme" "acme" "$OUT"
# an unlabeled island (no neighbors with a project) → empty suggestion (never guesses)
printf '%s\n' '{"op":"assert","from":"lonely","to":"nowhere","type":"relates","recorded_at":"2026-06-18T00:00:00Z"}' >> "$KD/graph/edges.jsonl"
OUT2=$(bash "$HERE/scripts/kb-project-suggest.sh" --knowledge-dir "$KD" --slug lonely)
check "no-neighbor → empty" "" "$OUT2"
rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run the test to verify it (the script already exists — confirm behavior)**

Run: `bash tests/test-kb-project-suggest.sh`
Expected: `ALL PASS` — `kb-project-suggest.sh` already implements plurality suggestion; this test pins the contract the backfill phase relies on. (If it FAILS, the suggest script's contract differs from the doc — reconcile before writing the phase.)

- [ ] **Step 3: Document the opt-in backfill phase in `agents/knowledge-maintainer.md`**

Add a clearly-labeled opt-in phase describing the unattributed-KB backfill, with these exact properties:

```markdown
## Phase: Project backfill (opt-in, explicit /second-brain:maintain only — NOT on auto-runs)

Only on an explicit `/second-brain:maintain` (never an auto-dispatched run). For wiki pages that
carry NO `project:` facet, propose an attribution deterministically and stage it (subject to the
50-change/run cap, reported, never silent):

1. For each unattributed structured page <slug>, run:
   `bash "$CLAUDE_PLUGIN_ROOT/scripts/kb-project-suggest.sh" --knowledge-dir "$KD" --slug <slug>`
   It returns the plurality `project:` facet of the page's edge-neighbours, or empty (no guess).
2. Apply only NON-empty suggestions, capped at the 50-change budget, and only via the existing
   never-overwrite facet set (`kb-project-backfill.sh`'s `set_project`) — a page that already has a
   facet is never rewritten. Pages with an empty suggestion are LEFT unattributed (reported, not guessed).
3. Report: pages attributed, pages left unattributed (no neighbour signal), and any hit on the cap.

This phase is deterministic (reads the edge graph + neighbour facets) and additive. It is the
Layer-2 semantic re-attribution the `0.33.0` upgrade points operators to.
```

- [ ] **Step 4: Note the phase in `skills/maintain/SKILL.md`**

Add one line to the explicit-run description: on an explicit `/second-brain:maintain`, the maintainer also runs the opt-in **project backfill** phase (attributes untagged nodes via `kb-project-suggest.sh`, staged/capped/reported) — auto-dispatched runs skip it, exactly like the 4b/4c bulk phases.

- [ ] **Step 5: Commit**

```bash
git add agents/knowledge-maintainer.md skills/maintain/SKILL.md tests/test-kb-project-suggest.sh
git commit -m "feat(maintainer): opt-in Layer-2 project backfill phase via kb-project-suggest (Phase C)"
```

---

## Part B — Cross-OS bug fixes (pre-existing, fix/0.30.2 theme)

### Task B1: raw-capture pending TSV path-separator (Windows)

**Files:**
- Modify: `mcp/src/tools/raw-capture-cli.ts:47` (the pending row path)
- Test: `tests/test-raw-capture.sh` (existing — the failing assertion at ~line 52)

**Interfaces:**
- Produces: the pending TSV work-list path column is forward-slash on all OSes (the maintainer drain + the bash test both expect POSIX paths).

- [ ] **Step 1: Confirm the failing assertion**

Run: `bash tests/test-raw-capture.sh`
Expected: FAIL — `pending row missing the item path` (on Windows the path column is `C:\…\<id>.md` with backslashes; the test greps `"$RAW/$PID.md"` with forward slashes).

- [ ] **Step 2: Fix the path emission**

In `mcp/src/tools/raw-capture-cli.ts`, the pending action (~line 47):

```ts
        const path = join(rawDir(brainDir, slug), `${i.id}.md`);
```

becomes (normalize the final joined path to forward slashes — no-op on POSIX):

```ts
        const path = join(rawDir(brainDir, slug), `${i.id}.md`).replace(/\\/g, '/');
```

(The `.replace` must be on the FULL joined path so every separator is normalized.)

- [ ] **Step 3: Rebuild the bundle**

Run: `cd mcp && npm run build`
(`raw-capture-cli.ts` ships in `raw-capture-cli.bundle.js`.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-raw-capture.sh`
Expected: PASS — including the pending-path assertion. (Sanity: `node mcp/dist/tools/raw-capture-cli.bundle.js pending` rows show `/…/<id>.md`, and `awk -F'\t' '{print NF}'` is `5` per row.)

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/raw-capture-cli.ts mcp/dist
git commit -m "fix(cross-os): forward-slash the pending TSV path column on Windows (Phase C)"
```

---

### Task B2: dream-lifecycle symlink-escape test robustness (Windows)

**Files:**
- Modify: `tests/test-dream-lifecycle.sh` (add a symlink-capability guard around the symlink subtest)

**Interfaces:**
- Produces: the symlink-escape security subtest runs where real symlinks exist (Unix/macOS/Linux) and SKIPS-with-reason where they do not (Windows/Git-Bash without Developer Mode), without weakening `dream-accept.sh`'s guard (which is unchanged and correct).

> **Root cause (verified):** the security guard in `dream-accept.sh` is correct. The TEST SETUP fails on Windows: Git-Bash's `ln -s` without admin/Developer Mode creates a regular file copy, not a symlink, so `find -type l` finds nothing, `dream-accept.sh` has nothing to refuse, returns 0, and the assertion (expecting refusal) fails. The fix makes the test skip where symlinks are unsupported — it does NOT touch the guard.

- [ ] **Step 1: Confirm the failing assertion**

Run: `bash tests/test-dream-lifecycle.sh`
Expected: on Windows, FAIL at `accept must REFUSE a staged out-of-tree symlink (escape)` (the only failing assertion; all others pass).

- [ ] **Step 2: Add a symlink-capability helper**

In `tests/test-dream-lifecycle.sh`, after the `setup` helper definition (near the top), add:

```bash
# True only if this filesystem creates REAL symlinks (Windows/Git-Bash without Developer Mode
# silently makes a file copy). The dream-accept escape guard can only be exercised where symlinks
# are real; the guard itself is OS-agnostic and unchanged.
supports_symlinks() {
  local d; d=$(mktemp -d)
  echo t > "$d/t.txt"; ln -s "$d/t.txt" "$d/l.txt" 2>/dev/null
  local ok=1; [ -L "$d/l.txt" ] && ok=0
  rm -rf "$d"; return $ok
}
```

- [ ] **Step 3: Guard the symlink subtest**

Wrap the out-of-tree-symlink subtest (the block beginning `setup "accept-symlink-escape"` through its `pass "accept refuses an out-of-tree staged symlink (escape blocked)"`) so it only runs when symlinks are real:

```bash
if supports_symlinks; then
  # --- Subtest 5b (C hardening): a staged OUT-OF-TREE symlink (escape) is REFUSED ---
  # ... existing subtest body UNCHANGED ...
  pass "accept refuses an out-of-tree staged symlink (escape blocked)"
else
  echo "SKIP: out-of-tree symlink escape test — filesystem does not support real symlinks (Windows without Developer Mode)"
  pass "symlink-escape guard not exercised here (no symlink support); covered on Unix/macOS/Linux"
fi
```

(Only the symlink-DEPENDENT subtest is wrapped. Any non-symlink lifecycle subtests stay outside the guard. `dream-accept.sh` is NOT modified — the real security guard is preserved.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-dream-lifecycle.sh`
Expected: on Windows, the symlink subtest reports `SKIP:` + a pass, and the whole suite is green; on a symlink-capable FS, the full guard subtest runs as before.

- [ ] **Step 5: Commit**

```bash
git add tests/test-dream-lifecycle.sh
git commit -m "test(cross-os): skip symlink-escape subtest where symlinks unsupported; guard unchanged (Phase C)"
```

---

## Part C — Phase B Minor cleanups (deferred review findings)

### Task C1: TypeScript test/comment cleanups (Phase B Minors T1, T2, T5)

**Files:**
- Modify: `mcp/src/tools/project-registry.test.ts` (remove unused import; add empty-slug test — T1)
- Modify: `mcp/src/tools/project-dir.ts` (restore the pin-tier comment bullet — T2)
- Modify: `mcp/test/project-dir.test.ts` (add cwd-registry-vs-known-project test — T2)
- Modify: `mcp/src/tools/knowledge-search.test.ts` (assert the global page is present — T5)

**Interfaces:** none new — coverage + comment fidelity only.

- [ ] **Step 1: T1 — remove the unused `mkdirSync` import + add the empty-slug guard test**

In `mcp/src/tools/project-registry.test.ts`, remove `mkdirSync` from the `from 'fs'` import (it is unused). Add a `loadRegistry` case asserting the empty-slug guard:

```ts
  it('skips a record whose slug is the empty string', () => {
    const dir = brain('{"slug":""}\n{"slug":"real"}\n');
    expect(loadRegistry(dir).map(r => r.slug)).toEqual(['real']);
    rmSync(dir, { recursive: true, force: true });
  });
```

- [ ] **Step 2: T2 — restore the pin-tier comment bullet in `project-dir.ts`**

In `mcp/src/tools/project-dir.ts`, the multi-paragraph comment above `resolveActiveSlug` lost its pin-tier sentence during the Phase B rewrite. Add a sentence documenting the pin tier so the prose matches the (complete) one-line precedence summary, e.g. after the cwd-known-project sentence:

```ts
  // …then the .active-session-slug pin (when it names a known project) is the per-session
  // fallback; bare cwd basename is the last resort.
```

- [ ] **Step 3: T2 — add the cwd-registry-supersedes-known-basename test**

In `mcp/test/project-dir.test.ts`, inside the `registry-path` describe block, add (this reuses the block's existing `brainWithChild()` helper):

```ts
  it('a cwd registry-path match wins over a same-basename known project', () => {
    const dir = brainWithChild();
    // also seed a bare `api` known project; the registry root_path match must still win
    mkdirSync(join(dir, 'projects', 'api'), { recursive: true });
    writeFileSync(join(dir, 'projects', 'api', 'PROJECT.md'), '# PROJECT: api\n');
    const slug = resolveActiveSlug(dir, {} as NodeJS.ProcessEnv, () => '/repos/acme/packages/api/src');
    expect(slug).toBe('acme__api');   // registry-path tier precedes the known-basename tier
    rmSync(dir, { recursive: true, force: true });
  });
```

- [ ] **Step 4: T5 — assert the global page is present in the family test**

In `mcp/src/tools/knowledge-search.test.ts`, in the SP-1 family test, add an assertion that the global (`project: ''`) page is in-scope (it hardens the test's own broaden premise):

```ts
  expect(slugs.some(s => /global/.test(s))).toBe(true);   // global pages stay in-scope (tier 4)
```

- [ ] **Step 5: Run the touched tests + typecheck**

Run: `cd mcp && npx vitest run src/tools/project-registry.test.ts test/project-dir.test.ts src/tools/knowledge-search.test.ts && npm run typecheck`
Expected: project-registry + project-dir green (incl. the new cases); knowledge-search shows only its 4 known pre-existing failures (lines 79/119/130/144) — the family test (now with the global assertion) still passes; typecheck clean.

- [ ] **Step 6: Build + commit**

Run: `cd mcp && npm run build` (keeps the `project-dir.ts` comment change reflected in the bundle; harmless).

```bash
git add mcp/src/tools/project-registry.test.ts mcp/src/tools/project-dir.ts mcp/test/project-dir.test.ts mcp/src/tools/knowledge-search.test.ts mcp/dist
git commit -m "chore(scoping): Phase B Minor cleanups — unused import, empty-slug + precedence + global tests, pin comment (Phase C)"
```

---

### Task C2: bash cleanup — hoist `ALT` out of the dream-snapshot loop (Phase B Minor T6)

**Files:**
- Modify: `scripts/dream-snapshot.sh` (compute `ALT` once, before the transcript loop)

**Interfaces:** none — micro-perf + readability; behavior identical.

- [ ] **Step 1: Confirm current behavior (regression baseline)**

Run: `bash tests/test-dream-lifecycle.sh`
Expected: green (after Task B2 — or the single pre-existing symlink skip if B2 not yet done). Note the result so Step 4 can confirm no change.

- [ ] **Step 2: Hoist `ALT`**

In `scripts/dream-snapshot.sh`, the family-alternation `ALT=$(printf '%s' "$FILTER_SLUGS" | tr ' ' '|')` is currently computed inside the per-transcript loop. Move that single assignment to ABOVE the transcript loop (compute once, only when `FILTER_SLUGS` is non-empty), and reference `$ALT` inside the loop. The grep line inside the loop stays `echo "$fname" | grep -qE "_(${ALT})_" || continue`.

- [ ] **Step 3: Verify nothing else changed**

Run: `cd mcp && npx vitest run src/tools/dream.test.ts`
Expected: 18/18 pass (the `buildSnapshotArgs` family contract is unaffected — this is a shell-only change to the snapshot script).

- [ ] **Step 4: Run the dream e2e + commit**

Run: `bash tests/test-dream-lifecycle.sh`
Expected: same result as Step 1 (no behavior change).

```bash
git add scripts/dream-snapshot.sh
git commit -m "chore(dream): hoist family-slug alternation out of the transcript loop (Phase C)"
```

---

## Self-Review (against the spec + the user's "finish all fixes")

**Spec coverage — "Migration & setup-collision RESOLVED" §:**
- Layer 1 deterministic (projects.jsonl hardening, backup-first, dedup-by-slug-keep-newest, fail-loud) → Task A2 (`sb_harden_projects_jsonl` + test) + Task A3 (migration invokes it). ✓
- Lazy identity fill (`root_path`/`git_remote`/`parent` on next session-load/setup) → A1 (session-load), A4 (setup); A3 documents it. ✓
- `origin:` on raw items → already shipped in Phase A; A3 notes it, no action. ✓ (explicitly NOT re-added)
- Flagged-dir reconciliation = report + confirm → A3 migration prints REVIEW lines, never deletes. ✓
- Layer 2 OPT-IN, /upgrade PRINTS only → A3 print + A5 maintainer phase (explicit-run only, capped, deterministic via kb-project-suggest). ✓
- Layer 3 setup collision = prompt, `{root_path, git_remote}` identity, never merge/clobber → A4 (`sb_project_identity` + setup prompt prose). ✓
- `git_remote` captured + compared (and persisted so a later setup can compare) → A1/A4 (`sb_git_remote`, written in both writers, compared in `sb_project_identity`). ✓

**"Finish all fixes" coverage:**
- Pre-existing Windows bug — raw-capture pending path → Task B1. ✓
- Pre-existing Windows bug — dream-lifecycle symlink-escape (test setup, not guard) → Task B2 (skip-with-reason; guard untouched). ✓
- Phase B deferred Minors — T1/T2/T5 (TS) → C1; T6 (bash) → C2; T4 (de-parent clear) → folded into A1; T7 (setup prose nit) → folded into A4. ✓ (T2 `here` var rename and T6 empty-family test are intentionally NOT done: cosmetic / impossible-state — noted, not silently dropped.)

**Placeholder scan:** every code step carries complete code or an exact command. The two SKILL.md prose edits (A4 collision prompt; A5 maintainer phase) are prose-by-design (LLM-executed skill bodies); their testable logic is extracted into `sb_project_identity` (A4) and `kb-project-suggest.sh` smoke (A5), so each has a real test. No TBD/TODO.

**Type/interface consistency:** `sb_git_remote` (A1) is consumed by `sb_project_identity` (A4) and both setup/session-load writers; `sb_harden_projects_jsonl` (A2) is consumed by the A3 migration; the `projects.jsonl` record shape `{slug,name,last_session_iso,hot_byte_count,parent?,root_path?,git_remote?}` is written identically by session-load (A1) and setup (A4) and read by `sb_project_identity` (A4) and `ProjectRecord` (the TS interface — `git_remote` is additive/optional and read-tolerant there; no TS reader requires it). Migration target `0.33.0` matches the plugin.json bump (A3).

**Scope:** Part A = the approved migration/collision design. Parts B/C = the user's "finish all fixes" (independent of A; reorderable). No new scoping behavior beyond the spec.
