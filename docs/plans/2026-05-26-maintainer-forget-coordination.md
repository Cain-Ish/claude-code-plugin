# Maintainer ↔ Forgetting Coordination Implementation Plan

> **For agentic workers:** Implement task-by-task following TDD. Steps use checkbox (`- [ ]`). See `second-brain:test-driven-development` and `second-brain:verification-before-completion`. All work on `main` (sole-developer repo). Target **0.17.0**.

**Goal:** Make forgetting durable + the knowledge-maintainer archive-aware: fix the probe field, add a net-archived source of truth, auto-restore on re-creation (extraction + write-guard), and teach the maintainer the archive/forget model.

**Architecture:** A read-only net-archived helper (`wiki-archived-slugs.sh`) is the single source of truth. Both re-creation chokepoints — `merge-project-update.sh` (script extraction) and `wiki-write-guard.sh` (LLM Write) — consult it and **auto-restore** the original instead of creating a duplicate. The maintainer learns to honor the archive and surface (not execute) forget candidates; the dream stays the sole gated archiver.

**Tech Stack:** Bash + `jq`; existing hooks/scripts/agent prose; tests auto-discovered by `tests/run-all.sh`.

**Spec:** `docs/specs/2026-05-26-maintainer-forget-coordination-design.md`

---

## Decisions locked (from the spec)
- Tombstone policy = **auto-restore** (revive original, no duplicate). Un-archiving is **un-gated**; archiving stays gated by the dream.
- Write-tool path = restore + **deny with redirect-to-Edit**.
- Probe query field = `tags:` → `description:` → `title:`.
- One archive executor (dream); maintainer only **surfaces** candidates.
- **Fail-open**: a missing/empty/corrupt log never blocks a normal create.

## Grounded facts (verified during planning)
- `merge-project-update.sh`: `source "$(dirname "$0")/lib.sh"` (gives `BRAIN_DIR`); `KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"`, `KNOWLEDGE_WIKI="$KNOWLEDGE_DIR/wiki"`. Two create sites: cross-ref stub (inside `if ! find … "$safe_ref.md" … grep -q .`) and `wiki_updates` (after `existing=$(find … "$slug.md" …)`).
- `wiki-write-guard.sh`: PreToolUse hook; resolves `TOOL`, `FILE_PATH`; matches `*/knowledge/wiki/*/*.md`; has `deny()` emitting permission JSON; kill switch `SB_PERSONA_GATE=off`; `$(dirname "$0")` is `scripts/`.
- Real `tags:` shape: `tags: [a, b, c]` or `tags: []`.
- Archive log lines: `{"event":"archived"|"restored","slug":"…","category":"…","date":"…"}` at `$BRAIN_DIR/wiki-archive-log.jsonl`; archive files at `$BRAIN_DIR/wiki-archive/<category>/<slug>.md`.

## File structure

| Path | Responsibility |
|------|----------------|
| `scripts/wiki-archived-slugs.sh` | NEW — read-only net-archived query (default / `--has` / `--path`); fail-open |
| `scripts/wiki-forget-candidates.sh` | probe query: `tags:`→`description:`→`title:` |
| `scripts/merge-project-update.sh` | auto-restore at both create sites |
| `scripts/wiki-write-guard.sh` | restore+deny on Write to an archived slug |
| `agents/knowledge-maintainer.md` | "Cold-tier archive awareness" section |
| `tests/test-wiki-archived-slugs.sh` | helper behaviour |
| `tests/test-merge-auto-restore.sh` | extraction revive path |
| `tests/test-wiki-write-guard.sh` | tombstone restore+deny (+ frontmatter unaffected) |
| `tests/test-wiki-forget-{probe,score}.sh` | `tags:` fixtures |
| `tests/test-maintainer-archive-aware.sh` | structural guard |
| `.claude-plugin/plugin.json`, `skills/upgrade/SKILL.md` | 0.17.0 + migration row |

---

## Task 0: Verify-first (done during planning)

- [ ] **Step 1:** Confirm creation sites + env + tags shape — already captured above (merge sites, guard structure, `tags: [..]`). No action; recorded.

---

## Task 1: `scripts/wiki-archived-slugs.sh` (net-archived source of truth)

**Files:** Create `scripts/wiki-archived-slugs.sh`; Test `tests/test-wiki-archived-slugs.sh`.

- [ ] **Step 1: Write the failing test** `tests/test-wiki-archived-slugs.sh`

```bash
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/wiki-archived-slugs.sh"; [ -x "$SC" ] || chmod +x "$SC" 2>/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BRAIN_DIR="$T"
mkdir -p "$T/wiki-archive/entities"
LOG="$T/wiki-archive-log.jsonl"
# x archived then restored (=> net: NOT archived); y archived (=> net: archived)
printf '%s\n' \
  '{"event":"archived","slug":"x","category":"entities","date":"2026-05-26T01:00:00Z"}' \
  '{"event":"archived","slug":"y","category":"entities","date":"2026-05-26T02:00:00Z"}' \
  '{"event":"restored","slug":"x","category":"entities","date":"2026-05-26T03:00:00Z"}' > "$LOG"
printf 'archived\n' > "$T/wiki-archive/entities/y.md"   # y's archive file exists

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
out=$(bash "$SC")
printf '%s\n' "$out" | grep -qx "y	entities" && ok "lists net-archived y" || bad "y not listed ($out)"
printf '%s\n' "$out" | grep -q '^x' && bad "x still listed (restored)" || ok "x excluded (restored)"
bash "$SC" --has y; [ $? -eq 0 ] && ok "--has y -> 0" || bad "--has y nonzero"
bash "$SC" --has x; [ $? -eq 1 ] && ok "--has x -> 1" || bad "--has x not 1"
p=$(bash "$SC" --path y); [ "$p" = "$T/wiki-archive/entities/y.md" ] && ok "--path y -> file" || bad "--path y wrong: $p"
bash "$SC" --path x >/dev/null; [ $? -eq 1 ] && ok "--path x -> 1 (not net-archived)" || bad "--path x not 1"
# fail-open: no log
rm -f "$LOG"; out=$(bash "$SC"); [ -z "$out" ] && ok "no log -> empty (fail-open)" || bad "expected empty"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL** (`bash tests/test-wiki-archived-slugs.sh`; script absent).

- [ ] **Step 3: Write `scripts/wiki-archived-slugs.sh`**

```bash
#!/usr/bin/env bash
# Net-archived source of truth: which wiki slugs are currently archived (forgotten).
# Reads $BRAIN_DIR/wiki-archive-log.jsonl (append-only; events archived|restored).
# Net set = per slug, the LAST event in append order is "archived".
# Modes: (default) print "slug<TAB>category"; --has <slug> (exit 0/1);
#        --path <slug> (print archive file path, or exit 1 if not net-archived/file gone).
# Fail-open: missing/empty/corrupt log or no jq -> empty set, never errors a caller.
set -u
BD="${BRAIN_DIR:-$HOME/.second-brain}"; LOG="$BD/wiki-archive-log.jsonl"; ARC="$BD/wiki-archive"
command -v jq >/dev/null 2>&1 || exit 0
net() {
  [ -f "$LOG" ] || return 0
  jq -rs 'reduce .[] as $e ({}; .[$e.slug] = $e)
          | to_entries | map(.value)
          | map(select(.event=="archived"))
          | .[] | [.slug, (.category // "")] | @tsv' "$LOG" 2>/dev/null || true
}
case "${1:-}" in
  --has)
    s="${2:-}"; [ -n "$s" ] || exit 1
    net | cut -f1 | grep -qxF "$s" ;;
  --path)
    s="${2:-}"; [ -n "$s" ] || exit 1
    cat=$(net | awk -F'\t' -v s="$s" '$1==s{print $2; exit}')
    [ -n "$cat" ] || exit 1
    p="$ARC/$cat/$s.md"; [ -f "$p" ] || exit 1
    printf '%s\n' "$p" ;;
  *)
    net ;;
esac
```

- [ ] **Step 4: `chmod +x`; run test → `PASS:7 FAIL:0`.**

```bash
chmod +x scripts/wiki-archived-slugs.sh && bash tests/test-wiki-archived-slugs.sh
```

- [ ] **Step 5: Commit**

```bash
git add scripts/wiki-archived-slugs.sh tests/test-wiki-archived-slugs.sh
git commit -m "feat(memory): wiki-archived-slugs.sh — net-archived source of truth"
```

---

## Task 2: Probe field fix (`tags:` → `description:` → `title:`)

**Files:** Modify `scripts/wiki-forget-candidates.sh`; Test edits in `tests/test-wiki-forget-probe.sh`, `tests/test-wiki-forget-score.sh`.

- [ ] **Step 1: Update the probe/score test fixtures from `keywords:` to `tags:`**

In `tests/test-wiki-forget-probe.sh`, change the three fixture heredocs' `keywords:` lines to `tags:` arrays. Replace `keywords: zorblax handshake` → `tags: [zorblax, handshake]`; both `keywords: foobar caching` → `tags: [foobar, caching]`.

In `tests/test-wiki-forget-score.sh`, no `keywords:` is used (skip).

- [ ] **Step 2: Run probe test → FAIL** (probe still reads `keywords:`, which the fixtures no longer have → query falls back to title "Foobar note A" etc. → the cascade/protect assertions misbehave).

Run: `bash tests/test-wiki-forget-probe.sh`
Expected: FAIL (title-derived queries reintroduce the "note" noise).

- [ ] **Step 3: Fix the probe query derivation** in `scripts/wiki-forget-candidates.sh` — replace the `qy=$(...)` line:

```bash
  # Topic query from the MAINTAINED, distinctive field: tags: (strip [ ] and commas),
  # then description:, then title:. (Real pages use tags:, never keywords:.)
  qy=$(awk -F': ' '
        /^tags:/        {t=$2; gsub(/[][,]/," ",t)}
        /^description:/ {d=$2}
        /^title:/       {ti=$2}
        END{ q=(t ~ /[^ ]/)?t:((d!="")?d:ti); print q }' "$path" \
      | sed 's/"//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
```

- [ ] **Step 4: Run probe + score tests → PASS**

```bash
bash tests/test-wiki-forget-probe.sh && bash tests/test-wiki-forget-score.sh
```
Expected: both `FAIL:0` (cascade-safe: exactly one foobar; zorblax protected; scores clean).

- [ ] **Step 5: Commit**

```bash
git add scripts/wiki-forget-candidates.sh tests/test-wiki-forget-probe.sh tests/test-wiki-forget-score.sh
git commit -m "fix(memory): forget probe query reads tags: (not the absent keywords:)"
```

---

## Task 3: Extraction auto-restore (`merge-project-update.sh`)

**Files:** Modify `scripts/merge-project-update.sh` (both create sites); Test `tests/test-merge-auto-restore.sh`.

- [ ] **Step 1: Write the failing test** `tests/test-merge-auto-restore.sh`

```bash
#!/usr/bin/env bash
# Extraction must REVIVE an archived page (not create a duplicate) when a delta
# would re-create its slug.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE="$ROOT/scripts/merge-project-update.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BRAIN_DIR="$T/brain"; KD="$T/knowledge"
mkdir -p "$BRAIN_DIR/projects/proj" "$BRAIN_DIR/wiki-archive/concepts" "$KD/wiki/concepts"
printf '# proj\n' > "$BRAIN_DIR/projects/proj/PROJECT.md"
# archived page 'widget-x' (lives in the archive, NOT in the live wiki) + log
printf -- '---\ntitle: "Widget X"\ntype: concepts\ndescription: "original widget x"\ntags: [widget]\n---\n# Widget X\noriginal body.\n' > "$BRAIN_DIR/wiki-archive/concepts/widget-x.md"
printf '%s\n' '{"event":"archived","slug":"widget-x","category":"concepts","date":"2026-05-26T01:00:00Z"}' > "$BRAIN_DIR/wiki-archive-log.jsonl"

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
# delta tries to (re)create widget-x with new content
echo '{"wiki_updates":[{"category":"concepts","slug":"widget-x","action":"create","title":"Widget X","description":"d","content":"fresh info about widget x that resurged in a new session."}]}' \
  | bash "$MERGE" --knowledge-dir "$KD" --project proj >/dev/null 2>&1

[ -f "$KD/wiki/concepts/widget-x.md" ] && ok "page revived into live wiki" || bad "page not revived"
[ ! -f "$BRAIN_DIR/wiki-archive/concepts/widget-x.md" ] && ok "archive copy moved out (no duplicate)" || bad "archive copy still present"
grep -q '"event":"restored".*widget-x' "$BRAIN_DIR/wiki-archive-log.jsonl" && ok "restored event logged" || bad "no restored event"
n=$(find "$KD/wiki" -name 'widget-x.md' | wc -l); [ "$n" -eq 1 ] && ok "exactly one live copy" || bad "got $n copies"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
```

> Note: confirm the merge CLI flags (`--knowledge-dir`, `--project`) against `scripts/merge-project-update.sh`'s arg parser; adjust the invocation if the flag names differ.

- [ ] **Step 2: Run → FAIL** (merge creates a fresh duplicate / leaves the archive in place).

- [ ] **Step 3: Add auto-restore at the cross-ref stub site.** In `scripts/merge-project-update.sh`, replace the `if ! find … "$safe_ref.md" … grep -q .; then` block body so a net-archived slug is revived instead of stubbed:

```bash
    if ! find "$KNOWLEDGE_WIKI" -name "$safe_ref.md" -type f ! -name 'index.md' 2>/dev/null | grep -q .; then
      arch=$("$(dirname "$0")/wiki-archived-slugs.sh" --path "$safe_ref" 2>/dev/null) || arch=""
      if [ -n "$arch" ]; then
        acat=$(basename "$(dirname "$arch")"); mkdir -p "$KNOWLEDGE_WIKI/$acat"
        mv "$arch" "$KNOWLEDGE_WIKI/$acat/$safe_ref.md"
        printf '{"event":"restored","slug":"%s","category":"%s","date":"%s"}\n' \
          "$safe_ref" "$acat" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BRAIN_DIR/wiki-archive-log.jsonl"
        WIKI_WRITES=1; CHANGED=1
      else
        mkdir -p "$KNOWLEDGE_WIKI/entities"
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        {
          printf '%s\n' "---"
          printf 'title: "%s"\n' "$ref"
          printf 'type: entities\n'
          printf 'description: "Auto-created stub — needs expansion."\n'
          printf 'created: %s\n' "$ts"
          printf 'updated: %s\n' "$ts"
          printf 'related: []\n'
          printf 'tags: []\n'
          printf '%s\n\n' "---"
          printf '# %s\n\n' "$ref"
          printf 'TODO: expand.\n'
        } > "$KNOWLEDGE_WIKI/entities/$safe_ref.md"
        WIKI_WRITES=1; CHANGED=1
      fi
    fi
```

- [ ] **Step 4: Add auto-restore at the `wiki_updates` site.** Immediately AFTER the line `existing=$(find "$KNOWLEDGE_WIKI" -name "$slug.md" -type f ! -name 'index.md' 2>/dev/null | head -1)`, insert:

```bash
    if [ -z "$existing" ]; then
      arch=$("$(dirname "$0")/wiki-archived-slugs.sh" --path "$slug" 2>/dev/null) || arch=""
      if [ -n "$arch" ]; then
        acat=$(basename "$(dirname "$arch")"); mkdir -p "$KNOWLEDGE_WIKI/$acat"
        mv "$arch" "$KNOWLEDGE_WIKI/$acat/$slug.md"
        printf '{"event":"restored","slug":"%s","category":"%s","date":"%s"}\n' \
          "$slug" "$acat" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BRAIN_DIR/wiki-archive-log.jsonl"
        existing="$KNOWLEDGE_WIKI/$acat/$slug.md"; target_file="$existing"; action="update"
      fi
    fi
```

(The existing `if [ -n "$existing" ] && [ "$existing" != "$target_file" ]; then …` line that follows still runs; the new content lands as an update on the revived page.)

- [ ] **Step 5: Run new test + the existing merge test (no regression)**

```bash
bash tests/test-merge-auto-restore.sh && bash tests/test-merge-project-update.sh
```
Expected: new test `PASS:4 FAIL:0`; existing merge test still passes (empty log → fail-open → unchanged behaviour).

- [ ] **Step 6: Commit**

```bash
git add scripts/merge-project-update.sh tests/test-merge-auto-restore.sh
git commit -m "feat(memory): extraction auto-restores archived pages instead of duplicating"
```

---

## Task 4: Write-guard restore+redirect (`wiki-write-guard.sh`)

**Files:** Modify `scripts/wiki-write-guard.sh`; Test `tests/test-wiki-write-guard.sh`.

- [ ] **Step 1: Write the failing test** `tests/test-wiki-write-guard.sh`

```bash
#!/usr/bin/env bash
# A Write that re-creates an archived slug must restore the original + DENY (redirect
# to Edit). A Write to a brand-new (non-archived) page keeps the frontmatter rule only.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/scripts/wiki-write-guard.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BRAIN_DIR="$T/brain"
mkdir -p "$BRAIN_DIR/wiki-archive/concepts" "$T/knowledge/wiki/concepts"
printf -- '---\ntitle: "Gone"\ntype: concepts\n---\n# Gone\noriginal.\n' > "$BRAIN_DIR/wiki-archive/concepts/gone.md"
printf '%s\n' '{"event":"archived","slug":"gone","category":"concepts","date":"2026-05-26T01:00:00Z"}' > "$BRAIN_DIR/wiki-archive-log.jsonl"

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
GONE="$T/knowledge/wiki/concepts/gone.md"
in=$(jq -nc --arg f "$GONE" '{tool_name:"Write", tool_input:{file_path:$f, content:"---\ntitle: x\n---\nnew"}}')
out=$(printf '%s' "$in" | bash "$G")
echo "$out" | grep -q '"permissionDecision":"deny"' && ok "archived-slug Write denied" || bad "not denied: $out"
echo "$out" | grep -qi "restored" && ok "deny message mentions restore" || bad "no restore message"
[ -f "$GONE" ] && ok "archived original restored to wiki path" || bad "not restored"
grep -q '"event":"restored".*gone' "$BRAIN_DIR/wiki-archive-log.jsonl" && ok "restored event logged" || bad "no restored event"

# Non-archived new page WITH frontmatter -> allowed (no output / no deny)
NEW="$T/knowledge/wiki/concepts/brand-new.md"
in2=$(jq -nc --arg f "$NEW" '{tool_name:"Write", tool_input:{file_path:$f, content:"---\ntitle: y\n---\nbody"}}')
out2=$(printf '%s' "$in2" | bash "$G")
echo "$out2" | grep -q '"permissionDecision":"deny"' && bad "new page wrongly denied" || ok "non-archived new page allowed"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL** (guard has no tombstone logic).

- [ ] **Step 3: Add the tombstone check** in `scripts/wiki-write-guard.sh`, immediately AFTER the index-skip block (the `case "$FILE_PATH" in */knowledge/wiki/index.md) exit 0 ;; esac`) and BEFORE the `deny()` definition is used — i.e. right before the `case "$TOOL" in` dispatch near the end. Insert:

```bash
# Tombstone / auto-restore: a Write that re-creates a FORGOTTEN page revives the
# original (move it back) and is denied with a redirect to Edit. Only fires for a
# fresh create (target absent) of a net-archived slug. Restore is non-destructive.
if [ "$TOOL" = "Write" ] && [ ! -f "$FILE_PATH" ]; then
  SLUG=$(basename "$FILE_PATH" .md)
  ARCH=$("$(dirname "$0")/wiki-archived-slugs.sh" --path "$SLUG" 2>/dev/null) || ARCH=""
  if [ -n "$ARCH" ]; then
    ACAT=$(basename "$(dirname "$ARCH")")
    WIKIROOT="${FILE_PATH%/wiki/*}/wiki"
    mkdir -p "$WIKIROOT/$ACAT"
    mv "$ARCH" "$WIKIROOT/$ACAT/$SLUG.md" 2>/dev/null
    BD="${BRAIN_DIR:-$HOME/.second-brain}"
    printf '{"event":"restored","slug":"%s","category":"%s","date":"%s"}\n' \
      "$SLUG" "$ACAT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BD/wiki-archive-log.jsonl" 2>/dev/null || true
    deny "Auto-restored '$SLUG' from the cold-tier archive (it had been forgotten) to wiki/$ACAT/$SLUG.md. Re-open and Edit it — do not recreate it."
  fi
fi
```

> This sits inside the `SB_PERSONA_GATE=off` early-exit already at the top of the file, so the kill switch covers it. `deny()` is defined above this point in the file — if not, move the tombstone block to after the `deny()` definition.

- [ ] **Step 4: Run → PASS**

```bash
bash tests/test-wiki-write-guard.sh
```
Expected: `PASS:5 FAIL:0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/wiki-write-guard.sh tests/test-wiki-write-guard.sh
git commit -m "feat(memory): write-guard restores archived slug + redirects to Edit"
```

---

## Task 5: Maintainer archive awareness

**Files:** Modify `agents/knowledge-maintainer.md`; Test `tests/test-maintainer-archive-aware.sh`.

- [ ] **Step 1: Write the failing structural test** `tests/test-maintainer-archive-aware.sh`

```bash
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$ROOT/agents/knowledge-maintainer.md"
P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
grep -qi "wiki-archive" "$M"            && ok "mentions the cold-tier archive"      || bad "no archive mention"
grep -q  "wiki-archived-slugs.sh" "$M"  && ok "checks net-archived before create"   || bad "no archived-slugs check"
grep -q  "wiki-restore.sh" "$M"         && ok "restores instead of recreating"      || bad "no restore guidance"
grep -qi "wiki-forget-score.sh" "$M"    && ok "surfaces forget candidates"          || bad "no forget-candidate surfacing"
grep -qiE "never archive|does not archive|dream .*archiv" "$M" && ok "states it never archives (dream-only)" || bad "no 'never archive' boundary"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Add the section** to `agents/knowledge-maintainer.md` (after Phase 5 REINDEX / before `## Constraints`):

```markdown
## Cold-tier archive awareness (forgetting, since 0.17.0)

The dream's FORGET phase moves low-value pages OUT of `~/knowledge/wiki/` to
`~/.second-brain/wiki-archive/<category>/<slug>.md`, logging each to
`~/.second-brain/wiki-archive-log.jsonl`. Archived pages are **intentionally
forgotten, not missing** — treat them as follows:

- **Never treat an archived slug as a broken/missing page.** If a `[[link]]` points to
  a slug that's net-archived (`bash ${CLAUDE_PLUGIN_ROOT}/scripts/wiki-archived-slugs.sh --has <slug>`),
  it was deliberately removed — do not flag it as a dead link to "fix" by recreating.
- **Before creating any page, check the archive.** If
  `wiki-archived-slugs.sh --has <slug>` succeeds, run
  `bash ${CLAUDE_PLUGIN_ROOT}/scripts/wiki-restore.sh <slug>` to revive the original and
  **Edit** it — never create a duplicate. (Extraction + the write-guard auto-restore too;
  this keeps you consistent with them.)
- **You may SURFACE forget candidates, but you NEVER archive.** Optionally run
  `bash ${CLAUDE_PLUGIN_ROOT}/scripts/wiki-forget-score.sh` (read-only) and list the
  lowest-scoring pages in your report as "forget candidates for the next dream."
  Archiving is the dream's sole, gated job (`dream_accept`) — you only consolidate,
  enrich, and surface.
```

- [ ] **Step 4: Run → `PASS:5 FAIL:0`.**

- [ ] **Step 5: Commit**

```bash
git add agents/knowledge-maintainer.md tests/test-maintainer-archive-aware.sh
git commit -m "feat(memory): knowledge-maintainer is archive-aware (honor, surface, never archive)"
```

---

## Task 6: Release — 0.17.0

**Files:** `.claude-plugin/plugin.json`, `skills/upgrade/SKILL.md`.

- [ ] **Step 1: Bump version** in `.claude-plugin/plugin.json`: `"0.16.0"` → `"0.17.0"`.

- [ ] **Step 2: Add the migration row** to `skills/upgrade/SKILL.md` (after the `0.16.0` row):

```
| **0.17.0** | Maintainer ↔ forgetting coordination. (a) Forget probe reads `tags:` (the maintained field) not the absent `keywords:`. (b) New `scripts/wiki-archived-slugs.sh` net-archived source of truth makes forgetting durable via AUTO-RESTORE: re-creating a forgotten slug revives the original instead of duplicating — extraction (`merge-project-update.sh`) mv+merges it; the write-guard restores + redirects to Edit. (c) `knowledge-maintainer` is archive-aware: honors the archive, restores-before-recreate, surfaces forget candidates, never archives (the dream stays the sole gated archiver). Un-archiving is un-gated (additive/safe); archiving stays gated. Fail-open on a missing/corrupt log. Prompt/script/test-only — no state migration. | No precondition. Bumping the marker is sufficient. |
```

- [ ] **Step 3: Migration-row gate**

Run: `bash tests/test-upgrade-migration-row.sh`
Expected: `PASS: upgrade migration row present for 0.17.0`.

- [ ] **Step 4: Full suite + validate**

```bash
bash scripts/validate-plugin.sh && SB_RUN_ALL_VITEST=0 bash tests/run-all.sh
```
Expected: `OK: all plugin files valid`; `ALL GREEN` (new tests `test-wiki-archived-slugs`, `test-merge-auto-restore`, `test-wiki-write-guard`, `test-maintainer-archive-aware` PASS; existing `test-merge-project-update` + `test-wiki-write-guard` semantics intact; fail: 0).

- [ ] **Step 5: Commit + push**

```bash
git add .claude-plugin/plugin.json skills/upgrade/SKILL.md
git commit -m "chore(release): maintainer<->forgetting coordination — bump 0.17.0 + migration row"
git push origin main
```

- [ ] **Step 6: Deep-review gate** — run `/second-brain:code-review-deep --base <pre-task-1 sha>` and read the output (standing release rule); resolve real findings before considering it shippable.

---

## Self-Review

**Spec coverage:** C1 net-archived helper → T1; C2 probe tags → T2; C3 extraction auto-restore (both sites) → T3; C4 write-guard restore+redirect → T4; C5 maintainer awareness → T5; C6 tests → each task; fail-open → T1 (helper) + T3/T4 (`|| arch=""`); reversible mv+log → T3/T4; dream sole archiver / maintainer surfaces-only → T5; version/migration → T6. No gap.

**Placeholder scan:** none — every script/test/section shown in full; one flagged verify (merge CLI flag names in T3 Step 1) is a check, not a placeholder.

**Type/name consistency:** `wiki-archived-slugs.sh` modes (`--has`/`--path`/default), the `restored` JSONL event shape (`event/slug/category/date`), `$BRAIN_DIR/wiki-archive-log.jsonl`, `$(dirname "$0")/wiki-archived-slugs.sh` sibling-call, and the `tags:`→`description:`→`title:` order are used identically across T1–T5 and their tests.
