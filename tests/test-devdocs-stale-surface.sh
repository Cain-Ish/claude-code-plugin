#!/bin/bash
# Dev-doc stale-surface lock. `.claude/skills/` is the model's own orientation layer for
# THIS repo; a claim there that a removed surface still ships sends every future session
# hunting files that do not exist. Found live 2026-08-21: `skills/code-review-deep` offered
# as "the repo's review tooling" (removed 0.44.0), a cost-router one-pager presented as
# installable (absorbed+removed 0.35.x), and verification one-liners grepping files gone
# from the tree. A removed surface MAY be cited as history — but the line must say so.
# ORACLE: the live tree (denylisted names are surfaces deleted in 0.34.0–0.44.0), not any
# doc's claim about it. Source-scan lock: no fixture, no model, no SB_* override applies.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
FAILED=0
fail(){ echo "FAIL: $1"; FAILED=1; }
pass(){ echo "PASS: $1"; }

# Guard the guard: if a denylisted surface is ever RESTORED, its mentions stop being
# historical and this lock is mis-scoped — fail loudly so it gets re-scoped in the same
# change (drop the name from DENY below).
for p in cost-router skills/code-review-deep skills/team scripts/team-run.sh \
         agents/quality-reviewer.md agents/team-worker.md; do
  if [ -e "$ROOT/$p" ]; then
    fail "denylisted surface '$p' exists in the tree again — re-scope this lock"
  fi
done

# Surfaces removed from the tree (cost-router 0.35.x; code-review-*/team family 0.44.0).
DENY='cost-router|code-review-(deep|scorer|unit-reviewer|history-reviewer|premise-reviewer)|quality-reviewer|team-worker|team-run\.sh'
# A mention is historical (allowed) when one of these sits on the SAME line or an ADJACENT
# one — prose wraps mid-sentence, so the removal marker legitimately lands one line away.
MARKER='[Rr]emoved|REMOVED|[Aa]bsorbed|[Hh]istorical|[Dd]eleted|[Dd]ropped|de-vendored|archive/docs|[Rr]etired|[Rr]emoval|[Gg]one|[Mm]ooted'
# Pure-history references by charter (every line is about the past; per-line markers would
# be noise). SKILL.md files are operational surface and are NEVER exempt.
EXEMPT='references/chronicle\.md|references/worked-transcripts\.md|references/worked-examples\.md'

viol=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  f=${hit%%:*}
  rest=${hit#*:}
  n=${rest%%:*}
  start=$(( n > 1 ? n - 1 : 1 ))
  end=$(( n + 1 ))
  if ! sed -n "${start},${end}p" "$f" | grep -qE "$MARKER"; then
    viol="${viol}${hit}
"
  fi
done <<VIOL_EOF
$(grep -rnE "$DENY" "$ROOT/.claude/skills" --include='*.md' 2>/dev/null | grep -vE "$EXEMPT")
VIOL_EOF

if [ -n "$viol" ]; then
  printf '%s' "$viol"
  n=$(printf '%s' "$viol" | grep -c .)
  fail "$n line(s) in .claude/skills present a removed surface as current — fix the claim or add a removal marker on (or adjacent to) the line"
else
  pass "no removed surface presented as current in .claude/skills"
fi

[ "$FAILED" = 0 ] || exit 1
echo
echo "ALL PASS"
