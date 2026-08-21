# Solution menu — ranked, with theory obligations, effort, and what each does NOT solve

Companion to `../SKILL.md`. The plan
(`archive/docs:docs/superpowers/plans/2026-06-30-p6-quarantine-dual-llm.md`) already chose the ranking; this
table records WHY, so a future author who wants to deviate must first discharge the theory
obligation and reconfirm with the maintainer (route via **sb-research-methodology**), not silently
swap approaches.

The threat model all options are scored against: the **lethal trifecta** = untrusted input +
private-data access + an exfil/persistence channel, co-located in one context. The monolithic
`maintain-llm-drain.sh` holds all three. Domain theory: **sb-memory-systems-reference**. Paper
lineage: CaMeL (2503.18813) + Willison's lethal-trifecta framing (borrow ledger:
**sb-external-positioning**).

---

## 1. Deterministic netless writer — CHOSEN (the shippable primary)

- **What:** the privileged write stage is a pure Node CLI (`consolidate-writer-cli`), no LLM, run
  under bwrap `--unshare-net`. All LLM judgment lives in the one quarantined summarizer. Target
  resolution (ADD/UPDATE/NOOP, mem0-style) uses the LOCAL `knowledge-search` bundle (BM25 + local
  ONNX, no network).
- **Why it wins:** the ONLY design that delivers a genuinely network-severed privileged stage with a
  SIMPLE kernel boundary (`--unshare-net`, no proxy plumbing), and it is more reversible/testable
  (deterministic = reproducible, idempotent by content hash).
- **Theory/derivation obligation:** prove the local reconcile needs no network (BM25 + local ONNX,
  `SECOND_BRAIN_DISABLE_EMBEDDINGS`-respecting); prove idempotence (a re-run over the same
  candidates + staging yields no diff); prove every write is `assertWithin`-guarded.
- **Effort:** the bulk of the campaign (Task 3 writer + Task 4 orchestration).
- **Does NOT solve:** LLM-quality dedup-MERGE prose + theme/reflection **authoring** on the
  unattended path — deferred to attended `/second-brain:maintain` (the knowledge-maintainer, already
  gated to explicit invocation). This is the spec-budgeted **~7-pt CaMeL utility cost**, recoverable
  any time via `/maintain`. The deterministic redundancy/cluster/forget-candidate/reindex still run;
  only new theme/reflection prose is skipped unattended.

## 2. Summarizer/writer dual-LLM split — the enclosing CaMeL architecture

- **What:** only the quarantined summarizer (`agents/dream-summarizer.md`, network up for the API)
  ever reads raw transcript text, as DATA; it emits structured, provenance-tagged candidate facts.
  The privileged writer never has the transcripts directory mounted.
- **Why:** breaks two trifecta legs BY CONSTRUCTION — transcript isolation (a poisoned instruction
  can never reach the context that writes memory) + network severing on the write stage.
- **Theory/derivation obligation:** show the writer's context can never contain transcript text
  (kernel: transcripts not mounted in Stage B; test-asserted the code references no transcripts
  path). Show the summarizer is write-isolated (binds only `candidates/`) and wiki/secret-isolated
  (no live wiki, no `~/.claude` beyond the ro credential).
- **Effort:** Tasks 1-4 together.
- **Does NOT solve:** the summarizer's OWN residual egress — it keeps network to reach the API while
  seeing untrusted transcripts. Bounded by write-isolation + wiki/secret-isolation + P6a/P6b
  sanitization of what it reads; the residual is addressed only by option 3.

## 3. Opt-in deny-proxy for the summarizer — DEFERRED (documented only)

- **What:** a selective-egress allowlist (model endpoint only) for the summarizer stage, behind
  `SB_MAINTAIN_LLM_DENY_PROXY`.
- **Why deferred:** selective egress inside bwrap requires a network namespace + a loopback-bound
  forward proxy or nftables — materially more complex and OS-fragile. The spec marks
  trifecta-severing "opt in", and the netless deterministic writer already severs network where it
  matters (the write stage). This is a future hardening of the summarizer's residual egress, NOT
  part of the shippable slice.
- **Theory/derivation obligation (if ever built):** demonstrate the allowlist actually blocks
  non-model egress under bwrap; prove it degrades safely when the proxy is unavailable (fail the run
  loud, not silently unconfined).
- **Effort:** M-L, mostly OS-fragility and testing across Linux distros.
- **Does NOT solve:** anything the netless writer already covers; it only tightens leg-2 residual on
  the summarizer.

## 4. Auto-accept with a reversibility window — the autonomy capstone

- **What:** combine the Task-5 confirm-gate (untrusted-only NEW pages held in `held-untrusted/`,
  never deleted) with the EXISTING safety floor — the 5 accept guards (symlink-escape reject,
  ≥50% staging floor, safe-mode no-delete, fail-closed pre-accept tarball, post-snapshot page
  protection) + reversible FORGET archive — so `auto_accept` can advance from `safe` toward `all`
  for CORROBORATED changes while conjured-from-nothing pages are quarantined.
- **Why:** delivers the constitution's "safety comes from reversible auto-consolidation … not a
  manual gate" — every destructive step is staged, reversible, provenance-tagged.
- **Theory/derivation obligation:** the falsifiable criterion (SKILL.md V4/V7) — N dream→auto-accept
  cycles with zero human input AND zero unreviewed destructive ops AND a passing rollback drill.
  Never claimed by eye.
- **Effort:** Task 5 (S-M) + the live N-cycle demonstration (operator-run on Linux+bwrap).
- **Does NOT solve:** the summarizer egress leg (pair with 1+2); and note the OPEN audit gap that
  `auto_accept=all` / direct MCP `dream_accept` currently DROP the FORGET manifest — promotion must
  not assume FORGET applies automatically (see **sb-failure-archaeology**).

---

## Rejected outright (do not re-propose without maintainer sign-off)

| Rejected path | Reason |
|---|---|
| Blanket `--unshare-net` on the whole maintainer | Bricks the API-dependent summarizer; "both stages cannot be `claude -p` AND have the writer run netless" (plan:82). |
| Two-LLM writer (privileged `claude -p` writer behind deny-proxy) | Preserves LLM dedup/theme quality at the cost of the netless property + proxy complexity; documented-not-built (plan:537-539). |
| Rewrite / migrate to hermes | Strategy-rejected: "a second from-scratch rewrite would re-accrete (v1.0 proves it)"; owned by **sb-external-positioning**. |
| Keep a human review gate as the safety mechanism | Contradicts CONSTITUTION.md:42-45 autonomy constraint; safety must be by-construction. |
| macOS/Windows kernel sandbox for the unattended path | The unattended path does not run there today; deferred with the rest of the cross-OS sandbox question (plan:544-545). |
