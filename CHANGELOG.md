# Changelog

Release narrative for every version (newest first). Never context-loaded;
the `/second-brain:upgrade` runner reads ONLY `skills/upgrade/migrations/<version>.md`
files, which exist solely for releases with a real migration action.

## 0.33.24

P4 skill-catalog diet — shrink the model's per-session skill catalog (no functionality removed).

- Converted 6 skills (status, review, audit, lint, recall, think) to user-invocable-only
  (disable-model-invocation: true): they leave the model's auto-discovered catalog but stay
  available as slash-commands. The model's second-brain catalog drops from ~9 to 3
  (query, code-review-deep, using-second-brain) — less per-session metadata + selection ambiguity.
  Dashboards (status/review/audit) being model-invocable also contradicted the silence-default
  principle; user-only resolves both.

## 0.33.23

Path-traversal guard hardening + the cross-platform path-test discipline (adapted from
`vercel-labs/skills` via the designer-skills deep-scan).

- **`path-guard.ts` now has a dedicated test suite** (it was security-critical but untested). It
  locks the full traversal-vector matrix — `..`, `..\`, absolute paths, `C:\…`, UNC, NUL, oversize —
  feeding each vector in BOTH forward-slash and backslash form so a regression fails on either OS
  instead of silently skipping on the one whose separator it uses, plus a containment **safety
  invariant** for `assertWithin` (every vector either throws or stays inside base — never escapes).
- **`assertSafeSlug` hardened** to also reject NUL/control chars (`\x00-\x1f`) and oversize (>128)
  slugs, reaching parity with `path-guard`'s `validateSlug` (a slug becomes a directory name, so
  these are never legitimate). Traversal chars (`/`, `\`, `..`) were already rejected.

## 0.33.22

P7 — graph search-ranking boost demoted to off-by-default; P8a/b retrieval-eval guards.

- **Graph ranking boost is now opt-in** (`SB_GRAPH_RANKING_BOOST=1`), off by default. A measurement
  over the real wiki (96 pages / 170 edges) showed the boost is a wash — it improved a gold page's
  rank in 6 cases, **degraded** it in 6, and changed nothing in 80 of 92 — while in the harm cases it
  displaced a page's own exact title-match (rank 0→1). It also provably cannot improve recall (a
  zero-base page receives zero boost). Demoting it removes the net-zero reranking and the historical
  ~10,000× score-inflation complexity from the hot path. The graph machinery is unchanged for
  `knowledge_neighbors` (blast-radius) + bi-temporal `supersedes`, and the project-scoping
  neighbourhood is unaffected. Recall is provably unchanged (eval suite green).
- **New deterministic retrieval-eval guards (P8a/b):** exact-term canary (#1 ranking), knowledge-update
  (overwrite wins), episodic recall round-trip (search→read), abstention (no match for an absent term),
  episodic golden + project-scoping, and a default-off guard for the boost flag. Closes the
  previously-missing episodic recall coverage.

## 0.33.21

P6b — transcript-ingest sanitization (the dominant poisoning vector P6a left open).

- **Strip invisible Unicode from untrusted session transcripts at both consume points.** Reusing the
  single canonical sanitizer (`stripInvisible`, now extracted to `mcp/src/tools/sanitize.ts`): the
  dream pipeline stages a **sanitized real copy** of each transcript (`dream-snapshot.sh` →
  bundled `sanitize-cli`) before the dream-runner agent reads it — never a symlink, so the source
  transcript is never mutated — and the episodic read path (`buildEpisodicIndex` + `episodicRead`)
  strips on read. Hardens `transcript → dream → wiki → auto-injection` and `transcript → episodic`
  for the Tags-block + zero-width channel. (The episodic path is enforced; the dream path is
  defense-in-depth — the dream-runner is *directed* to read the sanitized staging copies, but its
  broad read grant could still reach the originals, so scoping that agent's read surface is a
  deferred backlog item.) Degrades to a logged plain copy if node/CLI is absent.
- Adds `sb_plugin_root()` to `lib.sh` (removing the duplicate plugin-root resolver) and a directory
  re-used `sb_strip_invisible_copy()`.
- **Scope:** bidi-control (Trojan-Source) + variation-selector channels, and the quarantine/dual-LLM
  + write-scoping work, remain deferred (see the P6b plan's out-of-scope).

## 0.33.20

P6a security-hardening quick-wins (first slice of the spec-v4 P6 security workstream).

- **Strip invisible Unicode from captured content (raw-inbox `/capture` ingest path).** Raw-inbox
  items are sanitized on BOTH the write (`serialize()`) and read (`parse()`) paths — so legacy items
  captured before this version are also cleaned on the way to the drainer: the Unicode Tags block
  (U+E0000–U+E007F — one ASCII-smuggling channel that decodes to text for the model but renders
  invisibly) plus ZWSP / word-joiner / BOM are removed from the body, gist, and free-text frontmatter
  (source/origin/target_node, which otherwise ride into the wiki provenance back-ref). Preserves
  U+200C/U+200D so scripts and emoji ZWJ sequences are untouched. **Scope:** this hardens the
  raw-inbox capture path only; the transcript→dream→wiki path (`sb_archive_transcript` /
  `sb_archive_subagent_result`) and the bidi-control / variation-selector channels are NOT covered
  here — both are deferred to P6b.
- **Least-privilege the consolidation agents' node grant.** `raw-drainer` and `knowledge-maintainer`
  read untrusted transcript content; their unconditional `Bash(node *)` grant is scoped to
  `Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)` — the bundled CLIs they actually call — *reducing*
  (not eliminating) the arbitrary-Node surface. A directory-walked source-scan test fails the build
  if any agent grants node outside that path (or a blanket `Bash(*)` / bare `Bash`). Full
  containment (write-scoping, network sandbox, quarantine/dual-LLM) is deferred to P6b.

- **Self-heal couldn't repair a shim-less scheduler.** `sb_timer_installed` only checked the OS
  registration, so a stale Scheduled Task / unit left by an old version whose shim was GC'd read as
  "installed" — the scheduler then execs a non-existent `~/.second-brain/bin/sb-extract-drain.sh` and
  fails silently every fire, and `--ensure` / the session-load self-heal never repaired it. Now the
  shim is a required health signal (universal across systemd/launchd/windows): a
  registration-without-shim reads "absent" → `--ensure` / self-heal re-applies and regenerates it.
- **In-session floor didn't normalize Windows paths.** The in-session deterministic floor wrote
  `C:\…` backslash paths to PROJECT.md while the drainer twin normalized to forward slashes. Both now
  forward-slash-normalize, so captured decisions are clean, clickable, and consistent.

`/upgrade` to 0.33.19 runs `install-extract-timer.sh --ensure` once — now shim-aware, so it repairs a
stale shim-less task automatically. Skippable with `SB_DISABLE_AUTO_TIMER=1`. See `migrations/0.33.19.md`.

## 0.33.18

P1 autonomous capture loop — make session capture run with **zero manual steps** on OAuth/subscription
auth, without depending on the in-session recursive-`claude` lock.

- **Deterministic capture floor (in-session).** When no extractor backend is reachable, the Stop hook
  now writes a real files-changed delta to PROJECT.md (`sb_extract_deterministic` from the raw JSONL)
  instead of only a `[degraded]` breadcrumb — capture is never a full no-op.
- **Out-of-band drainer installed by default + self-healing.** `install-extract-timer.sh` gains an
  idempotent `--ensure` mode; setup installs the **hardened, no-credentials** drainer scheduler
  automatically, and the OAuth session-load banner self-installs it if it ever goes missing (instead of
  only nagging). The `--oauth` credential grant stays a separate, explicit consent. Opt out everywhere
  with `SB_DISABLE_AUTO_TIMER=1`.
- **Last-resort floor for the drainer too.** The out-of-band drainer — the path the timer runs — now
  falls back to a deterministic files-changed delta at the quarantine boundary (after the LLM has failed
  `SB_DRAIN_MAX_FAILS` times), so an OAuth box with no working backend still captures real signal. LLM
  enrichment is preserved until then. Opt out with `SB_DRAIN_FLOOR=off`.
- **Cross-platform fix.** Decisions citing Windows paths (`C:\…`) were corrupted when written to
  PROJECT.md — `awk -v` escape-processes its value, so `\t` became a TAB and `\W` dropped the backslash.
  Fixed by passing the bullet through `ENVIRON` (not escape-processed); the floor also normalizes
  backslashes to forward slashes. This fixed the bug class for the LLM extraction path as well.

`/upgrade` to 0.33.18 runs `install-extract-timer.sh --ensure` once (idempotent, hardened, no
credentials) so existing installs get the autonomous drainer — a one-line host-state change (a user
scheduler entry), skippable with `SB_DISABLE_AUTO_TIMER=1`. See `migrations/0.33.18.md`.

## 0.33.17

Fix: a stray `.second-brain/` (and sometimes `knowledge/`) folder appeared in the root of unrelated repos
on Windows. ~16 MCP tool/CLI call sites resolved the brain/knowledge dir as `join(process.env.HOME ?? '',
'.second-brain')`. On native-Windows Node, `HOME` is unset (Windows uses `USERPROFILE`), so the fallback
collapsed to a CWD-relative path and wrote runtime state into whatever directory the MCP server ran from.
Bash hooks run under MSYS where `$HOME` is set, which is why only the Node side rotted. Extracted a single
canonical resolver (`mcp/src/brain-paths.ts`: `os.homedir()` + CR/LF stripping) and migrated all call sites
plus `dream.ts` onto it. Added contract tests (fallback is absolute, homedir-anchored, ignores `HOME`) and a
source-scan guard that fails the build if any file reintroduces `process.env.HOME` for path resolution.

`/upgrade` to 0.33.17 is a marker bump (no data migration — runtime state regenerates; the canonical store at
`~/.second-brain` was always correct).

## 0.33.16

code-review-deep Bundle B + cost-router deep-review routing (no migration action).

- **C1 prior-PR-comment mining** (finding-generating, Pass 0): mines GitHub PR review comments on prior PRs
  touching the changed files (`git log` -> PR numbers -> `gh api .../pulls/N/comments`, ~10-PR cap, path-filtered)
  and emits `prior-review` findings into Pass 3 scoring. Adds `Bash(gh api *)` to the skill's allowed-tools.
- **C2 inline-comment compliance**: the per-unit reviewer now flags diffs that violate guidance in nearby code
  comments (keep-sorted / NOTE / INVARIANT / docstring contracts); reuses the existing `convention` category.
- **C3 adversarial refuter panel**: critical/high findings are scored by 1 normal + 2 refute-mode scorers; the
  final score is the median of the three (identical to "confirmed iff >= 2 of 3 score >= 70", so the
  >= 70 / 16-69 / <= 15 partition is unchanged). Panel scorers inherit the session/best model (a quality floor).
- **C4 least-privilege**: `disallowedTools: Write, Edit, NotebookEdit, WebFetch, WebSearch` on the five read-only
  review agents (unit, scorer, history, premise, quality).
- **C5/C6**: Pass-3 scoring shares the <= 5 wave cap (the refuter panel multiplies Pass-3 agents on a constrained
  host); a cost-ownership note documents that the skill self-tiers and cost-router does not override it.

cost-router 0.2.2 (separate plugin in this repo): a conservative, word-bounded REVIEW detector in
`classify-prompt.sh` recognizes a deep-review request and points the user at `/second-brain:code-review-deep`
(detect-&-degrade to `/cost-router:orchestrate` when second-brain is absent). It routes TO the self-tiering
skill, never tiers or decomposes it; the hook is `set -u`-safe under an unset `HOME`.

## 0.33.15

Fix: the 0.33.14 test (not the product) aborted the Linux CI bash suite (no migration action). The new
`test-install-extract-timer.sh` Test 19 captured the intentionally-non-zero `--apply` via
`OUT=$(... ); RC=$?` — and under `set -euo pipefail` an assignment from a failing command-substitution
aborts the script on bash 4/5 (the ubuntu CI), but NOT bash 3.2 (macOS), so it slipped through as
macos-pass / linux-fail (and was missed locally by not checking the final `Results:` line). Fixed to
capture the status via an `if`-condition (which suspends `set -e`). The 0.33.14 schtasks fix itself was
correct. Lesson reinforced: run the FULL suite (not just targeted gates) before push.

`/upgrade` to 0.33.15 is a marker bump (no data migration).

## 0.33.14

Fix: the Windows extraction-timer install was silently broken (no migration action) — caught by a LIVE
`--apply` (the tests stub `schtasks`, so they never exercised the real scheduler). git-bash MSYS-translates
`schtasks`' POSIX-looking flags (`/Create` → `C:\Program Files\Git\Create`), so `schtasks` rejected the
command and the task was **never created** — yet the script printed "applied". Now:

- `scripts/install-extract-timer.sh` runs the Windows `schtasks /Create` and `/Delete` under
  `MSYS_NO_PATHCONV=1` (verified against real `schtasks`: create→query→delete all succeed).
- `--apply` is **fail-loud**: it checks the `schtasks` exit, prints "… was NOT installed" + exits non-zero
  (rolling back the shim) instead of falsely claiming success.
- `tests/test-install-extract-timer.sh` Test 19: asserts both calls are `MSYS_NO_PATHCONV`-guarded and that
  `--apply` fails loud when `schtasks` errors (stubbed to exit 1).

`/upgrade` to 0.33.14 is a marker bump (no data migration).

## 0.33.13

Cross-platform extraction-timer hardening (no migration action). A 5-lens research sweep + a 3-lens deep
review (fix-first, all findings addressed + mutation-proven) hardened `install-extract-timer.sh` so the
out-of-band drainer is solid on Linux/macOS/Windows:

- **Survives plugin upgrades (all OSes):** the scheduler now runs a STABLE shim
  (`~/.second-brain/bin/sb-extract-drain.sh`) that resolves the LATEST installed plugin version's
  `extract-drain.sh` and execs it — instead of a version-pinned cache path that goes stale/GC'd after an
  upgrade. `sort -V` with a numeric-field fallback for older BSD `sort` (macOS).
- **Windows env forwarding:** a captured, `chmod 600` env-file (`~/.second-brain/.extract-timer-env`,
  sourced by the shim) carries the engine knobs (KNOWLEDGE_DIR / `SB_EXTRACTOR_*` / API key) the schtasks
  task previously dropped — matching the launchd behaviour.
- **WSL-safe bash on Windows:** `win_bash()` probes git-bash explicitly (guarded for unset
  `PROGRAMFILES`/`LOCALAPPDATA` under `set -u`) instead of a bare `command -v bash` that could schedule the
  WSL `System32\bash.exe` (the 0.33.1 class).
- **Creds-free hardened systemd unit preserved:** the env-file omits `ANTHROPIC_API_KEY`/`ANTHROPIC_BASE_URL`
  on the hardened Linux default (forwarded only under `--oauth`, or on launchd/windows which have no sandbox).
- sed-replacement escaping for `&`/`#` in a home path.

`tests/test-install-extract-timer.sh` grows to 52 checks (shim latest-version resolution, env-file +
mode-600, WSL-safe bash incl. the unset-var regression, creds gating, uninstall cleanup) — all mutation-proven.
No mcp/ change; no new files. `/upgrade` to 0.33.13 is a marker bump (no data migration).

## 0.33.12

Windows-portability sweep — close the `dream_accept` bug class at the root (no migration action). A 5-lens
sweep reproduced every tar/rsync/`ln`/spawn/CRLF site that consumes a plugin-provided path; the suite was
already largely safe (the 0.33.7 + 0.33.10 fixes, and most scripts let the MSYS runtime translate paths), but
two real items remained:

- **`scripts/lib.sh` (root cause):** the Node MCP injects `BRAIN_DIR` in Windows form (`C:\Users\…`), which
  GNU tar/rsync read as a remote `host:path` and `ln -s` mis-links. lib.sh now MSYS-normalizes `BRAIN_DIR`
  via `cygpath -u` **once at the inheritance boundary every script sources** — so every current *and future*
  tar/rsync/`ln` sink is safe by construction (no-op on POSIX; idempotent on already-MSYS paths). This
  generalizes 0.33.10's per-script `dream-accept.sh` fix and makes the equivalent `dream.ts` env change moot.
- **`scripts/dream-snapshot.sh`:** the transcript-staging `ln -sf` silently deep-copies on git-bash
  (winsymlinks off). Made explicit — `cp -p` on Windows (mtime preserved; pruned with the dream), real
  symlink on POSIX — so it no longer relies on accidental MSYS copy behavior.
- **`tests/test-lib-brain-dir-msys.sh`** (new): behavioral guard — sources lib.sh and asserts an already-MSYS
  path is unchanged (runs on Linux/macOS CI) and a Windows-form `C:\…` becomes `/c/…` round-tripping to the
  same dir (git-bash; mutation-proven RED when the normalize is removed).

CI has no Windows runner, so these are verified live on git-bash. `docs/surface-budget.json` tests 144→145.
No mcp/ runtime change. `/upgrade` to 0.33.12 is a marker bump (no data migration).

## 0.33.11

Behavioral test coverage — the remaining 14 audited "green ≠ working" gaps closed (no migration action).
Following 0.33.9's first two, every remaining gap where a test asserted PRESENCE (grep a source/prompt for a
string) but never EFFECT is now a real behavioral test that RUNS the code and checks the actual result. Each
new assertion was mutation-proven (the real behavior was broken, the test went red, then reverted).

- **SessionStart (new `tests/test-session-load-scope-banner.sh`):** runs `session-load.sh` and asserts its
  STDOUT — the cross-project-leak scope banner emits with the correct slug (and a stale pin never leaks),
  `SB_SCOPE_BANNER=off` suppresses it in OUTPUT, the plan/decision/blocker counts are exact on LF *and* CRLF
  PROJECT.md, and persona "Observed patterns" emits only the qualifying ungraduated signal.
- **Extraction→wiki:** `test-extract-drain.sh` / `test-extractor-local-backend.sh` now prove a drained/extracted
  delta actually writes a `learnings/*.md` page with its body (through the real merge), `test-extraction-quality-gate.sh`
  proves the gate preserves `wiki_updates`+`relations` while filtering noise, `test-merge-project-update.sh` proves
  the node-less create path writes a real page.
- **Raw drain/maintain (new `tests/test-maintain-drain-loop.sh`):** executable loop-control contract (stop on
  DRAINED:0 / REMAINING:0, 30-iter fail-loud cap, no-line→dispatch-once-more) + `DRAINED/REMAINING` parser;
  `test-kb-drain-reconcile.sh` proves the documented back-ref template is parseable by reconcile's regex (coupling)
  and the multi-ref loop flips both items.
- **Retrieval (vitest):** real-model `skipIf(EMBEDDINGS_OFFLINE)` tests that `knowledge_search` RRF fusion ranks a
  semantic match over a lexical decoy (not degraded), `episodic_search` vector recall returns a no-shared-token
  paraphrase's match, and `knowledge_neighbors` forwards `as_of`/`depth`/`direction` through the MCP wrapper.
- **Guards (`test-guard-wiring.sh`, `test-persona-context.sh`):** persona-tool-guard matcher is a superset of the
  tools it inspects (out-of-scope set pinned), and the `/?` Opus brief actually reaches `additionalContext`
  (sentinel + wrapper) with a non-empty fallback when the bundle is missing.

`docs/surface-budget.json` tests 142→144 (two new files). No mcp/ runtime change. `/upgrade` to 0.33.11 is a
marker bump (no data migration).

## 0.33.10

Fix: `dream_accept` was completely broken on Windows (no migration action). GNU tar and rsync parse a
leading drive letter as a REMOTE `host:path`, so `tar -f C:\Users\...\wiki-backup.tgz` failed with
"Cannot connect to C: resolve failed" — and the MCP passes `BRAIN_DIR`/`KNOWLEDGE_DIR` to the bash
scripts in Windows form. Every Windows `dream_accept` therefore fail-closed at the pre-accept backup,
reporting a misleading "disk full / unwritable" message (the real tar error was swallowed by `2>/dev/null`).

- `scripts/dream-accept.sh` now MSYS-normalizes `BRAIN_DIR`/`KNOWLEDGE_DIR` via `cygpath -u` (a no-op on
  POSIX, where paths have no drive letter) before any tar/rsync, so the backup and the apply both work on
  Windows. `dream-snapshot.sh` was unaffected — it uses mkdir/cp, which the MSYS runtime path-translates.
- The backup failure is now **fail-loud**: it reports tar's actual stderr instead of guessing "disk full"
  (that guess hid this bug for several releases — caught only when a real Windows accept failed).
- `tests/test-dream-accept-guards.sh` gains **B4**: a behavioral test that feeds a real Windows-form
  `BRAIN_DIR` (via `cygpath -w`) and asserts the accept succeeds and writes the backup — it runs on
  git-bash (where the bug lives) and skips on Linux/macOS. The prior sandboxes only used MSYS-form temp
  paths, so they never reproduced it.

`/upgrade` to 0.33.10 is a marker bump (no data migration).

## 0.33.9

Behavioral test coverage for critical wiring (no migration action). An audit found the suite has
systemic "green ≠ working" gaps — tests that grep a source/prompt file for a string (PRESENCE) but
never verify the behavior actually works (EFFECT), the same class as the persona-charter bug. First
two critical gaps closed with real behavioral guards:

- **`tests/test-subagent-dispatch-resolves.sh`** — every `second-brain:<X>` a skill references
  (dispatch or cross-ref) must RESOLVE to a real agent (`agents/<X>.md` whose `name:` matches) or
  skill, format-agnostically (maintain wraps `subagent_type:` across two lines, which a single-line
  grep misses). A renamed/typo'd subagent_type silently no-ops the dispatch — this already shipped
  once (9f2264a) and the old presence-greps did not catch it.
- **`tests/test-guard-wiring.sh`** — each PreToolUse safety guard (wiki-write, symlink, flow,
  persona-tool) must actually be REGISTERED in `hooks/hooks.json` with a matcher covering the tools
  it protects; the per-guard unit tests pipe inputs straight to the script and never check the
  harness wiring, so a deleted/narrowed registration would leave the guard inert but green.

Remaining audited gaps (scope-banner emit, extraction→wiki, +10 high/4 medium) tracked for follow-up.

`/upgrade` to 0.33.9 is a marker bump (no data migration).

## 0.33.8

Persona charter — every persona now carries a standing operating ethos (no migration action).
The persona-card seed (both the `scripts/persona-context.sh` auto-seed and the
`/second-brain:setup` scaffold) gains a neutral, 2nd-person `## Charter`: be indispensable
without becoming a crutch; anticipate needs before they're articulated; handle the tedious so the
user can focus on the brilliant; be less a servant asking permission, more a partner who knows
when to act and when to step back; grasp the *why* behind the work, not just execute commands.

- Applies to **new** personas (seeded) and **existing** ones — `/second-brain:setup` idempotently
  adds the section if missing (user-invoked, never an automatic rewrite of the user-owned card).
- **Actively governs every session:** `session-load.sh` injects the card's `## Charter` once per
  SessionStart (NOT per-prompt — no return to the 0.32.0 per-prompt noise it deliberately removed),
  so the ethos shapes the partnership on every install instead of merely documenting it.
- Guards: `test-persona-card-seed.sh` asserts the Charter is present, consistent across both seeds,
  and **neutral 2nd-person** (no first-person author voice); `test-session-load-persona-card.sh`
  asserts the Charter — and only it — is emitted at SessionStart.

`/upgrade` to 0.33.8 is a marker bump (no data migration).

## 0.33.7

Fix: the vector-deps installer no longer deep-copies ~490 MB per plugin version on Windows
(no migration action). `install-vector-deps.sh` installs the native deps (onnxruntime-node,
sharp, `@huggingface/transformers`) ONCE into `~/.second-brain/vector-deps` and links each
plugin version's `mcp/node_modules` at it — but on git-bash/MSYS `ln -s` silently
**deep-copies** the target (winsymlinks default), so every upgrade left a full real copy
(~490 MB), accumulating to multiple GB across versions in the plugin cache.

- **`link_version()` now links cross-OS without copying:** a Windows directory **junction**
  (`node fs.symlinkSync(target, link, "junction")` — needs no admin / SeCreateSymbolicLink
  privilege) and a normal `ln -s` on POSIX. Verified on Windows: git-bash `test -L`/`readlink`
  recognize the junction and `rm -f` unlinks it without touching the shared tree, so the
  existing idempotent relink logic is unchanged.
- **`test-upgrade-vector-deps.sh` now runs on Windows.** Its OS gate previously probed bare
  `ln -s` (which deep-copies), found no real symlink, and silently SKIPPED the whole suite —
  hiding this bug. It now probes the real junction mechanism, and adds a structural **T11**
  guard (runs on CI's linux/macos, which have no Windows runner) against reverting to a
  deep-copying `ln -s`.
- Reclaim existing duplication by pruning stale plugin-cache versions; the next
  `install-vector-deps` run relinks the active version as a junction (single shared copy).

`/upgrade` to 0.33.7 is a marker bump (no data migration).

## 0.33.6

Opt-in raw-inbox prune (no migration action). Processed raw captures are kept in
`~/.second-brain/projects/<slug>/raw/` as a provenance + truncation-recovery audit trail and are
**never searched** (retrieval is scoped to `~/knowledge/wiki/` — verified across knowledge_search,
episodic search, and the SessionStart/context hooks), so they carry no query-noise cost. For
operators who prefer a transient inbox, this adds an explicit opt-out:

- **New `prune-processed` CLI action** (`raw-capture-cli`) + `pruneProcessed()` — deletes a
  project's `processed`/`discarded` raw `.md` (and any sibling blob); **always keeps** unprocessed +
  malformed items. Idempotent. One-off via `/second-brain:capture --prune-processed`.
- **`SB_RAW_PRUNE_AFTER_DRAIN=1`** — opt-in flag the `raw-drainer` honors *after* its safety-net
  reconcile, so each drain batch clears the audit trail automatically. Default OFF (keep the trail).
- Default behavior is unchanged; nothing is deleted unless you opt in.

`/upgrade` to 0.33.6 is a marker bump (no data migration).

## 0.33.5

Truncation-free raw-inbox drain (no migration action). The Phase 4c drain previously ran entirely
inside one knowledge-maintainer context; a large captured document exhausted the subagent's output
budget, so it truncated after ~1–3 items. `0.33.3`'s reconcile made that *safe* (resumable, no
duplicates) but you still had to re-run `/second-brain:maintain` repeatedly to finish a backlog.

- **New `agents/raw-drainer.md`** — a lean, single-purpose drain worker: it reconciles, drains up
  to `SB_DRAIN_BATCH` (default 5) items one-at-a-time with full provenance, reconciles again, and
  ends with a parseable `DRAINED: <n>  REMAINING: <m>` line.
- **`/second-brain:maintain` now loops it.** Stage 1 dispatches the knowledge-maintainer for
  consolidation + ai-block authoring (no in-context drain); Stage 2 re-dispatches the `raw-drainer`
  in a **fresh context per batch** until a full pass drains nothing new (`DRAINED: 0`) or the inbox
  is empty (`REMAINING: 0`), with a 30-iteration fail-loud cap; Stage 3 reindexes. A fresh context
  per batch can never truncate the whole drain.
- **The knowledge-maintainer no longer drains in-context** — Phase 4c is delegated to the skill's
  loop (auto-dispatched runs already skipped it). The conservative (never auto-discard), provenance,
  and explicit-only invariants are preserved, and the drain stays resumable + idempotent
  (reconcile-backed).

`/upgrade` to 0.33.5 is a marker bump (no data migration — the drain just finishes in one
`/second-brain:maintain` now).

## 0.33.4

Cross-project drain fix for the raw-capture CLI (no migration action). Found while live-draining
witcherrpg's inbox from a claude-code-plugin session: `raw-capture-cli process <id>` returned
"No raw item with id …" so the maintainer couldn't mark items processed (it hand-edited files
as a workaround).

- **`process`/`pending`/`list`/`discard` were hard-scoped to the ACTIVE project** (`SB_ACTIVE_SLUG
  || resolveActiveSlug`), so they could never touch another project's inbox. Added a **`--slug
  <project>` flag** (precedence: `--slug` > `SB_ACTIVE_SLUG` > `resolveActiveSlug`), parsed in any
  order alongside `--node`. The maintainer's Phase 4c now passes `--slug <project>` explicitly, so
  the drain targets the right inbox even when a different project is the active session — and is
  immune to a `resolveActiveSlug` mis-resolution.

`/upgrade` to 0.33.4 is a marker bump (no data migration).

## 0.33.3

Truncation-safe, resumable raw-inbox drain (no migration action). Found by live-draining a project
backlog: the maintainer's Phase 4c wrote wiki nodes but the LLM batched the per-item "mark
processed" bookkeeping and truncated on a large backlog — nodes existed but raw items stayed
`unprocessed`, so a re-run RE-DRAINED them into duplicate nodes.

- **New `scripts/kb-drain-reconcile.sh`** — deterministic, idempotent: scans `wiki/**` for the
  `(raw <id>)` provenance back-refs the drain writes, and marks each referenced raw item
  `status: processed` + `target_node: <slug>`. Ghost ids and already-processed items are no-ops; raw
  items are never deleted.
- **Maintainer Phase 4c** now runs reconcile at the START (syncs any prior truncated run so
  duplicates can't arise on resume) and END (safety net), mandates strict per-item marking, and
  documents a Resumability contract: a truncated drain is safely *continued* by re-running
  `/second-brain:maintain` — never restarted, never duplicated. This matters most when transforming
  an old/large backlog on another machine: it drains incrementally across runs with no dup/loss.

`/upgrade` to 0.33.3 is a marker bump (no data migration).

## 0.33.2

Windows dream-pipeline fix (no migration action). Second bug in the dream-on-Windows path chain,
found by live-running 0.33.1: `dream_create` succeeded (the 0.33.1 git-bash fix worked) but
`dream_list`/`dream_status` couldn't see the created dream.

- **MCP server resolved `$HOME` via `process.env.HOME`, which is UNSET on Windows.** The server
  runs as `node server.bundle.js` with no env block, so on Windows `process.env.HOME` is empty
  (Windows uses `USERPROFILE`). `dream.ts` `brainDir()`/`resolveKnowledgeDir()` fell back to a
  RELATIVE `.second-brain` — while the git-bash-spawned `dream-snapshot.sh` (HOME set by git-bash)
  wrote the dream to the real `~/.second-brain/dreams`. The two sides diverged, so created dreams
  were invisible to the read tools. Now node resolves home via `os.homedir()` (USERPROFILE on
  Windows, == `$HOME` on POSIX), and `dream_create`/`dream_accept` pass the node-resolved
  `BRAIN_DIR`/`KNOWLEDGE_DIR` into the git-bash spawn so both sides use identical paths.

`/upgrade` to 0.33.2 is a marker bump (no data migration).

## 0.33.1

Cross-platform + setup bug-fix release (no migration action). Three fixes found by live-running
the 0.33.0 plugin on Windows/Git-Bash:

- **dream_* spawned WSL bash instead of git-bash (`mcp-bash-wsl-shadow`).** On Windows with WSL
  installed, the MCP server's `exec("bash")` resolved to `System32\bash.exe` (WSL) via Machine-PATH;
  WSL mounts the drive at `/mnt/c`, so the `/c/...` msys script path didn't exist → `dream_create`/
  `dream_accept` failed with "No such file." Now the MCP server probes `Git\bin\bash.exe` explicitly
  on win32 (falls back to `bash`); POSIX unchanged.
- **`/second-brain:setup` false-collision on legacy `projects.jsonl` records.** `sb_project_identity`
  keyed collision on the freshly-detected `git_remote`, so a pre-0.33 4-field record being re-set-up
  on the SAME repo was flagged a collision once a remote became detectable. Collision now keys on the
  STORED identity: a legacy record with no stored identity lazy-fills as `same`; only a differing
  stored identity is a collision.
- **CI bundle-current gate.** Committed `mcp/dist` bundles had been built with a drifted local esbuild
  (passed the local gate, failed CI's lockfile-exact rebuild). Rebuilt all bundles via `npm ci`.

Also: the cross-OS test sweep (resolves the prior pre-existing Windows test failures across path-
separator, jq-CRLF, IFS-tab, symlink/flock/systemd capability-skips) landed in this line. No data
migration — `/upgrade` to 0.33.1 is a marker bump (the 0.33.0 projects.jsonl hardening already ran).

## 0.33.0

Project scoping model + attribution correctness (M3), plus a cross-OS hardening pass. Closes the
attribution incident (a setup scan filed 88 docs into the wrong project's inbox) and makes scoping
monorepo-aware.

- **Attribution incident fix:** capture derives its destination from the scanned resource (not the
  ambient session slug) and fails loud on mismatch; each raw item carries an `origin:` provenance
  field; the maintainer drain holds foreign-origin items out of the work-list; `dream` defaults its
  mining scope to the active project (`"all"` is the explicit cross-project opt-out).
- **M3 monorepo-aware scoping:** `projects.jsonl` gains optional `parent`/`root_path`/`git_remote`;
  `resolveActiveSlug` maps a cwd to its registered monorepo child by longest-prefix `root_path`;
  search adds a family tier (own > family > graph-neighbour > global > other); `sb_detect_project`
  auto-detects submodule / workspace-manifest / `.sb-monorepo.json` topologies into `<root>__<leaf>`
  slugs; `dream --family` mines the whole family. Standalone repos are the unchanged no-parent case.
- **Migration & setup-collision:** Layer-1 `projects.jsonl` hardening (backup-first canonicalize +
  dedup, in migrations/0.33.0.md); Layer-2 opt-in maintainer project-backfill (printed by upgrade,
  never auto-dispatched); Layer-3 setup collision detection by `{root_path, git_remote}` identity
  that prompts (path-qualified / rename / use-existing) instead of silently clobbering same-basename
  repos.
- **Cross-OS hardening (Windows/Git-Bash):** fixed path-separator + jq-CRLF + IFS-tab-collapse bugs
  across registry/resolver/search/validate/capture/dream-snapshot/kb-project-suggest; symlink- and
  POSIX-signal-dependent tests skip where unsupported (guards unchanged); a `.sb-monorepo.json`
  marker path-traversal was closed by sanitizing the parent slug.

See migrations/0.33.0.md for the one deterministic upgrade step (projects.jsonl hardening).

## 0.32.0

Post-Phase-1 hardening: four independent fixes from a design + adversarial-verify pass (one
design — a machine heartbeat — was REFUTED and dropped for a simpler clamp).

- **Heartbeat → clamp (task 14):** a machine heartbeat would have been redundant (the headless
  run is already capped at 30min « the 6h staleness horizon) AND a weaker liveness signal. Instead
  `SB_MAINTAIN_LLM_TIMEOUT` is clamped below `SB_DREAM_RUN_TIMEOUT`, so an operator override can
  never let a live headless dream age past the horizon and get wrongly reclaimed + double-spawned.
- **Persona slim (task 15):** the persona-card was injected per-prompt AND at SessionStart — a
  ~95% paraphrase of USER.md, ~330 tokens re-sent every prompt. Both injections removed (USER.md
  carries identity, loaded once per session); `persona_dismiss` wired from a phantom to real
  backoff (self-suppress after N dismissals in a window; explicit `/?` briefs unaffected).
- **MCP nested-spawn guard (task 16):** the 11 destructive knowledge-base write-tools now refuse
  under `SB_NESTED_SPAWN=1` — a headless `claude -p` over untrusted transcript content (reachability
  confirmed: alwaysLoad, no --allowedTools, env inherited) can no longer mutate the live wiki /
  dream state / PROJECT.md / USER.md unattended.
- **knowledge_validate autofix-default (task 17):** the MCP tool defaulted `autofix:true` — a
  casual model call could delete pages. Flipped to report-only; the model must opt into mutation.
  Internal automation passes `{autofix:true}` explicitly, so it is unaffected.

MCP knowledge-base 2.8.2 → 2.9.0. Each change is TDD'd against an independent oracle (filesystem
facts, spy call-counts, status.json mtime). See migrations/0.32.0.md for the one optional user
step (folding a hand-edited persona-card into USER.md).

## 0.31.0

**Restore the automation: un-starve + harden the hands-off pipeline.** The hands-off
design was fully built but had drifted to "manual" through operational *starvation* and
*silent failure* (not missing features). This release fixes the actual root causes.
MCP unchanged (2.8.2). **No migration action** — no on-disk schema/format change; old
dreams, wiki pages, `status.json`, configs are fully compatible, and the maintainer/dream
write the SAME structure as before (the upgrade just pulls the new code).

### Automation restoration
- **Drainer un-starved (root cause #1):** `extract-drain.sh` deferred on ANY live
  interactive session, so an always-on operator's timer almost never drained. A bounded
  staleness-escape (persisted consecutive-defer counter + oldest-pending-transcript age)
  now lets exactly ONE drain through when starvation crosses `SB_DRAIN_DEFER_MAX` (6) or
  `SB_DRAIN_STALE_MAX` (24h). Opt-in `SB_DRAIN_DEFER_PMODE_ONLY=1` relaxes the base verdict.
- **Slow-HW timeout:** `SB_DRAIN_EXTRACT_TIMEOUT` 120→240s (a Pi blew the old budget →
  `ec=124` → poison-pill); inline budget proof keeps it under the 7200s lock-stale threshold.
- **Loud silent failures (root cause #2):** new OS-aware SessionStart banner keys on the
  ACTUAL drainer signatures (`ec=124` timeouts + poison-pilled transcripts), with a
  Linux-vs-mac/Windows remedy. Kill switch `SB_DRAIN_HEALTH_BANNER=off`.
- **Headless maintainer bounded + self-healing:** never runs the `bypassPermissions`
  agent without a wall-clock cap (refuses if no `timeout`/`gtimeout`); self-heals a dream a
  "successful" spawn left non-`completed` (silent death) → `failed`.
- **One dream-staleness policy:** `sb_dream_is_stale` (status.json mtime > `SB_DREAM_RUN_TIMEOUT`)
  replaces four disagreeing definitions across snapshot/autostage/verify/maintainer; autostage
  now reclaims a stale RUNNING dream too. `SB_DREAM_PENDING_STALE` retired (superseded).

### Hygiene
- **Deps:** `npm audit --omit=dev` now clean — patched transitives pinned via overrides
  (fast-uri, brace-expansion, hono, ip-address, vite, protobufjs, qs); vitest →4.1.9. NO
  exploitable CVE existed (the vite KEV is a different project). Verified on Node 22
  (375/375 tests, 0 production vulns).
- **Debris:** deleted dead `migrate-to-{1.2.0,2.8.0}.sh` (unreachable by the 0.x runner,
  retiring the 0.24.16 "kept" note); `SB_DREAM_SUMMARIZE` now machine-enforced in
  `graph-cluster.sh`; `SB_DREAM_AI_BLOCKS`/`SB_RECONCILE` honestly downgraded to advisory
  in the prompts; removed dead `sb_clear_extraction_marker`; added
  `SB_PERSONA_SIGNAL_WINDOW_DAYS`/`SB_PROJECT_STALE_DAYS` overrides.

Cross-OS verified throughout (no GNU-only `stat`/`date`/`timeout`/`pgrep`). Every fix
designed + adversarially verified via workflow, then implemented test-first against an
independent oracle. New tests: dream-staleness, maintain-llm-drain-timeout-guard,
extract-drain-unstarve, lib-drain-timeout, drain-health-banner, verify-dream-staleness,
dependency-audit.

Post-review hardening (two deep-reviews). The first pass closed 3 LOW gaps: the age-based
starvation-escape is rate-limited (`SB_DRAIN_ESCAPE_COOLDOWN`); the B2 self-heal treats a
missing status.json as a silent death (retains the failure counters); autostage blocks on
ANY fresh running dream. A second FP-aware multi-agent code review then caught a real
REGRESSION the first missed: the un-starve escape forced a `claude -p` under a held OAuth
lock and could poison-pill GOOD transcripts (the exact failure the original defer prevents).
Fixes: the escape is now GATED on `ANTHROPIC_API_KEY` (curl/API backstop, lock-immune) or the
opt-in `SB_DRAIN_DEFER_PMODE_ONLY` + a timeout binary — under pure OAuth it keeps deferring and
relies on the loud banner instead; the age cooldown is stamped only on age-driven escapes (a
counter escape no longer suppresses it); B2 mints a fresh terminal status.json for a
corrupt/truncated one (an in-place jq edit would itself fail); the dep-audit test asserts the
override floor + fails closed on a sub-floor prerelease; dream-snapshot's reclaim sets
`.ended_at`; and the new banner helpers gained direct coverage.

## 0.30.2

**Stamps the release that #79 shipped un-versioned + drops EOL Node 20.** MCP 2.8.2.

### The version that never got bumped
PR #79 (`fix(cross-os): Windows path-separator slug/path bugs across MCP`) landed the 0.30.2
code and rebuilt the bundles but **never bumped the version** — `plugin.json` and
`marketplace.json` both stayed at `0.30.1`, and there was no `## 0.30.2` CHANGELOG entry, so a
fresh `git pull` on another machine reported `0.30.1`. The full CI suite was green on #79 because
**no test asserts a release actually bumped its version**: `test-upgrade-migration-row.sh` only
checks the CHANGELOG has a `## <plugin.json version>` heading (stale-but-consistent passes), and
`validate-plugin.sh`'s drift check only compares `plugin.json` against `marketplace.json` (both
stale → they agree → pass). Fixed here:
- `plugin.json` + `marketplace.json` → `0.30.2`; MCP server self-version → `2.8.2`.
- New **`test-release-version-bump.sh`** tripwire: when the working tree changes any shipped
  source (`mcp/src`, `mcp/dist`, `mcp/package.json`, `scripts`, `hooks`, `skills`, `agents`,
  `bin`, `systemd`, `.claude-plugin`) versus the base branch (`origin/main`, the previous
  release — a git fact, not a self-assertion), the plugin version MUST be strictly greater than
  the base's. Wired into CI with `fetch-depth: 0` so `origin/main` resolves. Closes the "shipped
  without a bump" class the existing tests miss.

### Deep-review fix (path-guard exception contract)
The release deep-review caught a regression #79 introduced: `realResolve`'s new Windows drive-root
seed (`realpathSync(driveLetter + sep)`) was the only `realpathSync` in the function **not** wrapped
in a try/catch. On Windows with a missing/unmapped drive root it threw a raw `ENOENT` instead of
degrading to a lexical path — leaking a raw `Error` past the helper's documented "returns, or throws
`PathGuardError`" contract (callers gate on `e instanceof PathGuardError`). Now wrapped in the same
lexical fallback the per-segment walk uses. POSIX-unaffected (the branch is dead code there).

### Node 20 → 22 (LTS)
Node 20 ("Iron") reached end-of-life 2026-04-30. The esbuild bundle `--target` was still
`node20` — actually *behind* the `node 22` CI already runs on. Bumped all 16 bundle targets (+ the
one in `test-episodic-index.sh`) to `node22` and added an `engines: { node: ">=22" }` floor to
`mcp/package.json`. The rebuilt bundles are **byte-identical** (the code uses no syntax esbuild
down-levels differently between node20 and node22), so this is a zero-behavior-change toolchain
bump — only the floor and intent move.

## 0.30.1

**Completes the cross-OS work that 0.30.0 shipped without** (a PR-merge race landed 0.30.0
one commit short). MCP 2.8.1.

### Windows jq CRLF — the systemic faucet
The Windows (Git-Bash) `jq` build emits **CRLF in `-r` output even when the input is clean LF**,
so every `$(jq -r …)` value, `jq -r … | grep`, and config read is `\r`-contaminated on Windows —
silently breaking comparisons, arithmetic, `grep '^x$'` patterns, and path building (the
user-reported "error from version 0.30" was this in the validator's version-drift loop, building
`…/\r/.claude-plugin/plugin.json`). Fixed at the leverage points and broadly:
- **Config reader** (`sb_config_get`/`sb_config_bool`) strips `\r` — one fix makes EVERY config
  knob (incl. the new automation defaults) CR-safe; without it `auto_improve: true` read back as
  `"true\r"` and fell through to the default on Windows.
- **Validator** drift loop + hook counts CR-normalized.
- **121** single-line `$(jq -r …)` captures across 29 scripts CR-stripped; `cost-router` tier
  counts strip `\r` *before* `grep -c`.
- New `test-jq-crlf-windows.sh` reproduces Windows jq with a stub and runs the REAL validator /
  config reader / cost-router under it (we can't run Windows in CI) — discriminating.

### Deep-review fixes (the review found real gaps in 0.30.0)
- **5 MCP write/stat handlers** (`pin_to_user`, `pin_to_project`, `archive_to_wiki`,
  `persona_stats`, `persona_dismiss`) fell back to an **uncleaned `HOME`** — under a CRLF-tainted
  HOME that silently wrote to a phantom `…\r/.second-brain` tree on POSIX (invisible data loss) /
  ENOENT on Windows. Each now wraps its HOME fallback in `cleanEnvPath`.
- `discover-installed.sh` frontmatter `awk '/^---$/'` → `/^---[[:space:]]*$/` (a CRLF `.md`
  fence never toggled). `session-load.sh` cleans up the CRLF-normalized temp copy (no leak).

## 0.30.0

Two themes: **automation on by default** + **cross-OS (Windows/macOS) hardening** from an
adversarial audit. MCP 2.8.0.

### Automation is ON by default
It's an automation plugin — a fresh install should self-maintain without the operator
remembering to opt in. `ensure-dirs.sh` now seeds `auto_improve: true`, `auto_maintain: true`,
`auto_accept: "safe"` (and the bash readers default the same when a key is absent). Existing
configs are never clobbered, and explicit `false`/`"off"` always wins. Notes:
- `auto_maintain` (headless `claude -p` — reads OAuth + spends tokens) **only runs where
  `bwrap` exists** (the airtight sandbox), so it's a no-op on macOS / Windows / bwrap-less
  Linux. Set `auto_maintain: false` for a zero-spend box.
- `auto_accept: "safe"` auto-accepts only LOW-RISK dream changes (no archives/deletes) and
  backs up the wiki first. Use `"off"` to keep every apply a manual review, `"all"` for max.
- `/second-brain:setup` now shows what's on and lets you dial it back, instead of opt-in.

### Cross-OS hardening (Windows Git-Bash + macOS/BSD) — 13 fixes, all reproduced on Linux
Root cause for the Windows breakage: a **CRLF-tainted env var** (`CLAUDE_PLUGIN_ROOT`, `HOME`,
`KNOWLEDGE_DIR`, `BRAIN_DIR`, a `PATH` segment) carries a trailing `\r`, and a path `"x\r"`
does not exist — so BOTH `bash <path>` AND `fs.stat/readFile` fail with a misleading "No such
file or directory" on a file plainly present (the confirmed `dream_create` signature).
- **New `cleanEnvPath` helper** (`path-guard.ts`) strips CR/LF; applied at every env-path read:
  `toBashPath` + `scriptsDir`/`brainDir`/`resolveKnowledgeDir` (dream.ts), `server.ts`
  (KNOWLEDGE_DIR/BRAIN_DIR — a CR taint silently zeroed `knowledge_stats` + all wiki tools),
  `sb.ts` `hasClaudeOnPath` (per-PATH-segment, so an installed `claude` isn't missed),
  `sb-entry.ts`, `doc-sources.ts` (`git -C <root>`), the raw/doc CLIs, and `project-dir.ts`
  `slugFromProjectDir` (parity with bash so the slug never split-brains).
- **Bash CRLF + slug:** `sb_slug_from_dir` strips `\r` (no ghost `proj\r` project);
  `merge-project-update.sh` and `session-load.sh` CR-normalize PROJECT.md once before the awk
  readers (a CRLF PROJECT.md otherwise silently no-ops the whole merge AND zeroes every
  session-load scope counter + the wiki-enrichment harvest); the extractor's frontmatter strip
  `tr -d '\r'` first (a CRLF archive's `---\r` defeated the terminator and deleted the whole
  transcript).
- **macOS/BSD coreutils:** `lib.sh` archive-prune `stat` is now GNU-first
  (`stat -c %Y || stat -f %m`); `sb_validate_wiki` uses `mktemp` (honors `$TMPDIR`, no race);
  `discover-installed.sh` replaces the GNU-only `find -quit` with a portable `head -n1`.
- **Tests:** discriminating coverage added for `toBashPath`/`cleanEnvPath` CR-stripping
  (vitest), `sb_slug_from_dir` CR, and a CRLF-PROJECT.md session-load harvest (each verified to
  fail on the pre-fix code).
- **Known follow-up:** `persona_think`'s `spawn('claude')` still needs a Windows-specific launch
  (`.cmd`/`shell`) — deferred because the naive `shell:true` mangles its multi-line
  `--system-prompt` arg; tracked for a dedicated fix. The Opus advisor is optional and
  Linux-first, so the backbone is unaffected.

## 0.29.4

**Output-correctness wave — 4 silently-wrong-output bugs found by an adversarial
multi-agent audit (every finding reproduced by running the script).** All exit 0 while
emitting wrong/incomplete content, so weak tests missed them.

1. **`session-load.sh` — every session silently lost project wiki recall** *(highest
   impact).* The `PROJ_KW` keyword harvest used awk **range** expressions
   `/^## X$/,/^## /` whose START line also matches the `^## ` END pattern, collapsing
   each range to its header → the harvest was **always empty** → the wiki-enrichment gate
   never fired → the project's relevant wiki notes never loaded at session start. The same
   trap the comment at ~line 188 already fixed for the Never-rules block. Now uses
   in-section flags. New `test-session-load-wiki-enrichment.sh` (node-stub sentinel oracle)
   is discriminating.
2. **`grep -c … || echo 0` → `0\n0` (12 sites: cost-router-capture ×6, lib.sh ×3,
   merge-project-update ×3).** `grep -c` prints `0` *and* exits 1 on zero matches, so
   `|| echo 0` fired too — making counts the two-line string `0\n0`. In cost-router this
   split the escalation bullet (orphan count line on the zero-escalation happy path that
   the orchestrator reads); in merge-project it broke the supersede `$((overlap*100/old))`
   integer math. Fixed to `|| true` (grep already prints its own `0`).
3. **`wc -l` dropped a no-trailing-newline final transcript line** (stop-extract:97 +
   pre-compact:63) — and the marker advanced past it, losing it **permanently**. The Stop
   hook can read the transcript before the final newline flushes; `wc -l` counts newlines.
   Now `awk 'END{print NR}'` (record-count, newline-safe).
4. **`persona-context.sh` keyword filter `grep -vwF` shredded hyphenated identifiers**
   (`is-prod`, `node-is-modules`) because `-w` treats a hyphen as a word boundary, so a
   stopword *segment* matched and dropped the whole identifier — undoing the tokenizer's
   deliberate hyphen-preservation. Fixed to `-vxF` (whole-line match).

**Test oracles hardened** (the audit also flagged each test's weakness): cost-router now
exercises the zero-escalation branch + an orphan-count-line guard; stop-extract seeds a
no-trailing-newline final record and asserts it's archived + the marker reaches the true
count; session-load + persona gained the coverage they entirely lacked. Each new check
verified **discriminating** (fails on the buggy code, passes on the fix).

## 0.29.3

**cost-router telemetry: stop silently dropping the Escalation + Notes bullets.**
- `cost-router-capture.sh` built 6 markdown bullets with `printf '- …'` — a format
  string starting with `-`, which **bash `printf` parses as an option flag**
  (`printf: - : invalid option`). Every Stop-hook run therefore emitted the
  `## Escalation` and `## Notes` headings with **all their bullets dropped** — and
  `/cost-router:orchestrate` + `/cost-router:model-route` READ that page to bias tier
  decisions, so they were consuming blank escalation data on every machine. Fixed with
  `printf -- '- …'` (stops option parsing; bash-3.2/BSD-safe). Whole-repo swept — this
  was the only file with dash-led `printf` formats.
- **Test oracle hardened (task #43 in microcosm):** `test-cost-router-capture.sh`
  asserted only `grep -qiE 'escalat'` — which passed because the **`## Escalation`
  heading itself** matches the word, even with every bullet gone. It now asserts the
  actual bullet + its counts (`Total escalated to Opus: N of M`) AND a general
  structural oracle: **no `## section` may be empty** (heading → blank → next heading =
  dropped content). Verified discriminating — the structural check flags
  `[Escalation] [Notes]` on the buggy script, passes on the fixed one. Catches any
  future content-drop, not just this `printf` class.

## 0.29.2

**Finish the CRLF hardening — close the 15 frontmatter regexes 0.28.3 missed (MCP 2.7.7).**
0.28.3 made `parseDoc` + the `missing_frontmatter` check tolerate `---\r\n`, but
**15 other LF-only `^---\n` frontmatter regexes** across the KB pipeline were left
behind — so a CRLF page (Windows / `autocrlf` / `import-host`) was mis-handled by
everything else. Most consequential: the incomplete-frontmatter **detection**
(`isIncompleteFrontmatter`) and **patch** (`patchFrontmatter`) returned no match on a
CRLF page, so an imported page lacking required fields was silently **never flagged
and never patched** — un-healable by the automation, the exact "the plugin creates an
issue you can't fix" class. Now CRLF-tolerant (`^---\r?\n … \r?\n---`) in:
- `knowledge-validate.ts` (×7 — detect, patch, normalize, addFrontmatter guard, ai-block strip)
- `graph-project.ts` (×4 — related: projection read + write-back)
- `graph-cluster-cli.ts` (×2 — cluster frontmatter parse/strip)
- `test-oracle.ts` (×2 — the js-yaml oracle itself)

The match is CRLF-tolerant; the write-back normalizes the fence to LF (parses clean,
stays idempotent). New CRLF round-trip test (`knowledge-validate.test.ts`) verified
**discriminating** — a CRLF page is detected + patched + the result is js-yaml-valid +
idempotent with the fix, and FAILS (page silently un-flagged) without it. Oracle =
real js-yaml via `test-oracle`, never a re-implementation of the validator.

## 0.29.1

**KB self-heal: generated state pages are born VALID (stop the autofix↔regenerate churn).**
- `sb_write_generated_page` (lib.sh) emitted only 6 of the 7 canonical
  `REQUIRED_FM_FIELDS` — it omitted `tags` and `related`. So every Stop-hook
  regeneration of `wiki/state/cost-routing-patterns.md` was born INCOMPLETE:
  `knowledge_validate` autofix patched `tags:[]`/`related:[]` on each reindex, then
  the next regeneration stripped them again — an eternal churn loop the user could
  never fix by hand (the plugin re-created the issue every session). The helper now
  emits `tags: []` + `related: []` (byte-identical to what the autofix and the graph
  projector write for an edgeless page), so the page round-trips clean and self-heals
  on the next regeneration after deploy. This is the "stops churning" the helper's
  own contract already claimed.
- **Test oracle hardened (independent-oracle principle):** both
  `test-lib-generated-page.sh` and `test-cost-router-capture.sh` asserted a
  *handpicked* subset (title/type/generated/marker) and called it "born-valid" — so
  they stayed green while the page was actually `incomplete_frontmatter` by the real
  validator. They now derive the required-field set **directly from
  `knowledge-validate.ts`'s `REQUIRED_FM_FIELDS`** and assert every field is present,
  so the test tracks the validator and cannot drift. Verified discriminating (fails
  with `tags`/`related` stripped, passes with the fix).

## 0.29.0

**Command-surface collapse + SessionStart priority-rule guarantee.**
- **Surface collapse:** hid 5 skills from the user slash menu, each because its
  capability is now owned elsewhere — so hiding the *command* loses nothing:
  - `status` / `query` / `lint` — still **model-invocable** (`dmi:false`) and
    backed by MCP (`knowledge_stats` / `knowledge_search` / `knowledge_validate`,
    the last also auto-running with autofix on every reindex) plus the SessionStart
    banner. The model reaches them on request; the user no longer needs the verb.
  - `capture` — capture is **automatic**: the hook capture path (raw-capture CLI)
    ingests material and `/second-brain:maintain` drains the raw inbox into notes.
  - `improve` — session-insight capture is **automatic**: dream mines transcripts
    into wiki pages, and `pin_to_user` / `pin_to_project` record pins on request.
  - `doubt` (dev-QA adversarial review) is intentionally **kept visible** — it has
    no automation replacement (`dmi:true` too), so hiding it would strand a dead
    skill. Correctness over surface count.
  - The KB stays correct via automation (dream / maintainer / `knowledge_validate`
    autofix on reindex), not manual commands. The raw-inbox banner now points at
    `/second-brain:maintain` (the automated drain) instead of the now-hidden
    `/capture`.
- **SessionStart cap fix (source, not symptom):** forced priority-1 sections
  (USER.md + PROJECT.md, emitted `force` at the END) could be pushed past Claude
  Code's 10K-char hook ceiling by the budget-gated banners ahead of them — and the
  ceiling truncates from the END, dropping the very Never/Always rules `force`
  guarantees. `session-load.sh` now RESERVES the forced sections' actual bytes
  from the banner budget, so banners yield and the rules always land. New test
  `test-session-load-budget-reserve.sh` is discriminating (output 9.1K with the
  reserve vs 10.8K — over the cap — without it).

## 0.28.3

**Two more from the ship-readiness hunt (every candidate reproduced).** MCP 2.7.6.
- **CRLF frontmatter** (Windows / git autocrlf): the readers/validator hard-coded
  LF `^---\n`, so a `---\r\n` page lost its whole frontmatter — and worse, the
  validator saw "no frontmatter" and autofix PREPENDED a second block, corrupting
  the page on every reindex. `parseDoc` and the validator's detector now use
  `\r?\n`. (Other fence regexes are LF-only too but operate on plugin-written LF
  content — noted for a follow-up; these two were the read-loss + corruption pair.)
- **Generated MOC `title:`** was emitted unquoted (`title: ${proj}`) while 0.26.0
  only quoted `description:` — an author-controlled `project:` facet with a colon
  produced invalid YAML. Both now use JSON.stringify (valid double-quoted scalar).
- New oracle test: a CRLF page is read by parseDoc AND not double-blocked by the
  validator. Verified the title fix across colon/quote project names.

The other 9 hunt candidates were verified NON-blocking (atomicWriteJson's
swallow is intentional fail-soft; the dedupe multi-line edge needs a malformed +
multi-line-quoted + duplicate-key triple-coincidence that cannot occur; the rest
minor/edge) — not fixed, to avoid churn for non-bugs.

## 0.28.2

**macOS/BSD portability: GNU-only regex escapes that silently matched nothing.**
A ship-readiness bug-hunt (fresh-install / portability / runtime / supply-chain
/ hooks, every candidate reproduced before counting) surfaced GNU-sed/grep
escapes that BSD treats as the literal char — so on macOS they stripped/matched
NOTHING, silently:
- `sb_strip_ansi` (lib.sh) used `\x1b`/`\x07` hex in `sed` → on BSD it stripped
  no pty escape codes, leaking ANSI into extracted wiki content. Now builds the
  literal control bytes in bash (`$'\xNN'`, the idiom persona-tool-guard already
  uses) and matches them directly.
- `stop-verify-gate` / `extraction-quality-gate` used `\b…\b` word-boundaries in
  `grep -E` (GNU-only) → the test-run-detection and vague-word gates never fired
  on macOS. Now `grep -wE`. The same gate's `\.\w+` → `\.[A-Za-z0-9_]+`.
- `persona-context` used `\+` (GNU BRE) to trim keyword hyphens → no-op on BSD.
  Now `*`.
- Portability scanner gains rule 11: no `\b \w \s \d \xNN` inside a sed/grep
  program — so this whole class can't regress. New `test-strip-ansi.sh` asserts
  the strip via a byte-level oracle (no ESC/BEL/CR survives).

Fresh-install dimension came back clean. Linux behaviour is unchanged (the new
forms are byte-identical to the old GNU ones on GNU).

## 0.28.1

**Manual dream-accept now backs up live first (reversibility symmetry).** Only
the *auto*-accept path tarballed the live wiki before applying; a **manual**
`dream_accept` (or the `/second-brain:dream` Review phase) overwrote live with no
undo — surfaced live during the first real headless-maintainer test. `dream-accept.sh`
now tarballs the live wiki to `~/.second-brain/wiki-backup-pre-accept-*.tgz`
before the destructive rsync, and **fails closed** (refuses the accept) if the
backup can't be written — a disk-full/unwritable state is exactly when an
overwrite would be unrecoverable. The auto path already backs up, so it passes
`SB_DREAM_ACCEPT_SKIP_BACKUP=1` (one tarball, not two). Restore with
`tar xzf <tgz> -C "$KNOWLEDGE_DIR"`. Tested with a round-trip oracle (extract the
tarball, assert it reproduces the pre-accept wiki) + a fail-closed + skip case.

## 0.28.0

**Setup-time autonomy consent — opt in once, no JSON editing.** The consent
ladder (`auto_improve` / `auto_maintain` / `auto_accept`) was display-only: the
0.25.0 autonomy code shipped but stayed dormant because nothing wrote the keys
and `setup` was forbidden to. Now `/second-brain:setup`'s step 6c is interactive:
it presents the three tiers, asks the operator to choose explicitly, and persists
their choice — without ever flipping a default behind their back (it writes only
the tiers they pick, only under an explicit `/setup`, and defaults every answer
off).

- New `scripts/set-autonomy.mjs` — the single, dependency-free writer, run under
  setup's existing `Bash(node *)` grant (no new permission surface). It writes
  booleans as real JSON booleans (the `sb_config_bool` "false-trap"), keeps
  `auto_accept` a string enum, merges per-key so `retention.*` is never
  clobbered, writes atomically (tmp+rename in `BRAIN_DIR`), refuses to clobber a
  corrupt config, and **refuses to enable autonomy inside a nested plugin spawn**
  (`SB_NESTED_SPAWN=1`) — fail-closed by design.
- Enabling `auto_maintain` now prompts setup to SHOW (never run) the
  `install-extract-timer.sh` command, defaulting to the hardened no-credentials
  unit; `--oauth` (which grants the background service `~/.claude` OAuth access)
  is called out as a distinct second consent. Linger stays printed-not-run.
- `test-set-autonomy.sh`: oracle is jq on the real file PLUS a round-trip through
  the real `sb_config_bool`/`sb_config_get` readers — proving writer and reader
  agree on types — plus fail-closed checks (invalid value, nested spawn, corrupt
  file all leave config untouched).

## 0.27.0

**Command-surface collapse + ledger contract test.** Review follow-through on
the automation axis.
- `review` and `recall` are no longer user slash commands (`user-invocable:
  false`) — the SessionStart banner already surfaces `review`'s status, and
  `recall` is covered by the `episodic_search` MCP tool + the search-conversations
  agent. Both stay model-invocable, so no capability is lost; the user's command
  surface shrinks toward the intended core (setup / track / maintain / dream).
  Conservative on purpose: woven or independently-valuable commands (`query`,
  `audit`, `status`, `improve`, `capture`, `code-review-deep`) are kept.
- New cross-writer contract test: the two independent premium-spend ledger
  writers — `recordOpusLedger()` (TypeScript, second-brain) and `ob_record`
  (bash/jq, cost-router) — are asserted to emit the IDENTICAL key set against
  the real on-disk JSON each produces, so a field added to one can no longer be
  silently dropped by the other.

## 0.26.0

**Review-driven correctness + build hygiene** (MCP 2.7.5, cost-router 0.2.1).
Findings from a four-axis deep audit (data-quality, automation, cost-router,
code-size).

Data correctness — the runtime now uses a REAL YAML parser where it counted:
- `knowledge_validate` detects malformed frontmatter with `yaml.load()` instead
  of two hard-coded regex shapes. This catches the live failure classes the
  regex missed — duplicated mapping keys (the reader returned the STALE first
  `updated:` value, corrupting the recency boost) and unquoted values containing
  a colon — and can never again diverge from real YAML validity. js-yaml is now
  a runtime dependency. Autofix gained duplicate-key collapse (keep the freshest
  value). A new oracle test asserts the detector flags EXACTLY the pages a real
  parser rejects.
- Project MOC frontmatter is quoted (and drops the inner colon) so every
  generated `projects/*.md` is valid YAML — previously invalid on every reindex.
- The dream-runner is instructed to write the canonical `related: [a, b]` inline
  form, not the invalid bracketless `related: [[a]], [[b]]`.

cost-router:
- SessionStart banner no longer fires on `compact` (output is silently dropped
  post-compaction, upstream #15174 — matches the root hooks' stance).
- The premium-spend line shows only when spend was actually recorded today, so a
  standalone install stops advertising a permanent, misleading `$0.00`.
- README pricing states one baseline instead of two contradictory framings.

Build hygiene — tracked `mcp/dist/` is now ONLY the 16 self-contained
`*.bundle.js` that actually run (mcp.json launches `server.bundle.js`); the 176
per-file `tsc` artifacts that nothing imports at runtime are untracked and
gitignored. `build` typechecks without emitting them. `verify.sh` probes the
bundle that launches. Removed dead `stop-hook-predicate.sh`.

## 0.25.0

**Autonomy: gated auto-accept + consent ladder.** The headless dream pipeline
can now self-apply to the live wiki, behind a new `auto_accept` config key
(default `"off"`):
- `"safe"` applies only dreams with zero FORGET-archives and zero deletions
  (reversible consolidation); `"all"` applies any completed dream.
- Every auto-accept tarballs the live wiki first; FORGET stays a reversible
  move (never delete). The headless path requires `auto_maintain` too, so full
  unattended operation is a layered, explicit two-consent opt-in.
- The decision is a pure, directly-tested function (`sb_auto_accept_decision`)
  — 7 input→output cases incl. the safety-critical safe-refuses-forget gate.
- New three-tier consent ladder (auto_improve/auto_maintain/auto_accept, all
  default off) documented (wiki: autonomy-consent-ladder) and presented by
  `/second-brain:setup`.
Marketplace default unchanged (all off — nothing reaches the live wiki
unattended without explicit opt-in). The command-surface collapse is tracked
as a follow-up.

## 0.24.50

**Deep-review correctness batch + test-quality start.**
- **P4**: dream-snapshot `cp -r` reset all staged mtimes to "now" → dream-accept
  rsynced them onto live → the FORGET age-gate was re-armed corpus-wide every
  accepted dream (silently neutering the recency fix). `cp -rp` preserves mtimes.
- **P8**: episodic text-search similarity was a constant 0.5 and results were
  sliced unsorted (arbitrary truncation). Now varies by term-frequency density,
  sorted before slicing.
- **P7**: per-prompt episodic recall used mode:'vector' with no fallback —
  silently empty without the embedding model. Now mode:'both'.
- **P9**: episodic index / access-counts / dream status written non-atomically
  → crash mid-write corrupts them. Now tmp+rename (shared atomicWriteJson).
- **Test quality (user-raised: 506 green tests missed 14 bugs)**: added a real
  js-yaml oracle (test-oracle.ts) + rewrote the high-severity graph/reindex/
  validate tests that re-read the projector's output through the SAME tolerant
  regex that masked the original invalid-YAML bug. Plus discriminating oracle
  tests for episodic ranking and atomic writes.

MCP server 2.7.4. An audit found 53 tautological tests; the rest are tracked.

## 0.24.49

**Correctness wave (deep-review P1/P2/P3/P5).** The same bug class shipped
again in 0.24.48 — three interaction bugs made reindex non-idempotent on a
graph-enabled wiki. Fixed as one unit so the projector/validator/parseDoc trio
agree on the canonical empty shape `related: []`:
- parseDoc: `related: []` is authoritative — body-`[[link]]` scrape fires only
  when the key is ABSENT (was: whenever the list was empty → re-filled the
  projector's cleaned pages → false related_drift forever).
- patchFrontmatter: emits `related: []` on graph-enabled corpora instead of
  body-deriving a value the projector would overwrite (the oscillation).
- orphan-GC: admits edgeless pages with a legacy block-list `related:`, not
  just the inline form → stale/dead links finally scrubbed.
- Deleted a duplicate `sb_validate_wiki` (lib.sh) that shadowed the
  count-returning def, killing dream-accept's convergence telemetry.
- **Root-cause gate**: added js-yaml (DEV-only — never in the shipped bundle)
  + a parse-validity property test asserting projector/validator output is
  always valid YAML. This closes the structural cause of the whole
  "not-working logic" family — there was no real parser anywhere, so every
  test re-read through the same tolerant regex. Plus a duplicate-function lint
  guard in test-script-portability.

MCP server 2.7.3. Run `/second-brain:reindex` once.

## 0.24.48

**Node-shape convergence (user-requested).** Lint, the maintainer, and the
dream now shape every node to one canonical form, differing only in INPUT
(maintain=live wiki, dream=staging from past sessions):
- `knowledge_validate` autofix extended into a full frontmatter shaper —
  `incomplete_frontmatter`/`patch_frontmatter` fills ONLY absent required
  fields (never overwrites, never invents `created`/`updated`=today; derives
  from body date / slug date / mtime). Plus a WARN-only `related_drift` check
  surfacing where `related:` disagrees with the edge graph (detection only —
  the projector stays the sole writer).
- The dream runs the maintainer's exact shaper on its STAGING dir at
  `dream_accept` (new `sb_validate_wiki` helper), BEFORE merging onto live —
  killing the format drift between the two engines.
- Fixed `extractYamlValue`: an empty quoted value `description: ""` parsed to a
  stray `"`, corrupting MOC descriptions and breaking reindex idempotency.
- Maintainer Phase 4b now also re-shapes STALE existing ai-blocks (via
  `knowledge_validate`'s `ai_block_incomplete`), not just blockless pages.

MCP server 2.7.2. Run `/second-brain:reindex` once to patch incomplete pages.

## 0.24.47

**Wiki graph-pipeline repair (user-reported).** Five coupled bugs, root-caused
by a parallel investigation and each regression-tested:
- **Formatter**: the projector emitted invalid YAML `related: [[a]], [[b]]`
  (bracketless multi-item) and orphaned legacy block-list children — ~86% of
  live pages were affected, masked because every in-tree reader is a tolerant
  regex extractor. Now emits canonical `related: [a, b]` (β), valid YAML,
  matching the sibling emitter and reader.
- **Orphan-GC**: an edgeless page was *skipped*, so a node that lost its only
  edge kept its stale `related:`/`## Dependencies` forever. Now edgeless-but-
  dirty pages are scrubbed to `related: []` and the block removed.
- **Dangling/noise**: the projector re-emitted links to deleted pages. Now
  `current` edges are filtered to live page slugs (∪ project-facet MOC targets,
  preserving idempotency).
- **FORGET**: recency decayed over 180d while the candidate floor (0.15) sat
  above the reachable score, so FORGET emitted zero candidates. Now a 90-day
  window (`SB_FORGET_RECENCY_DAYS`); a regression test asserts a 90-day orphan
  is an actual candidate.
- **Lint normalizer**: `knowledge_validate` gains a dependency-free
  `malformed_frontmatter` detector + `normalize_frontmatter` autofix (runs every
  reindex/maintain) — re-serializes invalid `related:`/`tags:` and drops orphan
  lines, so the formatter is enforced on every update and the ~125 corrupted
  pages self-heal on the next consolidation. MCP server 2.7.1.

Run `/second-brain:reindex` once after upgrading to heal existing pages.

## 0.24.46

**R7a observability.** (1) `scripts/liveness-check.sh` — the
shipped-vs-running gate (three past audit findings were this ONE missing
check): per-plugin deployed-at-shipped-version probe against
installed_plugins.json, cost-router bridge freshness, episodic-indexer
keep-up, dangling vector-deps symlink. Advisory lines (OK/DRIFT/DORMANT/
STALE/MISSING); `--strict` for the release checklist; wired into
`/second-brain:review`. (2) `scripts/hook-timer.sh` — transparent latency
wrapper on the 5 heavy hooks (session-load, persona-context, stop-extract,
pre-compact, dream-autostage): appends `{kind:"latency", hook, duration_ms,
exit_code}` to the audit-log, flags runs >70% of the hook budget;
`/second-brain:status` renders p50/p95 per hook. The R1 ec=124 class becomes
visible before it bites. No user action — lands with the cache refresh.

## 0.24.45

**De-cap (user decision): premium spend is reported, never enforced.** The
hardcoded daily Opus cap is REMOVED from both plugins — premium-tier models
change over releases (Opus today, Fable next), so no dollar limit is keyed to
a model name anymore. cost-router 0.2.0: `opus-budget.sh over` removed
(ledger informational, cap_usd no longer written), SessionStart banner now
reads "premium-model spend today: $X (informational)", orchestrate skill
reports spend instead of gating THINK on it. second-brain: persona_think no
longer skips on a maxed ledger (spend still recorded after every call);
persona-think CLI prints the day's spend as an informational line. MCP server
2.7.0. `COST_ROUTER_OPUS_CAP_USD` / `SB_PERSONA_DAILY_BUDGET` are inert.

## 0.24.44

**R8 process hardening.** (1) Minimal CI (`.github/workflows/ci.yml`):
SHA-pinned official actions only, read-only token; Linux job runs tsc +
vitest + bundle-current gate + full bash suite + validator; macOS job runs
the dream-lifecycle + portability tests on real bash 3.2/BSD (closes the
standing PROJECT.md macOS item). (2) Bundle-current gate
(test-bundle-current.sh): every committed mcp/dist bundle must byte-match a
rebuild from committed src (0.24.7/0.24.8 stale-dist class). (3)
validate-plugin: version-drift now iterates EVERY marketplace plugin
(cost-router was unchecked); surface budget (docs/surface-budget.json) fails
undeliberate growth in skills/agents/scripts/tests; SKAG-6 — user-invocable +
disable-model-invocation must be explicit in every skill; the upgrade-runner
8KB cap enforced in the validator as promised. (4) Permission-dialect
canonicalization: 10 skills' short-form `mcp__knowledge-base__*` grants (dead
at runtime) swept to the live-verified `mcp__plugin_second-brain_knowledge-base__*`;
guard now rejects the short form. (5) run-all: suite-temp
HOME/BRAIN_DIR/KNOWLEDGE_DIR for every bash test (kills the real-KB leak
class structurally) + wall-time in the summary. (6) RELEASING.md tag contract
re-aligned to merge-gated releases (tags optional). No user action.

## 0.24.43

**R6b per-prompt diet.** (1) New combined `context-serve-cli` answers the
per-prompt wiki AND episodic lookups in ONE node process — persona-context.sh
paid two cold-starts on every UserPromptSubmit (measured live on the Pi 5:
2.18s -> 1.38s per prompt). Falls back to the two-CLI path on a stale cache;
wiki section byte-identical to knowledge-search-cli. (2) Log hygiene:
`gate=*` breadcrumbs logged at exit_code 0 are trace, not errors — routed to
audit-log.jsonl (they were ~41% of error-log lines and polluted verify.sh's
freshness check); both logs now rotate at 512KB keeping the newest 1000 lines.
No user action — lands with the cache refresh.

## 0.24.42

**R6a surface diet.** (1) The upgrade skill's 113KB migration table split: lean
3.4KB runner + `skills/upgrade/migrations/<version>.md` (7 actionable files) +
this CHANGELOG (58 narrative-only rows moved here; never context-loaded). A
typical upgrade hop now costs <2K tokens instead of ~44K. Policy gated:
CHANGELOG entry per release, 8KB runner cap. (2) The 5 vendored
obra/superpowers skills (brainstorming, systematic-debugging,
test-driven-development, verification-before-completion, writing-plans) are
REMOVED — install the upstream superpowers plugin (the setup skill warns when
absent; NOTICE.md documents the de-vendor). Kills the doubled skill-list
tokens and nondeterministic dual-dispatch. (3) Dead-weight sweep:
batch-extract.sh deleted (hardcoded --bare, unreferenced), lib.sh dead dream
helpers deleted, run-all.sh's tree-dirtying chmod block deleted (exec bits are
git-recorded; test-exec-bits now globs all tests), stale hooks.json
dream-autostage comment rewritten to the real C5-A/R4 behavior.

## 0.24.41

**R4 dream lifecycle: auto_maintain fails loudly, never silently.** (1) The OAuth systemd unit drops `RestrictNamespaces=true` — it made the maintainer's bubblewrap jail structurally impossible (100% failure, stuck-pending dreams); bwrap IS the containment there. Re-run `bash $CLAUDE_PLUGIN_ROOT/scripts/install-extract-timer.sh --apply --oauth` to deploy the updated unit. (2) A bwrap preflight runs BEFORE staging; failures re-stamp the throttle to a 24h retry (not a burned weekly slot) and quarantine after 3 strikes (`~/.second-brain/.llm-maintain-quarantine`, surfaced at SessionStart; SELF-CLEARS once the preflight passes again — e.g. after the unit redeploy — or on success, or by deleting the file). (3) Headless failures transition the dream `pending→failed` with captured stderr; autostage reclaims stale pendings (>24h, runner never started) into failed and banners them. (4) Snapshot prune reclaims failed/canceled staging (status.json kept); retention GC (`bak_ttl_days`) now runs without the `auto_improve` opt-in.

## 0.24.40

**R5.1 cost-router honest pipeline** (cost-router 0.1.2 in lockstep). (1) route-log no longer drops empty-models events; classifier nudges are high-precision (word-bounded THINK, `refactor`/`security` dropped, DO + short prompts silent — every prompt still logs); `opus-budget.sh spent` is a pure read; over-cap banner says "over cap". (2) Orchestrate examples dispatch the cr-* agents (`subagent_type`); the fabricated Step-7 budget line now reads the real ledger. (3) **Generated-page contract**: new `sb_write_generated_page` lib helper; the cost-routing-patterns page moves to `wiki/state/` with born-valid frontmatter — ends the knowledge_validate churn loop. The capture hook removes the stale root-level page automatically (only when it carries the generated-by attribution line) — no manual step. (4) cost-router's own hooks honor `SB_NESTED_SPAWN` (closes the R1 deferral); setup skill drops its unused `rm` grant.

## 0.24.39

**R2 search-serving.** (1) **Hub-proof ranking**: graph/related boosts computed from frozen pre-boost base scores, capped at ≤1× each page's own base, `relates` weight 0.25; relevance floor uses base scores in BM25-only mode. Fixes exact-title pages being floor-evicted by hub-inflated scores. Deliberate contract change: zero-text-relevance pages no longer ride the graph into results (`knowledge_neighbors` is the discovery tool). (2) **Honest output** — knowledge_search adds `score_norm` (0..1) and `tier` (when project-scoped) per candidate and `degraded:'bm25-only'` at result level; episodic_search adds `degraded:'text-only'`; raw `score` semantics unchanged (`KNOWLEDGE_MIN_SCORE` contract intact). MCP server 2.6.9. (3) **Eval integrity** — hub-distractor fixture, strict recall=1.0 gate on the curated fixture, `wiki-recall-check.sh --live-titles` probe (lint check 5), and hermetic access-counts: the search engine now resolves `access-counts.json` via `SB_BRAIN_DIR`/`BRAIN_DIR` (eval/test runs no longer read or pollute live state — the live file contained ONLY test artifacts and was reset, backup kept as `access-counts.json.bak-r2-cleanup`). (4) **Embeddings self-heal** — `install-vector-deps.sh --relink-only` (never downloads) runs automatically at SessionStart when the cache symlink is missing; coverage % in `/second-brain:status`.

## 0.24.38

**R1 extraction-loop fixes (deep-dive wave 1).** (1) **Nested-spawn circuit breaker** — capture/context hooks no-op under `SB_NESTED_SPAWN=1`, which the drainer/maintainer/quality-gate spawn sites now export (drainer spawns also run with cwd in `~/.second-brain/scratch`); never set it in a live session or capture goes dark for that session. Security guards (PreToolUse/PostToolUse/ConfigChange) deliberately do NOT honor it. (2) **Session-keyed extraction markers** — `.last-extracted-line-<slug>--<session_id>`, advancing instead of cleared per Stop (ends the duplicate re-archiving class), with a stale-marker clamp (marker past EOF resets to 0); the substantive gate and dream-mining archive now cover the FULL unprocessed delta while only the LLM input is window-capped. Legacy slug-keyed markers are inert and swept by the drainer's 30-day GC. (3) **Drainer budgets** — drainer extractor timeout is the new `SB_DRAIN_EXTRACT_TIMEOUT` (default 120s; the in-hook paths keep `SB_EXTRACT_TIMEOUT` at 25s/30s so a drainer override can't blow the 45s hook budget), input tail-capped at 200KB (`SB_EXTRACT_MAX_BYTES`), sub-1KB archive bodies with a valid header marked done without an LLM spawn (`SB_DRAIN_MIN_BYTES`), mkdir-lock staleness 1800s→7200s; subagent capture skips workflow StructuredOutput holding-message stubs (other trailing tool calls still archive). (4) **MCP server 2.6.8** — `episodic_read` rejects paths outside `~/.second-brain/transcripts` (closes the G-MCP-1 entry point missed in v0.21.0); bundle rebuilt.

## 0.24.37

**Cost-router integration fixes (deep-review).** Post-merge fixes to the 0.24.36 consumers; all additive and no-op when cost-router is absent. (1) **`cost-router-capture.sh` aggregated nothing** — its `jq -r` queries over the JSONL events file were missing `-s` (slurp), so on multi-line input every count came out 0 and the `cost-routing-patterns` page was effectively empty (the learning loop was inert). Fixed: slurp a bounded window (`tail -n 500`) before aggregating; a new `test-cost-router-capture.sh` assertion checks a NONZERO tier count so the class can't regress. (2) **Events-path contract drift** — capture resolved the events file via `${BRAIN_DIR:-…}` while the producer (`route-log.sh`) uses `${SB_BRAIN_DIR:-…}`; aligned to `${SB_BRAIN_DIR:-${BRAIN_DIR:-<brain>}}` so writer and reader always agree. (3) **`persona-think` ledger hardening** — the ledger path now falls back to `opusLedgerPath()` (honoring `COST_ROUTER_LEDGER`/`SB_BRAIN_DIR`) instead of silently skipping when no `brainDir` is injected; the `brainDir!` non-null assertion is now a guard; `recordOpusLedger` writes atomically (temp+rename) to match `opus-budget.sh`; `server.ts` honors `SB_BRAIN_DIR`/`BRAIN_DIR`. **No MCP tool/schema change** (server stays 2.6.7); bundle rebuilt.

## 0.24.36

**Cost-router deep integration (Contract A + B consumers).** Two additive changes, both no-ops when cost-router is not installed. (1) **`persona-think` now records and checks the shared Opus-budget ledger (Contract A)** — `mcp/src/tools/persona-think.ts` gains `readOpusLedger`/`recordOpusLedger` helpers that read/write `${COST_ROUTER_LEDGER:-<brain-dir>/opus-budget.json}` (schema: `{date, opus_cost_usd, opus_calls, cap_usd}`). After each Opus call the call's token cost is added to the ledger (input/1e6×$5 + output/1e6×$25); before the call, if `opus_cost_usd ≥ cap_usd` (`COST_ROUTER_OPUS_CAP_USD`, default 5.0), the call is skipped and a `budget_skipped:true` / `error:…budget exhausted…` result is returned instead. Absent or unwritable ledger is a graceful no-op — persona-think never fails because of ledger I/O. This makes the ledger the **single Opus meter** across persona-think and cost-router. **No MCP server version change** (server stays 2.6.7) — this is internal accounting only; no tool name or schema changed. (2) **New Stop-hook `scripts/cost-router-capture.sh` aggregates Contract B routing events** — reads `${COST_ROUTER_EVENTS:-<brain-dir>/cost-router-events.jsonl}` (produced by cost-router's `/orchestrate`), aggregates counts by tier, outcome, and escalation rate, and writes/refreshes a bounded markdown summary to `<knowledge-dir>/wiki/cost-routing-patterns.md` for the `/orchestrate` and `/model-route` classifiers to consult. Added to `hooks/hooks.json` Stop (no matcher = runs after every session). Absent events file → exit 0, no file created (zero cost when cost-router not installed). Verified by `test-cost-router-capture.sh` (RED→GREEN TDD: synthetic events → page created; absent events → no-op) + `test-real-kb-isolation.sh` + `test-script-portability.sh`.

## 0.24.35

**MCP server failed to start for every installed user — Claude Code does not substitute `${CLAUDE_PLUGIN_ROOT:-.}`** (reproduced live on Linux AND macOS via `/doctor` + `/mcp`). The repo-root `.mcp.json` server path used the shell-default form `${CLAUDE_PLUGIN_ROOT:-.}` (shipped 0.24.5 to silence a project-context "missing env var" warning). **Root cause:** Claude Code substitutes ONLY the bare `${CLAUDE_PLUGIN_ROOT}` token in MCP `args`; it does NOT evaluate the `${VAR:-default}` shell form, so the path collapsed to the cwd-relative `./mcp/dist/server.bundle.js` — which starts the server ONLY when the user's cwd is the plugin dir and fails in every real project (empirically `✘ Failed to connect` from `/tmp` and `$HOME`; bare form `✔ Connected` from any cwd). The 0.24.5 "zero regression in plugin context" assumption was false — it traded a loud, correct failure for a silent, cwd-dependent one. **Fix (revert + restructure):** (1) revert to bare `${CLAUDE_PLUGIN_ROOT}`; (2) move the manifest from the repo root to **`.claude-plugin/mcp.json`**, wired via **`plugin.json` `"mcpServers": "./.claude-plugin/mcp.json"`** — so it loads ONLY in plugin context (var set) and is NO LONGER double-read as a project-scoped MCP config when the repo is opened as a project (the double-read is what forced the `:-.` workaround). Net: works for all installed users AND the project-context warning is *eliminated*, not just suppressed. **`validate-plugin.sh` guard INVERTED** (the 0.24.5 guard *required* the now-broken `:-.` form): it now FAILs unless every `*.bundle.js` arg is anchored by a bare `${CLAUDE_PLUGIN_ROOT}/` prefix (rejecting both the `${CLAUDE_PLUGIN_ROOT:-...}` default *and* a bare relative path — the identical cwd-relative bug shape), FAILs if a root `.mcp.json` exists (regression guard against the double-read), and FAILs if `plugin.json` lacks the `mcpServers` reference (the relocated file is not auto-discovered). `discover-tools.sh` cache scan now matches both `.mcp.json` and `*/.claude-plugin/mcp.json` so MCP tool discovery still finds the relocated manifest (new guard `test-discover-tools-mcp-scan.sh`). **Supersedes the 0.24.5 row.** Verified by `claude plugin validate --strict` (accepts the restructure) + `test-validate-plugin.sh` (29 cases incl. the path-anchor guard cases + the new root-`.mcp.json` and `mcpServers`-wiring cases) + `test-discover-tools-mcp-scan.sh`. **Config/script/test-only — no MCP server change** (server stays 2.6.7).

## 0.24.34

**Post-0.24.33 quality cleanup** — two pre-existing nits surfaced by a quality sweep of the *shipped* 0.24.33 (running the cache's own test suite from its install dir). Neither is a runtime bug; both are test/display hygiene. (1) **`test-active-slug-resolution.sh` subtest 2 was location-dependent** — it keyed the test cwd off `$ROOT` (`$(dirname "$0")/..`, i.e. the checkout/cache dir name) and hardcoded the expected slug `claude-code-plugin`, so the known-project gate matched **only** when the suite ran from a directory literally named `claude-code-plugin`. From the plugin **cache** (dir `0.24.33`), a CI checkout, or a git worktree, the cwd basename wasn't a registered project → the resolver correctly fell to the stale pin → the test's hardcoded expectation failed (a spurious "shipped suite isn't green from its install location"). The **resolver was always correct**; the test made a false assumption about its own directory name. Fixed to `cd` into a controlled `$TMP/wd/claude-code-plugin` (basename = the registered project, location-independent). Introduced 0.24.30. (2) **`dream-accept.sh` refusal message word-split spaced paths** — the escape-refusal printed `printf '  %s\n' $OOT_LINKS` **unquoted**, so a staged symlink whose filename contains a space was split across lines in the error text (display-only — the security gate `[ -n "$OOT_LINKS" ]` and the `exit 1` are unaffected; an escape was never let through). Now reads `$OOT_LINKS` line-by-line (`while IFS= read -r`). Introduced 0.24.26. New failure-regime test `test-dream-lifecycle.sh` 5i (RED→GREEN: a spaced escape path must appear intact in the refusal message). (3) Two comment clarifications: `sb_realpath` now notes a symlink CHAIN still resolves via the subsequent `cd … && pwd -P` (the one-level leaf-deref isn't a gap), and dream-accept documents that the `_SW` fallback is a TOCTOU guard. **Test + script-comment only — no runtime behavior change, no MCP change** (server stays 2.6.7).

## 0.24.33

**macOS dream-accept parse-failure fix — `case` inside `$(…)` breaks bash 3.2** (reproduced live on macOS by the user; surfaced by the 0.24.32 upgrade validator). `scripts/dream-accept.sh` built its out-of-tree-symlink escape scan (shipped 0.24.26) as a one-line `case "$_t" in "$_SW"/*) … esac` **inside a multi-line `$(…)` command substitution**. macOS `/bin/bash` is GPL3-locked at **3.2.57**, whose pre-4.0 parser extracts the comsub body by naive paren-matching and mis-counts the `)` that closes each case pattern as the `$(` terminator → a hard **"syntax error" at LOAD time**, so the *entire* script fails to parse (not just the scan). Fixed on bash 4.0; parses fine on Linux/4+ CI, which is why it shipped. **Net effect on macOS: every `dream_accept` was broken** (the scan runs unconditionally on accept, so it's not C/headless-only). Fix: replaced the `case` with a `[[ "$_t" == "$_SW"/* ]] || printf …` glob-match — **behavior-identical** (in-tree alias preserved, out-of-tree symlink still flagged; verified by `test-dream-lifecycle.sh` subtests 5b/5c/5d) and bash-3.2-safe. **New permanent guard — `test-script-portability.sh` check 8** (a depth-aware awk scanner) makes the class unshippable: it flags any `case` keyword reached while a `$(…)` is still open (plus the inline `$(case …)` form), verified RED on the bug and zero false-positive across `scripts/` (the 25+ legit top-level `case "$x" in ''|*[!0-9]*) … esac` numeric guards sit at depth 0). **Why a static scanner, not `bash -n`:** the bug is a 3.2-parser-only failure — a `bash -n` smoke on a 4+/5.x CI host parses it cleanly, so it cannot catch this class; the scanner is the only guard that can. **Second fix (same release, surfaced by the deep-review gate):** the same macOS hosts would then hit a sibling bug — `dream-accept.sh` resolved staged symlinks with bare **`readlink -f`**, which **stock macOS/BSD `readlink` lacks**; on failure `_t` is empty → the legit in-tree `security/latest.md` alias (which `cp -r` copies into **every** snapshot) is flagged as an escape → **every accept refused**. New portable **`sb_realpath`** in `lib.sh` (`realpath` → `readlink -f` → `greadlink -f` → `cd && pwd -P` + leaf-deref — the established `symlink-guard.sh` doctrine) replaces the bare `readlink -f` for both the staging base and each link target, so `dream_accept` works on stock macOS, not merely parses. Failure-regime tests `test-dream-lifecycle.sh` 5e/5f (a shimmed `readlink`-without-`-f` host) prove the legit alias is accepted AND an out-of-tree escape is still refused (security non-regression). **Script+test-only — no MCP change** (server stays 2.6.7).

## 0.24.32

**Test-isolation fix — 4 tests were polluting the REAL `~/.second-brain`** (found by the 0.24.31 live deep-test). `test-merge-ai-block.sh`, `test-merge-ai-block-refresh.sh`, `test-project-plan-block.sh`, and the main body of `test-merge-project-update.sh` invoked `merge-project-update.sh --project-md $TMP/PROJECT.md` **without isolating `BRAIN_DIR`**, so its `sb_inc_wiki_writes` side-effect (a per-project `.wiki-writes` counter) wrote to the default `$HOME/.second-brain/projects/<basename-of-$TMP>/` — i.e. `projects/tmp.XXXX/` — in the user's real KB on **every suite run** (the slug is the real project only when the path is real; a `/tmp` test path leaks). Real projects were never corrupted (distinct tmp slugs), but orphan `tmp.*` dirs accumulated. Fixed: each test now `export BRAIN_DIR="$TMP/brain"` (auto-cleaned by the existing `trap rm -rf $TMP`). **New permanent guard `test-real-kb-isolation.sh`** makes the class unshippable — it fails at authoring time if any test invoking `merge-project-update`/`stop-extract`/`pre-compact`/`sb_inc_wiki_writes` does not isolate `BRAIN_DIR`/`HOME` from the real KB (verified RED-on-injection). **Test-only — no runtime/MCP change** (server stays 2.6.7).

## 0.24.31

**code-review-deep runtime-premise lens** — closes the bug class that shipped 0.24.29 (a false belief about the runtime env — `CLAUDE_PROJECT_DIR` reliably set — passed all three diff-static review lenses: unit, architectural, history). New read-only `code-review-premise-reviewer` agent (Pass 2d) enumerates every load-bearing runtime premise in a diff (env vars / filesystem / process state / cross-process shared state / services / platform) and flags unproven ones, with a special hunt for the **asymmetric-fallback trap** (a fallback whose own correctness rests on a different unproven premise — the racy pin). A gated **Pass 3.5** (orchestrator-run, user-confirmed, bug-fix-only) probes each flagged premise in the REAL env + checks a failure-regime test exists; a BROKEN premise is force-promoted to a confirmed critical finding. The fix lives in the shipped skill+agents (cross-plugin **enforcement**); the lazy `~/.second-brain/review-fragile-premises.md` note is **support only** (raises severity, never gates — knowledge isn't cross-plugin). Wave-cap updated (2b+2c+2d each a wave-1 slot, ≤5 holds). **No MCP change** (server stays 2.6.7). New tests: `test-code-review-premise-agent.sh` (read-only-tools + taxonomy + output contract), `test-code-review-deep-premise-wiring.sh` (Pass 0/2d/3.5/4 + carve-out wiring). Additive — the review skill gains a lens; nothing else changes.

## 0.24.30

**Active-slug fix — CORRECTS the 0.24.29 attempt, which did not work where `CLAUDE_PROJECT_DIR` is unset** — 0.24.29 used `CLAUDE_PROJECT_DIR > pin > cwd`, but live diagnosis showed `CLAUDE_PROJECT_DIR` is **inconsistently present** across MCP-server spawns (some processes have it, some don't), so when it was absent the **stale global pin still beat the correct per-process `cwd`** — the concurrent-session hijack persisted (a `cainish` pin still scoped a `claude-code-plugin` session). **Root cause of the miss:** all tests ran in sandboxes that set `CLAUDE_PROJECT_DIR` or relied on the pin; no live query against the real env (where it's unset) ran before merge; and the doc-sources test regression was "fixed" by reverting precedence to `pin > cwd` (green tests over real-env correctness). **Correct precedence: `CLAUDE_PROJECT_DIR > cwd-if-known-project > pin > cwd`.** The key is the **known-project gate** — `cwd` is trusted only when its basename names a registered project (`projects/<slug>/PROJECT.md` exists). Both `CLAUDE_PROJECT_DIR` and `cwd` are per-process (a concurrent session can't clobber them); the gate accepts the real project root (so the racy pin can't hijack it) but rejects a subdir cwd (which falls to the pin — preserving subdir survival). Verified **live in the real env** (no `CLAUDE_PROJECT_DIR`, real `cainish` pin, cwd = the known project → resolves `claude-code-plugin`, NOT the pin). The 3 CLIs + `persona-context.sh` now delegate to the single shared resolver (kills the inline duplication). Touched: `project-dir.ts` `resolveActiveSlug`, `lib.sh` `sb_resolve_slug`, `persona-context.sh` (sources `lib.sh`), `server.ts`, the 3 CLIs. **MCP server → 2.6.7.** Tests: `mcp/test/project-dir.test.ts` (9, incl. the live-bug case + subdir), `tests/test-active-slug-resolution.sh` (6). **Behavior-correcting + additive.**

## 0.24.29

**Active-slug precedence fix — per-session project dir beats the global pin (concurrent-session bug)** — _(SUPERSEDED by 0.24.30 — this attempt's `CLAUDE_PROJECT_DIR > pin > cwd` left the bug live where `CLAUDE_PROJECT_DIR` is unset; see the 0.24.30 row.)_ — the active project slug was resolved by trusting the single, shared `~/.second-brain/.active-session-slug` pin OVER the per-session signal. Because that pin is ONE global file rewritten by every SessionStart, a **concurrent** Claude session in another project clobbers it and **hijacks this session's scoping** (episodic_search / knowledge_search / the per-prompt wiki+episodic hints resolving to the wrong project — observed live: a `cainish` session's pin scoped a `claude-code-plugin` session to `cainish`). Fixed everywhere: the per-session project dir (`CLAUDE_PROJECT_DIR`, which Claude Code sets, else cwd) is now **authoritative**; the pin is demoted to a last-resort fallback (only when no project dir resolves — degenerate cwd / very old CLI). New shared `sb_slug_from_dir` (`lib.sh`) + `slugFromProjectDir`/`resolveActiveSlug` (`mcp/src/tools/project-dir.ts`) carry the tmp→scratch normalization consistently (the TS resolver previously lacked it, so a `/tmp` session diverged between bash and MCP). Touched: `lib.sh` (`sb_resolve_slug`), `session-load.sh` (now writes the pin from the project dir), `server.ts` `resolveActiveSlug`, `persona-context.sh`, and the 3 CLIs (`raw-capture`/`raw-scan`/`doc-sources-config`). **MCP server → 2.6.6.** New tests: `mcp/test/project-dir.test.ts` (7), `tests/test-active-slug-resolution.sh` (4). **Behavior-correcting + additive:** a single-session user is unaffected (their pin already matched their project); concurrent-session users stop getting cross-project scoping.

## 0.24.28

**Forward-looking `## Plan` block + `[pinned]` protection (focus-tracking M6/M7)** — PROJECT.md gains a `## Plan` checkbox ledger: the FORWARD state (what's next), re-read every session, distinct from the backward-looking `## Recent decisions`. The Stop-hook extractor (`extract-prompt.txt`) now emits a `plan` array; `merge-project-update.sh` **replace-reconciles** it — preserves `[pinned]` lines verbatim on top, normalizes items to `- [ ]`/`- [x]`, caps non-pinned at 7, and **NO-OPs on an empty emission** so a degraded session never wipes the plan. `[pinned]` lines are now protected from the cap-drop in BOTH `## Plan` and `## Recent decisions` (the oldest **non-pinned** bullet is dropped/archived instead). SessionStart adds a one-line `✓ second-brain: project memory loaded — <slug> (plan o/t · d decisions · b blockers)` banner so the active project scope is visible at a glance (a wrong cwd→slug resolution is caught instantly; kill switch `SB_SCOPE_BANNER=off`). `## Plan` rides in the already-force-injected PROJECT.md, so it costs no extra budget logic. **No MCP change** (server stays 2.6.5). New tests: `tests/test-project-plan-block.sh` (template parity · replace-reconcile · checkbox-normalize · no-wipe-on-empty · cap-7 · pinned-decision-survives-cap · banner). **Additive:** a PROJECT.md without a `## Plan` section simply gets no plan reconcile until the section is backfilled (below); new projects scaffold it from the template.

## 0.24.27

**Episodic project-scoping (context-isolation M1)** — closes the one remaining cross-project leak. `knowledge_search` has been project-scoped since SP-1 (0.24.9), but `episodic_search` never was: the per-prompt "[Past sessions]" hint (`episodic-search-cli.ts`, called every UserPromptSubmit) and the `episodic_search` MCP tool searched **all** projects, injecting another project's session memory into every prompt — a context-rot/distractor **correctness** bug (Chroma: one topically-related-but-irrelevant distractor measurably degrades output), not just wasted budget. New pure `withActiveScope()` + `scopeAndBroaden()` in `episodic-search.ts`: `episodic_search` now **defaults `activeProject` to the resolved active slug** (the same `resolveActiveSlug()` the knowledge tool uses) and prefers same-project exchanges, **broadening to all projects only when the active project has zero in-scope hits** (SP-1 parity — a thin/new project still gets recall); an explicit `project` hard-filters as before, and the sentinel **`project:"all"`** deliberately searches every project. The CLI reads **`SB_ACTIVE_SLUG`** (now forwarded by `persona-context.sh`, mirroring the knowledge-search CLI). Threshold tunable via `SB_EPISODIC_SCOPE_MIN_HITS` (default 1). **MCP server → 2.6.5** (behavior + `project` schema-doc change). New tests: `mcp/test/episodic-search-scope.test.ts` (8 vitest: scope-suppresses-other-project · broaden-when-thin · default-all · explicit-hard-filter · `withActiveScope` defaulting incl. `"all"`), `tests/test-episodic-cli-scope.sh` (CLI + hook wiring). **Additive:** with no active slug (or `project:"all"`), recall is the prior global behaviour.

## 0.24.26

**C jail hardening — close the staging→accept symlink escape** (found by an adversarial completeness-critic during the live C verification). The bwrap jail's mount boundary is airtight (8 escape probes empirically blocked: live-wiki / plugin-self-mod / hooks / ~/.second-brain / ~/.ssh+/etc / symlink-through all denied), **but the gap was temporal not spatial**: the writable staging is later mirrored to live by an **UNJAILED `rsync -a --delete`** (`dream-accept.sh`) with no `--safe-links`, so a prompt-injected headless agent could plant a symlink in staging (e.g. `decisions/x.md → ~/.claude/.credentials.json` or `→ ~/knowledge/graph`) that rsync copies **as a symlink** into the live wiki — a write-through/read-through trapdoor a later *unjailed* drain would execute (or that reads the OAuth token into a page on the next snapshot). (a) **`dream-accept.sh` now REFUSES the accept** if staging contains any symlink pointing **outside** the wiki tree (in-tree relative aliases like `security/latest.md → 2026-06-06.md` are legitimate and preserved) **+ `rsync --safe-links`** as defense-in-depth; the `cp` fallback is covered by the same reject guard. This hardens **all** dream accepts, not just C. (b) **`maintain-llm-drain.sh` binds the OAuth credential file `--ro-bind`** (was `--bind`/writable) — the agent only reads the token; writable let a prompt-injected agent truncate/overwrite the user's creds. **Documented residual** (inherent to any OAuth-headless run): the token is readable + network is up, so a prompt-injected agent could exfil it — mitigated by C being opt-in/default-off, the content being the user's own captured knowledge, and the dream review gate. **No MCP change.** New tests: `test-dream-lifecycle.sh` subtests 5b/5c (out-of-tree symlink refused · in-tree alias allowed), `test-maintain-llm-drain.sh` creds-`--ro-bind` assertions.

## 0.24.25

**Headless-LLM maintainer (C — the autonomy capstone)** — the deferred final step: the AI **auto-authors knowledge unattended** (dedup/relate/enrich/summarize/forget), but **nothing reaches the live wiki without a human `dream_accept`**, enforced by the **kernel**, not a prompt. New **`scripts/maintain-llm-drain.sh`** (final step of `extract-drain.sh`, gated on `config.json` **`auto_maintain: true`**, default false) **reuses the dream loop**: `dream-snapshot.sh` stages a wiki snapshot, then the dream-runner consolidation runs **headless** via `claude -p --permission-mode bypassPermissions` **inside bubblewrap** that binds **ONLY that dream's dir writable** (`--ro-bind / /` for everything else — the live wiki included), so the unattended agent **physically cannot write live**; the dream is left completed-unaccepted for review via `/second-brain:dream` (the SP-C nudge surfaces it). **`bwrap` is required — absent → SKIP, never run unconfined** (no silent downgrade), making airtight C **Linux-only** (macOS/Windows stay on explicit `/second-brain:maintain`). **Quadruple-gated:** `auto_maintain` (≠ SP-B's `auto_improve`) · CLAUDECODE-refuse (defense-in-depth + the drainer's) · `claude` **and** `bwrap` present · no unreviewed dream already pending (no stacking). Weekly-throttled (`SB_MAINTAIN_LLM_INTERVAL`, default 7d); `SB_MAINTAIN_LLM_MODEL` (default `claude-sonnet-4-6`), `SB_MAINTAIN_LLM_TIMEOUT` (1800s); **never auto-accepts**. **No MCP change.** New test `test-maintain-llm-drain.sh` (containment structure: bwrap · bypassPermissions · dream-dir-only bind · ro-bind · bwrap-absent→skip · no-unconfined-claude; gating: off/throttle/no-stack/proceeds-via-DRYRUN). **Operator-verified:** the real headless OAuth consolidation can't run from inside a Claude session (recursive lock), so CI covers the gating + containment and **you verify the real run in an idle window**. **Additive:** with `auto_maintain:false` (the seed) C never runs — behaviour unchanged.

## 0.24.24

**Project continuity (SP-E)** — **closes the autonomous-knowledge-loop roadmap (A–E)**. Two defects, both visible in a real PROJECT.md. (1) **PROJECT.md was budget-starvable** — the sibling of the 0.24.16 USER.md bug: `session-load.sh` appended the project hot tier with **no `force`**, *after* ~9 conditional banners, so a degraded multi-banner SessionStart could spend the byte budget and **silently drop the entire project context**. Now `sb_append "$PROJ_CONTENT" "PROJECT.md" 3000 force` — forced like USER.md (equally priority-1), capped at 3000B so PROJECT.md + USER.md (6000) + budget-bounded banners stay under Claude Code's ~10K hook-output ceiling. (2) **`[degraded]` breadcrumbs polluted Recent decisions** — `stop-extract.sh`/`pre-compact.sh` wrote the `[degraded] LLM extraction unavailable; session touched: …` note into `recent_decisions`, so it landed in PROJECT.md's **## Recent decisions** (5-bullet cap); a multi-day outage filled all 5 slots with noise, crowding out **real** decisions. Now routed to a **sidecar** `projects/<slug>/pending-extraction.log` (dated, deduped-per-day, bounded to 50 lines); the delta is empty so decisions stay clean. Correct *because* SP-A's drainer now mines the real knowledge **out-of-band** — the breadcrumb is a transient gap-log, not a decision. **No MCP change.** Tests: `test-session-load-usermd-budget.sh` gains the PROJECT.md `force`+cap assertion; `test-stop-extract.sh` asserts the breadcrumb lands in the sidecar (deduped, scratch-paths stripped) + PROJECT.md decisions stay clean; `test-session-load-conflicts.sh` bound updated to the ~10K hook cap (forced priority sections bypass the 8000 soft budget by design). **Deferred:** a first-class `## Plans`/`## State` schema (fuzzy, low payoff). **Additive:** the sidecar appears lazily; PROJECT.md force is behaviour-preserving for a normal-sized PROJECT.md (it just can no longer be silently dropped).

## 0.24.23

**Bounded retention (SP-D)** — caps what accumulates, **safely**. Discovery verdict: this is *hygiene, not disk pressure* — 90% of `~/.second-brain` (519M) is the bounded `vector-deps` runtime; the only thing that grows forever is ~16M of dead embedding-cache vectors (66% of keys had no live exchange) + ~16M of abandoned `*.bak`/`*.tgz`, **both regenerable**. The policy splits hard on **reversibility**: clean the regenerable junk, never touch the irreversible. New **`scripts/sb-prune-archives.sh`** (deterministic, content-free, zero-credential) runs as **step 4 of `maintain-deterministic.sh`** — so it inherits the `auto_improve` gate + the drainer guards + the `.last-maintain` throttle, **no new timer**: (a) **embeddings-cache GC** (`retention.embeddings_cache_gc`, default on) rewrites `.embeddings-cache.json` keeping only `episodic:<id>` entries with a live `episodic-index` exchange (+ transient `concept-*`) — atomic, lossless (a missed vector re-embeds on next search); (b) **`*.bak`/`*.tgz`/`*.pre-rebuild-*` prune** past `retention.bak_ttl_days` (14). It **NEVER** touches transcripts (the re-extraction + episodic source), the episodic-index (a single rebuildable file), or the **wiki-archive** (the *irreversible* sole copy of FORGET'd pages + the auto-restore source). `dream-snapshot.sh`'s count-cap is now **config-driven** (`retention.dream_keep_count`, default 5) and still terminal-only (deletes only `archived_at`-stamped dreams, never pending/running/unreviewed) — always-on, independent of `auto_improve`. `ensure-dirs.sh` seeds a self-documenting `retention` block (`wiki_archive_ttl_days: 0` = NEVER). **Deferred (SP-D4, irreversible → operator-verified):** the wiki-archive TTL + a net-archived-zombie reconcile lint; minor: `.extraction-state` compaction + `error-log` rotation. **No MCP change.** New tests: `test-sb-prune-archives.sh` (GC keeps-live/drops-dead/off-switch · `.bak` TTL · transcripts+index untouched · a code-line guard the wiki-archive is never operated on), retention-seed assertions in `test-config-reader.sh`. **Additive:** with `auto_improve:false` (the seed) the GC never runs; the dream cap is byte-equivalent to the prior hardcoded 5.

## 0.24.22

**Dream lifecycle truth (SP-C)** — fixes the "stale dream that nags forever" + a hidden deadlock. **Ground truth:** the dream that "nagged for 19 days" was a **banner bug, not lost knowledge** — every dream on disk is `completed` **and** `archived_at`-stamped (its pages were applied minutes after the run), but `session-load.sh` keyed the nudge on `status=="completed"` **alone** (no `archived_at` guard) then `break`-ed on the oldest → re-fired every session. Every other consumer (`dream_list`, review, status, `verify`) honours `archived_at`; the banner alone forgot. (a) **Terminal-state guard** — the nudge now skips archived dreams, so it goes **silent** once a dream is accepted/discarded. (b) **Stale escalation** — a completed-unarchived dream older than `SB_DREAM_STALE_DAYS` (default 7) gets a louder, distinctly-tagged banner ("still UNREVIEWED … NOT in your wiki yet"); age via `status.json` mtime (portable `stat`, no GNU date-parsing). (c) **Iterate-all** — dropped the `break`; counts all awaiting-review dreams (`+N more`) instead of silently surfacing only the oldest. (d) **Running-reclaim** (`dream-snapshot.sh`) — a crash mid-run would stick a dream at `running` **forever and deadlock every future dream** (the create-guard refuses while one is active); a pending/running dream with no `status.json` progress in `SB_DREAM_RUN_TIMEOUT` (default **3h**) is now reclaimed → `failed` (its staging kept) and the new dream proceeds, while a *fresh* running dream still blocks (no concurrent runs). **Decision (user): signal-only** — SP-C never auto-discards or silently auto-archives unpopulated knowledge; it only tells the truth + unblocks a crash. **Retention** (the fragile count-cap prune + a new TTL) is **deferred to SP-D**. **No MCP change.** New tests: `test-dream-nudge.sh` (archived→silent · fresh→nudge · stale→escalated · multiple→count · running→none), `test-dream-lifecycle.sh` subtests 8/9 (fresh-running blocks · stale-running reclaimed). **Additive:** reads existing `archived_at`/mtime; with no dreams, unchanged.

## 0.24.21

**Opt-in auto-consolidation (SP-B)** — closes the autonomous loop's consolidation half: captured knowledge can now be kept tidy *unattended*, but only the **content-free** work, and only when you **explicitly opt in**. The discovery drew the safe line: validate/project-backfill/reindex *mutate state but invent nothing* → out-of-band-safe (no LLM, no credentials); dedup/relate/enrich/raw-node *authoring* needs a Claude session → stays on `/second-brain:maintain`. **Decision (user): B — deterministic + nudge**; the full headless-LLM maintainer (C) is a separate future consent (and even then must stage→`dream_accept`, never write live). (a) **config.json reader** (`lib.sh`) — the plugin's first config-file mechanism (everything else was env-only): `sb_config_get`/`sb_config_bool` with **env-overrides-config** precedence and a raw boolean read so an explicit `false` is honoured (not the jq `//` trap). `ensure-dirs.sh` seeds `{"auto_improve": false}` (idempotent, never clobbers). (b) **Deterministic out-of-band consolidation** (`maintain-deterministic.sh`) — validate(+autofix) → project-backfill → reindex, run at the end of an `extract-drain.sh` cycle **when `auto_improve` is on**, inheriting the drainer's CLAUDECODE-refuse/defer/single-flight guards (no second timer), self-throttled to `SB_MAINTAIN_INTERVAL` (1h). Ships on the **hardened** unit — no `~/.claude` grant. **Capture consent ≠ consolidation consent:** it gates on *both* an installed timer *and* `auto_improve`. (c) **Self-install nudge** (`session-load.sh`) — when auto-consolidation is off and the raw inbox piles up (`≥ SB_NUDGE_RAW_THRESHOLD`, default 20), a mutually-exclusive SessionStart banner offers the two honest remedies (`auto_improve:true` for structure · `/second-brain:maintain` to author the backlog); `SB_AUTOCONSOLIDATE_NUDGE=off` to mute. **No MCP change.** New tests: `test-config-reader.sh` (incl. the `//` false-trap), `test-autoconsolidate-nudge.sh` (fire/suppress matrix), `test-maintain-deterministic.sh` (marker/throttle + the `auto_improve` gate). **Additive:** with the seeded `auto_improve:false`, behaviour is unchanged.

## 0.24.20

**Cross-OS schedulers (SP-A.3/.4)** — the out-of-band drainer now installs + runs on **macOS + Windows**, not just Linux, so an **OAuth-subscription user on any OS** gets autonomous capture (the API-key path already worked everywhere in-session). (a) **Portable drainer** (`extract-drain.sh`): the Linux-only `/proc/$PID/cmdline` read → portable `ps -p -o args=` (+ a `pgrep`-less `ps`-scan fallback), and `flock` → a flock-or-`mkdir` single-flight lock with a staleness-steal — stock macOS / Git-Bash have neither. (b) **OS-branched installer** (`install-extract-timer.sh`): `uname -s` → **systemd** (Linux, unchanged) / **launchd LaunchAgent** (macOS) / **Task Scheduler** (Windows Git-Bash). Snapshots the user's engine env (`SB_EXTRACTOR_LOCAL_URL`/`ANTHROPIC_BASE_URL`/…) into the unit, since schedulers get a minimal env. (c) The SessionStart capture-health timer-probe **branches per-OS** (launchctl/schtasks), so it no longer false-alarms "no timer" off Linux. **Honest caveats (printed by the installer + documented):** macOS has **no linger** — a LaunchAgent runs only while you're logged in (`RunAtLoad` catches up at next login); and there is **no portable sandbox off Linux** — the scheduled job runs **unsandboxed as you**, so `--oauth` is a Linux-only distinction (a no-op elsewhere; the job can read `~/.claude` regardless). **No MCP change.** New tests: portable lock + no-`/proc` (`test-extract-drain.sh`), launchd/windows/unsupported rendering + env-snapshot + systemd-intact (`test-install-extract-timer.sh`). The Linux-runnable parts are CI-tested; the actual launchd/Task-Scheduler **install + run is operator-verified per-OS** (it can't run on a Linux CI box). **Additive:** no install → behaviour unchanged on every OS.

## 0.24.19

**Claude-first universal engine** (correcting SP-A's framing for a broadly-shipped plugin — it ships to every OS and can't assume ollama). **Claude is the universal engine**; the local model is opt-in only. (a) **Auth-aware capture banner**: the 0.24.18 banner read the *drainer's* state file, so it **false-nagged API-key users** (who extract in-session via Backend 2 curl, needing no drainer) to "install the bridge." Now branches on auth: **API key** → silent unless extraction actually fails; **OAuth subscription** → "capture not running" offering all three paths in order (`export ANTHROPIC_API_KEY` first — instant, any OS, no daemon · `install-extract-timer.sh --apply --oauth` · `SB_EXTRACTOR_LOCAL_URL`); **none** → the auth-mode-line already covers it. (b) **`ANTHROPIC_BASE_URL` override** in Backend 2 (`lib.sh`): enterprise-gateway / proxy / air-gapped Anthropic-compatible endpoints now work — the SP-A spec *claimed* this override existed but it was hardcoded to the public host. Default unchanged. (c) **Docs reframe**: README gains a canonical "Extraction engine" paragraph (Claude = universal; local = opt-in offline/privacy); the SP-A spec's "offline-first identity" over-framing is corrected. **No MCP server change** (2.6.4). New tests: `test-extractor-base-url.sh`, auth-aware `test-session-load-capture-banner.sh`. **Deferred (need per-OS verification, separate cycle):** cross-OS out-of-band scheduling — the drainer install is still Linux/systemd-only; macOS (launchd) + Windows (Task Scheduler) for subscription users come next. **Additive:** API-key users already worked in-session on any OS; this just stops the false nag and adds the gateway override.

## 0.24.18

**Autonomous capture bridge (SP-A)** — the foundation of the autonomous-knowledge-loop roadmap. Deploys the out-of-band extraction drainer (`extract-drain.sh`, built v0.13.0 but **never installed or run** — a prior wiring audit said "wired" while a live-runtime check found 0 transcripts ever drained) so archived transcripts actually become wiki/PROJECT/graph knowledge with no live session. (a) **Local-LLM engine (Backend 0, the offline-first identity)**: extraction tries a local OpenAI-compatible endpoint FIRST — `POST $SB_EXTRACTOR_LOCAL_URL/v1/chat/completions` (e.g. ollama on `localhost:11434`, model `SB_EXTRACTOR_LOCAL_MODEL` default `qwen2.5:3b`) — offline, **no credentials**, and works **in-session** (no recursive-claude lock, unlike `claude -p`). Input-budgeted (`SB_EXTRACTOR_LOCAL_MAX_BYTES` default 6000, recent-tail) + `SB_EXTRACTOR_LOCAL_TIMEOUT` (default 90s). (b) **Auto fallback (the working path)**: `SB_EXTRACTOR_ENGINE=auto` (default) tries local → **falls through to Claude** (OAuth `claude -p` / `--bare`) when the local model can't deliver — so the loop WORKS even where local is too slow (live finding: a Pi 5 CPU can't run a 3B over a full real transcript in time → Claude handles it out-of-band). `=local` pins; `=cli`/`=bare` force a backend. (c) **systemd unit fix**: the drainer unit now also grants **`~/knowledge`** (it could never write the wiki before — only `~/.second-brain`), ships a **hardened local-only default** (no `~/.claude`) + an **`--oauth` opt-in** variant that grants `~/.claude` so the Claude fallback runs in the background service. (d) **Capture-health self-check** (the "wired ≠ works" guard): SessionStart shouts `capture not running` when transcripts are archived but undrained or the timer is absent (`SB_CAPTURE_HEALTH_BANNER=off`). **No MCP server change** (stays 2.6.4). New/updated tests: `test-extractor-local-backend.sh` (Backend 0, budgeting, fallback), drain backend-label, install hardened/oauth, `test-session-load-capture-banner.sh`. **Additive:** with no `SB_EXTRACTOR_LOCAL_URL` and no timer installed, behaviour is unchanged.

## 0.24.17

**Wiring-validation defect fixes** (3 runtime breaks found by a 14-unit whole-product wiring+functional validation that *executed* every chain in isolated sandboxes and adversarially re-verified — all 3 reproduced before fixing). (a) **D1 (HIGH) — SessionStart auto-reindex was silently dead**: `ensure-dirs.sh` carried a *duplicate* of the reindex-ESM-import bug (a static `import { x } from process.env.SB_BUNDLE` → `SyntaxError`, swallowed by `2>/dev/null`), so `wiki/index.md` was never auto-built on a fresh KB. The fix had been applied to `lib.sh` (0.24.16) but this copy was missed — source-over-symptom. Now `ensure-dirs.sh` delegates to the canonical `lib.sh` helpers; added an `sb_validate_wiki` twin (both use the dynamic-`import()` + error-logged pattern, never the silent static form). (b) **D2 (secret leak) — `*.pem.md`/`*.key.md`/`config.env.md` were captured into the raw inbox**: the deep-scan `SECRET_RE` anchored `\.pem$`/`\.key$` to the full path, but every candidate already ends in `.md`, so those branches were structurally unreachable and a private key wrapped in markdown leaked through. Now `.pem`/`.key`/`.env` match as dot-delimited extension components (`server.key.md` blocked; `monkey.md`/`api-keys.md`/`environment.md` still kept). (c) **D3 — persona dedup double-injected backslash bullets on mawk**: the USER.md↔persona-card dedup passed bullets via awk `-v`, which runs POSIX escape-processing on the value, so a `C:\temp\notes` bullet's `\t`/`\n` were rewritten and dedup missed → switched to `ENVIRON[]` (no escape processing; same mawk-hazard family as the 0.21.4/0.22.3 fixes, different facet). **No MCP server tool change** (server stays 2.6.4; only `raw-scan.ts` rebuilt). New guards: `test-ensure-dirs-reindex.sh`, `.pem`/`.key`/`.env` vitest cases, persona backslash-dedup case. **Additive:** all are correctness fixes to existing paths; no new state.

## 0.24.16

**Whole-product audit fixes** (no new feature — hardening surfaced by a 5-dimension validation of the shipped SP-0..SP-5 vision). (a) **Persona — USER.md never budget-starved**: `session-load.sh`'s `sb_append` gains a `force` arg so the human's global Never/Always rules (priority-1) always land even when conditional banners have spent the byte budget; capped at 6000B so a huge USER.md can't breach Claude Code's ~10K hook-output ceiling. (b) **Maintainer Phase 4c — binary items**: a captured PDF/image has only a placeholder `.md` body (bytes live in the sibling blob), so the drain now authors a `sources` node pointing at the original instead of fabricating content; + a reserve-a-slice note so a large Phase 4b backfill can't starve the inbox. (c) **Maintenance banner** now points at `/second-brain:maintain` (live) **and** `/second-brain:dream` (staged) — previously only `/dream`, even though SP-5 shipped the real maintainer skill. (d) **README** documents `/second-brain:capture` + `/second-brain:maintain` (were missing), corrects the `SB_MAINTAINER_*` docs (a *suggestion banner*, not auto-dispatch — neutered in 0.21.0), and adds the capture→inbox→drain memory-flow. (e) **Maintainer doc drift**: 6-phase→8-phase, dropped a non-existent "Phase 6", report template gains ai-block/raw-drain lines. (f) **Dead code**: removed `migrate-to-1.0.0.sh` + `migrate-to-1.3.0.sh` (zero live refs; pruned from this table); kept `1.2.0` (verify.sh hint) + `2.8.0` (live test). **No MCP server tool change, no kb-schema change** (server stays 2.6.4). New guards: `test-session-load-usermd-budget.sh`, `test-readme-skills.sh`, + binary/phase assertions in `test-maintainer-raw-drain.sh`. **Additive:** all changes are prompt/doc/bash hardening — with no new on-disk state, behaviour is unchanged.

## 0.24.15

**Full-pipeline integration smoke test** (caps the consolidation vision). New `tests/test-pipeline-smoke.sh` exercises the **real built CLI bundles** end-to-end in a fully isolated sandbox (temp `BRAIN_DIR`/`KNOWLEDGE_DIR` — never touches the real KB): SP-3 setup-scan curates high-signal repo docs (junk/`CHANGELOG` excluded) → SP-2 raw inbox (URL stored as an offline pointer, paste) → SP-4 drain plumbing (`pending` 5-column TSV → `process` flips status + writes the `target_node` back-ref → excluded from `pending`) → SP-1 project-scoped serving (the other project's page suppressed when scoped). It is the only test that proves the shipped artifacts **compose** (the per-component suites test each in isolation); skip-guarded when `node`/the bundles are absent. Phase 4c's node-authoring is LLM-driven, so only the deterministic plumbing it relies on is exercised (its wiring stays guarded by `test-maintainer-raw-drain.sh` + `test-maintain-skill.sh`). Test-only — no plugin-runtime change, no MCP server change (stays 2.6.4).

## 0.24.14

**Surface cleanup + 3-OS verification** (SP-5 — final sub-project of the consolidation vision; design `docs/specs/2026-06-04-surface-cleanup-design`, plan `docs/plans/2026-06-04-surface-cleanup`). Four audit-fixes surfaced by a discovery sweep (the SP-1..SP-4 scripts' cross-OS portability came back clean — `awk -v`, `stat -c||-f`, no `mapfile`/`grep -P` held). (a) **New `/second-brain:maintain` skill** — the maintainer had **no user-facing entry point** (it's referenced throughout but `skills/maintain/` didn't exist); the new thin, user-invocable skill dispatches the `knowledge-maintainer` agent (namespaced `second-brain:knowledge-maintainer`) for an **explicit** full run — the path that runs the bulk-authoring Phase 4b (ai-blocks) and **4c (raw-inbox drain)** that auto-dispatched runs skip. Realizes the vision's second main skill. (b) **`doc-sources.filterIgnored` Windows fix** — `relative().split('/')` → `.split(/[\\/]+/)` so junk-dir filtering (`node_modules`/`.git`) works when `path.relative` emits backslash separators (affected the doc-sources scan + the SP-3 setup-scan on Windows; same class SP-3's `isHighSignal` fixed). (c) **New `test-agent-allowed-tools.sh`** — agents had no allowed-tools guard (unlike skills), which is why the maintainer's missing `Bash(node *)` shipped undetected; the guard asserts each agent declares the `node`/`bash`-script grants its body invokes. (d) `/second-brain:doubt` example now points at a real file (`persona-signals.jsonl`, not the removed legacy `learnings.md`). **No MCP server tool change, no kb-schema change** (server stays 2.6.4). New `test-maintain-skill.sh` + `doc-sources.test.ts`. **Additive:** the `maintain` skill + guard are new surface; (b) fixes a latent Windows bug (no-op on Linux/macOS); (d) is prose.

## 0.24.13

KB **maintainer raw-inbox drain** — Phase 4c (SP-4 of the consolidation vision; design `docs/specs/2026-06-04-maintainer-raw-drain-design`, plan `docs/plans/2026-06-04-maintainer-raw-drain`). Closes the SP-2→SP-3→SP-4 pipeline: the `knowledge-maintainer` agent now turns **unprocessed raw-inbox items** (from `/second-brain:capture` + setup deep-scan) into wiki nodes. **Conservative + provenance:** per item — `target_node` set → update it; else a strong `knowledge_search` match → update; else **create** a typed node (the 8 content categories; authored only from the captured material, never invented) — and it **never auto-discards** (low-value items are left unprocessed and reported for manual prune). Bidirectional provenance: the node gets a `## Sources` line, and the raw item is marked `processed` with a `target_node` back-ref (kept in `raw/` as the audit trail). New `markProcessed` in `raw-inbox.ts` (status→processed + back-ref, reusing the SP-2 `isSafeId`/`fmValue` guards) and two `raw-capture-cli` actions: `pending` (deterministic TSV work-list) + `process <id> [--node <slug>]`. Phase 4c is **explicit-invocation only** (like 4b — an auto-dispatched maintenance run skips it) and counts against the shared **50/run** cap. Deep-review hardening: granted the agent `Bash(node *)` (Phase 4b/4c shell out to node CLIs — without it the process call would prompt/deny → re-drained duplicates) and tab-sanitized `target_node` in the TSV. **No MCP server tool change, no kb-schema change** (`processed` already valid; the 8 categories already exist; server stays 2.6.4). New `test-maintainer-raw-drain.sh` + `markProcessed`/`pending`/`process` tests. **Additive:** Phase 4c only fires on an explicit maintain with a non-empty inbox; empty inbox or auto-dispatch → behaviour unchanged.

## 0.24.12

KB **setup deep-scan** (SP-3 of the consolidation vision; design `docs/specs/2026-06-03-setup-deep-scan-design`, plan `docs/plans/2026-06-03-setup-deep-scan`). `/second-brain:setup` gains a step that **seeds the raw inbox** from the repo's existing high-signal docs, so a fresh project starts with material for the maintainer (SP-4) to refine into wiki nodes. New pure `mcp/src/tools/raw-scan.ts`: `scanCandidates` globs `**/*.{md,markdown}` → a curation heuristic (include iff root-level `*.md`, OR a *directory* segment is `docs/doc/adr(s)/rfc(s)/spec(s)/decisions/.ai-docs/notes`, OR basename matches `README|ARCHITECTURE|DESIGN|CONTRIBUTING|ROADMAP`) → low-signal (`CHANGELOG|LICENSE|CODE_OF_CONDUCT|*template*`) + **secret** (`.env|*.pem|*.key|id_rsa|*secret*|*credential*`) denylists → reused `doc-sources.filterIgnored` (junk dirs + `git check-ignore`) → byte-stable sort; `runScan` captures survivors into the per-project raw inbox via SP-2 `captureItem({capturedBy:'setup-scan'})`, capped at `SB_SCAN_MAX` (default 50), content-hash **dedup** on re-run. The setup step **previews** (`raw-scan-cli --dry-run`, listing both the to-capture set and the over-cap remainder) then captures only on explicit confirm; kill switch `SB_SCAN_SKIP=1`. Cross-OS hardened (deep-review): separator-normalized curation (`path.relative` emits native sep — Windows `docs\\adr\\x.md` no longer collapses to one segment), `glob follow:false` (no symlink-loop hang), and the capture fence recomputes its shell vars (skill fences are separate shells). **No new MCP server tool, no SP-2 schema change** (`setup-scan` was already a valid `captured_by`; server stays 2.6.4). New `raw-scan.ts` (5 vitest incl. a Windows-path case) + `test-setup-scan.sh` (git-ignore e2e + self-contained-capture guard). **Additive + opt-in:** the scan only writes on the user's confirm; declining (or `SB_SCAN_SKIP=1`) leaves setup unchanged. SP-4 maintainer drain (raw→nodes) deferred.

## 0.24.11

KB **raw inbox** (SP-2 of the consolidation vision; design `docs/specs/2026-06-03-raw-inbox-design`, plan `docs/plans/2026-06-03-raw-inbox`). A per-project staging area `~/.second-brain/projects/<slug>/raw/` for **unprocessed** material — dropped with provenance, held **out** of `knowledge_search`, surfaced as a backlog, and later refined into wiki nodes by the maintainer (SP-4, deferred). New user-invocable **`/second-brain:capture`**: `<path>` copies a file (binary → blob sidecar); `<url>` → an **offline pointer** (no fetch); inline text / `paste` → markdown; `--node <slug>` pre-records provenance; `--list` / `--discard <id>`; idempotent via content-hash. Each item is `raw/<id>.md` with flat-YAML provenance frontmatter (`status: unprocessed|processed|discarded`); the work-list is **derived** by scanning status (no index file — drift-free). New `raw` group in `kb-schema.json` (dual-reader, `searchable:false`). `session-load.sh` surfaces a backlog banner (open = unprocessed + malformed; mawk-free `total − closed`), kill switch `SB_RAW_INBOX=off`. Security-hardened (deep-review): `setStatus` rejects path-traversal ids (a `--discard ../../wiki/page` can't rewrite an arbitrary `.md`), and every frontmatter value is newline-sanitized (no `status:` injection). **No MCP server tool change** — capture rides a standalone `raw-capture-cli` bundle (server stays 2.6.4). New `raw-inbox.ts` (9 vitest, incl. traversal + injection regressions) + `test-raw-capture.sh` + `test-raw-inbox-banner.sh` + raw-group schema guards. **Additive + back-compat:** `raw/` appears lazily on first capture; with no captures and `SB_RAW_INBOX` unset, behaviour is unchanged. SP-3 setup deep-scan + SP-4 maintainer drain are deferred.

## 0.24.10

Release-gate **typecheck guard**. `tests/run-all.sh` runs `vitest`, which transpiles per-file and does **not** typecheck the project — so a real `tsc` error (and the stale committed `dist/` left behind when `npm run build` = `tsc && bundle` fails) slipped through the "ALL GREEN" gate invisibly. That is exactly how the 0.24.7 `EDGE_TYPES` zod-enum cast broke the build yet shipped in **both** 0.24.7 and 0.24.8. New `tests/test-mcp-typecheck.sh` runs `tsc --noEmit` (no side effects; skips cleanly when `node` or the local `typescript` is absent) and is auto-included via the `test-*.sh` glob, so the gate now **fails on a type error** — closing the "validate the real capability" gap (the gate was testing a cheap proxy, not the real `npm run build`). Test-only — no state migration, no MCP change.

## 0.24.9

KB **project-scoped serving** (SP-1 of the consolidation vision; design `docs/specs/2026-06-03-project-scoped-serving-design`, plan `docs/plans/2026-06-03-project-scoped-serving`). When a project is active, `knowledge_search` now serves *that project's* knowledge first instead of the whole wiki — killing the cross-project noise the per-prompt persona injection used to feed Claude. Each candidate is tiered: **T1** same `project:` facet **plus** the active project's own local-docs (registry pages are tier-1 by construction); **T2** the graph-neighbourhood of the project's anchor pages (`SB_SCOPE_HOPS`, default 2, 0–4); **T3** shared / no-facet; **T4** other project. Sorted **scoped-first** (tier asc, then score desc) and **auto-broadens** back to the full global pool when fewer than `SB_SCOPE_MIN_HITS` (default 3, 0–100) in-scope hits clear the score floor — so a legitimately cross-project answer is never starved. Wired through the single `knowledge_search` chokepoint so **both** injection surfaces inherit it: `knowledge-search-cli` forwards `SB_ACTIVE_SLUG`/`BRAIN_DIR`; `persona-context.sh` (per-prompt) and `session-load.sh` (session-start) export the active slug. The slug→project map + anchors are built from **wiki docs only** so a local-doc never overwrites a same-basename wiki page's project (which would leak that other-project page into scope). Kill switches: `SB_PROJECT_SCOPE=off`, `scope:"all"`, `SB_SCOPE_MIN_HITS`, `SB_SCOPE_HOPS`. Also unblocks the build: the 0.24.7 `EDGE_TYPES` source-of-truth migration left `server.ts` casting the zod edge enum to `[string, …]`, widening the `knowledge_relate`/`knowledge_neighbors` arg types back to `string` and breaking `tsc` (and thus `tsc && bundle`) since 0.24.7 — fixed to the `[EdgeType, …]` tuple. MCP server → 2.6.4. **Additive + back-compat:** with no active project (or `SB_PROJECT_SCOPE=off` / `scope:"all"`) the ranking is byte-for-byte the prior global search. New tests: 6 SP-1 vitest cases (incl. local-doc tier-1 + the same-basename leak guard) + `test-search-cli-scope.sh`.

## 0.24.8

Persona **behavioral protocol** — the Four Principles (SP-0 of the consolidation vision; distilled from Karpathy's Dec-2025 agent-failure-mode post). New `skills/using-second-brain/principles.md` (canonical source: **Think Before Coding · Simplicity First · Surgical Changes · Goal-Driven Execution**, full + a marked compact block) is referenced by `using-second-brain` as standing context and **re-surfaced once per session** by `persona-context.sh` on the first coding-intent prompt (memo-deduped; kill switch `SB_PRINCIPLES_INJECT=off`) — the just-in-time salience a static CLAUDE.md can't give. New advisory `scripts/simplicity-gate.sh` (PostToolUse on Write/Edit/MultiEdit): nudges toward a smaller, naive-correct version when a single change writes > `SB_SIMPLICITY_GATE_LINES` (default 150) lines — never blocks; kill switch `SB_SIMPLICITY_GATE=off`. *Goal-Driven* reuses the existing `stop-verify-gate`. Structural detectors for Surgical-Changes/assumptions are deferred (too fuzzy to gate without false-positive spam). The principles live in the **behavioral** layer only — never the user's identity `persona-card.md`. New guards: `test-persona-principles.sh`, `test-simplicity-gate.sh`. Prompt/script/hook/test-only — no state migration, no MCP change.

## 0.24.7

KB **single source of truth** (kill the divergent structure definitions). The category/type/group lists were hardcoded in 11+ places that had drifted (`knowledge-validate.ts` knew 10 categories, `wiki-write-guard.sh` 8, `ensure-dirs.sh` only 3; the 6 structured types were copy-pasted into 4+ files; forget-scoring omitted `security` and listed a dead `patterns`). New canonical `kb-schema.json` (structured_types, unstructured_types, generated_dirs, edge_types, project_sections, forget_protection) is read by **both** the TS MCP server (`mcp/src/constants/kb-schema.ts`, esbuild-inlined) and every bash script/hook (`scripts/kb-schema.sh`, sourced by `lib.sh` → `SB_*` vars). Migrated consumers: `knowledge-validate` (KNOWN_CATEGORIES), `ensure-dirs` (now creates all 8 content categories), `kb-ai-block-candidates` + lint Check 4 (structured-type loop), `wiki-forget-score` (tiers — now protects `security`, drops dead `patterns`), `server.ts` graph edge enums. Guards: `kb-schema.test.ts` (TS↔manifest, incl. ai-block keys + graph EDGE_TYPES) + `test-kb-schema.sh` (bash↔manifest + a drift guard that fails on any new hardcoded category list). MCP server → 2.6.3. Behavior-preserving except the two forget-tier fixes.

## 0.24.6

Windows dream fix + persona-seed de-leak. (a) **`/second-brain:dream` was broken on Windows**: the `dream_create`/`dream_accept` MCP tools built the `dream-snapshot.sh`/`dream-accept.sh` path with Node `path.join` (backslashes on Windows: `C:\Users\…`) and passed it to `bash`, which ate the `\` escapes (`C:Users…`) → "No such file or directory". New `toBashPath()` in `mcp/src/tools/dream.ts` converts to a Git-Bash POSIX path (`/c/Users/…`) before the spawn — fixing both the bash invocation and the scripts' own `$(dirname "$0")/lib.sh` resolution. MCP server → 2.6.2; 5 unit tests. (b) **Persona-seed de-leak**: the setup-skill persona-card scaffold shipped the plugin **author's** own conventions as the default persona (`skill bodies under ~500 lines; extract templates to siblings`, `no 2>/dev/null patterns`) and defaulted the identity to `senior engineer` — leaking author content to every fresh install, and the `setup/SKILL.md` vs `persona-context.sh` seeds diverged. Both seeds are now generic, neutral, and identical; identity defaults to a `(set your role…)` placeholder. New `test-persona-card-seed.sh` guard. Code/prompt/test-only — no state migration.

## 0.24.5

**_(SUPERSEDED by 0.24.35 — the `${CLAUDE_PLUGIN_ROOT:-.}` default does NOT resolve for installed-plugin MCP args; it collapses to a cwd-relative path and shipped the server broken for every installed user. The validator guard described below was INVERTED in 0.24.35. See the 0.24.35 row.)_** `.mcp.json` cross-context fix. The repo-root `.mcp.json` (which is both the plugin's MCP manifest AND the project-scoped MCP config when the repo is opened as a project) hardcoded a **bare** `${CLAUDE_PLUGIN_ROOT}` in the server path. That variable is set only in **plugin** context, so opening the cloned repo as a **project** produced `Missing environment variables: CLAUDE_PLUGIN_ROOT` and the knowledge-base server didn't start in that context. Fixed by giving it the documented fallback default `${CLAUDE_PLUGIN_ROOT:-.}` — in plugin context the var is set so the default is never evaluated (the installed-plugin MCP is byte-for-byte unchanged, zero regression risk); in project context it falls back to a repo-relative path so the warning is gone. `validate-plugin.sh` now **fails** on a bare `${CLAUDE_PLUGIN_ROOT}` in `.mcp.json` (new regression guard + 2 `test-validate-plugin.sh` cases). Config/script/test-only — no state migration.

## 0.24.4

Full-plugin audit + cross-platform hardening (no functional regression — 10-auditor functional/contract sweep found 0 blocking issues; these are the surfaced warn/advisory fixes + macOS/Windows portability). (a) **Skill `allowed-tools` gaps** (the v0.21.1 missing-`mktemp` class — caused permission prompts mid-run): `dream` +mktemp/mv/mkdir/rm, `setup` +grep/sed/awk/head/cat/wc, `review` +basename/dirname/tr/head, `import-host` +tr, `status` +`knowledge_validate` (+numeric-guard the persona-spend printf), `upgrade` +node/cd/bash. (b) **Script hardening:** `symlink-guard.sh` now fails **closed** if `realpath` is absent (portable `cd && pwd -P` parent-resolver) instead of fail-open; `wiki-recall-check.sh` awk gate uses `-v`+coercion (no shell-interp into awk source — the mawk bug class); `stop-extract.sh` timeout comment 40→25; maintainer Phase 4b drops an unbound `$KD`; `doubt` example layer id `stop-predicate`→`stop-extract`. (c) **Cross-platform (Linux/macOS/Windows-GitBash):** removed the only bash-4 builtin (`mapfile`→portable read loop, for macOS `/bin/bash` 3.2); paired the unpaired `stat -c`→`stat -f`; PCRE `grep -P`→portable fixed-string `grep -F` (the Unicode-tag-block scanner now works on BSD/macOS instead of silently no-op'ing); `timeout`→`timeout||gtimeout`; README cross-platform section corrected. New guards: `test-skill-allowed-tools.sh`, `test-script-portability.sh`, symlink-guard fail-closed + macOS-resolver cases. Prompt/script/doc/test-only — no state migration.

## 0.24.3

AI-native knowledge representation — **Phase 3** (maintenance + backfill — the block lifecycle closes). (a) **Refresh on update**: `merge-project-update.sh`'s UPDATE path now replaces a complete `<!-- ai:begin … ai:end -->` region in place (injects one after the frontmatter when absent), so an authored block is *refreshed* with the page, not only created — and `extract-prompt.txt` instructs the extractor to emit `ai_block` for `update` actions too. Idempotent, mawk-safe, leaves a malformed begin-without-end page untouched (never eats the body). (b) **Lint staleness**: `knowledge_validate` gains `ai_block_missing` (a structured, substantive — ≥200 prose chars — page with no block → gentle warning; stubs / non-structured types / generated `projects`+`themes` MOCs exempt), and `/second-brain:lint` Check 4 surfaces the same signal standalone (offline bash). (c) **Backfill**: new deterministic, read-only `scripts/kb-ai-block-candidates.sh` (idempotent work-list of blockless structured pages) feeds the **knowledge-maintainer's new Phase 4b**, which authors a block per page from its *existing prose only* (never invents values), renders via the CLI, injects between frontmatter and H1, self-checks via `knowledge_validate`, counts each against the 50/run cap, and runs **explicit-invocation only**. The **dream** stays surface-only (counts blockless staging pages, recommends `/second-brain:maintain`; never authors in staging — single authoring path through the maintainer; gated `SB_DREAM_AI_BLOCKS=off`). MCP server → 2.6.1. Additive + back-compat. The §7 timestamp block↔prose drift heuristic is deferred (the block carries no authored-time; structural missing-block is the robust offline signal). New tests: `test-merge-ai-block-refresh.sh`, validate `ai_block_missing` cases, lint Check 4, `test-kb-ai-block-candidates.sh`, `test-maintainer-ai-block-backfill.sh`, `test-dream-ai-block-parity.sh`.

## 0.24.2

AI-native knowledge representation — **Phase 2** (consumption: the block gets *used*). The machine-first shared intermediate now drives retrieval + injection: (a) `knowledge_search` indexes the block as a **proposition-level BM25 field** (weight 1.5; the prose body field excludes the block so terms aren't double-counted) and **returns the block as the result snippet** when present — so `session-load` + `persona-context`, which inject the search snippet, now hand the reader the structured proposition instead of a prose fragment; (b) new `knowledge_fetch` **`block` tier** reads just the shared intermediate (falls back to the summary when a page has no block); (c) new pure `aiBlockSnippet` renders the compact schema-ordered one-line form. MCP server → 2.6.0 (new fetch tier). Additive + back-compat: a page with no block behaves exactly as before. Phase 2b (the block's own embedding/vector) needs embeddings → deferred (offline-first stays BM25). Dream/maintainer refresh + lint staleness + backfill are Phase 3. New tests: `aiBlockSnippet`, search Phase-2 case, `knowledge-fetch.test.ts`.

## 0.24.1

AI-native knowledge representation — **Phase 1b** (auto-authoring at capture). The capture-time **extractor** now authors the `<!-- ai:begin -->` block automatically, so blocks populate without user interaction: (a) `extract-prompt.txt` emits a structured `ai_block` per `wiki_update` (per-type schema fields; values are plain slugs, never `[[links]]`); (b) new `renderAiBlock` (`ai-block.ts`) deterministically renders a block object → the marked region (schema-ordered, closed-vocabulary, empty-skipping) + a thin `ai-block-render-cli` bundle so bash can call it with no TS/bash schema drift; (c) `merge-project-update.sh` renders the `ai_block` and injects it into a newly-created page (between frontmatter and the H1), fail-safe (no block / no node ⇒ inject nothing). MCP server → 2.5.1. Consumption (search/session-load/`knowledge_fetch`) is Phase 2; dream/maintainer **refresh** of blocks on update is Phase 3 (P1b authors on create only). New tests: `renderAiBlock` cases, `test-merge-ai-block.sh`, `test-extract-prompt-ai-block.sh`. Additive — no state migration.

## 0.24.0

AI-native knowledge representation — **Phase 1** (design `docs/specs/2026-06-02-ai-native-knowledge-representation-design`, plan `docs/plans/2026-06-02-ai-native-representation-phase1`). Reframe: the KB is AI-to-AI, so prose forces every reader to re-derive structure. Phase 1 makes a per-page `<!-- ai:begin … ai:end -->` **structured block** (flat YAML `key: value`, the "shared intermediate") a *recognized, parsed, schema-validated, strip-safe* construct — the deterministic foundation. (a) new pure `mcp/src/tools/ai-block.ts` (parse + per-type schemas {learnings,decisions,entities,issues,concepts,security} + `validateAiBlock` + `stripAiBlock`); (b) `parseDoc` exposes `doc.aiBlock`, and the body-`[[link]]`→`related:` fallback strips the block (block values are plain slugs, never `[[links]]`); (c) every length/first-sentence consumer excludes the block — `firstSentence` (reindex), the FORGET `wc -c` + stub-floor (`wiki-forget-score.sh`), the search stub-penalty — so a uniform block can't skew FORGET scores or BM25; (d) `knowledge_validate` warns (gentle, not error) on a block missing a required field for its type. MCP server → 2.5.0. **Additive + back-compat:** no block ⇒ behaviour unchanged. **Authoring** (extractor at capture) is Phase 1b; **consumption** (search weight/return + session-load injection + a `knowledge_fetch` block tier) is Phase 2; dream/maintainer refresh + lint staleness + backfill are Phase 3. New tests: `ai-block.test.ts`, `test-wiki-forget-ai-block.sh`, + parseDoc/validate/reindex cases.

## 0.23.1

KB hierarchical organization — Phase 2 (maintainer/dream migrate old→new; skills now KNOW the structure). (a) `knowledge-maintainer` Phase 3 gains a **project-structure reconciliation** step: read `~/knowledge/graph/project-registry.jsonl`, run `kb-project-backfill.sh` for `part_of` trees (deterministic), and for unlabeled pages get a reproducible suggestion from new `scripts/kb-project-suggest.sh` (plurality of edge-neighbours' `project:` facets) — additive assign + log; **re-parenting stages**; closed vocabulary (never invent project keys, never tag generated `projects/`/`themes/` pages). (b) `dream-runner` + dream `SKILL.md` are **surface-only**: they know project MOCs exist + are excluded from clustering input, and surface ungrouped-project suggestions for the maintainer (never assign on the live path). (c) `knowledge-validate` broken-link check now **splits `[[target|alias]]`** before resolving (was a false-positive on every valid aliased link — same alias rule as the 0.22.4 graph-migrate fix). MCP server → 2.4.1. New guards: `tests/test-kb-project-suggest.sh`, `tests/test-kb-skill-awareness.sh`, validate alias-split test. Prompt/script + one MCP fix — no state migration.

## 0.23.0

Knowledge-base hierarchical organization — Phase 1 (design `docs/specs/2026-06-02-knowledge-base-hierarchical-organization-design`, plan `docs/plans/2026-06-02-kb-hierarchical-organization-phase1`). Fixes the flat-hub / scattered-project-notes problem **without moving any file**: hierarchy is a soft overlay projected from the edge log + a new optional `project:` (and `area:`) frontmatter facet. (a) `parseDoc` exposes the `project`/`area` facets. (b) `knowledge_reindex` deterministically projects one `wiki/projects/<slug>.md` **MOC** per project with ≥ `SB_MOC_MIN_MEMBERS` (default 3) members (grouped by type; FORGET-protected like `themes/`; `graph: exclude`), and rebuilds `index.md` as a thin **two-tier Home** (`## Maps of Content` → project/theme MOC links + `## Categories` → per-type counts with **plain-text** slug rows) marked `graph: exclude` so a markdown graph viewer never treats it as a 100-edge hub. Pure projection — a second reindex is byte-identical modulo the generated timestamp; `SB_KB_MOC=off` disables. (c) `projects` is a known category (validate + FORGET PROTECT arm). MCP server → 2.4.0. Additive + back-compat: with no `project:` facets and no `projects/` dir, `index.md` is the prior flat catalog. **Phases 2–3** (on-write facet preservation + `relates→part_of` promotion + maintainer plurality-vote; lint/drift enforcement) are separate future migrations.

## 0.22.5

Persona graph-capability awareness (read-only boundary preserved). The persona-as-collaborator protocol (`skills/using-second-brain/SKILL.md`) knew the **read** tools (`knowledge_search`/`episodic_search`/`knowledge_neighbors`) and the wingman graph-check, but never referenced `knowledge_relate`, so the persona-driven loop didn't close the loop on a relationship it confirmed mid-session. The wingman section now does — but as a **surface-only** step: when the work confirms (or retires) a typed relationship, the persona surfaces it once as a *suggested* `knowledge_relate` (confirmed/retired edges only, never speculative). It does **not** call the tool — edge curation stays owned by the three sanctioned writers (capture-time **extractor**, the user's manual `knowledge_relate`, the `knowledge-maintainer`), and the extractor records the relationship from the session transcript at Stop, so the graph still accrues **with no user interaction**. Deliberately keeps the persona a graph READER, not a 4th writer (the boundary `agents/dream-runner.md` enumerates). New `tests/test-persona-capability-awareness.sh` guards both halves: awareness of the capability AND the read-only `allowed-tools` boundary. Prompt/test-only — no state migration.

## 0.22.4

Post-0.22.3 completeness-audit cleanup (no functional regression in 0.22.2/0.22.3 — all four features audited `complete`; these are the surfaced gaps). (a) **`graph-migrate.sh` junk-edge root-cause fix**: the one-shot importer scraped `[[..]]` with a raw grep that also caught bash `[[ test ]]` expressions inside fenced code blocks, kept `[[target\|alias]]` display noise, and emitted edges with **no endpoint guard** — so the live graph accreted 6 `migration:v1` junk edges (shell fragments / aliases as `to`) that re-project as broken links. It now mirrors the sibling write path `merge-edges.sh`: skips fenced code blocks, reduces `[[target\|alias]]` to its target, and emits **only** edges whose target resolves to a real wiki page (prebuilt slug index → `resolves()` guard; case-preserving, so mixed-case slugs survive). (b) **Dream inline/background parity**: `skills/dream/SKILL.md` 2c RELATE gains the read-only `conflicts.jsonl` open-conflict echo that `agents/dream-runner.md` already had, so both dream paths report identically (guarded by new `tests/test-dream-conflict-echo.sh`). (c) Corrected stale `0.23.0` references in the write-time spec + two plans to the `0.22.2` version that actually shipped. Script/prompt/doc/test-only — no state migration.

## 0.22.3

Dream-dogfood fixes (caught on the first production dream, 2026-06-02). (a) **`wiki-forget-score.sh` mawk-safe**: an empty/sparse `access-counts.json` made `acount` return empty → `awk "BEGIN{a=$acc;…}"` threw `syntax error at or near ;` on mawk (Pi default), degrading the FORGET access signal; now values pass via `-v` + numeric coercion (`x=x+0`) and `acount` defaults empty→0 (same bug class as the 0.21.4 lint-awk fix). (b) **Dream SUMMARIZE theme pages are slugged `theme-<id>`** (was `<id>` = the smallest member slug, which is usually the cluster's *anchor page* → `duplicate_slug` error). (c) **Dream ENRICH no longer hand-edits `related:`** (it is projected from the edge log → overwritten at reindex); it surfaces relationship gaps as `knowledge_relate` suggestions instead. Script/prompt-only — no state migration.

## 0.22.2

Graphiti/GraphRAG adoption — three additive, flag-gated features (all back-compat; design in `docs/specs/2026-06-01-*`, decision in wiki `decisions/graphiti-graphrag-evaluation-2026-06-01`). (a) **Write-time contradiction detector** in `merge-edges.sh` — pure-bash R1 reintroduce / R2 opposing / R3 multi_parent (opt-in) flags structural edge collisions to a new append-only `~/knowledge/graph/conflicts.jsonl` sidecar; never blocks the edge append, fail-open, kill switch `SB_CONFLICT_DETECT=off`. Surfaced by a high-priority `session-load.sh` banner (`sb_conflicts_open_count`); drained by the **live** `knowledge-maintainer` Phase 3 (the dream stays read-only re: `graph/`). (b) **Dream SUMMARIZE phase** (7th-phase cycle; `SB_DREAM_SUMMARIZE=off` to skip) — deterministic label-propagation clustering (new `graph-cluster.ts` + bundled `graph-cluster-cli` + `scripts/graph-cluster.sh` shim) writes FORGET-protected `wiki/themes/` pages, staged and reviewed at `dream_accept`. (c) **Retrieval-grounded reconciliation** in `knowledge-maintainer` Phase 2/3 (`SB_RECONCILE=off` to disable) — `knowledge_search` top-k → ADD/UPDATE/NOOP/SUPERSEDE with a deterministic enumerated SUPERSEDE edge loop. Additive on disk: `conflicts.jsonl` and `wiki/themes/` appear lazily; with no `~/knowledge/graph/` and flags at defaults, behaviour is unchanged. No destructive migration.

## 0.22.1

`sb auth status` made authoritative. It now defers to the CLI's own `claude auth status` (JSON: `loggedIn`/`authMethod`) instead of guessing from PATH presence — so a logged-out machine reports `none (logged out)` (was mislabeled `subscription`), and OAuth subscription is distinguished from a claude-managed `api_key`. Hardened against a hostile/hijacked `claude` on PATH (supply-chain threat model): the probe reads stdout even on the CLI's non-zero logged-out exit (`claude auth status` exits 1 when logged out but still prints JSON), is bounded by an **untrappable SIGKILL** timeout (a SIGTERM-trapping child can't hang it; tune via `SB_AUTH_PROBE_TIMEOUT_MS`, default 3000ms, clamped 100..30000), caps output via `maxBuffer`, and strips control bytes from the CLI-supplied `authMethod` before echoing it (terminal escape-injection). The `ANTHROPIC_API_KEY` env branch still short-circuits first. The SessionStart banner in `session-load.sh` still uses the older PATH-presence heuristic (separate surface; follow-up). CLI/test-only — no state migration.

## 0.22.0

Bi-temporal relational memory (typed, multi-hop knowledge graph). New append-only edge log `~/knowledge/graph/edges.jsonl` (source of truth) with typed edges (`requires`/`affects`/`relates`/`part_of`/`supersedes`) and bi-temporal validity (`valid_from`/`valid_to` valid-time + `recorded_at` transaction-time; contradictions invalidate, never delete; point-in-time `as_of` queries). New MCP tools `knowledge_relate` (assert/invalidate) and `knowledge_neighbors` (multi-hop directional time-filtered walk); MCP server → 2.3.0. Capture-time edge emission (`merge-edges.sh` + extractor `relations[]` + Stop hook) so the graph accrues even when LLM consolidation is degraded; `knowledge_reindex` projects current edges onto `related:` + a generated `## Dependencies` block; `knowledge_search` graph-boost upgraded to a guarded 2-hop typed walk; `session-load.sh` injects the active project's dependency neighbourhood. **Opt-in & reversible:** with no `~/knowledge/graph/` directory present, behaviour is byte-for-byte identical to 0.21.4 (every new path guards on log existence). To enable, run the one-shot importer once; to undo, delete `~/knowledge/graph/`. Additive — no destructive migration.

## 0.14.0

Current 0.x line (post-rebaseline; the runner compares by semver, so it only runs when upgrading into 0.14.0). New `/second-brain:code-review-deep` skill — multi-pass GitHub code review: review-unit decomposition + parallel Haiku `code-review-unit-reviewer` agents (cross-file bug hunting) + FP-aware `code-review-scorer`, with second-brain wiki/episodic context as input and a lazily-created false-positive store at `~/.second-brain/review-false-positives.md`. Also fixes `validate-plugin.sh` frontmatter parser (sed start/end range → awk that stops at the first closing delimiter, so a body `---` thematic break no longer leaks into parsed frontmatter and false-passes the required-field check). Fully additive — no state migration; the FP store is created lazily on first write.

## 0.15.0

code-review-deep v2 — model follows the work: code units review on the inherited best model (was Haiku), docs units on Haiku; the `code-review-unit-reviewer` agent dropped its `model: haiku` pin so it inherits, and the orchestrator passes `model: "haiku"` only for `docs_only` units. New advisory architectural pass (one holistic `quality-reviewer` over the critical+high file union, rendered as a separate "Architectural notes" section, never scored or FP-recorded). Leak mitigations: parallel-dispatch wave cap (≤5 concurrent) + lean findings-only sub-agent returns. Port-audit fixes vs the upstream reference: dropped the contradictory `🤖` in the comment template, realized the Haiku delegation for Pass 0/1 mechanical steps, consistent "skipped as trivial" wording, refreshed the skill description. `context: fork` orchestration deferred — unsupported upstream (anthropics/claude-code#17283). Fully additive — no state migration.

## 0.15.1

code-review-deep v2 review-fix pass (the skill dogfooded on its own change). (a) `docs_only` no longer misclassifies the plugin's own prompt/product trees (`skills/**`, `agents/**`, `tests/**`) as docs, and any `critical`/`high` unit is forced code-side — so a `SKILL.md` / agent `.md` change gets the best model, not Haiku. (b) Pass 2b architectural reviewer occupies one wave-1 slot (preserves the ≤5 concurrency cap) and is scoped to lines changed since `origin/<base>` (no pre-existing-issue false positives). (c) `quality-reviewer` Bash scoped to read-only git + `TodoWrite` dropped — trust-boundary hardening, since it reviews PR-influenced content. (d) Self-contained leak triage inlined in the skill Notes (no dependency on the spec file shipping). (e) Hardened the unit-reviewer "no model pin" test to top-level keys only. (f) Every model name (Haiku/Sonnet/Opus) qualified with the word "model" so the orchestrator never mistakes it for an agent name. Prompt/agent/test-only — no state migration.

## 0.15.2

Episodic-embeddings degradation banner hardened (`session-load.sh` block 0b). It now ALSO fires the moment `node_modules/@huggingface/transformers` is absent from the plugin cache — the native dep that vanishes on every cache refresh (cache ships `dist/`, never `node_modules/`) — instead of only after >10 exchanges had already accumulated empty embeddings. The old index-state-only check stayed silent right after a refresh because the existing index still held its embeddings, so degradation went unnoticed until new exchanges rotted. Gated on an index already existing (fresh installs aren't nagged); still suppressible via `SB_EMBED_PENDING_BANNER=off`. New guard `tests/test-session-load-embed-banner.sh`. Hook/test-only — no state migration.

## 0.16.0

Memory health: principled forgetting + recall eval (grounded in 2026 SOTA — SCM/SAGE forgetting, mem0 eval). New dream **Phase 6 FORGET** stages reversible archive moves (out-of-tree to `~/.second-brain/wiki-archive/`, never delete) for low-value / old / unlinked / recall-safe wiki pages — applied only on `dream_accept` with a post-consolidation re-score guard; kill switch `SB_WIKI_FORGET=off`. New offline scripts (no embeddings): `wiki-recall-check.sh`, `wiki-forget-score.sh`, `wiki-forget-candidates.sh`, `wiki-restore.sh`. New release-gate `tests/test-knowledge-eval.sh` (recall@2 + token budget over a fixture corpus) so retrieval quality is measured and forgetting can't silently regress it. `ensure-dirs.sh` creates the archive dir. Additive — no state migration.

## 0.17.0

Maintainer ↔ forgetting coordination. (a) Forget probe reads `tags:` (the maintained field) not the absent `keywords:`. (b) New `scripts/wiki-archived-slugs.sh` net-archived source of truth makes forgetting durable via AUTO-RESTORE: re-creating a forgotten slug revives the original instead of duplicating — extraction (`merge-project-update.sh`) mv+merges it; the wiki-write-guard restores + redirects to Edit. (c) `knowledge-maintainer` is archive-aware: honors the archive, restores-before-recreate, surfaces forget candidates, never archives (the dream stays the sole gated archiver). Un-archiving is un-gated (additive/safe); archiving stays gated. Fail-open on a missing/corrupt log. Prompt/script/test-only — no state migration.

## 0.18.0

code-review-deep v2.1 — fix the gate, not the finder. (a) `code-review-scorer` un-pins `model: haiku` → inherits the session/best model, so the scorer matches the Opus reviewer it gates (removes the capability inversion that scored subtle finds "unverified" and dropped them). (b) The 16–69 confidence band is no longer dropped — it is surfaced in Pass 4 as a separate "Lower-confidence findings (unverified)" section, distinct from the numbered confirmed list and the architectural notes. (c) The false-positive auto-record ratchet is removed: the store grows ONLY from explicit user dismissals (a wrong auto-suppression would hide a real bug indefinitely). (d) Unit-reviewer reasons at `effort: high` (verified: `effort:` overrides session effort for dispatched subagents). Prompt/agent/test-only — no state migration.

## 0.19.0

code-review-deep history/regression lens. New `code-review-history-reviewer` agent (inherits the best model, `effort: high`, read-only `git log`/`git blame`) runs once over all changed code files as a scored Pass 2c, concurrent with Pass 2/2b under the existing ≤5 wave cap. It catches the regression bug class diff-only review misses: reverts of prior fixes, re-introduced bugs, removed deliberate guards. The `code-review-scorer` gains `git log`/`git blame` (and a history-verification instruction) so the gate can confirm regression findings — the v2.1 gate-lockstep lesson applied to tools. Prompt/agent/test-only — no state migration.

## 0.20.0

Shared vector-deps. `bin/install-vector-deps.sh` now installs `@huggingface/transformers` (+ native `onnxruntime-node`/`sharp`, ~519MB) ONCE into a version-independent shared dir (`~/.second-brain/vector-deps`, override `SB_VECTOR_DEPS_DIR`) keyed by a hash of `mcp/package.json` deps, and symlinks each version's `mcp/node_modules` at it. Version bumps re-link (milliseconds, no network) instead of re-downloading 519MB, and old versions no longer accumulate duplicate copies (was 4.7GB cache, ~4.1GB dead dupes). First post-0.20.0 run harvests any existing per-version `node_modules` (mv, no download). The vector-deps health check (re-runs every upgrade) drives this automatically; the two consumers (`session-load.sh` 0b `-d` test, upgrade `import()` check) are symlink-safe. Script/test-only — no user-state migration.

## 0.20.1

vector-deps safe-install + dogfood review fixes. `bin/install-vector-deps.sh` rewritten to a stage→validate→atomic-swap model: a rebuild is built in a private `mktemp` staging dir and proven (all deps present + import works) BEFORE the live shared tree or the per-version symlink is touched, so a failed/offline `npm install` can no longer destroy a working install or leave a dangling symlink. Adds a `sha256sum`→`shasum -a 256` fallback (macOS), a `deps_ok` completeness guard (a harvested or partial tree is never trusted/stamped), and per-run staging (concurrent runs can't corrupt each other — no lock needed). Also: code-review-deep dedup now prefers a `regression` finding on a cross-pass collision (keeps its commit citation); wave-cap prose clarified; session-load embeddings banner wording reflects the symlink reality. Script/prompt/test-only — no user-state migration.

## 0.21.4

`/second-brain:lint` awk reserved-word fix + regression test. `skills/lint/SKILL.md` Check 1 (orphan detection) and Check 3 (broken Cross-references) used `in` as an awk variable name. `in` is reserved in both gawk and mawk (used by `for (x in arr)` / `(elem in arr)`), so on Pi OS / Debian default `awk` (which is mawk 1.3.4 — gawk not installed) both blocks emitted `syntax error at or near in` and silently skipped, hiding broken cross-references entirely. Renamed both to `inside`; consolidated rationale into the skill header so it covers every awk block. New `tests/test-lint-skill.sh` (4 cases) guards the bug class permanently: parse-check across every awk block, explicit reserved-word grep with mawk-portable regex, RED-on-injection assertion (sed-injects the bug and asserts the test catches it — closes the "test passes vacuously" risk caught by the second deep-review pass), and a Cross-references-extractor functional fixture. Release process: this is the first version shipped through the full multi-pass deep-review gate (`code-review-unit-reviewer` + `code-review-history-reviewer` + a `quality-reviewer` post-fix pass), executed BEFORE the version bump per user request. Hook/test-only — no state migration.

## 0.21.3

`verify.sh` empty-file tolerance fix. After `/second-brain:status` clears the error-log via `: > ~/.second-brain/error-log.jsonl` (the natural pattern), the next `verify.sh` run was failing with a spurious "malformed JSON" — `jq -e '.'` on an empty file exits non-zero, and the pre-validator was gated on `[ -f "$ERR_LOG" ]` (exists, any size). Switched to `[ -s "$ERR_LOG" ]` (exists AND non-zero size); the empty-file case now skips Check 5 cleanly. New `tests/test-verify.sh` subtest 9b ("error-log empty: ok") covers the regression. Verified RED→GREEN: subtest 9b fails against the unchanged code, passes after the fix. Subtest 9 (genuine malformed JSON still fails) unchanged. Hook/test-only — no state migration.

## 0.21.2

error-log noise + integration-test contract fixes (caught by the new pre-push `quality-reviewer` gate). (a) `mcp/src/tools/embeddings.ts` was writing an "embeddings disabled via SECOND_BRAIN_DISABLE_EMBEDDINGS=1" line to `error-log.jsonl` on every process startup that touched the embeddings module. Since the in-memory dedup (`lastLoadError`) can't cross processes, vitest runs alone dropped ~500 noise rows and dwarfed real errors. User-opted disable is informational, not an error — moved the acknowledgement to stderr only; real `transformers` load failures still log. (b) `tests/test-episodic-index.sh:55` was asserting the OLD log-on-disable contract against the compiled bundle; the unit-test update caught the source change but missed the bash integration test. Updated to assert the new contract: disable ack on stderr (`run1.err`), `error-log.jsonl` must NOT receive an entry. (c) `mcp/test/episodic-index.test.ts` strengthened from `if (existsSync) expect.not.toMatch` (vacuous if file absent) to `expect(existsSync).toBe(false)` — catches re-introduction. Process: this release is the first one shipped through a deliberate pre-commit `/second-brain:quality-reviewer` pass, which is now the documented gate going forward. Hook/test-only — no state migration.

## 0.21.1

v0.21.0 dogfood review fixes (3 issues, all caught by post-release `quality-reviewer`). (a) HIGH — `agents/dream-runner.md` + `agents/knowledge-maintainer.md` Bash allowlist was missing `mktemp`, `stat`, `touch`; the agent bodies use `TMPFILE=$(mktemp)` for atomic status.json updates and would have silently failed. Added the three. (b) MEDIUM — `scripts/symlink-guard.sh` prefix check required a trailing slash (e.g. `$HOME/.ssh/*`), so a Write whose path resolved to the exact directory node `$HOME/.ssh` was passing unchallenged. Added an equality-fallback case (`"${prefix%/}"`). New regression test in `tests/test-symlink-guard.sh`. (c) MEDIUM — `scripts/config-change-guard.sh` was reading `.source`/`.file_path` from the ConfigChange JSON event based on educated guess; Anthropic's actual field names aren't documented at this granularity. Added a multi-name fallback (`.source // .matcher // .category // .config_source`, `.file_path // .path // .config_file // .target`) and now records the WHOLE raw event in `.extra` for forensics. Hook/agent/test-only — no state migration.

## 0.21.0

Anthropic-doctrine hardening + auto-invocation rethink (the [[plugin-hardening-gap-analysis-2026-05-28]] release). **Hardening:** (a) new `scripts/symlink-guard.sh` PreToolUse hook denies Write/Edit/MultiEdit whose realpath lands in `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/claude`, `~/.config/gh`, `~/.password-store`, `/etc`, or `~/.netrc` — Anthropic's "symlink resolution before path validation" rule. (b) new `scripts/config-change-guard.sh` ConfigChange audit-only hook records every mid-session settings.json edit to audit-log.jsonl. (c) new `mcp/src/path-guard.ts` with `assertWithin`/`validateSlug`; applied to `knowledge_fetch`, `archive_to_wiki`, `pin_to_project` to close the MCP Git CVE-2025-68143/4/5 pattern (path-traversal via tool args). (d) `dream-runner` + `knowledge-maintainer` agents drop unscoped `Bash` for a 24-command non-shell allowlist (no curl/eval/exec). **Rethink (4 doctrinal conflicts closed):** (e) C5-A — `dream-autostage.sh` no longer auto-stages or instructs subagent spawn; emits a user-facing suggestion banner pointing at `/second-brain:dream`. (f) C3-B — `session-load.sh` maintainer banner softened from "BLOCKING REQUIREMENT — you MUST" to "wiki maintenance suggested"; no longer creates `.maintainer-dispatched` automatically (reconcile state machine still works for manual + legacy paths). (g) C1-B HYBRID — `session-load.sh` now emits `persona-card.md` + `.installed-catalog.json` summary at SessionStart (doctrinal load), and `persona-context.sh` keeps the per-turn safety-net emit to guard against v2.10 regression. (h) P0e — `dream`, `setup`, `track`, `upgrade`, `import-host` skills flip `disable-model-invocation: false → true` (Anthropic: "workflows with side effects" are user-invocation-only). **Sandboxing:** (i) `systemd/sb-extract-drain.service` adds `NoNewPrivileges=`, `RestrictNamespaces=`, `ProtectHome=read-only`, `ReadWritePaths=%h/.second-brain` — the pty-compatible subset; pty-incompat directives stay out per [[pty-openpty-privatedevices-quirk]]. (j) opt-in bubblewrap wrapper around the claude-CLI extractor via `SB_USE_BWRAP=1` (no behavior change without opt-in). **Release flow:** (k) `scripts/validate-plugin.sh` now fails on plugin.json↔marketplace.json version drift and runs `claude plugin validate` when the CLI is available. **Docs:** 5 new wiki pages — `security/plugin-hardening-gap-analysis-2026-05-28`, `security/anthropic-containment-doctrine`, `security/glasswing-mythos-threat-context-2026-05`, `concepts/anthropic-10-element-prompt-structure`, `decisions/2026-05-28-plugin-architecture-rethink`. Hooks/scripts/agents/MCP changes are all back-compat for the existing state on disk; no user-data migration.
