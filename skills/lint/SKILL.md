---
name: lint
description: Health-check the knowledge base. Finds orphan pages, dead links, broken wiki-links, stale pages, contradictions, and missing cross-references. Run periodically to maintain wiki quality.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(find *) Bash(grep *) Bash(cat *) Bash(ls *) Bash(wc *) Bash(date *) mcp__knowledge-base__knowledge_index
---

# Knowledge Base Lint

Health-check the wiki for structural and content issues.

> **Bash blocks below use `$KD` for the resolved knowledge dir.** Set it once at the start of each block (skill-body `${user_config.X}` placeholders DO NOT expand in bash):
>
> ```bash
> KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
> ```

## Checks

### 1. Orphan Pages

Find pages in `wiki/` that are NOT listed in index.md:

```bash
# All wiki pages
find $KD/wiki -name '*.md' -type f

# Compare against index.md entries
cat $KD/index.md
```

Report any pages missing from the index.

### 2. Dead Links in Index

Check that every link in index.md points to an existing file:

```bash
grep -oP '\(wiki/[^)]+\)' $KD/index.md
```

Verify each referenced file exists.

### 3. Broken Wiki-Links

Search for `[[wiki-links]]` across all wiki pages and verify the target exists:

```bash
grep -roh '\[\[[^]]*\]\]' $KD/wiki/
```

For each link, check if a matching .md file exists in any wiki category.

### 4. Stale Pages

Find pages not modified in over 90 days:

```bash
find $KD/wiki -name '*.md' -mtime +90
```

### 5. Empty or Stub Pages

Find pages with less than 100 characters of content:

```bash
find $KD/wiki -name '*.md' -exec sh -c 'wc -c < "$1"' _ {} \; 
```

### 6. Missing Entity Pages

Check if entities mentioned in sources or learnings have their own entity pages:

```bash
grep -roh '\[\[[^]]*\]\]' $KD/wiki/sources/ $KD/wiki/learnings/
```

Cross-reference against files in `wiki/entities/`.

### 7. Contradictions and stale facts (requires reading)

Read related pages and check for conflicting claims. Focus on:
- Different dates or versions cited for the same thing
- Conflicting recommendations or assessments
- Outdated information superseded by newer sources

### 7a. Append-only drift

Pages should reflect *current* state, not be layered transcripts. Surface pages that look like they've been appended to without being rewritten:

- Multiple "however," / "but newer source says" / "as of <old date>, but actually" stretches in one body
- Several distinct dated paragraphs in the body itself (dates belong in `## History`, not the body)
- Pages with two clearly contradictory bullet lists in the same section

For each offender, offer to rewrite the body to current state and move the change provenance to a `## History` section per the schema.

### 7b. Missing History on heavily-revised pages

Find pages that have been touched by 3+ ingest entries in `log.md` but have no `## History` section. Offer to backfill a History stub from the log entries.

## Reporting

Present findings in a structured format:

```
# Knowledge Base Health Report

## Critical
- [list of broken links, dead references]

## Warnings  
- [list of orphans, stubs, stale pages]

## Suggestions
- [missing entity pages, potential cross-references]

## Summary
- Total pages: X
- Issues found: X
- Health score: X/10
```

## Fixing

Offer to fix issues:
- Add orphan pages to index.md
- Remove dead links from index.md
- Create stub entity pages for missing entities
- Add missing cross-references
- Mark stale pages with a `[NEEDS UPDATE]` banner

After fixes, re-index embeddings:
```
knowledge_index(force: false)
```

Log the lint run:
```markdown
## [YYYY-MM-DD] lint | N issues found, M fixed
```
