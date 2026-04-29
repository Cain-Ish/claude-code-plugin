#!/bin/bash
# Compile the wiki link graph.
#
# Walks every ~/knowledge/wiki/**/*.md and extracts:
#   1. Typed edges from `graph:` blocks (frontmatter or body):
#        graph:
#          - {relation: depends_on, target: persona-md, evidence: "..."}
#   2. Untyped edges from inline [[wiki-links]] (relation="links_to")
#
# Writes:
#   ~/knowledge/.graph/edges.jsonl
#   ~/knowledge/.graph/nodes.jsonl
#   ~/knowledge/.graph/build-meta.json
#
# Cheap: walks files once. Safe to re-run; output directory is rebuilt each
# invocation.

echo "compile-graph: deprecated in 0.7.0 — use knowledge_search MCP tool for semantic search" >&2
exit 0
