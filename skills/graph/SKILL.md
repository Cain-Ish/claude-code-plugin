---
name: graph
description: "Deprecated in 0.7.0. Use knowledge_search MCP tool for semantic search across wiki pages."
user-invocable: true
disable-model-invocation: false
allowed-tools: Read
argument-hint: ""
---

# Wiki Graph — Deprecated

The wiki link graph (`compile-graph.sh`) was deprecated in v0.7.0.

The graph layer added maintenance overhead without providing enough value — it was rarely queried in practice. Use the `knowledge_search` MCP tool instead for semantic search across wiki pages.

If you need to find relationships between pages, use `knowledge_search` with concept intersection queries (array of 2-5 terms).

The `~/knowledge/.graph/` directory may still exist from previous runs but is no longer updated.
