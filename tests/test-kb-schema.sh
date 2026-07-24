#!/bin/bash
# Guard: the KB single source of truth. kb-schema.json is valid; the bash loader (kb-schema.sh)
# exports SB_* lists that match it; and NO script/skill hardcodes a divergent category list — every
# consumer derives from the manifest. (The TS side is covered by mcp/src/constants/kb-schema.test.ts.)
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
M="$ROOT/kb-schema.json"
fail(){ echo "FAIL: $1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$M" ] || fail "kb-schema.json missing"
jq -e . "$M" >/dev/null 2>&1 || fail "kb-schema.json is not valid JSON"
pass "kb-schema.json present + valid"

# bash loader exports match the manifest exactly
SB_KB_SCHEMA="$M"; source "$ROOT/scripts/kb-schema.sh"
[ "$SB_STRUCTURED_TYPES" = "$(jq -r '.structured_types|join(" ")' "$M")" ] || fail "SB_STRUCTURED_TYPES != manifest"
[ "$SB_CONTENT_CATEGORIES" = "$(jq -r '(.structured_types+.unstructured_types)|join(" ")' "$M")" ] || fail "SB_CONTENT_CATEGORIES != manifest"
[ "$SB_ALL_CATEGORIES" = "$(jq -r '(.structured_types+.unstructured_types+.generated_dirs)|join(" ")' "$M")" ] || fail "SB_ALL_CATEGORIES != manifest"
[ "$SB_FORGET_PROTECTED" = "$(jq -r '.forget_protection.protected|join(" ")' "$M")" ] || fail "SB_FORGET_PROTECTED != manifest"
[ "$SB_EDGE_TYPES" = "$(jq -r '.edge_types|join(" ")' "$M")" ] || fail "SB_EDGE_TYPES != manifest"
pass "bash loader (kb-schema.sh) exports match the manifest"

# the six structured types are exactly as expected (anchor against accidental edit)
[ "$SB_STRUCTURED_TYPES" = "learnings decisions entities issues concepts security" ] \
  || fail "structured_types unexpected: $SB_STRUCTURED_TYPES"
pass "structured_types = the canonical six"

# ai-block contracts: every structured type has a block schema in the manifest, no extras,
# and each carries non-empty fields+required — a fresh machine learns the block grammar
# from kb-schema.json alone (markers + per-type field sets), never from code.
AB_TYPES=$(jq -r '.ai_blocks.types|keys_unsorted|join(" ")' "$M" | tr -d '\r')
[ "$AB_TYPES" = "$SB_STRUCTURED_TYPES" ] \
  || fail "ai_blocks.types keys != structured_types ($AB_TYPES)"
AB_EMPTY=$(jq -r '.ai_blocks.types[] | select((.fields|length)==0 or (.required|length)==0) | "x"' "$M" | tr -d '\r')
[ -z "$AB_EMPTY" ] || fail "an ai_blocks.types entry has empty fields/required"
jq -e '.ai_blocks.markers.begin and .ai_blocks.markers.end and (.frontmatter_required|length>0)' "$M" >/dev/null \
  || fail "ai_blocks.markers or frontmatter_required missing from manifest"
pass "ai-block contracts + markers + frontmatter_required live in the manifest"

# DRIFT GUARD: no script/skill may hardcode the six-type loop — it must use \$SB_STRUCTURED_TYPES.
H=$(grep -rnE 'for [a-z]+ in learnings decisions entities issues concepts security' "$ROOT/scripts" "$ROOT/skills" 2>/dev/null \
      | grep -vF 'SB_STRUCTURED_TYPES' || true)
[ -z "$H" ] && pass "no hardcoded six-type loop (all use \$SB_STRUCTURED_TYPES)" \
  || fail "hardcoded six-type loop found (source kb-schema.sh + use \$SB_STRUCTURED_TYPES):" "$H"

# DRIFT GUARD (0.33.38): the bash-side KNOWLEDGE_DIR must resolve through lib.sh's
# sb_knowledge_dir() (option > env > default, mirroring mcp/src/brain-paths.ts) — NOT a
# hand-rolled `${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-…:-$HOME/knowledge}`. The allowlisted
# files keep the inline form for a stated reason: they resolve BEFORE sourcing lib.sh
# (persona-context.sh, cost-router-capture.sh), never source lib.sh at all (the standalone
# kb-*/wiki-*/graph-cluster helpers), or deliberately invert the precedence for the systemd-
# timer env (maintain-deterministic.sh). lib.sh is the definition site. Any NEW script that
# trips this must call sb_knowledge_dir instead.
KD_ALLOW='lib.sh|persona-context.sh|cost-router-capture.sh|maintain-deterministic.sh|graph-cluster.sh|kb-drain-reconcile.sh|kb-project-backfill.sh|kb-project-suggest.sh|kb-ai-block-candidates.sh|wiki-forget-candidates.sh|wiki-forget-score.sh|wiki-redundancy.sh|wiki-restore.sh'
KD=$(grep -lE 'CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR.*:-.*HOME/knowledge' "$ROOT"/scripts/*.sh 2>/dev/null \
       | grep -vE "/(${KD_ALLOW})\$" || true)
[ -z "$KD" ] && pass "no NEW hand-rolled KNOWLEDGE_DIR resolution (all use \$(sb_knowledge_dir))" \
  || fail "hand-rolled KNOWLEDGE_DIR resolution found (use sb_knowledge_dir from lib.sh):" "$KD"

# --- SP-2: the `raw` group is visible to the json + bash readers (TS side in kb-schema.test.ts) ---
[ "$(jq -r '.raw.dir' "$M")" = "raw" ] || fail "kb-schema.json .raw.dir != raw"
[ "$SB_RAW_DIR" = "raw" ] || fail "kb-schema.sh did not export SB_RAW_DIR=raw (got '$SB_RAW_DIR')"
[ "$SB_RAW_STATUSES" = "$(jq -r '.raw.statuses|join(" ")' "$M")" ] || fail "SB_RAW_STATUSES != manifest"
pass "raw group visible to json + bash readers"

echo; echo "ALL PASS"
