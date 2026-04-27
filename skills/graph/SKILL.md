---
name: graph
description: Query the wiki link graph compiled from typed `graph:` blocks and inline [[wiki-links]]. Supports neighbor lookup, shortest path, and relation filtering. Run /second-brain:graph rebuild first if pages have changed since last compile.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(jq *) Bash(cat *) Bash(test *) Bash(bash *) Bash(grep *) Bash(sort *) Bash(uniq *)
argument-hint: "rebuild | neighbors <slug> | path <from> <to> | by-relation <relation>"
---

# Wiki Graph Queries

Query the compiled link graph at `~/knowledge/.graph/edges.jsonl` and `nodes.jsonl`. Built by `scripts/compile-graph.sh`.

## Background

Pages can declare typed edges in a `graph:` block:

```yaml
graph:
  - {relation: depends_on, target: persona-md, evidence: "all learnings rely on persona"}
  - {relation: cites, target: anthropic-evals, evidence: "Anthropic evals guide"}
```

`compile-graph.sh` extracts these (plus untyped `[[wiki-links]]` as `relation: links_to`) into `edges.jsonl`. This skill answers relational questions over that index without LLM-scanning every page.

## Steps

### 1. Subcommand dispatch

Parse `$ARGUMENTS`:
- `rebuild` -> run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/compile-graph.sh` and report the new node/edge count
- `neighbors <slug>` -> show all edges from/to `<slug>` grouped by relation
- `path <from> <to>` -> shortest path via BFS (limit depth 6, return one path)
- `by-relation <relation>` -> all edges with that relation

### 2. Confirm graph is fresh

```bash
test -f ~/knowledge/.graph/build-meta.json && jq '.built_at' ~/knowledge/.graph/build-meta.json
```

If build-meta is missing or older than the newest wiki page, suggest `rebuild` before answering.

### 3. neighbors <slug>

```bash
jq -c --arg s "$SLUG" 'select(.from == $s or .to == $s)' ~/knowledge/.graph/edges.jsonl \
  | jq -s 'group_by(.relation) | map({relation: .[0].relation, edges: .})'
```

Render as:
```
[depends_on]
  -> persona-md (evidence: "all learnings rely on persona")
[links_to]
  -> 2026-04-27-no-filler-phrases
  <- 2026-04-27-second-brain-cross-platform-fixes
```

### 4. path <from> <to>

BFS over edges (treat as undirected). Cap depth at 6. Return one shortest path, e.g.:

```
2026-04-27-no-filler -> persona-md -> ai-attribution-coauthor
```

If no path: report "no link path within 6 hops".

### 5. by-relation <relation>

```bash
jq -c --arg r "$RELATION" 'select(.relation == $r)' ~/knowledge/.graph/edges.jsonl
```

Useful for: "show all `cites`" / "show all `depends_on`" / "show all `links_to`" (default if pages have no typed graph blocks yet).

## Notes

- The graph is **lossy by design** — only typed `graph:` blocks and inline `[[wiki-links]]` are extracted. Free-text references to other pages do not count.
- Untyped `links_to` edges dominate at first; typed relations grow as you author them. `/second-brain:lint` can suggest where to add typed edges (pages with many `links_to` to the same target are good candidates).
- Adjacent compatible relations: `depends_on`, `derived_from`, `cites`, `extends`, `contradicts`, `supersedes`, `related_to`. Add new relation names freely — there is no schema enforcement.
- This skill is **read-only**. To add typed edges, edit the wiki page directly and re-run `rebuild`.
