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

echo "FAIL:$F"; [ "$F" -eq 0 ]
