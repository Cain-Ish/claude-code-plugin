---
name: query
description: Search the knowledge base and synthesize an answer. Uses semantic search (when MCP server is available) and keyword search to find relevant wiki pages, then synthesizes a cited response. Good answers can be filed back as new wiki pages.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(find *) Bash(grep *) Bash(cat *) Bash(ls *) Write Edit mcp__knowledge-base__knowledge_search
argument-hint: "[your question]"
---

# Query the Knowledge Base

Search for information across the wiki and synthesize an answer.

## Tool Integration

Read ~/.claude-companion/tool-registry.json to discover available tools.
Prefer semantic search (knowledge_search MCP tool) when available — it finds
conceptually related pages even when exact keywords don't match.

## Search Strategy

### Step 1: Semantic Search (preferred)

If the `knowledge_search` MCP tool is available:
```
knowledge_search(query: "$ARGUMENTS", limit: 5)
```

This returns ranked pages by semantic similarity.

### Step 2: Keyword Search (fallback or supplement)

Search the wiki directory with grep for key terms from the question:
```bash
grep -rli "keyword" ${user_config.knowledge_dir}/wiki/
```

Also check the index:
```bash
grep -i "keyword" ${user_config.knowledge_dir}/index.md
```

### Step 3: Read Relevant Pages

Read the top-matching pages fully. Don't just rely on excerpts —
the full context often contains the answer.

### Step 4: Synthesize Answer

Provide an answer that:
- Cites specific wiki pages: "According to [[source-title]]..."
- Synthesizes across multiple sources when relevant
- Acknowledges gaps: "The knowledge base doesn't cover X"
- Is honest about confidence level

### Step 5: Optionally File as New Page

If the synthesized answer represents a novel connection or insight
that isn't captured in any existing page, offer to create a new
synthesis page at `${user_config.knowledge_dir}/wiki/synthesis/`.

Update index.md and log.md if a new page is created.

### Step 6: Log the Query

Append to log.md:
```markdown
## [YYYY-MM-DD] query | Brief question summary
Result: [answered/partial/not-found]
Pages consulted: [list]
```
