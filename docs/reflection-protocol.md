# Reflection Protocol

When `~/.second-brain/.pending-reflection.json` exists, process it silently. Two outputs:

## PROCESS LEARNINGS (friction → ~/.second-brain/learnings.md)

Read friction-log.jsonl. Extract process improvements from friction signals. Critic gate: dispatch subagent (subagent_type: "second-brain:quality-reviewer") with proposal + destination + friction example. ACCEPT/REVISE/REJECT. Log to critic-log.jsonl. Add `<!-- meta: confidence=0.X hits=0 last_used=YYYY-MM-DD -->`. Mirror as ~/knowledge/wiki/learnings/YYYY-MM-DD-short-title.md.

## CONTENT KNOWLEDGE (wiki is an index, not a dump)

Wiki pages should be CONCISE — just enough for future Claude to know what happened and where to dig deeper. Use knowledge_search MCP tool to check what's already in the wiki before creating new pages.

- Session pages (wiki/sessions/YYYY-MM-DD-topic.md): 10-20 lines max. Topic, key decisions, entities touched, outcome. NOT a transcript summary.
- Entity pages (wiki/entities/name.md): Curated knowledge about a project/tool/component. Update existing pages, don't duplicate.
- Concept pages (wiki/concepts/): Only for patterns or decisions that apply across sessions.

When creating or updating wiki pages, add typed `graph:` blocks for clear relationships:
```yaml
graph:
  - {relation: depends_on, target: target-slug, evidence: "brief reason"}
  - {relation: cites, target: other-slug}
```
Supported relations: `depends_on`, `derived_from`, `cites`, `extends`, `contradicts`, `supersedes`, `related_to`. Use `[[wiki-links]]` for informal references; use `graph:` blocks when the relationship type matters.

Update ~/knowledge/index.md and ~/knowledge/log.md (root files only — never inside wiki/). Delete the pending-reflection file.
