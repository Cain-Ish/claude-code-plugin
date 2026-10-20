# Probe V2-D20 stage 1: Claude in the test-bed repos as they are run today

**Privacy first:** the tasks and rules of the two private repos live in a config under `docs/v2/research/raw/`
(gitignored), passed to the harness by path. This folder holds the harness and counts only: task ids, invented rule
ids, rule kinds and how the native setup delivers each rule. No task text, rule text or private path.

Question (pre-registered in [DECISIONS.md](../../DECISIONS.md), V2-D20 "Stage 1 check"): in each test-bed repo, does
Claude miss rules that bind a realistic task, and when it does, was the rule never in its context, or in context but
not applied? The answer decides which mechanism stage 2 tests ([research/2026-10-21-rethink.md](../../research/2026-10-21-rethink.md)).

## Harness

`native.mjs` (Node, no packages) runs one `claude -p` session per run in a fresh worktree of a pinned scratch clone,
with the repo's own `CLAUDE.md`, rules, skills and hooks, and nothing of the user's (setting sources project and local,
`--strict-mcp-config`, auto memory off, Bash and the web off). `log.mjs` is an `InstructionsLoaded` hook that logs
each instruction file that loads, with its reason and trigger file; `--include-hook-events` puts the repo's hook
output in the stream.

For each rule a run records: the check on the final output; the check on the first write; whether the rule was in
context before the first write and at all (an instruction load, a `Read` of its source, a `Skill` call, or its marker
text in anything Claude saw, each placed at the tool call it followed; a rule loaded by a write arrives with that
write, D12); and the chain: followed, not in context, or in context but not applied.

```
node native.mjs checks  <config>                  every check against a correct and a wrong sample
node native.mjs smoke   <config> <task>           one cheap session (a small model): plumbing only
node native.mjs run     <config> <task> [runs] [first]
node native.mjs summary <config>                  writes results/summary.json (counts only)
```

## Plumbing smoke (2026-10-21, before any task run)

One small-model session per repo, writing one file: valid in all three, under 0.01 USD each. Each repo's own skills
are listed and no plugin of the user's loads (the built-in ones do). The `InstructionsLoaded` hook logs the root
instruction file at session start, and a path rule at the first read of a matching file, with its trigger file. A
repo's `PostToolUse` reminder shows in the stream as hook output. The v1 repo has no git history in its extracted
form; the scratch copy is committed once so it can be pinned.
