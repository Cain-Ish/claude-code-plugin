---
name: lint
description: Health-check the second-brain wiki and PROJECT.md cross-references. Finds orphan wiki pages, dead [[wiki-links]], and broken Cross-references slugs. Read-only by default — offers fixes interactively.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(find *) Bash(grep *) Bash(cat *) Bash(ls *) Bash(test *) Bash(basename *) Bash(sort *) Bash(comm *) Bash(awk *)
---

<!-- user instruction verbatim: "1" -->

# Lint

Health-check the v1.0 second-brain. Three structural checks; no content rules.

> **Bash blocks below use `$KD` for the resolved knowledge dir** and `$BD` for `.second-brain`. Set them once at the start of each block (skill-body `${user_config.X}` placeholders DO NOT expand in bash):
>
> ```bash
> KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
> BD="$HOME/.second-brain"
> ```

## Checks

### 1. Orphan wiki pages

A wiki page is an *orphan* if no other wiki page or PROJECT.md links to it. Build the inbound-link set, then compare against the file set.

```bash
# All wiki page slugs (filename without .md)
ALL=$(find "$KD/wiki" -name '*.md' -type f | while read f; do basename "$f" .md; done | sort -u)

# All inbound links: [[slug]] occurrences across wiki + every PROJECT.md.
# Strip fenced code blocks and inline backtick spans first so bash [[ test ]]
# syntax and code-block placeholder examples don't surface as false dead-links.
# Slug regex accepts uppercase letters (phase markers: `self-evolve-v1-P2-plan`)
# and periods (version-style slugs: `vps-phase-3.2-2026-05-14`). Bash test
# expressions are already excluded by the code-fence / inline-code strip
# above, plus the fact that the slug regex requires the FIRST char to be
# alnum (real bash tests start with space + `-`).
LINKED=$(find "$KD/wiki" "$BD/projects" -name '*.md' -type f 2>/dev/null | while read -r f; do
  awk '
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    in_fence { next }
    { gsub(/`[^`]*`/, ""); print }
  ' "$f"
done | grep -oE '\[\[[a-zA-Z0-9][a-zA-Z0-9.-]*\]\]' \
     | sed -E 's/\[\[([^]]+)\]\]/\1/' | sort -u)

# Plus slugs listed in any "## Cross-references" section
CROSS=$(awk '
  /^## Cross-references/ { in=1; next }
  /^## / && in { in=0 }
  in && /^- / { sub(/^- */, ""); print }
' "$BD"/projects/*/PROJECT.md 2>/dev/null | sort -u)

# Orphans = ALL minus (LINKED ∪ CROSS), excluding known auto-generated slugs
# that aren't expected to be manually cross-referenced:
#   - index                — wiki/index.md catalog page (auto-generated)
#   - evolve-01[A-Z0-9]{24} — ULID-suffixed self-evolve decision logs emitted
#                            by the cainish-evolve pipeline; referenced by
#                            cycle index pages, not by hand.
comm -23 <(echo "$ALL") <(printf '%s\n%s\n' "$LINKED" "$CROSS" | sort -u) \
  | grep -vE '^(index|evolve-01[0-9A-Z]{24})$'
```

Report each orphan with its full path. Suggest the user either delete it (if obsolete) or add a `[[<slug>]]` reference somewhere it belongs.

### 2. Dead `[[wiki-links]]`

Every `[[slug]]` should resolve to a real wiki page (filename `<slug>.md` under any wiki category). Anything that doesn't resolve is dead.

```bash
# All link targets actually used. Same code-span strip + slug-shape filter
# as Check 1 — keeps bash [[ test ]] and code-block examples out of the set.
USED=$(find "$KD/wiki" "$BD/projects" -name '*.md' -type f 2>/dev/null | while read -r f; do
  awk '
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
    /^## Cross-references/ { in=1; next }
    /^## / && in { in=0 }
    in && /^- / { sub(/^- */, ""); print }
  ' "$f" | while read SLUG; do
    [ -z "$SLUG" ] && continue
    if ! find "$KD/wiki" -name "${SLUG}.md" -type f -print -quit | grep -q .; then
      echo "BROKEN: $PROJ -> $SLUG (no wiki/<category>/${SLUG}.md)"
    fi
  done
done
```

Suggest: drop the broken slug from `Cross-references`, or create the missing wiki page.

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

- No content rules: this skill no longer checks freshness tiers, coverage labels, append-only drift, contradictions, or stub size. Those were 0.7.0 ingest-pipeline concerns and are out of scope in v1.0.
- No write actions are taken without an explicit Y from the user.
