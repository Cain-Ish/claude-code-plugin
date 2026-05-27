---
name: upgrade
description: Detect installed plugin version vs the version in plugin.json, run idempotent migrations between them, and update the installed-version marker. Safe to run anytime — no-op when already at current version. Use after pulling a new plugin release.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Write Edit Bash(cat *) Bash(jq *) Bash(test *) Bash(date *) Bash(grep *) Bash(awk *) Bash(cp *) Bash(mv *) Bash(mkdir *)
---

# Plugin Upgrade

Idempotent migration runner. Reads the canonical version from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`, compares to `~/.second-brain/.installed-version`, and applies only the migrations between them.

## Steps

### 1. Read both versions

```bash
CURRENT=$(jq -r '.version' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
INSTALLED=$(cat ~/.second-brain/.installed-version 2>/dev/null || echo "0.0.0")
echo "Installed: $INSTALLED -> Current: $CURRENT"
```

### 2. Decide what to do

- If `$INSTALLED == $CURRENT` -> exit "already up to date"
- If `$INSTALLED < $CURRENT` -> walk migrations between them
- If `$INSTALLED > $CURRENT` -> exit with warning ("installed version is newer than plugin.json — did you downgrade?"). Offer to overwrite the marker.

### 3. Migration registry

Each migration is identified by its target version. Run only migrations whose target is `> $INSTALLED AND <= $CURRENT`.

> **Re-baselined to 0.11.1 (2026-05-24); historical rows pruned (2026-05-26).** The version was dropped from a misleading `2.x` to `0.11.1` (true maturity is pre-1.0). All pre-0.11 (`≤ 0.7.0`) and historical `1.x`/`2.x` rows have been **removed** — they were dead weight: the runner only walks targets in `(INSTALLED, CURRENT]`, and `INSTALLED` is always `≥ 0.11.1` post-rebaseline, so those rows could never fire. Fresh installs scaffold via `/second-brain:setup` + `ensure-dirs.sh`. **If the version ever re-crosses 1.0.0**, the pruned `1.x` history is in git — do NOT resurrect those rows; write fresh forward migrations instead.

| To version | Migration | Idempotent check |
|---|---|---|
| **vector-deps health** (re-runs every upgrade) | Smoke-import `@huggingface/transformers` from `$CLAUDE_PLUGIN_ROOT/mcp`. On failure, run `bash $CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh`. **Why**: mcp bundles mark `@huggingface/transformers` as esbuild `--external` because its native binaries (`onnxruntime-node`, `sharp`) can't be statically packed. A plugin cache refresh ships `dist/` but does not touch `node_modules/`, so vector search silently degrades to text-only on every fresh install or cache wipe. Without this gate the user sees no error — just empty embeddings and degraded recall. Idempotent: the script is a no-op when the package and import smoke-check both succeed. | `cd "$CLAUDE_PLUGIN_ROOT/mcp" && node --input-type=module -e 'await import("@huggingface/transformers"); console.log("ok")' >/dev/null 2>&1` — if exit 0, skip. Otherwise run `bash "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh"`; report the ~70MB network requirement before installing. |
| **0.14.0** | Current 0.x line (post-rebaseline; the runner compares by semver, so it only runs when upgrading into 0.14.0). New `/second-brain:code-review-deep` skill — multi-pass GitHub code review: review-unit decomposition + parallel Haiku `code-review-unit-reviewer` agents (cross-file bug hunting) + FP-aware `code-review-scorer`, with second-brain wiki/episodic context as input and a lazily-created false-positive store at `~/.second-brain/review-false-positives.md`. Also fixes `validate-plugin.sh` frontmatter parser (sed start/end range → awk that stops at the first closing delimiter, so a body `---` thematic break no longer leaks into parsed frontmatter and false-passes the required-field check). Fully additive — no state migration; the FP store is created lazily on first write. | No precondition. Bumping the marker is sufficient. |
| **0.15.0** | code-review-deep v2 — model follows the work: code units review on the inherited best model (was Haiku), docs units on Haiku; the `code-review-unit-reviewer` agent dropped its `model: haiku` pin so it inherits, and the orchestrator passes `model: "haiku"` only for `docs_only` units. New advisory architectural pass (one holistic `quality-reviewer` over the critical+high file union, rendered as a separate "Architectural notes" section, never scored or FP-recorded). Leak mitigations: parallel-dispatch wave cap (≤5 concurrent) + lean findings-only sub-agent returns. Port-audit fixes vs the upstream reference: dropped the contradictory `🤖` in the comment template, realized the Haiku delegation for Pass 0/1 mechanical steps, consistent "skipped as trivial" wording, refreshed the skill description. `context: fork` orchestration deferred — unsupported upstream (anthropics/claude-code#17283). Fully additive — no state migration. | No precondition. Bumping the marker is sufficient. |
| **0.15.1** | code-review-deep v2 review-fix pass (the skill dogfooded on its own change). (a) `docs_only` no longer misclassifies the plugin's own prompt/product trees (`skills/**`, `agents/**`, `tests/**`) as docs, and any `critical`/`high` unit is forced code-side — so a `SKILL.md` / agent `.md` change gets the best model, not Haiku. (b) Pass 2b architectural reviewer occupies one wave-1 slot (preserves the ≤5 concurrency cap) and is scoped to lines changed since `origin/<base>` (no pre-existing-issue false positives). (c) `quality-reviewer` Bash scoped to read-only git + `TodoWrite` dropped — trust-boundary hardening, since it reviews PR-influenced content. (d) Self-contained leak triage inlined in the skill Notes (no dependency on the spec file shipping). (e) Hardened the unit-reviewer "no model pin" test to top-level keys only. (f) Every model name (Haiku/Sonnet/Opus) qualified with the word "model" so the orchestrator never mistakes it for an agent name. Prompt/agent/test-only — no state migration. | No precondition. Bumping the marker is sufficient. |
| **0.15.2** | Episodic-embeddings degradation banner hardened (`session-load.sh` block 0b). It now ALSO fires the moment `node_modules/@huggingface/transformers` is absent from the plugin cache — the native dep that vanishes on every cache refresh (cache ships `dist/`, never `node_modules/`) — instead of only after >10 exchanges had already accumulated empty embeddings. The old index-state-only check stayed silent right after a refresh because the existing index still held its embeddings, so degradation went unnoticed until new exchanges rotted. Gated on an index already existing (fresh installs aren't nagged); still suppressible via `SB_EMBED_PENDING_BANNER=off`. New guard `tests/test-session-load-embed-banner.sh`. Hook/test-only — no state migration. | No precondition. Bumping the marker is sufficient. |
| **0.16.0** | Memory health: principled forgetting + recall eval (grounded in 2026 SOTA — SCM/SAGE forgetting, mem0 eval). New dream **Phase 6 FORGET** stages reversible archive moves (out-of-tree to `~/.second-brain/wiki-archive/`, never delete) for low-value / old / unlinked / recall-safe wiki pages — applied only on `dream_accept` with a post-consolidation re-score guard; kill switch `SB_WIKI_FORGET=off`. New offline scripts (no embeddings): `wiki-recall-check.sh`, `wiki-forget-score.sh`, `wiki-forget-candidates.sh`, `wiki-restore.sh`. New release-gate `tests/test-knowledge-eval.sh` (recall@2 + token budget over a fixture corpus) so retrieval quality is measured and forgetting can't silently regress it. `ensure-dirs.sh` creates the archive dir. Additive — no state migration. | Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/ensure-dirs.sh` (idempotent; creates `~/.second-brain/wiki-archive/`). Bumping the marker is sufficient. |
| **0.17.0** | Maintainer ↔ forgetting coordination. (a) Forget probe reads `tags:` (the maintained field) not the absent `keywords:`. (b) New `scripts/wiki-archived-slugs.sh` net-archived source of truth makes forgetting durable via AUTO-RESTORE: re-creating a forgotten slug revives the original instead of duplicating — extraction (`merge-project-update.sh`) mv+merges it; the wiki-write-guard restores + redirects to Edit. (c) `knowledge-maintainer` is archive-aware: honors the archive, restores-before-recreate, surfaces forget candidates, never archives (the dream stays the sole gated archiver). Un-archiving is un-gated (additive/safe); archiving stays gated. Fail-open on a missing/corrupt log. Prompt/script/test-only — no state migration. | No precondition. Bumping the marker is sufficient. |
| **0.18.0** | code-review-deep v2.1 — fix the gate, not the finder. (a) `code-review-scorer` un-pins `model: haiku` → inherits the session/best model, so the scorer matches the Opus reviewer it gates (removes the capability inversion that scored subtle finds "unverified" and dropped them). (b) The 16–69 confidence band is no longer dropped — it is surfaced in Pass 4 as a separate "Lower-confidence findings (unverified)" section, distinct from the numbered confirmed list and the architectural notes. (c) The false-positive auto-record ratchet is removed: the store grows ONLY from explicit user dismissals (a wrong auto-suppression would hide a real bug indefinitely). (d) Unit-reviewer reasons at `effort: high` (verified: `effort:` overrides session effort for dispatched subagents). Prompt/agent/test-only — no state migration. | No precondition. Bumping the marker is sufficient. |

### 4. Apply migrations

For each applicable migration:
1. State what it will do
2. Run the idempotent check
3. If safe, apply it (with backup if it touches user data)
4. Report success/failure

### 5. Update marker

```bash
echo "$CURRENT" > ~/.second-brain/.installed-version
echo "Upgraded $INSTALLED -> $CURRENT"
```

### 6. Re-run validation

After migrations, re-run the plugin validator if available:
```bash
test -x "${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh" \
  && bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh"
```

## Notes

- Migrations are intentionally minimal: most schema changes in this plugin are *additive* (new optional fields), so old data continues to work.
- Never delete or rewrite user data without explicit confirmation. The migration table is "what changed and how" — execution stays cautious.
- If a migration would be destructive, gate it behind `auto_improve: true` in `~/.second-brain/config.json` or explicit user confirmation.
- Future major versions (1.0.0+) may require interactive migrations. This skill is the place to add them.
