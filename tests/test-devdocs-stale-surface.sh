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
         CHANGELOG.md docs/specs docs/superpowers \
         agents/quality-reviewer.md agents/team-worker.md \
         agents/code-review-scorer.md agents/code-review-unit-reviewer.md \
         agents/code-review-history-reviewer.md agents/code-review-premise-reviewer.md; do
  if [ -e "$ROOT/$p" ]; then
    fail "denylisted surface '$p' exists in the tree again — re-scope this lock"
  fi
done
# Surfaces removed from the tree (cost-router 0.35.x; code-review-*/team family 0.44.0;
# CHANGELOG.md + docs/specs/ + docs/superpowers/ by the 0.34.0 "pre-1.0 diet", c65671f).
#
# Scan form: `find -exec grep +`, not `grep -r --include`. BSD grep does support --include,
# but this file would be the repo's only user of it and a BSD claim cannot be verified from
# the Windows dev box — the find form is unambiguously portable, so the question never arises.
#
# Why the CHANGELOG pattern is TWO alternatives, not a bare `CHANGELOG`: a bare match pulls in
# ~70 lines of the form "CHANGELOG 0.33.22", which are citations of a release RECORD, not of a
# file path — they resolve fine in history and marking them all would be exactly the
# marker-sprinkling that hollows out this lock. What is actually dangerous is (a) the file PATH
# `CHANGELOG.md`, which a reader will try to open, and (b) an instruction to write a "CHANGELOG
# entry/bullet", which sends a releaser to author a file that no longer exists. Those two are
# denied; the bare-version citation is deliberately OUT of scope. Do not widen this to a bare
# `CHANGELOG` without re-triaging those ~70 lines.
DENY='cost-router|skills/team|code-review-(deep|scorer|unit-reviewer|history-reviewer|premise-reviewer)|quality-reviewer|team-worker|team-run\.sh|CHANGELOG\.md|CHANGELOG (entry|entries|bullet|bullets|hunk|heading|headings)|docs/specs|docs/superpowers'
# A mention is historical (allowed) when one of these sits on the SAME line or an ADJACENT
# one — prose wraps mid-sentence, so the removal marker legitimately lands one line away.
MARKER='[Rr]emoved|REMOVED|[Aa]bsorbed|[Hh]istorical|[Dd]eleted|[Dd]ropped|de-vendored|archive/docs|[Rr]etired|[Rr]emoval|[Gg]one|[Mm]ooted'
# Pure-history references by charter (every line is about the past; per-line markers would
# be noise) are exempted BY FILE in the loop below. SKILL.md files are operational surface and
# are NEVER exempt.

viol=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  f=${hit%%:*}
  rest=${hit#*:}
  n=${rest%%:*}
  # Exemptions apply to the FILE, never the matched text: filtering the whole grep line would
  # drop a real violation that merely happens to name an exempt path on the same line.
  case "$f" in
    *chronicle.md|*worked-transcripts.md|*worked-examples.md) continue ;;
  esac
  start=$(( n > 1 ? n - 1 : 1))
  end=$(( n + 1))
  if ! sed -n "${start},${end}p" "$f" | grep -qE "$MARKER"; then
    viol="${viol}${hit}
"
  fi
done <<VIOL_EOF
$(find "$ROOT/.claude/skills" -name '*.md' -type f -exec grep -nE "$DENY" {} + )
VIOL_EOF

if [ -n "$viol" ]; then
  printf '%s' "$viol"
  n=$(printf '%s' "$viol" | grep -c .)
  fail "$n line(s) in .claude/skills present a removed surface as current — fix the claim or add a removal marker on (or adjacent to) the line"
else
  pass "no removed surface presented as current in .claude/skills"
fi


# The MARKER above accepts `archive/docs` as proof a citation is historical, so this lock is only
# as good as that branch being REACHABLE. It was pushed to origin on 2026-08-21 — before that it
# existed on exactly one machine, and every "history lives on archive/docs" pointer in the repo
# (README, CONSTITUTION, RELEASING, NOTICE, skills/status, scripts/lib.sh, and 10 dev-skill files)
# was dead for anyone who cloned. Guard it: a marker that resolves nowhere is not a marker.
# archive/docs == 94bede5 == c65671f^, an ancestor of main, so the SHA works even if the ref moves.
ARCHIVE_OK=0
for r in archive/docs origin/archive/docs 94bede5; do
  if git -C "$ROOT" cat-file -e "$r:CHANGELOG.md" ; then ARCHIVE_OK=1; break; fi
done
if [ "$ARCHIVE_OK" = 1 ]; then
  pass "archived docs are reachable (archive/docs branch or its commit)"
elif [ "$(git -C "$ROOT" rev-parse --is-shallow-repository )" = "true" ]; then
  echo "SKIP: shallow clone — cannot verify archive/docs reachability (fetch-depth 0 required)"
else
  fail "no ref resolves the archived docs (tried archive/docs, origin/archive/docs, 94bede5) — every 'history lives on archive/docs' pointer in the repo is dead; re-push the branch"
fi
[ "$FAILED" = 0 ] || exit 1
echo
echo "ALL PASS"
