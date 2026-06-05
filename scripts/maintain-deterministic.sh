#!/bin/bash
# maintain-deterministic.sh (SP-B) — the CONTENT-FREE half of consolidation, safe to run
# out-of-band with NO LLM and NO credentials: validate(+autofix) → project-backfill →
# reindex. It NEVER authors prose or makes dedup/supersede judgements — those need a
# Claude session via /second-brain:maintain. Called by extract-drain.sh at the end of a
# drain cycle WHEN config.json `auto_improve` is on (the call site gates it), so it
# inherits the drainer's CLAUDECODE-refuse / interactive-defer / single-flight guards and
# needs no second timer. Also runnable standalone. Fail-soft — always exits 0.
set -u
SDIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SDIR/lib.sh"

# Self-throttle so a 30-min drain cadence doesn't reindex every cycle. The marker also
# serves as the "last consolidated" timestamp. SB_MAINTAIN_FORCE=1 bypasses (tests).
MARK="$BRAIN_DIR/.last-maintain"
INT="${SB_MAINTAIN_INTERVAL:-3600}"; case "$INT" in ''|*[!0-9]*) INT=3600 ;; esac
if [ "${SB_MAINTAIN_FORCE:-0}" != "1" ]; then
  mt=$(stat -c %Y "$MARK" 2>/dev/null || stat -f %m "$MARK" 2>/dev/null || echo 0)
  [ "$(( $(date +%s) - ${mt:-0} ))" -ge "$INT" ] || exit 0
fi
: > "$MARK"

# Resolve the knowledge dir the same way the helpers do. Out-of-band the scheduler has no
# CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR injection, so install-extract-timer.sh forwards a
# custom dir into the unit's env (Environment=/plist + the systemd ReadWritePaths grant);
# absent that, this is the default ~/knowledge — matching the out-of-band extraction path.
KDIR="${KNOWLEDGE_DIR:-${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}}"

# 1. validate + autofix (frontmatter, empty pages, broken links) — deterministic
sb_validate_wiki "$KDIR" >/dev/null 2>&1 || true
# 2. project-backfill (project: facet via part_of fixpoint — additive, reversible)
[ -f "$SDIR/kb-project-backfill.sh" ] && bash "$SDIR/kb-project-backfill.sh" >/dev/null 2>&1 || true
# 3. reindex (index.md + project/theme MOCs + projects' related:/Dependencies)
sb_reindex_wiki "$KDIR" >/dev/null 2>&1 || true
exit 0
