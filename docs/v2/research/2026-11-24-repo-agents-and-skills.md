# Agents and skills made for one repo, tested and improved from its sessions

**Asked (2026-11-24):** the user sent [this video](https://www.youtube.com/watch?v=tTcxVv8HHNw) and asked for deep
research into it and the articles around it: "we need full guidelines in plugins so it will be used in other repos to
create dedicated and correctly made agents and other skills per repo with self-evaluate and self-improve loop as she
mention".

**Method.**
- **The video.** Its manual English captions (566 segments) were read in full. It is the AI Native DevCon London talk
  that the [research of 2026-11-20](2026-11-20-anthropic-memory-and-dreaming.md) read as text from Tessl's registry:
  85.8% of the video's three-word runs appear in that text, and its distinctive passages match (the head teacher, the
  radians, the hash check, "reinventing databases").
- **Four research subagents**, all Claude, one per strand:
  - Anthropic's platform docs and engineering posts;
  - Claude Code's docs;
  - the speaker's other talks and writing;
  - outside work on improving agents.
- **Spot-checks.** I re-read these at the source, word for word:
  - the SkillsBench paper's body;
  - the AGENTS.md study's abstract;
  - Anthropic's "The components of agent memory";
  - the Claude Code team's verification post;
  - the speaker's Substack post.

  Quotes not re-checked are marked "(subagent's reading)".
- **Read locally** (Claude Code 2.1.331):
  - `claude plugin eval --help`;
  - the official `skill-creator` skill.

## 1. What the speaker says, and what she does not

**Lamis Mukta**, member of technical staff on Anthropic's Applied AI team.

| Source | What bears on this request |
|---|---|
| **The talk:** ["Learning while you sleep: Beyond memory to dreaming"](https://www.youtube.com/watch?v=tTcxVv8HHNw), AI Native DevCon London, published 2026-06-22 | - **Skills' bottleneck (7:17):** "it's still kind of driven by humans and agents together ... You're still being quite opinionated about what things need skills".<br>- **The dream reads more than the conversation (21:04, 22:07):** "We're also really scrutinizing those tool calls and all of the other metadata"; transcripts carry "metadata on tools, other skills they used".<br>- **Steering (22:28):** "you're able to tell them, like in your specific case, these are the kinds of things I think are important and relevant".<br>- **Evidence (23:12):** the dream gives "transcripts where it's noticed this pattern has happened, and also some stats on like how prevalent this issue is".<br>- **Human gate (23:37):** "you as the individual can decide where you want to accept changes".<br>- **Upkeep (26:40):** "consolidate your memory and cut things that are no longer relevant. Add things that agents are missing".<br>- **Permissions (12:49):** org-wide context read-only; an agent's scratchpad writable. |
| **Podcast:** [Tessl podcast 113](https://tessl.io/podcast/113), "Inside Anthropic: How Claude Tag Is Changing Agentic Work", 2026-07-07 ([video](https://youtu.be/7Ue0yM4J-B8); full transcript; quotes are the subagent's reading) | - **Skills and memory per Slack channel, not per repo (05:57):** "it's kind of scope to a channel level".<br>- **Models check their own work (17:59):** "whether that's through like front end test or running tests or creating their own evals".<br>- **Defining success (18:20):** "how well can you define what success looks like in your case".<br>- **A reviewer agent (18:31):** "have another agent review its work until ... the reviewer kind of believes that that thing is complete".<br>- **Dreaming (50:48):** "it gives you hypotheses for what to change, gives you attachments to the sessions where it thinks that the evidence is there, and then you can basically decide which of those changes to implement".<br>- **A lighter harness (36:07):** "delete stuff from that harness over time". |
| **Substack:** ["Your IDE is your new home of work, but not for code"](https://lamismukta.substack.com/p/your-ide-is-your-new-home-of-work), 2026-02-23. Written before she joined Anthropic, about her writing workflow | - **Write skills for next time:** "With each iteration of my work, I can ask agents to compare the raw inputs and what we landed on, to update the context to better align with my preferences. I ask them to write any skills that would have been useful, for next time."<br>- **An improvement cycle:** "I have a skill which adds features and examples to that list when I run into limitations. From time to time, I go through an improvement cycle and an agent implements them." |
| **Press:** [Tom's Guide via Yahoo](https://tech.yahoo.com/ai/claude/articles/built-claude-agent-manage-inbox-101500521.html), 2026 (subagent's reading) | "Claude is really good at just like updating your prompts and skills for you if you need that" |

**Not in her words** in any source found:
- dedicated agents or skills for each repository;
- a loop in which evals or graders judge proposed changes to skills or agent definitions;
- dreaming that edits skills or agents. As she describes it, dreaming edits memory stores.

**Other leads:**
- **The "codebase memory store"** is Mahesh Murag's, at Code with Claude San Francisco
  ([recording](https://youtu.be/RtywqDFBYnQ)).
- **"You're not supposed to prompt Opus 5.5 …"** is a caption on third-party re-uploads and is not in her talk.

**So:**
- **What she supplies is the loop's shape:**
  - memory written in the session;
  - a dream out of band over transcripts, tool calls included;
  - steering;
  - evidence with prevalence;
  - a person who accepts or rejects each change;
  - and, before Anthropic, skills written "for next time" with a periodic improvement cycle.
- **How to make an agent or a skill correctly** comes from Anthropic's documentation (section 2), and is labelled so.

## 2. How Anthropic says to make an agent, a skill or a rule

**Where a piece of guidance belongs** ([features overview](https://code.claude.com/docs/en/features-overview.md)):
- "Use CLAUDE.md for instructions every session needs."
- "Rules with `paths` frontmatter only load when Claude works with matching files."
- "Use skills for content Claude only needs sometimes."
- "Use a subagent when you need context isolation or when your context window is getting full."
- "Use a hook when the action must happen the same way every time and doesn't need Claude to think."
- "An instruction like "never edit `.env`" in CLAUDE.md or a skill is a request, not a guarantee."

**A subagent** ([sub-agents](https://code.claude.com/docs/en/sub-agents.md); quotes are the subagent's reading):
- **Description:**
  - "Claude uses each subagent's description to decide when to delegate tasks";
  - "Those descriptions take up context, so keep them short";
  - "include phrases like "use proactively"".
- **Tools:** "Inherits every tool available to subagents if omitted", so a focused agent names its tools.
- **Memory:**
  - "`project` is the recommended default scope";
  - the agent's `MEMORY.md` loads at start, its "first 200 lines or 25KB".
- **Project agents:** "Project subagents (`.claude/agents/`) are ideal for subagents specific to a codebase. Check them
  into version control".
- **Names:** "Names can't contain `:`".
- **Plugin-shipped agents:** they ignore `permissionMode`, `mcpServers` and `hooks`, which a project agent can set.

**A skill** ([skills](https://code.claude.com/docs/en/skills.md);
[authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)):
- **The description:**
  - it drives selection: "Put the key use case first";
  - description and `when_to_use` together are cut at 1,536 characters.
- **Size:** "Keep `SKILL.md` under 500 lines"; "Keep references one level deep".
- **Evaluations first:**
  - "Create evaluations BEFORE writing extensive documentation";
  - "Identify gaps: Run Claude on representative tasks without a Skill";
  - "Write minimal instructions: Create just enough content to address the gaps and pass evaluations";
  - the checklist asks for "At least three evaluations created".
- **When to make one:** "Create a skill when you keep pasting the same instructions, checklist, or multi-step
  procedure into chat".
- **Two instances:** "Work with one instance of Claude ("Claude A") to create a Skill that is used by other instances
  ("Claude B")".
- **Start minimal**
  ([context engineering](https://www.anthropic.com/research/effective-context-engineering-for-ai-agents)): "start by
  testing a minimal prompt ... and then add clear instructions and examples to improve performance based on failure
  modes found during initial testing."

**What earns a place.** The [AGENTS.md study](https://arxiv.org/abs/2602.11988) (ETH Zürich, revised 2026-09-29)
found:
- "providing context files does not generally improve task success rates, while increasing inference cost by over 20%
  on average";
- "context files are useful for specifying non-standard coding practices";
- "any attempts to improve performance should be rigorously evaluated before deployment".

## 3. Self-evaluation: what exists, and what Anthropic says a check needs

**Native tools.**
- **`skill-creator`** (official plugin, read locally):
  - each test case runs twice in the same turn, "one with the skill, one without";
  - a changed skill is compared with a snapshot of its old version;
  - the description optimiser "splits the eval set into 60% train and 40% held-out test", "running each query 3 times
    to get a reliable trigger rate".
  - It covers skills only: not subagents, and not a repo's own sessions.
- **`claude plugin eval`** (Claude Code 2.1.269 or later; `--help` read on 2.1.331):
  - runs cases with graders (`regex`, `tool_used`, `tool_order`, `file_exists`, `llm`, `baseline`), three runs each;
  - an ablation arm runs without the plugin (`--ablation with-without`);
  - its target is "a path, a plugin name, or a `plugin@marketplace` id — installed and skills-dir plugins both
    resolve".
  - By the [docs](https://code.claude.com/docs/en/plugin-evals.md) (subagent's reading), "Each run starts in an empty
    workspace".
  - **Whether it can test a repo's own `.claude/skills/` and `.claude/agents/` inside that repo is unproven.** A probe
    must settle it before anything rests on it.

**What a check needs, by Anthropic's posts.**
- **Real failures, both sides**
  ([Demystifying evals](https://www.anthropic.com/research/demystifying-evals-for-ai-agents), 2026-01-09; subagent's
  reading):
  - "20-50 simple tasks drawn from real failures is a great start";
  - "Test both the cases where a behavior should occur and where it shouldn't";
  - "it's often better to grade what the agent produced, not the path it took".
- **A separate grader**
  ([outcomes](https://platform.claude.com/docs/en/managed-agents/define-outcomes); subagent's reading): "The grader uses
  a separate context window to avoid being influenced by the main agent's implementation choices"; "vague criteria
  produce noisy evaluations".
- **Held out** ([writing tools](https://www.anthropic.com/research/writing-tools-for-agents); subagent's reading): "We
  relied on held-out test sets to ensure we did not overfit".
- **Out of reach of the change**
  ([verification](https://claude.dev/blog/how-the-claude-code-team-thinks-about-verification/), Addy Osmani,
  2026-11-16):
  - a separate grader against a rubric "improved task success by up to 10 points";
  - "If a check is still failing after three rounds, Claude stops and brings in a human";
  - Code Review reads REVIEW.md "from the base or default branch, never from the pull request's changes";
  - and the loop in one sentence: "Keep it out of reach of the changes they judge, grade them against the bugs that
    mattered to you, and write down lessons when they miss something so that it doesn't happen more than once, and
    prune those lessons so they stay worth running."

## 4. Self-improvement: what works

**Anthropic.**
- **[The components of agent memory](https://www.anthropic.com/research/components-of-agent-memory)** (Lance Martin,
  2026-11-06):
  - "we ran a loop in which Claude reflected on its failures, proposed a change to the instructions, and rebuilt the
    wiki";
  - graded again, "100% of the criteria could be met, up from 72%".
- **[Dreams](https://platform.claude.com/docs/en/managed-agents/dreams)** (Managed Agents, research preview; subagent's
  reading):
  - "The input store is never modified, so you can review the output and discard it";
  - "The optional `instructions` field steers what the dreaming pipeline synthesizes".
  - A dream returns a whole new store, not a list of changes. Per-change evidence appears only in the talk, the
    podcast and the [cookbook](https://platform.claude.com/cookbook/managed-agents-cma-dreaming-with-a-dynamic-workflow):
    "Verify what memory already claims against it". The cookbook also warns: "There's no review by default. A bad
    transcript can reach your agent the next morning."
- **Claude Code's own background dream** ("autoDream"). It is undocumented, and known from public write-ups of the
  source leak of 2026-03-31
  ([Ars Technica](https://arstechnica.com/ai/2026/04/heres-what-that-claude-code-source-leak-reveals-about-anthropics-plans/),
  [Milvus](https://milvus.io/blog/claude-code-memory-memsearch.md); subagent's reading). In paraphrase:
  - it runs once 24 hours and five new sessions have passed;
  - it greps transcripts narrowly, for what it already suspects matters;
  - it edits memory with no approval step.

  Nothing here rests on it.

**Research** (all the subagent's reading, except where marked checked):
- **[ACE](https://arxiv.org/abs/2510.04618)** (ICLR 2026):
  - small "delta entries ... merged deterministically ... by lightweight, non-LLM logic";
  - whole-context rewrites collapsed: 18,282 tokens down to 122, and accuracy below baseline;
  - without reliable feedback, adaptive methods "may degrade".
- **[Probe-and-Refine](https://arxiv.org/abs/2606.20512)** (2026-06; repository guidance for coding agents):
  - edits "capped at 5 per iteration", "applied mechanically (no LLM call)", within a 3,000-character budget;
  - it stops after two iterations with no change;
  - on SWE-bench Verified: 33.0% with tuned guidance, 28.3% static, 25.5% none;
  - guidance tuned for one model "actively destabilizes" another.
- **[Reflexion](https://arxiv.org/abs/2303.11366):** self-reflection is "bound to their ability to write diverse,
  comprehensive tests"; a false-positive test suite made it worse.
- **[Agent Workflow Memory](https://arxiv.org/abs/2409.07429):** learns only from runs "judged correct by an evaluator
  module".
- **[Your Agent May Misevolve](https://arxiv.org/abs/2509.26354):** "memory-driven misevolution can be triggered by
  specific incidents". A single session must not make a rule.

## 5. Evidence against generating agents and skills

- **[SkillsBench](https://arxiv.org/abs/2602.12670)** (v4, 2026-06-14; checked in the body):
  - "Self-generated Skills land below the no-Skills baseline on all three configurations (−8.1 pp on Claude Code +
    Opus 4.7 ...)";
  - curated skills add 18.2 to 24.8 points;
  - the causes: "generated packs the solver never discovers, creator-side authoring that displaces solver work, and
    confidently wrong pack content";
  - "Focused Skills with at most three modules outperform larger or exhaustive bundles" (abstract, checked).
  - Its skills were written before the task, without feedback. So it shows that unverified skills hurt, not that
    evidence-driven refinement does.
- **[Agent Skills Can Be Harmful](https://arxiv.org/abs/2608.11888)** (2026-08; subagent's reading):
  - 307 failures traced to skills;
  - "skills often turn validation checklists and construction recipes into mandatory work".
- **The AGENTS.md study,** section 2.
- **No study** was found on the cost of many subagents in one repo.

**Reading.** An agent or skill made because a plugin can make one is likely to make Claude worse. Four things make
the difference, and the evidence supports a loop built on them:
- it starts from a gap seen in real sessions;
- it holds only what Claude cannot infer;
- it is tested against a run without it, by a grader the change cannot touch;
- a person keeps it.

## 6. What the plugin does today

Read on `v2` at `58e78a0e` (2.5.1).

| Need | Today | Gap |
|---|---|---|
| Agents made for the repo | Setup installs three fixed agents with `memory: project`: decision-checker, codebase-guide, memory-curator (D29) | No guidance or step for making one more |
| Guidance on where a lesson belongs | The "Where it belongs" table in `.project-map/README.md`: map entry, skill, path rule, check (D29, P1) | No agent row; no format, grounding or test guidance |
| The dream reads tool calls and metadata | The digest keeps typed prompts, answers, Claude's text, tool names with the first 80 characters of input, and the first 300 of results (`dream.mjs` `tag`). It drops subagent transcripts (`isSidechain`) and does not mark failed tool calls | Failures are invisible. An `Agent` call's `subagent_type` may fall past the 80 characters |
| Usage per skill and agent | K1 counts which map files each session read (`mapReads`) | No count of each skill's and agent's use, or of corrections after one ran |
| Proposals | Entries, status lines, rule drafts, skill drafts; a draft needs evidence from 2+ sessions (`dream/SKILL.md`, `finish`) | No agent drafts; no proposed change to an existing skill or agent |
| Prevalence | Evidence lines on each draft; the report counts proposals by kind | Partial |
| Steering | None | The project cannot say what matters to it |
| Self-evaluation of agents and skills | None. S5 checked the three agents once (06, section 3) | Each made artifact needs its own cases and a run without it |
| Human gate | `map-review` promotes or discards drafts; nothing is committed (D31, D33) | Holds; reuse it |

## 7. Candidates, smallest first

Each candidate names the decision it touches. The user's request of 2026-11-24 is the word that opens them, under
rule 3.

1. **G1. A guidelines skill that makes or improves one agent, skill, rule or check for this repo.** It runs on the
   user's request, or on a dream's draft. Its steps:
   1. **The gap first.** Point at the sessions, entries or request that show the gap. With none, make nothing.
   2. **The home.** Choose the smallest that holds it, by section 2: a `CLAUDE.md` line, a path rule, a skill, an
      agent, or a check or hook. Check that nothing in the repo already does it.
   3. **Ground it.**
      - Every path, command and name it states must exist in the repo; check each one.
      - It holds only what Claude cannot infer.
   4. **Write it by section 2's rules.**
      - An agent: a short "when to delegate" description, named tools, `memory: project`, and the steps each with how
        to tell it is done.
      - A skill: a description with what and when, a body under 500 lines, and scripts for deterministic steps.
   5. **Cases before release:**
      - three or more, taken from real sessions;
      - one where it should not be used;
      - each with an outcome a grader can check.
   6. **A paired run.** Each case runs with the artifact and without it (or with its old version), in fresh
      subagents. A separate grader judges the outcomes. Show the user the counts.
   7. **The result** lands as a draft. The user promotes it in `map-review`. Nothing is committed.
   8. **Improving it later:**
      - add the missed case first;
      - change the smallest part;
      - rerun every case;
      - stop after three failed rounds and bring in the user;
      - when the run without it passes as well, propose retiring it.

   Touches D29 (layout) and D31 (drafts). It names the charter outcome it serves: Claude held to what the project
   decided.
2. **G2. An agent row in the placement table**, pointing at G1. Touches D29's templates, and the copy rule of 2.5.1:
   the README's old hash goes into `FILES`.
3. **G3. The dream reads failures and use:**
   - the digest marks a failed tool call;
   - it keeps the name of each skill and agent called;
   - the report counts each one's use, and the corrections that came after it ran (K1's form, evidence only).

   Touches D31.
4. **G4. The dream proposes agents, and changes to existing skills and agents**, each from 2+ sessions with its
   evidence. A project-owned steering section in `.project-map/dreams.md` says what matters here. Touches D31 and D30.
5. **G5. `map-review` runs G1's paired check** before it promotes an agent or skill draft. Touches D31 and D33. D33's
   human gate stays.

## 8. Not taken

- **Generating agents or skills at setup, or from the repo alone.** SkillsBench and the AGENTS.md study measure that
  as a loss.
- **Promotion without a person**, and a scheduled or automatic dream. D33 rejected both (options B and C) on
  2026-11-23. Every source above keeps a person deciding.
- **`claude plugin eval` as the runner, until a probe shows it can test a repo's own `.claude/` in place.** Its cases
  start in an empty workspace.
- **A store or API outside the repo** (Managed Agents memory): D18 and PM4 keep plain files in git.
- **Rewriting an agent or skill whole.** ACE's collapse; Probe-and-Refine's capped deltas.
