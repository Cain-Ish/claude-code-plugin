#!/bin/bash
# Contract (Phase 1b): extract-prompt.txt must teach the extractor to emit `ai_block` per
# wiki_update — the machine-first shared intermediate — with the per-type schema fields and the
# plain-slug rule (values are never [[wiki-links]]). Guards the capture-time auto-authoring path.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; P="$ROOT/scripts/extract-prompt.txt"
F=0; ok(){ echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
[ -f "$P" ] || { echo "FAIL: extract-prompt.txt missing"; exit 1; }

grep -q 'ai_block' "$P"                                  && ok "prompt emits ai_block"                || bad "no ai_block in prompt"
grep -qiE 'claim, trigger, action|trigger, action'  "$P" && ok "learnings schema present"            || bad "no learnings schema"
grep -qiE 'choice, alternatives|alternatives, rationale' "$P" && ok "decisions schema present"       || bad "no decisions schema"
grep -qi 'plain slug' "$P"                               && ok "plain-slug rule present"             || bad "no plain-slug rule"
grep -qiF '[[wiki-links]]' "$P"                          && ok "explicit no-[[links]] in the block"  || bad "no explicit [[links]] prohibition"

# --- Capture widening (P0, 0.39.0) ---------------------------------------------
# Rec 1: the issues category must be REACHABLE — the whitelist regression that kept
# the existing symptom/cause/fix ai_block template dead for months.
grep -qF 'entities|concepts|learnings|issues' "$P"       && ok "issues in wiki_updates whitelist"    || bad "issues category not in whitelist (error→fix class locked out)"
# Rec 1: the learnings REUSABLE filter must ROUTE one-time gotchas to issues, not drop them.
grep -qiE 'route .*(to|into) .*issues|"issues" category instead' "$P" && ok "gotchas route to issues" || bad "learnings filter still DROPS one-time gotchas instead of routing to issues"
# Rec 3: fan-out cap raised 3 → 8 (Karpathy 10-15/source norm; MinHash is the noise brake).
grep -q 'Max 8 wiki_updates' "$P"                        && ok "wiki_updates cap raised to 8"        || bad "wiki_updates cap not raised to 8"
grep -q 'Max 3 wiki_updates' "$P"                        && bad "stale 'Max 3 wiki_updates' cap still present" || ok "old cap 3 removed"
# Rec 2: procedures(max2) key — the procedural-runbook class, all four fields.
grep -q '"procedures"' "$P"                              && ok "procedures key present"              || bad "no procedures key"
for fld in task_verb exact_commands preconditions gotcha_avoided; do
  grep -q "$fld" "$P"                                    && ok "procedures field $fld"               || bad "procedures field $fld missing"
done
grep -qi 'max 2 procedures' "$P"                         && ok "procedures capped at 2"              || bad "no procedures cap (need literal 'Max 2 procedures')"
# Rec 4: session_outcome key — done|partial|abandoned, feeds the sessions digest.
grep -q '"session_outcome"' "$P"                         && ok "session_outcome key present"         || bad "no session_outcome key"
grep -qiE 'done\|partial\|abandoned' "$P"                && ok "outcome vocabulary present"          || bad "no done|partial|abandoned vocabulary"

echo "FAIL:$F"; [ "$F" -eq 0 ]
