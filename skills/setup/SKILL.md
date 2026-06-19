---
name: setup
description: Scaffold the v1.0 hot tier — USER.md, projects/<slug>/PROJECT.md, projects.jsonl — for the active repo. Idempotent.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(git rev-parse:*) Bash(basename *) Bash(date *) Bash(test *) Bash(jq *) Bash(mkdir *) Bash(grep *) Bash(sed *) Bash(awk *) Bash(head *) Bash(cat *) Bash(wc *) Bash(node *)
---

# Setup

Scaffold the second-brain v1.0 hot tier for the active repo. The hot tier is the small, always-loaded surface: `USER.md` (your global preferences) plus a per-repo `PROJECT.md` (goal, state, conventions) plus an `projects.jsonl` registry. Combined target ≤ ~3200 bytes (~800 tokens).

This skill is idempotent — re-running it will not clobber existing files. It only fills in what's missing.

## Steps

### 1. Resolve active project

Detect the repo slug, parent (if a monorepo sub-project), and root_path using `sb_detect_project`, then **confirm with the operator before writing**:

```bash
# Monorepo-aware detection: slug / parent / root_path. Source lib.sh for sb_detect_project.
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
_det=$(sb_detect_project "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
IFS=$'\t' read -ra _det_fields <<< "$_det"
SLUG="${_det_fields[0]:-}"
if [ "${#_det_fields[@]}" -ge 3 ]; then
  PARENT="${_det_fields[1]}"; ROOT_PATH="${_det_fields[2]}"
else
  PARENT=""; ROOT_PATH="${_det_fields[1]:-}"
fi
NAME="$SLUG"
GIT_REMOTE=$(sb_git_remote "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
IDENT=$(sb_project_identity ~/.second-brain/projects.jsonl "$SLUG" "$ROOT_PATH" "$GIT_REMOTE")
echo "Identity check for slug=$SLUG: $IDENT"
if [ -n "$PARENT" ]; then
  echo "Detected sub-project: slug=$SLUG  parent=$PARENT  root_path=$ROOT_PATH"
else
  echo "Detected standalone project: slug=$SLUG  root_path=$ROOT_PATH"
fi
```

If `$IDENT` is `collision`, **STOP immediately and prompt the operator** — a different repo already owns this slug in `projects.jsonl`. Offer exactly three options and wait for a choice before writing anything:

1. **Use the path-qualified slug** `<root>__<leaf>` — the monorepo sub-project case. Re-run `sb_detect_project` treating the parent directory as the monorepo root, which produces a qualified slug that distinguishes the two repos.
2. **Rename to a user-chosen unique slug** — the standalone collision case. Ask the operator to supply a unique name; there is no auto-hashing. Update `SLUG` and `NAME` to the chosen value before proceeding.
3. **Use the existing project / abort** — if this repo truly is the same project (e.g. a re-clone), the operator can set `$IDENT` aside and proceed, or abort setup entirely.

**Never merge or clobber** the existing record. Only proceed to scaffold and write once the operator has resolved the collision (or `$IDENT` is `new` or `same`).

Show the operator what was detected and ask them to **accept, edit the parent, or clear it (treat as standalone) before writing** — never write a guessed `parent` unattended. Only proceed to the next steps once the operator confirms the slug and parent are correct.

Also ensure the base directories exist (note: the slug is path-qualified for sub-projects, e.g. `mono__api`):

```bash
mkdir -p ~/.second-brain/projects/"$SLUG"
test -f ~/.second-brain/projects.jsonl || : > ~/.second-brain/projects.jsonl
```

### 2. Scaffold USER.md

Check whether `~/.second-brain/USER.md` exists.

- If it exists: leave it alone, report its current byte count. Then verify it contains a `## Intent` section — if missing, append the default Intent block below (idempotent; same block the v1.2.0 migration appends).
- If it does not exist:
  - If `~/.second-brain/persona.md` exists (legacy 0.7.0 file), offer to condense it interactively into ≤15 lines of preferences and write the result to `USER.md`.
  - Otherwise prompt the user for ≤15 lines of cross-project preferences (tone, languages, defaults, "always do X / never do Y"). Write them to `USER.md` using the `Write` tool.
- After scaffolding (or detecting an existing file), ensure the following `## Intent` section is present at the bottom. This is the persona-as-first-thought protocol that the SessionStart hot tier and the `UserPromptSubmit` persona-context hook rely on:

```markdown
## Intent
For substantive requests (anything beyond a one-verb-on-one-noun edit), before answering:
1. Extract 3–5 keywords from the request (domain, action, surface).
2. Run the `second-brain:query` skill on those keywords. Read top 1–2 hits in full. Look for prior decisions, design plans, conventions, blockers, and restrictions the user has not restated.
3. Generate the followups a senior colleague would ask — adapted to this specific request — e.g., "is there an existing implementation? what tech stack and version? does anything similar already exist? what scope/auth/pagination is implied?".
4. Answer the followups yourself from retrieved context where possible. Surface only the ones that remain genuinely ambiguous AND costly to guess wrong, as one focused clarifying question.
5. If the wiki had nothing relevant, say so explicitly so the user knows you checked. Then proceed with your best interpretation.
```

`USER.md` is global — it applies to every repo.

### 3. Scaffold PROJECT.md

Check whether `~/.second-brain/projects/$SLUG/PROJECT.md` exists.

- If it exists: leave it alone, report its current byte count.
- If it does not exist: prompt the user for the `Goal` (≤3 lines) and `Conventions` (≤5 lines) and write the file using this 6-section template (filling in `<name>`, `Goal`, and `Conventions` from the prompt; leave the other sections empty for now — they will be filled in over time by the reflection and archive flows):

```markdown
# PROJECT: <name>

## Goal
<≤3 lines>

## State
<≤8 lines>

## Conventions
<≤5 lines>

## Recent decisions
<≤3 entries, each ≤2 lines, tagged [active|resolved|stale]>

## Open blockers
<≤15 lines, tagged [active|resolved|stale]>

## Cross-references
<≤3 wiki page slugs>

<!-- last_updated: ISO8601 -->
<!-- last_queried_wiki: YYYY-MM-DD -->
```

Set `<!-- last_updated: ... -->` to the current ISO8601 timestamp; leave `last_queried_wiki` blank for now.

### 4. Update projects.jsonl

Append a JSON line registering this project (one record per line; `projects.jsonl` is JSONL). Skip the append if a line with this `slug` already exists.

```bash
mkdir -p ~/.second-brain/projects/"$SLUG"
if [ ! -f ~/.second-brain/projects.jsonl ] || \
   ! jq -se --arg s "$SLUG" 'map(select(.slug == $s)) | length > 0' ~/.second-brain/projects.jsonl >/dev/null 2>&1; then
  jq -nc --arg s "$SLUG" --arg n "$NAME" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg p "$PARENT" --arg rp "$ROOT_PATH" --arg gr "$GIT_REMOTE" \
    '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}
     + (if $p  != "" then {parent:$p}      else {} end)
     + (if $rp != "" then {root_path:$rp}  else {} end)
     + (if $gr != "" then {git_remote:$gr} else {} end)' \
    >> ~/.second-brain/projects.jsonl
fi
```

### 4b. Project graph anchors + part_of edge (reconciliation projection)

**Precondition: skip entirely if `$PARENT` is empty** (standalone project — nothing to anchor or edge). Only run this block when a parent was confirmed.

If a `parent` was confirmed, mirror the relationship into the relational graph so
`knowledge_neighbors` and MOC cross-links surface family MOCs. This is graph
navigation only — facet assignment is driven by `projects.jsonl` truth, never by
the parent key.

```bash
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"; KD="${KD/#\~/$HOME}"
REG="$KD/graph/project-registry.jsonl"; mkdir -p "$KD/graph"
# each project anchors ITSELF (never the parent) — keeps facet assignment leaf-correct
for pair in "$SLUG:$SLUG" "$PARENT:$PARENT"; do
  a="${pair%%:*}"; p="${pair##*:}"; [ -n "$a" ] || continue
  grep -qF "\"anchor\":\"$a\"" "$REG" 2>/dev/null || \
    jq -nc --arg a "$a" --arg p "$p" '{anchor:$a, project:$p}' >> "$REG"
done
# project-level part_of edge (graph navigation): child → parent
EDGES="$KD/graph/edges.jsonl"
if [ -n "$PARENT" ] && ! jq -se --arg f "$SLUG" --arg t "$PARENT" \
     'map(select(.from==$f and .to==$t and .type=="part_of" and .valid_to==null)) | length>0' "$EDGES" >/dev/null 2>&1; then
  jq -nc --arg f "$SLUG" --arg t "$PARENT" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{op:"assert", from:$f, to:$t, type:"part_of", recorded_at:$ts, source:"setup", confidence:"high"}' >> "$EDGES"
fi
```

The maintainer's Phase 3 re-validates `projects.jsonl ↔ graph` on its normal cadence;
re-parenting requires `knowledge_relate --invalidate` on the old edge then a new assert.

### 5. Seed persona-card.md

The persona-card is the always-loaded identity surface — short, dense, idempotent. Read once per UserPromptSubmit by `persona-context.sh`. Cap ≤ 14 non-blank lines / ~800 bytes.

```bash
PCARD=~/.second-brain/persona-card.md
if [ ! -f "$PCARD" ]; then
  # Pull first bullet from USER.md as best-guess role line (falls back to a default).
  ROLE=$(grep -E '^- ' ~/.second-brain/USER.md 2>/dev/null | head -1 | sed -E 's/^- *(\[[0-9-]+\][[:space:]]*)?//')
  # Pull the first Goal line from any active PROJECT.md as project context.
  GOAL=$(awk '/^## Goal/{flag=1;next}/^## /{flag=0}flag && NF' ~/.second-brain/projects/*/PROJECT.md 2>/dev/null | head -1)
  cat > "$PCARD" <<EOF
# Persona

## Identity
- ${ROLE:-(set your role in ~/.second-brain/USER.md)}
- ${GOAL:-(current project — set Goal in PROJECT.md)}

## Communication style
- direct, terse, no filler

## Working preferences
- brainstorm 2-3 options before a non-trivial decision
- evidence before completion claims (run the check, then claim)

## How to engage me
- surface critical context; don't restate what I already know
- ask one focused question only when ambiguity is costly to guess wrong
- default to silence; volunteer only when the value clearly exceeds the interruption
EOF
  echo "Seeded persona-card.md ($(wc -c < "$PCARD") bytes)"
else
  echo "persona-card.md already present ($(wc -c < "$PCARD") bytes) — leaving alone"
fi
```

The persona-card is user-owned content. The persona reads it; nothing in the plugin should ever rewrite it automatically. The user edits it directly when their role, style, or preferences change.

### 6. Deep-scan the repo into the raw inbox (preview, then confirm)

Seed this project's KB by capturing its **high-signal docs** (README, `docs/`, ADRs,
`DESIGN.md`, …) into the raw inbox, where the maintainer later refines them into wiki
notes. Skipped entirely if `SB_SCAN_SKIP=1`. Curation reuses the doc-sources junk +
git-ignore filtering and a low-signal/secret denylist; the inbox dedups by content hash,
so re-running setup only captures new or changed docs.

```bash
if [ "${SB_SCAN_SKIP:-0}" != "1" ]; then
  SCAN_CLI="${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/raw-scan-cli.bundle.js"
  SCAN_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  cd "$SCAN_ROOT_DIR" || { echo "setup: cannot cd into $SCAN_ROOT_DIR"; exit 1; }
  SCAN_ROOT="$SCAN_ROOT_DIR" node "$SCAN_CLI" --dry-run
fi
```

Show the preview list. This writes nothing yet. **Ask the user to confirm** capturing
these into the raw inbox (an impactful action). On a yes (recompute the paths — each
bash block runs as a separate shell, so vars from the preview block do not persist):

```bash
SCAN_CLI="${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/raw-scan-cli.bundle.js"
SCAN_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$SCAN_ROOT_DIR" || { echo "setup: cannot cd into $SCAN_ROOT_DIR"; exit 1; }
SCAN_ROOT="$SCAN_ROOT_DIR" node "$SCAN_CLI"
```

Report the captured/skipped counts and point the user to `/second-brain:capture --list`.
If the preview was empty, say there were no high-signal docs to seed and move on.

### 6b. Companion-plugin check (superpowers)

Since 0.24.42 the discipline skills (brainstorming, TDD, systematic-debugging,
writing-plans, verification-before-completion) are NOT vendored — they come
from the upstream `superpowers` plugin (R6 de-vendor; see NOTICE.md). Check it
is installed and warn if not:

```bash
ls -d ~/.claude/plugins/cache/*/superpowers/*/ >/dev/null 2>&1 \
  && echo "superpowers: installed" \
  || echo "WARN: superpowers plugin not installed — the second-brain's workflow prose references superpowers:* skills (brainstorming, TDD, debugging, plans, verification). Install it from the official marketplace for the full discipline loop; the second-brain itself works without it."
```

### 6c. Autonomy consent ladder (review + dial-back — automation is ON by default)

Since 0.30.0 automation is **ON by default** — it's an automation plugin, so a fresh
install self-maintains without the operator having to remember to opt in. This step is
the transparency surface: show what's on and let the operator **dial it back or off**
with a single explicit choice instead of hand-editing JSON. It only writes the tiers
they change.

First show the three tiers verbatim, with their defaults:

```
Automation is ON by default (config.json), three tiers — change any here:
  auto_improve  : true  — pin session learnings to the hot tier (cheap, reversible, no LLM call)
  auto_maintain : true  — run the headless LLM consolidation out-of-band — spawns a
                          background `claude -p` that reads your OAuth creds with the
                          network up AND spends tokens. THE supply-chain line. It only
                          runs where `bwrap` exists (airtight sandbox) — a no-op on
                          macOS/Windows/bwrap-less Linux. Set false for a zero-spend box.
  auto_accept   : "safe" — apply a completed dream to the LIVE wiki unattended —
                          "off" (manual review) | "safe" (no archives/deletes) | "all".
                          Every auto-accept backs up the wiki first; FORGET is a
                          reversible move, never a delete.
To go fully manual: auto_improve=false, auto_maintain=false, auto_accept="off".
See the wiki: autonomy-consent-ladder.
```

Then:

1. **Show current values** (re-run safe — don't clobber an earlier choice):
   ```bash
   jq -r '"auto_improve=\(.auto_improve)  auto_maintain=\(.auto_maintain)  auto_accept=\(.auto_accept)"' \
     ~/.second-brain/config.json 2>/dev/null || echo "config.json not seeded yet (defaults: improve=on maintain=on accept=safe)"
   ```
   If a tier is already non-default, surface that and ask whether to change it
   rather than silently re-prompting.

2. **Ask the operator**, one decision per tier. Be explicit that `auto_maintain`
   authorises a recurring background process with access to their Claude OAuth
   credentials (their stated P0). Default every answer to OFF — only an explicit
   yes enables a tier. If they want everything off and it's already off, skip the
   write (nothing to do).

3. **Persist their explicit choice** with the dedicated writer (runs under the
   existing `Bash(node *)` grant — it validates values, writes booleans as real
   JSON booleans, preserves all other keys, and refuses inside a nested spawn).
   First confirm node is available, then write only the tiers they chose:
   ```bash
   node --version >/dev/null 2>&1 || echo "NODE-MISSING"   # node is the Bash(node *) grant
   node "${CLAUDE_PLUGIN_ROOT}/scripts/set-autonomy.mjs" \
     --auto-improve <true|false> --auto-maintain <true|false> --auto-accept <off|safe|all>
   ```
   - The writer prints `autonomy written to …` on success — only report the tiers
     as enabled if that line actually appeared (a non-zero exit or no success line
     means nothing was written; say so rather than claiming a write).
   - If node is missing (`NODE-MISSING`, exit 127), do NOT claim anything was
     enabled. Tell the operator autonomy stays off and show the exact manual edit
     for `~/.second-brain/config.json` — set `"auto_improve": true|false`,
     `"auto_maintain": true|false` (literal booleans, no quotes) and
     `"auto_accept": "off"|"safe"|"all"`.

4. **If (and only if) they enabled `auto_maintain`**, the out-of-band scheduler
   must be installed for it to actually run — but installing a recurring system
   service is a host-state change, so DO NOT run it for them. Show the exact
   command for them to run, defaulting to the **hardened, no-credentials** unit:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-extract-timer.sh" --apply
   ```
   Only if they specifically want the headless LLM maintainer's `claude -p`
   fallback (which needs their OAuth token) do they add `--oauth` — call this out
   as a SECOND, separate credential consent:
   ```
   # --oauth grants the background service read/write of ~/.claude (your OAuth
   # credentials) and drops the systemd namespace restriction. Only with --oauth
   # does the headless maintainer run; without it, auto_maintain stays inert on a
   # machine with no in-session claude. Enable consciously.
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-extract-timer.sh" --apply --oauth
   ```
   On Linux the script also PRINTS a `loginctl enable-linger` line for them to run
   (it never runs it — another deliberate host-state boundary). Off Linux there is
   no credential sandbox at all; say so.

### 7. Confirm

Print byte counts of `USER.md` and `PROJECT.md` and the combined total. Verify combined < ~3200 bytes (≈ 800-token hot-tier cap):

```bash
U=$(test -f ~/.second-brain/USER.md && wc -c < ~/.second-brain/USER.md || echo 0)
P=$(wc -c < ~/.second-brain/projects/"$SLUG"/PROJECT.md)
echo "USER.md: $U bytes"
echo "PROJECT.md ($SLUG): $P bytes"
echo "Combined: $((U + P)) bytes (cap ≈ 3200)"
```

If the combined size exceeds ~3200 bytes, advise the user to trim — the hot tier is meant to stay small and always-loaded.

## Notes

- All data stays local under `~/.second-brain/`. Nothing is synced or pushed.
- Do not place `~/.second-brain/` inside iCloud Drive, Dropbox, Google Drive, or OneDrive — those clients can corrupt JSONL during concurrent writes.
- This skill replaces the 0.7.0 setup flow. Legacy files (`learnings.md`, `quality-rules.md`, `friction-log.jsonl`, `persona.md`) are not created here; the `upgrade` skill handles migration.
