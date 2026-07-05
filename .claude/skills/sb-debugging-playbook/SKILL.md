---
name: sb-debugging-playbook
description: >-
  Symptom-to-triage playbook for live failures of the second-brain plugin. Load this skill when
  something is BROKEN RIGHT NOW and the cause is unknown — symptoms like: a stray .second-brain/
  directory appears in an unrelated repo; a PreToolUse guard (symlink/persona/wiki-write) silently
  allows what it should deny, especially on Windows; extraction emits [degraded] breadcrumbs, empty
  deltas, or ec=124 timeouts; dream_create/dream_accept fails on Windows ("No such file", "Cannot
  connect to C:"); a wiki page exists on disk but is invisible to knowledge_search; projects.jsonl
  makes slug resolution / dream scoping / search tiering go blind; the test suite reports green but
  a test actually failed (SKIP false-green); vector search silently degrades to text/BM25-only;
  validate-plugin.sh drift check fails only on Windows; test-bundle-current.sh fails; MCP tools read
  and write two different wikis. Keywords: fail-open, silent allow, CRLF, jq \r, MSYS, cygpath,
  WSL bash, ec=124, degraded, bm25-only, text-only, misroute, legacy wiki, stale bundle, false
  green. Do NOT load for: full incident history and root-cause narratives (use
  sb-failure-archaeology), how to measure/read logs and probes in depth (use
  sb-diagnostics-and-tooling), test-suite mechanics and adding tests (use sb-validation-and-qa),
  flag/kill-switch catalog (use sb-config-and-flags), or recreating the dev environment (use
  sb-build-and-env).
---

# sb-debugging-playbook — symptom → triage for the second-brain plugin

Audience: an engineer or model with zero repo context facing a live failure. This skill gives you,
per symptom: ranked likely causes, the ONE command that discriminates them, and the fix or the
sibling skill that owns the deep dive. All commands are **bash, run from the repo root**
(`C:/Workplace/Projects/claude-code-plugin` on the dev box; git-bash on Windows, plain bash on
Linux/macOS). Platform-specific commands are flagged.

Version stamp: written against plugin **0.33.31 as of 2026-07-05** — the 0.33.31 fix batch was
uncommitted working-tree state at authoring time (HEAD was `6fba312` = 0.33.30) and has since
landed as commit `e9dfbd1`. Anything marked "fixed 0.33.31" is only in your tree if
`jq -r .version .claude-plugin/plugin.json` says `0.33.31` or later.

## Terms (defined once, used everywhere below)

| Term | Meaning | Evidence |
|---|---|---|
| `BRAIN_DIR` | Runtime state root, default `~/.second-brain` (env-overridable; MSYS-normalized once at `scripts/lib.sh:5-12`) | scripts/lib.sh:5 |
| `KNOWLEDGE_DIR` | Wiki root, default `~/knowledge`; the **canonical wiki is `~/knowledge/wiki`** | mcp/src/brain-paths.ts:35-42 |
| legacy wiki | `~/.second-brain/wiki` — anything written there is a bug even if it "works": search only reads `~/knowledge/wiki` | agents/raw-drainer.md:136 |
| drainer | `scripts/extract-drain.sh`, the out-of-band timer job that LLM-extracts archived transcripts (OAuth sessions can't extract in-session) | extract-drain.sh:1-4 |
| dream | Background consolidation job: snapshot wiki → agent edits staging → human/auto accept (`~/.second-brain/dreams/drm_*/`) | mcp/src/tools/dream.ts |
| guards | PreToolUse hook scripts: `symlink-guard.sh`, `persona-tool-guard.sh`, `wiki-write-guard.sh` (+ `flow-guard.sh`, `plan-first-nudge.sh`) | hooks/hooks.json |
| FORGET | Dream phase that proposes reversible archiving of low-value wiki pages (nothing deleted until accept) | scripts/wiki-forget-candidates.sh |
| error-log / audit-log | `$BRAIN_DIR/error-log.jsonl` (failures) vs `$BRAIN_DIR/audit-log.jsonl` (guard verdicts + hook latency). `gate=`-prefixed exit-0 entries are TRACE and routed to audit-log, not errors | scripts/lib.sh:192-306 |

## First 10 minutes on any bug here

Run top to bottom; stop when a step points at a table row below.

1. **Pin the platform.** `uname -s; bash --version | head -1; command -v cygpath && echo git-bash`.
   Windows git-bash is the dev platform but has **no CI lane** — Windows-only breakage ships
   through green CI. macOS = bash 3.2 + BSD userland; Raspberry Pi = mawk. Platform decides which
   trap family you are in (see Traps).
2. **Pin the version and tree state.** `jq -r .version .claude-plugin/plugin.json | tr -d '\r'`
   and `git log --oneline -1; git status --short | head`. Many symptoms below are "fixed at version
   X" — confirm the fix is actually in the code you are running (the installed plugin cache may lag
   the repo).
3. **Read the error channel.** `tail -20 ~/.second-brain/error-log.jsonl | jq -c '{timestamp,script,message,exit_code}'`.
   Interpretation rules: `exit_code:0` entries (e.g. `extractor-diag …`) are diagnostics, not
   failures; `ec=124` = timeout-kill. Deep interpretation guide: **sb-diagnostics-and-tooling**.
4. **Read the guard/latency channel.** `jq -r 'select(.verdict)|.verdict' ~/.second-brain/audit-log.jsonl | sort | uniq -c`
   — a log with zero `deny`/`ask` ever, on a machine that writes code daily, is itself a symptom
   (row 2: guards fail-open sat undetected for months exactly this way).
5. **Run the runtime smoke check.** `bash scripts/verify.sh` — exit 0 = `verify: ok`, else one
   `verify: FAIL: <check>` line each (USER.md, PROJECT.md, hot-tier cap, MCP bundle present, wiki +
   index.md, stale/unreviewed dreams, fresh error-log entries).
6. **Check extractor health.** `jq . ~/.second-brain/.extractor-health.json` — `status:"queued"` is
   NORMAL on OAuth/subscription auth (in-session extraction defers to the drainer); only
   `status:"fail"` is a failure. Auth mode ground truth: `bash bin/sb auth status`.
7. **Check kill switches.** `env | grep -E '^SB_' | sort` — a "broken" guard/banner/phase is often
   just switched off (`SB_SYMLINK_GUARD=off`, `SB_PERSONA_GATE=off`, `SB_DREAM_SUMMARIZE=off`, …).
   Full catalog: **sb-config-and-flags**.
8. **Run the subsystem's test directly and trust the EXIT CODE, not the label.**
   `bash tests/test-<subsystem>.sh; echo "exit=$?"`. Caution: the suite harness
   (`tests/run-all.sh`) sandboxes `HOME` per test; a one-off run hits your real `HOME` unless you
   prefix `HOME=$(mktemp -d)` (some tests then legitimately SKIP). Suite mechanics:
   **sb-validation-and-qa**.
9. **Check the data geography.** `find ~/.second-brain/wiki -name '*.md' 2>/dev/null | wc -l`
   (expect 0 — anything there is legacy-wiki misroute, row 5) and
   `node -e "console.log('KD=',process.env.KNOWLEDGE_DIR,'OPT=',process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR)"`
   (both set and different → row 11). Full geography: **sb-run-and-operate**.
10. **Reproduce deterministically.** Hooks and guards are stdin-JSON filters — feed a synthetic
    payload and assert the JSON verdict (worked probes in D1 below and in
    **sb-diagnostics-and-tooling**). Never conclude "guard works" from absence of noise: empty
    stdout is a silent allow.

## Symptom → triage table

Columns: what you first see → ranked likely causes → the one discriminating command → fix / owner.

| # | Symptom (as first seen) | Likely causes, ranked | Discriminating command | Fix / owner |
|---|---|---|---|---|
| 1 | Stray `.second-brain/` (or `knowledge/`) dir appears at the root of an unrelated repo (Windows) | (1) Running a pre-0.33.17 plugin version — ~16 Node call sites resolved `process.env.HOME` (unset on native-Windows Node) → CWD-relative writes; (2) a NEW hand-rolled resolver reintroduced the class | `cd mcp && npx vitest run src/brain-paths.test.ts` — the source-scan test FAILS on any `process.env.HOME` or `.second-brain` string literal outside `brain-paths.ts` | Upgrade ≥0.33.17; route every new resolver through `mcp/src/brain-paths.ts` (`os.homedir()`). Story: Traps T1; history: **sb-failure-archaeology** |
| 2 | A PreToolUse guard doesn't fire on Windows — a write into `~/.ssh` (or a frontmatter-less wiki write) sails through silently | (1) Pre-0.33.31: path-form mismatch — payload `C:\…` vs prefixes `/c/…` → all three guards fail-OPEN; (2) kill switch set (`SB_SYMLINK_GUARD=off` / `SB_PERSONA_GATE=off`); (3) hook not wired (wrong plugin version/cache) | The one-shot armed-probe in **D1** below — expect `deny`; on `SILENT-ALLOW` follow D1's split (fail-open vs killed vs unwired vs a MANGLED probe payload) | Upgrade ≥0.33.31 (`sb_normalize_path` funnel, `scripts/lib.sh:29`); regression: `bash tests/test-normalize-path.sh`. Split lookalikes: D1 |
| 3 | Extraction "does nothing": `[degraded]` breadcrumbs, empty deltas, or `ec=124` in error-log | (1) OAuth auth → in-session extraction is structurally queued (**normal**, drainer handles it); (2) drainer timeouts on a slow box (`ec=124`, poison-pills after 3 fails); (3) drainer never runs (scheduler shim missing / task dead); (4) starvation: always-on interactive session defers every timer fire | `jq -r '.status+" / "+.backend+" / "+.reason' ~/.second-brain/.extractor-health.json` — `queued` = normal; `fail` = real; then **D5** | Timeouts: raise `SB_DRAIN_EXTRACT_TIMEOUT` (budget-proof comment at `scripts/lib.sh:1612-1625` — don't exceed half the lock-stale window). Scheduler: `bash scripts/install-extract-timer.sh --ensure`. Counters + probes: **sb-diagnostics-and-tooling** |
| 4 | Dream fails on Windows (`dream_create` / `dream_accept` errors) | Five historical layers, all fixed — on a current tree the residual causes are: (1) stale plugin cache running old code; (2) new path crossing the Node↔bash boundary unnormalized; (3) no-rsync accept limitations (deletions never applied — by design) | `for f in ~/.second-brain/dreams/drm_*/status.json; do jq -r '[.id,.status,(.error//"-")]|@tsv' "$f"; done | tail -5` — then map the error string via **D3** | Upgrade; the boundary funnel is `scripts/lib.sh:5-12` + `sb_normalize_path`; regression `bash tests/test-lib-brain-dir-msys.sh`. Full chain story: **sb-failure-archaeology** |
| 5 | Wiki page exists on disk but `knowledge_search` never returns it | (1) Legacy-wiki misroute — page written under `~/.second-brain/wiki` (raw-drainer has done this live); (2) `index.md` stale (never reindexed); (3) `root_orphan` — page sits at `wiki/` root, never indexed; (4) missing/broken frontmatter starves BM25 field scoring | `find ~/.second-brain/wiki -name '*.md' 2>/dev/null | wc -l` — >0 = misroute; if 0, run **D4** | Move pages into `~/knowledge/wiki/<category>/`, then reindex (MCP `knowledge_reindex` or `source scripts/lib.sh; sb_reindex_wiki "$HOME/knowledge"`). Misroute regression lock is still OPEN (audit medium) — re-verify after every drain |
| 6 | Slug resolution, dream family scoping, and search tiering all go blind at once (registry reads as empty) | (1) `projects.jsonl` pretty-printed — pre-0.33.31 session-load rewrote it with `jq` (no `-c`), one record across ~8 lines → line-by-line `JSON.parse` returns `[]`; (2) CRLF-tainted lines; (3) manual edit corruption | `tr -d '\r' < ~/.second-brain/projects.jsonl | grep -cv '^{.*}$'` — expect `0`; anything else = corrupt lines | `source scripts/lib.sh; sb_harden_projects_jsonl ~/.second-brain/projects.jsonl` (canonicalizes, writes a `.bak`, leaves unparseable files intact). Upgrade ≥0.33.31 so the rewrite uses `jq -c` (scripts/session-load.sh:707) |
| 7 | Suite reports green but you have evidence a test failed (pre-0.33.31 SKIP false-green) | (1) Pre-0.33.31 `run-all.sh` classified any test printing a `SKIP:` line as SKIP **even when it exited non-zero** (double bug: ERE `[:\s]` is the literal chars `:`,`\`,`s`); (2) the test itself is presence-not-effect (greps source, never runs behavior) | `bash tests/test-<name>.sh; echo "exit=$?"` — run it alone, trust the exit code. Harness check: `grep -n 'only honor SKIP' tests/run-all.sh` (present = fixed) | Upgrade ≥0.33.31 (SKIP now requires exit 0, `tests/run-all.sh:84-98`; fixture-locked by `tests/test-run-all-skip-semantics.sh`). Green-but-fake test patterns: **sb-validation-and-qa** |
| 8 | Vector search silently text-only / `bm25-only` (recall feels worse; no error shown) | (1) Vector deps not linked — the plugin cache ships `dist/` but never `node_modules/`, so EVERY plugin upgrade unlinks embeddings until relink; (2) `SECOND_BRAIN_DISABLE_EMBEDDINGS=1` set (it's the CI default); (3) model load failure (logged once per brain-dir); (4) episodic backlog: exchanges indexed before deps existed have no vectors | `jq -c 'select(.script=="embeddings")' ~/.second-brain/error-log.jsonl | tail -3` — a `transformers model load failed` entry names the heal command | `bash bin/install-vector-deps.sh --relink-only` (exit 3 = needs a download → rerun without the flag). MCP results carry `degraded:'bm25-only'` / `'text-only'` flags (mcp/src/tools/knowledge-search.ts:392, episodic-search.ts:298-304) but `sb query`/`sb recall` do NOT surface them — probe via MCP or the coverage one-liner in **sb-diagnostics-and-tooling** |
| 9 | `scripts/validate-plugin.sh` drift check fails on Windows only | (1) Windows git-bash jq emits CRLF in `-r` output even on clean LF input → `\r`-poisoned comparisons (historically: a spurious drift FAIL on every non-last marketplace entry — last one passed); (2) real version drift between `plugin.json` and `marketplace.json` | `printf '{"a":"b"}' | jq -r .a | od -c | tail -1` — `\r \n` at the end = the jq CRLF faucet is live on your box | Current validator strips `\r` at every jq read (scripts/validate-plugin.sh:92-96,116). If it STILL fails, it's real drift: sync both manifests in the release commit — **sb-change-control** |
| 10 | `tests/test-bundle-current.sh` fails: "mcp/dist/<x> is STALE" | (1) You edited `mcp/src` and didn't rebuild; (2) `node_modules` drift — your esbuild differs from the lockfile's; (3) wrong Node (engine `>=22`) | `bash tests/test-bundle-current.sh` — the failure line names the exact stale bundle | `cd mcp && npm ci && npm run build` (tsc gate + rebundle). NEVER hand-edit `mcp/dist/**` — dist is committed and byte-compared in CI. Build model: **sb-build-and-env**; gate policy: **sb-change-control** |
| 11 | MCP tools split across two wikis: `archive_to_wiki` (or dream) writes pages that `knowledge_search` can't see, same process | Three divergent `resolveKnowledgeDir` implementations with **conflicting env precedence**: `mcp/src/brain-paths.ts:35-42` (`CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` first) vs `mcp/src/server.ts:29-43` (`KNOWLEDGE_DIR` first) vs `mcp/src/tools/dream.ts:75-84` — OPEN audit medium as of 0.33.31 | `node -e "console.log(process.env.KNOWLEDGE_DIR, process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR)"` — both set AND different = split confirmed | Workaround: set at most ONE of the two env vars (or neither — default `~/knowledge` agrees everywhere). The real fix (single funnel) is an open backlog item; design rationale: **sb-architecture-contract** |
| 12 | MCP server `✘ Failed to connect` from a real project dir (works when cwd = plugin repo) | (1) The repo-root `.mcp.json` loaded as a PROJECT MCP server — `${CLAUDE_PLUGIN_ROOT}` is unexpanded outside plugin context (dev-box gotcha); (2) historic `${CLAUDE_PLUGIN_ROOT:-.}` manifest form (0.24.5→0.24.35; validator now FAILS on it) | `grep -n 'CLAUDE_PLUGIN_ROOT' .claude-plugin/mcp.json` — must be the bare token, no `:-` default | Dev box: disable the root `.mcp.json` via `.claude/settings.local.json`; do not edit its path. Install/run surface: **sb-run-and-operate** |
| 13 | Dream banner nags every session, or a dream is stuck `running` forever | (1) Dream completed but unreviewed (banner is correct — accept or discard it); (2) crashed runner: `status.json` mtime frozen — reclaimed as failed only after `SB_DREAM_RUN_TIMEOUT` (6h); (3) failed-dream banner ignores `archived_at` even after explicit discard (OPEN audit medium) | `for f in ~/.second-brain/dreams/drm_*/status.json; do jq -r '[.id,.status,(.archived_at//"-")]|@tsv' "$f"; done` + `ls -l` the status.json mtime | Accept/discard via MCP `dream_accept`/`dream_discard`; a genuinely dead `running` dream un-wedges itself after 6h (`sb_dream_is_stale`, scripts/lib.sh:1104) |
| 14 | Session context (USER.md rules, project state) missing right after a compaction | Expected: the SessionStart matcher deliberately excludes `compact` — upstream Claude Code drops SessionStart output after compaction (anthropics/claude-code#15174) | `jq -r '.hooks.SessionStart[0].matcher' hooks/hooks.json` — shows `startup\|resume\|clear` | Not a plugin bug; context returns on the next real SessionStart. Hook wiring table: **sb-architecture-contract** |
| 15 | `auto_maintain` (headless consolidation) never runs on the always-on Linux box | (1) 3-strike quarantine tripped (`.llm-maintain-quarantine`); (2) bubblewrap absent or namespaces blocked (the 0.24.41 `RestrictNamespaces` class → 100% silent failure); (3) `auto_maintain:false` in config | `cat ~/.second-brain/.llm-maintain-quarantine 2>/dev/null; bwrap --version 2>/dev/null || echo no-bwrap; jq .auto_maintain ~/.second-brain/config.json` — quarantine file = cause 1, `no-bwrap` = cause 2, `false` = cause 3 | Quarantine self-clears when the preflight passes; systemd unit must NOT set `RestrictNamespaces`. Non-Linux: auto_maintain is a documented no-op (needs a kernel sandbox) — stay on explicit `/second-brain:maintain`. Campaign to fix for real: **sb-autonomous-consolidation-campaign** |
| 16 | Linux CI lane red at the bash-suite step, but ALL local (Windows) gates green — including the very test CI failed | (1) A new executable file committed `100644` — git-bash FAKES the exec bit so `test-exec-bits` passes locally but fails on a real Linux checkout (shipped 0.33.31 red, fixed 0.33.32); (2) a genuinely Linux-only behavior difference (GNU tool versions, mawk) | `git ls-files --stage tests/ scripts/ bin/ \| grep 100644` — any hit on a `test-*.sh`/entrypoint = cause 1; empty = reproduce on real Linux: WSL + userland node/jq (esbuild + `python3` failures under WSL are mount artifacts, NOT CI-real — see the chronicle §23b triage) | Cause 1: `git update-index --chmod=+x <file>` (mode-only commit). Prevention lives in **sb-validation-and-qa**'s add-a-test checklist; full incident: **sb-failure-archaeology** §23b |

## Discriminating experiments (split the lookalike causes)

### D1. Guard silent — fail-open vs killed vs not wired

A guard that says nothing is indistinguishable from a guard that isn't running. Empty stdout =
silent allow; JSON with `.hookSpecificOutput.permissionDecision` = armed and fired. The probe
slurps (`jq -s`) so empty stdout PRINTS the `SILENT-ALLOW` label — plain
`jq -r 'x // "fallback"'` runs zero times on zero input and prints nothing, mimicking the exact
silence it exists to flag.

```bash
P="${CLAUDE_PLUGIN_ROOT:-$PWD}"   # repo checkout works for manual runs
printf '{"session_id":"probe","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"C:\\\\Users\\\\%s\\\\.ssh\\\\id_rsa"}}' "${USERNAME:-$USER}" \
  | BRAIN_DIR=$(mktemp -d) bash "$P/scripts/symlink-guard.sh" \
  | jq -rs '(.[0].hookSpecificOutput.permissionDecision) // "SILENT-ALLOW"'
```

- `deny` → guard armed, including against Windows-form paths (the 0.33.31 fix).
- `SILENT-ALLOW` → FIRST prove the probe, then the guard. Rerun the same `printf` piped into
  `jq -e . >/dev/null || echo PAYLOAD-MANGLED` instead of the guard: every shell/tool layer
  between you and bash (Claude Code's Bash tool, ssh, make) processes backslashes once, and a
  `\\\\` payload that loses a layer's worth becomes INVALID JSON — the guard reads unparseable
  stdin and stays silent, indistinguishable from fail-open. Reproduced live 2026-07-05: one extra
  tool layer turned this exact probe into a false `SILENT-ALLOW` against a healthy 0.33.31 guard
  that denies when fed valid JSON. If mangled, add backslashes for your layer count — or skip
  hand-built payloads entirely: `bash tests/test-symlink-guard.sh; echo "exit=$?"` is the
  authoritative probe (its `run_guard` sed-escapes real strings, immune to layer mangling; exit 0
  with tests 20-22 passing = armed against Windows-form paths).
- Payload valid but still `SILENT-ALLOW` → now split: rerun with a POSIX path (`$HOME/.ssh/x`).
  POSIX denies but Windows form doesn't = the pre-0.33.31 path-form fail-open (upgrade). Both
  `SILENT-ALLOW` = check `env | grep SB_SYMLINK_GUARD` (killed) → still both `SILENT-ALLOW` = the
  guard script itself is broken or you're probing the wrong checkout.
- Two probe rules learned the hard way: build the payload with `printf`, **not** `jq --arg`
  (git-bash jq rewrites POSIX paths into `C:\` form and invalidates the probe —
  tests/test-symlink-guard.sh:28-29), and set a throwaway `BRAIN_DIR` or your probe verdicts
  pollute the real audit-log. Full probe set for all guards: **sb-diagnostics-and-tooling**.
- Wiring (as opposed to script) proof: `jq '.hooks.PreToolUse' hooks/hooks.json` — but remember
  the deeper lesson: hooks.json proves wiring, only a live probe proves ARMED (the three guards
  were perfectly wired and perfectly inert for months).

### D2. "Search got worse" — degraded vs disabled vs backlog

```bash
ls ~/.second-brain/vector-deps/node_modules/@huggingface/transformers/package.json 2>/dev/null || echo DEPS-MISSING
ls "$P/mcp/node_modules" >/dev/null 2>&1 || echo UNLINKED   # junction/symlink to the shared tree
env | grep SECOND_BRAIN_DISABLE_EMBEDDINGS
```

DEPS-MISSING → `bash bin/install-vector-deps.sh`. UNLINKED (deps exist, link gone — the state
after every plugin upgrade) → `--relink-only`. Env var set → unset it (it is intended for CI).
All three clean but episodic recall still text-only → vector backlog: coverage one-liner in
**sb-diagnostics-and-tooling** §7.3; backfills at the next session-end extraction.

### D3. Dream fails on Windows — which layer

Map `status.json` `.error` (row 4's command) against the layer table. All layers are FIXED at the
noted version — a hit on a current tree means you are executing stale code (check step 2 of the
first-10-minutes list) or a NEW unnormalized boundary crossing.

| Error text you see | Layer | Fixed at |
|---|---|---|
| `No such file or directory` for a path that exists | Backslash path eaten by bash, OR CRLF-tainted env path (`…\r`), OR WSL `System32\bash.exe` shadowing git-bash (`/c/...` doesn't exist under WSL's `/mnt/c` view) | 0.24.6 / 0.30.0 / 0.33.1 |
| `Cannot connect to C: resolve failed` (accept) | GNU tar/rsync parse `C:\…` as a REMOTE `host:path`; the real stderr was historically swallowed and the script guessed "disk full" | 0.33.10, class-closed 0.33.12 |
| Dream created but `dream_list` shows nothing | Node-side relative `.second-brain` (HOME unset) — dream landed in a stray CWD-relative dir; go find it with row 1 | 0.33.2 / 0.33.17 |
| Accept succeeded but deletions never applied | Not a bug: the no-rsync (typical Windows) accept path is merge-copy only and announces it | by design, dream-accept.sh:216-241 |

Regression checks: `bash tests/test-lib-brain-dir-msys.sh` and `bash tests/test-dream-accept-guards.sh`.

### D4. Invisible wiki page — misroute vs unindexed vs orphan vs frontmatter

Run in order; first hit wins:

```bash
SLUG=<page-slug>
find ~/.second-brain/wiki -name "$SLUG.md" 2>/dev/null            # hit = legacy misroute (row 5 fix)
grep -rl "$SLUG" ~/knowledge/wiki/index.md >/dev/null || echo NOT-INDEXED   # reindex needed
ls ~/knowledge/wiki/"$SLUG".md 2>/dev/null && echo ROOT-ORPHAN    # root-level pages are never indexed
head -1 ~/knowledge/wiki/*/"$SLUG".md 2>/dev/null | grep -q '^---' || echo NO-FRONTMATTER
```

NOT-INDEXED → `knowledge_reindex`. ROOT-ORPHAN → move into a category dir, reindex.
NO-FRONTMATTER → `knowledge_validate {autofix:true}` patches it (report-only first — autofix
mutates). Validate taxonomy: **sb-diagnostics-and-tooling** §9.

### D5. Extraction dead — queued-normal vs timeout vs never-scheduled vs starved

```bash
source scripts/lib.sh
echo "health=$(jq -r .status ~/.second-brain/.extractor-health.json 2>/dev/null)"
echo "timeouts(last40)=$(sb_count_drain_timeouts 40) dead-letters=$(sb_count_drain_dead_letters) scheduler=$(sb_timer_health)"
cat ~/.second-brain/.drain-defer-count 2>/dev/null
```

- `health=queued`, everything else 0/installed → **normal OAuth deferral**, not a bug.
- `timeouts ≥ 3` → the box is too slow for `SB_DRAIN_EXTRACT_TIMEOUT` (the R1/Pi class); raise it
  within the documented budget proof (lib.sh:1612-1625).
- `scheduler=absent` → the shim or OS registration is gone (a task exec-ing a deleted shim "fails
  silently every fire" — observed live): `bash scripts/install-extract-timer.sh --ensure`.
- defer-count climbing toward `SB_DRAIN_DEFER_MAX` (6) → starvation by an always-on interactive
  session; the escape only fires when safe (API key present, or pmode-only + a `timeout` binary).
  Drainer state files and four run-probes: **sb-diagnostics-and-tooling** §5.

### D6. Invisible `\r` — proving CRLF poisoning

When a comparison/arithmetic/`grep '^x$'` fails on Windows for no visible reason:

```bash
somecmd | od -c | grep -m1 '\\r' && echo CR-POISONED   # or: cat -A file | head (shows ^M)
```

Two faucets, one tell each: (a) **jq stdout is text-mode on Windows** (`\n`→`\r\n`, jq 1.8.1) —
every `$(jq -r …)` capture needs `| tr -d '\r'`; the signature is *non-last records fail while the
last one passes* (no trailing `\r` on final output). (b) **CRLF-tainted env vars** (`BRAIN_DIR`
etc. set by a Windows-side writer) — `fs.stat`/`bash <path>` fail with a misleading "No such
file"; the TS side strips via `cleanEnvPath`, the bash side via `tr -d '\r'` at read boundaries.

## Traps that cost real time (story + tell)

Each burned days-to-months. Know the tell; the full post-mortems live in **sb-failure-archaeology**.

- **T1 — Windows HOME→CWD stray dirs.** ~16 Node call sites fell back from unset `HOME` to a
  CWD-relative `.second-brain` and littered unrelated repos; bash looked fine because MSYS sets
  `$HOME` (asymmetric platform premise). *Tell:* a `.second-brain/` or `knowledge/` folder where
  none belongs. Guard: brain-paths source-scan test (row 1).
- **T2 — Guards fail-open on the dev platform.** All three PreToolUse guards were inert on Windows
  for months (path-form mismatch) with 3,770 audit rows and zero errors; a deep audit, not an
  incident, found it. *Tell:* an audit-log with no `deny`/`ask` ever. Guard liveness must be proven
  by injecting a violation, not by absence of noise (D1).
- **T3 — 169 consecutive `ec=124` extraction timeouts.** Headless `claude -p` spawns re-entered
  the full plugin stack: ~24s startup vs a 25s timeout, every spawn killed, nobody noticed —
  "no errors" meant "not running". *Tell:* `extractor-diag …ec=124` runs in error-log; hook p95
  creeping toward its hooks.json budget.
- **T4 — `ln -s` deep-copies on MSYS.** "Symlinking" the ~490MB vector deps copied them per plugin
  version → 3.1GB cache; the test that would have caught it probed `ln -s`, found no real symlink,
  and silently SKIPPED on exactly the buggy OS. *Tell:* plugin cache in the GB; `ls -la` shows a
  real dir where a link should be. Rule: `fs.symlinkSync(…, 'junction')`, never bare `ln -s`.
- **T5 — swallowed stderr GUESSES a cause.** `dream_accept`'s tar failure was reported as "disk
  full / unwritable" for several releases because the real stderr (`Cannot connect to C:`) was
  eaten by `2>/dev/null`. *Tell:* an error message that describes a *plausible* cause rather than
  quoting tool output. House rule: fail loud, print the REAL stderr, route via `sb_log_error`.
- **T6 — jq without `-c` shreds JSONL; jq CRLF poisons everything.** One pretty-printing rewrite
  blinded the whole project registry every session (row 6); the CRLF faucet broke config reads
  (`auto_improve` read back as `"true\r"`). *Tell:* D6. Rules: always `jq -c` for line-oriented
  files, always `tr -d '\r'` after jq on Windows.
- **T7 — green ≠ working.** 506 green tests missed 14 bugs; 53 tests were tautological; a stubbed
  `schtasks` test printed "applied" while the real task was never created; vitest transpiles but
  never typechecks (a real `tsc` error shipped in two releases). *Tell:* the test greps a source
  file for a string instead of running the behavior. Standing review question: "does this gate
  test the real capability?" (**sb-validation-and-qa**).
- **T8 — capability-gated tests skip on exactly the buggy platform.** The `ln -s` probe (T4) and
  the path-guard symlink tests both self-skip on Windows — where the bugs lived — and there is
  still no Windows CI lane. *Tell:* `SKIP` lines in a suite run on the platform you're debugging.
- **T9 — non-GNU userlands silently no-op.** mawk (Pi) and BSD tools (macOS) accept GNU-isms and
  match NOTHING: `awk -v` escape-processes backslashes (corrupted Windows paths twice), GNU
  `\b`/`\x1b` regexes never fire on BSD, bash 3.2 fails to PARSE `case` inside `$(…)`. *Tell:*
  works on Linux CI, dead on Pi/macOS. Static scanner: `bash tests/test-script-portability.sh`.
- **T10 — ambient state trusted over per-process signals.** A global `.active-session-slug` pin
  clobbered by a concurrent session filed 88 docs into the wrong project's inbox. *Tell:*
  artifacts landing under the wrong project slug. Precedence is now
  `CLAUDE_PROJECT_DIR > cwd-if-known-project > pin` (mcp/src/tools/project-dir.ts) — a misroute
  needs cwd≠repo-root + unset `CLAUDE_PROJECT_DIR` + a stale pin to coincide.
- **Meta-trap.** Every one of these was a *silent degradation*, never a crash. When triaging here,
  distrust quiet subsystems: probe by injecting a violation you KNOW must trip (the planned P8
  liveness work exists because of this pattern — status: planned, not shipped).

## When NOT to use this skill

- You want the full incident chronicle, root causes, and status ledger → **sb-failure-archaeology**.
- You want to measure things (log schemas, latency percentiles, probe libraries, forget-score
  telemetry) → **sb-diagnostics-and-tooling**.
- You're adding/fixing tests or judging evidence quality → **sb-validation-and-qa**.
- You need a flag's default or a kill switch's exact name → **sb-config-and-flags**.
- The bug is "my environment won't build" → **sb-build-and-env**.

## Provenance and maintenance

Derived from repo evidence at plugin 0.33.31 (working tree, 2026-07-05; HEAD `6fba312` = 0.33.30
with the 0.33.31 batch uncommitted — since landed as `e9dfbd1`): `CHANGELOG.md` incident entries, `scripts/lib.sh` (normalize
funnel :29, log writers :182-306, prune :909, drain counters :1525-1546), `tests/run-all.sh:84-98`,
`scripts/session-load.sh:707`, `mcp/src/brain-paths.ts`, `mcp/src/server.ts:29-45`,
`mcp/src/tools/dream.ts:75-84`, `mcp/src/tools/knowledge-search.ts:392`,
`mcp/src/tools/episodic-search.ts:298-304`, `mcp/src/tools/graph-cluster-cli.ts:69-76`,
`scripts/wiki-write-guard.sh:26-31`, `scripts/validate-plugin.sh:92-118`,
`tests/test-bundle-current.sh`, `scripts/verify.sh`, and the 2026-07-02 deep audit
(88 confirmed findings). Every command above was verified against the working tree on 2026-07-05.

Re-verification one-liners (run when this skill feels stale):

| Fact class | Re-verify |
|---|---|
| Plugin version / is the 0.33.31 batch in your tree | `jq -r .version .claude-plugin/plugin.json | tr -d '\r'; git log --oneline -1` |
| SKIP-requires-exit-0 harness fix present | `grep -n 'only honor SKIP' tests/run-all.sh` |
| Guard path-form funnel present + used | `grep -n 'sb_normalize_path()' scripts/lib.sh; grep -c sb_normalize_path scripts/symlink-guard.sh scripts/persona-tool-guard.sh` |
| projects.jsonl writer uses `jq -c` | `grep -n 'jq -c --arg s' scripts/session-load.sh` |
| Stray-dir source-scan guard alive | `cd mcp && npx vitest run src/brain-paths.test.ts` |
| Two-wikis split still open (3 resolvers) | `grep -rn 'function resolveKnowledgeDir' mcp/src --include='*.ts'` — >1 hit outside tests = still open |
| Degraded-flag contracts | `cd mcp && npx vitest run src/tools/search-output-contract.test.ts` |
| REFLECT self-clustering exclusion | `grep -n 'generated:' mcp/src/tools/graph-cluster-cli.ts` |
| Guard wiring table | `jq '.hooks | keys' hooks/hooks.json` |
| Drainer scheduler health | `source scripts/lib.sh; sb_timer_health` |
| Legacy-wiki misroute clean | `find ~/.second-brain/wiki -name '*.md' 2>/dev/null | wc -l` (expect 0) |
