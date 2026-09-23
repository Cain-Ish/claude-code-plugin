# Buddy — a companion that shows what second-brain is doing

**Status: IMPLEMENTED 2026-09-22/23 after a re-scope (below); Phase 3 opt-ins (`buddy_react`,
tmux popup) remain PROPOSED and are not planned.**

**Re-scope (2026-09-23).** The buddy is not a pet with a stat sheet. It is the visible layer between
Claude and the knowledge base: the user sees when memory is delivered, offered, read, saved, or
gated; the buddy reminds Claude to save (one bounded line, once per session, only when a
decision-shaped session has saved nothing); and it answers from the KB directly without an LLM.
Stats/peak/dump were dropped from the identity; species/eyes/hat/rarity stay as the account-hash
sprite. Shipped: `sb_buddy_event` (lib.sh) + its TS twin `mcp/src/buddy-events.ts` (the MCP server
emits `read`/`remembered` events from `knowledge_*`, `episodic_*`, `pin_*`, `archive_to_wiki`,
`knowledge_relate`, `dream_*` into `.buddy/_global.json`), `scripts/buddy-statusline.sh` (one jq,
`set -f`, ~35 ms), producers in plan-first-nudge (gates + clears) / persona-tool-guard (phase) /
stop-verify-gate (Gate C + clear + critic offer) / session-load (delivered) / dream-autostage
(pending, `_global`) / stop-extract (remembered) / persona-context (retrieved + the memory nudge)
/ flow-guard (guard), `.buddy/` GC, `mcp/src/buddy-identity.ts` (wyhash + mulberry32, Zig-vector
pinned), `sb buddy [ask|name|mute|install|uninstall|--rehatch]` with a version-independent shim,
`skills/buddy` (`ask`, `why`, `pending`), setup step 6d, `tests/test-buddy-statusline.sh`
(8 sections incl. glob/exec safety, width at 60/80/120, hot-path ceiling, nudge), R8 bumps
(scripts 54, skills 17, tests 164). Review findings (2026-09-23, 19 items) were all applied.

Signature note: the helper is `sb_buddy_event <sid|_global> <kind> <mood> <line> [source] [ttl_s]`.

The ask: a Claude-buddy-style pet next to the input box that tells the user, at a glance, what the
plugin is doing right now — the session goal and phase, what memory was just delivered, which gate
fired and why, what is waiting for review — and that the persona layer and the other user-facing
layers can talk through, instead of each shouting its own banner.

---

## 0. What the research settled

**The native `/buddy` no longer exists.** Anthropic shipped it in v2.1.89 (2026-03-31), rolled it out
to Pro on 04-08, and removed it in v2.1.97 on 04-09 ("REMOVED: System Prompt: Buddy Mode"). It was a
system-prompt layer, not a plugin surface: no settings key, no hook could influence it, state lived
in `~/.claude.json` under `companion`. Species/rarity/stats were recomputed from `accountUuid` via
FNV-1a/wyhash + mulberry32 on every start. There is nothing to attach to.

**Where it rendered.** In plain terminals it sat in the input area's chrome; in tmux ≥ 3.2 it was a
floating popup in a corner. Neither placement is exposed to plugins.

**What a plugin can drive in the Claude Code TUI — the complete list:**

| Surface | Renders where | Who sees it | Works in Desktop / VS Code? |
|---|---|---|---|
| `statusLine` command (settings.json) | The line(s) directly **under the input box**; multi-line, ANSI colour, right-alignment allowed; re-run on every state change (~300 ms debounce) | user | yes |
| Hook `systemMessage` | Transcript, as a system notice | user | **no** — Desktop (#77518) and VS Code (#76736) drop it |
| Hook `additionalContext` | Model context only | model | yes |
| SessionStart plain stdout | Transcript at session start | user + model | yes |
| `Notification` hook | OS notification / terminal bell | user | yes |
| `spinnerVerbs` / `spinnerTips` (settings.json) | The "Thinking…" line while the model works | user | partial |
| MCP server `instructions` | System prompt, read once at session start | model | yes |
| Skill (`/second-brain:x`) | Transcript, on demand | user | yes |

No plugin API exists for a persistent panel, avatar, or custom widget, and none is announced.

**The statusline JSON.** The script receives on stdin: `session_id`, `transcript_path`, `cwd`,
`model.{id,display_name}`, `workspace.{current_dir,project_dir}`,
`context_window.{used_percentage,context_window_size,total_input_tokens,total_output_tokens}`,
`cost.{total_cost_usd,total_duration_ms,total_lines_added,total_lines_removed}`,
`rate_limits.five_hour.{used_percentage,resets_at}`, `version`, `output_style.name`. Whatever the
script prints is the statusline.

**How the community brought the buddy back** (`ramarivera/coding-buddy`, 441★, MIT): statusline
renders a right-aligned ASCII sprite with a speech bubble; an MCP server's `instructions` tells the
model to call `buddy_react` at the end of each turn; a Stop hook picks a canned line when the model
did not; a `/buddy` skill handles commands; tmux users get an optional popup. That is exactly the
integration set we already have — minus the statusline.

**What we already have that a buddy needs** (see `.claude/skills/sb-architecture-contract/references/state-files.md`):
- `~/.second-brain/.injected/<sid>.json` — goal, goal keywords, scope, plan_ack; `<sid>.phase` — `plan|implement|verify`.
- `audit-log.jsonl` — every guard verdict with rule name (`gate-a-plan-first`, `gate-b-drift-warn`, `gate-c-verify-block`, `info-flow:*`, `injection:*`) plus `gate=value-loop injected= read=` rows and `kind:"latency"` rows.
- `observations/<sid>.jsonl` — per-tool ok/err.
- `dreams/*/status.json` — pending / completed-unreviewed / failed.
- `persona-card.md`, `persona-signals.jsonl`, `.persona-dismissals.jsonl`.
- `.installed-catalog.json`, `.extractor-health.json`.
- Nothing named statusline, spinner, buddy, companion, pet or mascot exists in the repo.

**Constraints that bite:**
- `surface-budget.json` is at cap on every counted surface: `scripts` 53/53, `skills` 16/16. Any new
  script or skill needs a same-commit bump (R8) with a reason.
- CONSTITUTION scope rule: "a surface that does not produce, store, or deliver one of these four is
  not memory, and does not belong in this plugin". A mascot on its own fails this test.
- Token discipline: nothing always-injected that has not earned it.
- Cross-platform: bash + jq must work on Windows git-bash; coding-buddy's issue tracker is a warning
  about terminal-width detection and Unicode-width rendering.
- Hooks in one event run in parallel; the audit already found torn JSONL appends (D120). Any new
  state file must be written atomically (write temp, rename).
- Plugins cannot set `statusLine` declaratively. The user's `~/.claude/settings.json` must carry it;
  `/second-brain:setup` has to offer to write it, and must chain an existing statusline rather than
  replace it.

---

## 1. Placement — where the buddy lives

- **A. Statusline, right-aligned, 2–4 lines (recommended).** The only supported surface that sits
  next to the input box, refreshes live, and renders in CLI, Desktop, and VS Code. Left side: a
  one-line telemetry strip (goal · phase · context % · last verdict). Right side: sprite + bubble.
  Collapses to a single line under ~90 columns.
- **B. tmux popup / dedicated pane, top-right.** Closest to the original position and to what the
  user asked for. Only for tmux ≥ 3.2; the VPS + tmux + `/remote-control` setup qualifies, a Windows
  terminal does not. A `display-popup -E` window or a small pinned pane that tails the same state
  file. Build it as an opt-in add-on to A in a later phase, never as the primary path.
- **C. Transcript notices (`systemMessage`).** Broken on Desktop and VS Code. Use only as the fallback
  for CLI users who turn the statusline off.

**Recommended: A, with B as a phase-3 opt-in.** "Top-right near the input" is not reachable from a
plugin in a plain terminal; the statusline is the honest equivalent — directly under the input, right
edge, always visible.

## 2. What the buddy says — the data contract

One state file, `~/.second-brain/.buddy/<sid>.json`, written atomically by a small `lib.sh` helper
`sb_buddy_event <kind> <text> [meta-json]` and read by the renderer. Shape:

```json
{ "ts": 1758560000, "mood": "focused", "kind": "gate", "line": "Plan first — 2 files, no plan on record",
  "source": "plan-first-nudge", "ttl_s": 900 }
```

Producers (all existing hooks, one extra line each — no new hook scripts):

| Existing script | Event → mood / line |
|---|---|
| `session-load.sh` | `delivered` — "Loaded USER + PROJECT (7.2 KB) · 3 recent sessions" |
| `persona-context.sh` | `goal` — sets goal + phase the first time; `retrieved` — "2 wiki pages offered: [[x]], [[y]]" |
| `plan-first-nudge.sh` | `gate` — Gate A deny / Gate B warn / deny, with the reason already in the hook |
| `persona-tool-guard.sh` | `phase` — implement→verify flips; `guard` — ask/deny/rewrite verdicts |
| `flow-guard.sh`, `symlink-guard.sh`, `tool-return-scanner.sh` | `guard` — "Held: credential-shaped egress" / "Flag: injection pattern in tool return" |
| `stop-verify-gate.sh` | `gate` — Gate C block or the critic offer |
| `stop-extract.sh` / `pre-compact.sh` | `remembered` — "Filed 1 decision, 2 learnings → wiki" (from the extractor's own counts) |
| `dream-autostage.sh` | `pending` — "Dream ready for review (12 pages)" |
| `observe-tool-use.sh` (failure side) | `stumble` — after N consecutive failures on the same target |

Readers: the statusline renderer, `/second-brain:buddy`, and — this is the part that ties the layers
together — `persona-context.sh` can consult the same file to avoid re-nudging what the buddy just
showed. The buddy is not a new source of truth; it is the **one display for the state the hooks
already keep**.

Every line has a TTL; expired lines fall back to the ambient state (goal · phase). Nothing is ever
written that the user cannot trace to an `audit-log.jsonl` row.

## 3. Constitution fit — why this is not "a good tool in the wrong repo"

Frame it as the **delivery layer's face**, not as a pet:

- It shows *what was delivered* (hot tier loaded, wiki pages offered) and *whether the loop closed*
  (extraction filed, dream pending) — the exact `injected → read` metric the CONSTITUTION names as
  the measured contract, made visible per session for the first time.
- It replaces three user-visible channels that do not work everywhere (`systemMessage` from SAR and
  the critic offer; SessionStart banners that scroll away) with one that does.
- It costs zero tokens by default: rules-based, no LLM, no `additionalContext`.

The sprite, name, and moods are cosmetics on top of a telemetry line. If the cosmetics were deleted,
the line would still be a delivery surface. That is the test to keep applying: **every buddy line
must be a delivery, a gate, or a capture event**. "Good morning" is not one.

Kill switches: `SB_BUDDY=off` (whole thing), `SB_BUDDY_SPRITE=off` (telemetry only),
`SB_BUDDY_REACT=off` (default off — see §5). `SB_HOOK_PROFILE=minimal` turns the sprite off.

## 4. Identity and persona — what the buddy *is*

- Species / eyes / hat / rarity: deterministic from `accountUuid` in `~/.claude.json` with the
  original salt, so anyone who had a native buddy gets the same one back (coding-buddy proved the
  algorithm; same `wyhash + mulberry32`). Fallback seed: hash of `USER.md`'s first line.
- Name and voice: seeded from `persona-card.md` `## Identity` and `## Communication style`, editable
  via `/second-brain:buddy name <x>`. This is the hook the user asked for — the persona layer gets a
  face, and persona signals (`persona-signals.jsonl` score ≥ 0.7) can surface as the buddy's
  "I noticed you usually…" lines instead of another banner.
- Stats (DEBUGGING · PATIENCE · CHAOS · WISDOM · SNARK): keep them purely cosmetic and hash-derived.
  Do **not** derive them from session behaviour — that would be personality profiling, and it would
  be wrong more often than fun.

## 5. Model-authored reactions — optional, off by default

coding-buddy's MCP `instructions` field makes the model call `buddy_react` at the end of every turn.
It is charming and it costs a tool call per turn plus system-prompt tokens forever. Against the
token-discipline rule, and given the plugin already stacks five PreToolUse scripts, ship it as:

- an MCP tool `buddy_react({line, mood})` (23 → 24 tools; MCP tools are not budgeted), and
- **no** `instructions` push unless `SB_BUDDY_REACT=on`; when on, the `using-second-brain` skill
  carries a one-line "end the turn with `buddy_react`" instruction rather than the MCP manifest, so it
  is scoped to sessions that loaded the protocol.

Rules-based lines cover the daily-work case on their own.

## 6. Interaction — `/second-brain:buddy`

One skill (16 → 17, bump R8 with reason "delivery surface, user-invocable"):

| Command | Does |
|---|---|
| `/second-brain:buddy` | Card: sprite, name, current goal · phase, last 5 buddy lines with their audit rows |
| `/second-brain:buddy why` | Explain the last gate/guard line in full (reads the audit row, prints the rule and the retry path) |
| `/second-brain:buddy name <x>` / `mute` / `unmute` / `sprite off` | Persist in `~/.second-brain/buddy.json` |
| `/second-brain:buddy pending` | Everything waiting on the user: dreams to review, held untrusted pages, persona rule candidates |

`why` is the one that pays for the skill: today a Gate A deny is a wall of text once, then gone.

## 7. Renderer — `scripts/buddy-statusline.sh`

- bash + jq only, no node start-up; budget **< 50 ms** (the statusline re-runs on every state change,
  and `hook-timer.sh` cannot wrap it). Cache the sprite frame; read at most four small files.
- Input: statusline JSON on stdin (context %, model, cost) + `.buddy/<sid>.json` +
  `.injected/<sid>.{json,phase}` + a `dreams/` glob. Never tail `audit-log.jsonl` in the hot path;
  producers already put the line in the buddy file.
- Layout: measure `$COLUMNS` (fallback: `tput cols`, then 120); sprite 4 rows × ~12 cols
  right-aligned; bubble to its left, wrapped to the remaining width; under 90 cols drop the sprite
  and show one line: `🧠 goal · phase · ctx 34% · <line>`.
- Chaining: if the user already had a `statusLine`, `setup` records the old command in
  `~/.second-brain/buddy.json`; the renderer runs it and prints its output as the first line.
- Test: a width fixture at 60/80/120 columns asserting every ANSI-stripped row fits (copy
  coding-buddy's approach); a Windows git-bash CI job — this is where coding-buddy fell over.
- Scripts 53 → 54: bump R8 with reason "statusline renderer — delivery surface".

## 8. Phases

- **Phase 0 — spike (1 day).** `buddy-statusline.sh` printing `goal · phase · ctx% · last verdict`
  from files that already exist. No sprite, no new writers. Install by hand in one settings.json.
  Falsifiable check: does the user look at it? If a week of use says no, stop here — the telemetry
  line alone still earns its place, the mascot would not.
- **Phase 1 — events (2–3 days).** `sb_buddy_event` in `lib.sh`; one call added to each producer
  in §2; TTLs; atomic writes; test that every producer writes a line the renderer can parse.
- **Phase 2 — face + skill (2–3 days).** Sprite from account hash, persona-seeded name, the
  `/second-brain:buddy` skill with `why` and `pending`. `setup` offers to write `statusLine` and
  chains an existing one. R8 bumps for one script and one skill.
- **Phase 3 — opt-ins.** `buddy_react` MCP tool behind `SB_BUDDY_REACT`; tmux ≥ 3.2 popup for the
  VPS workflow; `Notification` hook for "dream ready" when the terminal is not focused.

## 9. Risks and open questions

- **Statusline ownership.** It is a user-level setting; the plugin can only offer. Two plugins that
  both want it will fight — chaining (§7) handles the common case, not the general one.
- **Desktop / VS Code rendering.** Statusline is reported to work in both; verify on this machine
  before Phase 1, because `systemMessage` already does not.
- **Width detection on Windows.** Unknown until tried; keep the single-line fallback as the default
  there until the fixture passes.
- **Noise.** A bubble that changes on every tool call is a distraction, not a companion. Rule:
  one line per event kind per 60 s, gates always win over retrievals, retrievals over captures.
- **Scope creep.** XP, achievements, moods from "code quality" — all of it is outside the four
  content classes. The `doubt` skill should be pointed at the buddy after Phase 2.

## Sources

- Removal: [issue #45517](https://github.com/anthropics/claude-code/issues/45517),
  [Bring Back Buddy #45596](https://github.com/anthropics/claude-code/issues/45596)
- Rebuild pattern: [ramarivera/coding-buddy](https://github.com/ramarivera/coding-buddy)
- Statusline: [code.claude.com/docs/en/statusline](https://code.claude.com/docs/en/statusline)
- Hooks: [code.claude.com/docs/en/hooks-guide](https://code.claude.com/docs/en/hooks-guide)
- Plugins: [code.claude.com/docs/en/plugins-reference](https://code.claude.com/docs/en/plugins-reference)
- Rendering gaps: [#77518 Desktop](https://github.com/anthropics/claude-code/issues/77518),
  [#76736 VS Code](https://github.com/anthropics/claude-code/issues/76736)
