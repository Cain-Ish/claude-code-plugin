# Eval harness (V2-D17): scenario A1, arms M0 and M1

The scenario, arms, checks, metrics and protocol are pre-registered in [05-eval-plan.md](../../05-eval-plan.md); the
check that locks D17 is in [DECISIONS.md](../../DECISIONS.md) under V2-D17. This folder is the harness that runs
them.

## Files

| Path | What |
| --- | --- |
| `eval.mjs` | Runner and scorer (Node, no npm packages): builds the run folders, runs the sessions, scores them, writes `results/<arm>.json`. Also the smoke check |
| `sessions.mjs` | The prompts of H1-H3, T and N, and the cue-word and answer-token patterns |
| `fixture/` | The front-end repo every session starts from (invented client and names) |
| `gold/` | Hand-written correct outputs for the smoke check: T's and N's files, T's reply, a memory store |
| `results/` | Scored runs, one file per arm; no paths, no session ids, no transcript text |

## Run

```
node eval.mjs --smoke                     # smoke check only
node eval.mjs <scratch-dir> M1 1 1        # arm, number of runs, first run number
```

It needs only Node and the installed `claude` CLI. Every run starts with the smoke check and stops if it fails. Run
folders and raw streams stay in `<scratch-dir>`.

- **M1:** a fresh copy of the fixture (`repo-H`) with `.claude/settings.local.json` turning auto memory on and
  pointing it at an empty `mem-H` beside the repo. H1, H2 and H3 run there in order. Then T and N each get their own
  fresh fixture copy (`repo-T`, `repo-N`) and their own copy of the store as H3 left it (`mem-T`, `mem-N`).
- **M0:** auto memory off; only T and N run, each on a fresh fixture copy.
- Every session: `claude -p` on Sonnet 5.5, user settings, MCP servers and skills excluded, Bash and the web denied,
  `acceptEdits`, the memory directory added with `--add-dir`, stream-json output.

## Scoring notes

- Capture (C1-C4) reads every file in the store after H3. The failure chain counts a decision as loaded when its
  capture item passes on the index that loads at start (`MEMORY.md`, first 200 lines and 25 KB) plus the memory files
  T read before its first Write of `UserAvatar.tsx`.
- Each run records the epoch (CLI version, model, a hash of the fixture and `sessions.mjs`); runs from different
  epochs are not compared.

## Smoke check

Gold outputs pass all 12 items; 14 planted wrong outputs each fail only their own item; the T and N prompts hold no
answer token and no history prompt a cue word; on a synthetic event stream the harness finds the "before writing"
point, the memory reads before it and a refused memory write (and does not count a failed Edit as a refusal).
