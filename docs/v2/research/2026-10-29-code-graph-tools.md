# Code-graph tools against v2, read from their code

**Date:** 2026-10-29. **Question (user):** four public tools give Claude Code persistent knowledge of a repo. Do they
already do what v2 does, and what can v2 borrow? The user asked for the answer from their code, not their READMEs.

**Method.** Shallow clones at the commits below, read and not run: no build, install or index. Four readers worked
in parallel, one per repo, and each cited `path:line`. Every claim this note's conclusion rests on was then re-read in
the code (marked ✓). Paths are relative to each repo's root.

| Repo | Commit | License | Runtime |
| --- | --- | --- | --- |
| [DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) (CBM) | `a3831c979547d33adaa36998dca2b004d735fc84` | MIT | one C binary, vendored SQLite |
| [colbymchenry/codegraph](https://github.com/colbymchenry/codegraph) | `13f983db5a3f4e72c81e9b5707f8bb85c9facd90` | MIT | Node ≥ 22.5 (`node:sqlite`), 65 MB of WASM grammars |
| [abhigyanpatwari/GitNexus](https://github.com/abhigyanpatwari/GitNexus) | `0a96ea995289ef7e3a83ddd1223b1820482a6155` | **PolyForm Noncommercial 1.0.0** ✓ | Node ^22.18, LadybugDB, native tree-sitter |
| [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify) | `0a8cd4e1e342235fe53e881fb5d591bf0460071f` | Apache-2.0 (earlier parts MIT) | Python ≥ 3.10, networkx, 25 tree-sitter wheels |

GitNexus's license forbids commercial use. From it v2 takes ideas only, never code.

## 1. What they are: indexes of code structure

| | Stores | Built by | Reaches Claude through |
| --- | --- | --- | --- |
| CBM | SQLite graph of symbols, routes, files; markdown headings as `Section` nodes with their text; one ADR per project (`src/store/store.c:327-482`) | tree-sitter (the reader counted 162 grammar files), no model | MCP (17 tools), plus hooks on `SessionStart`, `SubagentStart` ✓, `PreToolUse` Grep/Glob/Bash, `PostToolUse` Read (`src/cli/cli.c:6038-6075, 6349-6357`) |
| codegraph | SQLite: 23 symbol kinds, 13 edge kinds; no markdown (`src/db/schema.sql`, `src/extraction/grammars.ts:59-173`) | tree-sitter (WASM), no model | MCP, only `explore` by default, marked `anthropic/alwaysLoad` ✓ (`src/mcp/tools.ts:1848, 1953`); a `UserPromptSubmit` hook that runs `explore` on the prompt and injects up to 9,000 characters (`src/bin/codegraph.ts:1605-1660`) |
| GitNexus | LadybugDB: 35 node tables, 31 relation types; markdown headings as `Section`; files' full content (`gitnexus-shared/src/lbug/schema-constants.ts:11-96`) | tree-sitter (17 grammars), no model by default; `wiki` calls an LLM | MCP (19 tools, `npx -y gitnexus@latest`, unpinned); `PreToolUse` Grep/Glob/Bash and `PostToolUse` Bash ✓ (`gitnexus-claude-plugin/hooks/hooks.json`); a block written into CLAUDE.md and AGENTS.md, and 12 skills (`gitnexus/src/cli/ai-context.ts:229-296, 553-605`) |
| graphify | networkx JSON at `graphify-out/graph.json`; node types code, document, paper, image, rationale, concept; edges tagged `EXTRACTED`/`INFERRED`/`AMBIGUOUS` (`graphify/validate.py:4-7`) | tree-sitter for code; docs, PDFs and images by an LLM, by default the session's own subagents (`graphify/skill.md:165-172`) | a skill; a block in CLAUDE.md; `PreToolUse` on `Bash\|Grep` and `Read\|Glob`, at most 5 nudges per agent ✓ (`graphify/cli.py:981-1031`); optional MCP |

All four answer "what calls what, where is X". Each keeps its index fresh by content hash, file watcher or git hook.

## 2. None captures decisions into the repo

None writes what a session decided into committed, reviewable files with a source that is re-checked. The nearest:

- **CBM `manage_adr`:** one document per project, held in the user's cache database, not the repo. A legacy
  `adr.md` is migrated *into* the database (`src/mcp/mcp.c:20428-20434`) ✓. Its `source_hash` is always written as
  `''` (`src/store/store.c:11896-11905`) ✓, so it is never checked for staleness.
- **graphify `save-result` and `reflect`:** a query's answer saved with an outcome (`useful`, `dead_end`,
  `corrected`) under `graphify-out/memory/`. Outcomes are aggregated with a 30-day half-life into `LESSONS.md`
  (`graphify/ingest.py:296-370`, `graphify/reflect.py:1-25`). This is memory of questions answered, with no source
  quote, no "when it applies" and no review state. Its "rationale" nodes are code comments starting `NOTE:`, `WHY:`,
  `HACK:` or `TODO:`, and Python/JS docstrings (`graphify/extract.py:1810-1878`).
- codegraph and GitNexus: no write tool of any kind (readers' greps; codegraph's tools are all read-only).

None enforces anything. GitNexus states "MUST run impact before editing" as prose in CLAUDE.md
(`gitnexus/src/cli/ai-context.ts:239`). graphify has an opt-in `--strict` that denies the first raw Read until one
query has run (`graphify/cli.py:1048-1060`). No hook of any of the four looks at Edit or Write.

So the 2026-10-19 note's reading from READMEs ([prior-research-and-sota](2026-10-19-prior-research-and-sota.md),
finding 4: "structure is a commodity; rationale is the gap") holds in the code. They overlap v2 on persistence, not on
content: their memory is of code structure, and v2's is of what a project decided.

## 3. Their own evidence: fewer reads, no lower cost

These tools target what v2 measured as its weak side: orientation, investigation questions and tokens. Their own
committed data does not show a saving either:

- **codegraph**, A/B over 37 cells, one run each ✓ (`docs/benchmarks/codegraph-ab-matrix.md`): file reads 159 → 38,
  cost 15.4 USD with it against 13.8 without. In the prompt-hook eval (n=3), reads fell to 0–1, but answers on small
  and large repos came out partial ✓ (`scripts/agent-eval/offload-eval.md:64-75`). The README's "62% fewer tokens"
  has its harness committed, not its data. The README says "No data leaves your machine" (`README.md:284`), while
  telemetry is on by default ✓ (`src/telemetry/index.ts:251`).
- **GitNexus**, its one committed measurement ✓ (`eval/workflow_bench/measurement-2026-10-24.md`): cost +21.6% and
  +45.7% with it, 12/12 solved in both arms. The document itself says it shows no accuracy gain or cost saving. Its
  SWE-bench harness has no committed results.
- **CBM:** no token or task harness in the repo. The README's "10× fewer tokens" cites the authors' preprint, which
  the 2026-10-19 note recorded at quality 92% → 83%.
- **graphify:** the "71.5×" comes from `graphify/benchmark.py`, whose baseline is the whole corpus, or nodes × 50
  words when no count is passed. It measures the answer's size, never whether the answer is right ✓
  (`graphify/benchmark.py:53-80`).

None measures an editing task. v2's own measured gain is on rules followed, not tokens. The plugin kept and followed
the designer's spec 10 of 10, against native auto memory's 2 and 0 ([charter](../00-charter.md), 2026-10-25). None
of these tools aims there.

**Corrections to the 2026-10-19 note:**
- codegraph's "-62% tokens, -44% cost" is a README figure. Its committed A/B data shows cost up, as above.
- Graphify is not "local AST, no API cost" for documents: documents go through an LLM.
- CBM's and graphify's graphs can be committed (CBM's optional `graph.db.zst`, graphify's `graph.json`). They are
  not only local.

## 4. What v2 can borrow, by the decision it touches

| Mechanism | Seen in | Measured weakness it targets | Status for v2 |
| --- | --- | --- | --- |
| `SubagentStart` hook whose `additionalContext` carries the index | CBM `src/cli/cli.c:6215-6226, 6349-6357` ✓ | subagents do not see the index (04) | D18 deferred `SubagentStart` with the trigger "the first slice logs subagent use" (DECISIONS, D18). The first slice's build runs record subagent writes ([06](../06-first-slice.md), 2f's validity correction, lines 620-621), and D22's P2 cost is "mostly subagent research". **A trigger observation for D18, for the ledger.** The fix is its own step with a pre-registered check |
| Hint at search time: `PreToolUse` on Grep/Glob matching the term against the index and map entries, capped per agent | all four; per-agent cap in graphify `graphify/cli.py:981-1031` ✓ | orientation; investigation | Would reopen D18 ("Not used: `PreToolUse`") and D22 (investigation outside the claim, the user's choice). No trigger fired. codegraph's front-load data (fewer reads, partial answers) is the risk to probe. Not recommended now |
| Skip machine messages in `UserPromptSubmit`: a prompt that is only a task notification or agent message, and `<system-reminder>` blocks | codegraph `src/directory.ts:1115-1158` | — | **Possible bug in v2, unverified.** `takeForce` spends the epoch's marker on any `UserPromptSubmit` (`plugin/scripts/map.mjs`). If a subagent's hand-back fires that hook after a compaction, the forced decision lands on that turn and not on the user's next prompt. Probe whether hand-backs fire the hook before claiming it |
| Strip control characters from repo text before it reaches Claude | graphify `graphify/cli.py:231-236`; CBM labels repo metadata "data only" (`src/cli/hook_augment.c:1713-1719`) | charter: untrusted text is data | v2's index prints raw `git ls-files -z` paths (`plugin/scripts/map.mjs`, `index`). A committed file name containing a newline adds a line of its own to the index. A small fix for a later step |
| Explicit `timeout` on each hook entry | GitNexus `hooks.json`, graphify `graphify/install.py:494-500` | hook hygiene | v2's `hooks.json` sets none. Not a measured weakness |
| Report a file that could not be checked as unchecked, never as fresh | codegraph `src/mcp/answer-freshness.ts:13-66` | — | v2 already fails closed (D14, D18). Confirms v2's choice; nothing to take |

Not borrowed, each by an existing decision: a parser index (D21, rejected by citation; no file duplicated in 36 runs);
an MCP server and agents (D18); model-written extraction of documents (D15; graphify's runs on the session's own
subagents); writing into the user's CLAUDE.md (v2 leaves the project's files to the project, D15).

**Flags the readers raised about v2, closed here:**
- *The hook cap.* `startText` caps instruction, index and closing line together at 10,000 characters
  (`plugin/scripts/map.mjs`, `CAP`), so nothing is cut past the cap.
- *Tokens counted twice per message.* `native.mjs` sums usage once per message id (line 401), and `eval.mjs` reads
  the result's own usage.

## Not checked

- Nothing was run. Sizes and costs here are code constants and committed documents, not measurements.
- Grammar and tool counts are the readers' counts. Only the claims marked ✓ were re-read.
- Whether Claude Code sends `agent_id` to hooks inside subagents. graphify's per-agent cap rests on a code comment
  (`graphify/cli.py:986-988`), and CBM's `SubagentStart` text on its own comment. D12 proved `SubagentStart`
  arrives, and nothing about `agent_id`.
- CBM's preprint, and the star counts the 2026-10-19 note gave.
