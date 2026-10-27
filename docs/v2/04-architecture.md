# v2 architecture

**Status:** built only from locked decisions ([DECISIONS.md](DECISIONS.md), 2026-10-22). D20's write-time net is
DEFERRED with a trigger, so it is not part of this. One page by design (charter, definition of done item 3).

## What runs

A Claude Code plugin with no agents, no MCP server and no model call in a hook (V2-D18). The repo's own documents stay
the source of its knowledge. Claude sees an index of them, is made to decide which bear on its task, and reads those
itself (V2-D22). What a session decides, and no document holds, Claude writes into plain files in the repo, which the
index lists too (V2-D14, D13). Everything a person needs is readable and correctable with the plugin off (PM4).

## Files in a repo

| Path | What | Who writes it | Decision |
| --- | --- | --- | --- |
| the repo's documents (`.md`, `.mdx`, `.markdown`, `.txt`, `.rst`) | the project's own rules and knowledge | the project's people | D15, D22 |
| `.project-map/*.md` | entries captured from work: the statement, its source (a document anchor or the session's date), its area, when it applies, `verified` | Claude, under the capture instruction; committed with the work | D11, D13, D14, D16 |
| no cache (build step 2a) | the index is built at each session start from git's file list plus the untracked files under `.project-map/`, so an entry captured and not yet committed is listed. One git call (since D16's re-lock of 2026-10-26): 60 to 82 ms added p95 at 8 concurrent on P2 (190 documents, 6.1 KB) in three runs, under D18's 100 ms. With two calls it measured 87 ms in 2a and 106 to 112 ms on 2026-10-26 | the plugin | D15, D18 |

## Hooks

Node 20, exec form, one script per event, at most 100 ms of added p95 at 1 session on every tested machine, and at 8 concurrent sessions on the reference machine (V2-D18, re-locked 2026-10-27). `SessionStart`
runs in shell form once and says when Node is missing. Every hook takes the git toplevel (the nearest folder holding
`.git`) as the repo's root, so a session started in a subdirectory sees the whole index (D18, 2026-10-27).

| Event | What it does | Bytes | Reaches (D12) | Outcome served |
| --- | --- | --- | --- | --- |
| `SessionStart`: `startup`, `clear`, `resume` and `compact` (all four probed: D12, build step 0) | the capture instruction; the document index (Vercel's retrieval-led line, then the documents by directory). Past Claude Code's documented 10,000-character cap for one hook output, the index is cut at a directory with a line saying so (D22's guard; the live cliff on 2.1.311 sat between about 12,400 and 16,300 characters) | 904 B + 2 to 6 KB measured | the main session; re-emitted after `/compact` | Capture; Consistency |
| `UserPromptSubmit`, the session's first prompt and the first after each compaction (state keyed by the session id) | the forced decision: per index directory yes or no, then read the yes ones before changing anything | 227 B | the main session | Consistency |
| `PostToolUse` after a Read of a `.project-map/` file | labels the file's uncommitted entries "unreviewed, not yet committed" (D14). An entry whose source names a repo file is re-found in it now: found, no label; not found, "not found word for word in <path>; check it, captured <date>". Any other entry: "unverified quote, captured <date>" (D16, re-locked 2026-10-25). A source that cannot be read: "cannot read <path>; check it". Any other failure: one fail-closed label for the whole file. A leading byte-order mark is ignored (D18, 2026-10-27) | per read; 83 to 86 ms p95 at 8 concurrent with 30 re-finds of P2's 30 largest documents (1.26 MB; D16, re-locked 2026-10-26). The cost grows with the bytes the sources hold | the main session (D22 run 2: 3 of 3). Subagent reads, Grep and Bash are unlabelled until probed | Freshness; trust (PM5) |
| `PostToolUse` after a Write or Edit, and `Stop` | **Not built: D20's net is DEFERRED.** The fed-back check works when it is right, but no tested source writes such checks | | | |

Not used: `PreToolUse` (D18), `SubagentStart` (deferred: subagents do not see the index), MCP, agents.

## Commands

One: onboarding (V2-D15). It builds the index from git's file list, with no model and no cost per MB, and checks that
Node and git are present. A repo with no documents gets an empty index and an empty map (V2-D21).

## Budgets (PM8)

- Always on, per session: 904 B plus the index (2 KB in P1, 6 KB in P2), plus 227 B per forced decision.
- Hooks: added p95 at most 100 ms at 8 concurrent, on Windows (V2-D18).
- Surface: 3 hook events, 1 command, 0 agents, 0 MCP servers, 0 skills.

## Known weaknesses, each with its trigger

- **Cost.** In the document-heavy repo, the route spent about three times push's tokens, mostly in subagent
  research. It reopens D22 if the first slice's eval puts v2 above M1's no-worse ceiling.
- **A change named after the epoch's first prompt** (measured in 2e; outside the claim since D22's re-lock of
  2026-10-26).
  - *A vague first prompt:* on P2, R5 was missed in 4 of 5 runs.
  - *A task switch after a compaction:* R5 was missed in 3 of 5.

  The forced decision selects by the first prompt it sees. Bringing these cases back into scope reopens D22.
- **Untested shapes.** Investigation tasks (outside the claim), and an index past 86 directories (R0, v1's repo, in
  2d and 2e) or past 6.1 KB (P2). These are D22's triggers. A cut index (past the hook cap) has had no forced
  decision measured on it.
- **Letter case** in the map folder is folded by operating system (win32 and darwin), not by the file system, so a
  case-sensitive macOS volume or a case-insensitive Linux mount can list a renamed file wrongly. Reading
  `core.ignorecase` would cost a git spawn at every session start.
- **Subagents** do not see the index, since `SessionStart` reaches only the main session (D12). The read hook does not
  reach a subagent (D12, build step 0: 0 and 1 of 3), so a map file a subagent reads, or one met by Grep or Bash,
  arrives unlabelled. That is an accepted risk.
- **An automatic compaction inside a turn** is followed by writes before the next prompt, so the re-forced decision
  comes too late. That is a D22 trigger, with the forced text in `SessionStart`'s compact output as the untested
  candidate fix.
- **Capture may copy repo rules** into the map, since the instruction says to keep rules from any document read. This
  is D14's accepted risk, watched by its noise trigger.
- **Stale documents.** Claude reads the project's documents as they are. A stale document that contradicts a binding
  rule is not flagged: the volume check found 10 such entries in P2. D16 labels captured entries only.
- **The index build at session start** (from git's file list, no cache) adds 60 to 82 ms p95 at 8 concurrent on P2
  in three runs, with one git call since 2026-10-26. With two calls it measured 87 to 112 ms. A repo with a much
  larger file list may pass D18's 100 ms; a cache is the fallback (build step 2a).
- **Small machines with many sessions.** On a 4-core runner at 8 concurrent, session start and a map read add 143 to
  260 ms p95, against at most 100 ms at 1 session there and at 8 concurrent on the reference machine (D18's two-part
  budget, by the user's choice).
- **Friction.** A forced decision at the session's first prompt and after each compaction. A new task in the same
  session gets none until the next compaction (2e's task switch, above).
- **Pattern rules on Opus.** P1 R2 was missed under every pull arm and under a self-review; only a hand-written check
  fed back held it. It is an expected miss until D20's net reopens. P2 R4, a judgment rule, was missed by push and
  pull alike once the session compacted.

## Not v2

Everything in the charter's non-goals. Also: no inventory of the code (V2-D21), no conversion of documents (V2-D15),
no selector, and no rule text pushed for a document's rules (V2-D22).
