#!/bin/bash
# persona-context.sh — Layer 1 persona infrastructure (UserPromptSubmit hook)
# Reads STDIN JSON: {prompt, cwd, ...}
# Emits hookSpecificOutput.additionalContext composed from:
#   - persona-card.md identity (factual)
#   - installed plugin catalog summary (factual)
#   - BM25 wiki hits (existing intent-gate pattern)
#   - episodic search hint
# No LLM call. Hard cap on each section. Always exits 0 — must never block a prompt.
#
# Kill switch: SB_PERSONA_GATE=off
# /? prefix is reserved for T6 (think tool); current behavior exits silently so T6 wiring can take over.
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

# Kill switch
[ "${SB_PERSONA_GATE:-on}" = "off" ] && exit 0

RAW=$(cat 2>/dev/null || true)
[ -z "$RAW" ] && exit 0

PROMPT=$(printf '%s' "$RAW" | jq -r '.prompt // empty' 2>/dev/null || true)
[ -z "$PROMPT" ] && exit 0

SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null || true)

# /? prefix → route to persona-think (Layer 2 Opus brief), bypass Layer 1 silent injection.
case "$PROMPT" in
  '/?'*)
    QUERY="${PROMPT#/?}"
    QUERY="${QUERY# }"
    [ -z "$QUERY" ] && exit 0
    PLUGIN_ROOT_NOW="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
    THINK_CLI="$PLUGIN_ROOT_NOW/mcp/dist/cli/persona-think-cli.bundle.js"
    if [ -f "$THINK_CLI" ]; then
      BRIEF=$(printf '%s' "$QUERY" | node "$THINK_CLI" 2>/dev/null || true)
      if [ -n "$BRIEF" ]; then
        CTX="[Persona deep brief — Opus advisor, treat as structured second opinion]
$BRIEF
---
Use this brief to inform the response. Ask the clarifying questions if they're costly to guess wrong."
        jq -nc --arg ctx "$CTX" '{
          hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext: $ctx
          }
        }' 2>/dev/null || true
      fi
    else
      # Bundle missing — emit a one-line hint so the user knows /? is dead
      # rather than silently dropping their request. Common cause: `dist/`
      # not rebuilt after a plugin pull (`cd mcp && npm run build`).
      CTX="[Persona /? requested but persona-think-cli.bundle.js is missing — run \`cd $PLUGIN_ROOT_NOW/mcp && npm run build\`. Proceeding without the Opus brief.]"
      jq -nc --arg ctx "$CTX" '{
        hookSpecificOutput: {
          hookEventName: "UserPromptSubmit",
          additionalContext: $ctx
        }
      }' 2>/dev/null || true
      sb_log_error_path="${BRAIN_DIR:-$HOME/.second-brain}/error-log.jsonl"
      mkdir -p "$(dirname "$sb_log_error_path")" 2>/dev/null
      printf '{"timestamp":"%s","script":"persona-context.sh","message":"think-cli-bundle-missing path=%s","exit_code":0}\n' \
        "$(date -u +%FT%TZ)" "$THINK_CLI" >> "$sb_log_error_path" 2>/dev/null
    fi
    exit 0
    ;;
esac

# --- Trivial-skip triage (preserved from intent-gate.sh) ---
P_LOWER=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
P_TRIM="${P_LOWER# }"; P_TRIM="${P_TRIM% }"
W_COUNT=$(printf '%s' "$P_TRIM" | wc -w | tr -d ' ')

case "$P_TRIM" in
  yes|y|ok|okay|k|kk|sure|no|n|nope|done|good|great|nice|cool|right|correct|\
go|"go ahead"|"go for it"|"do it"|"let's go"|continue|next|proceed|\
lgtm|"ship it"|merge|approved|"sounds good"|"works for me"|wfm|fine|\
thanks|thx|ty|"thank you")
    exit 0 ;;
esac

case "$P_TRIM" in
  thanks*|thx*|"thank you"*|"thats "*|"that's "*|"that "*|perfect*|"works."*|"works,"*)
    [ "$W_COUNT" -le 8 ] && exit 0 ;;
esac

ACTION=0
case "$P_TRIM" in
  "implement "*|"build "*|"add "*|"fix "*|"refactor "*|"design "*|"create "*|\
"write "*|"plan "*|"debug "*|"investigate "*|"update "*|"migrate "*|\
"integrate "*|"review "*|"audit "*|"port "*|"rewrite "*|"extract "*|"split "*)
    ACTION=1 ;;
esac

if [ "$ACTION" -eq 0 ] && [ "$W_COUNT" -lt 4 ]; then
  exit 0
fi

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"

# Caps per section. Total adds up around ~2400B for the additionalContext payload,
# well under the Claude Code 10K-char hook output limit.
# CAP_PERSONA was raised from 400 to 1200 in v2.10 because the new structured
# format (`[Section] bullet` per line, ~80 chars each) needs ~1100B to fit a
# typical persona-card.md without truncating mid-section. The old 400-byte cap
# fit only 4 bullets in the new format.
CAP_PERSONA=1200
CAP_CATALOG=200
CAP_WIKI=600
CAP_EPISODIC=300

# --- Persona card abstract (auto-seed if missing) ---
PCARD_FILE="$BRAIN_DIR/persona-card.md"
if [ ! -f "$PCARD_FILE" ]; then
  ROLE=$(grep -E '^- ' "$BRAIN_DIR/USER.md" 2>/dev/null | head -1 | sed -E 's/^- *(\[[0-9-]+\][[:space:]]*)?//')
  cat > "$PCARD_FILE" <<SEED
# Persona

## Identity
- ${ROLE:-(set your role in ~/.second-brain/USER.md)}

## Communication style
- direct, terse, no filler

## Working preferences
- brainstorm 2-3 options before a non-trivial decision
- evidence before completion claims (run the check, then claim)

## How to engage me
- surface critical context; don't restate what I already know
- ask one focused question only when ambiguity is costly to guess wrong
- default to silence; volunteer only when the value clearly exceeds the interruption
SEED
fi
PERSONA_ABS=""
if [ -f "$PCARD_FILE" ]; then
  # USER.md is loaded by session-load.sh at session start; persona-card.md is
  # injected per-prompt by this hook. Bullets that already appear verbatim in
  # USER.md are stripped to avoid double-injection (observed in field data:
  # 480B persona-card 100% duplicated USER.md "Hard Rules" entries).
  #
  # Format: keep `## Section` headings as `[section]` tags so the model can
  # distinguish identity from style from hard rules. awk walks the persona-card
  # in order, emitting `[Section] bullet` lines, then dedups against USER.md.
  # `tr '\n' ';'` collapse was removed in v2.10 — it destroyed structure.
  USER_BULLETS_FILE="$BRAIN_DIR/USER.md"
  PERSONA_RAW=$(awk '
    /^## / { section = $0; sub(/^## */, "", section); next }
    /^- / && section != "" {
      bullet = $0; sub(/^- */, "", bullet)
      printf "[%s] %s\n", section, bullet
    }
  ' "$PCARD_FILE" 2>/dev/null)

  if [ -f "$USER_BULLETS_FILE" ] && [ -n "$PERSONA_RAW" ]; then
    # Dedup: drop persona lines whose bullet text (after `[Section] `) exactly
    # matches a bare bullet in USER.md.
    USER_BULLETS=$(grep -E '^- ' "$USER_BULLETS_FILE" 2>/dev/null | sed 's/^- *//')
    # Pass bullets via ENVIRON[], NOT `-v ub=` — `-v` runs POSIX escape processing on the value,
    # so a backslash bullet (`C:\temp\notes`) gets its `\t`/`\n` rewritten and the seen[] key no
    # longer matches the verbatim card bullet (dedup silently fails → double-inject on mawk).
    PERSONA_ABS=$(printf '%s\n' "$PERSONA_RAW" | SB_USER_BULLETS="$USER_BULLETS" awk '
      BEGIN { n = split(ENVIRON["SB_USER_BULLETS"], arr, "\n"); for (i=1;i<=n;i++) seen[arr[i]] = 1 }
      { line = $0; sub(/^\[[^]]+\] /, "", line); if (!(line in seen)) print $0 }
    ')
  else
    PERSONA_ABS="$PERSONA_RAW"
  fi

  # Word-boundary trim. If the persona block exceeds CAP_PERSONA bytes, cut at
  # the last newline that fits, so we never split mid-line or mid-word.
  # ${var%$'\n'*} removes the shortest suffix from the last \n onward.
  # Fallback: raw byte cut if no newline fits (single oversized line).
  if [ ${#PERSONA_ABS} -gt $CAP_PERSONA ]; then
    TRIMMED=$(printf '%s' "$PERSONA_ABS" | head -c $CAP_PERSONA)
    TRIMMED_AT_NL="${TRIMMED%$'\n'*}"
    if [ -n "$TRIMMED_AT_NL" ] && [ "$TRIMMED_AT_NL" != "$TRIMMED" ]; then
      PERSONA_ABS="$TRIMMED_AT_NL"
    else
      PERSONA_ABS="$TRIMMED"
    fi
  fi
fi

# --- Plugin catalog summary ---
CATALOG_FILE="$BRAIN_DIR/.installed-catalog.json"
CATALOG_ABS=""
if [ -f "$CATALOG_FILE" ]; then
  CATALOG_ABS=$(jq -r '
    [
      (.plugins // [] | unique_by(.name) | map(.name) | .[0:6] | join(", ")),
      (.agents  // [] | length | tostring + " agents"),
      (.skills  // [] | length | tostring + " skills")
    ] | map(select(length > 0)) | join(" | ")' "$CATALOG_FILE" 2>/dev/null)
  [ ${#CATALOG_ABS} -gt $CAP_CATALOG ] && CATALOG_ABS=$(printf '%s' "$CATALOG_ABS" | head -c $CAP_CATALOG)
fi

# --- Keyword extraction (preserved from intent-gate.sh) ---
STOP_WORDS="the a an is are was were will be been have has had do does did can could should would may might must shall to of in for on at by with from as into about between through after before during without under over up down out off then than so if or and but not no all each every both few more most other some any many much own same that this those these what which who whom whose when where how why it its i me my we our us you your he him his she her they them their also just only very really already still even well too"

# Tokenize on alphanumerics + hyphen so technical identifiers survive:
# claude-4-5, v2.8.0 ("v2", "8", "0" — close to intact), node-modules, BM25.
# `[:alpha:]`-only splitting (the previous behavior) shredded these into
# generic fragments ("claude", "v", "node") that missed their wiki pages.
KEYWORDS=$(printf '%s' "$P_TRIM" \
  | tr -cs '[:alnum:]-' '\n' \
  | sed 's/^-*//; s/-*$//' \
  | grep -v '^$' \
  | grep -vxF "$(echo "$STOP_WORDS" | tr ' ' '\n')" \
  | head -8 | tr '\n' ' ')
KEYWORDS="${KEYWORDS% }"

# --- Wiki hits via existing bundle ---
WIKI_HITS=""
SEARCH_CLI="$PLUGIN_ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
# Score floor for per-prompt wiki injection. knowledge-search uses RRF fusion
# of BM25 + ONNX cosine, producing scores in ~0.001–0.07 range. Observed:
# strong queries land 0.05+, borderline ~0.04, nonsense queries already
# return empty (knowledgeSearch's MIN_SCORE_RATIO=0.15 trims internally).
# Default 0.045 keeps strong + moderate hits, drops the long tail that
# field reports flagged as "noise". Tune via SB_PERSONA_WIKI_MIN_SCORE.
WIKI_MIN_SCORE="${SB_PERSONA_WIKI_MIN_SCORE:-0.045}"
# SP-1: resolve the active project slug ONCE — shared by the wiki block below AND the episodic
# hint. Delegate to lib.sh sb_resolve_slug (single source: CLAUDE_PROJECT_DIR > cwd-if-known-project
# > pin > cwd) so per-prompt scoping matches the hook + MCP resolver and a CONCURRENT session's
# stale .active-session-slug pin can't hijack it. Sourced lazily HERE (not at file top) so early-exit
# prompts don't pay the lib.sh load (it sources kb-schema.sh, which can spawn jq).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib.sh" 2>/dev/null || true
SB_ACTIVE_SLUG_VAL=$(sb_resolve_slug)
# R6b (HOOK-7): prefer the COMBINED CLI — one node boot answers both the wiki
# and the episodic lookup (was two cold-starts, ~0.5-1s each on a Pi 5, every
# prompt). Sections split on the separator line; the two-CLI path below stays
# as the fallback for a stale plugin cache without the combined bundle.
WIKI_RAW=""
EPISODIC_HINT=""
EPISODIC_CLI="$PLUGIN_ROOT/mcp/dist/tools/episodic-search-cli.bundle.js"
COMBINED_CLI="$PLUGIN_ROOT/mcp/dist/tools/context-serve-cli.bundle.js"
_SB_CTX_SEP='--8<--SB-EPISODIC--8<--'
_CTX_OK=0
if [ -n "$KEYWORDS" ] && [ -f "$COMBINED_CLI" ]; then
  # rc-gated: a PRESENT-but-broken bundle (truncated cache write, node
  # incompat) must fall through to the still-working single CLIs below, not
  # silently lose both hints (R6b review: asymmetric-fallback shape).
  if _CTX_OUT=$(KNOWLEDGE_DIR="$KD" KNOWLEDGE_MIN_SCORE="$WIKI_MIN_SCORE" BRAIN_DIR="$BRAIN_DIR" SB_ACTIVE_SLUG="$SB_ACTIVE_SLUG_VAL" \
    node "$COMBINED_CLI" "$KEYWORDS" 2>/dev/null); then
    _CTX_OK=1
    WIKI_RAW=$(printf '%s\n' "$_CTX_OUT" | awk -v s="$_SB_CTX_SEP" '$0==s{exit}{print}')
    EPISODIC_HINT=$(printf '%s\n' "$_CTX_OUT" | awk -v s="$_SB_CTX_SEP" 'f{print} $0==s{f=1}')
  fi
fi
if [ "$_CTX_OK" -eq 0 ]; then
  if [ -n "$KEYWORDS" ] && [ -f "$SEARCH_CLI" ]; then
    # SP-1: scope the per-prompt wiki injection to the active project (the slug session-load pinned).
    WIKI_RAW=$(KNOWLEDGE_DIR="$KD" KNOWLEDGE_MIN_SCORE="$WIKI_MIN_SCORE" BRAIN_DIR="$BRAIN_DIR" SB_ACTIVE_SLUG="$SB_ACTIVE_SLUG_VAL" \
      node "$SEARCH_CLI" "$KEYWORDS" 2>/dev/null || true)
  fi
  if [ -n "$KEYWORDS" ] && [ -f "$EPISODIC_CLI" ]; then
    EPISODIC_HINT=$(BRAIN_DIR="$BRAIN_DIR" SB_ACTIVE_SLUG="$SB_ACTIVE_SLUG_VAL" node "$EPISODIC_CLI" "$KEYWORDS" 2>/dev/null || true)
  fi
fi

# Slug-only format. The CLI emits `### [[slug]] — description` lines; we
# keep the `[[slug]]` tokens and drop descriptions because:
#  1. CAP_WIKI=600 truncated descriptions mid-word — the model saw a fragment
#     it couldn't use.
#  2. A slug list with the Read instruction below tells the model: "these
#     pages exist, decide which to read in full". That's stronger than a
#     decorative snippet.
# Cap at 12 slugs to bound size (~30 chars each = ~360B, well under CAP_WIKI).
if [ -n "$WIKI_RAW" ]; then
  WIKI_HITS=$(printf '%s' "$WIKI_RAW" \
    | grep -oE '\[\[[a-zA-Z0-9_-]+\]\]' \
    | awk '!seen[$0]++' \
    | head -12 \
    | tr '\n' ' ' \
    | sed 's/ *$//')
  [ ${#WIKI_HITS} -gt $CAP_WIKI ] && WIKI_HITS=$(printf '%s' "$WIKI_HITS" | head -c $CAP_WIKI)
fi
[ ${#EPISODIC_HINT} -gt $CAP_EPISODIC ] && EPISODIC_HINT=$(printf '%s' "$EPISODIC_HINT" | head -c $CAP_EPISODIC)

# --- Behavioral principles re-surface (once per session, first coding-intent prompt) ---
# Karpathy: prose in CLAUDE.md drifts; re-surfacing the compact Four Principles at the moment
# coding begins is the salience a static file can't provide. Once per session (memo flag),
# coding-intent only, kill switch SB_PRINCIPLES_INJECT=off.
PRINCIPLES_ABS=""; PRINCIPLES_DONE=""
_PMEMO="$BRAIN_DIR/.injected/${SESSION_ID}.json"
PRINCIPLES_DONE=$(jq -r '.principles // ""' "$_PMEMO" 2>/dev/null)
if [ "${SB_PRINCIPLES_INJECT:-on}" != "off" ] && [ "$PRINCIPLES_DONE" != "1" ] && [ -n "$SESSION_ID" ]; then
  _PLOWER=$(printf '%s' "$P_TRIM" | tr '[:upper:]' '[:lower:]')
  _CODING_RE='implement|refactor|debug|build|coding|\bcode\b|\bfix\b|\bbug\b|\bfunction\b|\bclass\b|\bmethod\b|\bapi\b|endpoint|\bscript\b|\bmodule\b|\bcomponent\b|\bfeature\b|optimi|migrat|\btest\b|add a|add the|add support|write a|write the|create a|create the'
  if printf '%s' "$_PLOWER" | grep -qE "$_CODING_RE"; then
    _PFILE="$PLUGIN_ROOT/skills/using-second-brain/principles.md"
    [ -f "$_PFILE" ] && PRINCIPLES_ABS=$(awk '/<!-- compact:begin/{f=1;next}/<!-- compact:end/{f=0}f' "$_PFILE" 2>/dev/null)
    [ -n "$PRINCIPLES_ABS" ] && PRINCIPLES_DONE=1
  fi
fi

# Bail out if nothing useful surfaced.
if [ -z "$PERSONA_ABS" ] && [ -z "$CATALOG_ABS" ] && [ -z "$WIKI_HITS" ] && [ -z "$EPISODIC_HINT" ] && [ -z "$PRINCIPLES_ABS" ]; then
  exit 0
fi

# --- Per-session injection memo: skip wiki/episodic sections whose content is unchanged ---
# v2.10 change: persona + catalog are ALWAYS injected, even if hash unchanged.
# The model has no persistent memory between turns — re-injecting persona every
# turn is the *only* mechanism by which it stays in working context. The
# previous behavior (suppress on hash match) silently dropped persona after
# turn 1 and made the user think the persona didn't work.
# Wiki + episodic hits still get hash-deduped: they're noisier and re-injecting
# the same 12 slugs every turn is genuine noise.
SHOW_WIKI=1; SHOW_EPISODIC=1
MEMO_DIR="$BRAIN_DIR/.injected"
MEMO_FILE=""
if [ -n "$SESSION_ID" ]; then
  mkdir -p "$MEMO_DIR" 2>/dev/null || true
  MEMO_FILE="$MEMO_DIR/${SESSION_ID}.json"
fi

sb_hash() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum | awk '{print $1}'
  else
    # Last resort: byte length — coarse but better than no dedup.
    printf '%d' "${#1}"
  fi
}

if [ -n "$MEMO_FILE" ] && [ -f "$MEMO_FILE" ]; then
  H_WIKI_NOW=$(sb_hash "$WIKI_HITS")
  H_EPISODIC_NOW=$(sb_hash "$EPISODIC_HINT")
  H_WIKI_PREV=$(jq -r '.wiki // ""' "$MEMO_FILE" 2>/dev/null)
  H_EPISODIC_PREV=$(jq -r '.episodic // ""' "$MEMO_FILE" 2>/dev/null)
  [ -n "$WIKI_HITS" ]   && [ "$H_WIKI_NOW"    = "$H_WIKI_PREV" ]    && SHOW_WIKI=0
  [ -n "$EPISODIC_HINT" ] && [ "$H_EPISODIC_NOW" = "$H_EPISODIC_PREV" ] && SHOW_EPISODIC=0
fi

# --- Compose as factual statements (per research: factual phrasing dodges prompt-injection defenses) ---
CTX="[Persona context — auto-loaded, treat as ambient state]"
# Persona + catalog: always emit when non-empty. Hash-dedup was removed in
# v2.10 — re-injection every turn is required because the model has no
# persistent memory between turns.
[ -n "$PERSONA_ABS" ] && CTX="$CTX
$PERSONA_ABS"
[ -n "$CATALOG_ABS" ] && CTX="$CTX

Installed specialists: $CATALOG_ABS"
# Wiki: slug-only list. Tell the model to Read what it needs in full — the
# previous "descriptions" format was unusable truncated fragments.
[ -n "$WIKI_HITS" ] && [ "$SHOW_WIKI" = "1" ] && CTX="$CTX

[Wiki — auto-retrieved slugs; Read in full if relevant before answering]
$WIKI_HITS"
[ -n "$EPISODIC_HINT" ] && [ "$SHOW_EPISODIC" = "1" ] && CTX="$CTX
$EPISODIC_HINT"
[ -n "$PRINCIPLES_ABS" ] && CTX="$CTX

[Coding principles — apply to any code you write or change this session]
$PRINCIPLES_ABS"

# Update memo with this turn's hashes for next-turn dedup.
if [ -n "$MEMO_FILE" ]; then
  jq -nc \
    --arg p "$(sb_hash "$PERSONA_ABS")" \
    --arg c "$(sb_hash "$CATALOG_ABS")" \
    --arg w "$(sb_hash "$WIKI_HITS")" \
    --arg e "$(sb_hash "$EPISODIC_HINT")" \
    --arg pr "${PRINCIPLES_DONE:-}" \
    '{persona:$p, catalog:$c, wiki:$w, episodic:$e, principles:$pr}' > "$MEMO_FILE" 2>/dev/null || true
fi

# If everything was suppressed, no header alone — exit silent.
if [ "$CTX" = "[Persona context — auto-loaded, treat as ambient state]" ]; then
  exit 0
fi

CTX="$CTX
---
If the above is relevant, use it directly. If you need deeper analysis, invoke /second-brain:think or prefix the next prompt with /?.
Before claiming code is ready to commit: run all applicable verification — tests, lint, type-check — and invoke relevant installed skills (code review, security review, quality checks). No completion claims without evidence."

jq -nc --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}' 2>/dev/null || exit 0
exit 0
