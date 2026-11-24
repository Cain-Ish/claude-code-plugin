# V2-D34 probes: testing a draft in place, and use in the field (2026-11-24)

These three probes come before 06, section 7, step 7a. Claude Code 2.1.331, on Windows. Each nested run had Claude
Code's nesting variables removed.

## Probe 1: what can test a draft agent or skill in place

**Setup:**
- A scratch git repo held one file, `src/math.js`, which exports `add`.
- A throwaway plugin folder held one skill, `change-entry`. It says to write `changes/<date>-<slug>.md` with
  `kind:` front matter.
- An agents file held one agent, `api-auditor`, described as "Use proactively when the user asks what this library
  exports".

**Two runs:**
- **The skill:** `claude -p "Please log that we added the add() helper." --plugin-dir <folder>`.
  - The init stream listed `drafttest:change-entry`.
  - Claude called `Skill` with `drafttest:change-entry`, then wrote `changes/2026-11-24-add-helper.md` with
    `kind: added`.
- **The agent:** `claude -p "What does this library export?" --agents <file>`.
  - The init stream listed `api-auditor`.
  - Claude answered from its own Glob and Read calls and never delegated.

**Reading:**
- A nested session can load a draft and use it from plain words, so a draft can be tested without making it live.
- Whether an agent gets delegated to at all is a bar of its own.

## Probe 2: use in the field

[`usage.mjs`](usage.mjs) reads Claude Code's local transcripts, read-only. It counts `Skill` and `Agent` calls and
failed tool calls per session, and prints counts only. It ran over three repos: the first field repo, this repo, and
one other.

| Repo | Sessions with tool use | Sessions using a skill | Sessions using an agent | Repo's own artifacts (sessions used) |
|---|---|---|---|---|
| First field repo | 14 | 10 | 13 | 2 agents (9 and 9); 2 skills (6 and 3) |
| This repo | 10 | 4 | 9 | none |
| A third repo | 9 | 7 | 5 | none |

- **The plugin's three agents:**
  - decision-checker ran in 2 sessions of the first field repo and 1 of this repo;
  - codebase-guide and memory-curator ran in none.
- **Failed tool calls:** the same kind of failure recurs across sessions, for example a shell command exiting
  non-zero in 12, 9 and 5 sessions of the three repos.

## Probe 3: a draft agent file is not loaded

**Setup.** A scratch repo with three files:
- `.claude/agents/zz-draft-agent.md.draft`;
- `.claude/agents/zz-live-agent.md`;
- `.claude/skills/zz-probe/SKILL.md.draft`.

**Result.** The init stream of `claude -p` listed `zz-live-agent` only. Neither draft was listed.

**Reading.** An agent draft is inert, as D31 found for rule and skill drafts.
