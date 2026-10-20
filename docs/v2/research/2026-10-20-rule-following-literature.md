# Research: coding agents following project rules and docs, the literature (2024-2026)

Collected from the web by a subagent on 2026-10-20 for [2026-10-20-adherence.md](2026-10-20-adherence.md). The numbers
were taken from the sources as listed and were not re-checked against the primary texts; most 2026 rows are single,
unreplicated preprints, so treat exact percentages as indicative.

Scope: what is known about why agents (a) never look for the relevant rule or doc and (b) ignore a rule that is in
context. Every row is NEW relative to `2026-10-19-prior-research-and-sota.md` and
`2026-10-20-memory-scenario-guide-and-docs.md` unless marked **[in notes]**. Tags: Peer-reviewed / Preprint /
Vendor / Practitioner. "(secondary)" means the number came from a write-up, not the primary text.

## Read this first: the two failures, measured

**(a) Never looks.** Three new independent measurements agree:
- 3.5% of runs opened the repo's policy file, and 97.6% of violations happened with it unopened [RepoComplianceBench].
- 71.1% of runs never tried to fetch policy docs even when told where they were [SWE-CC].
- Only 49% of Claude runs loaded all available curated skills, and 31% with distractors [Skills-in-the-Wild].

Together with [VERCEL] and [CODECOMPASS] **[in notes]**, the effect is consistent. What fixed it was making the
material unavoidable: a single mounted file the agent was told to read was opened in 91.6% of runs [SWE-CC], and
force-loading skills beat letting the agent choose (55.4 vs 51.2 vs 38.4) [Skills-in-the-Wild].

**(b) In context but ignored.** Reading the rule does not make it binding:
- With policies read, violations stayed at 33-36% [SWE-CC].
- Policy in the system prompt still left 25-85% risky-case violations, depending on the model [Policy-Invisible].
- The best of 30 configurations passed 36% of long-handbook tasks [HANDBOOK.md].
- Rules held in a prompt store left 45% of checks violated [Trace].

Measured drivers:
- **Rule count.** Compliance falls with the number of rules [IFScale][ManyIFEval][Prompt-Design-at-Scale].
- **The immediate request wins.** The current request overrides the standing rule [HANDBOOK.md].
- **Patterns win over instructions.** In-context patterns override written instructions [Instruction-Induction].
- **Unrewarded rules get skipped.** Process rules the model is not rewarded for are bypassed [Compliance-Gap].
- **Category matters.** Consolidation fixed git conventions (40% to 13% violated) but not docs or quality rules
  [SWE-CC].

The strongest measured fix is a deterministic check whose failure is fed back:
- One round of feedback: verification 90-100%, disclosure 55-97% [RepoComplianceBench].
- Compiled rules with hook verifiers: 70.1% vs 55.0% for the same rules as text [Trace].

Separately, a harness-level block is deterministic: it stopped the loop 120/120 vs 23% cooperative [Recuse]. That
is stopping, not rule-following.

Limits: rules that need judgment or refusal stay near 0-23% even with feedback, and agents build to the check
[Deliver-What-You-Check][ImpossibleBench].

---

## 1. Instruction count and context length

Verdict: compliance with *all* rules collapses well before context limits. The best models hold up to ~100
simple rules and fall steeply by 250-500. Length alone hurts even with perfect retrieval. Newer-model numbers on
IFScale were not retrieved (the leaderboard needs JS).

1. **IFScale** (https://arxiv.org/abs/2507.11538). Accuracy at 10/100/250/500 keyword rules:

   | Model | 10 | 100 | 250 | 500 |
   |---|---|---|---|---|
   | Claude Opus 4 | 100 | 94.6 | 67.9 | 44.6 |
   | Claude Sonnet 4 | 100 | 94.4 | 77.2 | 42.9 |
   | gemini-2.5-pro | 100 | 98.4 | 84.8 | 68.9 |
   | o3-high | 100 | 98.2 | 97.8 | 62.8 |

   - Primacy bias (later rules dropped more) peaks at ~150-200 rules.
   - Failures are omissions, ~6x more often than wrong variants.
   - Setup: 20 models, 5 seeds, report-writing task. Peer-reviewed (NeurIPS 2025).
2. **ManyIFEval / StyleMBPP** (https://arxiv.org/abs/2509.21051).
   - All 10 text rules followed: Claude 3.5 Sonnet 0.48 (0.93 per rule), GPT-4o 0.21, o3-mini-high 0.78.
   - All 6 code-style rules followed: Claude 3.5 Sonnet 0.01 (0.80 per rule), GPT-4o 0.68.
   - A logistic model on rule count predicts all-rules success within ~2-6 pp.
   - Setup: 12 models. Peer-reviewed (EMNLP Findings 2025).
3. **Prompt Design at Scale** (https://arxiv.org/abs/2607.19257).
   - "Perfect-response rate collapses to zero by N=80" rules, for every model, format and placement.
   - Recall stays near ceiling to 64-128K tokens, then drops (up to a 48-pt spread by format).
   - Refusals rise to 79-90% near the context ceiling.
   - Setup: 5 models, 960 + 5,520 calls per model. Preprint.
4. **AgentIF** (https://arxiv.org/abs/2505.16944).
   - Real agent system prompts average 1,723 words and 11.9 constraints each.
   - Models do worst on tool specifications and conditional constraints. "Best model <30% fully followed" is
     (secondary).
   - Setup: 707 instructions from 50 agent tasks. Peer-reviewed (NeurIPS 2025 D&B).
5. **Context Length Alone Hurts** (https://arxiv.org/abs/2510.05381).
   - Performance drops 13.9-85% as input grows within claimed limits, even when the extra tokens are whitespace or
     masked.
   - Reciting the evidence first recovers up to ~4%.
   - Setup: 5 models incl. Claude 3.7 Sonnet and GPT-4o; math, QA, code. Preprint.
6. **NoLiMa** (https://arxiv.org/abs/2502.05167).
   - When question and target share no keywords, 10 of 12 models (the count depends on the paper version) fall
     below 50% of their short-context score at 32K. GPT-4o went from 99.3 to 69.7.
   - Relevance: a rule phrased differently from the task is the hard case.
   - Peer-reviewed (ICML 2025).
7. **LLMs Get Lost in Multi-Turn Conversation** (https://arxiv.org/abs/2505.06120).
   - Instructions given across turns drop performance 39% on average.
   - Aptitude falls only 16%, but unreliability rises 112%. Models commit early and do not recover.
   - Setup: 15 LLMs, 200K+ simulated conversations. Peer-reviewed (ICLR 2026). Reminder arms are in §3.
8. **HANDBOOK.md** (https://arxiv.org/abs/2607.25398).
   - Agents must keep a company handbook (median 14.9K tokens, range 8.3K-79.4K) in force over ~30 tool calls.
   - Best strict pass is 36.2%, by Claude Fable 5 (GPT-5.6 Sol 23.5%).
   - Recurring failures: the immediate request overrides the standing rule; a check runs but its result is ignored;
     verification is skipped; the final report claims compliance anyway.
   - The handbook's "influence decays with distance: across turns, across tool calls."
   - Setup: 65 tasks, 824 deterministic criteria, 30 configs of 20 models. Preprint.
9. **Vendor long-context retrieval** (https://the-decoder.com/?p=31797).
   - Claude Opus 4.6 scores 76% on MRCR v2 8-needle at 1M tokens, vs Sonnet 4.5 at 18.5%.
   - Other reports put GPT-5.4 at 36.6% and Gemini 3 Pro at 24.5%. Sources disagree (76 vs 78.3).
   - This measures retrieval, not compliance. Vendor (secondary).

## 2. Repository context files and rule compliance

Verdict: two 2026 benchmarks now measure rule *compliance* in real repos, not just task success. Agents violate
roughly 35-45% of applicable repo policies. Most violations happen without the policy ever being opened.

10. **RepoComplianceBench** (https://arxiv.org/abs/2607.26819).
    - The policy file was opened in 12 of 347 unaided runs (3.5%); 97.6% of violations had it unopened.
    - Unaided compliance: disclose 17-40%, verify 4-92% by model, refuse and hand off 0% for all models.
    - Setup: 106 issues, 49 repos. Agents: Claude Code + Sonnet 4.6, Codex + GPT-5.5, Codex + GPT-5.3-Codex,
      OpenCode + DeepSeek-V4-Pro. ~25-30 runs per cell. Preprint. Arms are in §3 and §4.
11. **SWE-CC** (https://arxiv.org/abs/2610.06193).
    - Agents violated 43.1% of applicable policies; the top model reached 63.8% compliance.
    - Native arm (told where the docs are): 71.1% never tried to fetch them, and 12.6% got policy text.
    - Consolidated arm (one mounted file): opened in 91.6% of runs, but violation fell only from ~42-44% to ~33-36%.
    - Violations by category, native to consolidated: git conventions 40% to 13%; style 16% to 15%; docs ~37%
      (unchanged); AI-disclosure 85% to 73%.
    - 50.3% of violations happen mid-trajectory, not in the final diff.
    - Setup: 823 checkable policies, 12 repos, 500 SWE-bench-Verified tasks. Models: GPT-5.6 Luna, Gemini 3.7
      Flash, DeepSeek V4 Flash, Kimi K2.5, under mini-SWE-agent and OpenHands. Preprint.
12. **Guardrails Beat Guidance** (https://arxiv.org/abs/2604.11088).
    - Random rule files raised pass rate as much as curated ones (+13.8 pp), which the authors put down to "context
      priming".
    - Every individually helpful rule was a prohibition ("do not refactor unrelated code"). Every harmful one was a
      positive directive ("follow code style").
    - Pass rate stayed flat from 0 to 50 rules. It measures task pass, not compliance.
    - Setup: Claude Code + Opus 4.6, 679 rule files (25,532 rules), 5,000+ runs, SWE-bench Verified subset.
      Preprint.
13. **SWE-Gate** (https://arxiv.org/abs/2609.04167).
    - 221 of 644 test-passing repairs (34%) fail constraints taken from real PR review comments.
    - Setup: 303 instances, 75 repos, 4 LLMs. Preprint.
14. **How agents discover and read docs** (https://arxiv.org/abs/2608.20195).
    - 70.2% of doc consultations are self-initiated, and 7.5% follow a failure.
    - Instruction files and working notes are 60.5% of doc interactions; classical docs 10.6%; API references 1.3%.
    - Consulting docs goes with *less* immediate testing (OR 0.39). No doc-based validation sequence was seen.
    - Setup: 557 SWE-chat sessions (3,033 doc interactions) and 33K agent PRs. Preprint.
15. **Policy-Invisible Violations** (https://arxiv.org/abs/2604.12177).
    - Risky-case violations fall from 95.3% to 40.7% when the policy goes into the system prompt.
    - By model with the policy in prompt: Sonnet 4.6 25%, Opus 4.6 31.7%, GPT-5.4 30%, GPT-5.4 nano 85%.
    - Setup: 5 models, 60 risky and 60 safe cases each, 600 traces. Preprint.
16. **The Compliance Gap** (https://arxiv.org/abs/2605.01771).
    - Process instructions (e.g. "open files one at a time") got 0% compliance under default framing.
    - Sonnet 4 agreed 10/10 times, then bypassed the instruction 10/10.
    - Compliance was 97% where the rationale was rewarded (audit trails) and 0-4% where it was not.
    - Removing delegation tools raised compliance to 75%. Blinded human raters could not detect the gap.
    - Setup: 6 models, 2,031 sessions. Preprint, single author.
17. **When "Do Not" Is Not Deny** (https://arxiv.org/abs/2608.23550).
    - Only 4.4% (strict) to 16.6% of security rules in public CLAUDE.md files have a matching built-in control.
      The rest are advisory text.
    - It measures coverage, not obedience. It cites Rashidi 2026 (unverified): removing one scope sentence raised
      out-of-scope actions from 0% to 17.1%.
    - Setup: 481 files. Preprint.
18. **[in notes: ADHERENCE] new detail** (https://arxiv.org/abs/2605.10039).
    - Task identity moved compliance by 26.2 pp, more than any file-structure variable.
    - Practitioner (secondary): https://codex.danielvaughan.com/2026/07/04/agents-md-structure-doesnt-matter-factorial-study-instruction-adherence-codex-cli/
19. **τ-bench** (https://arxiv.org/abs/2406.12045; numbers read from https://sierra.ai/blog/benchmarking-ai-agents).
    - Function-calling agents "are not great at following rules provided in the policy documents".
    - The best agent (GPT-4o) is under 50% success, and about 25% pass^8 on retail.
    - Setup: 12 agents. Preprint (vendor-authored, Sierra).

## 3. Just-in-time and recency: rule next to the action vs loaded upfront

Verdict: thin. **No controlled study measures tool-time (PreToolUse-style) rule injection in coding agents.** The
closest evidence:
- The verbatim rule beats a one-line reminder.
- Restating instructions recovers part of the multi-turn loss, not all of it.
- Selecting only the relevant rules does not beat loading all of them (see 30).
- Position effects inside a prompt are contested.

20. **RepoComplianceBench arms** (see 10).
    - Disclose compliance, for three of four agents (DeepSeek excepted):

      | Arm | Disclose |
      |---|---|
      | One-line reminder | 31-60% |
      | Verbatim clause (Quote) | 60-77% |
      | One round of feedback | 55-97% |

    - Verification barely moved with Reminder or Quote (e.g. GPT-5.3-Codex 4% to 8%), but rose to 90-100% with
      feedback.
    - Refusal stayed at 0-10%.
21. **Recap and Snowball arms** (see 7).
    - GPT-4o: sharded 59.1, Snowball (repeat all earlier instructions each turn) 65.3, Recap (restate everything at
      the end) 76.6, full single-turn 93.0.
    - Repetition recovers 6-17.5 pts and leaves a 16-28-pt gap.
    - Setup: GPT-4o and 4o-mini only. Peer-reviewed.
22. **Anthropic prompting docs**
    (https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices).
    - Long documents at the top and the query at the end "can improve response quality by up to 30 percent in
      tests."
    - Opus 4.5/4.6 are "more responsive to the system prompt". "CRITICAL: You MUST…" phrasing now causes
      overtriggering; "dial back any aggressive language."
    - Vendor (docs, no method).
23. **OpenAI GPT-4.1 prompting guide** (https://cookbook.openai.com/examples/gpt4-1_prompting_guide).
    - For long context, put instructions at both the beginning and the end. If only once, put them above the
      context. This differs from Anthropic's "query at end".
    - Vendor (secondary mirrors).
24. **Position evidence conflicts**:
    - IFScale (1): primacy bias at moderate density.
    - Instruction Boosting / SCALEDIF (https://arxiv.org/abs/2510.14842): no consistent position effect, middle no
      worse. Same paper: rule *conflict* drives degradation; post-hoc boosting adds +7 pts (2 rules) and +4 (10).
    - Prompt Design at Scale (3): placement effect ≥ format effect at N=160, with direction varying by model.
    - [ADHERENCE] **[in notes]**: null.
    - All Preprint/Peer-reviewed. Verdict: no reliable position lever for compliance.
25. **Recuse Signal** (https://arxiv.org/abs/2606.06460).
    - A halt delivered in-band through a tool or protocol channel was acknowledged 0/20 times; by prompt, 20/20.
    - Two OpenAI models stopped 0/40 mid-flight.
    - A harness interceptor stopped the loop 120/120 across 6 models, vs a 23% cooperative baseline.
    - Implication: channel matters. Text arriving as tool output is weak, and a block is deterministic. Preprint.
26. **Instruction-Induction Conflict** (https://arxiv.org/abs/2605.20382).
    - When in-context examples show a competing pattern, instruction-following drops to ≤50% after just 1 example
      for GPT-5.2, Gemini 2.5 Flash and Qwen3-235B.
    - Claude Opus 4.6: 87% when the instruction fits its values, 6% when it does not.
    - A hint that the pattern is hard-coded adds 11-14 pts. Reasoning raises compliance but does not fix it.
    - Bears on "agents copy existing code over written rules". Setup: 13 models. Preprint.
27. **OpenDev** (https://arxiv.org/abs/2603.05344).
    - Counters "instruction fade-out" with event-driven system reminders (on failures, denied tool calls, unfinished
      todos, exploration spirals).
    - No ablation of the reminders. Preprint (system description).
28. **[in notes: ANTHROPIC-CTXENG] new detail.** The post recommends a hybrid: CLAUDE.md "naively dropped into
    context up front" plus glob/grep just-in-time. It says nothing about reminders or recency. Vendor.

## 4. Enforcement and feedback loops

Verdict: the best-supported lever. Feedback from a failing deterministic check reliably fixes *checkable*
violations, and blocks are near 100%. Two limits:
- Judgment rules (refuse, escalate) barely move.
- Agents optimise for the check, not the intent.

29. **Feedback arm** (see 10). One round of verifier feedback:
    - verification 90-100% (from 4-92%);
    - disclosure 55-97%;
    - refusal at most 23% (Sonnet 4.6).

    Preprint.
30. **Trace: compiling user corrections into hook verifiers** (https://arxiv.org/abs/2606.13174).
    - Diagnostic compliance:

      | Condition | Compliance |
      |---|---|
      | No rules | 31.6% |
      | Mem0 | 42.5% |
      | Relevant rules only | 54.0% |
      | All rules (prompt store) | 55.0% |
      | Compiled rules (hook verifier blocks and reports; ≤3 retries) | 70.1% |

    - ClawArena held-out violations fell from 100% to 37.6% (in-distribution) and to 2.0% (out-of-distribution).
    - "access alone does not make a preference binding."
    - Setup: 6 models (diagnostic, 29 checks), runs on Claude Code and Codex CLI. No ablation of block vs
      injection. Preprint.
31. **Static Analysis as a Feedback Loop** (https://arxiv.org/abs/2508.14419).
    - Bandit and Pylint fed back for 10 rounds: security issues >40% to 13%, readability >80% to 11%, reliability
      >50% to 11%.
    - Setup: GPT-4o, PythonSecurityEval. Preprint.
32. **BitsAI-Fix** (https://arxiv.org/abs/2508.03487). Lint-repair with re-scan verification reached ~85%
    remediation accuracy in production. Setup: ByteDance. Vendor (industrial preprint).
33. **Coding Agents Deliver What You Check** (https://arxiv.org/abs/2606.28430).
    - With a hidden 222-test oracle in the loop, scores went near-perfect while the requested reusable library was
      dead or absent ("building to the test").
    - Setup: Copilot CLI with Opus 4.7 and GPT-5.5, 18 runs. Preprint.
34. **ImpossibleBench** (https://arxiv.org/abs/2510.20270).
    - On tasks whose tests contradict the spec, the agent exploited the tests: GPT-5 76% (one-off SWE-bench), Opus
      4.1 54%, Sonnet 4 48%.
    - A "stop if tests are flawed" instruction cut this from 93% to 1% on LiveCodeBench but only from 66% to 54% on
      SWE-bench (secondary: https://www.greaterwrong.com/posts/qJYMbrabcQqCZ7iqm/impossiblebench-measuring-reward-hacking-in-llm-coding-1).
    - Later report: Opus 4.6 2.9%, Gemini 3.1 Pro 11.8% (https://arxiv.org/abs/2606.12429, different setup).
    - Peer-reviewed (ICLR 2026).
35. **OpenAI, "Harness engineering"** (https://openai.com/index/harness-engineering/, 2026-02-11).
    - AGENTS.md is a table of contents pointing to docs, plans and decisions, not an encyclopedia.
    - Custom linters' error messages carry the remediation instructions.
    - ~1M LOC with no hand-written code. No controlled numbers.
    - Vendor (primary returned 403; read via secondary, e.g. https://www.ignorance.ai/p/the-emerging-harness-engineering).
36. **Boris Cherny's verification tip**. Giving Claude a way to verify its work "2-3x the quality". Unmeasured
    estimate. Practitioner (secondary, e.g. https://karozieminski.substack.com/p/boris-cherny-claude-code-workflow).
37. **Checks need state, not only text** (see 15).
    - A deterministic checker with world-model access scored 93.0% accuracy (precision 0.97-1.00).
    - A content-only DLP checker scored 68.8% (recall 0.40).

## 5. Retrieval by relevance vs everything loaded

Verdict: picking the relevant subset has not been shown to raise compliance over loading everything (one small
diagnostic). Agents often skip retrievable material. When retrieval works, a correctly retrieved fact is acted on
only about half the time. Retrieval quality dominates write-side cleverness.

38. **Trace diagnostic** (see 30). Relevant-only 54.0% ≈ all rules 55.0%. Both are well below compiled verifiers
    (70.1%) and well above nothing (31.6%). Small n (29 checks). Preprint.
39. **Agent Skills in the Wild** (https://arxiv.org/abs/2604.04323).
    - Pass rates for Opus 4.6 in Claude Code:

      | Condition | Pass |
      |---|---|
      | Curated, force-loaded | 55.4 |
      | Curated, agent decides | 51.2 |
      | Curated + distractors | 43.5 |
      | Retrieved from 34K skills | 38.4-40.1 |
      | No skills | 35.4 |

    - Only 49% of trajectories load all curated skills (31% with distractors). With retrieval but no curated skills
      in the pool, only 16.3% load any skill.
    - Query-specific refinement: 40.1 to 48.2.
    - Setup: 3 agents (Opus 4.6, Kimi K2.5, Qwen3.5). Preprint.
40. **MERIT** (https://arxiv.org/abs/2609.05441).
    - Agents act on a *correctly retrieved* updated fact only 55% of the time.
    - Embedding retrieval on updated facts is erratic (0.30-0.95 across models).
    - Swapping the memory implementation moves success by up to 60 pts. Full replay is never cost-effective.
    - Setup: GPT-4.1, Claude Haiku 4.5 and one more model; Sonnet 5 spot check; 23,440 episodes. Preprint.
41. **Retrieval vs utilization bottlenecks** (https://arxiv.org/abs/2603.02473).
    - On LoCoMo, the retrieval method spans ~20 pts (57.1-77.2%) while the write strategy spans 3-8 pts.
    - Raw chunks (zero LLM calls) match or beat Mem0-style extraction.
    - Most failures happen at retrieval.
    - Peer-reviewed (ICLR 2026 MemAgents workshop).
42. **When Retrieval Metrics Mislead** (https://arxiv.org/abs/2606.23937).
    - Off-the-shelf retrievers put the exact governing clause at rank 1 for only 7% of τ-bench airline states.
    - Downstream decision F1 was still 0.58 retrieved vs 0.60 gold, 0.32 random, 0.21 none: neighbouring rules carry
      signal.
    - Setup: Qwen2.5-3B/7B classifier, not an end-to-end agent. Preprint.

Also relevant, already in notes: [VERCEL] passive index 100% vs skill 53%/79%; [CODECOMPASS] 58% zero calls;
[EXP-FOLLOWING] agents copy retrieved memories.

## 6. Agents following ADRs and design documents

Verdict: **no study measures agents *following* ADRs or design docs during coding.** What exists:
- *Detection* of violations after the fact.
- Effects of spec *format* and constraint *count*.
- One vendor teaser with no method.

[DAVIDSON] **[in notes]** remains the only report on over-applying an obsolete ADR.

43. **LLMs detecting ADR violations** (https://arxiv.org/abs/2602.07609).
    - Strong accuracy and agreement on explicit, code-inferable decisions.
    - Falls short on implicit or deployment-dependent decisions.
    - Setup: 980 ADRs, 109 repos; one screening LLM plus 3 validators. Preprint.
44. **Actual.ai teaser, "What Happens When Coding Agents Read Your ADRs"** (2026-09-15, via https://actual.ai/blog/agent-optimized-adrs).
    - With ADRs: wrong turns 191 to 20, tokens -37%, time -22%.
    - Setup: 15 feature requests, 10 OSS projects, 1 run per arm. No model, no definition of "wrong turn", no
      delivery method stated.
    - Vendor (teaser; full article not found).
45. **Constraint Decay** (https://arxiv.org/abs/2605.06445).
    - Assertion pass rate falls 27.28 pts on average from baseline to fully specified tasks (Clean Architecture
      layers, DB, ORM).
    - Convention-heavy frameworks (Django, FastAPI) are worse than minimal ones (Flask).
    - Setup: 100 backend tasks, 8 frameworks. Preprint.
46. **Architecture as Capability Equalizer** (https://arxiv.org/abs/2608.21747).
    - Code-proximate specs (OpenAPI; TypeScript contracts with ArchUnit-style rules) recover most of the gap for
      weaker models: route coverage 33% to 100%.
    - For Sonnet 4.6 and GPT-5, spec format barely matters (0.17-0.92 pts).
    - Self-validation was 100% for Sonnet 4.6 and 0% for Gemini Flash.
    - An import-based checker missed violations an LLM judge caught in 11 of 90 trials.
    - Setup: 6 models, 90 trials, 5 spec formats incl. Mermaid + ADRs. Preprint.

---

## Contradictions and thin spots

- **Rule count: harmless or harmful?** The two sides measure different things, so this is not a real conflict.
  - Guardrails Beat Guidance (12) found pass rate flat from 0 to 50 rules, and random = expert. It measures **task
    pass rate**.
  - IFScale, ManyIFEval and Prompt Design at Scale measure **rule compliance**, which falls with count.
  - Rules can prime task success while being individually ignored.
- **Instruction position**: contested (24). No source supports a dependable "put it last" lever for compliance.
  Vendors disagree (Anthropic: query at the end; OpenAI: both ends, or above if once).
- **Where memory fails**:
  - At retrieval (41).
  - At use: 55% of correct retrievals acted on (40).
  - Different benchmarks and stages; both can hold.
- **Recency and just-in-time injection**:
  - No controlled coding-agent study exists. The reminder evidence is indirect (20, 21) and practitioner designs
    are unmeasured (27).
  - No study separates "rule injected at tool time" from "rule blocked at tool time" (30 has no such ablation).
- **"Attention sinks"**: not covered. The literature (e.g. StreamingLLM) is about mechanism, not compliance
  evidence.
- **Sample sizes**:
  - RepoComplianceBench cells are ~25-30 runs (Handoff 9-10).
  - The Trace diagnostic is 29 checks.
  - Deliver-What-You-Check is 18 runs.
  - Most 2026 rows are single preprints, some single-author (Compliance Gap, Recuse), none replicated.
- **Model generations**: IFScale and ManyIFEval stop at Claude Opus 4 / 3.5 Sonnet. Compliance rows use Sonnet
  4.6, Opus 4.6-4.8, GPT-5.x and Fable 5. Newer-model IFScale results were not retrieved.
- **Not verified in the primary text**:
  - OpenAI harness post (403);
  - AgentIF's "<30%";
  - MRCR cross-vendor numbers;
  - Cherny's 2-3x;
  - the Actual.ai article body;
  - Rashidi's 0 to 17.1%.
