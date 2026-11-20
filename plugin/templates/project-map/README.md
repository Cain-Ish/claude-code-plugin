# Team memory

This folder is the project's memory, for Claude and for people. It holds the decisions, rules and requirements that
the code does not show. It is plain Markdown, reviewed like code: an entry counts as reviewed once it is committed.

- **One topic file per area,** such as `avatars.md` or `components.md`. Each starts with front matter: `name`, and a
  `description` of what it covers and when to read it. `decisions.md` holds what fits no other area.
- **`dreams.md`** logs each dream: a run of `/second-brain:dream` that reads past sessions and proposes entries.

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
- **Proposed by a dream:** it carries `- proposed: dream <date>` until `/map-review` accepts it.
- **Time-bound:** it carries `- review: <date>`. Once the date passes, `/map-review` asks whether it still holds.
- **Replaced, narrowed, expired or done:** it keeps its place, with
  `- status: <kind> <date> by <the new entry's id>: <what still holds>`.
- **Its history** is git's: `git log -p -- .project-map/`.
