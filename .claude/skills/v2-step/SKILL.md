---
name: v2-step
description: Run exactly one step of the second-brain v2 concept phase under docs/v2/01-process.md, then stop.
disable-model-invocation: true
argument-hint: "[optional: the step to run instead of the next one in the map issue]"
---

# One step of the v2 concept phase

Run **one** step, then stop and report. Small steps are the point: each one is doubted before it starts and leaves
everything the next step needs. Step override from the user, if any: $ARGUMENTS

## 1. Orient

Read, do not skim: `docs/v2/00-charter.md`, `docs/v2/01-process.md`, the status table in `docs/v2/DECISIONS.md`, the
map issue (`gh issue list --label wayfinder:map --state open --json number,title,body`), and the last step's gate
(`git log -1 --format=%B`). The step to run is the
override above, otherwise the first unchecked item under **Next steps** in the map issue. Say in three lines: where
the work stands, which step you will run, and what it needs.

## 2. Readiness

Check that every input of the step exists: files, research notes, the decisions it depends on (LOCKED), tools (`gh`
auth, the browser, Gemini). If something is missing, stop and say what. Do not improvise around a missing input.

## 3. Doubt before doing

Answer briefly, in writing, before any work:
- Is this step still needed, or did an earlier result make it moot?
- What is the smallest version of it that still settles the question? What would be over-built?
- Does it touch a LOCKED decision? If so, which reopen trigger fired? None fired: the decision stands.
- What would make this step fail, and how will we notice?

If the doubt changes the step, say so and change it before starting.

## 4. Do the step

- For a decision: write its check (the pass condition) into `DECISIONS.md` **before** running it.
- Save research to `docs/v2/research/YYYY-MM-DD-<topic>.md` as it is found: sources cited, and nothing private (no
  secrets, session ids, absolute local paths, email addresses, transcript quotes). The repo is public.
- Use subagents for broad reading so findings come back as conclusions. Use a second model for contested points:
  Gemini Pro in the browser at `gemini.google.com/u/1/app` (check that the account menu shows the Pro account). Put
  long text on the clipboard with PowerShell `Get-Content -Raw -Encoding UTF8 <file> | Set-Clipboard` and paste with
  Ctrl+V. Gemini cannot open GitHub URLs, so paste the text itself. Its answer is evidence to weigh, not a vote.
- A check that fails: change the option or the approach and retry. After the third failed attempt, stop and go up a
  level (rule 4).

## 5. Step gate

Update `DECISIONS.md` (status, result, attempts). In the map issue (edit its body), tick the step under **Next
steps**, add a line under **Decisions so far** for anything that locked, and add new open questions under **Fog**.
Then commit on branch `v2` with a conventional subject and this body, and push:

```
Produced: <what this step made, with paths>
Doubted: <what was questioned and how it was settled; what was cut as over-built>
Next needs: <what the next step needs; in place or not>
```

## 6. Stop

Report to the user in at most ten lines: the result, the doubt that mattered, and the next step. Do not start the
next step.
