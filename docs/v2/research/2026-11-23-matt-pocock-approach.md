# Matt Pocock's approach against second-brain

**Asked (2026-11-23):** "can you look into matt pocock skills and articles and rethink if our approach in plugin is correct? do
plugin gives guides to claude how to create agents and use structure of plugin and much more?"

Researched by a subagent from the sources listed under Sources, its claims about his views quoted from what it read;
reviewed here against the plugin. Marked *(inference)* where it is not his stated view.

Read: his skills repo (`abeeaf9`), AI Coding Dictionary, four AI Hero articles; no X posts or newsletters. Our paths are relative to `plugin/`.

## A. His approach, in his words

**Where knowledge lives**
- `CLAUDE.md` should be used "incredibly sparingly, usually only for navigation pointers" [retro]. It holds only what is "both **undiscoverable** and **globally relevant**" [init].
- "File paths change constantly." "Instead of documenting structure, describe capabilities." [AGENTS guide]
- ADRs only when "Hard to reverse", "Surprising without context" and "The result of a real trade-off"; glossary and ADRs are created lazily [domain-modeling].
- "memories are secondary sources, so they drift … A memory system needs pruning" [dictionary]. "Write history, not the present" [chief-of-staff].

**Skills and agents**
- "The pointer's _wording_, not its target, decides when the agent reaches the material" [writing-for-agents]. "A bare path is a pointer the agent has no reason to follow" [dictionary].
- Use model-invocation "only when the agent must reach the skill on its own" [SKILL-MECHANICS].
- His plugin ships skills only (`plugin.json` lists no agents); skills spawn subagents "with a fresh context window" [repo CLAUDE.md], which "exist to isolate context, not to compose hierarchies" [dictionary].

**Repo setup**
- "Explore, present what you found, confirm with the user, then write" [setup skill].
- A `CLAUDE.md` rule "_reduces_ the chance … It doesn't _prevent_ it" [hooks].

**Feedback loop**
- `retro` proposes, and the human picks. A mechanical violation "gets a deterministic check, full stop".

Not found: his view on project agents with memory, or on session-start injection.

## B. Agreement and conflict

**Where we agree**
- `templates/CLAUDE.template.md` keeps "Only what Claude cannot learn from the code".
- `templates/claude/rules/project-map.md` keeps a replaced entry, with a dated `- status: superseded … by <id>` line.
- The dream only proposes, `/map-review` settles each proposal with the user, and the commit is the review.
- `templates/claude/agents/decision-checker.md` is a separate reviewer.
- 4i did not ship K2: with no plugin, a fresh session re-found the corrected code in 12 of 12 runs ("Trust the explore step").

**Where we conflict**
1. `scripts/map.mjs` indexes directories as bare filenames, under "IMPORTANT: Prefer retrieval-led reasoning…", and forces a yes/no per directory. (D22 reopened on 2026-11-23.)
2. The entry format is written four times: in `INSTRUCTION` (`scripts/map.mjs`), `templates/claude/rules/project-map.md`, `templates/project-map/README.md` and `skills/dream/SKILL.md`.
3. `templates/claude/agents/codebase-guide.md` notes "what lives where". Private notes; cut tool calls in 4 of 5 runs; dropping wrong notes is instructed, not measured.
4. `INSTRUCTION` has one filter ("Keep what will still matter in later sessions"); his ADR has three tests. A1 needs requirements too, so his bar does not transfer whole.
5. `scripts/setup.mjs` creates `decisions.md` and `dreams.md` up front; he creates domain docs lazily. `skills/setup/SKILL.md` fills in discoverable commands; he keeps non-standard ones only.
6. `skills/dream/SKILL.md` turns a repeated correction into prose, where `retro` turns a mechanical one into a check.

## C. Does the plugin guide Claude on agents, skills and its structure?

**What exists**
- *Structure:* `templates/CLAUDE.template.md` (map, two agents); `INSTRUCTION` (where decisions go, "not in your auto memory"); the scoped rule (format); `templates/project-map/README.md` (lifecycle).
- *Skills and rules, only in `skills/dream/SKILL.md` steps 3 and 4:*
  - a path-specific correction seen in two or more sessions becomes `.claude/rules/*.md.draft`;
  - a repeated procedure becomes `.claude/skills/<name>/SKILL.md.draft`;
  - `templates/claude/skills/map-review/SKILL.md` promotes a draft by renaming it.

**What is missing**
- *Agents:* `scripts/setup.mjs` copies three fixed ones. The dream has no agent-draft kind, and `scripts/dream.mjs` puts back any change under `.claude/agents`. His plugin defines no agents either.
- *Placement:* in a session, everything goes to `.project-map/`; nothing says when it should be a rule, skill, check or `CLAUDE.md` line.
- *How to write a draft:* nothing covers the description as trigger, the invocation choice, no-op pruning, or generalising past the source sessions.

So the plugin teaches Claude to use its structure, not to extend it.

## D. Changes worth considering (smallest first)

1. **A placement line in `templates/project-map/README.md`:** decision: entry; path rule: `.claude/rules`; procedure: skill; mechanical rule: suggest a check. *(inference)*
   - Why: retro's table.
   - Risk: no observed failure yet (his SCOPE bar). D29 is LOCKED.
2. **Draft-writing rules in `skills/dream/SKILL.md` step 4:** description says what and when; `disable-model-invocation: true` unless Claude must reach it; a done-criterion per step; written for the class of task.
   - Why: SKILL-MECHANICS and the writing-for-agents FAQ.
   - Risk: it duplicates his `writing-for-agents`. D31 is LOCKED, and D33 (OPEN) raises the stakes.
3. **The dream reports a mechanical correction as a "for you" check.** *(inference)*
   - Why: retro.
   - Risk: the charter's non-goal "a code reviewer"; a new proposal kind; D31 LOCKED.
4. **A large index lists each directory, not its files.** *(inference)*
   - Why: his Home Repo entry: past a few hundred pointers, point at one file per area (repos there, directories here).
   - Risk: an extra listing call; possible A1 regression. D22 is OPEN.
5. **One home for the entry format.**
   - Why: single source of truth.
   - Risk: D14, D30 LOCKED; `INSTRUCTION` frozen by sha; the "rule loaded" checks need the rule.

## Sources

- https://github.com/mattpocock/skills at `abeeaf9`: `README.md`, `SCOPE.md`, `CLAUDE.md`, `GLOSSARY.md`, `.claude-plugin/plugin.json`, `.agents/`, `.out-of-scope/`, the skills cited plus `grill-with-docs`, `wayfinder`, `handoff`, in-progress skills, `docs/` pages.
- https://github.com/mattpocock/dictionary-of-ai-coding: Memory system, AGENTS.md, Context pointer, Skill, Subagent, Progressive disclosure, Home Repo.
- https://www.aihero.dev/a-complete-guide-to-agents-md (2026-01-18)
- https://www.aihero.dev/never-run-claude-init (2026-02-24)
- https://www.aihero.dev/how-to-use-claude-code-hooks-to-enforce-the-right-cli (2026-02-25)
- https://www.aihero.dev/how-to-make-codebases-ai-agents-love (2026-02-26)
- Ours: `plugin/` at 8f7f9b95dbd7, the charter, `DECISIONS.md`, `README.md`, commit aa1a1006.

## E. Outcome (2026-11-23)

- **The approach holds.** On the parts he writes about, the plugin agrees with him:
  - `CLAUDE.md` stays short;
  - history is kept, not rewritten;
  - proposals are reviewed before they bind;
  - review is a separate agent.

  K2 was dropped for the reason he gives: the next session's own exploration finds what the code shows.
- **The gap the user asked about is real.** The plugin teaches Claude to use its structure, not to extend it.
  - Nothing tells Claude where a new piece of knowledge belongs: a map entry, a path rule, a skill, a check or a
    `CLAUDE.md` line.
  - Nothing tells it how to write a good rule or skill draft.
  - Nothing tells it when a project agent is worth creating. His own plugin ships no agents: its skills spawn
    short-lived subagents to isolate context. So an "agent factory" is not taken.
- **Candidates for the next release,** each registered with a check before any code, smallest first:
  - **P1:** a placement table in the map's README template: decision, path rule, procedure, mechanical rule (a
    check, offered to the user). It reopens D29 (the templates) on the user's word.
  - **P2:** draft-writing rules in the dream skill's step 4: the description says what and when; invocation only when
    Claude must reach the skill itself; one done-criterion per step. This touches D31.
  - **D22's reopened question** (a large index) gains his "point at one file per area" as an option to weigh beside
    a size budget and a summary mode.
  - *Not taken now:* one home for the entry format (D14 and D30 freeze it by hash, and the rule must stay loaded), and
    a "for you" check from the dream (the charter's non-goal of code review).
