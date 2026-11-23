---
paths:
  - ".project-map/**"
---
# Writing the team memory

Each decision is one entry in the topic file for its area, in the words used:

```
### <the part of the project it governs>
> <the decision, rule or requirement, in the words used>

- id: <a short unique slug>
- source: <who stated it, or the document>, <YYYY-MM-DD>
- when: ["<kind of work it applies to>"]
- verified: <YYYY-MM-DD> <how you know it holds>
```

- A decision that replaces, narrows or ends an older one: keep the older entry and add to it
  `- status: <superseded|narrowed|expired|done> <YYYY-MM-DD> by <the new entry's id>: <what still holds>`.
- An entry that carries `- proposed: dream <date>` is a dream's proposal. It binds once review accepts it
  (`/map-review`); until then, treat it as unreviewed. Review turns that line into `- origin: dream <date>`.
- A decision that holds until a known date gets `- review: <YYYY-MM-DD>`.
- Entries hold words and repo paths only: session ids, email addresses and absolute paths stay out.
