# Positioning one-pager template

Fill-in template for external-facing positioning text (README section, blog post, paper
related-work block, marketplace listing). Governed by `../SKILL.md`: every claim must map to
its §2.1 defendable ledger or carry a §2.2 status label; when this template and the ledger
disagree, the ledger wins. Replace ALL-CAPS placeholders; delete guidance blockquotes before
publishing. Re-run the SKILL.md Provenance commands first — statuses drift.

---

## HEADLINE

> One sentence, capability-honest. Pattern: "<what it is> that <the one defendable
> differentiator>". Do not use: "SOTA", "learns", "fully autonomous", "injection-proof"
> (see SKILL.md §2.2).

PROJECT_NAME is a local-first memory plugin for Claude Code: it captures what a session
decided, consolidates it in the background, and injects a token-budgeted mental model of the
project at the next session start.

## What it does (3 bullets, mission triad)

- **Orientation** — a per-project hot tier (PROJECT.md + wiki + episodic recall) injected
  just-in-time, so the model starts oriented instead of re-deriving the repo by grep.
- **Compounding personalization** — captured decisions and grounded practice pages
  (reflections cite the memories they distill from) accumulate per user and per project.
- **Guardrails at tool-time** — deterministic PreToolUse rules (ask/deny/rewrite) with an
  audit log, kill switches, and self-edit protection.

> Source: CONSTITUTION.md mission triad. Keep bullet 3 rule-based in wording — the learned
> pipeline (P2) is planned, not shipped.

## How it differs (comparison block)

> Name the axis, never the winner. Credit borrows explicitly — honest borrowing is the
> credibility strategy. One row per system you mention; drop rows you don't need.

| vs | Their approach | This project |
|---|---|---|
| mem0 | LLM-resolved ADD/UPDATE/DELETE/NOOP over a vector store | deterministic MinHash ADD/UPDATE/NOOP at capture; DELETE replaced by reversible archive-and-restore |
| Letta / MemGPT | model self-edits memory via in-band tool calls | hook-driven capture + timer-driven consolidation — guaranteed by the harness, not the model's discipline; model-agnostic local files |
| Zep / Graphiti | bi-temporal knowledge graph service | same validity model (assert/invalidate, `supersedes`), borrowed with credit, as a dependency-free local JSONL log |
| GraphRAG | graph as a retrieval tier | measured the graph ranking boost on the real corpus (96 pages/170 edges: 6 improved / 6 degraded / 80 unchanged), demoted it to opt-in-off; graph kept for blast-radius + supersedence only |
| ChatGPT memory | passive recall bolted onto chat | memory that acts: injected orientation + tool-time guardrails + reversible forgetting |

## Claims (copy only what the ledger currently supports)

As of VERSION (DATE):

- Rule-based tool-time guardrails with an audit trail (shipped).
- Bi-temporal history — invalidate, never delete; every eviction reversible (shipped).
- Surface-budget-governed codebase: skill/agent/script/test counts cannot grow without a
  same-commit, git-blameable budget bump (shipped).
- Deterministic offline floor: no embeddings, no network, no native deps required; CI runs
  fully offline (shipped).

What we deliberately do NOT claim yet: benchmark recall numbers (eval suite planned, P8);
learned guardrails (planned, P2); fully-autonomous consolidation (open, P6); reranked
retrieval (candidate, P3b).

> The "do not claim" paragraph is load-bearing — it is what makes the rest credible. Keep it.

## Reproduce it

```bash
git clone REPO_URL && cd REPO_DIR
cd mcp && npm ci && npm test && cd ..     # offline-deterministic vitest suite
bash tests/run-all.sh                     # bash behavioral suite
bash scripts/validate-plugin.sh           # gates incl. the surface-budget ratchet
bash tests/test-knowledge-eval.sh         # retrieval regression gate (recall@2 = 1.0)
```

> Every published number must be reproducible by one of these commands or carry its own
> file:line/command provenance inline.

## Stamp

Written DATE against version VERSION (`jq -r .version .claude-plugin/plugin.json`).
Statuses re-verified with the SKILL.md Provenance commands on DATE.
