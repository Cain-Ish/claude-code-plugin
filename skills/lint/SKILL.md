---
name: lint
description: Health-check the second-brain wiki and PROJECT.md cross-references. Finds orphan wiki pages, dead [[wiki-links]], and broken Cross-references slugs. Read-only by default — offers fixes interactively.
# 0.33.24 skill-catalog diet: user slash command only — model-invocation disabled
# (knowledge_validate/reindex cover the automated path; the interactive lint stays explicit).
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Bash(find *) Bash(grep *) Bash(cat *) Bash(ls *) Bash(test *) Bash(basename *) Bash(sort *) Bash(comm *) Bash(awk *) Bash(bash *)
---

# Lint

Health-check the v1.0 second-brain. Three structural checks; no content rules.

> **Bash blocks below use `$KD` for the resolved knowledge dir** and `$BD` for `.second-brain`. Set them once at the start of each block (skill-body `${user_config.X}` placeholders DO NOT expand in bash):
>
> ```bash
> KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
> BD="$HOME/.second-brain"
> ```
>
> **awk reserved-word note (applies to every awk block in this skill).** Do
> not use the bare token `in` as a variable name in any awk program below —
> `in` is reserved in both gawk and mawk (used by `for (x in arr)` and the
> membership test `(elem in arr)`) and produces `syntax error at or near in`
> on Pi OS / Debian default `awk` (which is mawk 1.3.4). Use `inside`,
> `seen`, or any other identifier. Compound identifiers like `in_fence` are
> fine — only the bare `in` token collides with the reserved word. Verified
> RED: the historical form silently skipped Check 1 and Check 3 on Pi/
> Debian. The regression is guarded by `tests/test-lint-skill.sh` (parse-
> check across every awk block + RED-on-injection assertion).

## Checks

### 1. Orphan wiki pages

A wiki page is an *orphan* if no other wiki page or PROJECT.md links to it. Build the inbound-link set, then compare against the file set.

```bash
# All wiki page slugs (filename without .md). Exclude the generated MOC dirs
# (projects/, themes/) — like index.md they are auto-generated projections with no
# AUTHORED inbound links by design, so they must never be flagged as orphans.
ALL=$(find "$KD/wiki" -name '*.md' -type f -not -path '*/projects/*' -not -path '*/themes/*' | while read f; do basename "$f" .md; done | sort -u)

# All inbound links: [[slug]] occurrences across wiki + every PROJECT.md.
# Strip the graph projector's generated block (<!-- graph:begin --> ... <!-- graph:end -->),
# fenced code blocks, and inline backtick spans first so generated [[links]], bash [[ test ]]
# syntax, and code-block placeholder examples don't surface as false dead-links.
# NOTE (graph skip): the projector's "## Dependencies" block is a generated projection of
# ~/knowledge/graph/edges.jsonl, not authored content. Excluding it means a page linked ONLY
# from generated blocks counts as an orphan — correct, because orphan-ness must reflect AUTHORED
# references (the projector would just regenerate generated links). Dead edges are caught instead
# by knowledge_validate, which checks the related: frontmatter the projector also writes.
# Slug regex accepts uppercase letters (phase markers: `self-evolve-v1-P2-plan`)
# and periods (version-style slugs: `vps-phase-3.2-2026-05-14`). Bash test
# expressions are already excluded by the code-fence / inline-code strip
# above, plus the fact that the slug regex requires the FIRST char to be
# alnum (real bash tests start with space + `-`).
LINKED=$(find "$KD/wiki" "$BD/projects" -name '*.md' -type f 2>/dev/null | while read -r f; do
  awk '
    /<!-- graph:begin/ { in_graph = 1; next }
    /<!-- graph:end/   { in_graph = 0; next }
    in_graph { next }
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    in_fence { next }
    { gsub(/`[^`]*`/, ""); print }
  ' "$f"
done | grep -oE '\[\[[a-zA-Z0-9][a-zA-Z0-9.-]*\]\]' \
     | sed -E 's/\[\[([^]]+)\]\]/\1/' | sort -u)

# Plus slugs listed in any "## Cross-references" section. (`inside`, not
# `in` — see header note on awk reserved words.)
CROSS=$(awk '
  /^## Cross-references/ { inside=1; next }
  /^## / && inside { inside=0 }
  inside && /^- / { sub(/^- */, ""); print }
' "$BD"/projects/*/PROJECT.md 2>/dev/null | sort -u)

# Orphans = ALL minus (LINKED ∪ CROSS), excluding known auto-generated slugs
# that aren't expected to be manually cross-referenced:
#   - index                — wiki/index.md catalog page (auto-generated)
#   - evolve-01[A-Z0-9]{24} — ULID-suffixed self-evolve decision logs emitted
#                            by the cainish-evolve pipeline; referenced by
#                            cycle index pages, not by hand.
#   - evolve-cycle-YYYY-MM-DD — per-run self-evolve cycle summary pages emitted
#                            by the same pipeline; these ARE the cycle index
#                            pages (they reference the evolve-01* logs), so like
#                            wiki/index.md they have no inbound links by design.
comm -23 <(echo "$ALL") <(printf '%s\n%s\n' "$LINKED" "$CROSS" | sort -u) \
  | grep -vE '^(index|evolve-01[0-9A-Z]{24}|evolve-cycle-[0-9]{4}-[0-9]{2}-[0-9]{2})$'
```

Report each orphan with its full path. Suggest the user either delete it (if obsolete) or add a `[[<slug>]]` reference somewhere it belongs.

### 2. Dead `[[wiki-links]]`

Every `[[slug]]` should resolve to a real wiki page (filename `<slug>.md` under any wiki category). Anything that doesn't resolve is dead.

```bash
# All link targets actually used. Same code-span strip + slug-shape filter
# as Check 1 — keeps bash [[ test ]] and code-block examples out of the set.
USED=$(find "$KD/wiki" "$BD/projects" -name '*.md' -type f 2>/dev/null | while read -r f; do
  awk '
    /<!-- graph:begin/ { in_graph = 1; next }
    /<!-- graph:end/   { in_graph = 0; next }
    in_graph { next }
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    in_fence { next }
    { gsub(/`[^`]*`/, ""); print }
  ' "$f"
done | grep -oE '\[\[[a-zA-Z0-9][a-zA-Z0-9.-]*\]\]' \
     | sed -E 's/\[\[([^]]+)\]\]/\1/' | sort -u)

# Existing slugs
EXISTS=$(find "$KD/wiki" -name '*.md' -type f | while read f; do basename "$f" .md; done | sort -u)

# Dead = USED minus EXISTS
comm -23 <(echo "$USED") <(echo "$EXISTS")
```

For each dead link, also report which file(s) it appears in:

```bash
DEAD_SLUG="counting-pipeline-redundant-fallback"   # example
grep -rln "\[\[${DEAD_SLUG}\]\]" "$KD/wiki" "$BD/projects" 2>/dev/null
```

Suggest: rename the link to a real slug, create the missing page, or remove the dead reference.

### 3. Broken `Cross-references:` slugs in PROJECT.md

Each `~/.second-brain/projects/<slug>/PROJECT.md` has a `## Cross-references` section listing ≤3 wiki page slugs. Verify each slug resolves to a real wiki page.

```bash
for f in "$BD"/projects/*/PROJECT.md; do
  [ -f "$f" ] || continue
  PROJ=$(basename "$(dirname "$f")")
  awk '
    /^## Cross-references/ { inside=1; next }
    /^## / && inside { inside=0 }
    inside && /^- / { sub(/^- */, ""); print }
  ' "$f" | while read SLUG; do
    [ -z "$SLUG" ] && continue
    if ! find "$KD/wiki" -name "${SLUG}.md" -type f -print -quit | grep -q .; then
      echo "BROKEN: $PROJ -> $SLUG (no wiki/<category>/${SLUG}.md)"
    fi
  done
done
```

Suggest: drop the broken slug from `Cross-references`, or create the missing wiki page.

### 4. Missing ai-block on structured pages

A page in one of the six structured categories (learnings, decisions, entities, issues,
concepts, security) should carry an `<!-- ai:begin … ai:end -->` block — the machine-first
"shared intermediate" an AI reads instead of re-deriving the page from prose. A *substantive*
page (≥ 200 non-space prose chars) with no block predates the feature or was never authored.
Stubs are exempt. (`infm`/`drop`, not the reserved `in` — see the awk header note.)

```bash
# Structured types come from the KB single source of truth (kb-schema.json), not a hardcoded list.
source "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/cache/second-brain/second-brain/*/}/scripts/kb-schema.sh" 2>/dev/null || true
for type in ${SB_STRUCTURED_TYPES:-learnings decisions entities issues concepts security}; do
  d="$KD/wiki/$type"; [ -d "$d" ] || continue
  find "$d" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | while read -r f; do
    # Skip pages that already have a block. Use `grep -l` (whole-file, capture) NOT `grep -q`:
    # `grep -q` exits at the first match, and when this block is pasted into a job-control shell
    # (monitor mode, how /second-brain:lint runs it) that early exit SIGPIPEs the upstream `find`
    # and ends the loop after one page -> the check would silently report 0. `grep -l` reads to EOF.
    [ -n "$(grep -lE '<!--[[:space:]]*ai:begin' "$f" 2>/dev/null)" ] && continue
    # Canonical type = explicit frontmatter `type:` (else the dir): a page mis-filed in a
    # structured dir but declaring a non-structured/typo'd type (`type: index`, `type: concept`)
    # is not a candidate -- keeps lint in lockstep with knowledge_validate.
    ftype=$(awk 'NR==1 && !/^---[[:space:]]*$/{exit} NR>1 && /^---[[:space:]]*$/{exit} /^type:[[:space:]]/{sub(/^type:[[:space:]]*/,"");gsub(/[\047",]/,"");gsub(/[[:space:]]+$/,"");print;exit}' "$f")
    case "${ftype:-$type}" in learnings|decisions|entities|issues|concepts|security) ;; *) continue ;; esac
    # An UNTERMINATED region (begin, no matching end) is NOT a block: its held lines are emitted
    # at END so they still count (never silently drop a real page's prose -- mirrors the
    # knowledge_validate bounded strip + the forget-scorer guard). `infm`/`drop`, not reserved `in`.
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
    [ "$prose" -ge 200 ] && echo "MISSING-BLOCK: $type/$(basename "$f" .md) ($f)"
  done
done
```

Suggest: run `/second-brain:maintain` — the knowledge-maintainer (Phase 4b) backfills the block
from the page's own prose. Do **not** hand-author the block here (lint is read-only by default).

### 5. Live-title recall probe (search health)

Every page's own title should retrieve that page in the top-2. A failure here
means search RANKING is broken for real content (the hub-boost bug class —
R2.1/R2.2 contracts), not that a page is bad. Read-only; deterministic BM25-only path with a hermetic
brain dir (never touches live access counts).

If `$CLAUDE_PLUGIN_ROOT` is not set in your Bash environment, resolve it first:
`PR=$(ls -d ~/.claude/plugins/cache/second-brain/second-brain/*/ | sort -V | tail -1)`
and use `$PR` in place of `$CLAUDE_PLUGIN_ROOT` below. Note: the full probe
takes ~1 min per 100 pages on Pi-class hardware; cap with
`SB_EVAL_TITLE_SAMPLE=40` for a quick spot-check.

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/wiki-recall-check.sh" \
  --live-titles "${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}" --k 2
```

Report the recall line; if misses are listed, name the missed slugs under a
`## Search recall misses` section — they are SERVING bugs to investigate (or
genuinely ambiguous titles), not pages to edit. Same-titled page series (e.g.
daily digests) are deduplicated to one probe query automatically.

## Reporting

Present findings in three sections; keep counts visible. Example:

```
# Wiki health report

## Orphan pages (3)
- /home/u/knowledge/wiki/concepts/loose-page.md
- ...

## Dead [[wiki-links]] (2)
- [[old-name]] referenced in wiki/learnings/2026-04-12-foo.md
- [[typo-slug]] referenced in projects/my-repo/PROJECT.md

## Broken Cross-references (1)
- my-repo -> obsolete-concept (no wiki page)

## Missing ai-blocks (1)
- learnings/oauth-bare-flag (substantive page, no ai:begin block)

## Summary
- Wiki pages scanned: 47
- Issues found: 6
```

## Fixing

Offer fixes one issue at a time:

- Orphans → delete the file, or pick a target page to add a `[[<slug>]]` reference into.
- Dead links → fix the target slug, or remove the link.
- Broken Cross-references → drop the slug from the offending PROJECT.md, or create the missing wiki page.

No re-indexing step is required — `knowledge_search` reads the wiki tree directly on every call.

## Notes

- No content rules: freshness tiers, coverage labels, append-only drift, and contradictions are owned by the maintainer/dream consolidation cycle, not this skill (stub pages are `knowledge_validate`'s territory). Lint checks structure and retrieval health only.
- No write actions are taken without an explicit Y from the user.
