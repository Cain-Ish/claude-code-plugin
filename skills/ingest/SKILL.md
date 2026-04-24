---
name: ingest
description: Process a new source document into the knowledge base. Reads the source, discusses key takeaways, creates wiki pages (source summary, entity pages, concept pages), adds cross-references, and updates the index. Use when adding articles, notes, papers, or session insights.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(ls *) Bash(find *) Bash(cat *) Bash(wc *) Bash(grep *) Bash(date *) WebSearch WebFetch mcp__knowledge-base__knowledge_index
argument-hint: "[file-path or URL]"
---

# Ingest Source into Knowledge Base

Process a new source and integrate it into the wiki.

## Tool Integration

Read ~/.second-brain/tool-registry.json to discover available tools.
Use any relevant tools to enhance the ingestion:
- Documentation tools: verify technical claims against current docs
- Search tools: find related context for richer wiki pages
- Memory tools: check if related topics were discussed in past sessions

## Steps

### 1. Read the Source

If `$ARGUMENTS` is a file path, read it with the Read tool.
If it's a URL, fetch it with WebFetch.
If no argument, ask the user what to ingest.

### 2. Discuss Takeaways

Before creating wiki pages, briefly discuss with the user:
- What are the 2-3 most interesting or useful points?
- How does this connect to existing knowledge?
- Are there specific people, tools, or concepts worth tracking?

### 3. Create Wiki Pages

Based on the source content, create appropriate pages:

**Source summary** — always create one at `${user_config.knowledge_dir}/wiki/sources/`:

```markdown
# [Source Title]

One-line summary of what this source covers.

## Key Points

- Point 1
- Point 2
- Point 3

## Details

[Expanded summary of the most important content]

## Source

- **Type**: [article/paper/notes/transcript/documentation]
- **Author**: [if known]
- **Date**: [original date if known]
- **Ingested**: [today's date YYYY-MM-DD]

## Related

- [[relevant-entity-or-concept]]
```

**Entity pages** — create in `${user_config.knowledge_dir}/wiki/entities/` for notable people, organizations, products, or tools mentioned:

```markdown
# [Entity Name]

One-line description of who/what this is.

## Overview

[What we know about this entity from all sources]

## Mentions

- [[source-that-mentions-this]] — context of mention

## Related

- [[other-related-entities-or-concepts]]
```

**Concept pages** — create in `${user_config.knowledge_dir}/wiki/concepts/` for ideas, patterns, frameworks, or techniques:

```markdown
# [Concept Name]

One-line definition or summary.

## Description

[What this concept is and why it matters]

## Applications

[How this concept is applied in practice]

## Related

- [[related-concepts-or-entities]]
```

### 4. Update Existing Pages

If ingesting a source that relates to existing wiki pages:
- Read existing pages that might be affected
- Add new cross-references using `[[wiki-links]]`
- Update entity or concept pages with new information from this source
- Resolve any contradictions (note both perspectives if unclear)

### 5. Update Index and Log

**index.md** — add entries under the appropriate category:
```markdown
- [Page Title](wiki/category/filename.md) — one-line summary
```

**log.md** — append a new entry:
```markdown
## [YYYY-MM-DD] ingest | Source Title
Ingested from: [path or URL]
Pages created: [list of new pages]
Pages updated: [list of updated pages]
```

### 6. Re-index Embeddings

After creating/updating wiki pages, call the `knowledge_index` MCP tool to update embeddings for semantic search:
```
knowledge_index(force: false)
```

If the MCP tool is not available, skip this step — the index will be updated next time the MCP server runs.

## File Naming Convention

- Use lowercase kebab-case: `my-source-title.md`
- Keep names descriptive but concise
- For dated content: `YYYY-MM-DD-title.md`
