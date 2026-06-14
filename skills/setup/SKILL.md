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

Determine the repo slug from the current working directory's git root (falls back to `pwd` if not a git repo):

```bash
SLUG=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
NAME="$SLUG"
echo "Active project: $SLUG"
```

Also ensure the base directories exist:

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
if ! grep -q "\"slug\":\"$SLUG\"" ~/.second-brain/projects.jsonl 2>/dev/null; then
  jq -nc --arg s "$SLUG" --arg n "$NAME" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}' \
    >> ~/.second-brain/projects.jsonl
fi
```

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
  SCAN_ROOT="$SCAN_ROOT_DIR" node "$SCAN_CLI" --dry-run
fi
```

Show the preview list. This writes nothing yet. **Ask the user to confirm** capturing
these into the raw inbox (an impactful action). On a yes (recompute the paths — each
bash block runs as a separate shell, so vars from the preview block do not persist):

```bash
SCAN_CLI="${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/raw-scan-cli.bundle.js"
SCAN_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
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

### 6c. Autonomy consent ladder (interactive opt-in — explicit choice only)

Autonomy is **off by default**. This step lets the operator turn it on with a
single explicit choice instead of hand-editing JSON — but it ONLY ever writes the
tiers they pick, and only here, under their direct `/setup` invocation. Never
infer or default a tier ON.

First show the three tiers verbatim:

```
Autonomy is opt-in, three tiers (config.json — all default off):
  auto_improve  : pin session learnings to the hot tier (cheap, reversible, no LLM call)
  auto_maintain : run the headless LLM consolidation out-of-band — spawns a
                  background `claude -p` that reads your OAuth creds with the
                  network up. THE supply-chain line — enable consciously.
  auto_accept   : apply a completed dream to the LIVE wiki unattended —
                  "off" (manual review) | "safe" (no archives/deletes) | "all"
                  Every auto-accept backs up the wiki first; FORGET is a
                  reversible move, never a delete.
Full hands-off needs BOTH auto_maintain AND auto_accept. See the wiki:
autonomy-consent-ladder.
```

Then:

1. **Show current values** (re-run safe — don't clobber an earlier choice):
   ```bash
   jq -r '"auto_improve=\(.auto_improve)  auto_maintain=\(.auto_maintain)  auto_accept=\(.auto_accept)"' \
     ~/.second-brain/config.json 2>/dev/null || echo "config.json not seeded yet (all tiers default off)"
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
