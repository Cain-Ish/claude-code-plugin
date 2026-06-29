#!/usr/bin/env bash
# FORGET archive selection = recall-probe AND a MinHash redundancy cross-check (0.33.27).
#   - unique answer            -> protected (recall-probe)
#   - genuine near-dup pair    -> exactly ONE archived (recall-probe + cross-check + twin guard)
#   - distinct SAME-TOPIC pair -> BOTH kept (recall-probe sees coverage via shared tags, but MinHash
#                                 says they are not dups -> the cross-check prevents a false-forget)
#   - SB_REDUNDANCY=off        -> graceful fallback to prior recall-probe-only behavior (no regression)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/wiki-forget-candidates.sh"
REDUN_BUNDLE="$ROOT/mcp/dist/tools/wiki-redundancy-cli.bundle.js"
SEARCH_BUNDLE="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
[ -x "$SC" ] || chmod +x "$SC" 2>/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export KNOWLEDGE_DIR="$T" BRAIN_DIR="$T/brain"
mkdir -p "$T/wiki/entities" "$T/brain"; echo '{}' > "$T/brain/access-counts.json"

# unique-answer old orphan -> protected by the recall-probe AND (no near-dup) by the cross-check
printf -- '---\ntitle: Zorblax protocol\ndescription: the unique zorblax handshake\ntags: [zorblax, handshake]\n---\nThe zorblax protocol handshake is unique and documented only here in this note.\n' > "$T/wiki/entities/zorblax.md"
# GENUINE near-dup pair: identical bodies (a duplicate capture) -> MinHash sim 1.0 -> exactly one archived
# NOTE: no token shared with zorblax (e.g. "handshake") — else the recall-probe weakly matches it
# and the fallback path would false-forget zorblax for an unrelated reason.
dupbody="Foobar caching layer duplicate note describing the foobar caching behavior in careful detail for the permanent record kept here always."
printf -- '---\ntitle: Foobar A\ndescription: foobar caching\ntags: [foobar, caching]\n---\n%s\n' "$dupbody" > "$T/wiki/entities/foobar-a.md"
printf -- '---\ntitle: Foobar B\ndescription: foobar caching\ntags: [foobar, caching]\n---\n%s\n' "$dupbody" > "$T/wiki/entities/foobar-b.md"
# DISTINCT but same-TOPIC pair: shared tags (recall-probe sees coverage) yet different bodies
# (MinHash sim < threshold) -> the cross-check must KEEP BOTH (the false-forget this feature prevents).
printf -- '---\ntitle: PG indexing basics\ndescription: postgres indexing\ntags: [postgres, indexing]\n---\nPostgres indexing fundamentals explain btree page structure and how the planner picks an index scan for simple equality lookups on one column.\n' > "$T/wiki/entities/pg-basics.md"
printf -- '---\ntitle: PG indexing advanced\ndescription: postgres indexing\ntags: [postgres, indexing]\n---\nCovering partial expression and gin gist bloom indexes accelerate composite predicates jsonb containment and full text ranking in demanding analytical workloads.\n' > "$T/wiki/entities/pg-advanced.md"
touch -d '120 days ago' "$T"/wiki/entities/*.md 2>/dev/null || { echo "SKIP: touch -d unsupported"; exit 0; }

P=0; F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node absent (recall-probe needs it)"; exit 0; }
[ -f "$SEARCH_BUNDLE" ] || { echo "SKIP: search bundle absent (recall-probe unavailable)"; exit 0; }

if [ -f "$REDUN_BUNDLE" ]; then
  # ---- cross-check ON (MinHash available) ----
  out=$(SB_FORGET_FLOOR=0.99 bash "$SC")
  echo "--- cross-check output ---"; printf '%s\n' "$out"; echo "---"
  printf '%s\n' "$out" | grep -q 'zorblax' && bad "zorblax (unique) must be protected" || ok "unique-answer page protected"
  nf=$(printf '%s\n' "$out" | grep -cE 'foobar-(a|b)')
  [ "$nf" -eq 1 ] && ok "exactly one of the genuine near-dup pair archived (twin guard)" || bad "expected 1 foobar archived, got $nf"
  if printf '%s\n' "$out" | grep -qE 'pg-(basics|advanced)'; then
    bad "distinct same-topic page false-forgotten — cross-check failed ($(printf '%s' "$out" | grep -oE 'pg-[a-z]+' | tr '\n' ' '))"
  else
    ok "distinct same-topic pages KEPT (cross-check prevents the recall-probe false-forget)"
  fi
  # ---- graceful fallback: SB_REDUNDANCY=off -> prior recall-probe-only behavior ----
  outf=$(SB_FORGET_FLOOR=0.99 SB_REDUNDANCY=off bash "$SC")
  echo "--- fallback (SB_REDUNDANCY=off) output ---"; printf '%s\n' "$outf"; echo "---"
  printf '%s\n' "$outf" | grep -qE 'pg-(basics|advanced)' \
    && ok "fallback archives a same-topic page (prior behavior restored — no regression)" \
    || bad "fallback did not restore recall-probe-only behavior: $outf"
  printf '%s\n' "$outf" | grep -q 'zorblax' && bad "fallback: unique zorblax must stay protected" || ok "fallback: unique page still protected"
else
  echo "  SKIP cross-check (redundancy bundle absent) — exercising prior recall-probe-only behavior"
  out=$(SB_FORGET_FLOOR=0.99 bash "$SC")   # MINHASH_OK=0 -> prior behavior
  printf '%s\n' "$out" | grep -q 'zorblax' && bad "zorblax must be protected" || ok "unique-answer page protected (fallback)"
  printf '%s\n' "$out" | grep -qE 'foobar-(a|b)' && ok "redundant duplicate archivable (fallback)" || bad "redundant page should be archivable (fallback)"
fi
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
