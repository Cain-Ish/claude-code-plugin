# Deep-dive improvement plan — second-brain + cost-router (2026-06-10)

**Status:** draft — awaiting user review
**Method:** 17-agent dynamic workflow (`wf_9a15f793-71d`): 6 subsystem explorers + episodic
pain-point miner → per-area adversarial verifiers → 3-lens strategy panel
(reliability/autonomy, product value, simplicity/maintenance) → completeness critic.
63 findings; 59 confirmed, 2 refuted, 2 deliberate-and-tracked. All evidence verified
live on this box (second-brain 0.24.37, cost-router 0.1.1, Pi 5, subscription OAuth).
Full per-finding evidence (file:line + verifier verdicts), strategy texts, and critic
gaps: `docs/specs/2026-06-10-plugin-deep-dive-findings-appendix.md`.

## How to read this

Work is grouped into **9 waves (R1–R9)**, each shippable as one or two releases under the
existing discipline (version bump lockstep + migration row + deep-review gate + green
suite). Order within P-levels is the recommended sequence — R1/R2 unblock measurement
for everything later. Effort: S = hours, M = a day-ish, L = its own design cycle.

| Wave | Theme | Priority | Effort | Headline |
|---|---|---|---|---|
| R1 | Extraction loop stops wasting itself | P0 | S+M | kills 169 ec=124 timeouts, 95%-duplicate archives, 435MB junk transcripts |
| R2 | Search serves the right page | P0 | M | fixes ~10,000x hub-boost score corruption + silent embedding death per release |
| R3 | Security follow-ups | P0/P1 | S+M | closes the missed G-MCP-1 entry point + agent blast-radius |
| R4 | Dreams/auto_maintain actually run unattended | P1 | M | auto_maintain currently has a 100% structural failure rate |
| R5 | cost-router: honest pipeline, then keep-or-kill | P1 | S+M | plugin was never installed; learning loop broken end-to-end |
| R6 | Token & surface diet | P1 | M | 44K-token upgrade skill, duplicated vendored skills, dead scripts |
| R7 | Observability & self-healing (`sb doctor`) | P1/P2 | M+L | banners that fix instead of nag; served→used retrieval metric |
| R8 | Release/process hardening | P2 | S+M | CI backstop, bundle gate, drift gates, surface budget |
| R9 | Data-plane integrity & privacy | P2 (one item P1) | M+L | backup/restore, index atomicity, transcript redaction, injection audit |

What is **good** and stays untouched: fail-soft exit-0 hook discipline, single-flight
locking with stale-steal, drainer quarantine-after-3, tmp+mv atomicity in bash, the
layered PreToolUse guard architecture, the meta-test culture (109 shell + 464 vitest
green in 2m36s on the Pi), cost-router's portable bash quality, and the eval scaffolding
(`wiki-recall-check.sh`) that R2 builds on.

---

## R1 — Extraction loop stops wasting itself (P0)

The single highest-leverage wave. Root cause of nearly all observed runtime waste: the
OAuth drainer's headless `claude -p` spawns re-enter the **full plugin stack** (hooks +
MCP, ~24s on the Pi) against a 25s default timeout — all 169 `ec=124` kills, 247 nested
session-load firings, 60%+ of error-log volume, 435MB of junk transcripts in
`~/.claude/projects/-home-cainish`. Independently, `stop-extract.sh` clears the
extraction marker on every Stop firing, so one session was re-archived 18× into a
2.9MB / 95%-duplicate archive the drainer then fed whole to the extractor.

### R1.1 Nested-spawn circuit breaker (S)
- Export `SB_NESTED_SPAWN=1` around the `claude` invocations in `sb_call_extractor`
  (`scripts/lib.sh:771`) and `scripts/maintain-llm-drain.sh`; add a 2-line early-exit
  guard in the shared lib.sh hook-entry path so every hook no-ops when it's inherited.
- Raise the drainer-path `SB_EXTRACT_TIMEOUT` default (`lib.sh:1087`) to ≥120s (it runs
  out-of-band, no hook budget) and have `install-extract-timer.sh` write
  `Environment=SB_EXTRACT_TIMEOUT` into the systemd units.
- Run drainer spawns with cwd in a dedicated scratch dir so junk transcripts concentrate
  in one prunable project dir.
- Test: invoke each hook entry script with `SB_NESTED_SPAWN=1`, assert immediate exit-0
  and no log writes.

### R1.2 Idempotent capture (M)
- Key the extraction marker by **session_id** (stop-extract.sh already reads it at :243)
  and set it to TOTAL_LINES after processing, mirroring `pre-compact.sh:194`; clear only
  when the session transcript disappears (fixes HOOK-1, also removes the two-sessions-
  same-project race).
- `sb_archive_transcript` records last-archived line per session → disjoint appends.
- Cap extractor input in `sb_extract_transcript` (~200KB tail of newest exchanges), or
  pre-gate oversized archives to `outcome=error reason=too-large` (HOOK-4).
- Fast-path archives with <1KB post-header body to `outcome=ok reason=too-small` without
  spawning — covers the 50 pending 378-byte subagent stubs (HOOK-5); also make
  `subagent-capture.sh` skip capture when the final assistant text is an interim holding
  message before a structured return.
- Align PreCompact budgets: inner extract timeout ~30s vs 45s hook budget (HOOK-10).

### R1.3 episodic_read path guard (S — security, do not defer)
`episodic_read` does `fs.readFile` on a model-supplied absolute path with **no**
`assertWithin` — the one G-MCP-1 entry point the v0.21.0 hardening commit (4837873)
missed; gap analysis listed it explicitly. Guard with the existing `path-guard.ts`
helper scoped to `${BRAIN_DIR}/transcripts`, plus traversal/symlink tests mirroring the
knowledge-fetch ones. (MCP server change → server version bump.)

**Acceptance:** error-log shows no new `ec=124` for a week of normal use; one session's
repeated Stops produce one disjoint archive; transcripts dir stops growing with stubs;
a traversal attempt on episodic_read returns a guard error.

---

## R2 — Search serves the right page (P0)

Live, reproduced: `knowledge_search('plugin hardening gap analysis…')` returns a hub
page at score 1,329,612 while the page whose **title literally contains the query** is
absent from top-8 (scoped to 'security' it wins at ~113). Root cause:
`knowledge-search.ts:177-205` mutates `target.score` **in place while iterating**, so
boosts compound geometrically through hubs (architecture-v1: degree 68; 538/603 edges
are weak migration-generated `relates`); the `MIN_SCORE_RATIO` floor is then computed
from the inflated top score and evicts every honestly-scored page. This corrupted
ranking is what `persona-context.sh` injects into **every prompt**. Separately, every
version bump silently breaks embeddings (missing `mcp/node_modules` symlink — confirmed
on 0.24.35/0.24.37; 58/894 exchanges unembedded) and both search tools fall back to
BM25-only with no flag.

### R2.1 Hub-proof ranking (M)
Compute all boosts from a frozen snapshot of pre-boost base scores; cap total received
boost per page (≤1× its own base score, or divide contributions by source out-degree);
apply `MIN_SCORE_RATIO` to base scores; down-weight `relates` edges.

### R2.2 Eval that can see this class (S)
- Hub-distractor fixture: dense `edges.jsonl` cluster in `tests/fixtures/eval-wiki` +
  golden queries where a title-matching page must beat a high-degree hub at recall@2
  (today's fixture: 10 pages, zero `related:`, no edges — exercises none of the boost
  paths, which is exactly why this shipped).
- Live-wiki probe mode in `wiki-recall-check.sh`: auto-generate exact-title golden
  queries from real page titles (invariant: a page's own title returns its slug in
  top-2); runnable from `/second-brain:lint` and the dream FORGET phase.

### R2.3 Honest output contract (S)
Emit `tier` per candidate, rank-normalized scores on one scale, and
`degraded: 'bm25-only'` when `embedTexts` returns null (both knowledge_search and
episodic_search); rewrite the stale `server.ts:68` tool description (still claims plain
BM25 — predates RRF, graph boost, ai-block field, SP-1 tiering).

### R2.4 Embeddings that stay alive (S)
In `session-load.sh` block 0b: when transformers are missing **and** shared deps exist
**and** the deps-key matches, run `install-vector-deps.sh` automatically — that path is
a pure local symlink (the design doc's consent gate was for the ~70MB download, which
stays consent-gated). One-shot backfill of the 58 unembedded exchanges; add an
embedding-coverage % line to `/second-brain:status`.

**Deliberately deferred:** SP-1 slot interleave (MCP-SCOPE-1) — the starvation evidence
is confounded by the hub bug; re-measure with the golden-title probe after R2.1 and only
then decide (also run the existing `project:` facet backfill on the plugin's own pages).

**Acceptance:** golden-title live probe green on the real wiki; the gap-analysis page is
top-2 for its own title; coverage line shows 100%; next version bump does not break
embeddings.

---

## R3 — Security follow-ups (P0 item shipped in R1.3; rest P1)

- **G-MCP-2 / G-MCP-3 — decide, don't drift (S):** bundle SHA pin (stamp sha256 of
  `dist/*.bundle.js` at build, verify at session-load/ensure-dirs) is S-effort and fits
  the supply-chain P0; the read-only/mutation server split is plausibly YAGNI for a
  single-user stdio server. Either implement or record an explicit deferral in the wiki
  so audits stop re-flagging both (currently: no closure, no deferral record anywhere).
- **Agent blast-radius (M):** dream-runner + knowledge-maintainer hold `Bash(rm *)`,
  `Bash(mv *)`, `Bash(cp *)` + unrestricted Write/Edit while consuming mined transcripts
  (prompt-injection surface); staging-only discipline is prompt-level and **no**
  PreToolUse guard covers destructive Bash against the live wiki (wiki-write-guard only
  matches Write|Edit|MultiEdit; persona-tool-guard reads `file_path`, Bash sends
  `command`). Route destructive staging ops through a small path-checked
  `scripts/dream-fs.sh` and grant only that, or add a Bash deny-guard for
  `~/knowledge/wiki` + brain-dir targets from subagent context.
- **cost-router /setup grants (S):** drop `Bash(rm *)` (used nowhere in the flow) and
  scope `mv` to the settings-file pattern.

---

## R4 — Dreams and auto_maintain actually run unattended (P1)

`auto_maintain=true` has a **100% failure rate** on this box and nobody knew: the
systemd unit sets `RestrictNamespaces=true`, which makes the bwrap jail that
`maintain-llm-drain.sh` requires physically impossible (reproduced, exit 1). The
failure leaves dreams stuck at `status=pending` with `error:null`, stderr discarded —
the exact `drm_20260607T161658Z` you hand-rescued — and the pre-stamped weekly throttle
burns the 7-day slot on a <1s structural failure. Failed/canceled dreams are invisible
everywhere and their ~1.1MB staging is never pruned.

- Preflight bwrap probe **before** staging; on failure, log the named cause and skip
  without creating a dream.
- Reconcile sandbox layers: drop `RestrictNamespaces` from the OAuth unit with a
  documented trade-off (bwrap is the containment there) or run the maintainer from a
  sibling unit without that directive.
- On rc≠0: capture stderr tail into `sb_log_error`, tmp+mv status `pending→failed` so
  dream_list/status/autostage reflect reality.
- Failure-aware throttle: keep the anti-spam pre-stamp but re-stamp to a ~24h retry on
  failure; `.llm-maintain-fails` counter quarantines after 3 with one persistent banner
  (mirrors `SB_DRAIN_MAX_FAILS`).
- Surface failed/canceled dreams in the autostage scan + dream skill; prune terminal
  dreams past `dream_keep` (delete `staging/`, keep `status.json`).
- Decouple retention GC from `auto_improve` (`bak_ttl_days` is silently inert today
  because GC only runs on the auto_improve path).
- Integration test: run the probe under `systemd-run` with the unit's actual properties.

**Acceptance:** with auto_maintain on, a scheduled run either completes a dream or
produces a visible `failed` status with a captured error — never a silent pending.

---

## R5 — cost-router: honest pipeline, then keep-or-kill (P1)

The most embarrassing finding of the audit: **the plugin was never installed on the
machine it was built for** (absent from `installed_plugins.json`; one dev smoke event
ever). Even installed, the learning loop is broken end-to-end: `route-log.sh` drops
100% of classifier events (empty-models-CSV jq bug, reproduced), nothing ever records
Opus spend (the orchestrate skill *prints a fabricated budget line*), and second-brain's
own maintenance churns/guts the one wiki page capture produces. The framing is also
wrong for this install: USD caps on subscription OAuth, no Fable tier, and `/setup`
unconditionally recommends `opusplan` — which would replace your deliberate Fable choice.

### R5.1 Make the data honest, then install (S)
- `route-log.sh`: `[ -z "$models_csv" ] && models_json='[]'` + test (CR-002).
- Classifier precision: suppress nudges for DO-tier and <25-char prompts; word-boundary
  matches for the THINK list; drop bare `*security*`/`*plan*` substrings (in a repo with
  30+ files in docs/plans/, `*plan*` fires constantly and a THINK false-positive
  persuades toward MORE Opus — inverting the plugin's purpose) (CR-006).
- Stop printing fabricated budget lines in orchestrate Step 7; make
  `opus-budget.sh spent` a pure read (the SessionStart banner currently *writes* the
  ledger on date rollover); clamp negative remaining (CR-009, part of CR-003).
- Generated-page contract: new `sb_write_generated_page` lib.sh helper emitting valid
  frontmatter + machine marker; route `cost-router-capture.sh` through it; teach
  maintenance/validate to skip marked pages (kills the churn loop: CR-007, SCRIPTS-06,
  MCP-CHURN-1 — one fix, three findings).
- README: replace the unverifiable "70–85%" with the price-ratio statement; rephrase the
  learning-loop claim as conditional (CR-010). Add `subagent_type: 'cr-*'` to the
  orchestrate examples so the three pinned agents aren't dead weight (CR-008).
- **Install cost-router from the local marketplace.**

### R5.2 Dogfood 2 weeks → dated keep-or-kill decision (pinned to PROJECT.md)
- **Keep** (route-log shows nudges preceding actual model choices): invest the M-effort
  re-denomination — Contract A in opus_calls/day (recordable under both auth modes; USD
  optional for API-key users), Fable in the tier table, `/setup` presents opusplan as a
  trade-off ("replaces claude-fable-5 — your current frontier pick"), README leads with
  "your $10/$50 main model orchestrates; $3 and $1 models do the work" (CR-003/004/005).
- **Kill:** remove from marketplace.json, delete the `cost-router-capture.sh` consumer
  hook and cr-* agents; demote to a passive status line. Net deletion of ~14 files.

---

## R6 — Token & surface diet (P1)

- **Split the upgrade skill (M):** `skills/upgrade/SKILL.md` is 107KB / ~44K tokens
  loaded on every `/second-brain:upgrade`; 42 of 62 rows are "No precondition" changelog
  prose; it was pruned once (2026-05-24) and regrew in two weeks because the policy
  mandates a row per release. Shrink SKILL.md to ~2KB of runner instructions reading
  `skills/upgrade/migrations/<version>.md` only for versions in (INSTALLED, CURRENT];
  no-op releases get a CHANGELOG.md entry (never context-loaded) instead of a file.
  Amend RELEASING.md policy; add a validator size cap (~8KB) so it cannot regrow.
- **De-vendor the 5 superpowers skills (M):** upstream 5.1.0 is installed alongside;
  five near-identical descriptions double skill-list tokens every session and dispatch
  nondeterministically between divergent bodies — the repo **already has** a fragmented
  design-doc corpus (`docs/specs|plans` vs `docs/superpowers/specs|plans`, 11 files in
  the latter) as evidence. Delete the vendored copies, rewrite cross-refs
  `second-brain:X → superpowers:X`, document superpowers ≥5.1.0 as a recommended
  companion + setup-skill warning when absent. Trade-off (decision for you): standalone
  installs without superpowers lose those 5 skills — the alternative is keeping them
  with explicitly differentiated "only if superpowers absent" descriptions.
- **Dead-weight sweep (S, one PR, net-negative LOC):** delete `batch-extract.sh`
  (hardcoded `--bare`, cannot auth on this box, referenced only by a comment); delete
  dead lib.sh dream helpers; delete the `run-all.sh` chmod block (tests are
  bash-invoked; it's what keeps dirtying your tree — fixes the 4 mode-only diffs at the
  root) and normalize exec bits once via `git update-index --chmod=+x`; rewrite the
  stale hooks.json dream-autostage comment.
- **Per-prompt diet (M):** merge persona-context.sh's two node cold-starts
  (knowledge-search-cli at :235 + episodic-search-cli at :259; 2.2–3.7s measured per
  substantive prompt) into one combined CLI invocation; route exit-0 breadcrumbs from
  error-log to audit-log and add size-based rotation (error-log is 41% non-error and
  unrotated — it dilutes the exact signal the SessionStart banner reads).

---

## R7 — Observability & self-healing (P1 start, L item its own cycle)

- **Hook latency telemetry (M):** stamp entry/exit in lib.sh, append
  `{hook, duration_ms}` to audit-log.jsonl; p50/p95 per hook in `/second-brain:status`
  with budget warnings at >70% of the hooks.json timeout. (The entire R1 timeout
  disaster was only diagnosable by forensic log mining.)
- **Liveness/dormancy gate (S):** `scripts/liveness-check.sh` wired into
  `/second-brain:review` + the release checklist: marketplace plugins present in
  `installed_plugins.json` (else "shipped but not deployed"); cross-plugin bridges have
  their producer (else "integration dormant"); freshness probes on value artifacts
  (route-log, episodic index mtime, embeddings symlink). Three independent findings
  (CR-001, MCP-INTEG-1, MCP-DEPS-1) are this one missing check.
- **`sb doctor --fix` (L — own design cycle):** one self-healing entry point unifying
  what banners currently nag about: auto-relink embeddings, reclaim/transition stuck
  dreams, prune the drainer scratch dir, rotate logs, bwrap-vs-unit probe, deployment
  gaps. Changes the SessionStart contract: no-consent fixes run automatically and report
  "fixed X" once; only consent-requiring fixes (downloads, API keys) still instruct.
- **Retrieval observability (M, then L):** log served slugs per prompt to
  `retrieval-log.jsonl`; at Stop, check the window for usage evidence ([[slug]]
  citations, fetches of served pages) and write `used:[…]` back; surface serving
  precision in `/status`; feed chronic served-never-used pages into the FORGET scorer.
  This converts "is the knowledge base useful" from a vibe into a number and gives every
  future serving change a before/after metric.

---

## R8 — Release/process hardening (P2)

- **Minimal CI + branch protection (M):** one workflow, SHA-pinned official actions,
  `permissions: contents: read`, no secrets, no third-party actions: `npm ci` +
  `bash tests/run-all.sh` (claude-CLI steps self-skip; suite is 2m36s on a Pi). Verifier
  downgraded this to medium for a single-maintainer repo with a working local gate — but
  it's the only server-side backstop for the bypassed-hook/other-machine case, and an
  optional `runs-on: macos-latest` job running `test-dream-lifecycle.sh` closes the
  standing macOS PROJECT.md item without buying hardware.
- **Bundle-current gate (S):** `npm run bundle && git diff --quiet -- dist || fail` in
  `make release-check` — the 0.24.7/0.24.8 stale-bundle incident class; the tsc gate
  only catches the type-error subclass.
- **Version-drift gate for all plugins (S):** validate-plugin.sh hard-codes
  `.plugins[0]`; iterate `.plugins[]` and resolve each `source` — cost-router drift is
  currently unchecked (the exact class the check was added for in v0.21.0).
- **Structural test isolation (M):** run-all.sh exports suite-temp
  `HOME`/`BRAIN_DIR`/`KNOWLEDGE_DIR` for every test (tests setting their own win) —
  kills the whole leak class including the KNOWLEDGE_DIR dimension the enumerated grep
  guard misses. Caveat from the verifier: claude-CLI-spawning tests need `~/.claude`
  care. Subsumes the planned static meta-guard PROJECT.md item.
- **Small stuff (S):** selective mirror instead of copying 618MB node_modules into tmpfs
  per suite run; separate vitest timeout knob; record the 156s Pi baseline + print wall
  time in run-all summary; re-align or amend the lapsed tag contract in RELEASING.md
  (nothing tagged since v0.22.1; doc also states stale test counts).
- **Surface budget (S):** counts of skills/agents/scripts/hooks/TS files/tests + upgrade
  SKILL.md byte-size in a checked-in `docs/surface-budget.json`; validate-plugin fails
  on growth without a same-commit baseline bump ("I chose to grow this" becomes
  git-blameable). Plus the SKAG-6 validator fields (user-invocable +
  disable-model-invocation explicit, side-effectful skills must declare DMI).
- **Permission-dialect canonicalization (S probe + M sweep):** three dialects coexist —
  short vs plugin-namespaced MCP names (10 skills use `mcp__knowledge-base__*`; the live
  runtime exposes `mcp__plugin_second-brain_knowledge-base__*`), colon vs space Bash
  matchers, and unverified `${CLAUDE_PLUGIN_ROOT}` substitution in agent `tools:` — at
  most one form per axis matches the runtime, and the test guards currently **enforce
  the possibly-wrong dialect**. One live probe session with permission prompts visible →
  record verified premises in `review-fragile-premises.md` → mechanical conversion →
  guards reject non-canonical forms. Fold the SKAG-5 rm/mv narrowing in if the probe
  clarifies the scoped form.
- **Approved-roadmap leftovers (S):** the unshipped tranche of the 2026-05-29 CC
  feature-adoption roadmap: FileChanged/watchPaths hook (#6, fixes the reindex-staleness
  class), `disallowedTools` deny-half on read-only agents, `maxTurns` on dream-runner /
  knowledge-maintainer, preloaded `skills:` on worker agents.

---

## R9 — Data-plane integrity & privacy (critic gaps; mostly P2, first item P1)

The critic's verdict: the audit's blind spots are data-plane, not control-plane. Each of
these needs a mini-spec before implementation.

- **Backup/restore (P1, M):** `~/.second-brain` (565MB) and `~/knowledge/wiki` live on
  an SD-card-class medium with **no** scheduled backup and no restore drill — the
  existing rescue tarballs are all manual. Smallest real fix: git-init the wiki (text,
  diffs well) + a timer-driven `sb backup` tarball of the brain dir's irreplaceable
  subset (excluding regenerable embeddings cache) with rotation, restore documented and
  drilled once. Offline-first compliant (local target; remote optional later).
- **TS write atomicity (S):** `episodic-search.ts:185` plain-`writeFile`s the 7MB
  episodic index with no tmp+mv and no lock, and the indexer is launched backgrounded
  from two hooks — consistent with the index rescue artifacts already in the brain dir.
  tmp+mv + a cheap lockfile; the bash-side discipline already exists as the pattern.
- **Transcript privacy (M):** archived transcripts are verbatim (65 files / 17MB), kept
  indefinitely, re-served by episodic tools and shipped wholesale to headless `claude
  -p`. Reuse the raw-scan secret regexes as scrub-on-archive; add a retention knob to
  config.json; document what is stored where.
- **Offline outage vs poison (M):** the drainer's fails counter can't tell a multi-day
  network outage from poison input — an outage permanently quarantines healthy
  transcripts with no requeue command. Distinguish curl/auth failures (don't count) from
  extractor rejections (count); add `sb requeue` (or fold into `sb doctor`). This is the
  offline-first principle applied to the plugin itself.
- **Memory-content injection audit (L, own spec):** untrusted session content flows
  extraction → wiki → persona-context injection into every future prompt, unscanned
  (tool-return-scanner covers only PostToolUse). Needs a considered design: taint
  marking at write time, scan-on-serve, or trust tiers per source. GAP-COMP-1 verbatim:
  persona-context.sh:321 composes served memory as "factual statements" precisely
  because that phrasing dodges injection defenses — worth a deliberate look.
- **Fresh-install funnel (M):** no end-to-end fresh-HOME test of marketplace add →
  install → setup → first session; README's last substantive touch is ~0.24.16 era. A
  scripted smoke test would also exercise the consent-gated vector-deps download path
  nobody tests.
- **Pi memory benchmark (S):** all current numbers are latency-only; nobody measured RSS
  with 2-3 concurrent sessions × per-prompt node spawns × the 519MB vector-deps model on
  an 8GB host. An OOM-kill mid-write is also the most plausible trigger for the index
  corruption class above.
- **Persona-signals pipeline audit (S investigation):** `persona-signals.jsonl` has
  **1 line after weeks of daily use** — the signal→graduation loop is plausibly as
  dormant as cost-router was. Verify emission, merge, graduation; wire its freshness
  into the R7 liveness check.

---

## Explicitly not doing (so audits stop re-finding them)

- `sb_prune_transcripts` word-splitting (SCRIPTS-09) — **refuted** by the verifier.
- Removing the `doubt` skill (SKAG-10) — refuted as a non-finding: zero session cost,
  load-bearing dev infrastructure; optionally one description line scoping it.
- SP-1 slot interleave — deferred pending post-R2 re-measurement (above).
- tests/*.sh portability scan + macOS dream-lifecycle run — already tracked in
  PROJECT.md as deliberate deferrals; R8's CI item offers the cheapest macOS path.
- G-MCP-3 server split — likely YAGNI; R3 records the decision either way.

## Suggested first three releases

1. **R1 complete + R1.3 guard** (one release) — biggest waste kill, one security close.
2. **R2 complete** (one release) — search correctness + eval + embeddings liveness.
3. **R5.1 + install** (one release) — cost-router honest and actually running, dogfood
   clock starts. R4 can be developed in parallel with R2/R5 (mostly disjoint files —
   note R1 and R4 both touch `maintain-llm-drain.sh`, so land R1 first).

Every release: version bump lockstep, migration row (until R6.1 changes that policy),
deep-review gate, green suite.
