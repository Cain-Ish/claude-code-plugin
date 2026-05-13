---
name: recall
description: Search past conversation transcripts for decisions, solutions, and context from previous sessions. Uses hybrid vector + text search over archived session transcripts.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read mcp__knowledge-base__episodic_search mcp__knowledge-base__episodic_read
argument-hint: "[query] [--project <slug>] [--after YYYY-MM-DD]"
---

# Recall

Search past conversations to recover decisions, solutions, and patterns from previous sessions.

## Steps

### 1. Parse the argument

`$ARGUMENTS` is the user's search query. If it contains `--project <slug>`, peel that off and pass as the `project` filter. If it contains `--after YYYY-MM-DD` or `--before YYYY-MM-DD`, pass those as date filters.

### 2. Call `episodic_search`

```
episodic_search(query: "<question>", project: "<optional>", after: "<optional>", before: "<optional>")
```

The tool returns ranked results with similarity scores, session metadata, and file paths.

For complex queries involving multiple related concepts, pass an array of 2-5 terms to trigger AND matching:
```
episodic_search(query: ["BM25", "scoring", "recency"])
```

### 3. Read top results

For the top 2-3 results, use `episodic_read` with the `path`, `startLine`, and `endLine` from the search results to get full conversation context.

### 4. Synthesize

Write a focused response that:
- Summarizes what was decided and why
- Notes specific solutions, file paths, or patterns from the conversation
- Highlights gotchas or rejected alternatives if present
- Cites sessions by project and date

### 5. On empty results

If no results found:
1. Tell the user no matching conversations were found in the transcript archive
2. Note that only sessions with substantive tool use are archived (trivial sessions are skipped)
3. Suggest narrowing the search with different keywords or broadening with a project filter

## Notes

- Transcripts are archived automatically by Stop and PreCompact hooks
- Archive cap: 100 files, 5MB total — oldest files pruned first
- Search uses hybrid vector (ONNX embeddings) + text matching
- Exchanges are indexed at the user↔assistant turn level
- The episodic index is rebuilt incrementally after each session
