#!/usr/bin/env bash
# Guard against the two dream prompt surfaces drifting apart — the regression class
# the post-0.22.3 completeness audit found: agents/dream-runner.md (background path)
# carried the read-only conflicts.jsonl echo in its RELATE phase, but skills/dream/SKILL.md
# (inline path) did not, so an identical dream produced different reports.
# Both surfaces must: (a) read conflicts.jsonl read-only, (b) echo the open-conflict count,
# (c) write nothing to graph/ (the knowledge-maintainer owns the drain).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/dream/SKILL.md"
AGENT="$ROOT/agents/dream-runner.md"
P=0; F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }

for pair in "SKILL:$SKILL" "AGENT:$AGENT"; do
  label="${pair%%:*}"; file="${pair#*:}"
  [ -f "$file" ] || { bad "$label file missing ($file)"; continue; }
  grep -q "conflicts.jsonl" "$file"                  && ok "$label reads conflicts.jsonl"        || bad "$label no conflicts.jsonl"
  grep -qiE "read-only|read only" "$file"            && ok "$label says read-only"               || bad "$label not marked read-only"
  grep -qiE "open[- ]conflict count|open conflicts"  "$file" && ok "$label echoes open-conflict count" || bad "$label no open-conflict count"
  # must NOT instruct writing to graph/ from the dream — maintainer owns the drain.
  # Anchor on `graph/` so this can't pass on the unrelated FORGET "writes nothing to
  # the wiki" line; allow ** around either "nothing" or "write nothing" (the two surfaces
  # bold it differently) and an optional backtick before graph.
  grep -qiE "writes? +(\*\*)?nothing(\*\*)? +to +\`?graph/" "$file" && ok "$label writes nothing to graph/" || bad "$label missing 'writes nothing to graph/'"
done

echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
