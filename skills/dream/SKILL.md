---
name: dream
description: |
  Run a "dream" — consolidation of the knowledge base that stages every change
  for review before anything is applied. Use when accumulated sessions should be
  consolidated into the wiki, or to check/accept/discard an existing dream.
  Equivalent to Anthropic's managed-agents Dreams API, running locally. Supports
  inline (default) and background (--background) execution modes.
user-invocable: true
disable-model-invocation: true
argument-hint: "[--background] [instructions text]"
allowed-tools: Read Write Edit Bash(ls *) Bash(cat *) Bash(wc *) Bash(date *) Bash(find *) Bash(grep *) Bash(diff *) Bash(jq *) Bash(bash *) Bash(mktemp *) Bash(mv *) Bash(mkdir *) Bash(rm *) Bash(basename *) Bash(dirname *) Agent mcp__plugin_second-brain_knowledge-base__dream_create mcp__plugin_second-brain_knowledge-base__dream_status mcp__plugin_second-brain_knowledge-base__dream_list mcp__plugin_second-brain_knowledge-base__dream_accept mcp__plugin_second-brain_knowledge-base__dream_discard mcp__plugin_second-brain_knowledge-base__dream_cancel mcp__plugin_second-brain_knowledge-base__knowledge_search mcp__plugin_second-brain_knowledge-base__knowledge_reindex mcp__plugin_second-brain_knowledge-base__knowledge_validate
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
   - `transcript_filter`: omit `project_slug` → the **active project** (leaf); `project_slug: "all"`
     → every project; `family: true` → the whole **monorepo family** (the active project's root +
     siblings, from `projects.jsonl`). `"all"` wins if both are set.
3. Report dream ID and transcript count
4. If BACKGROUND=true → spawn dream-runner agent with `run_in_background: true`, passing the dream_id. Report that dream is running in background and user will be notified on completion. Stop here.
5. If inline → proceed to Execution phase

## Phase: Execution

Resolve the runtime-state root ONCE, honoring the same `SB_BRAIN_DIR`/`BRAIN_DIR` override the
MCP server used to create the dream — never hardcode `~/.second-brain` below:

```bash
BRAIN_DIR="${SB_BRAIN_DIR:-${BRAIN_DIR:-$HOME/.second-brain}}"
```

Set dream status to `running` via:
```bash
TMPFILE=$(mktemp)
jq '.status = "running" | .started_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
  $BRAIN_DIR/dreams/{dream_id}/status.json > "$TMPFILE" && mv "$TMPFILE" $BRAIN_DIR/dreams/{dream_id}/status.json
```

### Step 1: Transcript Mining

Read all transcript files from `$BRAIN_DIR/dreams/{dream_id}/transcripts/`.

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

### Step 2: 7-Phase Wiki Consolidation

Work exclusively on the staging wiki at `$BRAIN_DIR/dreams/{dream_id}/staging/wiki/`.

**2a. AUDIT** — Read all pages. Fix:
- Missing YAML frontmatter → add it
- Broken `[[wiki-links]]` → fix or create stub
- Empty pages → delete
- Date-prefixed filenames → rename, move date to `created:` field

> Node-shape note (0.24.48): you do NOT need to hand-canonicalize frontmatter
> FORMAT (β `related:`/`tags:`, missing required fields). `dream_accept` runs
> the maintainer's exact shaper (`knowledge_validate` autofix, via
> `sb_validate_wiki`) over the staging dir BEFORE merging onto live, and the
> post-merge reindex re-projects relations. Focus your AUDIT on CONTENT (dead
> links, dupes, empties) — the deterministic format pass is automatic and
> identical to the maintainer's, so dream and maintainer output converge to the
> same canonical shape.

**2b. DEDUPLICATE** — Find pages with overlapping titles/content:
- Merge overlapping pages: keep broader page, fold narrower into it
- Update all `[[wiki-links]]` and `related:` references to point to surviving page
- Add `## History` entry noting the merge

**2c. RELATE** — relationships live in the bi-temporal edge log (`~/knowledge/graph/edges.jsonl`)
and are **projected** onto `related:` + the `## Dependencies` block at reindex. **The dream does
NOT curate edges** — `graph/edges.jsonl` is not snapshotted into staging, so do **not** hand-edit
`related:` or the `<!-- graph:begin -->` block here (it is overwritten at projection).
- If you spot strong missing relationships while mining, surface them in the dream report as
  suggested `knowledge_relate` calls for the user / `knowledge-maintainer` to apply **live**.
- You may **read** `~/knowledge/graph/conflicts.jsonl` (live, read-only) and echo the folded
  open-conflict count into the dream report ("N open graph conflicts — resolve via the
  maintainer"). Write **nothing** to `graph/` — the `knowledge-maintainer` owns the drain.

**2d. ENRICH** — Category-specific BODY quality. Do **NOT** hand-edit `related:` — it is
projected from the edge log; surface relationship gaps as suggested `knowledge_relate` calls
in the report (per 2c), not frontmatter edits (the next reindex overwrites them).
- **Learnings**: imperative titles, actionable body, remove session noise
- **Entities**: overview + current state + a body section referencing linked learnings/decisions
- **Concepts**: Problem → Solution → Where Applied → Trade-offs
- Apply transcript mining insights from Step 1 (new pages, updated content)
- **AI-blocks (surface-only; advisory `SB_DREAM_AI_BLOCKS=off` — this step only COUNTS blockless pages and reports; off ⇒ omit the count. No wiki write to gate, so advisory, not machine-enforced.)** — scan staging for structured
  pages (learnings/decisions/entities/issues/concepts/security) lacking an `<!-- ai:begin -->`
  block and count them. **Do NOT author blocks in staging** — block authoring stays a single
  path through the live **knowledge-maintainer** (it grounds the block in the page's current
  prose; the dream would re-derive from prose it is still rewriting). Surface the count in the
  dream report: "N structured pages have no ai-block — run `/second-brain:maintain` to backfill."

**2e. SUMMARIZE** — whole-corpus theme pages (skip if `SB_DREAM_SUMMARIZE=off` — machine-enforced:
`graph-cluster.sh` returns `[]` when off, so the per-cluster write loop below has zero iterations
and no theme page is authored). Cluster the staging wiki's link graph and write one summary page
per cluster, so a fresh session can be handed *themes*, not just nearest slugs. Clustering is
deterministic and **staging-local** (reads `related:` + body `[[links]]`, never the live edge log):

```bash
CLUST=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/graph-cluster.sh" \
  --knowledge-dir "$BRAIN_DIR/dreams/{dream_id}/staging")
```

`CLUST` is JSON `[{id, members, member_hash}]` for clusters ≥ `SB_SUMMARIZE_MIN_CLUSTER`
(default 4), capped at `SB_SUMMARIZE_MAX_PAGES` (default 8). Theme pages are slugged
**`theme-<id>`** — the cluster id is the smallest member slug, which is usually an EXISTING
page (the cluster's anchor), so the `theme-` prefix prevents a `duplicate_slug` collision with it.
For each cluster:
- If `staging/wiki/themes/theme-<id>.md` exists with a **matching `member_hash`**, skip it
  (membership *and* member content unchanged — no LLM call).
- Else write/overwrite `staging/wiki/themes/theme-<id>.md` with frontmatter `type: themes`,
  `generated: true`, `related: [members]` (inline list of the member slugs, NOT the
  `[[a]], [[b]]` form — that is invalid YAML, same rule as 2e′ below), `member_hash: <hash>`,
  `created`/`updated`, and an LLM summary INSIDE the markers
  `<!-- theme:begin (generated — do not hand-edit) -->` … `<!-- theme:end -->` describing
  what the cluster is about and how its members relate. Author only the marked region.

Theme pages are derived/regenerable (FORGET protects the `themes` category) and are staged
like any other page — reviewed at `dream_accept`; the embedding cache + live index populate
on accept, not at dream time.

**Project MOCs** are the deterministic sibling: reindex projects one
`wiki/projects/<key>.md` per `project:` facet (≥3 members) into the two-tier index. The dream
does NOT assign `project:` on the live path (that is the `knowledge-maintainer`'s job) — if
mining surfaces a clear ungrouped project, **surface it as a suggestion** in the report
("group X, Y, Z under project `<key>`"), the same surface-only pattern as relationships.
`projects/` + `themes/` are excluded from clustering input so MOCs never become hubs.

**2e′. REFLECT** — synthesize the cross-cutting *practice* a cluster teaches (skip if `SB_DREAM_REFLECT=off`
— machine-enforced: `graph-cluster.sh --gate reflect` returns `[]` when off, so the write loop has zero
iterations). SUMMARIZE *indexes* a cluster; REFLECT distills the rule its members add up to, GROUNDED by
citing them so a synthesized rule stays traceable + retractable. The one ablation-backed memory op
(Generative Agents 2304.03442).

```bash
RCLUST=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/graph-cluster.sh" --gate reflect \
  --knowledge-dir "$BRAIN_DIR/dreams/{dream_id}/staging")
```

Same clusters as SUMMARIZE. For each cluster, **in order**: **(1) decide eligibility FIRST** — reflect
ONLY if **≥ half the members are actionable** (learnings/issues/decisions) AND a genuine cross-cutting
practice emerges; otherwise **SKIP entirely, write NOTHING** (never pad, never duplicate a theme).
**(2) idempotence** — `<id>` = smallest member slug; skip if a `reflection-<id>` page already exists with
a matching `member_hash` in EITHER `staging/wiki/learnings/` OR `staging/wiki/concepts/` (check both — the
type may have been chosen differently on a prior run). **(3) write** ONE page at the exact path
`staging/wiki/learnings/reflection-<id>.md` (type `learnings`, default) or
`staging/wiki/concepts/reflection-<id>.md` (type `concepts`, pattern-shaped) — existing categories only,
never a new `reflections/` dir — with `generated: true`, `reflection: true`, `related: [members]` (inline
list, NOT the `[[a]], [[b]]` form), `member_hash`, the synthesis inside `<!-- reflect:begin -->` …
`<!-- reflect:end -->`, and a closing `Grounded in: [[member]]…` evidence line. **Do NOT author the
`ai:begin` block** — the knowledge-maintainer backfills `evidence:` from this prose (same single-path rule
as 2d). Reflection pages are FORGET-protected (learnings/concepts), count against the dream change budget,
and are staged like any page.

**2f. REINDEX** — Do NOT call the `knowledge_reindex` MCP tool here: it always targets the LIVE
`knowledgeDir` (no staging-path argument exists) and runs `knowledge_validate` with
`autofix: true` against it, which would mutate the live wiki mid-dream — a direct violation of
"never touch live wiki during execution" below and of `dream_discard`'s rollback guarantee.
Instead, regenerate `staging/wiki/index.md` by hand: read every staged page and rebuild the
catalog yourself. Run AFTER SUMMARIZE + REFLECT so new theme, project-MOC, and reflection pages
are catalogued in the two-tier index.

**2g. FORGET** — bound cold-tier wiki growth (skip entirely if `SB_WIKI_FORGET=off`).
Scores the **LIVE** wiki read-only (it copies to a temp to probe; never mutates live —
and real page ages matter, since staging mtimes are all fresh from the dream snapshot),
selecting low-value, old, unlinked, recall-safe pages, and writes a manifest. Archiving
happens only on accept (Review phase) — the FORGET phase writes nothing to the wiki.

```bash
MAN=$BRAIN_DIR/dreams/{dream_id}/forget-manifest.tsv
if [ "${SB_WIKI_FORGET:-on}" != "off" ]; then
  CAND=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/wiki-forget-candidates.sh"); rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "FORGET: recall guard unavailable — skipping forgetting this dream (fail-safe)."
  else
    : > "$MAN"
    while IFS=$'\t' read -r slug path; do
      [ -n "$slug" ] || continue
      printf '%s\t%s\n' "$slug" "$(basename "$(dirname "$path")")" >> "$MAN"
    done <<< "$CAND"
    n=$(grep -c . "$MAN" 2>/dev/null || echo 0)
    echo "FORGET: staged $n page(s) for archive."
  fi
fi
```

The selector scores structural importance only — connectivity + category weight (no
embeddings; access counts and recency are telemetry, never scored — age survives only as
the <30d PROTECT floor and a sort tie-break). It takes `score < SB_FORGET_FLOOR` (default 0.15), unprotected, capped at
`SB_FORGET_MAX_PER_DREAM` (default 5), and drops any page its live recall-probe shows is
the UNIQUE answer to its topic. If `$n > 0`, add a `## Proposed archives (N)` section to
`diff.md` listing the staged slugs so they're reviewed alongside the consolidation.

### Step 3: Finalize

Generate the diff:
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/dream-diff.sh" {dream_id}
```

Update status to completed:
```bash
TMPFILE=$(mktemp)
jq '.status = "completed" | .ended_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
  $BRAIN_DIR/dreams/{dream_id}/status.json > "$TMPFILE" && mv "$TMPFILE" $BRAIN_DIR/dreams/{dream_id}/status.json
```

Proceed to Review phase.

## Phase: Review

1. Read `$BRAIN_DIR/dreams/{dream_id}/diff.md`
2. Present a concise summary:
   - Pages added (count + titles)
   - Pages modified (count + what changed)
   - Pages removed (count)
   - Key insights surfaced
3. Apply:
   - Call `dream_accept` to apply the consolidation to the live wiki.
   - **Forgetting** — handled by `dream_accept` itself (machine lock in
     `scripts/dream-accept.sh`): if `forget-manifest.tsv` exists, each listed
     page that is STILL forgettable in the post-accept wiki (re-score guard —
     pages the dream just enriched are kept) is archived to
     `$BRAIN_DIR/wiki-archive/` (reversible move, never delete — the
     user's accept IS the confirmation) and logged to `wiki-archive-log.jsonl`.
     The accept output reports `FORGET: archived N page(s)` — relay that count.
4. Report completion — consolidation changes + N pages archived (restore any with
   `bash "$CLAUDE_PLUGIN_ROOT/scripts/wiki-restore.sh" <slug>`).

If the diff shows 0 total changes AND no archive manifest, call `dream_discard` instead
and report that the wiki was already well-consolidated. On any discard, also
`rm -f $BRAIN_DIR/dreams/{dream_id}/forget-manifest.tsv` (archive nothing).

## Constraints

- Max 50 wiki page changes per dream (matches knowledge-maintainer cap)
- Never delete user-created content unless exact duplicate or empty
- All writes go to staging/wiki/ — never touch live wiki during execution
- Clean up: remove session-narrative noise ("in this session", "files touched")
- Keep wiki-link format: `[[lowercase-kebab-case]]`
