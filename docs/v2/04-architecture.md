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
| `.project-map/.cache/` (gitignored) | the index, rebuilt from git's file list | the plugin | D15, D18 |

## Hooks

Node 20, exec form, one script per event, at most 100 ms of added p95 at 8 concurrent sessions (V2-D18). `SessionStart`
runs in shell form once and says when Node is missing.

| Event | What it does | Bytes | Reaches (D12) | Outcome served |
| --- | --- | --- | --- | --- |
| `SessionStart`, `startup` and `compact` | the capture instruction; the document index (Vercel's retrieval-led line, then the documents by directory) | 904 B + 2 to 6 KB measured | the main session; re-emitted after `/compact` | Capture; Consistency |
| `UserPromptSubmit`, the session's first prompt and the first after each compaction | the forced decision: per index directory yes or no, then read the yes ones before changing anything | 227 B | the main session | Consistency |
| `PostToolUse` after a Read of a `.project-map/` file | labels the file's uncommitted entries "unreviewed, not yet committed" (D14); runs D16's re-find on its entries' anchors and labels changed or gone ones | per read | the main session (D22 run 2: 3 of 3) | Freshness; trust (PM5) |
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
- **Untested shapes.** Investigation tasks, a vague first prompt, several compactions, and an index past 45
  directories. These are D22's triggers.
- **Subagents** do not see the index, since `SessionStart` reaches only the main session (D12).
- **Stale documents.** Claude reads the project's documents as they are. A stale document that contradicts a binding
  rule is not flagged: the volume check found 10 such entries in P2. D16 labels captured entries only.
- **The index build at session start** (from git's file list) is unmeasured. The 16 to 45 ms measured so far delivered
  a precomputed file. It is the first D18 measurement in the slice.
- **Friction.** A forced decision at the session's first prompt and after each compaction. A new task in the same
  session gets none, which is untested. Both are measured in the first slice.
- **Pattern rules on Opus.** P1 R2 was missed under every pull arm and under a self-review; only a hand-written check
  fed back held it. It is an expected miss until D20's net reopens. P2 R4, a judgment rule, was missed by push and
  pull alike once the session compacted.

## Not v2

Everything in the charter's non-goals. Also: no inventory of the code (V2-D21), no conversion of documents (V2-D15),
no selector, and no rule text pushed for a document's rules (V2-D22).
