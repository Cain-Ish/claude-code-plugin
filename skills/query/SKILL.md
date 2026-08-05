---
name: query
description: Answer a question from the second-brain wiki, citing the pages used. Use when the user asks something the wiki likely covers — topical or relational ("what depends on X", "what breaks if X changes"). Supports --scope <category> to narrow the search.
# Surface-collapse (0.29.0): not a user slash command -- covered by automation/MCP; capability preserved via model-invocation where dmi=false.
user-invocable: false
disable-model-invocation: false
allowed-tools: Read Bash(test *) Bash(cat *) mcp__plugin_second-brain_knowledge-base__knowledge_search mcp__plugin_second-brain_knowledge-base__knowledge_neighbors
argument-hint: "[your question] [--scope <category>]"
---

# Query

Find wiki pages relevant to a question. This skill is a thin wrapper around the `knowledge_search` MCP tool: it issues the search, then leaves synthesis to Claude using the returned candidates.

## Steps

### 1. Parse the argument

`$ARGUMENTS` is the user's question. If it contains a `--scope <category>` token, peel that off and use it as the `scope` argument; otherwise leave `scope` unset to search all categories.

Scope can be any wiki subdirectory name (e.g. `concepts`, `entities`, `learnings`). Omit to search all directories.

### 1a. Project questions → start from the project node

If the question is about **the current project** ("what did we decide about…", "how does this project handle…", "what's blocked here") rather than a general topic, first call `knowledge_neighbors` on the **active project slug** — a project slug with no edges of its own resolves via the project registry to the project's anchor entity (`resolved_anchor` in the result), returning the project's decision/learning/subsystem web. Also consider reading the project hub page `wiki/projects/<slug>.md` (a generated Map of Content of every page carrying that project's facet). Then proceed with the topical search below; the graph hop finds project pages whose text doesn't share the question's words.

### 1b. Relational questions → also walk the graph

If the question is **relational** rather than topical — "what depends on X", "what does X require", "what breaks if I change X", "blast radius of X", "what's related to X" — also call `knowledge_neighbors` on X's slug alongside the BM25 search:

```
knowledge_neighbors(slug: "<X>", direction: "both")
```

`direction: "out"` = X's dependencies (what it requires/affects); `"in"` = its blast radius (what breaks if X changes); `"both"` (default) = the full neighbourhood. Each returned edge carries its type (`requires`/`affects`/`relates`/`part_of`/`supersedes`), hop distance, and validity interval. Synthesize the relational answer from these edges and cite the connected slugs. For purely topical questions ("how do we do X"), skip this and use `knowledge_search` alone. If the graph is absent/empty, fall back to `knowledge_search` only.

### 2. Call `knowledge_search`

```
knowledge_search(query: "<question>", scope: "<optional category>")
```

The tool returns a JSON object of the shape:

```json
{
  "candidates": [
    { "path": "/home/.../wiki/learnings/2026-04-29-counting-pipeline.md", "score": 3, "first_lines": "# Counting pipeline fallback gotcha\n..." }
  ]
}
```

`candidates` is ranked by hybrid search: field-weighted BM25 (title 3x, description 2x, tags 2x, ai-block 1.5x, body 1x) fused with ONNX embeddings via RRF when the vector deps are installed. Without embeddings, ranking is BM25 alone and the result carries `degraded: 'bm25-only'` — surface that flag when present. Capped at 8 results; may be empty.

### 3. Read the top candidates

For each candidate (in score order, up to ~3), read the full file with the `Read` tool. The `first_lines` snippet is just a hint — the full page often contains the answer the snippet doesn't show.

### 4. Synthesize an answer

Write a focused response that:

- Cites each wiki page used: e.g. `According to [[counting-pipeline-redundant-fallback]]…`
- Synthesizes across multiple candidates when more than one is relevant
- Acknowledges gaps explicitly: "The wiki doesn't cover X — here's what I can offer from general knowledge."
- Is honest about confidence: low-score matches (score 1) are often noise.

### 5. On empty candidates

If `candidates` is empty:

1. Tell the user the wiki has no coverage for this question.
2. Offer two follow-ups: (a) answer from general knowledge with that caveat, or (b) offer to capture the answer with `/second-brain:capture` (the raw-inbox drain turns it into a wiki page) so the next query hits a wiki page.

Do not silently fabricate citations — if the wiki has nothing, say so.

## Notes

- This skill never writes to the wiki. Wiki growth happens via the Stop-hook/drainer auto-extractor (creates/updates wiki pages from session content), the raw-inbox drain (`/second-brain:capture` → the maintain skill's raw-drainer worker), the `archive_to_wiki` MCP tool (graduates resolved entries from PROJECT.md), and dream consolidation (`dream_accept`).
- Search is hybrid BM25 + vector (RRF fusion; `degraded: 'bm25-only'` without embeddings) with frontmatter field weighting. It reads full page content, so terms deep in a page still match. Date tokens (YYYY, MM, DD) are filtered from scoring.
- If the wiki has an `index.md`, consider reading it first to browse available pages by category before searching — useful when the question is broad.
- No re-indexing step is needed for search — `knowledge_search` reads the wiki tree on every call. The `index.md` catalog is regenerated by `knowledge_reindex` or after wiki writes.
