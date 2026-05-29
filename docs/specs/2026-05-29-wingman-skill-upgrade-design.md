# Design: persona wingman upgrade + skill graph-awareness (Tier 1)

**Date:** 2026-05-29
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Target release:** 0.22.0 (additive; wingman behavior activates next session, lint-guard dormant until graph migration)
**Roadmap:** Tier-1 of the CC-feature roadmap follow-up; the "persona as ai-to-ai / ai-to-human wingman" the user originally requested.

## Summary

Three focused changes turn the persona skill into an **earned-interrupt wingman** and make two
skills aware of the relational graph that shipped in 0.22.0:

1. **`using-second-brain`** (the persona/wingman skill, loaded every session) gains an
   **earned-interrupt** behavior: before *acting on* a named entity, do a one-shot
   `knowledge_neighbors` check and speak up ONLY when the typed graph carries a costly-to-miss
   edge — plus a **native-memory cross-check** that flags when Claude Code's built-in
   auto-memory contradicts the second-brain graph/wiki.
2. **`query`** gains relational recall — `knowledge_neighbors` for "what depends on X / what
   breaks if I change X" questions.
3. **`lint`** gains a guard so it never flags `[[links]]` inside the graph projector's generated
   `## Dependencies` block — preventing a tool-war between lint and the projector.

This is deliberately small (three skill edits, one real code change in the lint awk) and frames
the wingman as *refining* the skill's existing "silence is the default" rule, never overriding it.

## Background (verified)

- The wingman skill's line 34 already says: *"Silence is the default… proactive AI in coding
  contexts is perceived as annoying — engage only when expected value clearly exceeds the
  flow-disruption cost."* The earned-interrupt OPERATIONALIZES that escape clause; it is not a
  new philosophy. A `requires`/`affects` edge you're about to break IS the "expected value
  exceeds cost" case.
- Native auto-memory is already injected into context at session start (the `MEMORY.md` the
  harness loads). The cross-check needs **no new tool** — Claude already sees both memory
  layers; the wingman just has to notice contradiction.
- `lint` Check 2 (dead links) already strips fenced code blocks via an `in_fence` awk toggle
  (skills/lint/SKILL.md:53-54, 93-94). The graph-guard is a parallel `in_graph` toggle —
  same mawk-safe compound-identifier pattern the repo already requires.
- The projector's generated region is delimited by exact constants
  `<!-- graph:begin (generated from ~/knowledge/graph/edges.jsonl — do not hand-edit) -->`
  and `<!-- graph:end -->` (mcp/src/tools/graph-project.ts:8-9).
- Graph is NOT migrated on the dev box (`~/knowledge/graph/edges.jsonl` absent), so the
  lint-guard is **preventive** — it bites the moment the user runs `graph-migrate.sh`.

## Goals

- Wingman speaks up before a costly mistake, stays silent otherwise (proactivity gated on a
  real graph signal, not chattiness).
- Native vs second-brain memory contradictions are surfaced, not silently resolved.
- `query` answers relational ("depends on / blast radius") questions.
- `lint` and the projector never fight over the generated block.
- No new MCP tool; no new dependency; additive; reversible.

## Non-goals (YAGNI)

- **No episodic auto-search in the earned-interrupt.** Considered (graph+episodic); rejected —
  the "smells like prior work" trigger is too fuzzy to gate deterministically. The existing
  hard-rule + `/second-brain:recall` already cover episodic pull.
- **No new tool for the native cross-check.** Native memory is already in context.
- **No change to the silence-by-default rule.** The wingman refines it, doesn't replace it.
- **No auto-resolution of memory conflicts.** Flag once; the user decides (consistent with #1's
  offer-don't-force posture).
- **No lint behavior change beyond the generated-block skip.**

## 1. `using-second-brain` — earned-interrupt wingman

Add a section after the existing numbered list, BEFORE "Engagement gate". Two clearly-bounded
triggers, both one-shot and gated:

### Earned interrupt (graph)
- **When:** you are about to *act on* (edit / refactor / delete / rename) a named entity that
  resolves to a wiki or graph node — not merely discuss it.
- **Do:** one `knowledge_neighbors(slug, direction:'both')` call.
- **Surface ONLY if** the result contains a `requires` / `affects` / `part_of` edge you would be
  breaking, or a `supersedes` / invalidated edge warning against reintroducing a retired thing.
  One heads-up line (deps + blast radius + any "don't reintroduce X"), then proceed silently.
- **Silent if** the graph is empty, absent, or returns nothing relevant — preserves line 34
  verbatim.

### Native-memory cross-check
- Native auto-memory (`MEMORY.md`) is already in your context at session start.
- If a fact in native memory **contradicts** the second-brain graph/wiki on something load-bearing
  to the current action, flag the conflict ONCE — don't silently pick a side. State which is the
  structured source of truth (the second-brain) vs the flat scratchpad (native).
- This matters only while both memory systems run; once native is disabled (the #1 offer) it is
  inert. No new tool — you already see both.

**Framing line** (so it can't drift into over-proactivity): "This refines silence-by-default; it
does not replace it. No graph signal → no interrupt."

**Frontmatter:** add `mcp__knowledge-base__knowledge_neighbors` to `allowed-tools`.

## 2. `query` — relational recall

Add a step: when the question is relational ("what depends on X", "what does X require", "what
breaks if I change X", "blast radius of X"), call `knowledge_neighbors(slug, direction)` alongside
`knowledge_search`, and synthesize from both. Keep the existing BM25 flow for topical questions.
**Frontmatter:** add `mcp__knowledge-base__knowledge_neighbors` to `allowed-tools`.

## 3. `lint` — projector generated-block guard

In the two dead-link awk extractors (Check 1 orphan detection and Check 2 dead links), add an
`in_graph` toggle alongside the existing `in_fence` one:

```awk
/<!-- graph:begin/ { in_graph = 1; next }
/<!-- graph:end/   { in_graph = 0; next }
in_graph { next }
/^[[:space:]]*```/  { in_fence = !in_fence; next }
in_fence { next }
```

(Compound identifier `in_graph` — `in` alone is reserved in awk; the repo already enforces this,
see test-lint-skill.sh.) Both dead-link extractors run this — Check 1 (orphan detection, builds
the inbound-link SET) and Check 2 (dead-link detection). Effect: `[[links]]` inside the
projector's `## Dependencies` block (including `Superseded:` links to retired/archived slugs)
are never reported as dead.

**Deliberate semantic for Check 1 (orphans):** because generated links are excluded from the
inbound-link set, a page linked ONLY from generated `## Dependencies` blocks now counts as an
orphan. This is correct, not a regression: generated links are a projection of the edge log, not
an authored reference — they should not rescue a page from orphan status (the projector would
just regenerate them next reindex). Orphan-ness must reflect AUTHORED references. The spec calls
this out so it isn't mistaken for a bug later.

**Why this is complete, not a band-aid:** dead edges don't go undetected — the projector writes
neighbours into `related:` frontmatter, and `knowledge_validate` already checks `related:` for
broken links. Detection moves to the layer that owns graph integrity; lint stops fighting the
projector over generated prose. Add a one-line Note in the skill explaining the skip.

## Error handling

- `knowledge_neighbors` unavailable / graph absent → wingman stays silent (no interrupt), `query`
  falls back to `knowledge_search` only. Both already degrade this way.
- lint `in_graph` guard with a malformed/half-open marker → the toggle simply stays in its last
  state to end-of-file; worst case a trailing region is skipped (under-reports, never false-flags
  — the safe direction).

## Testing

Per [[validate-the-real-capability]], test what can be tested for real; be explicit about what
can't:

- **lint (real test):** extend `tests/test-lint-skill.sh`:
  1. A fixture page with `[[ghost-slug]]` INSIDE a `graph:begin/end` block → dead-link extractor
     must NOT surface `ghost-slug`.
  2. A `[[ghost-slug]]` OUTSIDE the block (real body) → still IS surfaced (guard didn't over-skip).
  3. Orphan-set semantic: a page whose ONLY inbound `[[link]]` sits inside a generated graph block
     is treated as an orphan (generated links don't count as authored references).
  4. The existing awk-parse-clean + RED-on-injection + Cross-references-extractor cases still pass
     (the new toggle is mawk-safe).
- **query / using-second-brain (prompt-only):** `claude plugin validate --strict` confirms
  frontmatter + allowed-tools parse; no false executable test for prose behavior.
- **Explicitly not unit-testable:** the earned-interrupt and native cross-check are behavioral
  instructions to a prompt — verified by review reading, not a deterministic test. The spec states
  this openly rather than fabricating a green check.

## File-change inventory

**Modified:**
- `skills/using-second-brain/SKILL.md` — earned-interrupt + native cross-check sections; add
  `knowledge_neighbors` to allowed-tools.
- `skills/query/SKILL.md` — relational-recall step; add `knowledge_neighbors` to allowed-tools.
- `skills/lint/SKILL.md` — `in_graph` toggle in both dead-link awk blocks + a Note.
- `tests/test-lint-skill.sh` — graph-block skip cases (real + negative).

## Rollout

Additive — no migration. Ships in 0.22.0. The wingman behavior activates next session; the
lint-guard is dormant until the user migrates the graph (`graph-migrate.sh`), then correct.
Gated by the full test suite + an adversarial review before merge (the prior two features each had
a real bug caught at that gate).
