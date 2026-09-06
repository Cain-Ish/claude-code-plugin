#!/bin/bash
# brain-os-run.sh — THE OFFLINE ENGINE SEAM.
#
# One named entry point for every pass that PROCESSES already-captured knowledge, as
# opposed to capturing it. The plugin stays the live runtime (hooks, retrieval, MCP
# tools); this is the thinking tank that runs out-of-band and improves what the wiki
# already holds. Invoked ONLY from the drainer tick (extract-drain.sh), so it inherits
# that script's single-flight lock, CLAUDECODE-refuse and interactive-defer guards and
# needs no timer of its own.
#
# Passes, in dependency order:
#   1. maintain   — deterministic upkeep: validate+autofix → project-backfill → reindex
#   2. embed      — offline embedding warm pass over the wiki
#   3. consolidate— the quarantined Stage A summarizer + deterministic Stage B writer
#   4. codemap    — out-of-band code-structure regen
#   5. history    — snapshot the wiki (the reversibility window)
# Retention pruning is NOT a pass here: it must run even when the engine is off, so it stays
# in the drainer. Putting it behind `brain_os` would repeat the exact bug the drainer comment
# warns about — gating retention behind an opt-in made bak_ttl_days silently inert.
# Reindex precedes embed so pages written this cycle are embedded in the same cycle.
#
# OPTIONAL BY CONSTRUCTION: `brain_os: false` in config.json (or SB_BRAIN_OS=off) disables
# the whole offline lane and the plugin keeps working exactly as before — capture,
# retrieval and the in-session /second-brain:maintain + /second-brain:dream paths are
# untouched. Each pass ALSO keeps its own pre-existing gate (auto_improve, auto_maintain,
# auto_codemap, auto_embed), so turning the engine on changes no defaults.
#
# Fail-soft as a whole (a broken pass must never wedge the drainer), fail-LOUD per pass
# (every failure lands in error-log.jsonl; no silent 2>/dev/null exits).
set -u
SDIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SDIR/lib.sh"

[ "${SB_BRAIN_OS:-on}" = "off" ] && exit 0
[ "$(sb_config_bool .brain_os on)" = "on" ] || exit 0

_pass() {  # _pass <name> <command...> — run a pass, log a nonzero exit, never abort the lane
  local _name="$1"; shift
  "$@" || sb_log_error "brain-os" "pass '$_name' exited $? (lane continues)" 1
}

# D116: the extraction batch's own 3600s worst-case budget proof (lib.sh sb_call_extractor,
# "BUDGET PROOF") only accounts for the batch loop itself — it never accounted for THIS
# engine, which extract-drain.sh runs INSIDE that same single-flight lock right after the
# batch (see extract-drain.sh's comment on the call site: "It runs inside this drainer's
# single-flight lock"). maintain-llm-drain.sh bounds itself (SB_MAINTAIN_LLM_TIMEOUT/
# SB_CW_TIMEOUT), but the embedding warm pass and codemap regen below were bare `node`
# spawns with NO timeout — a first-run ONNX embed of a large wiki, or a huge repo walk, can
# run arbitrarily long, past the 7200s SB_DRAIN_LOCK_STALE steal-threshold; the mkdir-lock
# fallback (git-bash/macOS, no flock) then judges the still-live run stale, steals it, and
# a DIFFERENT tick's cleanup trap removes the stealer's lock too — see lib.sh:2203 for the
# batch half of this budget proof.
# extract-drain.sh's mkdir-lock branch exports SB_BRAIN_OS_DEADLINE (absolute epoch, already
# margined) when it acquired the lock; fall back to a fixed conservative per-pass cap when
# unset (flock path — no steal risk — or a standalone/manual invocation).
_sb_brainos_pass_budget() {  # _sb_brainos_pass_budget <default_s> — seconds this pass may run
  local dflt="${1:-600}" now remaining
  if [ -n "${SB_BRAIN_OS_DEADLINE:-}" ]; then
    case "$SB_BRAIN_OS_DEADLINE" in
      *[!0-9]*) : ;;
      *)
        now=$(date +%s)
        remaining=$(( SB_BRAIN_OS_DEADLINE - now ))
        [ "$remaining" -lt 5 ] && remaining=5   # never hand sb_timeout a non-positive/zero budget
        [ "$remaining" -lt "$dflt" ] && dflt="$remaining"
        ;;
    esac
  fi
  printf '%s' "$dflt"
}

# 1. Deterministic upkeep (content-free, no credentials). Self-throttled internally.
if [ "$(sb_config_bool .auto_improve on)" = "on" ]; then
  _pass maintain bash "$SDIR/maintain-deterministic.sh" >/dev/null 2>&1
fi

# 2. Embedding warm pass (NEW). knowledgeSearch embeds every page in scope and caches the
#    vectors in KNOWLEDGE_DIR/wiki/.embeddings-cache.json, so ONE offline search moves that
#    cost out of the user's next session entirely. Deliberately reuses the shipped search
#    path rather than re-deriving the cache key/hash — a second implementation would drift
#    and silently produce a 100% cache miss.
#    SB_BRAIN_DIR is pointed at a scratch dir so the warm pass cannot write access-count
#    telemetry for pages nobody actually read (R2.2 hermeticity).
if [ "$(sb_config_bool .auto_embed on)" = "on" ] && [ "${SECOND_BRAIN_DISABLE_EMBEDDINGS:-0}" != "1" ]; then
  # sb_knowledge_dir(), never a hand-rolled chain: the inline form had the OPPOSITE
  # precedence (env before the plugin option), which is the "two wikis" bug class —
  # the engine would warm a cache for a different tree than the MCP server reads.
  _KD="$(sb_knowledge_dir)"
  _SEARCH_CLI="$(sb_plugin_root)/mcp/dist/tools/knowledge-search-cli.bundle.js"
  if [ -d "$_KD/wiki" ] && [ -f "$_SEARCH_CLI" ] && command -v node >/dev/null 2>&1; then
    _EMB_SCRATCH="$BRAIN_DIR/scratch/embed-warm"
    mkdir -p "$_EMB_SCRATCH" 2>/dev/null
    # D116: bounded — a first-run ONNX embed of a large wiki was previously unbounded,
    # able to run past the drainer lock's staleness steal-threshold.
    _EMB_BUDGET=$(_sb_brainos_pass_budget 600)
    _EMB_ERR=$(KNOWLEDGE_DIR="$_KD" SB_BRAIN_DIR="$_EMB_SCRATCH" \
      sb_timeout "$_EMB_BUDGET" node "$_SEARCH_CLI" "warm embedding pass" 2>&1 >/dev/null) || \
      sb_log_error "brain-os" "embedding warm pass failed or exceeded ${_EMB_BUDGET}s: ${_EMB_ERR:0:200}" 1
  fi
fi

# 3. The consolidation lane (Stage A quarantined summarizer → Stage B deterministic writer).
#    A SEPARATE, stronger consent than auto_improve: it spends tokens and needs the OAuth
#    grant. Self-gated + weekly-throttled inside; auto_accept governs what reaches live.
# SB_BRAIN_OS_NO_LLM=1 (set by the drainer on a DEFERRED tick) runs everything except this
# pass: the deterministic passes need no OAuth lock, so an always-on operator still gets
# offline processing instead of nothing at all.
if [ "${SB_BRAIN_OS_NO_LLM:-0}" != "1" ] && [ "$(sb_config_bool .auto_maintain on)" = "on" ]; then
  _pass consolidate bash "$SDIR/maintain-llm-drain.sh" >/dev/null 2>&1
fi

# 4. Out-of-band code-map regen (deterministic, content-free). The CLI self-gates on
#    git-rev drift, so a fresh tree costs one git probe — the heavy walk stays OUT of any
#    Claude session (autonomy + cost).
if [ "$(sb_config_bool .auto_codemap on)" = "on" ]; then
  # No session cwd out-of-band: target SB_CODEMAP_REPO when set, else the most-recently-
  # active project's root_path from the registry (the source session-load.sh trusts).
  # Multi-repo users get each repo mapped as it becomes the most recent (documented limit).
  CM_REPO="${SB_CODEMAP_REPO:-}"
  if [ -z "$CM_REPO" ] && [ -f "$BRAIN_DIR/projects.jsonl" ]; then
    # -R + per-line fromjson?: ONE garbage line must not kill the whole slurp (a plain -s
    # aborts and misreports a present-but-corrupt registry as empty; corrupt projects.jsonl
    # is a real class and sb_harden_projects_jsonl leaves unparseable files intact).
    # select(.root_path): the newest record may lack it (optional) — an older mappable repo
    # must still win. tr -d '\r': Windows jq emits CRLF (would poison the -d test below).
    CM_REPO=$(jq -Rrs 'split("\n") | map(fromjson? | select(type=="object") | select(.root_path)) | max_by(.last_session_iso // "") | .root_path // empty' \
      "$BRAIN_DIR/projects.jsonl" 2>/dev/null | tr -d '\r')
  fi
  # D118: defense-in-depth — a registry row for $HOME/a bare temp root should never
  # be written now (session-load.sh refuses it at registration time), but this also
  # covers a pre-existing registry from before that fix, and an operator-set
  # SB_CODEMAP_REPO pointed at one by mistake. Refusing here is what stops the
  # whole-home-directory codemap crawl (a live 9.6MB graph.json full of AppData
  # browser-extension bundles) at the actual point of the expensive walk.
  CM_REFUSED=""
  [ -n "$CM_REPO" ] && CM_REFUSED=$(sb_registration_refused_reason "$CM_REPO")
  if [ -n "$CM_REFUSED" ]; then
    sb_log_error "brain-os" "gate=registration refused $CM_REFUSED root=$CM_REPO (codemap target)" 0
  elif [ -n "$CM_REPO" ] && [ -d "$CM_REPO" ]; then
    # Flat dist path — the bundle lives at dist/tools/ (NOT dist/tools/codemap/).
    CM_CLI="$(sb_plugin_root)/mcp/dist/tools/code-map-cli.bundle.js"
    if [ -f "$CM_CLI" ] && command -v node >/dev/null 2>&1; then
      # The CLI is a fail-soft boundary — it ALWAYS exits 0 and reports failures as
      # 'code-map: ERROR …' on stderr — so `|| log` alone is DEAD CODE for every failure it
      # can actually hit (an unwritable store would silently no-op forever). Capture stderr
      # and match the marker; `||` still covers node-binary/bundle-load crashes.
      # D116: bounded — a huge repo walk was previously unbounded (comment above even notes
      # the CLI "always exits" but never bounds the WALK time itself).
      CM_BUDGET=$(_sb_brainos_pass_budget 600)
      CM_ERR=$(CLAUDE_PROJECT_DIR="$CM_REPO" sb_timeout "$CM_BUDGET" node "$CM_CLI" 2>&1 >/dev/null) || \
        sb_log_error "brain-os" "codemap regen crashed or exceeded ${CM_BUDGET}s for $CM_REPO: ${CM_ERR:0:200}" 1
      case "$CM_ERR" in *"code-map: ERROR"*)
        sb_log_error "brain-os" "codemap regen failed for $CM_REPO: ${CM_ERR:0:200}" 1 ;;
      esac
    else
      sb_log_error "brain-os" "codemap regen skipped: bundle or node missing ($CM_CLI)" 1
    fi
  else
    # NORMAL state (empty registry pre-first-session), never a silent no-op — but this runs
    # every 30 min, so an error-log line here is the banner-spam class. gate=* + ec=0 routes
    # it to the audit-log TRACE channel (R6b, sb_log_error).
    sb_log_error "brain-os" "gate=codemap-skip: no target repo (SB_CODEMAP_REPO unset; registry empty or root_path missing: '${CM_REPO:-}')" 0
  fi
fi

# 5. Reversibility window: commit whatever this lane changed. CONSTITUTION.md allows unattended
#    writes only because they are reversible; the pre-accept tarball covers one accept, this
#    gives the wiki a walkable history so any unattended change can be inspected and undone.
#    Last, so it captures every pass above. Never gates the lane.
[ -f "$SDIR/wiki-history.sh" ] && _pass history bash "$SDIR/wiki-history.sh" snapshot "brain-os engine run" >/dev/null 2>&1

exit 0
