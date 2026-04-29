# Reflection Protocol

When `~/.second-brain/.pending-reflections.jsonl` exists and is non-empty, process it silently. The file is JSONL format — one JSON object per line, appended chronologically by pre-compact, stop, and clear hooks.

## Entry Fields

Each line contains: `session_id`, `date`, `appended_at` (ISO8601 — use for chronological ordering), `trigger` (`stop`/`pre-compact`/`clear`), `user_turns`, `friction_count`, `positive_signals`, `first_try_success`, `drift_count`, `priority`, `suggest_plugin_improve`, `transcript_path` (may no longer exist after compaction), `context_snapshot` (path to ~100-line transcript tail saved at write-time — survives compaction), `goals`, `completed`, `in_progress`, `blockers`.

## Processing Order

Process **all entries**, bottom of file first (most recent context first). For each entry:

1. Read the `context_snapshot` file if it exists (preferred for `pre-compact` entries where the original transcript is gone)
2. For `stop`/`clear` entries, read `transcript_path` if available, fall back to `context_snapshot`
3. Extract knowledge into two outputs (below)
4. Use `knowledge_search` MCP tool to check for existing wiki pages before creating new ones — multiple reflections may touch the same entities

## PROCESS LEARNINGS (friction -> ~/.second-brain/learnings.md)

Read friction-log.jsonl. Extract process improvements from friction signals. Critic gate: dispatch subagent (subagent_type: "second-brain:quality-reviewer") with proposal + destination + friction example. ACCEPT/REVISE/REJECT. Log to critic-log.jsonl. Add `<!-- meta: confidence=0.X hits=0 last_used=YYYY-MM-DD -->`. Mirror as ~/knowledge/wiki/learnings/YYYY-MM-DD-short-title.md.

## CONTENT KNOWLEDGE (wiki is an index, not a dump)

Wiki pages should be CONCISE — just enough for future Claude to know what happened and where to dig deeper. Use knowledge_search MCP tool to check what's already in the wiki before creating new pages.

- Session pages (wiki/sessions/YYYY-MM-DD-topic.md): 10-20 lines max. Topic, key decisions, entities touched, outcome. NOT a transcript summary.
- Entity pages (wiki/entities/name.md): Curated knowledge about a project/tool/component. Update existing pages, don't duplicate.
- Concept pages (wiki/concepts/): Only for ideas or frameworks that apply across sessions.
- Pattern pages (wiki/patterns/name.md): Reusable codebase patterns. E.g., "useFetch wrapper", "DynamicInput JSON Schema forms". Include: what it does, where it's used, gotchas.
- Issue pages (wiki/issues/YYYY-MM-DD-title.md): Known bugs and workarounds. Include: symptom, root cause, fix/workaround, affected files.
- Decision pages (wiki/decisions/YYYY-MM-DD-title.md): Why we chose X over Y. Include: context, decision, alternatives considered, consequences.

Use `[[wiki-links]]` for cross-references between pages.

Update ~/knowledge/index.md and ~/knowledge/log.md (root files only — never inside wiki/).

## Cleanup

After processing all entries:
1. Truncate `~/.second-brain/.pending-reflections.jsonl` (write empty or delete it)
2. Delete processed snapshot files from `~/.second-brain/.reflection-context/`
3. Process all queued entries — never skip reflections, every session may contain important knowledge
