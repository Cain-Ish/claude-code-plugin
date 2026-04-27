---
name: query
description: Search the knowledge base and synthesize an answer. Uses semantic search (when MCP server is available) and keyword search to find relevant wiki pages, then synthesizes a cited response. Good answers can be filed back as new wiki pages.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(find *) Bash(grep *) Bash(cat *) Bash(ls *) Write Edit WebSearch WebFetch mcp__knowledge-base__knowledge_search
argument-hint: "[your question]"
---

# Query the Knowledge Base

Search for information across the wiki and synthesize an answer.

## Tool Integration

Read ~/.second-brain/tool-registry.json to discover available tools.
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

Search the wiki directory with grep for key terms from the question. Resolve the knowledge dir from the auto-injected env var (skill-body `${user_config.X}` doesn't expand in bash):

```bash
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
grep -rli "keyword" "$KD/wiki/"
```

Also check the index:
```bash
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
grep -i "keyword" "$KD/index.md"
```

### Step 3: Read Relevant Pages

Read the top-matching pages fully. Don't just rely on excerpts —
the full context often contains the answer.

### Step 3.5: Research-on-miss (new in 0.5.0)

If steps 1–3 returned nothing useful (semantic search empty AND keyword search empty AND index has no relevant entry), do not just return "not found." Instead:

1. State briefly: "The knowledge base doesn't cover this. I can research it now and ingest the result so future queries hit cache."
2. Wait for user confirmation (`yes` / `skip`). Don't research silently — research costs tokens and time, and the user may want to answer from their own knowledge.
3. On confirmation:
   - Use `WebSearch` for breadth, then `WebFetch` on the 1–2 most authoritative sources
   - Synthesize a focused answer grounded in those sources (cite each)
   - Offer to ingest the synthesis as a new `wiki/sources/<slug>.md` page using the standard ingest template (with `Coverage:` and `Freshness tier:` set appropriately — short tiers for fast-moving topics, longer for stable references)
4. On skip: return "no wiki coverage; you may want `/second-brain:ingest <url>` for sources you want indexed."

This closes the "miss → silent void → next time same miss" loop.

### Step 4: Synthesize Answer

Provide an answer that:
- Cites specific wiki pages: "According to [[source-title]]..."
- Synthesizes across multiple sources when relevant
- Acknowledges gaps: "The knowledge base doesn't cover X"
- Is honest about confidence level

### Step 5: Optionally File as New Page

If the synthesized answer represents a novel connection or insight
that isn't captured in any existing page, offer to create a new
synthesis page under `<knowledge-dir>/wiki/synthesis/` — where
`<knowledge-dir>` resolves to `$CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR`
or `~/knowledge` by default. Substitute the actual path when writing.

Update index.md and log.md if a new page is created.

### Step 6: Log the Query

Append to log.md:
```markdown
## [YYYY-MM-DD] query | Brief question summary
Result: [answered/partial/not-found]
Pages consulted: [list]
```
