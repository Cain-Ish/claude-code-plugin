# Team memory

This folder is the project's memory, for Claude and for people. It holds the decisions, rules and requirements that
the code does not show. It is plain Markdown, reviewed like code: an entry counts as reviewed once it is committed.

- **One topic file per area,** such as `avatars.md` or `components.md`. Each starts with front matter: `name`, and a
  `description` of what it covers and when to read it. `decisions.md` holds what fits no other area.
- **`dreams.md`** logs each dream: a run of `/second-brain:dream` that reads past sessions and proposes entries.

## Where it belongs

Not all that Claude learns is an entry. Before adding one, find its home here. Claude only offers the other homes;
the user decides, since a new rule or skill loads at once.

| What it is | Where it goes |
| --- | --- |
| A decision, rule or requirement for this project | an entry here |
| A procedure repeated across sessions | an entry here; offer the user a skill in `.claude/skills/` |
| A rule for certain paths that keeps being corrected | an entry here; offer the user a path rule in `.claude/rules/` |
| A task that needs its own context, tools or notes | an entry here; offer the user an agent in `.claude/agents/` |
| A rule a tool can enforce: a format, an import, a forbidden call | an entry here; offer the user a check (a lint rule, a test or a hook), since an instruction lowers the odds of a mistake and a check prevents it |
| A command every session needs and cannot find, such as how to run the tests | a line in `CLAUDE.md` |
| Where code lives, or what the code already shows | nowhere in the map: it changes, and Claude finds it |

`/second-brain:tailor` makes a skill, agent or path rule as a draft, with the cases that test it. A dream proposes
entries and status lines, and drafts of path rules, skills, agents and changes to the repo's own, from what two or
more sessions show. In its digests, `[private]` stands for text removed as private, which no proposal quotes.

## Session start

- **`index.ignore`** in this folder leaves folders out of the document index: one folder or glob pattern per line,
  from the repo's root, such as `docs/archive` or `**/fixtures`; `#` starts a comment. This folder is always listed.
  When git rejects a line, the file is not used that session, and you are told.
- **Claude starts the plugin's skills** when they fit: a dream when one is due, status, setup and tailor. Each asks
  your permission the first time. To allow them in advance, add rules such as `Skill(second-brain:dream)` to
  `permissions.allow` in `.claude/settings.json`.

## An entry

```
  ### <the part of the project it governs>
  > <the decision, rule or requirement, in the words used>

  - id: <a short unique slug>
  - source: <who stated it, or the document>, <YYYY-MM-DD>
  - when: ["<kind of work it applies to>"]
  - verified: <YYYY-MM-DD> <how you know it holds>
```

## Its life

- **Captured in a session:** it shows in the working-tree diff until someone commits it.
- **Proposed by a dream:** it carries `- proposed: dream <date>` until `/map-review` accepts it, which turns that line
  into `- origin: dream <date>`.
- **Time-bound:** it carries `- review: <date>`. Once the date passes, `/map-review` asks whether it still holds.
- **Replaced, narrowed, expired or done:** it keeps its place, with
  `- status: <kind> <date> by <the new entry's id>: <what still holds>`.
- **Its history** is git's: `git log -p -- .project-map/`.
