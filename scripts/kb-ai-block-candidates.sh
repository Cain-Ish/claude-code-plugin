#!/bin/bash
# Deterministic, read-only backfill work-list (AI-native Phase 3). One TSV row per blockless
# structured wiki page with substantive prose: <type>\t<slug>\t<path>. The knowledge-maintainer
# (Phase 4b) authors an ai-block for each. Idempotent (pure read; a page with <!-- ai:begin -->
# is skipped). No mutation. Mirrors kb-project-* tooling. mawk-safe.
#
# Usage: bash kb-ai-block-candidates.sh --knowledge-dir <dir>
set -u
KDIR=""; MINPROSE="${SB_AI_BLOCK_MIN_PROSE:-200}"
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KDIR="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$KDIR" ] || KDIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"
KDIR="${KDIR/#\~/$HOME}"
WIKI="$KDIR/wiki"; [ -d "$WIKI" ] || exit 0

# Structured types come from the KB single source of truth (kb-schema.json), never hardcoded.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]:-$0}")/kb-schema.sh" 2>/dev/null || true
for type in ${SB_STRUCTURED_TYPES:-}; do
  dir="$WIKI/$type"; [ -d "$dir" ] || continue
  find "$dir" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | sort | while IFS= read -r f; do
    # idempotent: skip pages that already have a block (any spacing). `grep -l` (whole-file)
    # not `grep -q` -- `grep -q`'s early exit SIGPIPEs the upstream `find` under job-control
    # (monitor) shells, ending the loop after one page; keep this identical to lint Check 4.
    [ -n "$(grep -lE '<!--[[:space:]]*ai:begin' "$f" 2>/dev/null)" ] && continue
    # Canonical type = explicit frontmatter `type:` (like knowledge_validate's doc.type), else the
    # dir. A page mis-filed in a structured dir but declaring a non-structured/typo'd type
    # (e.g. `type: index`, `type: concept`) is NOT a candidate -- keeps this in lockstep with validate.
    ftype=$(awk 'NR==1 && !/^---[[:space:]]*$/{exit} NR>1 && /^---[[:space:]]*$/{exit} /^type:[[:space:]]/{sub(/^type:[[:space:]]*/,"");gsub(/[\047",]/,"");gsub(/[[:space:]]+$/,"");print;exit}' "$f")
    case "${ftype:-$type}" in learnings|decisions|entities|issues|concepts|security) ;; *) continue ;; esac
    # Prose length = body minus frontmatter and COMPLETE marked regions. An UNTERMINATED region
    # (begin with no matching end) is NOT a block -> its held lines are emitted at END so they
    # still count (mirrors knowledge-validate.ts's bounded strip + the 59a9b25 forget-scorer guard;
    # never under-counts a real page into silent omission). mawk-safe.
    prose=$(awk '
      NR==1 && /^---[[:space:]]*$/ { infm=1; next }
      infm && /^---[[:space:]]*$/  { infm=0; next }
      infm { next }
      /<!--[[:space:]]*(graph|theme|ai):begin/ && !drop { drop=1; buf=$0 "\n"; next }
      drop && /<!--[[:space:]]*(graph|theme|ai):end[[:space:]]*-->/ { drop=0; next }
      drop { buf = buf $0 "\n"; next }
      { print }
      END { if (drop) printf "%s", buf }
    ' "$f" | tr -d '[:space:]' | wc -c)
    [ "$prose" -ge "$MINPROSE" ] || continue
    printf '%s\t%s\t%s\n' "$type" "$(basename "$f" .md)" "$f"
  done
done
