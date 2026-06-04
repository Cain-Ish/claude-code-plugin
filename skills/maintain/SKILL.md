---
name: maintain
description: Run the knowledge-maintainer on the second-brain wiki — audit, dedup, relate, enrich, author ai-blocks, and drain the raw inbox into wiki nodes. An explicit full maintenance run.
user-invocable: true
disable-model-invocation: true
allowed-tools: Agent Read
---

# /second-brain:maintain — run the knowledge-maintainer

Dispatch the **knowledge-maintainer** agent for an **explicit** full maintenance run over
the knowledge base. Use the `Agent` tool with `subagent_type: "knowledge-maintainer"`.

Unlike an auto-dispatched maintenance run (which the plugin triggers after extraction or a
reindex and which performs only the consolidation phases), an explicit `/second-brain:maintain`
run also performs the two **bulk-authoring** phases that auto-runs deliberately skip:

- **Phase 4b** — author/backfill the machine-first `ai-block` on structured pages.
- **Phase 4c** — drain the **raw inbox** (`/second-brain:capture` + setup deep-scan material)
  into wiki nodes (conservative create/update, never auto-discard, with provenance).

Tell the agent this is an explicit run so it does not skip 4b/4c. When it finishes, relay its
report: pages audited/merged/related/enriched, ai-blocks authored, raw items drained
(created / updated / left-unprocessed for manual prune), and the reindex result. The agent
writes live and is bounded by its 50-change/run cap; if it reports work left over the cap,
re-run `/second-brain:maintain`.
