---
name: query
description: Search the second-brain wiki for pages relevant to a question. Thin wrapper around the knowledge_search MCP tool — returns candidate pages and lets Claude synthesize a cited answer from them.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(test *) Bash(cat *) mcp__knowledge-base__knowledge_search
argument-hint: "[your question] [--scope concepts|issues|entities|learnings|decisions]"
---

<!-- user instruction verbatim: "1" -->

# Query

Find wiki pages relevant to a question. This skill is a thin wrapper around the `knowledge_search` MCP tool: it issues the search, then leaves synthesis to Claude using the returned candidates.

## Steps

### 1. Parse the argument

`$ARGUMENTS` is the user's question. If it contains a `--scope <category>` token, peel that off and use it as the `scope` argument; otherwise leave `scope` unset to search all categories.

Valid scopes: `concepts`, `issues`, `entities`, `learnings`, `decisions`.

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

`candidates` is ranked by token-overlap score (highest first), capped at 5 results, and may be empty.

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
2. Offer two follow-ups: (a) answer from general knowledge with that caveat, or (b) suggest they pin the answer with `/second-brain:improve` after the conversation so the next query hits a wiki page.

Do not silently fabricate citations — if the wiki has nothing, say so.

## Notes

- This skill never writes to the wiki. Wiki growth happens via `/second-brain:improve` (proposes pins) and the `archive_to_wiki` MCP tool (graduates resolved entries from PROJECT.md).
- Token-overlap search is literal: a question phrased differently from the indexed page may miss. If you suspect a miss, retry with synonyms or fewer keywords before declaring "no coverage."
- No re-indexing step is needed — `knowledge_search` reads the wiki tree on every call.
