---
name: dream
description: |
  Run a "dream" — background consolidation of the knowledge base. Mines session
  transcripts for missed insights, deduplicates wiki entries, builds cross-links,
  and stages all changes for review before applying. Equivalent to Anthropic's
  managed-agents Dreams API, running locally. Supports inline (default) and
  background (--background) execution modes.
user-invocable: true
disable-model-invocation: false
argument-hint: "[--background] [instructions text]"
allowed-tools: Read Write Edit Bash(ls *) Bash(cat *) Bash(wc *) Bash(date *) Bash(find *) Bash(grep *) Bash(diff *) Bash(jq *) Bash(bash *) Agent mcp__knowledge-base__dream_create mcp__knowledge-base__dream_status mcp__knowledge-base__dream_list mcp__knowledge-base__dream_accept mcp__knowledge-base__dream_discard mcp__knowledge-base__dream_cancel mcp__knowledge-base__knowledge_search mcp__knowledge-base__knowledge_reindex mcp__knowledge-base__knowledge_validate
---

# Dream — Knowledge Base Consolidation

Fully automated. Detect state and act — no prompts, no menus.

## State Detection

On invocation, check current state via `dream_list` and act accordingly:

1. **Dream completed** → go to Review phase
2. **Dream running** → report status, estimate remaining
3. **Dream pending** → go to Execution phase
4. **No active dream** → go to Creation phase

## Phase: Creation

1. Parse arguments:
   - If `--background` flag present: set BACKGROUND=true
   - Remaining text after flags = instructions for the dream
2. Call `dream_create` with:
   - `instructions`: from args or empty
   - `transcript_filter`: default (all transcripts, max 50)
3. Report dream ID and transcript count
4. If BACKGROUND=true → spawn dream-runner agent with `run_in_background: true`, passing the dream_id. Report that dream is running in background and user will be notified on completion. Stop here.
5. If inline → proceed to Execution phase

## Phase: Execution

Set dream status to `running` via:
```bash
TMPFILE=$(mktemp)
jq '.status = "running" | .started_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
  ~/.second-brain/dreams/{dream_id}/status.json > "$TMPFILE" && mv "$TMPFILE" ~/.second-brain/dreams/{dream_id}/status.json
```

### Step 1: Transcript Mining

Read all transcript files from `~/.second-brain/dreams/{dream_id}/transcripts/`.

For each transcript, scan the metadata header (session_id, slug, date, tool_count) first. Then read the full content.

Identify:
- **Recurring patterns** (topics/entities mentioned across 3+ sessions that lack wiki pages)
- **Implicit decisions** made but never recorded
- **Entity relationships** visible across sessions but not cross-linked in wiki
- **Behavioral patterns** consistent across sessions (complement persona-signals)

Collect findings as a structured list of proposed wiki actions:
- `create` — new page for a previously uncaptured entity/concept/learning
- `update` — add content to an existing page
- `relate` — add cross-links between existing pages

### Step 2: 5-Phase Wiki Consolidation

Work exclusively on the staging wiki at `~/.second-brain/dreams/{dream_id}/staging/wiki/`.

**2a. AUDIT** — Read all pages. Fix:
- Missing YAML frontmatter → add it
- Broken `[[wiki-links]]` → fix or create stub
- Empty pages → delete
- Date-prefixed filenames → rename, move date to `created:` field

**2b. DEDUPLICATE** — Find pages with overlapping titles/content:
- Merge overlapping pages: keep broader page, fold narrower into it
- Update all `[[wiki-links]]` and `related:` references to point to surviving page
- Add `## History` entry noting the merge

**2c. RELATE** — Build `related:` links:
- Every page should have at least 1 relation
- Priority: Entity↔Learning, Entity↔Concept, Learning↔Learning
- Make relations bidirectional

**2d. ENRICH** — Category-specific quality:
- **Learnings**: imperative titles, actionable body, remove session noise
- **Entities**: overview + current state + linked learnings/decisions
- **Concepts**: Problem → Solution → Where Applied → Trade-offs
- Apply transcript mining insights from Step 1 (new pages, updated content)

**2e. REINDEX** — Call `knowledge_reindex` MCP tool (pointed at staging dir is not possible via MCP, so manually update staging/wiki/index.md if needed)

**2f. FORGET** — bound cold-tier wiki growth (skip entirely if `SB_WIKI_FORGET=off`):
- Run the candidate selector against the **LIVE** wiki (read-only — it copies to a
  temp to probe and never mutates live; real page ages matter, and staging mtimes are
  all fresh from the dream snapshot, so scoring staging would protect everything):
  ```bash
  bash "$CLAUDE_PLUGIN_ROOT/scripts/wiki-forget-candidates.sh" > /tmp/forget-cand.$$; rc=$?
  ```
  It scores pages on offline signals (access/recency/connectivity/category — no
  embeddings), selects `score < SB_FORGET_FLOOR` (default 0.15), unprotected, capped at
  `SB_FORGET_MAX_PER_DREAM` (default 5), then drops any page the live recall-probe
  shows is the UNIQUE answer to its topic.
- **Fail-safe:** if `rc` is 2 (recall guard unavailable — search CLI / vector path
  missing), SKIP forgetting this dream and note it. Never archive without the guard.
- For each emitted `slug<TAB>path`, append `slug<TAB><category>` (category = parent
  dir name) to `~/.second-brain/dreams/{dream_id}/forget-manifest.tsv`, and add a
  `## Proposed archives (N)` section to `diff.md` listing the slugs. Do NOT modify
  staging pages — forgetting archives LIVE pages on accept (Review phase), not via the diff.

### Step 3: Finalize

Generate the diff:
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/dream-diff.sh" {dream_id}
```

Update status to completed:
```bash
TMPFILE=$(mktemp)
jq '.status = "completed" | .ended_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
  ~/.second-brain/dreams/{dream_id}/status.json > "$TMPFILE" && mv "$TMPFILE" ~/.second-brain/dreams/{dream_id}/status.json
```

Proceed to Review phase.

## Phase: Review

1. Read `~/.second-brain/dreams/{dream_id}/diff.md`
2. Present a concise summary:
   - Pages added (count + titles)
   - Pages modified (count + what changed)
   - Pages removed (count)
   - Key insights surfaced
3. Apply:
   - Call `dream_accept` to apply the consolidation to the live wiki.
   - **Forgetting** — if `~/.second-brain/dreams/{dream_id}/forget-manifest.tsv` exists,
     archive each listed LIVE page (reversible move, never delete — the user's accept
     IS the confirmation):
     ```bash
     MAN=~/.second-brain/dreams/{dream_id}/forget-manifest.tsv
     ARC=~/.second-brain/wiki-archive; LOG=~/.second-brain/wiki-archive-log.jsonl
     KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
     while IFS=$'\t' read -r slug cat; do
       [ -n "$slug" ] || continue
       src="$KD/wiki/$cat/$slug.md"; [ -f "$src" ] || continue
       mkdir -p "$ARC/$cat"; mv "$src" "$ARC/$cat/$slug.md"
       printf '{"event":"archived","slug":"%s","category":"%s","date":"%s"}\n' \
         "$slug" "$cat" "$(date -u +%FT%TZ)" >> "$LOG"
     done < "$MAN"
     rm -f "$MAN"
     ```
     Then call `knowledge_reindex` so archived pages leave the search index.
4. Report completion — consolidation changes + N pages archived (restore any with
   `bash "$CLAUDE_PLUGIN_ROOT/scripts/wiki-restore.sh" <slug>`).

If the diff shows 0 total changes AND no archive manifest, call `dream_discard` instead
and report that the wiki was already well-consolidated. On any discard, also
`rm -f ~/.second-brain/dreams/{dream_id}/forget-manifest.tsv` (archive nothing).

## Constraints

- Max 50 wiki page changes per dream (matches knowledge-maintainer cap)
- Never delete user-created content unless exact duplicate or empty
- All writes go to staging/wiki/ — never touch live wiki during execution
- Clean up: remove session-narrative noise ("in this session", "files touched")
- Keep wiki-link format: `[[lowercase-kebab-case]]`
