# Second opinion on the release question (2026-11-06)

**What ran:** Gemini 4 Argon, through the Antigravity CLI in plan mode (rule 10), in an empty folder holding only the
brief.
- *The brief* was 46 KB of public text from branch `v2`:
  - the README;
  - DECISIONS.md from V2-D24 to the end (D24, D25, D26, D27);
  - 06 from "2k, check 5" to the end (the field check, then build step 2l).
- *It asked four questions:* which D24 option, what is missing for a stable `2.0.0`, failure modes for a v1 user that
  D25 to D27 do not cover, and README lines that a new user would misread.
- *It ran on* commit `20c50ed` (plugin `d21b69bfc1ed`, `2.0.0-alpha.6`). Its answer is evidence to weigh, not a vote.
- *Not run:* the devils-advocate workflow (rule 8). It is multi-agent, and the last release review ran it on the
  user's go. It waits for that go.

## Its answer, in short

- **D24:** (b), tightened. `main` should not move until the current CLI passes a field bar with at least one in-claim
  epoch, and 2l's bench and CI are done.
  - *What would move it to (a):* a README claim narrowed to capture and quote checks, or A1 and P1 build re-run on
    the current CLI.
  - *What would move it to (c), or reopen D22:* in-claim field sessions where more than half of the writes still
    bypass the forced decision, or the read-through stays near zero.
- **Ranked gaps:**
  1. no in-claim epoch in the field;
  2. alpha.6's gates not finished;
  3. no live session on macOS or Linux;
  4. eval drift from CLI 2.1.305 to 2.1.319;
  5. the labels' size in Bash workflows;
  6. the scanners' blind spots.

## Dispositions

Rule 8: each point fires a named reopen trigger, is fixed, or is recorded as an accepted risk. Nothing re-argues a lock
without a trigger.

| Point | Fires | Disposition |
| --- | --- | --- |
| D24: (b), with an in-claim epoch from the field | none: D24 is open and the user's | **Recorded for the user** with D24. It agrees with the recommendation already put to them |
| No in-claim epoch in the field | none | **Recorded:** it is D24's question. The field repo has new sessions on CLI 2.1.319 since check 5. They are not counted until D24 sets the bar |
| alpha.6's gates not finished | none | **Done in part:** CI on `4d201a2` passed on three systems. At one session, session start adds 78.3, 42.7 and 25.2 ms p95 on Windows, macOS and Linux; alpha.5 on `648144d` added 71.7, 45.5 and 27.8. The reference bench is registered and waits for a quiet machine. The interactive screen waits for the user's first session |
| No live session on macOS or Linux | none | **Accepted risk,** stated in the README's status. A live check needs a person on those systems, or CI holding credentials |
| Eval drift, 2.1.305 to 2.1.319 | none | **Recorded:** D24 lists it under "not checked". A1 and P1 build on the current CLI run only on the user's ask |
| The labels' size in Bash workflows | none | **Recorded:** it is asked with D24; the README's known issues state it |
| The scanners' blind spots (C9 one level deep) | none | **No action:** fixed in 18b (`d8ff1b4`). The brief quoted check 5's text, written before the fix |
| D25: v1's timer keeps using the API key for 14 days | none | **Fixed in the README:** "Coming from v1" says v1's old copy can still use the key until the timer is removed, and that v2's no-network claim covers v2's hooks only. D27's line is the reach |
| D26: a hand edit of `settings.json` with shell quoting | none (D26's triggers need a failed cleanup) | **Fixed in the README:** copy the command as it appears in the file, so its JSON escapes stay, and write `'` for `'\''`. Otherwise an **accepted risk**: the edit is in words, as D26 states |
| D27: after `rm -rf ~/.second-brain`, the line stops while the scheduler entry and `statusLine` stay | none | **Accepted risk:** the shims the leftovers would run are gone. What a missing shim shows in the statusline, and what the scheduler then logs, was not checked |
| D27: a `BRAIN_DIR` that is not in the hook's environment | none | **Accepted risk:** a custom folder is rare, and the README tells such users to use their folder |
| README: the opening paragraph reads as covering every change | none | **Fixed:** a known issue states that only the first prompt of a session or after a compaction gets the forced decision, with the 45 writes of check 5 |
| README: "Nothing leaves your machine" for an upgrader | none | **Fixed** with the D25 line above |
| README: quote checks read as tamper-proof | none | **No action:** the next sentence states the limit |
| README: Install still names `second-brain-v2` | none | **No action now:** it installs the published alpha. The release commit renames the marketplace (D25) and moves Install (map issue, 18g) |

## A correction made while writing the fix

- The first draft of the new known issue said that none of the 45 writes came in a turn the forced decision covered.
  That is wrong: 7 came in the two forced turns (06, check 5).
- The issue now says none came in reply to a first prompt that asked for the change.
- Gemini's "21 occurred on the prompt after an initial question" matches 06: 1 in the question's turn, 21 in the next
  prompt.
