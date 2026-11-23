# AI Native DevCon 2026 London: what a project's second brain should take

**Asked (2026-11-23):** the user asked for a deep research of AI Native DevCon 2026. There were two aims:
- find the presentation in which Lamis Mukta live-codes how Anthropic engineers build, instead of prompts, dedicated
  project agents, a graph, telemetry and a self-improving loop;
- collect anything else the plugin should take from it: the logic of a project's second brain and how the agents
  system is built. Nothing over-engineered.

**Sources.** Tessl publishes the conference as one folder per talk:
`https://tessl.io/registry/ainativedev/aidevcon-2026-ldn/0.100.14/files/<talk>/` holds `outline.md`, `quotes.md` and a
speech-to-text `transcript.md`. There are 42 talks. The registry states no dates.

**Method.**
- Lamis's transcript was read in full by a fetch subagent.
- The other 41 talks went to agy (Gemini 4 Argon) in sweeps. Seven batches answered. Three timed out twice, and their
  12 talks were read by a fetch subagent instead (outlines and quotes for all 12, transcripts for four).
- The quotes this note rests on were checked against the files. Two of six agy claims were not in the talks and are
  left out: an "activation, trajectory, outcome" framing for evals, and invisible characters as an injection route.

## 1. The talk the user described

**Not found in the conference's published text** (the limits are at the end of this section).
- **Lamis's talk** (`talk-lamis-context-engineering-dreaming`; the files give only her first name) has no live coding
  or demo, no graph, no named telemetry, and no project-specific agents. It covers context engineering, memory in
  production, and dreaming: "the orchestrator deploy a fleet of sub agents that go and analyze what those
  transcripts", whose output "you as the individual. Can decide where you want to accept". The research of
  2026-11-20 already maps it.
- **The closest talks**, each with part of the description:
  - **Brian Douglas (Paper Compute), "Training AI on your own code".** Tapes is "an open source telemetry proxy that
    intercepts LLM API calls and builds a content-addressable Merkle DAG of every conversation turn" (the outline's
    abstract). The transcript shows sessions turned into skills, with a human to "go clean up like the skill
    itself", and telemetry to "identify how often it gets invoked or whether it's working". It has a brief UI
    showing, but no live coding.
  - **Ryan Lopopolo (OpenAI), "Harness engineering".** His review agents are "a curated set of review personas that
    are essentially bulleted list of guardrails". As an aim, he would collect "every review comment, every time you
    have had to interrupt the agent" and "dream over it every night".
  - **Paul Stack, "Humans architect, AI writes code".** A planner agent writes the plan, and an adversarial reviewer
    checks it for at most five rounds before a human arbitrates. His instruction file tells the agent: "if you hit a
    non-obvious problem during a session that's going to trip up future users ... record it and propose an update."
  - **May Walter (Hud), "Runtime intelligence".** Production telemetry, "a sensor that runs with your app in
    production", feeds a weekly repo agent.
- **The other leads, checked on 2026-11-23:**
  - Tessl's second registry, `latest-aidevcon-speakers-london-2026` (0.1.6), holds the same 42 talks.
  - The event ran on 1 and 2 June 2026. Its agenda ([luma](https://luma.com/aidevcon-ldn26)) lists "live demos" on
    day 1, and "Workshops & Unconference sessions" on day 2. It gives no titles or speakers, and neither registry
    holds the workshops.
  - [Tessl podcast 113](https://tessl.io/podcast/113), "Inside Anthropic: How Claude Tag Is Changing Agentic Work"
    (7 July 2026), is the only other source with Lamis Mukta. By the page's summary, she describes Claude Tag, an
    agent "with its own permissions and its own keys, scoped per channel", and dreaming as "a review pass over
    session transcripts and memory stores" that a person approves. The summary names no graph, telemetry or demo.
    The [video](https://youtu.be/7Ue0yM4J-B8) was not watched.
  - The Code with Claude 2026 London workshop "Build a production-ready agent with Claude Managed Agents" (19 May
    2026) is a live build, by Michael Cohen of Anthropic, not Lamis.
- **Limits of this search:** most talks were read by their outline and quotes, not their whole transcript; Trieloff's
  live demo is redacted in the files; the day-2 workshops and the podcast's video were not seen. So "not found" means
  not in the published text. The talk may be one of the day-2 workshops, or the podcast. The user can supply the
  link.

## 2. What the talks confirm in v2 as it is

- **Plain Markdown memory in the repo, readable by any harness.** Douglas: "transfer the skills over" between
  harnesses. Lübken's embedded agents keep Markdown memory files. (Both are agy's reading, not checked.)
- **A human gate on every memory change.** Douglas's human cleanup; Walter: "If something works 90% of the time, it's
  not an automation". Syme's repo agents run "read only no secrets and very narrow safe outputs". In v2, D30's
  `proposed:` line waits for `/map-review`.
- **Staleness flagged, not trusted.** Sloan: design context "by its nature falls out of sync with the code base over
  time". This is D16 and D30.
- **Lean always-on text.** Jones: "You're better off having no instructions in your agent's MD then lots of them";
  Böckeler on attention. This is D18's budget.
- **Mining corrections and repeated failures.** The dream's analyzer already has the kinds `correction` and `failure`
  (D31).
- **Agents built around the project's rules,** not general prompts. Lopopolo's personas are lists of guardrails;
  Batey: "Agents are really really good at reviewing implementations against a well structured" record. This is
  `decision-checker` over the project's recorded decisions (D29).

## 3. Candidates: logic only, each small

Each candidate names the decision it touches. None reopens anything on its own (rule 3).

**K1. Usage evidence from the transcripts the dream already reads.** This is the talks' telemetry and self-improving
loop, without new infrastructure. Sources: Douglas, tracking "how often it gets invoked or whether it's working";
Lopopolo, collecting interruptions.
- *What:* for each map entry and each rule, the dream's report counts the sessions that read it, and those where a
  correction on the same topic came after the read. Two signals follow:
  - "never read in N sessions": the index or the title does not lead Claude to it;
  - "read, then corrected again": the wording does not hold Claude to it.
- *Touches:* D31 (prepare already parses the transcripts; the counts are deterministic), D32 (the status report), D30.
- *Decider:* evidence. *Smallest check:* run the counts over a field repo's transcripts, and see whether they name
  entries the user agrees need work.

**K2. A self-update line in the capture instruction** (Stack). Claude also records "a non-obvious problem that will
trip up future sessions", as a proposal.
- *Touches:* D14's frozen instruction, which fires D16's "the capture instruction changes", so it needs a re-check
  like 06's 2s. It overlaps the dream's `correction` and `failure` kinds, which catch the same thing after the session.
- *Decider:* the user.

**K3. `decision-checker` grounded on the code before the change, and adversarial.**
- *Sources:* Azriel: "if we give the agent the base branch and the base code and not the diff, we're getting better
  results", because a diff biases it "to the specific solution that the engineer choose to implement". Stack's
  reviewer that does not trust the code.
- *What:* the template tells the agent to read the bearing decisions and the code as it was before the change, and
  only then the change, and to look for the way it breaks a decision.
- *Touches:* D29's templates. *Check:* S5's agent outcome bar, re-run (5 runs).

## 4. Not taken

These reject only the variants seen in these talks. The user's ask (dedicated project agents, a graph, telemetry and
a self-improving loop, as Lamis showed them) stays open until its source is found and read.
- **Douglas's graph of sessions** (a Merkle DAG). Git and Claude Code's own transcripts already hold the record, and a
  second store is what v1's postmortem warns about.
- **Douglas's telemetry proxy** on the API path. It needs the network, and it sits between the user and the model
  (D18).
- **Nightly or scheduled dreaming** (Lopopolo's aim). See D33: option (B) was rejected on 2026-11-23.
- **Fine-tuning on sessions** (Douglas) and **fine-grained agent hierarchies.** Marsden's case is for few,
  coarse-grained agents (agy's reading, not checked).
