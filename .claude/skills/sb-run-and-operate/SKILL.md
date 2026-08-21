---
name: sb-run-and-operate
description: >
  Operator runbook for the second-brain Claude Code plugin: install, first-run setup, auth
  modes, the out-of-band drainer scheduler, upgrades, data geography, dream operations, and
  the user-facing skill/agent surface. Load this when installing the plugin,
  running /second-brain:setup or /second-brain:upgrade, deciding or diagnosing
  auth mode (ANTHROPIC_API_KEY vs OAuth/subscription, "extraction queued" banners,
  sb auth doctor), installing/uninstalling the drainer timer (systemd/launchd/schtasks,
  install-extract-timer.sh), answering "where does this file live / is it safe to delete"
  under ~/.second-brain or ~/knowledge, accepting/discarding/restoring dreams
  (wiki-backup-pre-accept, wiki-archive, wiki-restore.sh), or asking what a plugin skill or
  agent does. Do NOT load for: building bundles or recreating the dev environment
  (sb-build-and-env), measuring health via logs/probes/CLIs (sb-diagnostics-and-tooling),
  the full flag catalog (sb-config-and-flags), triaging live failures
  (sb-debugging-playbook), or change/release process (sb-change-control).
---

# sb-run-and-operate — install, run, upgrade, operate

Everything here is verified against the working tree at plugin version **0.33.37 (2026-07-13;
counts, versions, and surface tables re-verified — deeper cites last fully verified at
0.33.31)**. Surface counts, the tool count, the hook-event list, and the removal notes were
re-verified 2026-08-21 at 0.45.0. Commands are bash, run from the repo root unless they use `$CLAUDE_PLUGIN_ROOT`
(the installed plugin's cache dir; inside this repo, the repo root works for both).
Platform-specific commands are flagged.

## 0. Terms used throughout (defined once)

| Term | Meaning |
|---|---|
| **BRAIN_DIR** | `~/.second-brain` — private machine state (registry, transcripts, dreams, logs, config). Env override `BRAIN_DIR` / `SB_BRAIN_DIR`. |
| **KNOWLEDGE_DIR** | `~/knowledge` — the knowledge tier (`wiki/` + `graph/`). Set by the `knowledge_dir` plugin option, delivered as env `CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR`. |
| **hot tier** | `USER.md` + `projects/<slug>/PROJECT.md` + `projects.jsonl` — the small always-loaded surface injected at SessionStart. Size contract (USER.md ~3200 B target; emit caps 6000/3000; 8000 B budget) home: `skills/setup/SKILL.md`. |
| **drainer** | `scripts/extract-drain.sh` — out-of-band job that LLM-extracts archived transcripts a live session could not process; run every 30 min by a per-OS scheduler (§4). |
| **dream** | Staged background consolidation of the wiki: snapshot → run 7 phases on a **staging copy** → human/auto review → `dream_accept` applies to live (§7). |
| **FORGET** | Dream phase that proposes low-value pages for **reversible archive** (move to `~/.second-brain/wiki-archive/`, never delete). |
| **raw inbox** | `~/.second-brain/projects/<slug>/raw/` — captured-but-unprocessed material, drained into wiki pages by the raw-drainer agent. |

## 1. Install

Inside Claude Code (`README.md:33-37`):

```
/plugin marketplace add Cain-Ish/claude-code-plugin
/plugin install second-brain@second-brain
```

The marketplace (`.claude-plugin/marketplace.json`) carries one plugin: `second-brain` (source
`./`; the `cost-router` subplugin was absorbed and removed in 0.35.x — §9). Installing second-brain
wires, via `.claude-plugin/plugin.json`:

- **One MCP server** — `mcpServers: "./.claude-plugin/mcp.json"` → stdio server `knowledge-base`
  = `node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/server.bundle.js`, `alwaysLoad: true`. 23 tools as of
  0.45.0 (`grep -c '^registerJsonTool(' mcp/src/server.ts` — `code_map`/`code_neighbors` landed
  0.33.33). The bundles under `mcp/dist/` are
  **committed**, so a marketplace install needs no build step (`README.md:204`).
- **Hooks** — declared in `hooks/hooks.json` (not plugin.json), across 9 events: SessionStart
  (dir scaffold + discovery + hot-tier load + dream banner), UserPromptSubmit (persona context),
  Stop (verify gate, extraction, SAR banner), SubagentStop (result capture),
  PreCompact (extraction), PreToolUse (safety guards), ConfigChange (audit), PostToolUseFailure
  (tool-failure observation), PostToolUse (quality/injection/simplicity scans). Full matrix, matchers, and kill switches:
  sb-config-and-flags. Design rationale and invariants: sb-architecture-contract.
- **One userConfig option** — `knowledge_dir` (type directory, default `~/knowledge`).

### Prerequisites (`README.md:236-239`, `mcp/package.json`)

| Requirement | Notes |
|---|---|
| Node >= 22 | MCP server, `sb` CLI, and every `mcp/dist/tools/*.bundle.js` |
| bash | All hooks are `bash ${CLAUDE_PLUGIN_ROOT}/scripts/*.sh`. **Windows: Git Bash (or WSL) required — native cmd/PowerShell is not supported.** macOS stock bash 3.2 is supported. |
| jq | Used pervasively by hooks and skills (bundled with Git Bash) |
| GNU coreutils (macOS, optional) | provides `timeout`/`gtimeout`; without it, in-session extraction runs unbounded |

### Optional vector tier (one-time, ~70 MB)

Semantic search needs `@huggingface/transformers`, which cannot ship in the bundles:

```bash
bash "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh"              # one-time install into shared ~/.second-brain/vector-deps
bash "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh" --relink-only  # no-network heal after a version bump; exit 3 = full install needed
```

Without it nothing errors: `knowledge_search` degrades to BM25-only and `episodic_search` to
text-only, a SessionStart banner flags it, and `/second-brain:upgrade` offers the installer on
every run (`README.md:206-212`). Installer internals (staging/swap, Windows junction, exit
codes): sb-build-and-env.

## 2. First run: `/second-brain:setup`

Idempotent scaffold of the hot tier (`skills/setup/SKILL.md`). Steps, in order:

| Step | What it does | Opt-out / caution |
|---|---|---|
| 1 | Resolve the active project (monorepo-aware slug/parent); on slug collision it STOPS and offers exactly 3 options — never merges or clobbers | confirm slug with the operator |
| 2 | Scaffold `~/.second-brain/USER.md` (≤15 lines of prefs; existing file left alone) | — |
| 3 | Scaffold `projects/<slug>/PROJECT.md` (Goal/State/Conventions/Recent decisions/Open blockers/Cross-references) | — |
| 4 | Register the project in `projects.jsonl`; 4b writes graph anchors + a `part_of` edge when a monorepo parent was confirmed | — |
| 4c | Install the drainer scheduler: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-extract-timer.sh" --ensure` (idempotent, credentials-free) | `SB_DISABLE_AUTO_TIMER=1` skips it |
| 5 | Seed `~/.second-brain/persona-card.md` (≤14 non-blank lines; user-owned afterward) | — |
| 6 | Deep-scan the repo into the raw inbox (`raw-scan-cli.bundle.js`, `--dry-run` preview first; content-hash dedup makes reruns cheap) | `SB_SCAN_SKIP=1` skips |
| 6c | Autonomy consent ladder (below) | — |
| 7 | Confirm hot tier < ~3200 bytes combined | trim if over |

### Autonomy dials (`~/.second-brain/config.json`, seeded by `scripts/ensure-dirs.sh:30-41`)

Defaults since 0.30.0 — automation ON: `auto_improve: true` (free, offline deterministic wiki
upkeep on the drainer timer), `auto_maintain: true` (headless `claude -p` maintainer —
**reads your Claude OAuth and spends tokens**; only actually runs where `bwrap` exists, so it is
a no-op on macOS/Windows/bwrap-less Linux), `auto_accept: "safe"` (auto-apply low-risk dreams
only: no live-page deletions, FORGET dreams left for manual review). Persist changes with:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/set-autonomy.mjs" --auto-improve false --auto-maintain false --auto-accept off
```

Retention defaults in the same file: `dream_keep_count: 5`, `bak_ttl_days: 14`,
`embeddings_cache_gc: true`, `wiki_archive_ttl_days: 0` (= archived pages never expire).

Do not place `~/.second-brain` inside iCloud/Dropbox/Google Drive/OneDrive — concurrent JSONL
writes corrupt (`skills/setup/SKILL.md:391-392`).

## 3. Auth modes — the ops matrix

Backend decision lives in `sb_call_extractor` (`scripts/lib.sh:1284-1305`). The one fact that
shapes everything: **spawning `claude -p` from inside a Claude Code session under OAuth re-enters
the same OAuth-locked process and hangs** (the "recursive-claude lock"), so:

| Auth mode | In-session Stop/PreCompact extraction | Out-of-band drainer / cron / CI |
|---|---|---|
| `ANTHROPIC_API_KEY` exported | **works** — curl backstop, lock-immune | works (also enables the drainer's starvation escape) |
| OAuth / subscription (`claude /login`) | **queues** — health file records `status=queued`; the transcript is still archived for the drainer | works via the `claude` CLI backend, with interactive-session defer rules (§4) |
| Local LLM (`SB_EXTRACTOR_LOCAL_URL`, e.g. ollama) | works — no creds, no lock, offline-capable | works |

Diagnose with the standalone CLI (`bin/sb`, a bash wrapper; `bin/sb.cmd` for cmd.exe):

```bash
"$CLAUDE_PLUGIN_ROOT/bin/sb" auth status   # authoritative mode verdict (probes `claude auth status`)
"$CLAUDE_PLUGIN_ROOT/bin/sb" auth doctor   # prints the two supported setups + fix commands
export ANTHROPIC_API_KEY=sk-ant-...        # enables in-session extraction; without it OAuth queues
```

Under pure OAuth this is **not a failure** — it is the designed split: in-session capture queues,
the drainer floor still captures everything out-of-band. The SessionStart banner surfaces
`queued`/`fail` states from `~/.second-brain/.extractor-health.json`. Banner interpretation and
deeper probes: sb-diagnostics-and-tooling.

## 4. Out-of-band drainer operations

`scripts/extract-drain.sh` processes archived transcripts outside any session; always exits 0;
refuses to run when `CLAUDECODE=1`. `scripts/install-extract-timer.sh` manages its scheduler:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/install-extract-timer.sh"               # print rendered unit; touch NOTHING
bash "$CLAUDE_PLUGIN_ROOT/scripts/install-extract-timer.sh" --ensure      # idempotent install-if-needed (what setup 4c runs)
bash "$CLAUDE_PLUGIN_ROOT/scripts/install-extract-timer.sh" --apply       # install + enable
bash "$CLAUDE_PLUGIN_ROOT/scripts/install-extract-timer.sh" --uninstall   # removes unit/plist/task + shim + env file
bash "$CLAUDE_PLUGIN_ROOT/scripts/install-extract-timer.sh" --apply --oauth  # Linux/systemd ONLY: creds-granting variant (explicit consent; no-op printed elsewhere)
```

| OS | Mechanism | Cadence | Platform notes |
|---|---|---|---|
| Linux | systemd user units (`systemd/sb-extract-drain.timer`) | `OnBootSec=5min`, `OnUnitActiveSec=30min`, `Persistent=true` | For runs while logged out, run `loginctl enable-linger "$USER"` yourself — the script only PRINTS it (deliberate host-state boundary). Hardened default unit never persists `ANTHROPIC_API_KEY`. |
| macOS | launchd LaunchAgent `~/Library/LaunchAgents/sb-extract-drain.plist` | `StartInterval=1800` + `RunAtLoad` | Runs only while logged in (no linger equivalent). |
| Windows (Git Bash) | Task Scheduler `schtasks /Create /TN sb-extract-drain /SC MINUTE /MO 30` | every 30 min | Installer probes real Git-for-Windows bash paths first so it never schedules WSL's `System32\bash.exe`; fails LOUD if schtasks rejects. |
| other | unsupported | — | fallback printed: export `ANTHROPIC_API_KEY` for in-session capture, or cron `extract-drain.sh` yourself |

Operating facts you will need:

- **Stable shim**: the scheduler runs `~/.second-brain/bin/sb-extract-drain.sh`, which resolves
  the **latest installed plugin version** (`sort -V`) each tick — the scheduler survives plugin
  upgrades without reinstallation.
- **Single-flight**: `flock -n` on `~/.second-brain/.extract-drain.lock`; where flock is missing
  (stock macOS, Git Bash) an atomic mkdir-lock with a 7200 s staleness steal
  (`extract-drain.sh:199-227`). A slow run cannot overlap the next tick.
- **Defer + escape**: the drainer skips while an interactive `claude` session is alive (the OAuth
  lock is global). After 6 consecutive defers or a >24 h-old backlog, exactly one drain is forced
  through — but only when safe (API key set, or the relaxed pmode-only verdict plus a `timeout`
  binary). Tuning knobs: sb-config-and-flags; starvation triage: sb-debugging-playbook.
- **Batch**: 5 transcripts per run (`SB_DRAIN_BATCH`), outcome ledger
  `~/.second-brain/.extraction-state.jsonl`. After each batch, in the same lock: archive
  retention GC always; deterministic wiki maintenance if `auto_improve`; the headless LLM
  maintainer if `auto_maintain` (Linux + bwrap only).
- **Opt-out**: `SB_DISABLE_AUTO_TIMER=1` makes both setup 4c and the SessionStart self-heal skip
  installation (`session-load.sh:390`); `--uninstall` removes everything the installer created.

## 5. Upgrade: `/second-brain:upgrade`

Mechanism (`skills/upgrade/SKILL.md`):

1. `CURRENT` = `.claude-plugin/plugin.json .version`; `INSTALLED` =
   `~/.second-brain/.installed-version` (`0.0.0` if absent).
2. Compare with `sort -V`, **never** string compare (`0.24.9 > 0.24.18` lexically).
3. Apply only migration files `skills/upgrade/migrations/<version>.md` where
   `> INSTALLED AND <= CURRENT`. A version with no file is a marker-bump-only release — most
   releases; the narrative lives in CHANGELOG.md, which is never context-loaded. As of 0.33.37
   there are 18 migration files: 0.16.0, 0.20.0, 0.20.1, 0.22.0, 0.24.18, 0.24.28, 0.24.41,
   0.24.42, 0.24.45, 0.24.47, 0.24.48, 0.24.49, 0.24.50, 0.25.0, 0.32.0, 0.33.0, 0.33.18,
   0.33.19.
4. Each migration: state intent → idempotent check → apply (backup if it touches user data) →
   report. Destructive ones require explicit confirmation.
5. **Step 4b runs on EVERY upgrade** (not version-gated): smoke-import
   `@huggingface/transformers`; on failure offer `bin/install-vector-deps.sh` (covers fresh
   installs and cache wipes — dist ships, node_modules never does).
6. Finish: `echo "$CURRENT" > ~/.second-brain/.installed-version`, then run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh"`.

Safe to run anytime; no-op at current version. How releases themselves are cut: sb-change-control.

## 6. Data geography — the ops map

Two roots, one privacy rule: plugin code (shareable via marketplace) contains zero user data;
all user data stays local under the two roots below, nothing synced (`README.md:245`).

- **BRAIN_DIR** (`~/.second-brain`) — private state: hot tier, project registry, raw inbox,
  transcripts, dreams, wiki-archive, backups, config, logs, scheduler shim.
- **KNOWLEDGE_DIR** (`~/knowledge`) — the wiki (`wiki/<category>/*.md`, `wiki/index.md`) and the
  graph (`graph/edges.jsonl` + registry/quarantine/conflicts). `graph/` is a **sibling** of
  `wiki/`, not inside it.

Deletion quick rules (full path→writer→reader→safety map:
[references/data-geography.md](references/data-geography.md)):

| Class | Paths |
|---|---|
| NEVER delete | `~/knowledge/wiki/`, `graph/edges.jsonl` (append-only history), `USER.md`, `persona-card.md`, `projects/`, `projects.jsonl`, `transcripts/` (self-capped), `wiki-archive/` (**the only copy of forgotten pages**) |
| Safe to delete (regenerable) | `episodic-index.json`, `wiki/index.md`, both `.embeddings-cache.json` caches (`wiki/` page vectors + `transcripts/` episodic vectors — re-embedded on next search), `.injected/`, `scratch/`, `tool-registry.json`, `vector-deps/` (~70 MB re-download), lock/marker dotfiles when nothing is running |
| Auto-pruned — do not manage by hand | dreams (keep 5), `wiki-backup-pre-accept-*.tgz` (14 d), transcripts (100 files/5 MB), extraction markers (30 d) |

## 7. Dream operations

Lifecycle tools (MCP, on the `knowledge-base` server): `dream_create` → `dream_status` /
`dream_list` → `dream_accept` | `dream_discard` | `dream_cancel`. User entry point:
`/second-brain:dream` (inline default; `--background` dispatches the dream-runner agent).

- **Where things live**: `~/.second-brain/dreams/drm_*/` = `status.json` (lifecycle +
  heartbeat), `staging/wiki/` (the copy all 7 phases mutate), `transcripts/` (sanitized copies),
  `diff.md`, `forget-manifest.tsv`. The live wiki is read-only to a running dream.
- **One active dream at a time**; a pending/running dream whose `status.json` mtime is older
  than 6 h (`SB_DREAM_RUN_TIMEOUT`) is reclaimed as failed. Retention keeps the newest 5.
- **Accept is guarded** (guard rationale: sb-architecture-contract): before the destructive
  apply, `dream-accept.sh` writes a **fail-closed backup**
  `~/.second-brain/wiki-backup-pre-accept-<UTCstamp>.tgz` — if the backup cannot be written the
  accept is refused (`dream-accept.sh:131-152`). Restore any accept with:

  ```bash
  tar xzf ~/.second-brain/wiki-backup-pre-accept-<stamp>.tgz -C "${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
  ```

- **Safe mode** (`auto_accept: "safe"`, the default) sets `SB_DREAM_ACCEPT_NO_DELETE=1`: accepts
  that would remove any live page are refused, and FORGET-proposing dreams are always left for
  manual review.
- **Windows caveat**: without rsync (normal on Git Bash) accept merge-copies staging over live
  and **deletions are NOT applied** — announced in the accept output. FORGET/dedup removals wait
  for an rsync-equipped accept (`dream-accept.sh:216-241`).
- **FORGET is reversible**: on accept, manifest pages are re-scored against the post-accept wiki,
  then **moved** to `~/.second-brain/wiki-archive/<category>/` and logged to
  `wiki-archive-log.jsonl` (`skills/dream/SKILL.md:235-259`). Restore:

  ```bash
  bash "$CLAUDE_PLUGIN_ROOT/scripts/wiki-restore.sh" --list     # what is archived
  bash "$CLAUDE_PLUGIN_ROOT/scripts/wiki-restore.sh" <slug>     # move back + reindex after
  ```

- **Discard** removes staging/transcripts and stamps `archived_at` (nothing applied). **Cancel**
  flips pending/running → canceled; the runner self-stops at its next status check.

Live state check: `ls ~/.second-brain/dreams/ && cat ~/.second-brain/dreams/drm_*/status.json | jq .status`

## 8. The user-facing surface

As of 0.45.0: **17 skills** (`ls -d skills/*/ | wc -l`) and **4 agents** (`ls agents/*.md`).
Invocation column from each SKILL.md frontmatter: `/` = user slash command
(`user-invocable: true`), `M` = model may auto-invoke (`disable-model-invocation: false`),
`docs` = neither (retained as documentation after the 0.27.0/0.29.0 surface collapses).

| Skill | One-liner | Inv. |
|---|---|---|
| `setup` | Scaffold the hot tier for the active repo; idempotent (§2) | / |
| `upgrade` | Semver migration walk + marker update (§5) | / |
| `import-host` | Import CLAUDE.md/AGENTS.md/.cursorrules etc. into USER.md/PROJECT.md, chunk-by-chunk confirmed | / |
| `track` | Declare folders/globs as project doc sources, auto-indexed each session (`--list`/`--remove`) | / |
| `capture` | Raw-inbox capture CLI docs — capture itself is automatic since 0.29.0 | docs |
| `maintain` | Full knowledge-maintainer run, then loop raw-drainer until the inbox is empty | / |
| `dream` | Run a dream (§7); inline default, `--background` | / |
| `query` | Wiki search wrapper around `knowledge_search`; cited synthesis | M |
| `recall` | Search past transcripts (hybrid vector+text) for decisions/solutions | / |
| `status` | Hot-tier + wiki health at a glance | / |
| `review` | Open blockers, stale projects, pending dreams across all projects; read-only | / |
| `audit` | What the safety layer did this session (reads `audit-log.jsonl`); read-only | / |
| `lint` | Wiki + PROJECT.md cross-reference health check; read-only by default | / |
| `improve` | Retired manual pin flow (replaced by dream + `pin_to_*` MCP tools) | docs |
| `think` | Opus advisor brief via `persona_think` (~$0.11/call) | / |
| `doubt` | Adversarial validation of the plugin itself, rotating focus | / |
| `using-second-brain` | Persona-as-collaborator protocol (consult identity/memory before substantive answers) | M |

| Agent | Role (all model-dispatched, not user commands) |
|---|---|
| `dream-runner` | Executes the 7-phase dream on staging; dispatched by `/dream --background` |
| `knowledge-maintainer` | 7-phase KB caretaker cycle (hygiene→audit→dedup→relate→enrich→ai-blocks→reindex) |
| `raw-drainer` | One bounded raw-inbox batch → wiki nodes; looped by `/maintain`; resumable |
| `search-conversations` | Cross-session memory restoration from transcript history |

> REMOVED in 0.44.0 — `code-review-deep` + `team` skills and six agents (`quality-reviewer`,
> the four `code-review-*` reviewers, `team-worker`) plus `scripts/team-run.sh`. They served none
> of CONSTITUTION.md's four content classes. The fresh-context critic role moved to
> `persona_think` (`skills/doubt` step 4, `stop-verify-gate.sh` critic offer).

## 9. cost-router subplugin — REMOVED (0.35.x)

Absorbed into second-brain and removed entirely: the marketplace entry, the `cost-router/`
source tree, its `cr-*` agents and skills, all `COST_ROUTER_*` flags, and second-brain's
`cost-router-capture.sh` Stop hook are gone. Tier routing lives in `model-ladder.json`
(consumed by stop-extract / pre-compact / maintain-llm-drain / extraction-quality-gate /
lib.sh). If a cached install still shows cost-router, uninstall it. History: wiki
`entities/cost-router` + the `archive/docs` branch.

## When NOT this skill

| Need | Go to |
|---|---|
| Build bundles, recreate dev env, vector-deps internals | sb-build-and-env |
| Measure health: logs, probes, `sb` diagnostics, banner interpretation | sb-diagnostics-and-tooling |
| Any flag's default/semantics, kill-switch catalog | sb-config-and-flags |
| Live failure triage (drainer starvation, misroutes, guard failures) | sb-debugging-playbook |
| Release/change process, gates | sb-change-control |
| Why the design is shaped this way; invariants | sb-architecture-contract |

## Provenance and maintenance

Derived from repo evidence only: `.claude-plugin/{plugin,marketplace,mcp}.json`, `README.md`,
`hooks/hooks.json`, `skills/setup/SKILL.md`, `skills/upgrade/SKILL.md` + `migrations/`,
`skills/dream/SKILL.md`, `scripts/{install-extract-timer,extract-drain,ensure-dirs,dream-accept,
wiki-restore,session-load,lib}.sh`, `bin/{sb,install-vector-deps.sh}`, `mcp/src/cli/sb.ts`,
`mcp/src/server.ts`, `cost-router/` (since removed). Authored 2026-07-05 against the 0.33.31 working tree
(HEAD 6fba312 + uncommitted release batch); counts/versions re-verified 2026-07-13 at 0.33.37.

Volatile facts — re-verify before trusting counts/versions:

```bash
jq -r .version .claude-plugin/plugin.json                      # plugin version (was 0.45.0)
jq -r '.plugins[].version' .claude-plugin/marketplace.json     # second-brain version (single entry since cost-router's removal)
ls -d skills/*/ | wc -l                                        # skill count (was 17)
ls agents/*.md | wc -l                                         # agent count (was 4)
ls skills/upgrade/migrations/                                  # migration files (was 19)
grep -c '^registerJsonTool(' mcp/src/server.ts                 # MCP tool count (was 23)
jq -r '.hooks | keys[]' hooks/hooks.json                       # hook events (was 9)
head -6 skills/*/SKILL.md | grep -E 'name:|invocable|invocation'  # skill invocation flags
sed -n '30,41p' scripts/ensure-dirs.sh                         # config.json defaults
grep -n 'MINUTE\|StartInterval' scripts/install-extract-timer.sh; grep -n OnUnitActiveSec systemd/sb-extract-drain.timer   # 30-min cadence
sed -n '278,293p' mcp/src/cli/sb.ts                            # auth doctor text
grep -n 'wiki-backup-pre-accept' scripts/dream-accept.sh       # backup tarball name
```
