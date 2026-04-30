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

## Path resolution

Throughout this skill, `<knowledge-dir>` means the resolved knowledge base path:
the value of `$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` if set, otherwise `~/knowledge`.
When you create or read files, substitute the actual path — do NOT use the literal
string `<knowledge-dir>` or `<knowledge-dir>`, which won't resolve.

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

**Source summary** — always create one at `<knowledge-dir>/wiki/sources/`:

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
- **Coverage**: [high | medium | low]  <!-- how complete is this page? high = comprehensive, low = stub/excerpt -->
- **Freshness tier**: [live | 7d | 30d | 90d | permanent]  <!-- how often does this need re-checking? -->

<!-- Choosing freshness_tier:
  live      = breaking / changes hourly (rarely used; API status pages)
  7d        = fast-moving (API docs, framework releases, market data)
  30d       = active topic (library best practices, evolving standards)
  90d       = stable reference (default for most ingests)
  permanent = mathematical truths, foundational papers, history -->


## Related

- [[relevant-entity-or-concept]]
```

**Entity pages** — create in `<knowledge-dir>/wiki/entities/` for notable people, organizations, products, or tools mentioned:

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

**Concept pages** — create in `<knowledge-dir>/wiki/concepts/` for ideas, patterns, frameworks, or techniques:

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

### 3b. Extract Patterns, Issues, and Decisions

If the source mentions reusable code patterns, known bugs/workarounds, or architectural decisions, create appropriate pages:

**Pattern pages** — create in `<knowledge-dir>/wiki/patterns/`:

```markdown
# [Pattern Name]

One-line summary of the pattern.

## Usage

[Where and how this pattern is used in the codebase]

## Example

[Code snippet or file reference]

## Gotchas

[Common pitfalls or edge cases]

## Related

- [[relevant-entities]]
```

**Issue pages** — create in `<knowledge-dir>/wiki/issues/`:

```markdown
# [Issue Title]

One-line summary of the issue.

## Symptom

[What the user sees or experiences]

## Root Cause

[Why this happens]

## Workaround / Fix

[How to resolve or work around it]

## Affected Files

- `path/to/file.ts`

## Related

- [[relevant-entities]]
```

**Decision pages** — create in `<knowledge-dir>/wiki/decisions/`:

```markdown
# [Decision Title]

One-line summary of the decision.

## Context

[What prompted this decision]

## Decision

[What was decided]

## Alternatives Considered

- Alternative 1: [why not chosen]
- Alternative 2: [why not chosen]

## Consequences

[What follows from this decision]

## Related

- [[relevant-entities]]
```

### 4. Update Existing Pages — keep them current, don't append blindly

If ingesting a source that relates to existing wiki pages:

- Read existing pages that might be affected
- Add new cross-references using `[[wiki-links]]`
- **Rewrite the body to reflect the current state, not the history of states.** If the new source supersedes the old (newer date, more authoritative source, explicit user statement of what's current), update the affected sections so they read as truth *today*. Add new facts, remove or replace facts that are no longer accurate. The page body should never read like a layered transcript of every prior version.
- **Append a one-line entry to a `## History` section** at the bottom of the page for every rewrite, so change provenance survives:
  ```
  ## History
  - [YYYY-MM-DD] Updated <section>: <what changed>; source: [[this-source]]
  ```
  Create the section if missing.
- **Only when two sources genuinely conflict and neither is clearly more current**, keep both perspectives in the body (each clearly attributed) and add a `## Open Questions` section flagging the conflict. This is the exception, not the default.

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
