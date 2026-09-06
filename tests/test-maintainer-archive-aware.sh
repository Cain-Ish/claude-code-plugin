#!/usr/bin/env bash
# Structural guard: the knowledge-maintainer agent must know the cold-tier archive /
# forgetting model — honor it, restore-before-recreate, surface candidates, never archive.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$ROOT/agents/knowledge-maintainer.md"
P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
grep -qi "wiki-archive" "$M"            && ok "mentions the cold-tier archive"      || bad "no archive mention"
grep -q  "wiki-archived-slugs.sh" "$M"  && ok "checks net-archived before create"   || bad "no archived-slugs check"
grep -q  "wiki-restore.sh" "$M"         && ok "restores instead of recreating"      || bad "no restore guidance"
grep -qi "wiki-forget-score.sh" "$M"    && ok "surfaces forget candidates"          || bad "no forget-candidate surfacing"
grep -qiE "never archive|not.* archive|dream.*sole|sole gated" "$M" && ok "states it never archives (dream-only)" || bad "no 'never archive' boundary"

# D193 (functional, not just doc-structural): wiki-restore.sh must refuse to overwrite a
# live page that now occupies the restored slug — a `mv` with no `[ -e "$dest" ]` check
# would silently clobber it AND destroy the archived copy in the same step (it's a move,
# not a copy). dream-accept's _release_holds refuses exactly this race ("NEVER clobber
# it"); the documented undo for FORGET had no such guard until now.
RS="$ROOT/scripts/wiki-restore.sh"
SB=$(mktemp -d)
export HOME="$SB" BRAIN_DIR="$SB/brain" KNOWLEDGE_DIR="$SB/knowledge"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"
mkdir -p "$BRAIN_DIR/wiki-archive/entities" "$KNOWLEDGE_DIR/wiki/entities"
printf -- '---\ntitle: x\ntype: entities\nrelated: []\n---\n\nARCHIVED-COPY\n' > "$BRAIN_DIR/wiki-archive/entities/x.md"
printf -- '---\ntitle: x\ntype: entities\nrelated: []\n---\n\nLIVE-COPY (written after the archive)\n' > "$KNOWLEDGE_DIR/wiki/entities/x.md"
bash "$RS" entities/x >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "D193: restore refuses (nonzero) when a live page now occupies the slug" \
  || bad "D193: restore overwrote/clobbered rc=0 despite a live page at the slug"
grep -q 'LIVE-COPY' "$KNOWLEDGE_DIR/wiki/entities/x.md" 2>/dev/null \
  && ok "D193: live page left untouched" || bad "D193: live page was overwritten"
[ -f "$BRAIN_DIR/wiki-archive/entities/x.md" ] && grep -q 'ARCHIVED-COPY' "$BRAIN_DIR/wiki-archive/entities/x.md" \
  && ok "D193: archived copy preserved (not destroyed by the refused move)" \
  || bad "D193: archived copy was lost even though the restore was refused"
rm -rf "$SB"

echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
