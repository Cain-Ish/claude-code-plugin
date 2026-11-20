# V2-D29 setup probes (06, section 3, S0)

`probes.mjs` runs probes P1 to P6 as registered in 06, section 3. Each runs with the pinned CLI 2.1.305 in throwaway
repos under a scratch folder. It writes `results/<probe>.json`: flags and counts only, no transcript text.

```
D17_CLAUDE=<pinned claude-2.1.305> node probes.mjs <scratch> [P1,P2,P3,P4,P5,P6]
```

**Two additions to P3, recorded before any run (2026-11-20):**
- a **control arm**: the same untracked rule, without the label. A 0 of 5 in the labelled arm then cannot mean that the
  rule never loaded;
- an **Opus 5.5 arm** beside the registered Haiku. The user works on Opus, and a label's effect can differ by model.

The registered bar is unchanged: at most 1 of 5 nonces in the labelled arm. It applies to each model.

**Probe notes:**
- In 2.1.305, the `--permission-mode` choice for the default mode is `manual`.
- P4 runs in an isolated `CLAUDE_CONFIG_DIR`, so the user's own transcripts are never at risk. If the session cannot
  start there (no login), the result still shows whether cleanup ran at startup.

## Results (2026-11-20, CLI 2.1.305; P1, P2, P5, P6 on Haiku 5.5)

| Probe | Result | What it changes |
| --- | --- | --- |
| P1 | A session's transcript goes to the folder of its **launch directory**: a subdirectory and a linked worktree each get their own folder, not the repo root's. A SessionStart hook's input carries `transcript_path` and `cwd` | The dream's folder list is learned from `dirname(transcript_path)` at each session start, as planned |
| P2 | In `manual` and `acceptEdits`, Read and Write of a file in the OS temp folder are both **denied** headless (they would prompt in a live session) | The dream's run folder goes inside the repo: `.project-map/.dream-run/`, ignored and excluded from the index |
| P5 | Writes to `.claude/rules/x.md` and `.claude/skills/x/SKILL.md` are **denied** in `manual` and `acceptEdits` (they would prompt), and **land with no prompt in `auto`** | Registered fallback fired: in auto mode the gate does not ask. Staging as `*.md.draft` goes back to the user before S7 |
| P6 | A project agent with `tools: Read, Grep, Glob` and `memory: project` **wrote a file outside its memory folder** (`notes/out.txt`). The auto-enabled Write is not limited to the memory folder | Project agents with project memory can write anywhere a session can. Their prompts limit them, and S5 counts writes outside the memory folder |
| P6c (added after P6b was inconclusive, before its run) | An agent with `tools: Read, Bash(git diff:*)` ran `git diff --stat` and also `git log -1`: the pattern **does not limit** Bash | Project agents get no Bash. They cannot see commits, so an unreviewed dream entry must be visible in the file itself |
| P4 | Inconclusive: in an isolated `CLAUDE_CONFIG_DIR` the session could not start (no login), and no transcript was deleted. Copying the user's credentials to force it was declined | The expiry warning uses file mtime, the conservative reading. It is advisory and marked `shortcut:` in the code |
| P3 (5 runs per arm and model) | An untracked `.claude/rules/nonce.md` scoped to `src/**`. **Opus 5.5:** the nonce landed in **5 of 5 without the label, and 0 of 5 with it**. **Haiku 5.5:** 0 of 5 in both arms, so it never followed the rule even unlabelled, and its arm is uninformative | Opus passes the registered bar (at most 1 of 5). The session-start label stops an unreviewed rule in the main session. It does not reach subagents, which load path rules on a matching file without the label (D12) |

**S0 outcome.** P1-P6 are answered (P4 inconclusive and handled conservatively). One registered fallback fired: **P5**,
no gate in `auto` mode. So the choice between direct writes with the label (P3: 0 of 5 on Opus) and `*.md.draft`
staging goes back to the user before S7, as registered.
