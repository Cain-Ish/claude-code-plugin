---
name: setup
description: Scaffold the v1.0 hot tier — USER.md, projects/<slug>/PROJECT.md, index.txt — for the active repo. Idempotent.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Write Edit Bash(git rev-parse:*) Bash(basename *) Bash(date *) Bash(test *) Bash(jq *) Bash(mkdir *)
---

# Setup

Scaffold the second-brain v1.0 hot tier for the active repo. The hot tier is the small, always-loaded surface: `USER.md` (your global preferences) plus a per-repo `PROJECT.md` (goal, state, conventions) plus an `index.txt` registry. Combined target ≤ ~3200 bytes (~800 tokens).

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
test -f ~/.second-brain/index.txt || : > ~/.second-brain/index.txt
```

### 2. Scaffold USER.md

Check whether `~/.second-brain/USER.md` exists.

- If it exists: leave it alone, report its current byte count. Then verify it contains a `## Intent` section — if missing, append the default Intent block below (idempotent; same block the v1.2.0 migration appends).
- If it does not exist:
  - If `~/.second-brain/persona.md` exists (legacy 0.7.0 file), offer to condense it interactively into ≤15 lines of preferences and write the result to `USER.md`.
  - Otherwise prompt the user for ≤15 lines of cross-project preferences (tone, languages, defaults, "always do X / never do Y"). Write them to `USER.md` using the `Write` tool.
- After scaffolding (or detecting an existing file), ensure the following `## Intent` section is present at the bottom. This is the persona-as-first-thought protocol that the SessionStart hot tier and the `UserPromptSubmit` intent-gate hook rely on:

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

### 4. Update index.txt

Append a JSON line registering this project (one record per line; `index.txt` is JSONL). Skip the append if a line with this `slug` already exists.

```bash
if ! grep -q "\"slug\":\"$SLUG\"" ~/.second-brain/index.txt 2>/dev/null; then
  jq -nc --arg s "$SLUG" --arg n "$NAME" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}' \
    >> ~/.second-brain/index.txt
fi
```

### 5. Confirm

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
