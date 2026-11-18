# The field checkup of 2026-11-18: the rethink, item by item

**Sources:**
- the checkup the first field repo's session sent on 2026-11-18;
- 06's 2q, which carries B1 and G6, released as `2.0.2`;
- D16, D22, D23, D24 and D28 in [DECISIONS.md](../DECISIONS.md);
- the user's instruction of the same day, after 2q: "add all reported improves - rethink reports, verify them, plan
  steps and implement, then verify end results and PR with merge. I give you free hand".

**How the instruction is read.** It delegates the items to a rethink, as on 2026-11-03 (D23's rethink 2). It does not
choose an option. Each item below gets a rule written before its evidence is read. A rule may keep a frozen text. A
locked decision that changes is recorded as "reopened by the user's delegation of 2026-11-18", with the item's
evidence.

**Registered 2026-11-18, before the delegated counts (G4, G5) report.** A subagent reads the field transcripts and
auto memory, since that text is private and stays local. Its counts are spot-checked by hand: three naming lists
re-read, and two memory files.

## Items already settled

| Item | What | Where |
| --- | --- | --- |
| B1 | A file named inside a source's parentheses taken as its source | `2.0.2`, 06 2q |
| G6 | Onboarding silent on map files that are not committed | `2.0.2` |
| G2 | Label noise | `2.0.1` (on that map, one Read goes from 6,778 characters to 688 on `2.0.2`) |

## G1: entries that have stopped binding (V2-D28)

- *Verified:* the field map holds 10 `- status:` lines. 9 start with a kind (superseded 2, narrowed 2, and one each of
  expired, answered, done, refined and used), and 1 is free text. The plugin ignores them.
- *Route, in two steps,* so that each check can fail on its own:
  1. **2r, (L) alone:** `labels()` reads the status line. This is D28's (L) check as registered: session start and
     the prompt hook stay byte-identical, and no frozen text changes. Added before the code:
     - *the unsafe side:* a status line that HEAD does not hold must not end a committed entry. The entry keeps
       "unreviewed", and a self-test case covers it;
     - *wording:* "narrowed" entries still bind in part. So the label shows the status line's own head, such as
       `status: narrowed 2026-11-18 …`, and never says "ended";
     - *the cap:* a differential fuzz against `2.0.2` near the 10,000-character cap.
  2. **2s, the texts:** (I), the capture instruction's sentence asking for a status line, and (N), the naming line's
     clause on status lines. Both are checked under A1 with a control arm (below).

## B2: the capture date not at the end of the source line

- *Verified:* 41 of 67 field entries put text after the date. 2q's parser attempts failed, because free text cannot
  tell a capture date from a topic date.
- *Route:* the capture instruction asks for the date last, with any context in parentheses before it. That is an
  additive sentence in 2s. The source slot's "title or path" stays as it is: A1's designer document has no repo path,
  and C2 is where v2 beat native, 10 against 2.
- *Rule:* adopted only if, in 2s's scenario, the new text ends the source line with the date clearly more often than
  the `2.0.2` control, and A1 does not regress. The scenario takes the field's shape, in which the owner answers a
  question Claude asked.
- *Old entries:* the field session migrates its own entries after the text locks, not before.

## G4: decisions kept in auto memory and not in the map

- *To verify (delegated count):* the field's auto-memory files, classed as a project decision or rule (P), a working
  habit (H) or other (R). For each P: is it in the map, and does it agree?
- *Rule, registered now:*
  - 2 or more P files absent from the map, or in conflict with it: a sentence goes into 2s ("decisions and rules for
    this project go in this map; your auto memory is for your own way of working"). Its effect is direction, not
    measured by A1, and A1 checks only that capture does not regress.
  - Fewer than 2: recorded only.

## G5: the naming line at every finish (D23)

- *To verify (delegated count),* by D23's registered definitions. A finishing reply is the last assistant text of a
  turn. Each named decision is "applied" when it shaped the turn's work, and "restated" otherwise.
- *Rule, registered now* (D23's own field trigger):
  - Restated decisions above 20% of those named, in a count of at least 20 naming lists: D23 reopens on its own
    trigger, and its record names (d), session-scoped naming, as the next attempt. (d) is then built in 2s and must
    pass D23's check: A1's V2 arm, T5f in at least 8 of 10, every other pass item at its bar, over-attribution in at
    most 1 of 10.
  - At most 20%, or fewer than 20 lists: D23's (a) stays, and G5 is recorded with the count. This is the 2026-11-03
    precedent: the delegation does not override a count that keeps the line.
- D28's clause for the naming line, "not one whose status line ends it", is separate from G5 and is judged under
  D28.

## G3: "read every document in a yes directory" in a large directory (D22)

- *The record decides it.* D22's scope probe (map issue, step 17f5) failed. The documents' names and listing did not
  tell which bound a write ("R5's document never names its language"), and 38 to 145 documents were listed at every
  gated write.
- A forced read "of those whose names bear on the task" is that refuted route. A1's small folders cannot test it. The
  check that could is P2's cell against a `2.0.2` control, and it is not run in this step.
- **The forced decision stays frozen.** G3 is recorded as a D22 field observation, beside 2026-10-29's "0 of 3 epochs
  read every yes directory". Reopen if: a P2-cell check with a control is run on a candidate text.

## The field scanner's path rule (count 5)

- `field.mjs`'s `CITES` matches a path anywhere in a source: B1's class.
- 06 records that count 5's "not a defect" rested on B1. The user approved the report that raised it without singling
  it out. It is recorded as a C5 miss caused by B1, which `2.0.2` fixes, and D24 is not reopened: `2.0.0` is
  superseded.
- *The probe change,* registered in the field README before the code: `CITES` leaves out a path inside parentheses
  that pair. *Pass:* on counts 4 and 5's frozen corpora, the only changes are entries whose source names a file only
  inside such parentheses.

## Results

(Filled in as each item's evidence comes in.)
