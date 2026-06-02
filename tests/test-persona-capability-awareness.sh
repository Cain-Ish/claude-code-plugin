#!/usr/bin/env bash
# The persona-as-collaborator protocol (skills/using-second-brain/SKILL.md) must stay
# AWARE of the second-brain toolkit so it uses each capability without the user manually
# invoking a tool ("persona aware what + how to use", no user interaction) — WHILE keeping
# the deliberate write boundary: the persona is a graph READER, not a writer.
#
# Edge curation is owned by three paths only (capture-time extractor, the user's manual
# knowledge_relate, the knowledge-maintainer). The always-on persona must NOT become a
# fourth graph writer (history-review regression class, 0.22.5). Instead the wingman READS
# (knowledge_neighbors) and SURFACES a suggested knowledge_relate when the work confirms a
# relationship — the extractor then records it from the transcript, so the graph still
# accrues with no user interaction.
#
# This guards both halves: awareness of the capability AND the read-only boundary.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SK="$ROOT/skills/using-second-brain/SKILL.md"
P=0; F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
[ -f "$SK" ] || { echo "FAIL: skills/using-second-brain/SKILL.md missing"; exit 1; }

ALLOWED=$(grep -m1 '^allowed-tools:' "$SK")

# Read-side tools the persona drives autonomously — must be granted.
for t in knowledge_search episodic_search knowledge_neighbors; do
  printf '%s' "$ALLOWED" | grep -q "$t" && ok "read tool granted: $t" || bad "read tool missing from allowed-tools: $t"
done

# BOUNDARY: the persona stays READ-ONLY. knowledge_relate must NOT be in allowed-tools —
# granting it makes the always-on persona a 4th, ungoverned graph writer.
printf '%s' "$ALLOWED" | grep -q 'knowledge_relate' \
  && bad "knowledge_relate in allowed-tools — persona must stay read-only (4th-writer regression)" \
  || ok "allowed-tools is read-only (no knowledge_relate write grant)"

# AWARENESS: the protocol still references knowledge_relate so the persona can SURFACE it.
grep -q 'knowledge_relate' "$SK" \
  && ok "protocol aware of knowledge_relate (as a suggestion)" \
  || bad "protocol never mentions knowledge_relate — persona unaware of the capability"

# FRAMING: it must be a SURFACE/SUGGEST, and the real writers (extractor + maintainer) named,
# so the persona knows it is not the one writing.
grep -qiE 'surface|suggest' "$SK" && grep -qi 'extractor' "$SK" && grep -qi 'maintainer' "$SK" \
  && ok "framed as surface-only; extractor + maintainer named as the writers" \
  || bad "knowledge_relate not framed as surface-only with the real writers named"

# ANTI-SPAM: the load-bearing discipline clause must be present (not just the heading word).
grep -qiE 'never[^.]*speculative|only confirmed/retired' "$SK" \
  && ok "scoped to confirmed/retired only (never speculative)" \
  || bad "missing the 'never speculative' discipline clause (over-assertion risk)"

echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
