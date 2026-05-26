# Memory Forgetting + Eval Implementation Plan

> **For agentic workers:** Implement task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`. All work is on `main` (sole-developer repo).

**Goal:** Bound the cold-tier wiki via a reversible, dream-staged forgetting pass scored on offline signals, with a recall@k + token-cost eval that gates releases and protects forgetting from degrading recall.

**Architecture:** Pure shell + the existing `knowledge-search-cli`. One shared recall script powers both a deterministic fixed-corpus release gate and a live per-candidate probe inside a new dream `FORGET` phase. Archiving moves pages **out of the indexed wiki tree** to `~/.second-brain/wiki-archive/` (removes them from search with no indexer change), applied only on `dream_accept`.

**Tech Stack:** Bash + `jq` + `awk`/`stat`/`grep`; the existing `mcp/dist/tools/knowledge-search-cli.bundle.js` (honors `KNOWLEDGE_DIR`, `SECOND_BRAIN_DISABLE_EMBEDDINGS`); tests auto-discovered by `tests/run-all.sh`.

**Spec:** `docs/specs/2026-05-26-memory-forgetting-and-eval-design.md`

---

## Decisions locked during planning (divergences from spec, with cause)

- **Archive location = `~/.second-brain/wiki-archive/<category>/<slug>.md`** (spec said `wiki/.archive/`). Cause: `knowledge-search.ts` walks every `wiki/` subdir incl. dot-dirs, so an in-tree archive stays searchable; moving out of `~/knowledge/wiki/` removes it from the index with zero TS/rebuild.
- **Eval is recall@2** (spec said @3). Cause: the CLI emits the top-2 slug+description lines that actually reach context. Token cost = bytes of that block / 4.
- **Eval runs BM25-only** via `SECOND_BRAIN_DISABLE_EMBEDDINGS=1` for determinism + offline fidelity.
- Archive log: `~/.second-brain/wiki-archive-log.jsonl`.

## File structure

| Path | Responsibility |
|------|----------------|
| `scripts/wiki-recall-check.sh` | recall@k + token cost over a corpus; exit 1=recall/token fail, 2=infra fail. Shared by gate + probe. |
| `scripts/wiki-forget-score.sh` | offline composite score per wiki page → TSV `score slug path reasons protflag`. |
| `scripts/wiki-forget-candidates.sh` | select archivable pages (score<floor, unprotected, cap) + run recall-probe guard → final list. |
| `scripts/wiki-restore.sh` | move an archived page back + reindex; `--list`. |
| `skills/dream/SKILL.md` | add Phase 6 FORGET (calls candidates script, stages moves, fail-safe, kill switch). |
| `agents/dream-runner.md` | grant the new scripts; mention Phase 6. |
| `scripts/ensure-dirs.sh` | create `~/.second-brain/wiki-archive/` lazily. |
| `tests/fixtures/eval-wiki/wiki/<cat>/*.md` | committed deterministic corpus. |
| `tests/fixtures/eval-queries.jsonl` | `{"q","expect":[slug...]}` lines. |
| `tests/test-wiki-recall-check.sh` | unit-tests the recall script (tmp corpus). |
| `tests/test-knowledge-eval.sh` | release gate: recall@2 + token budget on the fixture corpus. |
| `tests/test-wiki-forget-score.sh` | scorer behavior. |
| `tests/test-wiki-forget-probe.sh` | candidate selection + recall-protect behavior. |
| `.claude-plugin/plugin.json`, `skills/upgrade/SKILL.md` | version bump + migration row. |

---

## Task 0: Confirm groundings (verify-first)

**Files:** none (verification).

- [ ] **Step 1: Confirm search CLI honors KNOWLEDGE_DIR + emits parseable slugs**

```bash
cd /home/cainish/Projects/claude-code-plugin
T=$(mktemp -d); mkdir -p "$T/wiki/learnings"
printf -- '---\ntitle: Widget caching\ndescription: how widgets cache\n---\nWidgets cache via the foobar store.\n' > "$T/wiki/learnings/widget-caching.md"
KNOWLEDGE_DIR="$T" SECOND_BRAIN_DISABLE_EMBEDDINGS=1 node mcp/dist/tools/knowledge-search-cli.bundle.js "widget cache" ; rm -rf "$T"
```
Expected: a line like `### [[widget-caching]] — how widgets cache`. Confirms `KNOWLEDGE_DIR` override + slug output. If it prints nothing, lower expectations to BM25 wording but the `[[slug]]` format is the contract the recall script parses.

- [ ] **Step 2: Confirm archived (out-of-tree) pages are not searched** — implied by `knowledge-search.ts:54` (`wikiRoot = join(knowledgeDir,'wiki')`); a file under `~/.second-brain/wiki-archive/` is never under `wiki/`. No action; recorded.

No commit.

---

## Task 1: `scripts/wiki-recall-check.sh` (shared recall measurement)

**Files:** Create `scripts/wiki-recall-check.sh`; Test `tests/test-wiki-recall-check.sh`.

- [ ] **Step 1: Write the failing test**

Create `tests/test-wiki-recall-check.sh`:

```bash
#!/usr/bin/env bash
# Unit-test scripts/wiki-recall-check.sh against a throwaway corpus.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/wiki-recall-check.sh"
[ -x "$SC" ] || chmod +x "$SC" 2>/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/wiki/learnings"
printf -- '---\ntitle: Widget caching\ndescription: widgets cache via foobar\n---\nWidgets cache via the foobar store for speed.\n' > "$T/wiki/learnings/widget-caching.md"
printf -- '---\ntitle: Auth tokens\ndescription: oauth token refresh\n---\nOAuth tokens refresh on a sliding window.\n' > "$T/wiki/learnings/auth-tokens.md"
printf '%s\n' '{"q":"how do widgets cache","expect":["widget-caching"]}' \
              '{"q":"oauth token refresh","expect":["auth-tokens"]}' > "$T/q.jsonl"

P=0; F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }

out=$(bash "$SC" --corpus "$T" --queries "$T/q.jsonl" --k 2); rc=$?
echo "$out" | grep -qE 'recall@2=1\.0' && ok "perfect recall on matching corpus" || bad "expected recall@2=1.0, got: $out"
[ "$rc" -eq 0 ] && ok "exit 0 on success" || bad "exit $rc"

# infra failure -> exit 2
out=$(bash "$SC" --corpus "$T" --queries "$T/missing.jsonl" --k 2 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "missing queries file -> exit 2" || bad "expected exit 2, got $rc"

# gate fail -> exit 1 (impossible recall threshold)
out=$(SB_EVAL_MIN_RECALL=1.0 bash "$SC" --corpus "$T" --queries <(echo '{"q":"nonexistent zzz","expect":["nope"]}') --k 2 --gate 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "gate recall failure -> exit 1" || bad "expected exit 1, got $rc ($out)"

echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
```

- [ ] **Step 2: Run, verify it fails**

Run: `bash tests/test-wiki-recall-check.sh`
Expected: FAIL (script absent → first run errors / non-zero).

- [ ] **Step 3: Write `scripts/wiki-recall-check.sh`**

```bash
#!/usr/bin/env bash
# Measure recall@k + injected-token cost of knowledge_search over a corpus.
# Exit: 0 = ok / gate passed; 1 = gate recall|token failure; 2 = infra failure.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
CORPUS=""; QUERIES=""; K=2; GATE=0
while [ $# -gt 0 ]; do case "$1" in
  --corpus)  CORPUS="$2"; shift 2;;
  --queries) QUERIES="$2"; shift 2;;
  --k)       K="$2"; shift 2;;
  --gate)    GATE=1; shift;;
  *) echo "wiki-recall-check: unknown arg $1" >&2; exit 2;;
esac; done
command -v node >/dev/null 2>&1 || { echo "recall: node missing" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "recall: jq missing"   >&2; exit 2; }
[ -f "$CLI" ]     || { echo "recall: search CLI missing ($CLI)" >&2; exit 2; }
[ -f "$QUERIES" ] || { echo "recall: queries file missing ($QUERIES)" >&2; exit 2; }
[ -d "$CORPUS/wiki" ] || { echo "recall: corpus has no wiki/ ($CORPUS)" >&2; exit 2; }

hits=0; total=0; bytes=0; misses=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  q=$(printf '%s' "$line" | jq -r '.q')
  out=$(KNOWLEDGE_DIR="$CORPUS" SECOND_BRAIN_DISABLE_EMBEDDINGS=1 node "$CLI" "$q" 2>/dev/null) \
    || { echo "recall: search errored on query: $q" >&2; exit 2; }
  bytes=$(( bytes + ${#out} ))
  got=$(printf '%s' "$out" | grep -oE '\[\[[^]]+\]\]' | sed -E 's/\[\[|\]\]//g' | head -n "$K")
  total=$(( total + 1 )); hit=0
  while IFS= read -r exp; do
    [ -z "$exp" ] && continue
    printf '%s\n' "$got" | grep -qxF "$exp" && { hit=1; break; }
  done < <(printf '%s' "$line" | jq -r '.expect[]')
  [ "$hit" -eq 1 ] && hits=$(( hits + 1 )) || misses="$misses '$q'"
done < "$QUERIES"

tokens=$(( bytes / 4 ))
recall=$(awk "BEGIN{ if($total==0){print \"0.0\"} else {printf \"%.3f\", $hits/$total} }")
echo "recall@$K=$recall tokens=$tokens queries=$total hits=$hits"
[ -n "$misses" ] && echo "misses:$misses"
if [ "$GATE" -eq 1 ]; then
  MINR="${SB_EVAL_MIN_RECALL:-0.8}"; MAXT="${SB_EVAL_MAX_TOKENS:-8000}"
  awk "BEGIN{exit !($recall < $MINR)}" && { echo "GATE FAIL: recall $recall < $MINR"; exit 1; }
  [ "$tokens" -gt "$MAXT" ] && { echo "GATE FAIL: tokens $tokens > $MAXT"; exit 1; }
  echo "GATE PASS"
fi
exit 0
```

- [ ] **Step 4: `chmod +x scripts/wiki-recall-check.sh`; run test → PASS**

Run: `chmod +x scripts/wiki-recall-check.sh && bash tests/test-wiki-recall-check.sh`
Expected: `PASS:4 FAIL:0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/wiki-recall-check.sh tests/test-wiki-recall-check.sh
git commit -m "feat(memory): wiki-recall-check.sh — shared recall@k + token measurement"
```

---

## Task 2: Eval fixture corpus + release gate (#3)

**Files:** Create `tests/fixtures/eval-wiki/wiki/<cat>/*.md` (~10 pages), `tests/fixtures/eval-queries.jsonl`, `tests/test-knowledge-eval.sh`.

- [ ] **Step 1: Create the fixture corpus** (10 pages, unambiguous). Example pages — create each file with frontmatter + a body sentence:

```bash
cd /home/cainish/Projects/claude-code-plugin
mkdir -p tests/fixtures/eval-wiki/wiki/{learnings,concepts,decisions,entities}
mk(){ mkdir -p "$(dirname "$1")"; printf -- '---\ntitle: %s\ndescription: %s\n---\n%s\n' "$2" "$3" "$4" > "$1"; }
mk tests/fixtures/eval-wiki/wiki/learnings/bm25-recency-boost.md "BM25 recency boost" "search adds a recency decay over 90 days" "Knowledge search applies a 30 percent recency boost decaying linearly over ninety days."
mk tests/fixtures/eval-wiki/wiki/learnings/oauth-bare-flag.md "OAuth bare flag incompat" "claude --bare rejects OAuth tokens" "The claude --bare flag rejects OAuth subscription tokens and requires an API key."
mk tests/fixtures/eval-wiki/wiki/learnings/vector-deps-cache.md "Vector deps vanish on cache refresh" "transformers missing after plugin cache refresh" "A plugin cache refresh ships dist but not node_modules so the transformers vector dependency goes missing."
mk tests/fixtures/eval-wiki/wiki/concepts/hot-cold-tier.md "Hot and cold memory tiers" "USER.md PROJECT.md hot tier wiki cold tier" "The second brain splits memory into a hot tier of USER.md and PROJECT.md and a cold tier wiki."
mk tests/fixtures/eval-wiki/wiki/concepts/hybrid-search.md "Hybrid BM25 plus vector search" "fuses lexical BM25 and vector embeddings" "Retrieval fuses lexical BM25 scoring with vector embedding similarity using reciprocal rank fusion."
mk tests/fixtures/eval-wiki/wiki/decisions/dream-staging.md "Dream staging and review" "dreams stage changes for accept or discard" "Dreams stage all wiki changes into a diff that the user accepts or discards before anything is applied."
mk tests/fixtures/eval-wiki/wiki/decisions/forget-archive-move.md "Forgetting archives by moving out of tree" "archive pages outside the indexed wiki" "Forgetting archives a page by moving it out of the indexed wiki tree so it is removed from search reversibly."
mk tests/fixtures/eval-wiki/wiki/entities/pi5-host.md "Pi 5 homelab host" "Raspberry Pi 5 8GB NVMe local host" "The home host is a Raspberry Pi 5 with 8GB RAM and an NVMe drive running the local stack."
mk tests/fixtures/eval-wiki/wiki/entities/ovh-vps.md "OVH public VPS" "public-facing OVH virtual private server" "The public-facing host is an OVH VPS exposed to the internet and treated as the primary attack surface."
mk tests/fixtures/eval-wiki/wiki/learnings/episodic-embeddings.md "Episodic embeddings indexing" "transcript exchanges embedded for vector recall" "Episodic memory embeds transcript exchanges so past conversations are searchable by vector similarity."
```

- [ ] **Step 2: Create `tests/fixtures/eval-queries.jsonl`**

```bash
cat > tests/fixtures/eval-queries.jsonl <<'JSONL'
{"q":"how does the recency boost work in search","expect":["bm25-recency-boost"]}
{"q":"why does claude bare reject my subscription login","expect":["oauth-bare-flag"]}
{"q":"transformers missing after updating the plugin","expect":["vector-deps-cache"]}
{"q":"what are the hot and cold memory tiers","expect":["hot-cold-tier"]}
{"q":"do we combine bm25 and embeddings","expect":["hybrid-search"]}
{"q":"how do dreams apply changes safely","expect":["dream-staging"]}
{"q":"how does forgetting remove a page from search","expect":["forget-archive-move"]}
{"q":"what is the home raspberry pi host","expect":["pi5-host"]}
{"q":"which host is public facing","expect":["ovh-vps"]}
{"q":"how is past conversation made searchable","expect":["episodic-embeddings"]}
JSONL
```

- [ ] **Step 3: Write the gate test `tests/test-knowledge-eval.sh`**

```bash
#!/usr/bin/env bash
# Release gate: knowledge_search recall@2 + token budget over the fixture corpus.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$ROOT/tests/fixtures/eval-wiki"
Q="$ROOT/tests/fixtures/eval-queries.jsonl"
echo "test-knowledge-eval.sh"
bash "$ROOT/scripts/wiki-recall-check.sh" --corpus "$CORPUS" --queries "$Q" --k 2 --gate
rc=$?
[ "$rc" -eq 0 ] && echo "PASS: recall+token gate" || echo "FAIL: gate rc=$rc"
[ "$rc" -eq 0 ]
```

- [ ] **Step 4: Run → PASS** (tune fixtures only if a query genuinely can't hit top-2)

Run: `SB_EVAL_MIN_RECALL=0.8 bash tests/test-knowledge-eval.sh`
Expected: `recall@2=…` (≥0.8), `GATE PASS`, `PASS: recall+token gate`. If a single fixture query misses on BM25, reword that query or page body to be lexically unambiguous (the corpus is ours to make clean) — do NOT lower the 0.8 threshold below the spec.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/eval-wiki tests/fixtures/eval-queries.jsonl tests/test-knowledge-eval.sh
git commit -m "feat(memory): deterministic recall@2 + token eval gate over fixture corpus (#3)"
```

---

## Task 3: `scripts/wiki-forget-score.sh` (offline composite scorer)

**Files:** Create `scripts/wiki-forget-score.sh`; Test `tests/test-wiki-forget-score.sh`.

- [ ] **Step 1: Write the failing test `tests/test-wiki-forget-score.sh`**

```bash
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/wiki-forget-score.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export KNOWLEDGE_DIR="$T" BRAIN_DIR="$T/brain"
mkdir -p "$T/wiki/learnings" "$T/wiki/entities" "$T/brain"
echo '{}' > "$T/brain/access-counts.json"
# protected learning, linked
printf -- '---\ntitle: Keep me\ndescription: important\n---\nbody body body body body body body body body body body body body body body body body body body body body body.\n' > "$T/wiki/learnings/keep-me.md"
# orphan stub entity, old, tiny -> forgettable
printf -- '---\ntitle: Dead stub\ndescription: x\n---\ntiny.\n' > "$T/wiki/entities/dead-stub.md"
# a page that links to keep-me (gives keep-me inbound=1)
printf -- '---\ntitle: Linker\ndescription: links\n---\nsee [[keep-me]] for details and more context here.\n' > "$T/wiki/entities/linker.md"
# age the dead stub > 30d
touch -d '90 days ago' "$T/wiki/entities/dead-stub.md"

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
out=$(bash "$SC")
# dead-stub should score lower than keep-me
ds=$(echo "$out" | awk -F'\t' '$2=="dead-stub"{print $1}')
km=$(echo "$out" | awk -F'\t' '$2=="keep-me"{print $1}')
awk "BEGIN{exit !($ds < $km)}" && ok "dead-stub scores below keep-me" || bad "ds=$ds km=$km"
# keep-me is category-protected (learnings)
echo "$out" | awk -F'\t' '$2=="keep-me"{print $5}' | grep -q "PROTECT:category" && ok "keep-me category-protected" || bad "keep-me not protected"
# dead-stub is age-eligible (not age-protected) and unlinked
echo "$out" | awk -F'\t' '$2=="dead-stub"{print $5}' | grep -qv "PROTECT:age" && ok "dead-stub not age-protected" || bad "dead-stub wrongly age-protected"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL** (`bash tests/test-wiki-forget-score.sh`, script absent).

- [ ] **Step 3: Write `scripts/wiki-forget-score.sh`**

```bash
#!/usr/bin/env bash
# Composite importance per wiki page (offline signals only; NO embeddings).
# Output TSV (sorted ascending = most forgettable first):
#   score<TAB>slug<TAB>path<TAB>reasons<TAB>protflag
set -u
KD="${KNOWLEDGE_DIR:-$HOME/knowledge}"; WIKI="$KD/wiki"
BD="${BRAIN_DIR:-$HOME/.second-brain}"; AC="$BD/access-counts.json"
MINAGE="${SB_FORGET_MIN_AGE_DAYS:-30}"
WA="${SB_FORGET_W_ACCESS:-0.30}"; WR="${SB_FORGET_W_RECENCY:-0.25}"
WC="${SB_FORGET_W_CONNECTIVITY:-0.25}"; WG="${SB_FORGET_W_CATEGORY:-0.20}"
command -v jq >/dev/null 2>&1 || { echo "forget-score: jq missing" >&2; exit 2; }
[ -d "$WIKI" ] || { echo "forget-score: no wiki at $WIKI" >&2; exit 2; }
now=$(date +%s)
links=$(grep -rhoE '\[\[[^]]+\]\]' "$WIKI" 2>/dev/null | sed -E 's/\[\[|\]\]//g' | sort | uniq -c)
inbound(){ printf '%s\n' "$links" | awk -v s="$1" '$2==s{print $1; f=1} END{if(!f)print 0}' | head -1; }
acount(){ [ -f "$AC" ] && jq -r --arg s "$1" '.[$s] // 0' "$AC" 2>/dev/null || echo 0; }

find "$WIKI" -type f -name '*.md' ! -name 'index.md' -not -path '*/.*' | while read -r f; do
  slug=$(basename "$f" .md); cat=$(basename "$(dirname "$f")")
  age=$(( (now - $(stat -c %Y "$f")) / 86400 )); body=$(wc -c < "$f")
  inb=$(inbound "$slug"); acc=$(acount "$slug")
  s_acc=$(awk "BEGIN{a=$acc; v=(a<=0)?0:(log(a+1)/log(20)); print (v>1)?1:v}")
  s_rec=$(awk "BEGIN{d=$age; print (d>=180)?0:(1-d/180)}")
  s_con=$(awk "BEGIN{c=$inb; print (c>=3)?1:c/3}")
  case "$cat" in
    learnings|decisions|concepts) s_cat=1.0; prot="PROTECT:category";;
    entities|sources|patterns|issues) s_cat=0.5; prot="";;
    *) s_cat=0.2; prot="";;
  esac
  case "$slug" in evolve-01*|*session*) s_cat=0.1;; esac
  [ "$body" -lt 200 ] && s_cat=$(awk "BEGIN{print ($s_cat<0.2)?$s_cat:0.2}")
  score=$(awk "BEGIN{printf \"%.3f\", $WA*$s_acc+$WR*$s_rec+$WC*$s_con+$WG*$s_cat}")
  pf="$prot"
  [ "$age" -lt "$MINAGE" ] && pf="${pf:+$pf,}PROTECT:age"
  [ "$inb" -gt 0 ] && pf="${pf:+$pf,}PROTECT:linked"
  printf '%s\t%s\t%s\tacc=%s inb=%s age=%sd cat=%s body=%sb\t%s\n' \
    "$score" "$slug" "$f" "$acc" "$inb" "$age" "$cat" "$body" "$pf"
done | sort -n
```

- [ ] **Step 4: `chmod +x`; run test → `PASS:3 FAIL:0`.**

- [ ] **Step 5: Commit**

```bash
git add scripts/wiki-forget-score.sh tests/test-wiki-forget-score.sh
git commit -m "feat(memory): wiki-forget-score.sh — offline composite importance scorer"
```

---

## Task 4: Candidate selection + recall-probe guard, and the dream FORGET phase

**Files:** Create `scripts/wiki-forget-candidates.sh`; Modify `skills/dream/SKILL.md`, `agents/dream-runner.md`; Test `tests/test-wiki-forget-probe.sh`.

- [ ] **Step 1: Write the failing test `tests/test-wiki-forget-probe.sh`**

```bash
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/wiki-forget-candidates.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export KNOWLEDGE_DIR="$T" BRAIN_DIR="$T/brain"
mkdir -p "$T/wiki/entities" "$T/brain"; echo '{}' > "$T/brain/access-counts.json"
# unique-answer old orphan stub: should be a score candidate BUT recall-protected
printf -- '---\ntitle: Zorblax protocol\ndescription: the unique zorblax handshake\nkeywords: zorblax handshake\n---\nThe zorblax protocol handshake is unique and documented only here.\n' > "$T/wiki/entities/zorblax.md"
touch -d '120 days ago' "$T/wiki/entities/zorblax.md"
# redundant old orphan stub: a sibling covers the same topic -> archivable
printf -- '---\ntitle: Foobar note A\ndescription: foobar caching duplicate\nkeywords: foobar caching\n---\nFoobar caching duplicate note A content.\n' > "$T/wiki/entities/foobar-a.md"
printf -- '---\ntitle: Foobar note B\ndescription: foobar caching duplicate\nkeywords: foobar caching\n---\nFoobar caching duplicate note B content.\n' > "$T/wiki/entities/foobar-b.md"
touch -d '120 days ago' "$T/wiki/entities/foobar-a.md" "$T/wiki/entities/foobar-b.md"

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
out=$(SB_FORGET_FLOOR=0.99 bash "$SC")   # high floor so all stubs are score-candidates
echo "$out" | grep -q "zorblax" && bad "zorblax (unique answer) must be PROTECTED, not archived" || ok "unique-answer page protected by recall probe"
echo "$out" | grep -qE "foobar-(a|b)" && ok "redundant duplicate is archivable" || bad "redundant page should be archivable"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL** (script absent).

- [ ] **Step 3: Write `scripts/wiki-forget-candidates.sh`**

```bash
#!/usr/bin/env bash
# Select archivable wiki pages: score < floor, unprotected, capped; then a live
# recall-probe drops any page that is the UNIQUE answer to its own topic query.
# Emits one slug<TAB>path per archivable page. Exit 2 if the recall guard cannot run.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KD="${KNOWLEDGE_DIR:-$HOME/knowledge}"
FLOOR="${SB_FORGET_FLOOR:-0.15}"; CAP="${SB_FORGET_MAX_PER_DREAM:-5}"
SCORER="$ROOT/scripts/wiki-forget-score.sh"
RECALL="$ROOT/scripts/wiki-recall-check.sh"
[ -x "$SCORER" ] || chmod +x "$SCORER" 2>/dev/null
[ -x "$RECALL" ] || chmod +x "$RECALL" 2>/dev/null

scored=$(bash "$SCORER") || { echo "candidates: scorer failed" >&2; exit 2; }

# score-eligible = score < FLOOR and no PROTECT flag, capped
mapfile -t cand < <(printf '%s\n' "$scored" | awk -F'\t' -v fl="$FLOOR" '
  $1 < fl && $5 == "" { print $2 "\t" $3 }' | head -n "$CAP")

emit=""
for row in "${cand[@]}"; do
  slug="${row%%$'\t'*}"; path="${row#*$'\t'}"
  # derive probe query from title + keywords frontmatter
  qy=$(awk -F': ' '/^title:/{t=$2} /^keywords:/{k=$2} END{print t" "k}' "$path")
  # probe the FULL corpus: is this slug the top-2 answer to its own topic?
  qf=$(mktemp); printf '{"q":%s,"expect":[%s]}\n' "$(jq -Rn --arg q "$qy" '$q')" "$(jq -Rn --arg s "$slug" '$s')" > "$qf"
  full=$(bash "$RECALL" --corpus "$KD" --queries "$qf" --k 2 2>/dev/null); rc=$?
  rm -f "$qf"
  [ "$rc" -eq 2 ] && { echo "candidates: recall guard unavailable -> abort (fail-safe)" >&2; exit 2; }
  own_hit=$(printf '%s' "$full" | grep -oE 'recall@2=[0-9.]+' | head -1)
  # probe the corpus WITHOUT this page: does another page still answer the topic?
  tmpw=$(mktemp -d); cp -r "$KD/." "$tmpw/"; rm -f "$tmpw/wiki/"*"/$slug.md"
  qf2=$(mktemp); printf '{"q":%s,"expect":["__none__"]}\n' "$(jq -Rn --arg q "$qy" '$q')" > "$qf2"
  without=$(KNOWLEDGE_DIR="$tmpw" bash "$RECALL" --corpus "$tmpw" --queries "$qf2" --k 2 2>/dev/null)
  # if removing the page yields NO results at all for the topic, it was the unique answer -> PROTECT
  got_after=$(printf '%s' "$without" | grep -oE 'tokens=[0-9]+' | sed 's/tokens=//')
  rm -rf "$tmpw" "$qf2"
  if [ "${got_after:-0}" -gt 0 ]; then
    emit="$emit$slug\t$path\n"   # topic still answerable by a sibling -> safe to archive
  fi   # else: unique answer -> protect (skip)
done
printf '%b' "$emit"
```

> Note: the "unique answer" test = after removing the page, the topic query returns *some* other page (tokens>0 ⇒ a sibling answers) → safe; if it returns nothing → this page was the only answer → protect. Conservative.

- [ ] **Step 4: `chmod +x`; run test → `PASS:2 FAIL:0`.**

- [ ] **Step 5: Add Phase 6 to `skills/dream/SKILL.md`** — in Step 2 (5-Phase Wiki Consolidation), after Phase 5, insert:

```markdown
### Phase 6: FORGET — bound cold-tier growth (reversible, staged)

Skip entirely if `SB_WIKI_FORGET=off`. Otherwise, on the STAGING wiki:

1. Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/wiki-forget-candidates.sh` (it scores
   pages on offline signals, selects `score < SB_FORGET_FLOOR` (default 0.15),
   unprotected, capped at `SB_FORGET_MAX_PER_DREAM` (default 5), and drops any page
   the live recall-probe shows is the UNIQUE answer to its topic).
2. **Fail-safe:** if the script exits 2 (recall guard unavailable — e.g. search CLI
   or deps missing), SKIP forgetting this dream and note it in the summary. Never
   archive without a working recall guard.
3. For each emitted `slug<TAB>path`, STAGE an archive move in the dream diff:
   move the page to `~/.second-brain/wiki-archive/<category>/<slug>.md` and append a
   record to `~/.second-brain/wiki-archive-log.jsonl`
   (`{slug,path,category,score,reasons,date}`). These are part of the dream diff the
   user reviews — applied only on `dream_accept`, reverted by `dream_discard`.
4. Report: "FORGET: staged N pages for archive (M protected by recall-probe)."
```

- [ ] **Step 6: Grant scripts in `agents/dream-runner.md`** — ensure its `Bash` tool scope permits running the three scripts (they live under `scripts/`); if it enumerates allowed commands, add `Bash(*/scripts/wiki-*.sh *)` or confirm its existing `Bash` grant covers them. Add a one-line mention of Phase 6.

- [ ] **Step 7: Commit**

```bash
git add scripts/wiki-forget-candidates.sh tests/test-wiki-forget-probe.sh skills/dream/SKILL.md agents/dream-runner.md
git commit -m "feat(memory): dream FORGET phase + recall-probe candidate guard (#2)"
```

---

## Task 5: Restore + archive dir scaffolding

**Files:** Create `scripts/wiki-restore.sh`; Modify `scripts/ensure-dirs.sh`.

- [ ] **Step 1: Add archive dir to `scripts/ensure-dirs.sh`** — alongside other `mkdir -p` lines, add:

```bash
mkdir -p "$HOME/.second-brain/wiki-archive"
```

- [ ] **Step 2: Write `scripts/wiki-restore.sh`**

```bash
#!/usr/bin/env bash
# Restore an archived wiki page back into the indexed tree (or --list archives).
set -u
KD="${KNOWLEDGE_DIR:-$HOME/knowledge}"; WIKI="$KD/wiki"
BD="${BRAIN_DIR:-$HOME/.second-brain}"; ARC="$BD/wiki-archive"; LOG="$BD/wiki-archive-log.jsonl"
if [ "${1:-}" = "--list" ]; then
  [ -f "$LOG" ] && jq -r 'select(.event!="restored") | "\(.date)\t\(.category)/\(.slug)"' "$LOG" 2>/dev/null || echo "(no archive log)"
  exit 0
fi
slug="${1:-}"; [ -n "$slug" ] || { echo "usage: wiki-restore.sh <slug> | --list" >&2; exit 2; }
src=$(find "$ARC" -type f -name "$slug.md" 2>/dev/null | head -1)
[ -n "$src" ] || { echo "restore: $slug not in archive" >&2; exit 1; }
cat=$(basename "$(dirname "$src")"); dest="$WIKI/$cat/$slug.md"
mkdir -p "$WIKI/$cat"; mv "$src" "$dest"
printf '{"event":"restored","slug":%s,"category":%s,"date":%s}\n' \
  "$(jq -Rn --arg v "$slug" '$v')" "$(jq -Rn --arg v "$cat" '$v')" "$(jq -Rn --arg v "$(date -u +%FT%TZ)" '$v')" >> "$LOG"
echo "restored $slug -> $dest (run a reindex to re-add to search)"
```

- [ ] **Step 3: Smoke-test restore**

```bash
cd /home/cainish/Projects/claude-code-plugin
T=$(mktemp -d); export KNOWLEDGE_DIR="$T" BRAIN_DIR="$T/b"
mkdir -p "$T/wiki/entities" "$T/b/wiki-archive/entities"
printf 'x' > "$T/b/wiki-archive/entities/gone.md"
bash scripts/wiki-restore.sh gone && [ -f "$T/wiki/entities/gone.md" ] && echo "RESTORE OK" || echo "RESTORE FAIL"
rm -rf "$T"
```
Expected: `RESTORE OK`.

- [ ] **Step 4: Commit**

```bash
git add scripts/wiki-restore.sh scripts/ensure-dirs.sh
git commit -m "feat(memory): wiki-restore.sh + ensure wiki-archive dir"
```

---

## Task 6: Release — version, migration row, full gate

**Files:** Modify `.claude-plugin/plugin.json`, `skills/upgrade/SKILL.md`.

- [ ] **Step 1: Bump version** in `.claude-plugin/plugin.json`: `"version": "0.15.2"` → `"0.16.0"` (new feature ⇒ minor bump).

- [ ] **Step 2: Add migration row** to `skills/upgrade/SKILL.md` table (after the `0.15.2` row):

```
| **0.16.0** | Memory health: principled forgetting + recall eval. New dream Phase 6 FORGET stages reversible archive moves (out-of-tree to `~/.second-brain/wiki-archive/`) for low-value, old, unlinked, recall-safe wiki pages — applied only on `dream_accept`, kill switch `SB_WIKI_FORGET=off`. New `scripts/wiki-{recall-check,forget-score,forget-candidates,restore}.sh` (offline, no embeddings). New release-gate `tests/test-knowledge-eval.sh` (recall@2 + token budget over a fixture corpus). `ensure-dirs.sh` creates the archive dir. Additive — no state migration. | Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/ensure-dirs.sh` (idempotent; creates the archive dir). Bumping the marker is sufficient. |
```

- [ ] **Step 3: Migration-row gate**

Run: `bash tests/test-upgrade-migration-row.sh`
Expected: `PASS: upgrade migration row present for 0.16.0`.

- [ ] **Step 4: Full suite + validate**

Run: `bash scripts/validate-plugin.sh && SB_RUN_ALL_VITEST=0 bash tests/run-all.sh`
Expected: `OK: all plugin files valid`; `ALL GREEN` (new tests: `test-wiki-recall-check`, `test-knowledge-eval`, `test-wiki-forget-score`, `test-wiki-forget-probe` all PASS; fail: 0).

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json skills/upgrade/SKILL.md
git commit -m "chore(release): memory forgetting + eval — bump 0.16.0 + migration row"
git push origin main
```

- [ ] **Step 6: Deep-review release gate** — run `/second-brain:code-review-deep --base <pre-0.16 sha>` on the change and read the output (the standing release rule). Resolve real findings.

---

## Self-Review

**Spec coverage:** forgetting scorer → T3; candidate selection + recall-probe guard → T4; dream Phase 6 + staging + fail-safe + kill switch → T4; reversible archive + log → T4/T5; restore → T5; shared recall-check → T1; fixed-corpus gate (recall+tokens) → T2; offline/no-embeddings → T1 (`SECOND_BRAIN_DISABLE_EMBEDDINGS`), T3 (filesystem signals); conservative defaults → T3/T4 (env table); archive-dir scaffold → T5; version/migration → T6. **Divergences documented:** archive out-of-tree (not `wiki/.archive/`), recall@2 (not @3) — both with cause.

**Placeholder scan:** none — every script + test shown in full; commands have expected output.

**Type/name consistency:** script names (`wiki-recall-check.sh`, `wiki-forget-score.sh`, `wiki-forget-candidates.sh`, `wiki-restore.sh`), env vars (`SB_WIKI_FORGET`, `SB_FORGET_FLOOR`, `SB_FORGET_MIN_AGE_DAYS`, `SB_FORGET_MAX_PER_DREAM`, `SB_EVAL_MIN_RECALL`, `SB_EVAL_MAX_TOKENS`, `SECOND_BRAIN_DISABLE_EMBEDDINGS`), exit-code contract (1=recall/gate, 2=infra), archive path (`~/.second-brain/wiki-archive/<cat>/<slug>.md`), TSV column order (`score slug path reasons protflag`) are used identically across tasks and tests.
