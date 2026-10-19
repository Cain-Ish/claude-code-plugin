# Probe P1 (V2-D12): which channels arrive, and where

The check and its pass condition are pre-registered in [DECISIONS.md](../../DECISIONS.md) under V2-D12, committed
before any run (`90c77c9`).

## Run

`node probe.mjs <scratch-dir> 3`. It needs only Node and the installed `claude` CLI (no npm packages). Each run
builds a fresh git repo and a probe plugin `prb` with new random nonces, then runs 11 headless sessions on Haiku
with user settings excluded (`--setting-sources project,local`) and Bash, Grep, Glob, WebFetch and WebSearch denied,
so a nonce can only be known through its channel. Raw streams stay in the scratch directory; `results.json` holds
the scored cells, scored from the stream (the model's own tool calls and text), not from a summary.

## Channels

| Code | Channel |
| --- | --- |
| CM | root `CLAUDE.md` (also the positive control) |
| IM | `@docs/imported.md`, imported by the root `CLAUDE.md` |
| UR | unscoped rule `.claude/rules/general.md` |
| PR | path rule `.claude/rules/src.md`, `paths: src/**` |
| NC | nested `src/CLAUDE.md` |
| PS | project skill with `paths: src/**` (nonce in the description) |
| KS | plugin skill with `paths: src/**` (nonce in the description) |
| SS / SC | plugin SessionStart `additionalContext`, matcher `startup` / `compact` |
| SA | plugin SubagentStart `additionalContext` |
| UP | plugin UserPromptSubmit `additionalContext` |
| MI | plugin MCP server instructions |
| AM | auto memory `MEMORY.md`, with `autoMemoryDirectory` pointed into the repo by `settings.local.json` |
| NEG | negative control: a file nothing loads |
| W | path rule `paths: src/components/**`: "a new file here starts with `// <nonce>`" |
| WN | nested `src/components/CLAUDE.md`: "a new file here ends with `// <nonce>`" |

## Sessions per run

- **S:** the main session lists nonces, reads `src/a.ts`, lists again.
- **A (8 sessions):** for each of Explore, Plan, general-purpose and the plugin agent `prb:lister`, one session in
  which the main session only launches that agent with "list without tools" (start), and one with "read `src/a.ts`,
  then list" (after read).
- **K:** one process, one turn at a time: read `src/a.ts` and answer its line count (no nonce quoted), `/compact`,
  then list.
- **W:** create `src/components/Avatar.tsx` with Write as the first file tool, follow any instructions that apply,
  then list. Scored in the first Write's content, in the final file, and in the listing.

## Harness fixes from the one-run pilot (before the check; the pass condition is unchanged)

1. Subagents launched after the main session had read `src/a.ts` saw the path-activated project skill: skill
   activation is per session. Fixed: one session per subagent and moment, and the main session touches no file.
2. Explore and Plan on Haiku call Read before writing a START list. Fixed: start and after-read are separate
   single-reply prompts.
3. Sending all K messages at once queued the third one mid-turn; Haiku saw it attached to the Read result and
   ignored it as an injection. Fixed: stream-json input, one message per turn, each after the previous result.
4. W re-read the file it had just written; reading the file it wrote is allowed.

After the check, for re-probes only (`results.json` comes from the scorer as it ran): the scorer counted a denied
Read as a read (see the Explore note below), and it now requires a successful one; and validity is judged per cell,
as the pre-registered text says, so a faulty session voids only its own cells, not the whole run.

## Results (2026-10-20, Claude Code 2.1.304, Haiku, 3 of 3 runs valid)

Hits in 3 valid runs. s / r = at start / after reading `src/a.ts`; /c = after `/compact`.

| Channel | Main s / r / c | Explore s / r | Plan s / r | general-purpose s / r | Plugin agent s / r |
| --- | --- | --- | --- | --- | --- |
| CM, IM, UR: root `CLAUDE.md`, its import, unscoped rule | 3 / 3 / 3 | 0 / 0 | 0 / 0 | 3 / 3 | 3 / 3 |
| PR, NC: path rule, nested `CLAUDE.md` | 0 / 3 / 3 | 0 / 2 | 0 / 3 | 0 / 3 | 0 / 3 |
| PS: project skill with `paths:` | 0 / 3 / 3 | 0 / 2 | 0 / 3 | 0 / 3 | 0 / 0 |
| KS: plugin skill with `paths:` | 3 / 3 / 3 | 3 / 3 | 3 / 3 | 3 / 3 | 0 / 0 |
| SS: SessionStart, `startup` | 3 / 3 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| SC: SessionStart, `compact` | 0 / 0 / 3 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| SA: SubagentStart | 0 / 0 / 0 | 3 / 3 | 3 / 3 | 3 / 3 | 3 / 3 |
| UP: UserPromptSubmit | 3 / 3 / 3 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| MI: MCP server instructions | 3 / 3 / 3 | 0 / 3 | 0 / 3 | 0 / 3 | 0 / 3 |
| AM: auto memory (redirected into the repo) | 3 / 3 / 3 | 0 / 0 | 0 / 0 | 3 / 3 | 3 / 3 |
| NEG: negative control | 0 / 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |

**Write-first (W, WN):** in the first Write's content 0 of 3; in the final file 2 of 3 (the model edited the file
after the Write); listed after the Write 3 of 3. The path rule and the nested `CLAUDE.md` of a directory arrive with
the first Write into it, too late to shape that Write.

Notes:
- Explore after read, 2 of 3: in the miss, Explore wrote a wrong absolute path, the Read was denied, and the file was
  never touched. Scored as pre-registered: 2 of 3 is unreliable.
- After `/compact` the summary carried none of the path-scoped nonces. They came back because compaction re-attaches
  the recently read file, which loads its path rules again.
- The plugin skill was listed from the start: its `paths:` gate did not apply. The plugin agent (tools: Read) gets no
  skill listing at all.
- MCP server instructions reach a subagent only after its first tool call.
- Auto memory reached general-purpose and the plugin agent. The research note, from the docs, says subagents do not
  get it.

## Limits

- Headless (`-p`) sessions on Haiku. Interactive sessions and other models were not probed.
- One CLI version (in `results.json`). V2-D12 carries a CLI-change reopen trigger (PM8).
- Auto memory was redirected into the repo; its default location under the user's home was not probed.
- A listing is the model's own report of its context, so a miss can be a false negative. The positive control and
  the 3-of-3 bar bound this; a hit cannot be guessed (random nonce, no search tools, no direct read).
